class_name VoxelRenderSystem
extends Node
## Product-facing owner of the selected dedicated DDA backend.
##
## Shapes are packed into persistent R8UI atlases. A compute upload writes only the dirty cuboid;
## adding a fragment consumes reserved atlas space and only refreshes GPU metadata/BVH.

const MIN_ATLAS_DEPTH := 256
const MAX_ATLAS_DEPTH := 2048

## Lado del atlas de bricks en bricks, no en texeles: 128 x 128 deja la textura en 1024 x 1024 y solo
## crece en profundidad, que es el eje con margen (2048 texeles = 256 capas de bricks).
const BRICK_GRID_SIDE := 128

## Holgura sobre los bricks que pide el mapa, para que los fragmentos que nacen al romper algo
## quepan sin reconstruir el atlas entero.
const BRICK_HEADROOM := 13

## The BVH and Shape storage keep fixed leaves for runtime fragments. Activating a reserved leaf
## avoids rebuilding metadata for the complete map during destruction.
const FRAGMENT_ENTRY_HEADROOM := 256
const SMALL_MAP_INITIAL_ENTRY_HEADROOM := 512
const SMALL_MAP_SHAPE_THRESHOLD := 64

## Techo de celdas del atlas de macroceldas. Es la misma rejilla dividida entre ocho, así que el mapa
## entero son 885 K celdas: sobra de largo.
const MAX_MACRO_ATLAS_CELLS := 16_000_000

var world: VoxelWorld3D
var effect: DedicatedVoxelDDAEffect
var compositor: Compositor
var shadow_clipmaps: VoxelShadowClipmaps
var local_shadow_pool: VoxelLocalShadowPool
var _voxel_atlas := VoxelAtlas3D.new()
var _macro_atlas := VoxelAtlas3D.new()
var _bricks := VoxelBrickPool.new()
var _brick_table := PackedInt32Array()
var _brick_table_dirty := true
var _macros := PackedByteArray()
var _slots := {}
var _shapes: Array[VoxelShape3D] = []
var _transforms := {}
var _entry_indices := {}
var _reserved_entry_indices := {}
## Una hoja que nació en el BVH de vidrio puede alojar cualquier Shape; una hoja que no nació allí
## solo puede reciclarse para opacos porque la topología secundaria permanece fija.
var _entry_glass_capable := {}
var _free_entry_indices := PackedInt32Array()
var _reserved_entry_headroom := FRAGMENT_ENTRY_HEADROOM
var _palette_rows := {}
var _glass_usage := {}
var _macro_atlas_dimensions := Vector3i.ZERO
var _cursor := Vector3i.ZERO
var _shelf_height := 0
var _layer_depth := 0
var _metadata_dirty := false
var _palette_dirty := false
var _camera: Camera3D
var last_metadata_sync_ms := 0.0
var last_transform_sync_ms := 0.0
var last_metadata_fallback_reason := ""
var last_damage_update_ms := 0.0
var damage_uploads_enabled := true
var entry_capacity_rebuilds := 0
var _entry_capacity_dirty := false
var _cleanup_elapsed := 0.0
var _transform_tracker := VoxelTransformTracker.new()
var _movable_transforms := {}


## El arranque del renderer son ~3,6 s con el mapa entero (atlas ~1 s, volumen de sombras ~2,6 s), y
## ocurre después de importar. `setup_progressive` reparte ese tramo en la pantalla de carga;
## `setup` sigue siendo la llamada de siempre para los bancos de pruebas.
func setup(voxel_world: VoxelWorld3D, camera: Camera3D) -> bool:
	# Vía `Callable` para que el analizador no exija `await`: sin pantalla `_setup` no se suspende.
	var result: Variant = _setup.call(voxel_world, camera, Callable())
	if result is bool:
		return result
	push_error("VoxelRenderSystem: el arranque sin pantalla de carga se suspendió")
	return false


func setup_progressive(
	voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable
) -> bool:
	return await _setup(voxel_world, camera, progress)


func _setup(voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable) -> bool:
	world = voxel_world
	_camera = camera
	effect = DedicatedVoxelDDAEffect.new()
	compositor = Compositor.new()
	compositor.compositor_effects = [effect]
	camera.compositor = compositor
	world.voxels_changed.connect(_on_voxels_changed)
	world.body_split.connect(_on_body_split)
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				_shapes.append(shape)
	if _shapes.is_empty():
		return true
	# Cinco edificios + 256 reservas era el caso patológico: una destrucción normal cruzaba el techo
	# por muy poco y pagaba la reconstrucción durante juego. Los mapas grandes ya aportan miles de
	# hojas reciclables y mantienen la reserva corta para no aumentar su recorrido por píxel.
	_reserved_entry_headroom = SMALL_MAP_INITIAL_ENTRY_HEADROOM \
		if _shapes.size() <= SMALL_MAP_SHAPE_THRESHOLD else FRAGMENT_ENTRY_HEADROOM
	if progress.is_valid():
		progress.call(0.0, "Construyendo el atlas de voxeles…")
		await Engine.get_main_loop().process_frame
	if not _rebuild_atlases():
		return false
	shadow_clipmaps = VoxelShadowClipmaps.new()
	shadow_clipmaps.name = "VoxelShadowClipmaps"
	add_child(shadow_clipmaps)
	if world.renderer_settings.sun_shadows_enabled:
		# El tramo de sombras es el grueso del arranque: se le da del 20 % al 97 % de la barra.
		var shadows := func(fraction: float, label: String) -> void:
			progress.call(0.20 + 0.77 * fraction, label)
		var started := false
		if progress.is_valid():
			started = await shadow_clipmaps.setup_progressive(world, camera, shadows)
		else:
			started = shadow_clipmaps.setup(world, camera)
		if not started:
			return false
		effect.configure_shadow_clipmaps(
			shadow_clipmaps.get_static_rids(),
			shadow_clipmaps.get_dynamic_rids(),
			shadow_clipmaps.get_shader_metadata()
		)
		# Antes la clipmap avisaba aqui cada vez que se desplazaba. El volumen es fijo: los metadatos
		# se entregan una vez, arriba, y no vuelven a cambiar.
	else:
		shadow_clipmaps.set_process(false)
	_refresh_effect_upload_sources()
	local_shadow_pool = VoxelLocalShadowPool.new()
	local_shadow_pool.name = "VoxelLocalShadowPool"
	add_child(local_shadow_pool)
	local_shadow_pool.setup(world, camera)
	local_shadow_pool.volumes_changed.connect(effect.configure_local_shadow_volumes)
	effect.configure_local_shadow_volumes([], local_shadow_pool.get_shader_metadata())
	if progress.is_valid():
		progress.call(1.0, "Listo")
	return true


func register_shape(shape: VoxelShape3D) -> void:
	if _shapes.has(shape):
		return
	_shapes.append(shape)
	if not _can_allocate(shape):
		last_metadata_fallback_reason = "atlas_capacity:%s" % shape.name
		_rebuild_atlases()
		return
	_allocate_shape(shape)
	_upload_entire_shape(shape)
	if not _activate_reserved_entry(shape):
		var palette_key := shape.palette.get_instance_id()
		var palette_missing := not _palette_rows.has(palette_key)
		last_metadata_fallback_reason = (
			"new_palette:%s" % shape.name if palette_missing
			else "renderer_entry_capacity:%s" % shape.name
		)
		# No se reconstruye dentro de la señal de destrucción: una explosión puede crear cientos de
		# fragmentos. Se agrupan todos y `_process` hace una sola reconstrucción al final del frame.
		# `_sync_metadata` incluye todas las Shapes vivas y vuelve a dejar HEADROOM hojas libres, de
		# modo que el límite deja de ser fijo sin encarecer de entrada los mapas pequeños.
		_metadata_dirty = true
		_palette_dirty = _palette_dirty or palette_missing
		if not palette_missing:
			# Después de crecer basta volver a dejar el margen normal; todas las Shapes activas ya forman
			# parte de la nueva topología.
			_reserved_entry_headroom = FRAGMENT_ENTRY_HEADROOM
			_entry_capacity_dirty = true


func unregister_shape(shape: VoxelShape3D) -> void:
	_shapes.erase(shape)
	_deactivate_shape_entry(shape)
	_slots.erase(shape.get_instance_id())
	_transforms.erase(shape.get_instance_id())
	_glass_usage.erase(shape.get_instance_id())


## Las Shapes que pueden haber cambiado de sitio desde el frame anterior, o sea las de cuerpos
## dinamicos. Barrer los 2312 nodos del mapa cada frame era puro coste de GDScript.
##
## Se pregunta al mundo en el momento en vez de mantener una cache, que es donde estaba el fallo: la
## cache se llenaba al registrar la Shape, asi que una que pasaba a dinamica despues -una torre que
## pierde su apoyo, un tramo suelto que estrena cuerpo- no entraba nunca. El cuerpo caia y su
## transformada no volvia a subir a la GPU: quedaba un fantasma de pie en el sitio de antes,
## atravesable e indestructible porque los voxeles de verdad ya estaban en otro lado. La sombra si se
## movia, porque la clipmap ya leia esta misma lista.
func movable_shapes() -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	_movable_transforms.clear()
	if world == null:
		return result
	var snapshot: Dictionary = _transform_tracker.collect(world.get_transform_tracked_body_ids())
	var snapshot_shapes: Array = snapshot.shapes
	var transforms: Array = snapshot.transforms
	for index in mini(snapshot_shapes.size(), transforms.size()):
		var shape := snapshot_shapes[index] as VoxelShape3D
		if shape == null:
			continue
		result.append(shape)
		_movable_transforms[shape.get_instance_id()] = transforms[index]
	return result


func _process(delta: float) -> void:
	if effect == null:
		return
	last_metadata_sync_ms = 0.0
	last_transform_sync_ms = 0.0
	var transform_updates: Array[Dictionary] = []
	for shape in movable_shapes():
		var key := shape.get_instance_id()
		# El compositor no es un VisualInstance3D y por ello Godot no interpola estos metadatos por
		# nosotros. Subir la muestra de render evita que carrocería, ruedas y cascotes avancen a saltos
		# de física aunque la cámara ya sea suave.
		var render_transform: Transform3D = _movable_transforms[key] \
			if _movable_transforms.has(key) else shape.get_global_transform_interpolated()
		if _transforms.has(key) and _transform_equal(_transforms[key], render_transform):
			continue
		_transforms[key] = render_transform
		if not _entry_indices.has(key) and shape.renderer_slot >= 0:
			_entry_indices[key] = shape.renderer_slot
		if not _entry_indices.has(key):
			_activate_reserved_entry(shape)
		if _entry_indices.has(key) and not _metadata_dirty:
			transform_updates.append({
				"index": int(_entry_indices[key]), "transform": render_transform,
			})
		else:
			last_metadata_fallback_reason = "moving_shape_without_entry:%s" % shape.name
			# A shape without atlas/entry metadata cannot be made visible by rebuilding every frame.
			# Leave it out and let registration/capacity handling resolve it explicitly.
	if not transform_updates.is_empty() and not _metadata_dirty:
		var transform_started := Time.get_ticks_usec()
		if not effect.update_entry_transforms(transform_updates):
			last_metadata_fallback_reason = "effect_rejected_transform_batch"
		last_transform_sync_ms = (Time.get_ticks_usec() - transform_started) / 1000.0
	_cleanup_elapsed += delta
	if _cleanup_elapsed >= 1.0:
		_cleanup_elapsed = 0.0
		var live: Array[VoxelShape3D] = []
		var live_keys := {}
		for shape in _shapes:
			if is_instance_valid(shape) and shape.is_inside_tree() and shape.voxel_count() > 0:
				live.append(shape)
				live_keys[shape.get_instance_id()] = true
		_shapes = live
		# Un Object liberado no puede cruzar el límite de una función con parámetro tipado: el error
		# ocurre antes de entrar a la guarda `is_instance_valid`. Se limpian los metadatos por el id
		# estable que ya usa el atlas, sin volver a tocar el Object muerto.
		for key: Variant in _entry_indices.keys():
			if not live_keys.has(key):
				_deactivate_entry_key(int(key))
	if _metadata_dirty:
		var started := Time.get_ticks_usec()
		_sync_metadata(_palette_dirty)
		last_metadata_sync_ms = (Time.get_ticks_usec() - started) / 1000.0
		if _entry_capacity_dirty:
			entry_capacity_rebuilds += 1
			last_metadata_fallback_reason = "entry_capacity_rebuilt:%d" % _entry_indices.size()
		_metadata_dirty = false
		_palette_dirty = false
		_entry_capacity_dirty = false


## Censo CPU de los cuatro registros que deben describir exactamente las mismas Shapes. Sirve para
## convertir un posible fallo visual futuro en una causa concreta y también para pruebas de estrés.
func get_coherence_snapshot() -> Dictionary:
	var effect_entry_count := effect.get_entry_count() if effect != null else 0
	var live_keys := {}
	var missing_slots: Array[String] = []
	var missing_entries: Array[String] = []
	var invalid_entries: Array[String] = []
	var stale_renderer_slots: Array[String] = []
	for shape in _shapes:
		if not is_instance_valid(shape) or not shape.is_inside_tree() or shape.voxel_count() <= 0:
			continue
		var key := shape.get_instance_id()
		live_keys[key] = true
		if not _slots.has(key):
			missing_slots.append(shape.name)
		if not _entry_indices.has(key):
			missing_entries.append(shape.name)
			continue
		var entry_index := int(_entry_indices[key])
		if entry_index < 0 or entry_index >= effect_entry_count:
			invalid_entries.append(shape.name)
		if shape.renderer_slot != entry_index:
			stale_renderer_slots.append(shape.name)
	var orphan_slots := 0
	for key in _slots:
		if not live_keys.has(key):
			orphan_slots += 1
	return {
		"live_shapes": live_keys.size(),
		"atlas_slots": _slots.size(),
		"renderer_entries": _entry_indices.size(),
		"free_entries": _free_entry_indices.size(),
		"gpu_entry_records": effect_entry_count,
		"missing_slots": missing_slots,
		"missing_entries": missing_entries,
		"invalid_entries": invalid_entries,
		"stale_renderer_slots": stale_renderer_slots,
		"orphan_slots": orphan_slots,
		"metadata_rebuild_pending": _metadata_dirty,
		"entry_capacity_rebuilds": entry_capacity_rebuilds,
	}


func _rebuild_atlases() -> bool:
	var live: Array[VoxelShape3D] = []
	var max_macro_x := 1
	var max_macro_y := 1
	var total_macro_volume := 0
	var total_bricks := 0
	for shape in _shapes:
		if not is_instance_valid(shape) or shape.data == null or shape.voxel_count() == 0:
			continue
		live.append(shape)
		var macro_dimensions := shape.data.get_macro_dimensions()
		max_macro_x = maxi(max_macro_x, macro_dimensions.x)
		max_macro_y = maxi(max_macro_y, macro_dimensions.y)
		total_macro_volume += macro_dimensions.x * macro_dimensions.y * macro_dimensions.z
		total_bricks += shape.data.get_occupied_macros().size()
	_shapes = live
	if _shapes.is_empty():
		return true
	# La reconstrucción es transaccional. Hasta que los dos atlas candidatos estén completos se
	# conservan el pool, slots y texturas que el frame anterior sigue dibujando. El código anterior
	# borraba del registro de render las Shapes que no entraban, aunque su colisión siguiera viva.
	var previous_bricks = _bricks
	var previous_brick_table := _brick_table
	var previous_brick_table_dirty := _brick_table_dirty
	var previous_macros := _macros
	var previous_slots := _slots
	var previous_dimensions := _macro_atlas_dimensions
	var previous_cursor := _cursor
	var previous_shelf_height := _shelf_height
	var previous_layer_depth := _layer_depth
	var brick_grid := _plan_brick_grid(total_bricks)
	_bricks = VoxelBrickPool.new()
	if not _bricks.configure(brick_grid):
		push_error("VoxelRenderSystem: no se pudo reservar el pool de %d bricks" % total_bricks)
		_bricks = previous_bricks
		return false
	# Se pide cuatro veces el volumen que hace falta: el empaquetado por estantes desperdicia mucho
	# con 2312 Shapes de tamaños dispares, y aquí cada celda cubre 512 voxeles, así que la holgura
	# cuesta megabytes en vez de cientos.
	var candidate_dimensions := _plan_atlas(
		max_macro_x, max_macro_y, total_macro_volume * 4, MAX_MACRO_ATLAS_CELLS, 512
	)
	var layout_ready := false
	for attempt in 6:
		_macro_atlas_dimensions = candidate_dimensions
		_macros = PackedByteArray()
		_macros.resize(candidate_dimensions.x * candidate_dimensions.y * candidate_dimensions.z)
		_macros.fill(0)
		_slots = {}
		_brick_table = PackedInt32Array()
		_brick_table_dirty = true
		_bricks.configure(brick_grid)
		_reset_packer()
		layout_ready = true
		for shape in _shapes:
			if not _allocate_shape(shape):
				layout_ready = false
				break
			_copy_macros_to_cpu_atlas(shape)
		if layout_ready:
			break
		candidate_dimensions = _grow_macro_atlas(candidate_dimensions)
		if candidate_dimensions == Vector3i.ZERO:
			break
	if not layout_ready:
		push_error(
			"VoxelRenderSystem: reconstrucción cancelada; %d Shapes no caben sin perder sincronía"
			% _shapes.size()
		)
		_bricks = previous_bricks
		_brick_table = previous_brick_table
		_brick_table_dirty = previous_brick_table_dirty
		_macros = previous_macros
		_slots = previous_slots
		_macro_atlas_dimensions = previous_dimensions
		_cursor = previous_cursor
		_shelf_height = previous_shelf_height
		_layer_depth = previous_layer_depth
		return false
	var candidate_voxels := VoxelAtlas3D.new()
	var candidate_macros := VoxelAtlas3D.new()
	if not candidate_voxels.create(_bricks.get_dimensions(), _bricks.get_bytes(), true) \
			or not candidate_macros.create(_macro_atlas_dimensions, _macros, true):
		candidate_voxels.release()
		candidate_macros.release()
		_bricks = previous_bricks
		_brick_table = previous_brick_table
		_brick_table_dirty = previous_brick_table_dirty
		_macros = previous_macros
		_slots = previous_slots
		_macro_atlas_dimensions = previous_dimensions
		_cursor = previous_cursor
		_shelf_height = previous_shelf_height
		_layer_depth = previous_layer_depth
		return false
	var previous_voxel_atlas := _voxel_atlas
	var previous_macro_atlas := _macro_atlas
	_voxel_atlas = candidate_voxels
	_macro_atlas = candidate_macros
	_sync_metadata(true)
	_refresh_effect_upload_sources()
	previous_voxel_atlas.release()
	previous_macro_atlas.release()
	return true


func _refresh_effect_upload_sources() -> void:
	if effect == null:
		return
	var sources: Array = [_voxel_atlas, _macro_atlas]
	if world != null and world.renderer_settings.sun_shadows_enabled \
			and shadow_clipmaps != null and is_instance_valid(shadow_clipmaps):
		sources.append_array(shadow_clipmaps.get_upload_sources())
	effect.configure_upload_sources(sources)


static func _grow_macro_atlas(current: Vector3i) -> Vector3i:
	var cells := current.x * current.y * current.z
	if current.z < MAX_ATLAS_DEPTH and cells * 2 <= MAX_MACRO_ATLAS_CELLS:
		return Vector3i(current.x, current.y, current.z * 2)
	if current.x < 512 and current.y < 512 and cells * 4 <= MAX_MACRO_ATLAS_CELLS:
		return Vector3i(current.x * 2, current.y * 2, current.z)
	return Vector3i.ZERO


## Rejilla del pool de bricks para un número dado de bricks ocupados. Solo crece en Z: X e Y se
## quedan fijos en 128 bricks (1024 texeles) porque es donde está el límite de tamaño de textura.
static func _plan_brick_grid(brick_count: int) -> Vector3i:
	var per_layer := BRICK_GRID_SIDE * BRICK_GRID_SIDE
	var wanted := maxi(1, brick_count * BRICK_HEADROOM / 10)
	var layers := clampi((wanted + per_layer - 1) / per_layer, 1, MAX_ATLAS_DEPTH / 8)
	return Vector3i(BRICK_GRID_SIDE, BRICK_GRID_SIDE, layers)


## Elige el tamaño del atlas de macroceldas para un volumen dado. Se busca un cubo con lado potencia
## de dos que deje sitio de sobra para el desperdicio del empaquetado, sin pasarse del techo.
static func _plan_atlas(max_x: int, max_y: int, volume: int, cell_budget: int, side_cap: int) -> Vector3i:
	var side := maxi(1, _next_power_of_two(maxi(max_x, max_y)))
	# 1,6x de holgura: el empaquetado por estantes deja huecos, y quedarse corto significa Shapes
	# invisibles.
	while side < side_cap and side * side * side < volume * 16 / 10:
		side *= 2
	var depth := clampi(
		_next_power_of_two(maxi(1, volume * 16 / 10 / maxi(1, side * side))),
		MIN_ATLAS_DEPTH, MAX_ATLAS_DEPTH
	)
	while side * side * depth > cell_budget and depth > 1:
		depth /= 2
	return Vector3i(side, side, depth)


func _reset_packer() -> void:
	_cursor = Vector3i.ZERO
	_shelf_height = 0
	_layer_depth = 0


func _can_allocate(shape: VoxelShape3D) -> bool:
	if not _voxel_atlas.get_rd_rid().is_valid():
		return false
	if _bricks.get_used() + shape.data.get_occupied_macros().size() > _bricks.get_capacity():
		return false
	return not _fit(shape.data.get_macro_dimensions()).is_empty()


## Empaquetado por estantes en tres dimensiones sobre el atlas de macroceldas: se avanza en X hasta
## agotar la fila, se sube en Y hasta agotar la capa y se avanza en Z. Apilar solo en Z, que es lo
## que hacía antes, agota la profundidad con dos docenas de Shapes grandes.
##
## Sin ordenar por altura a propósito: es la mejora estándar del shelf packing, pero aquí mete
## primero las Shapes grandes y llenan el atlas antes — medido sobre el atlas denso, entraban 619
## Shapes sin ordenar y solo 308 ordenadas. El orden del mundo reparte mejor.
func _fit(dimensions: Vector3i) -> Dictionary:
	var cursor := _cursor
	var shelf := _shelf_height
	var layer := _layer_depth
	if cursor.x + dimensions.x > _macro_atlas_dimensions.x:
		cursor = Vector3i(0, cursor.y + shelf, cursor.z)
		shelf = 0
	if cursor.y + dimensions.y > _macro_atlas_dimensions.y:
		cursor = Vector3i(0, 0, cursor.z + layer)
		layer = 0
	if cursor.z + dimensions.z > _macro_atlas_dimensions.z \
			or cursor.x + dimensions.x > _macro_atlas_dimensions.x \
			or cursor.y + dimensions.y > _macro_atlas_dimensions.y:
		return {}
	return {
		"origin": cursor,
		"cursor": Vector3i(cursor.x + dimensions.x, cursor.y, cursor.z),
		"shelf": maxi(shelf, dimensions.y),
		"layer": maxi(layer, dimensions.z),
	}


func _allocate_shape(shape: VoxelShape3D) -> bool:
	var macro_dimensions := shape.data.get_macro_dimensions()
	var placement := _fit(macro_dimensions)
	if placement.is_empty():
		return false
	# El pool reserva un brick por macrocelda ocupada y devuelve la tabla que el shader consulta.
	# Sale vacía cuando ya no queda sitio, y entonces la Shape no se coloca en ningún sitio.
	var pool_base := _bricks.get_used()
	var table := _bricks.append_shape(shape.data)
	if table.is_empty():
		return false
	_cursor = placement.cursor
	_shelf_height = placement.shelf
	_layer_depth = placement.layer
	_slots[shape.get_instance_id()] = {
		"atlas_origin": Vector3i.ZERO,
		"macro_origin": placement.origin as Vector3i,
		"dimensions": shape.data.get_dimensions(),
		"macro_dimensions": macro_dimensions,
		"brick_table_base": _brick_table.size(),
		"pool_base": pool_base,
		"pool_count": _bricks.get_used() - pool_base,
	}
	_brick_table.append_array(table)
	_brick_table_dirty = true
	return true


func _copy_macros_to_cpu_atlas(shape: VoxelShape3D) -> void:
	var slot: Dictionary = _slots[shape.get_instance_id()]
	var macro_dimensions: Vector3i = slot.macro_dimensions
	var macro_source := shape.data.get_macro_occupancy()
	var macro_origin: Vector3i = slot.macro_origin
	for z in macro_dimensions.z:
		for y in macro_dimensions.y:
			var source_offset := y * macro_dimensions.x + z * macro_dimensions.x * macro_dimensions.y
			var target_offset := macro_origin.x + (macro_origin.y + y) * _macro_atlas_dimensions.x \
				+ (macro_origin.z + z) * _macro_atlas_dimensions.x * _macro_atlas_dimensions.y
			for x in macro_dimensions.x:
				_macros[target_offset + x] = macro_source[source_offset + x]


func _upload_entire_shape(shape: VoxelShape3D) -> void:
	_copy_macros_to_cpu_atlas(shape)
	var slot: Dictionary = _slots[shape.get_instance_id()]
	var macro_dimensions: Vector3i = slot.macro_dimensions
	# Los bricks de una Shape van seguidos en el pool pero no en la textura. Antes eso se resolvía
	# recorriendo las macroceldas en GDScript y subiendo cada brick por su cuenta: en el mapa de
	# Teardown eran 549.804 vueltas — el 53 % sobre macroceldas vacías — y 260.672 subidas sueltas,
	# cada una con su textura de staging. `append_shape` ya dejó los bytes escritos en el pool, así
	# que basta con sacarlos en tandas y dejar que el atlas haga una copia por brick desde una sola
	# fuente. Un fragmento recién roto sigue siendo una tanda y ya está.
	for upload: Dictionary in _bricks.extract_uploads(slot.pool_base, slot.pool_count):
		_voxel_atlas.update_compact_regions(upload.bytes, upload.source_size, upload.copies)
	_macro_atlas.update_region(
		_macros, slot.macro_origin, slot.macro_origin + macro_dimensions - Vector3i.ONE
	)


func _on_voxels_changed(
	shape: VoxelShape3D, _world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i
) -> void:
	var started := Time.get_ticks_usec()
	# El slot del volumen fuente queda libre antes de registrar sus fragmentos. Antes se esperaba al
	# barrido de limpieza de un segundo: durante ráfagas se agotaban las 256 hojas reservadas y el
	# cascote seguía teniendo colisión pero desaparecía hasta que otro slot se liberaba.
	if shape.voxel_count() == 0:
		unregister_shape(shape)
		return
	if not _slots.has(shape.get_instance_id()) or dirty_min.x < 0:
		return
	if not damage_uploads_enabled:
		last_damage_update_ms = 0.0
		return
	var slot: Dictionary = _slots[shape.get_instance_id()]
	var macro_dimensions: Vector3i = slot.macro_dimensions
	var base: int = slot.brick_table_base
	var low := dirty_min / 8
	var high := dirty_max / 8
	# El cráter toca unos pocos bricks: cada uno se reescribe entero y se sube suelto, que sale más
	# barato que recortar el cuboide sucio de un pool disperso.
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var brick_slot: int = _brick_table[
					base + x + macro_dimensions.x * (y + macro_dimensions.y * z)
				]
				if brick_slot < 0:
					continue
				_voxel_atlas.update_compact_region(
					_bricks.refresh_brick(shape.data, brick_slot, Vector3i(x, y, z)),
					_bricks.get_slot_origin(brick_slot), Vector3i(8, 8, 8)
				)
	# La ocupación de macroceldas es derivada y diminuta; solo se copia el cuboide sucio.
	var macro_source := shape.data.get_macro_occupancy()
	var macro_origin: Vector3i = slot.macro_origin
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var source_index := x + y * macro_dimensions.x \
					+ z * macro_dimensions.x * macro_dimensions.y
				var target := macro_origin + Vector3i(x, y, z)
				var target_index := target.x + target.y * _macro_atlas_dimensions.x \
					+ target.z * _macro_atlas_dimensions.x * _macro_atlas_dimensions.y
				_macros[target_index] = macro_source[source_index]
	_macro_atlas.update_region(_macros, macro_origin + low, macro_origin + high)
	last_damage_update_ms = (Time.get_ticks_usec() - started) / 1000.0


func _on_body_split(_source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	for body in created:
		for shape in body.get_shapes():
			register_shape(shape)


func _sync_metadata(include_palette: bool) -> void:
	if effect == null or not _voxel_atlas.get_rd_rid().is_valid():
		return
	var entries: Array[Dictionary] = []
	_entry_indices.clear()
	_reserved_entry_indices.clear()
	_entry_glass_capable.clear()
	_free_entry_indices = PackedInt32Array()
	var palette_texels := PackedColorArray()
	if include_palette:
		_palette_rows.clear()
		# Cada fila contiene 256 colores sRGB seguidos por 256 texels de propiedades:
		# roughness, metallic, emission/32. El shader los mantiene separados para no aplicar la
		# conversion sRGB a datos lineales.
		palette_texels.resize(maxi(1, _shapes.size()) * 512)
	for index in _shapes.size():
		var shape := _shapes[index]
		if not _slots.has(shape.get_instance_id()):
			continue
		var palette_key := shape.palette.get_instance_id()
		if not _palette_rows.has(palette_key):
			_palette_rows[palette_key] = index
		var palette_row := int(_palette_rows[palette_key])
		_entry_indices[shape.get_instance_id()] = entries.size()
		shape.renderer_slot = entries.size()
		_entry_glass_capable[entries.size()] = _shape_has_glass(shape)
		entries.append(_entry_for_shape(shape, palette_row))
		_transforms[shape.get_instance_id()] = shape.global_transform
		if include_palette:
			var colors := shape.palette.get_colors()
			var properties := shape.palette.get_render_properties()
			for material in mini(256, colors.size()):
				palette_texels[palette_row * 512 + material] = colors[material]
			for material in mini(256, properties.size()):
				palette_texels[palette_row * 512 + 256 + material] = properties[material]
	for reserve_offset in _reserved_entry_headroom:
		var entry_index := entries.size()
		entries.append(_placeholder_entry(entry_index))
		_reserved_entry_indices[entry_index] = true
		_entry_glass_capable[entry_index] = true
		_free_entry_indices.append(entry_index)
	var grid := _bricks.get_grid()
	effect.configure_entries(
		_voxel_atlas.get_rd_rid(), _macro_atlas.get_rd_rid(), entries,
		palette_texels, maxi(1, _shapes.size()),
		_brick_table if _brick_table_dirty else PackedInt32Array(),
		Vector2i(grid.x, grid.y)
	)
	_brick_table_dirty = false


func _entry_for_shape(shape: VoxelShape3D, palette_row: int) -> Dictionary:
	var slot: Dictionary = _slots[shape.get_instance_id()]
	return {
		"transform": shape.global_transform,
		"dimensions": slot.dimensions,
		"voxel_size": shape.voxel_size,
		"atlas_origin": slot.atlas_origin,
		"macro_origin": slot.macro_origin,
		"macro_dimensions": slot.macro_dimensions,
		"brick_table_base": slot.brick_table_base,
		"palette_row": palette_row,
		"has_glass": _shape_has_glass(shape),
	}


static func _placeholder_entry(entry_index: int) -> Dictionary:
	return {
		"transform": Transform3D(Basis.IDENTITY, Vector3(1_000_000.0 + entry_index * 2.0, 0, 0)),
		"dimensions": Vector3i.ONE,
		"voxel_size": 0.1,
		"atlas_origin": Vector3i.ZERO,
		"macro_origin": Vector3i.ZERO,
		"macro_dimensions": Vector3i.ONE,
		"brick_table_base": 0,
		"palette_row": 0,
		# Reserved leaves also exist in the glass BVH, so either material class can occupy them later.
		"has_glass": true,
	}


func _deactivate_shape_entry(shape: VoxelShape3D) -> void:
	if not is_instance_valid(shape):
		return
	var key := shape.get_instance_id()
	_deactivate_entry_key(key)
	shape.renderer_slot = -1


func _deactivate_entry_key(key: int) -> void:
	if not _entry_indices.has(key):
		return
	var entry_index := int(_entry_indices[key])
	effect.update_entries([{"index": entry_index, "entry": _placeholder_entry(entry_index)}])
	# Una hoja inicial cuya Shape murió es tan reutilizable como una reserva original. Convertirla en
	# reserva mantiene fija la topología BVH, evita aumentar el coste de recorrido y hace que partir
	# una Shape recicle su propia hoja en el mismo evento.
	_reserved_entry_indices[entry_index] = true
	if not _free_entry_indices.has(entry_index):
		_free_entry_indices.append(entry_index)
	_entry_indices.erase(key)
	_transforms.erase(key)
	_slots.erase(key)
	_glass_usage.erase(key)


func _activate_reserved_entry(shape: VoxelShape3D) -> bool:
	if not is_instance_valid(shape) or not _slots.has(shape.get_instance_id()):
		return false
	var key := shape.get_instance_id()
	if _entry_indices.has(key):
		return true
	var palette_key := shape.palette.get_instance_id()
	var free_offset := _find_free_entry_offset(_shape_has_glass(shape))
	if free_offset < 0 or not _palette_rows.has(palette_key):
		return false
	var entry_index := _free_entry_indices[free_offset]
	_free_entry_indices.remove_at(free_offset)
	_entry_indices[key] = entry_index
	shape.renderer_slot = entry_index
	_reserved_entry_indices[entry_index] = true
	_transforms[key] = shape.global_transform
	if not effect.update_entries([{
		"index": entry_index,
		"entry": _entry_for_shape(shape, int(_palette_rows[palette_key])),
	}]):
		_entry_indices.erase(key)
		shape.renderer_slot = -1
		_free_entry_indices.append(entry_index)
		last_metadata_fallback_reason = "effect_rejected_entry:%s" % shape.name
		return false
	if _brick_table_dirty:
		var grid := _bricks.get_grid()
		effect.update_brick_table(_brick_table, Vector2i(grid.x, grid.y))
		_brick_table_dirty = false
	return true


func _find_free_entry_offset(needs_glass: bool) -> int:
	for offset in range(_free_entry_indices.size() - 1, -1, -1):
		var entry_index := _free_entry_indices[offset]
		if not needs_glass or bool(_entry_glass_capable.get(entry_index, false)):
			return offset
	return -1


func _shape_has_glass(shape: VoxelShape3D) -> bool:
	var key := shape.get_instance_id()
	if _glass_usage.has(key):
		return bool(_glass_usage[key])
	var used: PackedByteArray = shape.data.get_used_materials()
	var colors := shape.palette.get_colors()
	for material in mini(256, mini(used.size(), colors.size())):
		if used[material] != 0 and colors[material].a < 0.995:
			_glass_usage[key] = true
			return true
	_glass_usage[key] = false
	return false


static func _transform_equal(a: Transform3D, b: Transform3D) -> bool:
	return a.origin.is_equal_approx(b.origin) and a.basis.is_equal_approx(b.basis)


static func _next_power_of_two(value: int) -> int:
	var result := 1
	while result < value:
		result <<= 1
	return result


func _exit_tree() -> void:
	if is_instance_valid(_camera):
		_camera.compositor = null
	compositor = null
	effect = null
	_voxel_atlas.release()
	_macro_atlas.release()
