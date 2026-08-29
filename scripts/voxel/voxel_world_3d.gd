class_name VoxelWorld3D
extends Node3D
## Owns voxel Bodies, spatial queries, destruction splitting and the Jolt physics budget.

signal voxels_changed(shape: VoxelShape3D, world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i)
signal body_split(source: VoxelBody3D, created: Array[VoxelBody3D])
signal body_unregistered(body: VoxelBody3D)
signal voxel_impact(center: Vector3, removed_voxels: int, blast_radius: float)
## Evento semántico anterior al corte voxel. Los mecanismos que reaccionan a una explosión —como
## una torreta que sale despedida— no tienen que deducir la causa a partir de `voxel_impact`.
signal explosion_started(center: Vector3, radius: float, energy: float)

const GROUP := "voxel_world"

@export var physics_budget: VoxelPhysicsBudget
@export var renderer_settings: VoxelRendererSettings
@export var show_diagnostics := true
@export var impact_particles_enabled := true
@export var physics_impact_damage_enabled := true
## Auditoria de desarrollo: compara periodicamente el indice incremental contra el flood fill
## historico. Es deliberadamente opt-in porque materializa todos los indices de Shapes grandes.
@export var verify_connectivity_in_debug := false

var awake_bodies := 0
var compound_boxes := 0
## Las de los cuerpos despiertos, que son las unicas que le cuestan solver a Jolt.
var awake_compound_boxes := 0
var collision_rebuild_ms := 0.0
var retired_bodies := 0
var structural_coalesces := 0
var impact_particles := 0
var damage_native_ms := 0.0
var damage_query_ms := 0.0
var damage_notify_ms := 0.0
var damage_particles_ms := 0.0
var damage_split_ms := 0.0
var damage_connectivity_ms := 0.0
var connectivity_macros_visited := 0
var connectivity_voxels_materialized := 0
var connectivity_fallbacks := 0
var damage_external_support_ms := 0.0
var damage_component_fill_ms := 0.0
var damage_support_contacts_ms := 0.0
var damage_component_contact_calls := 0
var damage_support_routes_ms := 0.0
var damage_support_seed_ms := 0.0
var damage_fragment_ms := 0.0
var damage_detach_ms := 0.0
var damage_body_ms := 0.0
var damage_fragments := 0
var _damage_grounded_by_shape := {}
## Pares Shape->vecino cuyo contacto material atravesaba el cráter antes del daño actual. Solo esos
## enlaces se revalidan con tolerancia estricta; los contactos authored alejados conservan la
## holgura del mapa y no se rompen porque otra zona de la misma Shape recibió un impacto.
var _damage_cut_contact_pairs := {}
## Cuántos cuerpos rígidos se crean como mucho en un frame. Dos conserva respuesta inmediata y
## reparte el tercero: junto al compound de 64 cajas bajó el frame P95 de destrucción de 41,03 a
## 35,69 ms y la ventana de impacto de 45,58 a 41,27 ms en Lee.
const FRAGMENTS_PER_FRAME := 2
var _pending_fragments: Array[Dictionary] = []
var _pending_support_checks := {}
var _collision_handoffs := VoxelCollisionHandoffQueue.new()
var _next_detachment_transaction := 1
var _active_damage_epoch := 0
var _pending_structural_coalesce := {}
var _desync_recovery_queued := {}
var _connectivity_verification_counter := 0
var damage_connectivity_guard_ms := 0.0
var connectivity_skipped := 0
var damage_impulse_ms := 0.0
var damage_budget_ms := 0.0
var physics_impacts := 0
var physics_impact_damage_ms := 0.0
var last_physics_impact := {}
var motion_contact_ms := 0.0
var motion_contact_tests := 0
var motion_contact_hits := 0
var _bodies: Array[VoxelBody3D] = []
var _dynamic_bodies: Array[VoxelBody3D] = []
var _dynamic_shapes: Array[VoxelShape3D] = []
var _dynamic_grid := {}
## Shape -> isla de contacto en la que nacio, por cuerpo. Ver `_capture_weld_baseline`.
var _weld_baseline := {}
## Indice inverso de `_contact_cache`: Shape -> quienes la tienen por vecina. Ver `_invalidate_contacts`.
var _contact_users := {}
var _dynamic_grid_cells := {}
var _dynamic_grid_transforms := {}
var _collision_rebuild_queue: Array[VoxelBody3D] = []
var _collision_rebuild_queued := {}
## Colisión inicial ya mallada, pendiente de entrar a Jolt según cercanía al jugador. Se conserva por
## Shape (no por nodo físico) para poder invalidarla exactamente si esa geometría recibe daño.
var _baked_collision_queue: Array[Dictionary] = []
var _baked_collision_pending_blocks := 0
var _baked_collision_priority_elapsed := 0.0
var _burst_budget_pending := false
var _maintenance_elapsed := 0.0
var _body_cleanup_elapsed := 0.0
var _physics_impact_queue := VoxelImpactQueue.new()
var _motion_damage_scanner := VoxelMotionDamageScanner.new()
var _motion_scan_elapsed := 0.0
var _particle_pool: VoxelParticlePool
var _diagnostics: Label
var _runtime_registry := VoxelRuntimeRegistry.new()
## Bodies sin simulacion propia cuyas Shapes cambian de transformada desde otro controlador. Las
## ruedas visuales son el caso principal: su Body auxiliar permanece congelado para no entrar al
## solver, pero el renderer y la sombra deben seguirlas mientras VehicleWheel3D las anima.
var _externally_transformed_body_ids := {}
var _structural_graph := VoxelStructuralGraph.new()
var _support_planner := VoxelSupportPlanner.new()
var _damage_planner := VoxelDamagePlanner.new()

const IDLE_MAINTENANCE_INTERVAL := 0.25
const ACTIVE_MAINTENANCE_INTERVAL := 0.10
const DYNAMIC_GRID_CELL_SIZE := 8.0
const BAKED_COLLISION_PREFETCH_RADIUS := 80.0
const BAKED_COLLISION_FRAME_BUDGET_USEC := 1500
## Una pieza congelada es peor que un pequeño burst de cocción: se dedica un presupuesto temporal
## mayor únicamente a retirar los shards antiguos que bloquean handoffs activos.
const COLLISION_HANDOFF_BUDGET_USEC := 5000
const COLLISION_REBUILD_BUDGET_USEC := 1500
const BAKED_COLLISION_PRIORITY_INTERVAL := 0.5
const PHYSICS_IMPACT_MIN_ENERGY := 180.0
const PHYSICS_IMPACTS_PER_FRAME := 2
const PHYSICS_IMPACT_FRAME_BUDGET_USEC := 4000
const MAX_PENDING_PHYSICS_IMPACTS := 16
const MOTION_DAMAGE_MIN_SPEED := 3.0
const MOTION_CONTACT_MARGIN := 0.08
const MAX_MOTION_BODIES_PER_TICK := 8
const MAX_MOTION_CONTACT_TESTS_PER_TICK := 8
const MOTION_CONTACT_COOLDOWN_MSEC := 220
const MOTION_SCAN_INTERVAL := 1.0 / 30.0


## Fogonazo de boca. Vive en el mundo y no en el arma porque el pool de partículas es del mundo:
## un cañón no necesita su propio emisor ni su propia luz.
func emit_muzzle_blast(
	origin: Vector3, direction: Vector3, power := 1.0, ground_y := -INF
) -> void:
	if _particle_pool != null and impact_particles_enabled:
		_particle_pool.emit_muzzle_blast(origin, direction, power, ground_y)


## Bola de fuego. Va aparte de `damage_sphere` a propósito: el corte de voxel es la parte física
## de una explosión y esta es la óptica. Una carga que revienta en el aire, sin nada que romper,
## tiene que verse igual.
func emit_explosion(center: Vector3, radius: float) -> void:
	if _particle_pool != null and impact_particles_enabled:
		_particle_pool.emit_explosion(center, radius)


func _ready() -> void:
	add_to_group(GROUP)
	ensure_physics_budget()
	if renderer_settings == null:
		renderer_settings = VoxelRendererSettings.new()
	_particle_pool = VoxelParticlePool.new()
	_particle_pool.name = "VoxelParticlePool"
	add_child(_particle_pool)
	if show_diagnostics:
		_create_diagnostics()
	for child in get_children():
		if child is VoxelBody3D:
			register_body(child)


## Los importadores y tests pueden llenar el mundo en el mismo tick en que lo añaden al árbol,
## antes de que Godot entregue `_ready`. Mantener la inicialización perezosa aquí evita que ese
## camino use una configuración distinta o intente leer un Resource nulo.
func ensure_physics_budget() -> VoxelPhysicsBudget:
	if physics_budget == null:
		physics_budget = VoxelPhysicsBudget.new()
	return physics_budget


## `make_dynamic()` reemplaza un StaticBody y sus shards con un RigidBody. Los nodos viejos salen al
## final del frame; hasta entonces el cuerpo nuevo chocaría contra su propia colisión. Esta ruta
## cubre transiciones completas (torres/postes), complementando el ticket de los detach parciales.
func queue_transition_collision_handoff(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body) or not body.collision_handoff_pending:
		return
	if _collision_handoffs.contains_fragment(body):
		return
	_collision_handoffs.enqueue({
		"transaction": _next_detachment_transaction,
		"fragment": body,
		"source_body": null,
		"source_shape": null,
		"source_revision": 0,
		"absorbed": [],
		"impulse_center": Vector3.ZERO,
		"impulse_energy": 0.0,
		"impulse_radius": 0.0,
		"ready_frame": -1,
	})
	_next_detachment_transaction += 1


func create_body_from_asset(source: String, body_transform := Transform3D.IDENTITY) -> VoxelBody3D:
	var asset := VoxelAssetImporter.load_asset(source) if source.ends_with(".vox") \
		else VoxelAssetImporter.load_legacy_blueprint(source)
	if asset.is_empty():
		return null
	var body := VoxelBody3D.new()
	body.name = source.get_file().get_basename().capitalize()
	body.transform = body_transform
	add_child(body)
	for entry: Dictionary in asset.shapes:
		body.add_voxel_shape(VoxelShape3D.from_asset(entry, asset.palette))
	register_body(body)
	return body


func register_body(body: VoxelBody3D) -> void:
	if _bodies.has(body):
		return
	if not body.has_meta("structural_family"):
		body.set_meta("structural_family", body.get_instance_id())
	_bodies.append(body)
	if body.state == VoxelBody3D.State.DYNAMIC:
		_dynamic_bodies.append(body)
	body.body_state_changed.connect(_on_body_state_changed)
	body.runtime_state_changed.connect(_on_runtime_state_changed)
	for shape in body.get_shapes():
		register_shape(shape)
	_capture_weld_baseline(body)
	_bind_runtime_sleep_signal(body)
	_sync_runtime_body(body)


## Que Shapes de un mismo cuerpo se tocaban ANTES de que nadie las tocase. Dos que nunca se tocaron
## estan soldadas por quien hizo el mapa, no por su geometria, asi que ninguna destruccion puede
## romper esa union: solo se separa lo que la destruccion ha separado de verdad.
func _capture_weld_baseline(body: VoxelBody3D) -> void:
	var shapes := body.get_shapes()
	if body.state != VoxelBody3D.State.DYNAMIC or shapes.size() < 2:
		return
	var groups := _contact_groups(shapes, {})
	for index in groups.size():
		for shape: VoxelShape3D in groups[index]:
			_weld_baseline[shape.get_instance_id()] = index


func register_shape(shape: VoxelShape3D) -> void:
	if shape.structural_lineage == 0:
		shape.structural_lineage = shape.get_instance_id()
	shape.sync_revision_baseline()
	var body := _body_of(shape)
	if body != null and body.state == VoxelBody3D.State.DYNAMIC:
		_register_dynamic_shape(shape)
	else:
		_index_static_shape(shape)
	if not shape.voxels_changed.is_connected(_on_shape_changed.bind(shape)):
		shape.voxels_changed.connect(_on_shape_changed.bind(shape))
	if body != null:
		# Algunos importadores registran el Body antes de añadir todas sus Shapes (ruedas visuales del
		# vehículo, por ejemplo). Actualizar también su total evita clasificarlo como vacío más tarde.
		_sync_runtime_body(body)


func unregister_body(body: VoxelBody3D) -> void:
	if body == null:
		return
	untrack_external_body_transforms(body)
	# Las ruedas authored viven en un Body visual sin colisión para no contaminar el compound de la
	# carrocería. Su vida pertenece al vehículo: si la carrocería queda vacía por destrucción, no
	# pueden permanecer cuatro ruedas fantasma en el renderer ni en la lista dinámica.
	var vehicle_visual := body.get_meta("teardown_vehicle_visual_body") as VoxelBody3D \
		if body.has_meta("teardown_vehicle_visual_body") else null
	if vehicle_visual != null:
		body.remove_meta("teardown_vehicle_visual_body")
		if _bodies.has(vehicle_visual):
			unregister_body(vehicle_visual)
		vehicle_visual.queue_free()
	# Última barrera de ownership. Los consumidores sueltan aquí cualquier referencia que no haya
	# sido transferida por `body_split`; el Body todavía está vivo mientras corren los callbacks.
	body_unregistered.emit(body)
	_bodies.erase(body)
	_dynamic_bodies.erase(body)
	_collision_rebuild_queued.erase(body.get_instance_id())
	_collision_rebuild_queue.erase(body)
	if body.body_state_changed.is_connected(_on_body_state_changed):
		body.body_state_changed.disconnect(_on_body_state_changed)
	if body.runtime_state_changed.is_connected(_on_runtime_state_changed):
		body.runtime_state_changed.disconnect(_on_runtime_state_changed)
	for shape in body.get_shapes():
		_cancel_baked_collision(shape)
		_unregister_shape_spatial(shape)
		_runtime_registry.remove_shape(shape.get_instance_id())
		_weld_baseline.erase(shape.get_instance_id())
		_desync_recovery_queued.erase(shape.get_instance_id())
	for index in range(_pending_fragments.size() - 1, -1, -1):
		var pending: Dictionary = _pending_fragments[index]
		if pending.get("source_body") != body:
			continue
		var pending_shape_variant: Variant = pending.get("shape")
		var new_owner: VoxelBody3D = _body_of(pending_shape_variant as VoxelShape3D) \
			if is_instance_valid(pending_shape_variant) else null
		if new_owner != null and new_owner != body:
			pending.source_body = new_owner
		else:
			_pending_fragments.remove_at(index)
	_collision_handoffs.remove_body(body)
	_runtime_registry.remove_body(body.get_instance_id())
	_apply_runtime_metrics()


## Colision estatica bajo demanda. El mapa entero cuesta 15,5 s y el 95 % es geometria donde el
## jugador no esta: se construye un radio alrededor del punto de entrada antes de soltarlo y el
## resto se va levantando por cercania, con presupuesto por frame, mientras juega.
## Los cuerpos que la clipmap tiene que vigilar cada frame. El resto son estaticos y no se mueven.
func get_dynamic_bodies() -> Array[VoxelBody3D]:
	return _dynamic_bodies


## Vista incremental para consumidores por frame. Evita que agua, clipmaps y rejilla recorran todos
## los props dormidos solo para descartarlos inmediatamente.
func get_awake_dynamic_bodies() -> Array[VoxelBody3D]:
	var result: Array[VoxelBody3D] = []
	for body_id: int in _runtime_registry.get_awake_body_ids():
		var body := instance_from_id(body_id) as VoxelBody3D
		if body != null and is_instance_valid(body) and body.state == VoxelBody3D.State.DYNAMIC:
			result.append(body)
	return result


## IDs directos para consumidores nativos por frame. Evita reconstruir Arrays de Nodes en
## GDScript antes de que el tracker vuelva a recorrerlos.
func get_awake_dynamic_body_ids() -> PackedInt64Array:
	return _runtime_registry.get_awake_body_ids()


## Fuente de transformadas para consumidores visuales. Se mantiene separada de
## `get_awake_dynamic_body_ids`: un Body visual sin colision no debe inflar los presupuestos Jolt ni
## el contador de cuerpos despiertos solo para que el renderer pueda seguirlo.
func get_transform_tracked_body_ids() -> PackedInt64Array:
	var result := get_awake_dynamic_body_ids()
	for body_id: int in _externally_transformed_body_ids:
		result.append(body_id)
	return result


func track_external_body_transforms(body: VoxelBody3D) -> void:
	if body != null and is_instance_valid(body):
		_externally_transformed_body_ids[body.get_instance_id()] = true


func untrack_external_body_transforms(body: VoxelBody3D) -> void:
	if body != null:
		_externally_transformed_body_ids.erase(body.get_instance_id())


func is_body_externally_transform_tracked(body_id: int) -> bool:
	return _externally_transformed_body_ids.has(body_id)


func queue_collision_rebuild(body: VoxelBody3D) -> void:
	var key := body.get_instance_id()
	if _collision_rebuild_queued.has(key):
		return
	_collision_rebuild_queued[key] = true
	_collision_rebuild_queue.append(body)


func prioritize_collision_rebuild(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body) or not body.has_pending_collision_rebuild():
		return
	var key := body.get_instance_id()
	_collision_rebuild_queue.erase(body)
	_collision_rebuild_queue.push_front(body)
	_collision_rebuild_queued[key] = true


func queue_baked_static_collision(
	body: VoxelBody3D, shape: VoxelShape3D, records: Array
) -> void:
	if body == null or shape == null \
			or body.state == VoxelBody3D.State.DYNAMIC or not body.collision_enabled:
		return
	# Una Shape puede ser visualmente densa pero no producir caras fisicas (material atravesable en
	# una paleta compartida). Un caché válido con cero bloques es un resultado terminado, no una
	# colisión atrasada: dejar su revisión en cero producía `coherence DESYNC` desde el arranque.
	if records.is_empty():
		body.acknowledge_static_collision_revision(shape)
		_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
		_sync_runtime_shape(shape, body)
		return
	_baked_collision_queue.append({
		"body": body,
		"shape": shape,
		"records": records,
		"cursor": 0,
		"distance_squared": INF,
	})
	_baked_collision_pending_blocks += records.size()
	_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), true)
	_sync_runtime_shape(shape, body)


## Instala sincrónicamente solo la zona en la que el jugador puede aterrizar al aparecer. Devuelve
## métricas para separar este coste imprescindible del resto del mapa, que queda en streaming.
func prime_baked_static_collision(center: Vector3, radius: float) -> Dictionary:
	var started := Time.get_ticks_usec()
	var installed := 0
	for index in range(_baked_collision_queue.size() - 1, -1, -1):
		var entry: Dictionary = _baked_collision_queue[index]
		var shape := entry.shape as VoxelShape3D
		var body := entry.body as VoxelBody3D
		if not is_instance_valid(shape) or not is_instance_valid(body):
			if is_instance_valid(shape):
				_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
			_baked_collision_pending_blocks -= (entry.records as Array).size() - int(entry.cursor)
			_baked_collision_queue.remove_at(index)
			continue
		var bounds := shape.world_bounds()
		var closest := center.clamp(bounds.position, bounds.end)
		if closest.distance_squared_to(center) > radius * radius:
			continue
		var remaining: Array = (entry.records as Array).slice(int(entry.cursor))
		body.import_baked_static_collision(shape, remaining)
		body.acknowledge_static_collision_revision(shape)
		installed += remaining.size()
		_baked_collision_pending_blocks -= remaining.size()
		_baked_collision_queue.remove_at(index)
		_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
		_sync_runtime_body(body)
	_prioritize_baked_collision(center)
	return {
		"blocks": installed,
		"pending_blocks": _baked_collision_pending_blocks,
		"ms": (Time.get_ticks_usec() - started) / 1000.0,
	}


## Completes the immutable part of the broad phase while the map is still loading. Otherwise the
## first shot has to sort every static Shape before it can even discover what was hit.
func finalize_spatial_index() -> void:
	# La indexación toca `_static_grid`: se queda en el hilo principal. El
	# índice de conectividad, en cambio, solo escribe dentro de su propia VoxelShapeData, así que se
	# reparte entre los núcleos. Era el 41 % de la carga del mapa medido en serie (8,5 s de 20,6 s).
	var pending := {}
	for body in _bodies:
		if not is_instance_valid(body) or body.state == VoxelBody3D.State.DYNAMIC:
			continue
		for shape in body.get_shapes():
			_index_static_shape(shape)
			if shape.data != null:
				# Dos Shapes podrían compartir el mismo recurso: una sola tarea por instancia.
				pending[shape.data.get_instance_id()] = shape.data
	if pending.is_empty():
		return
	# Se prepara fuera del frame de juego. Las Shapes pequeñas siguen construyéndolo bajo demanda;
	# las grandes evitan que el primer corte pague el escaneo de todas sus macroceldas.
	var shapes := pending.values()
	var group := WorkerThreadPool.add_group_task(
		func(index: int) -> void: shapes[index].prepare_connectivity_index(),
		shapes.size(), -1, true, "voxel_connectivity_index"
	)
	# Se espera aquí: un impacto no puede llegar mientras un worker reconstruye el índice.
	WorkerThreadPool.wait_for_group_task_completion(group)


## La rejilla de Shapes estaticas, que es la que consulta la busqueda de cimiento. No se usa el arbol
## AABB para eso: la destruccion lo marca sucio y la primera consulta posterior lo reconstruye
## entero, 2312 Shapes ordenadas — medido, 56 ms por disparo. Una Shape estatica no se mueve, asi que
## en la rejilla solo hay que meterla una vez y sacarla cuando pasa a dinamica o muere.
func _index_static_shape(shape: VoxelShape3D) -> void:
	if not is_instance_valid(shape) or not shape.is_inside_tree() or shape.data == null:
		return
	_static_grid.insert(shape, shape.world_bounds())
	# El conteo lineal se paga una sola vez al registrar/importar la Shape, nunca en el frame del
	# primer disparo. Después el corte nativo descuenta exactamente las raíces que elimina.
	shape.foundation_voxel_count(FOUNDATION_HARDNESS)


## Applies material-aware damage and returns one record per affected Shape.
func damage_sphere(
	center: Vector3, radius: float, energy: float, options: Dictionary = {}
) -> Array[Dictionary]:
	if String(options.get("cause", "impact")) == "explosion":
		explosion_started.emit(center, radius, energy)
	# Varias cargas pueden detonarse en el mismo frame. Comparten epoch para que las piezas authored
	# que todavía se tocan terminen en un solo Body; daños de frames distintos nunca se sueldan.
	_active_damage_epoch = Engine.get_process_frames()
	_pending_structural_coalesce[_active_damage_epoch] = true
	var affected: Array[Dictionary] = []
	var total_removed := 0
	impact_particles = 0
	damage_native_ms = 0.0
	damage_query_ms = 0.0
	damage_notify_ms = 0.0
	damage_particles_ms = 0.0
	damage_split_ms = 0.0
	damage_connectivity_ms = 0.0
	connectivity_macros_visited = 0
	connectivity_voxels_materialized = 0
	connectivity_fallbacks = 0
	damage_external_support_ms = 0.0
	damage_component_fill_ms = 0.0
	damage_support_contacts_ms = 0.0
	damage_component_contact_calls = 0
	damage_support_routes_ms = 0.0
	damage_support_seed_ms = 0.0
	damage_fragment_ms = 0.0
	damage_detach_ms = 0.0
	damage_body_ms = 0.0
	damage_fragments = 0
	_damage_grounded_by_shape.clear()
	_damage_cut_contact_pairs.clear()
	damage_connectivity_guard_ms = 0.0
	connectivity_skipped = 0
	damage_impulse_ms = 0.0
	damage_budget_ms = 0.0
	# El corte y la reevaluación estructural usan la región exacta del cráter. La banda exterior solo
	# sirve para el impulso; no debe provocar flood-fills de edificios que no cambiaron.
	var query_started := Time.get_ticks_usec()
	var damage_shapes := _query_shapes(center, radius)
	# La rejilla dinámica se refresca a 10 Hz. Un objeto rápido puede impactar ya fuera de su celda
	# anterior; los dos Bodies entregados por el solver se añaden explícitamente para no perderlo.
	for extra_variant: Variant in options.get("extra_bodies", []):
		var extra := extra_variant as VoxelBody3D
		if extra == null or not is_instance_valid(extra):
			continue
		for extra_shape in extra.get_shapes():
			if not damage_shapes.has(extra_shape):
				damage_shapes.append(extra_shape)
	# Algunos impactos tienen un dueño material inequívoco. El frontal de un coche debe abrir la
	# pared blanda que tiene delante, no horadar su propia carrocería con la misma esfera. El filtro
	# se aplica después de incorporar los Bodies del solver para no depender de la rejilla a 10 Hz.
	var only_body_ids := {}
	for only_variant: Variant in options.get("only_bodies", []):
		var only_body := only_variant as VoxelBody3D
		if only_body != null and is_instance_valid(only_body):
			only_body_ids[only_body.get_instance_id()] = true
	if not only_body_ids.is_empty():
		var filtered_shapes: Array[VoxelShape3D] = []
		for candidate in damage_shapes:
			var candidate_body := _body_of(candidate)
			if candidate_body != null and only_body_ids.has(candidate_body.get_instance_id()):
				filtered_shapes.append(candidate)
		damage_shapes = filtered_shapes
	var apply_radial_impulse := bool(options.get("apply_impulse", true))
	var nearby_shapes: Array[VoxelShape3D] = []
	if apply_radial_impulse:
		nearby_shapes = _query_shapes(center, radius * 3.0)
	damage_query_ms = (Time.get_ticks_usec() - query_started) / 1000.0
	var support_seed_map := {}
	var finalized_impulse_bodies := {}
	var seed_started := Time.get_ticks_usec()
	# El cambio invalida la cache al emitir `voxels_changed`. Se guardan antes los dos extremos de
	# cada enlace que puede desaparecer para que una viga fuera del radio también se reevalúe.
	for candidate in damage_shapes:
		var candidate_body := _body_of(candidate)
		if candidate_body == null or candidate_body.state != VoxelBody3D.State.STATIC \
				or candidate.anchored:
			continue
		for old_neighbour in _local_static_contacts(candidate, center, radius):
			support_seed_map[old_neighbour.get_instance_id()] = old_neighbour
			_damage_cut_contact_pairs[_contact_pair_key(candidate, old_neighbour)] = true
	damage_support_seed_ms = (Time.get_ticks_usec() - seed_started) / 1000.0
	for shape in damage_shapes:
		var body := _body_of(shape)
		if body == null:
			continue
		var was_static := body.state == VoxelBody3D.State.STATIC
		if body.state == VoxelBody3D.State.RETIRED_STATIC:
			body.reactivate(_box_allowance_for_new_body())
		var damage: Dictionary = shape.damage_sphere(
			center, radius, energy, FOUNDATION_HARDNESS
		)
		damage_native_ms += shape.last_damage_native_ms
		damage_notify_ms += shape.last_damage_notify_ms
		if int(damage.get("removed", 0)) <= 0:
			continue
		body.set_meta("damage_epoch", _active_damage_epoch)
		support_seed_map[shape.get_instance_id()] = shape
		total_removed += int(damage.removed)
		var particle_started := Time.get_ticks_usec()
		if impact_particles_enabled and bool(options.get("particles", true)):
			impact_particles += _particle_pool.emit_damage(
				shape, damage, center, energy, radius, String(options.get("cause", "impact"))
			)
		damage_particles_ms += (Time.get_ticks_usec() - particle_started) / 1000.0
		var split_started := Time.get_ticks_usec()
		var created: Array[VoxelBody3D] = []
		# Perder material de raíz exige reclasificar aunque quede una sola isla; contener roca en otra
		# zona no. Forzar el flood-fill en cada cráter superficial del terreno costaba 107 ms.
		var should_classify := bool(damage.get("should_classify", false))
		damage_connectivity_guard_ms += float(damage.get("guard_usec", 0)) / 1000.0
		if should_classify:
			created = _split_disconnected(body, shape, center, radius)
			# `_split_disconnected` ya decidió todas las componentes afectadas de esta Shape y sus
			# rutas externas. Volver a pasar la Shape fuente por `_drop_unsupported` repetía un BFS
			# voxel-a-voxel inmediatamente después (hasta 4,6 ms medidos). Se conservan las semillas
			# vecinas capturadas antes del daño: ellas son las que pueden haber perdido este apoyo.
			support_seed_map.erase(shape.get_instance_id())
		else:
			connectivity_skipped += 1
		damage_split_ms += (Time.get_ticks_usec() - split_started) / 1000.0
		# Y si el cuerpo era un `<body dynamic>` de varias Shapes, puede haber quedado partido en dos
		# islas soldadas al mismo cuerpo rigido. Eso es lo que dejaba tramos de tuberia flotando en
		# formacion con un hueco en medio.
		var loose := _split_loose_shapes(body)
		if not loose.is_empty():
			created.append_array(loose)
			damage_fragments += loose.size()
		created = _finalize_detached_bodies(
			body, shape, created, was_static, center, radius, finalized_impulse_bodies
		)
		affected.append({"shape": shape, "damage": damage, "new_bodies": created})
		# Una Shape dinámica puede vaciarse por completo en un segundo impacto. Su compound anterior
		# seguía vivo hasta el rebuild diferido (y, si era la única Shape, el Body nunca desaparecía):
		# en Lee observamos un fantasma de 0 voxeles, 56 cajas y 7 t. La fuente estática espera al
		# handoff; una fuente ya dinámica no protege ninguna colisión vieja y se limpia aquí.
		if not was_static and is_instance_valid(shape) and shape.voxel_count() == 0:
			_cleanup_empty_source(shape)
	var support_seeds: Array[VoxelShape3D] = []
	for support_seed: Variant in support_seed_map.values():
		if is_instance_valid(support_seed):
			support_seeds.append(support_seed as VoxelShape3D)
	if _pending_fragments.is_empty():
		_drop_unsupported(support_seeds)
	else:
		# Una continuación que toca el cuarto fragmento todavía parece una cadena estática sin raíz.
		# Soltarla aquí la convierte en otro RigidBody antes de que el fragmento diferido pueda reclamarla.
		for support_shape in support_seeds:
			_pending_support_checks[support_shape.get_instance_id()] = {
				"shape": support_shape, "epoch": _active_damage_epoch,
			}
	var impulse_started := Time.get_ticks_usec()
	var impulse_bodies := {}
	# El radio de impulso es mayor que el de corte, pero sigue siendo local. Recorrer todos los
	# Bodies importados y leer el centro de masa de cada RigidBody costaba ~200 ms por disparo.
	for shape in nearby_shapes:
		var impulse_body := _body_of(shape)
		if impulse_body != null and impulse_body.state == VoxelBody3D.State.DYNAMIC:
			impulse_bodies[impulse_body] = true
	for body: VoxelBody3D in impulse_bodies:
		if finalized_impulse_bodies.has(body.get_instance_id()):
			continue
		# `apply_explosion_impulse` despierta únicamente si el centro de masa recibe impulso. Antes se
		# despertaba primero por mero solape de AABB: un cable/poste largo a nueve metros podía entrar
		# al solver aunque su centro estuviera fuera de la onda, multiplicando Bodies durante el
		# colapso. Si la Shape fue dañada, su señal ya despertó el Body; si era estática, el finalizador
		# creó y despertó el fragmento. No se pierde ninguna transición estructural.
		# El empuje sale del tamaño de la onda, no de `energy`: desde que `energy` es penetración
		# frente a la dureza vive en torno a 1, y usarla aquí dejaba los escombros quietos.
		body.apply_explosion_impulse(center, radius * 5.0, radius * 3.0)
	damage_impulse_ms = (Time.get_ticks_usec() - impulse_started) / 1000.0
	var budget_started := Time.get_ticks_usec()
	# New bodies are allowed to exist inside the documented 192-Body burst window. Enforcing and
	# recounting the complete dynamic list inside every shot cost ~3 ms; the existing 10 Hz budget
	# tick performs the same work outside the destruction call.
	_burst_budget_pending = true
	damage_budget_ms = (Time.get_ticks_usec() - budget_started) / 1000.0
	if total_removed > 0 and bool(options.get("emit_impact_signal", true)):
		voxel_impact.emit(center, total_removed, radius)
	return affected


## Cola un choque físico sin mutar Shapes durante `_integrate_forces`. Dos RigidBodies informan el
## mismo contacto desde lados opuestos; la clave canónica los fusiona y conserva el impulso mayor.
func queue_physics_impact(
	source: VoxelBody3D, collider: Object, point: Vector3,
	impulse: float, relative_speed: float
) -> void:
	if not physics_impact_damage_enabled:
		return
	if source == null or not is_instance_valid(source) or source.state != VoxelBody3D.State.DYNAMIC:
		return
	var target := _voxel_body_from_collision_object(collider)
	if target == source:
		return
	# El suelo base, un StaticBody no voxel y los raycasts de las ruedas no son objetivos de daño.
	# Descartarlos aquí evita incluso construir la clave/cola en cada bache de la carretera.
	if source.get_physics_body() is VoxelVehicle3D and target == null:
		return
	_physics_impact_queue.enqueue(
		source, target, collider, point, impulse, relative_speed, MAX_PENDING_PHYSICS_IMPACTS
	)


static func _voxel_body_from_collision_object(collider: Object) -> VoxelBody3D:
	var node := collider as Node
	while node != null:
		if node is VoxelBody3D:
			return node as VoxelBody3D
		node = node.get_parent()
	return null


func _process_physics_impacts() -> void:
	var processed := 0
	var frame_damage_ms := 0.0
	while processed < PHYSICS_IMPACTS_PER_FRAME and not _physics_impact_queue.is_empty():
		var record: Dictionary = _physics_impact_queue.pop_front()
		# Un impacto puede esperar varios frames; mientras tanto la destrucción puede retirar el Body.
		# Castear directamente el Variant que apunta al Node liberado falla antes de poder comprobar null.
		var source_variant: Variant = record.source
		if not is_instance_valid(source_variant):
			continue
		var source := source_variant as VoxelBody3D
		if source == null:
			continue
		var target_variant: Variant = record.target
		var target := target_variant as VoxelBody3D if is_instance_valid(target_variant) else null
		var profile_source := source.vehicle_impact_owner \
			if source.vehicle_impact_owner != null \
				and is_instance_valid(source.vehicle_impact_owner) else source
		var profile := physics_impact_profile(
			profile_source, float(record.impulse), float(record.speed)
		)
		if not bool(profile.valid):
			continue
		var impact_energy := float(profile.energy)
		var radius := float(profile.radius)
		var penetration := float(profile.penetration)
		var vehicle_impact := bool(profile.vehicle)
		# Mismo criterio que `queue_physics_impact`: un vehículo solo daña al cuerpo que embistió. Si
		# la destrucción liberó ese cuerpo mientras el impacto esperaba turno, ya no queda nada que
		# romper y la esfera sin `only_bodies` mordería el propio casco del que embiste.
		if vehicle_impact and target == null:
			continue
		var extra_bodies: Array[VoxelBody3D] = [source]
		if target != null and is_instance_valid(target):
			extra_bodies.append(target)
		last_physics_impact = {
			"point": record.point, "impulse": record.impulse, "speed": record.speed,
			"energy": impact_energy, "radius": radius, "penetration": penetration,
			"kind": "vehicle" if vehicle_impact else "body",
			"strength": float(profile.strength),
		}
		# Cuenta el intento antes del daño: material indestructible también consumió una consulta y no
		# puede abrir la compuerta para vaciar los 16 eventos de la cola en un solo frame.
		processed += 1
		var started := Time.get_ticks_usec()
		var damage_options := {
			"apply_impulse": false,
			"emit_impact_signal": false,
			"particles": true,
			"extra_bodies": extra_bodies,
			"cause": "vehicle_impact" if vehicle_impact else "physics_impact",
		}
		if vehicle_impact and target != null and is_instance_valid(target):
			damage_options["only_bodies"] = [target]
		var affected := damage_sphere(record.point, radius, penetration, damage_options)
		frame_damage_ms += (Time.get_ticks_usec() - started) / 1000.0
		physics_impact_damage_ms = frame_damage_ms
		if not affected.is_empty():
			physics_impacts += 1
		if frame_damage_ms * 1000.0 >= PHYSICS_IMPACT_FRAME_BUDGET_USEC:
			break


## Perfil material del choque. Para cuerpos ordinarios conserva la curva existente y el daño
## bidireccional. Un vehículo necesita despejar aproximadamente el ancho de su frontal en madera a
## velocidad urbana: la masa aporta energía y `strength` del XML gradúa el radio, mientras que la
## dureza del material todavía reduce el alcance dentro de `damage_sphere_material`.
static func physics_impact_profile(
	source: VoxelBody3D, impulse: float, normal_speed: float
) -> Dictionary:
	var impulse_energy := 0.5 * maxf(0.0, impulse) * maxf(0.0, normal_speed)
	var vehicle := source.get_physics_body() as VoxelVehicle3D \
		if source != null and is_instance_valid(source) else null
	if vehicle != null:
		var kinetic_energy := 0.5 * maxf(vehicle.mass, 1.0) * normal_speed * normal_speed
		var effective_energy := maxf(impulse_energy, kinetic_energy * 0.10)
		if effective_energy < PHYSICS_IMPACT_MIN_ENERGY:
			return {"valid": false}
		var strength := vehicle.impact_strength
		var automatic_radius := clampf(
			0.55 + normal_speed * 0.10 + strength * 0.035, 0.75, 1.45
		)
		return {
			"valid": true,
			"vehicle": true,
			"energy": effective_energy,
			"strength": strength,
			"radius": clampf(vehicle.impact_radius, 0.75, 3.2) \
				if vehicle.impact_radius > 0.0 else automatic_radius,
			"penetration": clampf(
				0.95 + normal_speed * 0.035 + strength * 0.07, 1.05, 2.35
			),
		}
	if impulse_energy < PHYSICS_IMPACT_MIN_ENERGY:
		return {"valid": false}
	return {
		"valid": true,
		"vehicle": false,
		"energy": impulse_energy,
		"strength": 0.0,
		"radius": clampf(0.10 + sqrt(impulse_energy) * 0.0065, 0.16, 1.25),
		"penetration": clampf(
			0.55 + log(maxf(impulse_energy, PHYSICS_IMPACT_MIN_ENERGY) / 250.0) * 0.28,
			0.45, 2.3
		),
	}


## Follaje y decorado `unphysical` no generan caras Jolt para que el jugador pueda atravesarlos.
## Esta pasada exacta y acotada conserva la interacción destructiva: una torre veloz consulta solo
## Shapes estáticas cuyo AABB toca y confirma contacto voxel en C++ antes de generar el impacto.
func _physics_process(delta: float) -> void:
	if not physics_impact_damage_enabled:
		return
	_motion_scan_elapsed += delta
	if _motion_scan_elapsed < MOTION_SCAN_INTERVAL:
		return
	_motion_scan_elapsed = 0.0
	var started := Time.get_ticks_usec()
	var scan: Dictionary = _motion_damage_scanner.scan(
		self, _static_grid, get_awake_dynamic_bodies(), Time.get_ticks_msec(),
		MOTION_DAMAGE_MIN_SPEED, MOTION_CONTACT_MARGIN, MAX_MOTION_BODIES_PER_TICK,
		MAX_MOTION_CONTACT_TESTS_PER_TICK, MOTION_CONTACT_COOLDOWN_MSEC
	)
	motion_contact_ms = (Time.get_ticks_usec() - started) / 1000.0
	motion_contact_tests = int(scan.tests)
	motion_contact_hits += int(scan.hits)


func get_metrics() -> Dictionary:
	return {
		"awake_bodies": awake_bodies,
		"compound_boxes": compound_boxes,
		"awake_compound_boxes": awake_compound_boxes,
		"collision_rebuild_ms": collision_rebuild_ms,
		"retired_bodies": retired_bodies,
		"structural_coalesces": structural_coalesces,
		"impact_particles": impact_particles,
		"active_particles": _particle_pool.get_active_count() if _particle_pool != null else 0,
		"damage_native_ms": damage_native_ms,
		"damage_query_ms": damage_query_ms,
		"damage_notify_ms": damage_notify_ms,
		"damage_particles_ms": damage_particles_ms,
		"damage_split_ms": damage_split_ms,
		"damage_connectivity_ms": damage_connectivity_ms,
		"connectivity_macros_visited": connectivity_macros_visited,
		"connectivity_voxels_materialized": connectivity_voxels_materialized,
		"connectivity_fallbacks": connectivity_fallbacks,
		"damage_external_support_ms": damage_external_support_ms,
		"damage_component_fill_ms": damage_component_fill_ms,
		"damage_support_contacts_ms": damage_support_contacts_ms,
		"damage_component_contact_calls": damage_component_contact_calls,
		"damage_support_routes_ms": damage_support_routes_ms,
		"damage_support_seed_ms": damage_support_seed_ms,
		"support_search_ms": support_search_ms,
		"support_touch_ms": support_touch_ms,
		"support_grid_ms": support_grid_ms,
		"support_touch_calls": support_touch_calls,
		"support_nodes": support_nodes,
		"support_candidates": support_candidates,
		"damage_fragment_ms": damage_fragment_ms,
		"damage_connectivity_guard_ms": damage_connectivity_guard_ms,
		"connectivity_skipped": connectivity_skipped,
		"damage_impulse_ms": damage_impulse_ms,
		"damage_budget_ms": damage_budget_ms,
		"physics_impacts": physics_impacts,
		"physics_impact_damage_ms": physics_impact_damage_ms,
		"pending_physics_impacts": _physics_impact_queue.size(),
		"last_physics_impact": last_physics_impact,
		"motion_contact_ms": motion_contact_ms,
		"motion_contact_tests": motion_contact_tests,
		"motion_contact_hits": motion_contact_hits,
		"pending_collision_rebuilds": _collision_rebuild_queue.size(),
		"pending_collision_blocks": _pending_collision_block_count(),
		"pending_collision_handoffs": _collision_handoffs.size(),
		"pending_fragments": _pending_fragments.size(),
		"pending_baked_collision_shapes": _baked_collision_queue.size(),
		"pending_baked_collision_blocks": _baked_collision_pending_blocks,
		"dynamic_shapes": _dynamic_shapes.size(),
	}


## Lo que ya no llega al suelo tiene que caer, y ese es literalmente el modelo de Teardown: no hay
## analisis de tensiones — "if you knock down all the walls of a house but there's one voxel still
## standing, it will stay up" —, solo se pregunta si el trozo sigue conectado al cimiento, y esa
## conexion es INDIRECTA: su `IsBodyJointedToStatic` la define como "either by being static itself or
## by being directly or indirectly jointed to something static".
##
## Aqui el cimiento es la roca. El suelo de Teardown es `rock`, dureza 1e6, que no se rompe con nada,
## asi que una Shape con roca viva dentro es ancla por definicion. Todo lo demas necesita una cadena
## de contactos reales hasta una de ellas.
##
## Sin esto nada del mapa caia nunca: toda Shape importada entra con `anchored = false`, y una Shape
## no anclada que sigue siendo una sola isla conectada sale de `_split_disconnected` sin mirar nada.
## Una seccion de tuberia, una reja y una torre son cada una UNA isla.
##
## No hay regla de tamano. La habia -"lo mas grande de 30 m es terreno"- y era lo que dejaba tu torre
## clavada en el aire: la envolvente de una Shape girada se hincha, y en Lee 34 Shapes pasaban de 30 m
## de caja sin ser terreno, con AABB cubicas de 44 y 51 m de lado. Medido. El terreno no necesita esa
## regla porque ya es roca: 516 Shapes del mapa la cumplen por material.
const FOUNDATION_HARDNESS := 1000.0
## Holgura de autor entre Shapes distintas. Lee coloca algunas piezas que forman un único objeto
## (por ejemplo el mástil y la cabeza de la torre eléctrica) con hasta 12 cm entre sus rejillas.
## Reducir este margen global separa el objeto antes de tiempo y deja su handoff esperando dos
## cuerpos que deberían caer como uno.
const CONTACT_MARGIN := 0.12
## Un componente recién clasificado dentro de una Shape ya no tiene holgura de autor: sus voxeles
## vienen de la misma rejilla exacta. Usar aquí los 12 cm globales puentea una celda recién borrada y
## hace que una reja siga "tocando" el pilar después de volar su unión.
const COMPONENT_CONTACT_MARGIN := 0.09

var _static_grid := VoxelShapeGrid.new()
## Shape id -> cantidad exacta de voxeles de raíz todavía vivos.
## Contactos ya calculados, por id de Shape. Entre dos Shapes estaticas el contacto no cambia si no
## se rompe una de las dos, y en una partida se dispara muchas veces en la misma esquina.
var _contact_cache := {}
var _support_searches := 0
var support_search_ms := 0.0
var support_touch_calls := 0
var support_dropped := 0
var support_touch_ms := 0.0
var support_grid_ms := 0.0
var support_nodes := 0
var support_candidates := 0
var support_foundation_tests := 0
var support_foundation_ms := 0.0


## `true` si la Shape todavía contiene material de cimiento vivo. El tamaño, la AABB y el contacto
## de colisión no convierten una pieza en raíz.
func _is_foundation(shape: VoxelShape3D) -> bool:
	var started := Time.get_ticks_usec()
	support_foundation_tests += 1
	var result := shape.foundation_voxel_count(FOUNDATION_HARDNESS)
	support_foundation_ms += (Time.get_ticks_usec() - started) / 1000.0
	return result > 0


## Las Shapes estaticas cuyos voxeles vivos tocan de verdad a los de esta. Solapar cajas
## envolventes no vale como contacto: las AABB de un barrio entero se solapan entre si y todo
## saldria conectado con todo. La caja solo genera candidatos; `touches` decide.
## Parte un cuerpo dinamico cuyas Shapes han dejado de tocarse.
##
## Un `<body dynamic="true">` de Teardown puede traer varias Shapes en un unico cuerpo rigido: los
## tramos de tuberia de Lee vienen de cuatro en cuatro. Si un disparo se lleva una entera, las que
## quedan siguen soldadas y se quedan flotando en formacion, con el hueco en medio y nadie que las
## suelte. `_split_disconnected` no lo ve porque solo mira dentro de una Shape.
##
## Solo corre sobre el cuerpo que acaba de recibir daño y sobre sus propias Shapes, que son unas
## pocas, asi que no aparece en el perfil.
func _split_loose_shapes(body: VoxelBody3D) -> Array[VoxelBody3D]:
	# Un joint NO es motivo para no partir. `is_physics_persistent()` cuenta las retenciones de
	# constraint, y en Lee 20 de los 40 cuerpos dinamicos multi-Shape tienen una: eran exactamente los
	# que se quedaban con medio poste flotando, soldado por el RigidBody a la mitad que el joint
	# sujeta. Lo que si hay que respetar es un vehiculo -sus Shapes son un chasis- y un handoff a
	# medias, que todavia no tiene colision con la que decidir nada.
	if body.state != VoxelBody3D.State.DYNAMIC or body.physics_persistent \
			or body.collision_handoff_pending or body.get_physics_body() is VoxelVehicle3D:
		return []
	var shapes: Array[VoxelShape3D] = []
	for shape in body.get_shapes():
		if shape.data != null and shape.voxel_count() > 0:
			shapes.append(shape)
	if shapes.size() < 2:
		return []
	var groups := _contact_groups(shapes, _weld_baseline)
	if groups.size() < 2:
		return []
	var created: Array[VoxelBody3D] = []
	# El primer grupo se queda con el cuerpo original; los demas estrenan el suyo.
	for index in range(1, groups.size()):
		var piece := VoxelBody3D.new()
		piece.name = "%s_suelto%d" % [body.name, index]
		piece.state = VoxelBody3D.State.DYNAMIC
		piece.structural = body.structural
		piece.collision_enabled = body.collision_enabled
		piece.set_meta("structural_family", body.get_meta(
			"structural_family", body.get_instance_id()
		))
		add_child(piece)
		for shape: VoxelShape3D in groups[index]:
			_unregister_shape_spatial(shape)
			body.release_voxel_shape(shape)
			piece.add_voxel_shape(shape, true, false)
		piece.rebuild_dynamic_collision(_box_allowance_for_new_body())
		register_body(piece)
		piece.wake_for_interaction()
		created.append(piece)
	body.rebuild_dynamic_collision(_box_allowance_for_new_body())
	body.wake_for_interaction()
	return created


## Agrupa las Shapes de un mismo cuerpo por contacto real entre voxeles, mas las soldaduras de autor
## que no puede romper nadie. `weld` vacio da el agrupamiento crudo, que es el que fija la linea base.
func _contact_groups(shapes: Array[VoxelShape3D], weld: Dictionary) -> Array:
	var edges := PackedInt32Array()
	for first in shapes.size():
		for second in range(first + 1, shapes.size()):
			if _linked(shapes[first], shapes[second], weld):
				edges.append(first)
				edges.append(second)
	var groups: Array = []
	for native_group: PackedInt32Array in _structural_graph.connected_groups(shapes.size(), edges):
		var group: Array[VoxelShape3D] = []
		for shape_index in native_group:
			group.append(shapes[shape_index])
		groups.append(group)
	return groups


func _linked(a: VoxelShape3D, b: VoxelShape3D, weld: Dictionary) -> bool:
	if a == b:
		return false
	var key_a := a.get_instance_id()
	var key_b := b.get_instance_id()
	# Islas distintas al nacer: nunca se tocaron, asi que no hay geometria que destruir entre ellas.
	if weld.has(key_a) and weld.has(key_b) and int(weld[key_a]) != int(weld[key_b]):
		return true
	return _shapes_touch(a, b)


func _shapes_touch(a: VoxelShape3D, b: VoxelShape3D) -> bool:
	return _shapes_touch_with_margin(a, b, CONTACT_MARGIN)


func _shapes_touch_with_margin(a: VoxelShape3D, b: VoxelShape3D, margin: float) -> bool:
	if a == b or a.data == null or b.data == null:
		return false
	if not a.world_bounds().grow(margin).intersects(b.world_bounds()):
		return false
	# `touches` recorre las celdas del volumen sobre el que se llama: se llama sobre el menor.
	var self_smaller := a.voxel_count() <= b.voxel_count()
	var from := a if self_smaller else b
	var to := b if self_smaller else a
	# `touches` espera other -> self, o sea la transformada que lleva un punto del OTRO volumen al
	# propio. Construirla al reves cuela mientras las dos Shapes estan cerca del origen y se nota a lo
	# bestia lejos: medido en Lee, una torre de 24 m a 70 m del centro no "tocaba" el suelo que tenia
	# justo debajo ni con dos metros de margen, y con la transformada buena toca a 12 cm.
	var relative := from.global_transform.affine_inverse() * to.global_transform
	return from.data.touches(
		to.data, relative, from.voxel_size, to.voxel_size, margin, 0
	)


## Une únicamente piezas estructurales nacidas/despertadas por el mismo batch de daño y que todavía
## conservan contacto voxel. Esto no es un merge por colisión: Bodies de frames distintos o dos
## fragmentos del mismo volumen separados por el cráter nunca se sueldan.
func _coalesce_ready_structural_bodies() -> void:
	for epoch_variant: Variant in _pending_structural_coalesce.keys():
		var epoch := int(epoch_variant)
		var fragments_pending := false
		for pending_fragment: Dictionary in _pending_fragments:
			if int(pending_fragment.get("damage_epoch", -1)) == epoch:
				fragments_pending = true
				break
		if fragments_pending:
			continue
		var candidates: Array[VoxelBody3D] = []
		for body in _dynamic_bodies:
			if not is_instance_valid(body) or body.state != VoxelBody3D.State.DYNAMIC \
					or not body.structural or int(body.get_meta("damage_epoch", -1)) != epoch \
					or body.get_total_voxels() == 0:
				continue
			candidates.append(body)
		# Se agrupa antes de liberar los handoffs. Todos los compounds ya existen y el host se vuelve a
		# cocinar una vez al absorber; esperar a que cada Body reciba su impulso los separa físicamente
		# durante el mismo frame y hace imposible reconocer después que eran una sola torre.
		var unassigned := candidates.duplicate()
		while not unassigned.is_empty():
			var group: Array[VoxelBody3D] = [unassigned.pop_back()]
			var cursor := 0
			while cursor < group.size():
				var current := group[cursor]
				cursor += 1
				for index in range(unassigned.size() - 1, -1, -1):
					if not _structural_bodies_touch(current, unassigned[index]):
						continue
					group.append(unassigned[index])
					unassigned.remove_at(index)
			if group.size() < 2:
				continue
			var host := group[0]
			for candidate in group:
				if candidate.get_total_voxels() > host.get_total_voxels():
					host = candidate
			_absorb_bodies_into(host, group)
			host.set_meta("damage_epoch", epoch)
			host.continuous_collision = true
			host.rebuild_dynamic_collision(_box_allowance_for_new_body())
			host.wake_for_interaction()
			structural_coalesces += group.size() - 1
		_pending_structural_coalesce.erase(epoch)


func _structural_bodies_touch(a: VoxelBody3D, b: VoxelBody3D) -> bool:
	if a == b:
		return false
	# Solo se reagrupa una familia que ya compartió Body antes de este corte. Dos edificios o dos
	# cascotes que simplemente chocaron durante la misma explosión nunca se sueldan.
	var family_a := int(a.get_meta("structural_family", -1))
	if family_a < 0 or family_a != int(b.get_meta("structural_family", -2)):
		return false
	for shape_a in a.get_shapes():
		if shape_a.voxel_count() == 0:
			continue
		for shape_b in b.get_shapes():
			if shape_b.voxel_count() == 0:
				continue
			# Mismo linaje = partes del mismo volumen cortado: tolerancia numérica solamente. Linajes
			# distintos = piezas authored cuya colocación admite CONTACT_MARGIN.
			var same_lineage := shape_a.structural_lineage != 0 \
				and shape_a.structural_lineage == shape_b.structural_lineage
			var margin := 0.005 if same_lineage else CONTACT_MARGIN
			if _shapes_touch_with_margin(shape_a, shape_b, margin):
				return true
	return false


func _static_contacts(shape: VoxelShape3D) -> Array[VoxelShape3D]:
	var cache_key := shape.get_instance_id()
	if _contact_cache.has(cache_key):
		var cache_entry := _contact_cache[cache_key] as Dictionary
		if _contact_cache_entry_valid(shape, cache_entry):
			var cached: Array[VoxelShape3D] = []
			for cached_shape: VoxelShape3D in cache_entry.get("contacts", []):
				cached.append(cached_shape)
			return cached
		_invalidate_contacts(shape)
	var result: Array[VoxelShape3D] = []
	support_nodes += 1
	var bounds := shape.world_bounds()
	var grown := bounds.grow(CONTACT_MARGIN)
	var grid_started := Time.get_ticks_usec()
	var candidates := _static_grid.query(grown)
	support_grid_ms += (Time.get_ticks_usec() - grid_started) / 1000.0
	support_candidates += candidates.size()
	for candidate in candidates:
		if candidate == shape or candidate.data == null:
			continue
		var body := _body_of(candidate)
		if body == null or body.state != VoxelBody3D.State.STATIC:
			continue
		# Se recorre el volumen mas pequeno de los dos: `touches` itera las celdas de aquel sobre el
		# que se llama.
		var self_smaller := shape.voxel_count() <= candidate.voxel_count()
		var from := shape if self_smaller else candidate
		var to := candidate if self_smaller else shape
		# other -> self, igual que en `_shapes_touch`: al reves el contacto falla a distancia.
		var relative := from.global_transform.affine_inverse() * to.global_transform
		var contact_margin := COMPONENT_CONTACT_MARGIN \
			if _damage_cut_contact_pairs.has(_contact_pair_key(shape, candidate)) \
			else CONTACT_MARGIN
		support_touch_calls += 1
		var touch_started := Time.get_ticks_usec()
		var hit: bool = from.data.touches(
			to.data, relative, from.voxel_size, to.voxel_size, contact_margin, 0
		)
		support_touch_ms += (Time.get_ticks_usec() - touch_started) / 1000.0
		if hit:
			result.append(candidate)
	var contact_revisions := {}
	for neighbour in result:
		var neighbour_body := _body_of(neighbour)
		contact_revisions[neighbour.get_instance_id()] = {
			"revision": neighbour.content_revision(),
			"generation": neighbour_body.physics_generation if neighbour_body != null else 0,
			"pose": neighbour.global_transform,
		}
	var source_body := _body_of(shape)
	_contact_cache[cache_key] = {
		"source_revision": shape.content_revision(),
		"source_generation": source_body.physics_generation if source_body != null else 0,
		"source_pose": shape.global_transform,
		"contacts": result,
		"contact_revisions": contact_revisions,
	}
	# Indice inverso: quien tiene a cada vecino en SU lista. Un contacto es de dos, pero la cache es
	# por Shape y `_reaches_foundation` corta en cuanto descubre cimiento, asi que el vecino puede
	# quedarse sin entrada propia para siempre.
	for neighbour in result:
		var neighbour_key := neighbour.get_instance_id()
		var users: Dictionary = _contact_users.get(neighbour_key, {})
		users[cache_key] = true
		_contact_users[neighbour_key] = users
	return result


func _contact_cache_entry_valid(shape: VoxelShape3D, entry: Dictionary) -> bool:
	var source_body := _body_of(shape)
	if source_body == null or source_body.state != VoxelBody3D.State.STATIC \
			or int(entry.get("source_revision", -1)) != shape.content_revision() \
			or int(entry.get("source_generation", -1)) != source_body.physics_generation \
			or not (entry.get("source_pose", Transform3D.IDENTITY) as Transform3D) \
				.is_equal_approx(shape.global_transform):
		return false
	var revisions := entry.get("contact_revisions", {}) as Dictionary
	for neighbour_variant: Variant in entry.get("contacts", []):
		if not is_instance_valid(neighbour_variant):
			return false
		var neighbour := neighbour_variant as VoxelShape3D
		var neighbour_body := _body_of(neighbour)
		var recorded := revisions.get(neighbour.get_instance_id(), {}) as Dictionary
		if neighbour.voxel_count() <= 0 or neighbour_body == null \
				or neighbour_body.state != VoxelBody3D.State.STATIC \
				or int(recorded.get("revision", -1)) != neighbour.content_revision() \
				or int(recorded.get("generation", -1)) != neighbour_body.physics_generation \
				or not (recorded.get("pose", Transform3D.IDENTITY) as Transform3D) \
					.is_equal_approx(neighbour.global_transform):
			return false
	return true


## Contactos materiales que atraviesan únicamente la región que va a cambiar. Sirve para guardar
## los dos extremos de aristas que el cráter puede borrar sin recorrer todos los contactos de una
## Shape de terreno de cientos de metros.
func _local_static_contacts(
	shape: VoxelShape3D, world_center: Vector3, radius: float
) -> Array[VoxelShape3D]:
	var center := shape.world_to_voxel(world_center)
	var reach := ceili((radius + CONTACT_MARGIN) / shape.voxel_size) + 1
	var low := Vector3i(floori(center.x), floori(center.y), floori(center.z)) \
		- Vector3i.ONE * reach
	var high := Vector3i(ceili(center.x), ceili(center.y), ceili(center.z)) \
		+ Vector3i.ONE * (reach + 1)
	var local_indices: PackedInt32Array = shape.data.get_live_indices_region(low, high)
	if local_indices.is_empty():
		return []
	var result: Array[VoxelShape3D] = []
	var world_reach := radius + CONTACT_MARGIN + shape.voxel_size
	var region := AABB(
		world_center - Vector3.ONE * world_reach, Vector3.ONE * world_reach * 2.0
	)
	for neighbour in _static_grid.query(region):
		if neighbour == shape or neighbour.data == null:
			continue
		var body := _body_of(neighbour)
		if body == null or body.state != VoxelBody3D.State.STATIC:
			continue
		var relative := shape.global_transform.affine_inverse() * neighbour.global_transform
		if shape.data.component_touches(
			local_indices, neighbour.data, relative, shape.voxel_size,
			neighbour.voxel_size, CONTACT_MARGIN
		):
			result.append(neighbour)
	return result


## Busca cimiento desde `shape` saltando de contacto en contacto. Devuelve las Shapes visitadas y si
## alguna llega al suelo; asi una sola busqueda resuelve toda la cadena a la vez.
func _reaches_foundation(
	shape: VoxelShape3D, excluded: VoxelShape3D = null
) -> Dictionary:
	var excluded_id := excluded.get_instance_id() if excluded != null else 0
	return _support_planner.route(
		_structural_graph,
		shape.get_instance_id(), excluded_id,
		_native_is_foundation_id, _native_static_contact_ids, _native_touches_foundation_directly
	)


func _native_is_foundation_id(shape_id: int) -> bool:
	var shape_variant := instance_from_id(shape_id)
	return is_instance_valid(shape_variant) and _is_foundation(shape_variant as VoxelShape3D)


func _native_static_contact_ids(shape_id: int) -> PackedInt64Array:
	var result := PackedInt64Array()
	var shape_variant := instance_from_id(shape_id)
	if not is_instance_valid(shape_variant):
		return result
	for neighbour in _static_contacts(shape_variant as VoxelShape3D):
		result.append(neighbour.get_instance_id())
	return result


func _native_body_for_shape_id(shape_id: int) -> VoxelBody3D:
	var shape_variant := instance_from_id(shape_id)
	return _body_of(shape_variant as VoxelShape3D) if is_instance_valid(shape_variant) else null


func _native_touches_foundation_directly(shape_id: int, excluded_id: int) -> bool:
	if _contact_cache.has(shape_id):
		return false
	var shape_variant := instance_from_id(shape_id)
	if not is_instance_valid(shape_variant):
		return false
	var excluded_variant := instance_from_id(excluded_id) if excluded_id != 0 else null
	var excluded := excluded_variant as VoxelShape3D if is_instance_valid(excluded_variant) else null
	return _touches_foundation_directly(shape_variant as VoxelShape3D, excluded)


func _touches_foundation_directly(shape: VoxelShape3D, excluded: VoxelShape3D) -> bool:
	var started := Time.get_ticks_usec()
	var candidates := _static_grid.query(shape.world_bounds().grow(CONTACT_MARGIN))
	for candidate in candidates:
		if candidate == shape or candidate == excluded or candidate.data == null \
				or not _is_foundation(candidate):
			continue
		var body := _body_of(candidate)
		var contact_margin := COMPONENT_CONTACT_MARGIN \
			if _damage_cut_contact_pairs.has(_contact_pair_key(shape, candidate)) \
			else CONTACT_MARGIN
		if body != null and body.state == VoxelBody3D.State.STATIC \
				and _shapes_touch_with_margin(shape, candidate, contact_margin):
			damage_support_contacts_ms += (Time.get_ticks_usec() - started) / 1000.0
			return true
	damage_support_contacts_ms += (Time.get_ticks_usec() - started) / 1000.0
	return false


func _component_reaches_external_foundation(
	shape: VoxelShape3D, component: Dictionary, grounded_by_shape: Dictionary
) -> bool:
	var dimensions := shape.data.get_dimensions()
	var minimum := Vector3(component.get("minimum", Vector3i.ZERO)) - Vector3(dimensions) * 0.5
	var maximum := Vector3(component.get("maximum", Vector3i.ZERO) + Vector3i.ONE) \
		- Vector3(dimensions) * 0.5
	var component_bounds := shape.global_transform * AABB(
		minimum * shape.voxel_size, (maximum - minimum) * shape.voxel_size
	)
	var contacts_usec := 0
	var grid_started := Time.get_ticks_usec()
	var candidates := _static_grid.query(component_bounds.grow(CONTACT_MARGIN))
	contacts_usec += Time.get_ticks_usec() - grid_started
	for neighbour in candidates:
		if neighbour == shape or neighbour.data == null:
			continue
		var neighbour_body := _body_of(neighbour)
		if neighbour_body == null or neighbour_body.state != VoxelBody3D.State.STATIC:
			continue
		var relative := shape.global_transform.affine_inverse() * neighbour.global_transform
		var touch_started := Time.get_ticks_usec()
		damage_component_contact_calls += 1
		var existing_indices: PackedInt32Array = component.get("indices", PackedInt32Array())
		var seed_index := int(component.get("seed_index", -1))
		# Si el enlace atravesaba justo la zona borrada, no puede sobrevivir gracias a la holgura de
		# importación. Los enlaces alejados son authored y conservan los 12 cm originales.
		var contact_margin := COMPONENT_CONTACT_MARGIN \
			if _damage_cut_contact_pairs.has(_contact_pair_key(shape, neighbour)) \
			else CONTACT_MARGIN
		var touches: bool
		if existing_indices.is_empty() and seed_index >= 0:
			touches = shape.data.component_seed_touches(
				seed_index, neighbour.data, relative, shape.voxel_size,
				neighbour.voxel_size, contact_margin
			)
		else:
			_ensure_component_indices(shape, component)
			touches = shape.data.component_touches(
				component.indices, neighbour.data, relative, shape.voxel_size,
				neighbour.voxel_size, contact_margin
			)
		contacts_usec += Time.get_ticks_usec() - touch_started
		if not touches:
			continue
		# Aunque el vecino tampoco llegue a fundación, esta componente es su soporte físico. No puede
		# degradarse a chips por ser pequeña: primero debe nacer como Body y absorber la continuación
		# (poste de 8 voxeles sosteniendo una cabeza authored de 50).
		component["external_contact"] = true
		var neighbour_key := neighbour.get_instance_id()
		var route_cache_key := "%d:%d" % [shape.get_instance_id(), neighbour_key]
		var grounded: bool
		if grounded_by_shape.has(route_cache_key):
			grounded = bool(grounded_by_shape[route_cache_key])
		else:
			var route_started := Time.get_ticks_usec()
			var search := _reaches_foundation(neighbour, shape)
			damage_support_routes_ms += (Time.get_ticks_usec() - route_started) / 1000.0
			grounded = bool(search.grounded)
			# Los contactos de varios vecinos suelen converger en la misma isla. Memorizar toda la
			# visita evita repetir el mismo BFS exacto por cada punto de contacto del edificio.
			for visited_key in (search.visited as Dictionary):
				if int(visited_key) != shape.get_instance_id():
					grounded_by_shape["%d:%d" % [shape.get_instance_id(), int(visited_key)]] = grounded
			grounded_by_shape[route_cache_key] = grounded
		if grounded:
			damage_support_contacts_ms += contacts_usec / 1000.0
			return true
	damage_support_contacts_ms += contacts_usec / 1000.0
	return false


static func _contact_pair_key(a: VoxelShape3D, b: VoxelShape3D) -> String:
	return "%d:%d" % [a.get_instance_id(), b.get_instance_id()]


func _drop_unsupported(shapes: Array[VoxelShape3D]) -> Array[VoxelBody3D]:
	var dropped: Array[VoxelBody3D] = []
	_support_searches = 0
	support_touch_calls = 0
	support_foundation_tests = 0
	support_foundation_ms = 0.0
	support_touch_ms = 0.0
	support_grid_ms = 0.0
	support_nodes = 0
	support_candidates = 0
	var support_started := Time.get_ticks_usec()
	var plan: Dictionary = _support_planner.plan_drop_chains(
		shapes, _structural_graph, _native_body_for_shape_id, _native_is_foundation_id,
		_native_static_contact_ids, _native_touches_foundation_directly
	)
	_support_searches = int(plan.searches)
	# Toda isla suelta cae como un solo cuerpo; el commit de Nodes/Jolt permanece aquí y se ejecuta
	# una vez por cadena ya planificada en C++.
	for chain_variant: Variant in plan.chains:
		var chain: Array[VoxelBody3D] = []
		for body_variant: Variant in chain_variant as Array:
			var body := body_variant as VoxelBody3D
			if body != null:
				chain.append(body)
		var merged := _merge_dropped_chain(chain)
		if merged != null:
			dropped.append(merged)
	support_search_ms = (Time.get_ticks_usec() - support_started) / 1000.0
	support_dropped = dropped.size()
	return dropped




## Suelta una cadena de Shapes estaticas como un solo cuerpo dinamico. El mas grande hace de
## anfitrion y el compound se reconstruye UNA vez al final. El antiguo corte en 12 convertía una
## tubería larga de 40 tramos en 40 RigidBody3D precisamente durante el peor frame del colapso.


func _merge_dropped_chain(chain: Array[VoxelBody3D]) -> VoxelBody3D:
	if chain.is_empty():
		return null
	var host := chain[0]
	for body in chain:
		if body.get_total_voxels() > host.get_total_voxels():
			host = body
	# El host todavía no está completo. Cocinar su compound aquí y repetirlo después de absorber las
	# demás Shapes duplicaba el pico precisamente en el frame del colapso.
	host.make_dynamic(_box_allowance_for_new_body(), false)
	host.set_meta("damage_epoch", _active_damage_epoch)
	_absorb_bodies_into(host, chain)
	host.rebuild_dynamic_collision(_box_allowance_for_new_body())
	host.wake_for_interaction()
	return host


## Transfiere cuerpos authored al mismo componente rígido sin reconstruir la colisión en cada
## Shape. También es el camino que conserva joints y cables al cambiar de dueño.
func _absorb_bodies_into(host: VoxelBody3D, bodies: Array[VoxelBody3D]) -> void:
	for body in bodies:
		if body == host:
			continue
		for shape in body.get_shapes():
			_unregister_shape_spatial(shape)
			body.release_voxel_shape(shape)
			if host.state == VoxelBody3D.State.DYNAMIC:
				shape.calibrate_for_dynamic_structure()
			host.add_voxel_shape(shape, true, false)
			register_shape(shape)
		# Lo que colgaba del cuerpo absorbido -joints, cables- tiene que enterarse de quien es ahora
		# su dueño. Es la misma orden de "transferir" que ya usa el corte de un cuerpo.
		body_split.emit(body, [host] as Array[VoxelBody3D])
		unregister_body(body)
		body.queue_free()


## Completa una separación a través de contactos intactos alejados del cráter. Solo se llama cuando
## ya nació un componente dinámico, así que el barrido completo se paga una vez por desprendimiento,
## no por impacto superficial.
func _absorb_static_continuations(
	created: Array[VoxelBody3D], source_body: VoxelBody3D
) -> Array[VoxelBody3D]:
	var claimed := {}
	var all_absorbed: Array[VoxelBody3D] = []
	for host in created:
		if not is_instance_valid(host) or host.state != VoxelBody3D.State.DYNAMIC:
			continue
		var seeds: Array[VoxelShape3D] = []
		for moving_shape in host.get_shapes():
			for neighbour in _static_contacts(moving_shape):
				# El flood-fill interno ya decidió que el remanente del Body fuente está separado. El
				# margen tolerante entre Shapes no puede volver a soldar a través del voxel recién borrado.
				if _body_of(neighbour) == source_body:
					continue
				if not claimed.has(neighbour.get_instance_id()):
					seeds.append(neighbour)
		var absorbed: Array[VoxelBody3D] = []
		for continuation_seed in seeds:
			if not is_instance_valid(continuation_seed) \
					or claimed.has(continuation_seed.get_instance_id()):
				continue
			var search := _reaches_foundation(continuation_seed)
			var visited := search.visited as Dictionary
			for key in visited:
				claimed[key] = true
			if bool(search.grounded):
				continue
			for key in visited:
				var continuation := visited[key] as VoxelShape3D
				var continuation_body := _body_of(continuation)
				if continuation_body != null \
						and continuation_body.state == VoxelBody3D.State.STATIC \
						and not absorbed.has(continuation_body):
					absorbed.append(continuation_body)
		if absorbed.is_empty():
			continue
		for absorbed_body in absorbed:
			if not all_absorbed.has(absorbed_body):
				all_absorbed.append(absorbed_body)
		_absorb_bodies_into(host, absorbed)
		host.rebuild_dynamic_collision(_box_allowance_for_new_body())
		host.wake_for_interaction()
	return all_absorbed


## Único commit de un desprendimiento. Tanto la ruta inmediata como la cola diferida llegan aquí
## con el contexto original; así ninguna continuación estática, señal o impulso depende del número
## de fragmentos que cupieron en el frame del disparo.
func _finalize_detached_bodies(
	source_body: VoxelBody3D, source_shape: VoxelShape3D,
	created: Array[VoxelBody3D], source_was_static: bool,
	impulse_center: Vector3, blast_radius: float, impulse_registry := {}, transaction := -1
) -> Array[VoxelBody3D]:
	var live: Array[VoxelBody3D] = []
	for fragment in created:
		if is_instance_valid(fragment) and fragment.state == VoxelBody3D.State.DYNAMIC:
			live.append(fragment)
	if live.is_empty():
		return live
	var transaction_id := int(transaction)
	if transaction_id < 0:
		transaction_id = _next_detachment_transaction
		_next_detachment_transaction += 1

	for fragment in live:
		if not fragment.has_meta("damage_epoch"):
			fragment.set_meta("damage_epoch", _active_damage_epoch)
		if source_was_static:
			fragment.begin_collision_handoff()
	var absorbed: Array[VoxelBody3D] = []
	if source_was_static and is_instance_valid(source_body):
		absorbed = _absorb_static_continuations(live, source_body)

	if is_instance_valid(source_body):
		body_split.emit(source_body, live)
	for fragment in live:
		impulse_registry[fragment.get_instance_id()] = true
		if source_was_static and fragment.collision_handoff_pending:
			_collision_handoffs.enqueue({
				"transaction": transaction_id,
				"fragment": fragment,
				"source_body": source_body,
				"source_shape": source_shape,
				"source_revision": source_shape.content_revision() \
					if is_instance_valid(source_shape) else 0,
				"absorbed": absorbed.duplicate(),
				"impulse_center": impulse_center,
				"impulse_energy": blast_radius * 5.0,
				"impulse_radius": blast_radius * 3.0,
				"ready_frame": -1,
			})
		else:
			fragment.wake_for_interaction()
			fragment.apply_explosion_impulse(
				impulse_center, blast_radius * 5.0, blast_radius * 3.0
			)
	if source_was_static and is_instance_valid(source_body):
		prioritize_collision_rebuild(source_body)
	return live

## Corta una componente de su Shape y la convierte en cuerpo rigido. Es lo caro de la destruccion:
## el corte va en C++ pero crear el nodo, el compound de cajas y el cuerpo de Jolt son ~2,6 ms por
## trozo, y eso no se optimiza, se reparte.
func _spawn_fragment(shape: VoxelShape3D, indices: PackedInt32Array,
		retained_anchors: PackedInt32Array, count: int, damage_epoch := -1) -> VoxelBody3D:
	if not is_instance_valid(shape) or shape.data == null:
		return null
	var source_owner := _body_of(shape)
	var structural_family: Variant = source_owner.get_meta(
		"structural_family", source_owner.get_instance_id()
	) if source_owner != null else shape.structural_lineage
	var detach_started := Time.get_ticks_usec()
	var detached := shape.detach_component_preserving(indices, retained_anchors)
	damage_detach_ms += (Time.get_ticks_usec() - detach_started) / 1000.0
	if detached == null:
		return null
	damage_fragments += 1
	var body_started := Time.get_ticks_usec()
	var fragment := VoxelBody3D.new()
	fragment.name = "VoxelFragment_%d" % Time.get_ticks_usec()
	# The detached Shape is dynamic from birth. Building a full static concave collision and
	# replacing it with a box compound one line later doubled split cost on large fragments.
	fragment.state = VoxelBody3D.State.DYNAMIC
	fragment.structural = count >= physics_budget.structural_voxel_threshold
	fragment.continuous_collision = true
	fragment.set_meta("structural_family", structural_family)
	fragment.set_meta("damage_epoch", _active_damage_epoch if damage_epoch < 0 else damage_epoch)
	detached.calibrate_for_dynamic_structure()
	add_child(fragment)
	fragment.add_voxel_shape(detached, true)
	damage_body_ms += (Time.get_ticks_usec() - body_started) / 1000.0
	fragment.last_interaction_msec = Time.get_ticks_msec()
	register_body(fragment)
	return fragment


## Los trozos que no cupieron en el frame de su disparo. Los indices pueden haber quedado obsoletos
## si esa Shape ha recibido mas dano entretanto: `detach_component_preserving` ignora las celdas que
## ya son aire, asi que el trozo sale mas pequeno o no sale, y nunca sale mal.
func _flush_pending_fragments() -> void:
	var made := 0
	while made < FRAGMENTS_PER_FRAME and not _pending_fragments.is_empty():
		var entry: Dictionary = _pending_fragments.pop_front()
		var shape := entry.shape as VoxelShape3D
		if not is_instance_valid(shape):
			continue
		made += 1
		var fragment := _spawn_fragment(
			shape, entry.indices, entry.retained, int(entry.count),
			int(entry.get("damage_epoch", _active_damage_epoch))
		)
		if fragment != null:
			var source_variant: Variant = entry.get("source_body")
			var source_body: VoxelBody3D = source_variant as VoxelBody3D \
				if is_instance_valid(source_variant) else _body_of(shape)
			_finalize_detached_bodies(
				source_body, shape, [fragment] as Array[VoxelBody3D],
				bool(entry.get("source_was_static", false)),
				entry.get("impulse_center", Vector3.ZERO) as Vector3,
				float(entry.get("blast_radius", 0.0)), {},
				int(entry.get("transaction", -1))
			)
		if shape.voxel_count() == 0:
			_unregister_shape_spatial(shape)


func _split_disconnected(
	_body: VoxelBody3D, shape: VoxelShape3D, impulse_center: Vector3, blast_radius: float
) -> Array[VoxelBody3D]:
	var connectivity_started := Time.get_ticks_usec()
	var root_started := Time.get_ticks_usec()
	var use_material_foundation := not shape.anchored and _is_foundation(shape)
	damage_external_support_ms += (Time.get_ticks_usec() - root_started) / 1000.0
	var fill_started := Time.get_ticks_usec()
	var components: Array = shape.classified_components_by_hardness(FOUNDATION_HARDNESS) \
		if use_material_foundation else shape.classified_components()
	_connectivity_verification_counter += 1
	if verify_connectivity_in_debug and _connectivity_verification_counter % 16 == 1:
		var reference_anchors := shape.data.get_indices_hardness_at_least(
			shape.palette.get_hardnesses(), FOUNDATION_HARDNESS
		) if use_material_foundation else (
			shape.anchor_indices if shape.anchored else PackedInt32Array()
		)
		var reference := shape.data.find_components_6_with_anchors_reference(reference_anchors)
		if _component_signatures(components) != _component_signatures(reference):
			push_error(
				"DESYNC connectivity: el indice incremental difiere del flood fill en Shape #%d; "
				+ "se usa el resultado de referencia" % shape.get_instance_id()
			)
			components = reference
			connectivity_fallbacks += 1
	var connectivity_metrics := shape.data.get_connectivity_metrics()
	connectivity_macros_visited += int(connectivity_metrics.get("macros_visited", 0))
	connectivity_voxels_materialized += int(
		connectivity_metrics.get("voxels_materialized", 0)
	)
	connectivity_fallbacks += int(connectivity_metrics.get("fallbacks", 0))
	damage_component_fill_ms += (Time.get_ticks_usec() - fill_started) / 1000.0
	if components.size() == 1 and not _has_structural_support(components[0]):
		var external_started := Time.get_ticks_usec()
		if _component_reaches_external_foundation(
			shape, components[0] as Dictionary, _damage_grounded_by_shape
		):
			(components[0] as Dictionary)["anchored"] = true
		damage_external_support_ms += (
			Time.get_ticks_usec() - external_started
		) / 1000.0
	elif components.size() > 1:
		var grounded_by_shape := _damage_grounded_by_shape
		for component: Dictionary in components:
			if _has_structural_support(component):
				continue
			var external_started := Time.get_ticks_usec()
			if _component_reaches_external_foundation(shape, component, grounded_by_shape):
				component["anchored"] = true
			damage_external_support_ms += (
				Time.get_ticks_usec() - external_started
			) / 1000.0
	damage_connectivity_ms += (Time.get_ticks_usec() - connectivity_started) / 1000.0
	var fragment_started := Time.get_ticks_usec()
	if components.is_empty():
		_unregister_shape_spatial(shape)
		damage_fragment_ms += (Time.get_ticks_usec() - fragment_started) / 1000.0
		return []
	# A building can remain one connected island after its last foundation voxel is removed.
	# Connectivity alone is therefore not enough to early-out: an anchored Shape whose sole
	# component no longer reaches a live anchor must detach in its entirety.
	if components.size() == 1:
		var only_component: Dictionary = components[0]
		if _has_structural_support(only_component):
			damage_fragment_ms += (Time.get_ticks_usec() - fragment_started) / 1000.0
			return []

	var created: Array[VoxelBody3D] = []
	var component_plan := _damage_planner.plan_detached_components(
		components, physics_budget.particle_voxel_limit
	)
	for decision: Dictionary in component_plan:
		var component: Dictionary = components[int(decision.component_index)]
		_ensure_component_indices(shape, component)
		var indices: PackedInt32Array = component.indices
		# Las componentes soportadas ya se omitieron. Una componente sin ruta se desprende completa:
		# conservar voxeles por porcentaje fue lo que arrancaba bases visualmente intactas.
		var retained_anchors := PackedInt32Array()
		var count := indices.size() - retained_anchors.size()
		if count <= 0:
			continue
		if bool(decision.particle_candidate) \
				and not bool(component.get("external_contact", false)):
			var discarded := shape.detach_component_preserving(indices, retained_anchors)
			if discarded != null:
				# La Shape desprendida todavía no pertenece al SceneTree. Las partículas necesitan su
				# transformada mundial para muestrear centros, así que se conserva explícitamente.
				var discarded_transform := discarded.transform
				add_child(discarded)
				discarded.global_transform = discarded_transform
				_particle_pool.emit_component(
					discarded, discarded.data.get_live_indices(), impulse_center
				)
				discarded.queue_free()
			continue
		# Los primeros trozos nacen en el acto; el resto espera turno. Crear ocho RigidBody3D con su
		# compound de cajas en el mismo frame son 37 ms medidos, y lo unico que se ve al repartirlos es
		# que un cascote tarda un frame de mas en empezar a caer.
		if created.size() >= FRAGMENTS_PER_FRAME:
			_pending_fragments.append({
				"shape": shape, "indices": indices, "retained": retained_anchors,
				"count": count, "source_body": _body,
				"source_was_static": _body.state == VoxelBody3D.State.STATIC,
				"source_revision": shape.content_revision(),
				"dirty_min": component.get("minimum", Vector3i.ZERO),
				"dirty_max": component.get("maximum", Vector3i.ZERO),
				"impulse_center": impulse_center, "blast_radius": blast_radius,
				"damage_epoch": _active_damage_epoch,
				"transaction": _next_detachment_transaction,
			})
			continue
		var fragment := _spawn_fragment(shape, indices, retained_anchors, count)
		if fragment != null:
			created.append(fragment)
	if shape.voxel_count() == 0:
		_unregister_shape_spatial(shape)
	# Damage and each detach already rebuilt precisely the touched static macrocells through the
	# Shape signal; a full-body rebuild here would repeat that work for every split.
	damage_fragment_ms += (Time.get_ticks_usec() - fragment_started) / 1000.0
	return created


static func _has_structural_support(component: Dictionary) -> bool:
	return bool(component.get("anchored", false))


static func _component_signatures(components: Array) -> Array[String]:
	var signatures: Array[String] = []
	for component: Dictionary in components:
		signatures.append("%d:%d:%s:%s" % [
			int(component.get("voxel_count", 0)),
			int(component.get("anchor_count", 0)),
			str(component.get("minimum", Vector3i.ZERO)),
			str(component.get("maximum", Vector3i.ZERO)),
		])
	signatures.sort()
	return signatures


func _ensure_component_indices(shape: VoxelShape3D, component: Dictionary) -> void:
	var indices: PackedInt32Array = component.get("indices", PackedInt32Array())
	if not indices.is_empty() or int(component.get("voxel_count", 0)) <= 0:
		return
	var started := Time.get_ticks_usec()
	indices = shape.data.get_component_6(int(component.get("seed_index", -1)))
	component["indices"] = indices
	component["indices_materialized"] = true
	connectivity_voxels_materialized += indices.size()
	damage_component_fill_ms += (Time.get_ticks_usec() - started) / 1000.0


## Un joint roto no cambia ni un voxel: ni el planner de daño ni la conectividad vuelven a mirar la
## pieza que sostenia. Se reevalua su soporte explicitamente o una reja sin uniones se queda flotando.
func queue_support_check(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body) or body.state != VoxelBody3D.State.STATIC:
		return
	for shape in body.get_shapes():
		if shape.anchored:
			continue
		_pending_support_checks[shape.get_instance_id()] = {"shape": shape, "epoch": -1}


## Un chequeo de soporte diferido solo espera a los fragmentos de su propia oleada de daño o de una
## anterior. Antes esperaba a que la cola entera se vaciara: con destrucción sostenida y dos
## fragmentos por frame, ese momento no llegaba nunca y nada se caía.
func _flush_ready_support_checks() -> void:
	if _pending_support_checks.is_empty():
		return
	var oldest_pending := 9223372036854775807
	for pending: Dictionary in _pending_fragments:
		oldest_pending = mini(oldest_pending, int(pending.get("damage_epoch", 0)))
	var ready: Array[VoxelShape3D] = []
	for key: int in _pending_support_checks.keys():
		var entry: Dictionary = _pending_support_checks[key]
		if int(entry.epoch) >= oldest_pending:
			continue
		_pending_support_checks.erase(key)
		var shape_variant: Variant = entry.shape
		if is_instance_valid(shape_variant):
			ready.append(shape_variant as VoxelShape3D)
	if not ready.is_empty():
		_drop_unsupported(ready)


func _process(delta: float) -> void:
	_process_physics_impacts()
	_flush_pending_fragments()
	_flush_ready_support_checks()
	_flush_one_collision_rebuild()
	_flush_collision_handoff_budget()
	_coalesce_ready_structural_bodies()
	_process_collision_handoffs()
	_baked_collision_priority_elapsed += delta
	if _baked_collision_priority_elapsed >= BAKED_COLLISION_PRIORITY_INTERVAL:
		_baked_collision_priority_elapsed = 0.0
		var camera := get_viewport().get_camera_3d()
		if camera != null:
			_prioritize_baked_collision(camera.global_position)
	_flush_baked_collision_budget()
	_body_cleanup_elapsed += delta
	if _body_cleanup_elapsed >= 2.0:
		_body_cleanup_elapsed = 0.0
		_cleanup_body_list()
	_maintenance_elapsed += delta
	var interval := ACTIVE_MAINTENANCE_INTERVAL if awake_bodies > 0 \
		else IDLE_MAINTENANCE_INTERVAL
	if _maintenance_elapsed < interval:
		return
	_maintenance_elapsed = 0.0
	_enforce_physics_budget(_burst_budget_pending)
	_burst_budget_pending = false
	_update_metrics()
	_refresh_awake_dynamic_grid()
	if _diagnostics != null:
		var coherence := get_physics_coherence_snapshot()
		_diagnostics.text = (
			"Voxel/Jolt  awake_bodies %d / %d\nactive_boxes %d / %d  total_boxes %d\n"
			+ "collision_rebuild_ms %.2f  pendientes %d  handoffs %d  retired_bodies %d\n"
			+ "coherence %s  shape %s  consumer %s\n"
			+ "impact_particles %d  active_particles %d"
		) % [
			awake_bodies, physics_budget.target_awake_bodies,
			awake_compound_boxes, physics_budget.max_active_boxes, compound_boxes,
			collision_rebuild_ms, _collision_rebuild_queue.size(), _collision_handoffs.size(),
			retired_bodies, coherence.status, str(coherence.get("shape", "-")),
			str(coherence.get("consumer", "-")),
			impact_particles, _particle_pool.get_active_count(),
		]


func _process_collision_handoffs() -> void:
	for shape_variant: Variant in _collision_handoffs.process(Engine.get_physics_frames()):
		if is_instance_valid(shape_variant):
			_cleanup_empty_source(shape_variant as VoxelShape3D)


func _flush_collision_handoff_budget() -> void:
	# `size/is_empty` cuentan solo fragmentos todavía congelados. Un ticket ya liberado puede seguir
	# aquí únicamente para priorizar la reconstrucción física de su origen.
	var started := Time.get_ticks_usec()
	while not _collision_rebuild_queue.is_empty():
		var selected := _collision_handoffs.select_pending_source() as VoxelBody3D
		var budget := COLLISION_HANDOFF_BUDGET_USEC if selected != null \
			else COLLISION_REBUILD_BUDGET_USEC
		if Time.get_ticks_usec() - started >= budget:
			return
		if selected != null:
			prioritize_collision_rebuild(selected)
		var before := _pending_collision_block_count()
		_flush_one_collision_rebuild()
		if _pending_collision_block_count() >= before:
			return


func _cleanup_empty_source(shape: VoxelShape3D) -> void:
	if shape == null or not is_instance_valid(shape) or shape.voxel_count() > 0:
		return
	var body := _body_of(shape)
	_unregister_shape_spatial(shape)
	_weld_baseline.erase(shape.get_instance_id())
	if body == null:
		shape.queue_free()
		return
	body.release_voxel_shape(shape)
	shape.queue_free()
	if body.get_shapes().is_empty():
		unregister_body(body)
		body.queue_free()


func get_physics_coherence_snapshot() -> Dictionary:
	# El registro mantiene revisiones y estado pendiente al escribir. Antes, esta consulta recorría
	# cada Shape y, para cada una, volvía a recorrer toda la cola baked: O(shapes * queue) cada 100 ms
	# justo mientras había cuerpos despiertos. En Lee eran ~2 200 * ~17 000 comparaciones GDScript.
	var snapshot: Dictionary = _runtime_registry.get_coherence_snapshot()
	if snapshot.get("status") == "DESYNC":
		var shape := instance_from_id(int(snapshot.get("shape", 0))) as VoxelShape3D
		if shape != null and is_instance_valid(shape):
			snapshot["support_route"] = get_support_route_trace(shape)
			if snapshot.get("consumer") == "voxel_change_signal":
				_queue_desync_recovery(shape)
		return snapshot
	if snapshot.get("status") == "COHERENT" and (
			not _pending_fragments.is_empty() or not _collision_handoffs.is_empty()
	):
		return {
			"status": "PENDING", "shape": "-", "body": "-",
			"consumer": "fragment_queue",
		}
	return snapshot


func _queue_desync_recovery(shape: VoxelShape3D) -> void:
	var key := shape.get_instance_id()
	if _desync_recovery_queued.has(key):
		return
	_desync_recovery_queued[key] = true
	_recover_desynced_shape.call_deferred(shape, key)


func _recover_desynced_shape(shape: VoxelShape3D, key: int) -> void:
	_desync_recovery_queued.erase(key)
	if not is_instance_valid(shape) or shape.data == null \
			or shape.last_notified_revision == shape.content_revision():
		return
	shape.recover_unnotified_mutation()


## Se calcula solo al solicitar diagnóstico: no añade coste al BFS normal de soporte.
func get_support_route_trace(shape: VoxelShape3D) -> Array[int]:
	if shape == null or not is_instance_valid(shape):
		return []
	var predecessor := {shape.get_instance_id(): 0}
	var frontier: Array[VoxelShape3D] = [shape]
	var target := 0
	while not frontier.is_empty():
		var current: VoxelShape3D = frontier.pop_front()
		if _is_foundation(current):
			target = current.get_instance_id()
			break
		for neighbour in _static_contacts(current):
			var key := neighbour.get_instance_id()
			if predecessor.has(key):
				continue
			predecessor[key] = current.get_instance_id()
			frontier.append(neighbour)
	if target == 0:
		return []
	var route: Array[int] = []
	while target != 0:
		route.push_front(target)
		target = int(predecessor.get(target, 0))
	return route


func _enforce_physics_budget(burst: bool) -> void:
	var now := Time.get_ticks_msec()
	var plan: Dictionary = _runtime_registry.plan_budget(
		physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
		physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
	)
	# El censo, suma y ordenación viven en C++. GDScript conserva únicamente las mutaciones de nodos
	# y Jolt, que deben ocurrir en el hilo principal de acuerdo con el contrato de Godot.
	for body_id: int in plan.simplify_ids:
		var body := instance_from_id(body_id) as VoxelBody3D
		if body == null or not is_instance_valid(body):
			continue
		body.rebuild_dynamic_collision(int(plan.allowance))
		_sync_runtime_body(body)
	plan = _runtime_registry.plan_budget(
		physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
		physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
	)
	if not bool(plan.over_budget):
		return
	for body_id: int in plan.retirement_order:
		if not bool(plan.over_budget):
			break
		var body := instance_from_id(body_id) as VoxelBody3D
		if body == null or not is_instance_valid(body) \
				or body.state != VoxelBody3D.State.DYNAMIC:
			continue
		# Replacing the PhysicsBody invalidates every Joint3D connected to it. Door and mechanism
		# bodies therefore remain dynamic (they can still sleep normally and cost almost nothing).
		if body.is_physics_persistent():
			continue
		var was_awake := body.is_awake()
		# Los fragmentos por debajo del umbral estructural son cosméticos. Si el burst ya rebasa el
		# techo medido, conservarlos como RigidBody degrada también las piezas importantes; se pasan
		# inmediatamente al pool visual hasta recuperar presupuesto. No se congela ni simplifica una
		# componente estructural para ocultar el coste.
		if not body.structural:
			_retire_debris_to_particles(body)
			plan = _runtime_registry.plan_budget(
				physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
				physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
			)
			continue
		# Un prop que lleva dormido desde que se importó no ha interactuado nunca y no cuesta nada:
		# retirarlo a estática solo lo mataría. Se retira lo que estuvo vivo y acaba de pararse.
		if body.last_interaction_msec == 0 and not was_awake:
			continue
		var inactive_long_enough := not body.is_awake() and (
			now - body.last_interaction_msec >= int(physics_budget.retire_after_seconds * 1000.0)
		)
		if inactive_long_enough:
			body.retire_to_static()
			retired_bodies += 1
			_sync_runtime_body(body)
		elif _can_degrade_to_particles(body, now):
			_retire_debris_to_particles(body)
		plan = _runtime_registry.plan_budget(
			physics_budget.target_awake_bodies, physics_budget.burst_awake_bodies,
			physics_budget.max_active_boxes, physics_budget.max_boxes_per_body, burst
		)


## Cajas que puede gastar un cuerpo que acaba de nacer o de volverse dinamico.
##
## Cuenta solo lo que esta despierto, igual que `_enforce_physics_budget`. Con el total sumaba las
## 13 903 cajas de los 632 props dormidos de Lee contra un techo de 8 192, o sea siempre negativo, y
## la reserva salia 1: una torre de 24 m y 9 640 voxeles se volvia dinamica con UNA caja de colision.
## Ahi estaba el "no cae": el bloque resultante seguia apoyado en el suelo y ademas era el unico que
## chocaba, asi que ni caia ni se podia tocar de verdad.
func _box_allowance_for_new_body() -> int:
	var available := maxi(1, physics_budget.max_active_boxes - awake_compound_boxes)
	return mini(physics_budget.max_boxes_per_body, available)


func _can_degrade_to_particles(body: VoxelBody3D, now: int) -> bool:
	# Cosmetic debris may leave the rigid-body budget before the 1.5 s structural retirement
	# threshold; it has no gameplay role and only degrades when it is also far from the camera.
	var debris_delay_msec := int(minf(1.0, physics_budget.retire_after_seconds) * 1000.0)
	if body.structural or now - body.last_interaction_msec < debris_delay_msec:
		return false
	var camera := get_viewport().get_camera_3d()
	var shapes := body.get_shapes()
	if camera == null or shapes.is_empty():
		return false
	var center := shapes[0].world_bounds().get_center()
	return center.distance_to(camera.global_position) > 30.0


func _retire_debris_to_particles(body: VoxelBody3D) -> void:
	for shape in body.get_shapes():
		_particle_pool.emit_component(shape, shape.data.get_live_indices(), body.global_position)
	unregister_body(body)
	body.queue_free()
	retired_bodies += 1


func _update_metrics() -> void:
	_apply_runtime_metrics()
	# La invariante autorreparable consulta solo IDs marcados al escribir. Ya no vuelve a sumar ni a
	# contar voxeles de cada cuerpo dinámico en cada mantenimiento.
	for body_id: int in _runtime_registry.get_zero_voxel_body_ids():
		var body := instance_from_id(body_id) as VoxelBody3D
		if body == null or not is_instance_valid(body):
			_runtime_registry.remove_body(body_id)
			continue
		unregister_body(body)
		body.queue_free()
	_apply_runtime_metrics()


func _apply_runtime_metrics() -> void:
	var metrics: Dictionary = _runtime_registry.get_metrics()
	awake_bodies = int(metrics.awake_bodies)
	compound_boxes = int(metrics.compound_boxes)
	awake_compound_boxes = int(metrics.awake_compound_boxes)


func _cleanup_body_list() -> void:
	var live: Array[VoxelBody3D] = []
	for body in _bodies:
		if is_instance_valid(body):
			live.append(body)
	_bodies = live


func _body_of(shape: VoxelShape3D) -> VoxelBody3D:
	var node: Node = shape.get_parent()
	while node != null:
		if node is VoxelBody3D:
			return node
		node = node.get_parent()
	return null


func _on_shape_changed(
	world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i, shape: VoxelShape3D
) -> void:
	_cancel_baked_collision(shape)
	_invalidate_contacts(shape)
	_sync_runtime_shape(shape)
	var body := _body_of(shape)
	if body != null:
		_sync_runtime_body(body)
	voxels_changed.emit(shape, world_aabb, dirty_min, dirty_max)


func _cancel_baked_collision(shape: VoxelShape3D) -> void:
	for index in range(_baked_collision_queue.size() - 1, -1, -1):
		var entry: Dictionary = _baked_collision_queue[index]
		if entry.shape != shape:
			continue
		_baked_collision_pending_blocks -= (entry.records as Array).size() - int(entry.cursor)
		_baked_collision_queue.remove_at(index)
	_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
	_sync_runtime_shape(shape)


func _prioritize_baked_collision(center: Vector3) -> void:
	for entry: Dictionary in _baked_collision_queue:
		var shape := entry.shape as VoxelShape3D
		if not is_instance_valid(shape) or not shape.is_inside_tree():
			entry.distance_squared = INF
			continue
		var bounds := shape.world_bounds()
		var closest := center.clamp(bounds.position, bounds.end)
		entry.distance_squared = closest.distance_squared_to(center)
	_baked_collision_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.distance_squared) < float(b.distance_squared)
	)


func _flush_baked_collision_budget() -> void:
	var started := Time.get_ticks_usec()
	var radius_squared := BAKED_COLLISION_PREFETCH_RADIUS * BAKED_COLLISION_PREFETCH_RADIUS
	while not _baked_collision_queue.is_empty() \
			and Time.get_ticks_usec() - started < BAKED_COLLISION_FRAME_BUDGET_USEC:
		var entry: Dictionary = _baked_collision_queue[0]
		if float(entry.distance_squared) > radius_squared:
			return
		var body := entry.body as VoxelBody3D
		var shape := entry.shape as VoxelShape3D
		var records := entry.records as Array
		var cursor := int(entry.cursor)
		if not is_instance_valid(body) or not is_instance_valid(shape) or cursor >= records.size():
			if is_instance_valid(shape):
				_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
			_baked_collision_pending_blocks -= maxi(0, records.size() - cursor)
			_baked_collision_queue.pop_front()
			continue
		body.import_baked_static_collision(shape, [records[cursor]])
		entry.cursor = cursor + 1
		_baked_collision_pending_blocks -= 1
		if int(entry.cursor) >= records.size():
			body.acknowledge_static_collision_revision(shape)
			_baked_collision_queue.pop_front()
			_runtime_registry.set_baked_collision_pending(shape.get_instance_id(), false)
			_sync_runtime_body(body)


## Romper voxeles puede deshacer un contacto, asi que se tira la entrada de esa Shape y tambien la de
## quien la tuviera por vecina: si no, el vecino seguiria creyendose apoyado en ella.
##
## Las dos direcciones. Mirar solo la lista propia no basta porque `_reaches_foundation` para en
## cuanto descubre cimiento y no llega a expandir al vecino, asi que un apoyo puede no tener entrada
## propia mientras lo que aguanta encima si lo tiene en la suya. Le hacias un boquete al apoyo, el
## contacto dejaba de existir y lo de arriba seguia creyendose apoyado hasta que otro impacto
## cualquiera le tiraba la cache: era el "no cae hasta que disparo a otra cosa".
func _invalidate_contacts(shape: VoxelShape3D) -> void:
	var key := shape.get_instance_id()
	var cached := _contact_cache.get(key, {}) as Dictionary
	for neighbour_variant: Variant in cached.get("contacts", []):
		if is_instance_valid(neighbour_variant):
			_contact_cache.erase((neighbour_variant as VoxelShape3D).get_instance_id())
	for user_key in _contact_users.get(key, {}):
		_contact_cache.erase(user_key)
	_contact_users.erase(key)
	_contact_cache.erase(key)


func _on_body_state_changed(body: VoxelBody3D) -> void:
	for shape in body.get_shapes():
		_invalidate_contacts(shape)
		if body.state == VoxelBody3D.State.DYNAMIC:
			_cancel_baked_collision(shape)
			_static_grid.remove_id(shape.get_instance_id())
			_register_dynamic_shape(shape)
		else:
			_unregister_dynamic_shape(shape)
			_index_static_shape(shape)
	if body.state == VoxelBody3D.State.DYNAMIC:
		if not _dynamic_bodies.has(body):
			_dynamic_bodies.append(body)
	else:
		_dynamic_bodies.erase(body)
	_bind_runtime_sleep_signal(body)
	_sync_runtime_body(body)


func _on_runtime_state_changed(body: VoxelBody3D) -> void:
	_sync_runtime_body(body)


func _on_runtime_sleeping_changed(body: VoxelBody3D) -> void:
	_sync_runtime_body(body)


func _bind_runtime_sleep_signal(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	var rigid := body.get_physics_body() as RigidBody3D
	if rigid == null:
		return
	var callback := _on_runtime_sleeping_changed.bind(body)
	if not rigid.sleeping_state_changed.is_connected(callback):
		rigid.sleeping_state_changed.connect(callback)


func _sync_runtime_body(body: VoxelBody3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	_runtime_registry.upsert_body(
		body.get_instance_id(), body.state == VoxelBody3D.State.DYNAMIC, body.is_awake(),
		body.structural, body.is_physics_persistent(), body.compound_boxes,
		body.get_total_voxels(), body.last_interaction_msec
	)
	for shape in body.get_shapes():
		_sync_runtime_shape(shape, body)
	_apply_runtime_metrics()


func _sync_runtime_shape(shape: VoxelShape3D, owner: VoxelBody3D = null) -> void:
	if shape == null or not is_instance_valid(shape) or shape.data == null:
		return
	var body := owner if owner != null else _body_of(shape)
	if body == null or not is_instance_valid(body):
		return
	var revision := shape.content_revision()
	_runtime_registry.upsert_shape(
		shape.get_instance_id(), shape.data, body.get_instance_id(), revision,
		shape.last_notified_revision,
		body.get_collision_revision(shape) if body.collision_enabled else revision,
		body.collision_enabled, body.has_pending_collision_rebuild(),
		body.collision_handoff_pending
	)


## Broad phase de la destruccion. Antes preguntaba al arbol AABB, y ahi estaba el pico: la
## destruccion lo marca sucio y la siguiente consulta lo reconstruia entero — medido, 54-59 ms por
## disparo, mas que todo lo demas junto. Una Shape estatica no se mueve y su envolvente no encoge al
## romperse voxeles, asi que reconstruir no aportaba nada. La rejilla se indexa una vez.
##
## La rejilla responde por caja y no por esfera: es una banda mas ancha en las esquinas, y no importa
## porque `damage_sphere` de cada Shape ya devuelve cero cuando el crater no la toca.
func _query_shapes(center: Vector3, radius: float) -> Array[VoxelShape3D]:
	var result := _static_grid.query(AABB(center - Vector3.ONE * radius, Vector3.ONE * radius * 2.0))
	var low := _dynamic_grid_cell(center - Vector3.ONE * radius)
	var high := _dynamic_grid_cell(center + Vector3.ONE * radius)
	var visited := {}
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var bucket: Array = _dynamic_grid.get(Vector3i(x, y, z), [])
				for shape_variant: Variant in bucket:
					# La rejilla dinámica se refresca a 10 Hz; una Shape destruida puede seguir en el
					# bucket unos ticks. Validar el Variant antes del cast evita tocar la instancia libre.
					if not is_instance_valid(shape_variant):
						continue
					var shape := shape_variant as VoxelShape3D
					if shape == null or not shape.is_inside_tree() \
							or shape.voxel_count() == 0:
						continue
					var key := shape.get_instance_id()
					if visited.has(key):
						continue
					visited[key] = true
					var bounds := shape.world_bounds()
					var closest := center.clamp(bounds.position, bounds.end)
					if closest.distance_squared_to(center) <= radius * radius:
						result.append(shape)
	return result


func _unregister_shape_spatial(shape: VoxelShape3D) -> void:
	_pending_support_checks.erase(shape.get_instance_id())
	_invalidate_contacts(shape)
	_static_grid.remove_id(shape.get_instance_id())
	_unregister_dynamic_shape(shape)
	_runtime_registry.remove_shape(shape.get_instance_id())


func _register_dynamic_shape(shape: VoxelShape3D) -> void:
	if not _dynamic_shapes.has(shape):
		_dynamic_shapes.append(shape)
	_update_dynamic_grid_shape(shape, true)


func _unregister_dynamic_shape(shape: VoxelShape3D) -> void:
	_dynamic_shapes.erase(shape)
	var key := shape.get_instance_id()
	var old_cells: Array = _dynamic_grid_cells.get(key, [])
	for cell: Vector3i in old_cells:
		var bucket: Array = _dynamic_grid.get(cell, [])
		bucket.erase(shape)
		if bucket.is_empty():
			_dynamic_grid.erase(cell)
	_dynamic_grid_cells.erase(key)
	_dynamic_grid_transforms.erase(key)


func _refresh_awake_dynamic_grid() -> void:
	# Los props importados entran en la rejilla al registrarse y duermen ahi. Solo un cuerpo despierto
	# puede haber cambiado de sitio, asi que una consulta de daño no recorre las 628 Shapes dormidas.
	for body in get_awake_dynamic_bodies():
		for shape in body.get_shapes():
			_update_dynamic_grid_shape(shape)


func _update_dynamic_grid_shape(shape: VoxelShape3D, force := false) -> void:
	if not is_instance_valid(shape) or not shape.is_inside_tree() or shape.data == null:
		return
	var key := shape.get_instance_id()
	var current_transform := shape.global_transform
	if not force and _dynamic_grid_transforms.has(key) \
			and (_dynamic_grid_transforms[key] as Transform3D).is_equal_approx(current_transform):
		return
	var old_cells: Array = _dynamic_grid_cells.get(key, [])
	for cell: Vector3i in old_cells:
		var old_bucket: Array = _dynamic_grid.get(cell, [])
		old_bucket.erase(shape)
		if old_bucket.is_empty():
			_dynamic_grid.erase(cell)
	var bounds := shape.world_bounds()
	var low := _dynamic_grid_cell(bounds.position)
	var high := _dynamic_grid_cell(bounds.end - Vector3.ONE * 0.0001)
	var new_cells: Array[Vector3i] = []
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var cell := Vector3i(x, y, z)
				var bucket: Array = _dynamic_grid.get(cell, [])
				bucket.append(shape)
				_dynamic_grid[cell] = bucket
				new_cells.append(cell)
	_dynamic_grid_cells[key] = new_cells
	_dynamic_grid_transforms[key] = current_transform


static func _dynamic_grid_cell(position: Vector3) -> Vector3i:
	return Vector3i(
		floori(position.x / DYNAMIC_GRID_CELL_SIZE),
		floori(position.y / DYNAMIC_GRID_CELL_SIZE),
		floori(position.z / DYNAMIC_GRID_CELL_SIZE)
	)


func _flush_one_collision_rebuild() -> void:
	collision_rebuild_ms = 0.0
	while not _collision_rebuild_queue.is_empty():
		# Igual que en `flush_one_static_collision_rebuild`: asignar un Object liberado a una variable
		# tipada revienta antes de llegar a la guarda, asi que se comprueba sobre el Variant.
		var pending: Variant = _collision_rebuild_queue.pop_front()
		if not is_instance_valid(pending):
			continue
		var body := pending as VoxelBody3D
		_collision_rebuild_queued.erase(body.get_instance_id())
		collision_rebuild_ms = body.flush_one_collision_rebuild(
			_box_allowance_for_new_body() if body.state == VoxelBody3D.State.DYNAMIC \
			else physics_budget.max_boxes_per_body
		)
		if body.has_pending_collision_rebuild():
			queue_collision_rebuild(body)
		_sync_runtime_body(body)
		return


func _pending_collision_block_count() -> int:
	var count := 0
	for body in _collision_rebuild_queue:
		if is_instance_valid(body):
			count += body.pending_collision_rebuild_count()
	return count


func _create_diagnostics() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 90
	add_child(canvas)
	_diagnostics = Label.new()
	# Anclado abajo a la izquierda y creciendo hacia arriba. Con una posicion fija arriba habia que
	# adivinar cuantas lineas ocupaba el contador de `main.gd`, y en cuanto le crecio la tercera se
	# solapaban. Desde abajo da igual cuanto crezca cualquiera de los dos; se dejan 40 px para la
	# linea de ayuda.
	_diagnostics.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_diagnostics.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_diagnostics.offset_left = 12.0
	_diagnostics.offset_top = -40.0
	_diagnostics.offset_bottom = -40.0
	_diagnostics.add_theme_font_size_override("font_size", 13)
	_diagnostics.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.88))
	_diagnostics.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.95))
	_diagnostics.add_theme_constant_override("shadow_offset_x", 1)
	_diagnostics.add_theme_constant_override("shadow_offset_y", 1)
	_diagnostics.add_theme_constant_override("shadow_outline_size", 2)
	canvas.add_child(_diagnostics)
