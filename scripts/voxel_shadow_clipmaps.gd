class_name VoxelShadowClipmaps
extends Node
## Volumen de ocupacion del mapa entero para los rayos de sol y de AO, con cuatro niveles de
## resolucion. Cada texel R8UI guarda un bloque de 2x2x2 celdas, un bit por celda.
##
## Antes esto eran cuatro clipmaps centrados en la camara que se desplazaban con ella, y esa era la
## fuente de los trompicones al caminar: cada vez que la camara cruzaba el borde de un nivel habia
## que rasterizar en CPU la loncha que entraba, y eso medido en Lee son 82-144 ms clavados en un solo
## frame. Ahora el volumen es fijo y cubre el mapa de punta a punta, que es lo que hace Teardown
## (1252x128x1252 texeles con tres mips). No se desplaza nunca, asi que no hay nada que rasterizar
## mientras juegas: solo lo que cambia por destruccion o por objetos que se mueven.
##
## La capa estatica y la dinamica van fusionadas en un solo volumen. Separadas costarian el doble de
## memoria — inviable al cubrir el mapa entero — y ademas obligaban al shader a leer dos texturas por
## muestra para juntarlas con un OR. El precio es que mover algo obliga a re-rasterizar su region
## incluyendo la geometria fija de alrededor, pero esa region es pequena.
##
## La clase conserva el nombre `VoxelShadowClipmaps` por compatibilidad con el renderer y los
## bindings existentes.

const LEVELS := 4
## Celda del nivel 0. Los niveles van doblando: 0,2 / 0,4 / 0,8 / 1,6 m.
##
## A 0,1 m el mapa entero de Lee (329 x 73 x 367 m) pedia 1 GB. A 0,2 m son 133 MB, que es justo lo
## que ya costaban los cuatro clipmaps de antes, y la resolucion solo empeora en los primeros 51 m
## —los unicos que el nivel 0 cubria a 0,1 m— a cambio de que no haya un solo tiron.
const BASE_CELL_SIZE := 0.2
## Techo del nivel 0. Un mapa mas grande que Lee engorda la celda en vez de reventar la VRAM.
const MAX_LEVEL0_BYTES := 192 * 1024 * 1024
## Margen alrededor del mapa para que un rayo que sale por un borde no lea basura.
const VOLUME_PADDING := 2.0
## Techo de refresco dinamico por frame. Lo que no entra se arrastra al siguiente: una sombra un
## frame tarde no se ve; un frame de 100 ms si.
## Shapes en movimiento que refrescan sombra por frame. Es un techo duro, no un presupuesto de
## tiempo: la version anterior acumulaba en una cola lo que no le daba tiempo a rasterizar, y con 65
## props despiertos entraban mas regiones por frame de las que salian. La cola crecia sin limite y
## `_coalesce`, que es O(n^2) sobre ella, subia sola de 21 a 191 ms mientras nadie tocaba nada.
const SHAPES_PER_FRAME := 12
## Umbral de la zona muerta, al cuadrado. Una celda del nivel fino son 10 cm.
const SHADOW_DEADBAND_SQ := 0.01
## Cada cuantos frames se barren las Shapes borradas.
const SWEEP_EVERY_FRAMES := 15

var last_upload_bytes := 0
var last_damage_upload_bytes := 0
var last_dynamic_update_ms := 0.0
var last_region_allocate_ms := 0.0
var last_region_raster_ms := 0.0
var last_region_upload_ms := 0.0
var last_damage_update_ms := 0.0
var total_memory_bytes := 0
var damage_updates_enabled := true

var _world: VoxelWorld3D
var _camera: Camera3D
var _textures: Array[VoxelAtlas3D] = []
## Celda (no metros) de la esquina baja del volumen, por nivel. Todos los niveles arrancan en el
## mismo punto del mundo, asi que estos son el mismo sitio expresado en celdas distintas.
var _origins: Array[Vector3i] = []
var _logical_sizes: Array[Vector3i] = []
var _packed_sizes: Array[Vector3i] = []
var _base_cell_size := BASE_CELL_SIZE
var _transform_tracker := VoxelTransformTracker.new()
var _update_planner := VoxelShadowUpdatePlanner.new()
var _movable_bounds := {}
var _shape_cache: Array[VoxelShape3D] = []
var _shape_cache_frame := -1
## Quien toca una caja, sin barrer las 2312 Shapes del mapa en cada region.
var _grid := VoxelShapeGrid.new()
## Cajas sucias que no entraron en el presupuesto del frame anterior.
## Por donde empieza el reparto de turnos: sin rotarlo, las primeras Shapes de la lista se comen el
## cupo cada frame y las ultimas no ven una actualizacion de sombra jamas.
## Cajas de daño pendientes por nivel, sin fusionar mas alla de `MERGE_MAX_SIDE`.
var _pending_damage_regions: Array = []
var _damage_level_cursor := 1


## Rasterizar los cuatro niveles del mapa entero son ~21 s de C++ en el hilo principal. Con una
## pantalla de carga escuchando se usa `setup_progressive`, que cede un frame entre niveles para que
## algo se dibuje; sin ella `setup` sigue siendo una llamada normal y no cede nada.
func setup(voxel_world: VoxelWorld3D, camera: Camera3D) -> bool:
	# A través del `Callable` porque el analizador exige `await` ante cualquier corrutina, y sin
	# pantalla `_setup` nunca se suspende. Mismo motivo que en `TeardownMapImporter.import_map`.
	var result: Variant = _setup.call(voxel_world, camera, Callable())
	if result is bool:
		return result
	push_error("VoxelShadowClipmaps: el arranque sin pantalla de carga se suspendió")
	return false


func setup_progressive(
	voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable
) -> bool:
	return await _setup(voxel_world, camera, progress)


func _setup(voxel_world: VoxelWorld3D, camera: Camera3D, progress: Callable) -> bool:
	_world = voxel_world
	_camera = camera
	if not _measure_volume():
		return false
	total_memory_bytes = 0
	# Se rasteriza antes de crear la textura y esos bytes son los datos iniciales del
	# `texture_create`. Crearla vacia y subirla despues costaba 16,7 s de los 21 s del arranque:
	# `update_region` extrae la region sucia byte a byte en GDScript —y aqui la region sucia es el
	# volumen entero, 155 MB en el nivel 0—, la vuelve a copiar para redondear a potencia de dos, y
	# remata con un buffer de staging del mismo tamano. Todo para llegar a los mismos bytes.
	var group := _shape_group()
	if progress.is_valid():
		progress.call(0.0, "Trazando el volumen de sombras…  %d niveles" % LEVELS)
		await Engine.get_main_loop().process_frame
	# Los cuatro niveles son independientes: leen las mismas Shapes sin tocarlas y cada uno escribe
	# su propio buffer. En serie son 4,7 s del arranque; repartidos, lo que tarde el mas gordo.
	var layers: Array[PackedByteArray] = []
	layers.resize(LEVELS)
	var task := WorkerThreadPool.add_group_task(
		_rasterize_into.bind(group, layers), LEVELS, LEVELS, true, "voxel_shadow_clipmaps"
	)
	WorkerThreadPool.wait_for_group_task_completion(task)
	for level in LEVELS:
		# La copia en CPU solo hace falta para crear la textura: despues nadie la lee, y en el nivel 0
		# son 155 MB de RAM que no pintan nada. Se sueltan al salir del bucle.
		var texture := VoxelAtlas3D.new()
		if not texture.create(_packed_sizes[level], layers[level], true):
			return false
		_textures.append(texture)
		total_memory_bytes += layers[level].size()
		_pending_damage_regions.append([] as Array[AABB])
	layers.clear()
	_track_shapes()
	_world.voxels_changed.connect(_on_voxels_changed)
	set_process(true)
	return true


## Encaja el volumen sobre el mapa. Todos los niveles comparten esquina, y esa esquina se alinea al
## tamano de celda mas grueso para que la celda de cada nivel caiga exacta y no haya que redondear
## por nivel: asi el shader solo necesita un origen para los cuatro.
func _measure_volume() -> bool:
	var bounds := AABB()
	var first := true
	for shape in _all_shapes():
		var box := shape.world_bounds()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return false
	bounds = bounds.grow(VOLUME_PADDING)
	_base_cell_size = BASE_CELL_SIZE
	while true:
		var coarse := _base_cell_size * float(1 << (LEVELS - 1))
		var low := Vector3(
			floorf(bounds.position.x / coarse) * coarse,
			floorf(bounds.position.y / coarse) * coarse,
			floorf(bounds.position.z / coarse) * coarse
		)
		var high := Vector3(
			ceilf(bounds.end.x / coarse) * coarse,
			ceilf(bounds.end.y / coarse) * coarse,
			ceilf(bounds.end.z / coarse) * coarse
		)
		_origins.clear()
		_logical_sizes.clear()
		_packed_sizes.clear()
		for level in LEVELS:
			var cell := _cell_size(level)
			_origins.append(Vector3i(
				roundi(low.x / cell), roundi(low.y / cell), roundi(low.z / cell)
			))
			var logical := Vector3i(
				roundi((high.x - low.x) / cell),
				roundi((high.y - low.y) / cell),
				roundi((high.z - low.z) / cell)
			)
			_logical_sizes.append(logical)
			_packed_sizes.append(logical / 2)
		var level0 := _packed_sizes[0]
		if level0.x * level0.y * level0.z <= MAX_LEVEL0_BYTES:
			break
		# Mapa mas grande de lo previsto: se dobla la celda y se vuelve a medir, en vez de intentar
		# reservar una textura que no cabe.
		_base_cell_size *= 2.0
	return true


func get_static_rids() -> Array[RID]:
	var result: Array[RID] = []
	for texture in _textures:
		result.append(texture.get_rd_rid())
	return result


## Estatico y dinamico comparten volumen. El shader lee solo el juego "estatico"; estos bindings
## quedan apuntando a las mismas texturas para no tener que renumerar el set de uniformes entero.
## Estos cuatro slots no consumen memoria adicional. Eliminarlos exigiría renumerar los bindings
## 15-23 del shader y del efecto.
func get_dynamic_rids() -> Array[RID]:
	return get_static_rids()


func get_upload_sources() -> Array:
	var result: Array = []
	result.append_array(_textures)
	return result


## Cinco vec4, que es justo el tamano del buffer que ya existia:
##   [0] xyz = esquina del volumen en metros, w = 1 si hay sombras
##   [1..4] xyz = tamano logico del nivel en celdas, w = metros por celda
func get_shader_metadata() -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(20)
	if _origins.is_empty():
		return values
	var origin_world := Vector3(_origins[0]) * _cell_size(0)
	values[0] = origin_world.x
	values[1] = origin_world.y
	values[2] = origin_world.z
	values[3] = 1.0
	for level in LEVELS:
		values[4 + level * 4 + 0] = float(_logical_sizes[level].x)
		values[4 + level * 4 + 1] = float(_logical_sizes[level].y)
		values[4 + level * 4 + 2] = float(_logical_sizes[level].z)
		values[4 + level * 4 + 3] = _cell_size(level)
	return values


## Los cuatro niveles son texturas de la RenderingDevice: si no se sueltan a mano, Godot avisa de
## RIDs filtrados al salir.
func _exit_tree() -> void:
	for texture: VoxelAtlas3D in _textures:
		texture.release()
	_textures.clear()


func _process(_delta: float) -> void:
	# El volumen es fijo: aqui ya no se desplaza nada. Solo se atiende lo que cambia.
	last_upload_bytes = 0
	last_region_allocate_ms = 0.0
	last_region_raster_ms = 0.0
	last_region_upload_ms = 0.0
	_flush_pending_damage_level()
	_update_dynamic_shapes()


func _track_shapes() -> void:
	var tracked_shapes: Array = []
	var tracked_bounds: Array = []
	var tracked_dynamic: Array = []
	for shape: VoxelShape3D in _all_shapes():
		var body := _body_of(shape)
		var dynamic := body != null and body.state == VoxelBody3D.State.DYNAMIC
		var bounds := shape.world_bounds()
		_grid.insert(shape, bounds)
		tracked_shapes.append(shape)
		tracked_bounds.append(bounds)
		tracked_dynamic.append(dynamic)
	_update_planner.reset(tracked_shapes, tracked_bounds, tracked_dynamic)
	last_upload_bytes = total_memory_bytes


## Todas las Shapes en un solo grupo: el volumen ya no separa estatico de dinamico.
func _shape_group() -> Dictionary:
	var group := {"shapes": [], "transforms": [], "voxel_sizes": PackedFloat32Array()}
	for shape in _all_shapes():
		group.shapes.append(shape.data)
		group.transforms.append(shape.global_transform)
		group.voxel_sizes.append(shape.voxel_size)
	return group


func _rasterize_into(level: int, group: Dictionary, layers: Array) -> void:
	layers[level] = _rasterize_level(group, level)


## Rellena un nivel entero en C++. En GDScript esto era un bucle por voxel vivo y por nivel: 79,3 M
## x 4 = 317 M de iteraciones a 1,58 M/s en el mapa de Lee, o sea 201 s de arranque en negro.
func _rasterize_level(group: Dictionary, level: int) -> PackedByteArray:
	var packed := _packed_sizes[level]
	if group.shapes.is_empty():
		var empty := PackedByteArray()
		empty.resize(packed.x * packed.y * packed.z)
		return empty
	return VoxelShapeData.rasterize_occupancy_level(
		group.shapes, group.transforms, group.voxel_sizes,
		_origins[level], _logical_sizes[level], _cell_size(level), packed
	)


func _refresh_world_cell_region(level: int, logical_region: AABB) -> void:
	var logical_low := Vector3i(logical_region.position)
	var logical_size := Vector3i(logical_region.size)
	var packed_size := logical_size / 2
	if packed_size.x <= 0 or packed_size.y <= 0 or packed_size.z <= 0:
		return
	var allocation_started := Time.get_ticks_usec()
	var region := PackedByteArray()
	region.resize(packed_size.x * packed_size.y * packed_size.z)
	last_region_allocate_ms += (Time.get_ticks_usec() - allocation_started) / 1000.0
	var raster_started := Time.get_ticks_usec()
	var cell_size := _cell_size(level)
	var world_region := AABB(logical_region.position * cell_size, logical_region.size * cell_size)
	for shape in _grid.query(world_region):
		region = shape.data.rasterize_occupancy_region(
			shape.global_transform, shape.voxel_size, logical_low, logical_size,
			cell_size, packed_size, region
		)
	last_region_raster_ms += (Time.get_ticks_usec() - raster_started) / 1000.0
	var upload_started := Time.get_ticks_usec()
	# El volumen no envuelve: la region cae entera dentro de la textura, asi que es una sola copia.
	var copies: Array[Dictionary] = [{
		"destination": (logical_low - _origins[level]) / 2,
		"source": Vector3i.ZERO,
		"size": packed_size,
	}]
	_textures[level].update_compact_regions(region, packed_size, copies)
	last_upload_bytes += region.size()
	last_region_upload_ms += (Time.get_ticks_usec() - upload_started) / 1000.0


func _update_dynamic_shapes() -> void:
	var started := Time.get_ticks_usec()
	var movable := _movable_shapes()
	var plan: Dictionary = _update_planner.plan(
		movable, _movable_bounds, Engine.get_process_frames(), SHAPES_PER_FRAME,
		SHADOW_DEADBAND_SQ, _base_cell_size, SWEEP_EVERY_FRAMES, MERGE_MAX_SIDE
	)
	for update: Dictionary in plan.grid_updates:
		_grid.insert(update.shape, update.bounds)
	for key in plan.removals:
		_grid.remove_id(key)
	# Cada cosa que se mueve refresca SU caja, en los cuatro niveles. Antes se fusionaban todas en
	# una sola region para que el coste fuera O(Shapes) y no O(Shapes x niveles); con el barrido de
	# 10 ms por region eso tenia sentido, con la rejilla ya no, y la fusion a ciegas era ademas la
	# mina: dos escombros en extremos opuestos daban una caja de 250 m, y eso son 106 s de raster.
	for region in plan.dirty:
		for level in LEVELS:
			_refresh_world_aabb(level, region)
	last_dynamic_update_ms = (Time.get_ticks_usec() - started) / 1000.0


func _on_voxels_changed(
	shape: VoxelShape3D, _world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i
) -> void:
	var started := Time.get_ticks_usec()
	if not damage_updates_enabled:
		last_damage_upload_bytes = 0
		last_damage_update_ms = 0.0
		return
	var dimensions := shape.data.get_dimensions()
	var local_low := (Vector3(dirty_min) - Vector3(dimensions) * 0.5) * shape.voxel_size
	var local_high := (Vector3(dirty_max + Vector3i.ONE) - Vector3(dimensions) * 0.5) \
		* shape.voxel_size
	var changed := AABB(shape.global_transform * local_low, Vector3.ZERO)
	for corner in 8:
		var point := shape.global_transform * Vector3(
			local_high.x if corner & 1 else local_low.x,
			local_high.y if corner & 2 else local_low.y,
			local_high.z if corner & 4 else local_low.z
		)
		changed = changed.expand(point)
	# El nivel 0 sigue al crater en el acto. Los tres gruesos se acumulan y se consumen uno por
	# frame, para no meter cuatro subidas al driver en el mismo intervalo de presentacion.
	_refresh_world_aabb(0, changed.grow(_cell_size(0)))
	for level in range(1, LEVELS):
		# Fusionar a ciegas es la mina de siempre: una bomba que muerde cosas separadas 50 m daba una
		# sola caja de 50 m y rasterizarla son los picos de 120 ms. Se acumulan cajas sueltas y solo
		# se juntan las que siguen cabiendo en `MERGE_MAX_SIDE`.
		var pending: Array[AABB] = _pending_damage_regions[level]
		pending.append(changed.grow(_cell_size(level)))
		_pending_damage_regions[level] = _coalesce(pending)
	last_damage_upload_bytes = last_upload_bytes
	last_damage_update_ms = (Time.get_ticks_usec() - started) / 1000.0


func _flush_pending_damage_level() -> void:
	for _attempt in range(1, LEVELS):
		var level := _damage_level_cursor
		_damage_level_cursor += 1
		if _damage_level_cursor >= LEVELS:
			_damage_level_cursor = 1
		var pending: Array[AABB] = _pending_damage_regions[level]
		if pending.is_empty():
			continue
		# Una caja por frame y nivel. El crater ya se ve al instante en el nivel 0; los gruesos solo
		# dan la sombra lejana y pueden ir un par de frames por detras sin que se note.
		_refresh_world_aabb(level, pending.pop_back())
		break


func _refresh_world_aabb(level: int, world_region: AABB) -> void:
	var cell_size := _cell_size(level)
	var low := Vector3i(
		floori(world_region.position.x / cell_size),
		floori(world_region.position.y / cell_size),
		floori(world_region.position.z / cell_size)
	)
	var high_position := world_region.end
	var high := Vector3i(
		ceili(high_position.x / cell_size),
		ceili(high_position.y / cell_size),
		ceili(high_position.z / cell_size)
	)
	# Las subidas de bytes empaquetados empiezan y acaban en frontera de dos celdas, y ademas
	# alineadas con el origen del volumen para que el destino salga en texeles enteros.
	var origin := _origins[level]
	low = origin + Vector3i(
		floori((low.x - origin.x) / 2.0) * 2,
		floori((low.y - origin.y) / 2.0) * 2,
		floori((low.z - origin.z) / 2.0) * 2
	)
	high = origin + Vector3i(
		ceili((high.x - origin.x) / 2.0) * 2,
		ceili((high.y - origin.y) / 2.0) * 2,
		ceili((high.z - origin.z) / 2.0) * 2
	)
	low = low.max(origin)
	high = high.min(origin + _logical_sizes[level])
	if high.x <= low.x or high.y <= low.y or high.z <= low.z:
		return
	_refresh_world_cell_region(level, AABB(Vector3(low), Vector3(high - low)))


## Junta cajas solo mientras el resultado siga siendo pequeno. El limite sale de la medida: una
## region de 4 m cuesta 0,36 ms de raster y una de 16 m ya cuesta 7 ms, porque el bucle recorre los
## voxeles de origen que caen dentro. Antes se fusionaba todo sin mirar, y dos escombros en extremos
## opuestos del mapa daban una caja de 250 m — 106 s en un frame.
const MERGE_MAX_SIDE := 8.0


func _coalesce(regions: Array[AABB]) -> Array[AABB]:
	# El planificador nativo devuelve un `Array` suelto: guardarlo tal cual dejaba el hueco sin tipo
	# y el siguiente `_flush_pending_damage_level` reventaba al releerlo.
	var merged: Array[AABB] = []
	merged.assign(_update_planner.coalesce(regions, MERGE_MAX_SIDE))
	return merged


func _cell_size(level: int) -> float:
	return _base_cell_size * float(1 << level)


## Solo lo que puede haberse movido desde el frame anterior.
func _movable_shapes() -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	_movable_bounds.clear()
	if _world == null:
		return result
	var snapshot: Dictionary = _transform_tracker.collect(_world.get_transform_tracked_body_ids())
	var snapshot_shapes: Array = snapshot.shapes
	var bounds: Array = snapshot.bounds
	for index in mini(snapshot_shapes.size(), bounds.size()):
		var shape := snapshot_shapes[index] as VoxelShape3D
		if shape == null:
			continue
		result.append(shape)
		_movable_bounds[shape.get_instance_id()] = bounds[index]
	return result


## Se llama varias veces por frame desde el refresco de regiones. Dentro de un frame la lista no
## cambia, asi que se calcula una vez.
## Una Shape que nace a mitad de frame entra en el volumen al frame siguiente. El resultado es un
## frame de latencia en la sombra, no un hueco permanente.
func _all_shapes() -> Array[VoxelShape3D]:
	var frame := Engine.get_process_frames()
	if frame == _shape_cache_frame:
		return _shape_cache
	var result: Array[VoxelShape3D] = []
	for body in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		for shape in (body as VoxelBody3D).get_shapes():
			if shape.voxel_count() > 0:
				result.append(shape)
	_shape_cache = result
	_shape_cache_frame = frame
	return result


static func _body_of(shape: VoxelShape3D) -> VoxelBody3D:
	var node: Node = shape.get_parent()
	while node != null:
		if node is VoxelBody3D:
			return node
		node = node.get_parent()
	return null
