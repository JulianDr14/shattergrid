class_name VoxelBody3D
extends Node3D
## Public Body in the World -> Body -> Shape model.

signal body_state_changed(body: VoxelBody3D)
signal runtime_state_changed(body: VoxelBody3D)

enum State { STATIC, DYNAMIC, RETIRED_STATIC }

const GROUP := "voxel_bodies"

var state := State.STATIC
var structural := true
## Bodies with live gameplay constraints (doors, mechanisms) must keep the same PhysicsBody RID.
## Retiring them to a replacement StaticBody3D would silently invalidate their joints.
## `physics_persistent` remains as a compatibility/manual pin. Runtime constraints use the counted
## holds below so one broken cable cannot unprotect a Body that still owns a live joint.
var physics_persistent := false
var physics_generation := 0
var collision_handoff_pending := false
## Solo los cuerpos que nacen de geometría estática necesitan CCD. Los 632 props authored dormidos
## no pagan ese coste; postes, vigas y fragmentos largos sí evitan atravesar apoyos delgados.
var continuous_collision := false
## Desactivable para medir el motor sin el coste de Jolt: las mallas cóncavas se llevan el 96 % del
## tiempo de carga de un mapa grande, así que apagarlas aísla lo que cuesta todo lo demás.
var collision_enabled := true
var compound_boxes := 0
var collision_rebuild_ms := 0.0
var last_faces_ms := 0.0
var last_interaction_msec := 0
var _physics_body: PhysicsBody3D
var _collision_nodes: Array[CollisionShape3D] = []
var _macro_collisions := {}
## La colisión estática se reparte en cuerpos de región. Un solo StaticBody con miles de Shapes
## tiene una AABB del tamaño del terreno y obliga al narrowphase a probarlas todas contra una torre
## que cae; los shards permiten que el broadphase descarte las regiones lejanas.
var _static_collision_shards := {}
var _pending_static_collisions: Array[Dictionary] = []
var _pending_static_collision_keys := {}
var _pending_dynamic_collision := false
var _constraint_holds := {}
var _handoff_collision_layer := 1
var _handoff_collision_mask := 1
var _handoff_impulses: Array[Dictionary] = []
var _vehicle_descriptor := {}
var _collision_installer := VoxelCollisionInstaller.new()
var _mass_properties := VoxelMassProperties.new()

const LARGE_BODY_CCD_BOX_THRESHOLD := 20
const LARGE_BODY_CCD_MASS_THRESHOLD := 2000.0
const LARGE_BODY_CCD_SPEED_THRESHOLD := 14.0


func _init() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	if _physics_body == null:
		_create_physics_body(state == State.DYNAMIC)


func add_voxel_shape(
	shape: VoxelShape3D, preserve_global := false, rebuild_collision := true
) -> void:
	if _physics_body == null:
		_create_physics_body(state == State.DYNAMIC)
	var desired_global := shape.global_transform if shape.is_inside_tree() else shape.transform
	var desired_local := shape.transform
	if shape.get_parent() != null:
		shape.reparent(_physics_body, preserve_global)
	else:
		_physics_body.add_child(shape)
		if preserve_global:
			shape.global_transform = desired_global
		else:
			shape.transform = desired_local
	shape.voxels_changed.connect(_on_shape_voxels_changed.bind(shape))
	if state == State.DYNAMIC and rebuild_collision:
		rebuild_dynamic_collision()
	elif state != State.DYNAMIC and rebuild_collision:
		rebuild_static_collision(shape)


## Saca una Shape del cuerpo sin destruirla, para pasarsela a otro. Es lo que necesita partir un
## cuerpo cuyas Shapes han dejado de tocarse.
func release_voxel_shape(shape: VoxelShape3D) -> void:
	var listener := _on_shape_voxels_changed.bind(shape)
	if shape.voxels_changed.is_connected(listener):
		shape.voxels_changed.disconnect(listener)
	if shape.get_parent() == _physics_body:
		_physics_body.remove_child(shape)


func remove_voxel_shape(shape: VoxelShape3D) -> void:
	if shape.get_parent() == _physics_body:
		_physics_body.remove_child(shape)
	shape.queue_free()
	rebuild_all_collision()


func get_shapes() -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	if _physics_body == null:
		return result
	for child in _physics_body.get_children():
		if child is VoxelShape3D:
			result.append(child)
	return result


func make_dynamic(max_boxes := 128, rebuild_collision := true) -> void:
	if state == State.DYNAMIC:
		return
	continuous_collision = true
	for shape in get_shapes():
		shape.calibrate_for_dynamic_structure()
	state = State.DYNAMIC
	structural = get_total_voxels() >= 64
	_replace_physics_body(true)
	if rebuild_collision:
		rebuild_dynamic_collision(max_boxes)
	var voxel_world := _find_voxel_world()
	if voxel_world != null:
		begin_collision_handoff()
		voxel_world.queue_transition_collision_handoff(self)
	last_interaction_msec = Time.get_ticks_msec()
	body_state_changed.emit(self)
	runtime_state_changed.emit(self)


func retire_to_static() -> void:
	if state != State.DYNAMIC:
		return
	state = State.RETIRED_STATIC
	_replace_physics_body(false)
	for shape in get_shapes():
		rebuild_static_collision(shape)
	body_state_changed.emit(self)
	runtime_state_changed.emit(self)


func reactivate(max_boxes := 128) -> void:
	if state != State.RETIRED_STATIC:
		return
	make_dynamic(max_boxes)


func is_awake() -> bool:
	return state == State.DYNAMIC and _physics_body is RigidBody3D \
		and not (_physics_body as RigidBody3D).sleeping


## CCD por Shape compuesta es caro: barrer permanentemente las 29 cajas de la torre contra mallas
## cóncavas regionales explica los picos bimodales de 7/26 ms. Postes, piezas pequeñas y cuerpos
## rápidos lo conservan; una estructura grande que avanza menos de 23 cm por tick usa discreto.
func update_adaptive_ccd() -> void:
	var rigid := _physics_body as RigidBody3D
	if rigid == null:
		return
	var speed := rigid.linear_velocity.length()
	var needs_ccd := continuous_collision and (
		speed >= VoxelVehicle3D.CCD_MIN_SPEED if rigid is VoxelVehicle3D else (
			compound_boxes <= LARGE_BODY_CCD_BOX_THRESHOLD
			or rigid.mass <= LARGE_BODY_CCD_MASS_THRESHOLD
			or speed >= LARGE_BODY_CCD_SPEED_THRESHOLD
		)
	)
	if rigid.continuous_cd != needs_ccd:
		rigid.continuous_cd = needs_ccd


## Duerme el cuerpo sin sacarlo de la simulación. Los props de Teardown nacen en reposo, y dormirlos
## evita que Jolt resuelva 628 cuerpos durante los primeros segundos de partida; pero siguen siendo
## cuerpos dinámicos de verdad, así que despiertan solos en cuanto algo los toca, tira de un joint o
## les aplica una fuerza. Antes se usaba `freeze`, que es lo contrario: convierte el prop en estática
## muerta que ni el jugador empujando ni una explosión al lado podían mover.
func sleep() -> void:
	if not _physics_body is RigidBody3D:
		return
	# Jolt ignora `sleeping` mientras el cuerpo no haya dado un paso por el espacio, asi que dormirlo
	# en el mismo frame en que se crea no hace nada — medido: el prop se despertaba y caia igual.
	if not is_inside_tree():
		(_physics_body as RigidBody3D).sleeping = true
		if _physics_body is VoxelVehicle3D:
			(_physics_body as VoxelVehicle3D).park_after_sleep()
		return
	var tree := get_tree()
	await tree.physics_frame
	await tree.physics_frame
	if is_instance_valid(self) and _physics_body is RigidBody3D:
		(_physics_body as RigidBody3D).sleeping = true
		if _physics_body is VoxelVehicle3D:
			(_physics_body as VoxelVehicle3D).park_after_sleep()
		# Jolt no garantiza `sleeping_state_changed` al asignar la propiedad desde script. Sin esta
		# notificacion el registro conservaba los 632 props como despiertos, el presupuesto intentaba
		# simplificarlos y esa reconstruccion los despertaba de verdad unos frames despues.
		runtime_state_changed.emit(self)


## Despertar explícito para las interacciones que Jolt no ve venir: agarrar un objeto, abrir una
## puerta, o revivir un cuerpo ya retirado a estática por el presupuesto.
func wake_for_interaction() -> void:
	if state == State.RETIRED_STATIC:
		reactivate()
	if _physics_body is RigidBody3D:
		(_physics_body as RigidBody3D).sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	runtime_state_changed.emit(self)


func get_total_voxels() -> int:
	var total := 0
	for shape in get_shapes():
		total += shape.voxel_count()
	return total


func get_physics_body() -> PhysicsBody3D:
	return _physics_body


## Promueve el RigidBody authored por `<vehicle>` antes de cocinar su compound. Las Shapes se
## preservan en mundo al recentrar el Body en el marco del coche; así la dirección, la suspensión
## y el centro de masa dejan de depender de que el mapa esté lejos del origen.
func configure_vehicle(descriptor: Dictionary) -> VoxelVehicle3D:
	if state != State.DYNAMIC or descriptor.is_empty():
		return null
	# Un coche authored alcanza 20–50 m/s y debe barrer postes/paredes delgadas. Los estacionados
	# duermen, así que habilitar CCD aquí solo tiene coste para los que realmente están circulando.
	continuous_collision = true
	_vehicle_descriptor = descriptor
	_replace_physics_body(true)
	var vehicle := _physics_body as VoxelVehicle3D
	if vehicle != null:
		vehicle.configure(self, descriptor)
	return vehicle


## Un Body estático reparte su colisión entre varios StaticBody3D regionales. Los joints de Godot
## solo conocen el `JoltBody` raíz, por lo que consumidores que necesiten una excepción de colisión
## coherente (puertas durante el despeje del marco) deben incluir también esos shards.
func get_collision_objects() -> Array[CollisionObject3D]:
	var result: Array[CollisionObject3D] = []
	for child: Node in get_children():
		if child is CollisionObject3D and is_instance_valid(child):
			result.append(child as CollisionObject3D)
	return result


func acquire_physics_hold(owner: Variant) -> void:
	_constraint_holds[_hold_key(owner)] = true


func release_physics_hold(owner: Variant) -> void:
	_constraint_holds.erase(_hold_key(owner))


func is_physics_persistent() -> bool:
	return physics_persistent or not _constraint_holds.is_empty() or collision_handoff_pending


func physics_hold_count() -> int:
	return _constraint_holds.size() + (1 if physics_persistent else 0)


func has_physics_hold(owner: Variant) -> bool:
	return _constraint_holds.has(_hold_key(owner))


static func _hold_key(owner: Variant) -> String:
	if owner is Object:
		return "object:%d" % (owner as Object).get_instance_id()
	return str(owner)


func begin_collision_handoff() -> void:
	if not _physics_body is RigidBody3D or collision_handoff_pending:
		return
	var rigid := _physics_body as RigidBody3D
	_handoff_collision_layer = rigid.collision_layer
	_handoff_collision_mask = rigid.collision_mask
	rigid.collision_layer = 0
	rigid.collision_mask = 0
	rigid.freeze = true
	rigid.sleeping = false
	_handoff_impulses.clear()
	collision_handoff_pending = true


func complete_collision_handoff(
	impulse_center := Vector3.ZERO, impulse_energy := 0.0, impulse_radius := 0.0
) -> void:
	if not collision_handoff_pending:
		return
	collision_handoff_pending = false
	if not _physics_body is RigidBody3D:
		return
	var rigid := _physics_body as RigidBody3D
	rigid.collision_layer = _handoff_collision_layer
	rigid.collision_mask = _handoff_collision_mask
	rigid.freeze = false
	rigid.sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	if impulse_energy > 0.0 and impulse_radius > 0.0:
		apply_explosion_impulse(impulse_center, impulse_energy, impulse_radius)
	var queued_impulses := _handoff_impulses.duplicate()
	_handoff_impulses.clear()
	for queued: Dictionary in queued_impulses:
		apply_explosion_impulse(
			queued.center as Vector3, float(queued.energy), float(queued.radius)
		)
	runtime_state_changed.emit(self)


## Cierra un ticket porque este Body va a desaparecer. No restaura capas ni lo descongela: hacerlo
## durante `unregister_body` reactiva por un frame la colisión estática fantasma que el handoff
## precisamente mantenía aislada.
func cancel_collision_handoff() -> void:
	if not collision_handoff_pending:
		return
	collision_handoff_pending = false
	_handoff_impulses.clear()
	runtime_state_changed.emit(self)


func get_collision_revision(shape: VoxelShape3D) -> int:
	return shape.collision_revision if is_instance_valid(shape) else 0


func is_static_collision_revision_pending(shape: VoxelShape3D, target_revision: int) -> bool:
	if shape == null or not is_instance_valid(shape) or shape.data == null:
		return false
	if get_collision_revision(shape) >= target_revision:
		return false
	return _has_pending_static_collision_for_shape(shape)


## El handoff solo necesita saber si todavía queda colisión VIEJA habilitada. La revisión completa
## puede seguir pendiente mientras se recocinan las caras nuevas; los bloques del cráter se
## desactivan al encolarlos y Jolt los retira en el tick seguro que ya exige el ticket.
func is_static_collision_handoff_pending(shape: VoxelShape3D, _target_revision: int) -> bool:
	if shape == null or not is_instance_valid(shape):
		return false
	var prefix := "%d:" % shape.get_instance_id()
	for key: String in _pending_static_collision_keys:
		if not key.begins_with(prefix):
			continue
		var collision := _macro_collisions.get(key) as CollisionShape3D
		if collision != null and is_instance_valid(collision) and not collision.disabled:
			return true
	return false


func acknowledge_static_collision_revision(shape: VoxelShape3D) -> void:
	if shape != null and shape.data != null:
		shape.collision_revision = shape.content_revision()


## RID que representan físicamente a este Body. En dinámico es uno; en estático incluye los shards
## regionales para que raycasts internos —por ejemplo el cable sujeto al propio poste— puedan
## excluir toda su colisión y no solo el nodo lógico sin Shapes.
func get_collision_rids() -> Array[RID]:
	var result: Array[RID] = []
	if _physics_body != null and is_instance_valid(_physics_body):
		result.append(_physics_body.get_rid())
	for shard: StaticBody3D in _static_collision_shards.values():
		if is_instance_valid(shard):
			result.append(shard.get_rid())
	return result


func rebuild_all_collision(max_boxes := 128) -> void:
	if state == State.DYNAMIC:
		rebuild_dynamic_collision(max_boxes)
	else:
		_clear_collisions()
		for shape in get_shapes():
			rebuild_static_collision(shape)


## Cuántas macroceldas de 8 voxeles entran en cada malla de colisión estática.
##
## Cada bloque acaba siendo una `ConcavePolygonShape3D` con su propio BVH. Godot/Jolt recomiendan
## mantener bajo el número de Shapes; una por macrocelda generaba miles de BVH pequeños y hacía que
## cargar Lee tardara 6–14 segundos. El bloque adaptativo conserva las caras exactas a 10 cm, pero
## agrupa su índice espacial en regiones de 0,8/1,6/3,2 m según ocupación. El techo de 3,2 m
## mantiene cada reconstrucción destructiva por debajo de un frame sin multiplicar mucho el total
## de Shapes: en Lee pasa de 30.321 a 31.549 bloques (+4,1 %) frente al antiguo techo de 6,4 m.
const TARGET_STATIC_COLLISION_BLOCKS := 32
const MAX_STATIC_MACRO_BLOCK := 4
## Dos bloques por eje: cada StaticBody regional contiene como máximo 2³ = 8 concave shapes.
const STATIC_COLLISION_SHARD_SPAN := 2


static func collision_block_for(shape: VoxelShape3D) -> int:
	var occupied := shape.data.get_occupied_macros().size()
	var block := 1
	while block < MAX_STATIC_MACRO_BLOCK \
			and ceili(float(occupied) / float(block * block * block)) \
			> TARGET_STATIC_COLLISION_BLOCKS:
		block *= 2
	return block


## La colisión estática se genera siempre a resolución de voxel. Antes bajaba a bloques de 4 en las
## Shapes de más de 16 K voxeles, que en un mapa real son todas las del suelo, y `coarse_occupied`
## marca lleno un bloque entero si tiene un solo voxel dentro: la superficie salía dilatada hasta 30
## cm por encima de lo que se dibuja y cualquier desnivel se convertía en un escalón de 40 cm. Al
## caminar eso son paredes invisibles y sitios donde el jugador se queda metido sin poder bajar.
##
## Las caras coplanares se fusionan en C++ para conservar esta precisión sin entregar dos
## triángulos por cara de voxel a Jolt. La precisión del suelo no es negociable.
static func static_collision_lod_for(_shape: VoxelShape3D) -> int:
	return 1


func rebuild_static_collision(
	shape: VoxelShape3D, dirty_min := Vector3i(-1, -1, -1), dirty_max := Vector3i(-1, -1, -1)
) -> void:
	if _physics_body == null or _physics_body is RigidBody3D or shape.data == null \
			or not collision_enabled:
		return
	var started := Time.get_ticks_usec()
	var block := collision_block_for(shape)
	var collision_lod := static_collision_lod_for(shape)
	var faces_usec := 0
	for macro: Vector3i in _static_collision_blocks(shape, dirty_min, dirty_max, block):
		var faces_started := Time.get_ticks_usec()
		_rebuild_static_collision_block(shape, macro, block, collision_lod)
		faces_usec += Time.get_ticks_usec() - faces_started
	compound_boxes = 0
	collision_rebuild_ms = (Time.get_ticks_usec() - started) / 1000.0
	# Reparto entre lo que se puede hilar (generar caras, C++ puro) y lo que no (crear la forma y
	# darsela a Jolt, que exige el hilo principal).
	last_faces_ms = faces_usec / 1000.0
	shape.collision_revision = shape.content_revision()


## Destruction must not hand several new triangle BVHs to Jolt in the same frame. The visual atlas
## is updated immediately, while these collision blocks are deduplicated and consumed globally by
## VoxelWorld3D at one block per frame.
func queue_static_collision_rebuild(
	shape: VoxelShape3D, dirty_min: Vector3i, dirty_max: Vector3i
) -> void:
	if _physics_body == null or _physics_body is RigidBody3D or shape.data == null \
			or not collision_enabled or dirty_min.x < 0:
		return
	var block := collision_block_for(shape)
	var lod := static_collision_lod_for(shape)
	for macro: Vector3i in _static_collision_blocks(shape, dirty_min, dirty_max, block):
		var key := _static_collision_key(shape, macro)
		# Se retira primero la geometría vieja. Así un fragmento no espera cientos de cocciones para
		# empezar a caer y tampoco puede chocar contra los voxeles que acaba de abandonar.
		var stale := _macro_collisions.get(key) as CollisionShape3D
		if stale != null and is_instance_valid(stale):
			stale.disabled = true
		if _pending_static_collision_keys.has(key):
			_pending_static_collision_keys[key] = shape.content_revision()
			continue
		_pending_static_collision_keys[key] = shape.content_revision()
		_pending_static_collisions.append({
			"key": key, "shape": shape, "macro": macro, "block": block, "lod": lod,
		})
	var voxel_world := _find_voxel_world()
	if voxel_world != null and not _pending_static_collisions.is_empty():
		voxel_world.queue_collision_rebuild(self)


func has_pending_static_collision_rebuild() -> bool:
	return not _pending_static_collisions.is_empty()


func pending_static_collision_rebuild_count() -> int:
	return _pending_static_collisions.size()


func flush_one_static_collision_rebuild() -> float:
	while not _pending_static_collisions.is_empty():
		var pending: Dictionary = _pending_static_collisions.pop_front()
		var target_revision := int(_pending_static_collision_keys.get(pending.key, 0))
		_pending_static_collision_keys.erase(pending.key)
		# El `is_instance_valid` va antes de la asignacion a proposito: asignar un Object ya liberado
		# a una variable tipada revienta ahi mismo y nunca se llegaba a la guarda.
		var shape: VoxelShape3D = pending.shape if is_instance_valid(pending.shape) else null
		if shape == null or shape.data == null or state == State.DYNAMIC:
			continue
		var started := Time.get_ticks_usec()
		var faces_started := Time.get_ticks_usec()
		_rebuild_static_collision_block(
			shape, pending.macro, int(pending.block), int(pending.lod)
		)
		last_faces_ms = (Time.get_ticks_usec() - faces_started) / 1000.0
		collision_rebuild_ms = (Time.get_ticks_usec() - started) / 1000.0
		if not _has_pending_static_collision_for_shape(shape):
			shape.collision_revision = maxi(target_revision, shape.content_revision())
		return collision_rebuild_ms
	return 0.0


func _has_pending_static_collision_for_shape(shape: VoxelShape3D) -> bool:
	var prefix := "%d:" % shape.get_instance_id()
	for key: String in _pending_static_collision_keys:
		if key.begins_with(prefix):
			return true
	return false


## El daño de varios voxeles/Shapes del mismo cuerpo puede emitir muchas señales en un frame. El
## compound dinámico se rehace una sola vez desde el presupuesto global, igual que la colisión
## estática por macroceldas.
func queue_dynamic_collision_rebuild() -> void:
	if _pending_dynamic_collision:
		return
	_pending_dynamic_collision = true
	var voxel_world := _find_voxel_world()
	if voxel_world != null:
		voxel_world.queue_collision_rebuild(self)
	else:
		flush_one_collision_rebuild.call_deferred()


func has_pending_collision_rebuild() -> bool:
	return _pending_dynamic_collision or has_pending_static_collision_rebuild()


func pending_collision_rebuild_count() -> int:
	return (1 if _pending_dynamic_collision else 0) + pending_static_collision_rebuild_count()


func flush_one_collision_rebuild(max_boxes := 128) -> float:
	if _pending_dynamic_collision:
		_pending_dynamic_collision = false
		rebuild_dynamic_collision(max_boxes)
		return collision_rebuild_ms
	return flush_one_static_collision_rebuild()


func _static_collision_blocks(
	shape: VoxelShape3D, dirty_min: Vector3i, dirty_max: Vector3i, block: int
) -> Array[Vector3i]:
	var blocks := {}
	if dirty_min.x >= 0:
		var span := 8 * block
		var low := dirty_min / span
		var high := dirty_max / span
		for z in range(low.z, high.z + 1):
			for y in range(low.y, high.y + 1):
				for x in range(low.x, high.x + 1):
					blocks[Vector3i(x, y, z)] = true
	else:
		# En una reconstrucción completa solo interesan las macroceldas con algo dentro. Recorrer
		# el volumen entero eran ~1,9 M de llamadas vacías por mapa importado.
		var dimensions := shape.data.get_macro_dimensions()
		var plane := dimensions.x * dimensions.y
		for macro_index in shape.data.get_occupied_macros():
			blocks[Vector3i(
				(macro_index % dimensions.x) / block,
				((macro_index / dimensions.x) % dimensions.y) / block,
				(macro_index / plane) / block
			)] = true
	var result: Array[Vector3i] = []
	result.assign(blocks.keys())
	return result


func _rebuild_static_collision_block(
	shape: VoxelShape3D, macro: Vector3i, block: int, lod: int
) -> void:
	# La mascara sale de la paleta convertida de Teardown y deja fuera el decorado sin fisica y el
	# follaje: ver `TeardownPalette.WALK_THROUGH`. Un `.vox` de terceros no la trae y colisiona
	# entero.
	var faces := shape.data.build_macro_faces(
		macro, shape.voxel_size, block, lod, TeardownPalette.mask_for(shape)
	)
	_install_static_collision_faces(shape, macro, faces)


## Instala un bloque ya mallado. La importación normal y el caché compilado convergen aquí, de modo
## que ambos producen exactamente los mismos shards, keys y recursos de Jolt. Al destruirse una
## macrocelda, `_rebuild_static_collision_block` vuelve a generar solo ese bloque desde voxeles vivos.
func _install_static_collision_faces(
	shape: VoxelShape3D, macro: Vector3i, faces: PackedVector3Array
) -> void:
	var key := _static_collision_key(shape, macro)
	var collision: CollisionShape3D = _macro_collisions.get(key)
	if faces.is_empty():
		if collision != null:
			var shard := collision.get_parent() as StaticBody3D
			var shard_key := String(collision.get_meta("static_shard_key", ""))
			_collision_nodes.erase(collision)
			collision.queue_free()
			_macro_collisions.erase(key)
			# El hijo sigue contado hasta que corre queue_free; uno significa que esta región quedó
			# vacía y su Body también puede salir del broadphase.
			if shard != null and shard != _physics_body and shard.get_child_count() <= 1:
				_static_collision_shards.erase(shard_key)
				shard.queue_free()
		return
	var shard_key := _static_collision_shard_key(shape, macro)
	var parent: Node = collision.get_parent() if collision != null \
		else _static_collision_shard(shape, macro)
	var installed := _collision_installer.install_concave(
		parent, collision, shape, faces, shard_key, macro
	)
	if collision == null and installed != null:
		collision = installed
		_collision_nodes.append(collision)
		_macro_collisions[key] = collision
	if collision != null and is_instance_valid(collision):
		collision.disabled = false


## Extrae las caras iniciales ya fusionadas para el compilado offline del mapa. No se guardan RIDs
## ni nodos de PhysicsServer: esos identificadores solo valen durante este proceso. Se persiste la
## entrada geométrica pura que permite reconstruirlos sin repetir `build_macro_faces`.
func export_baked_static_collision(shape: VoxelShape3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var prefix := "%d:" % shape.get_instance_id()
	for key: String in _macro_collisions:
		if not key.begins_with(prefix):
			continue
		var collision := _macro_collisions[key] as CollisionShape3D
		if collision == null or not collision.shape is ConcavePolygonShape3D:
			continue
		result.append({
			"macro": collision.get_meta("static_macro", Vector3i.ZERO),
			"faces": (collision.shape as ConcavePolygonShape3D).get_faces(),
		})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left: Vector3i = a.macro
		var right: Vector3i = b.macro
		return left.z < right.z or (left.z == right.z and (
			left.y < right.y or (left.y == right.y and left.x < right.x)
		))
	)
	return result


## Restaura el producto de `export_baked_static_collision`. Las Shapes siguen siendo destructibles:
## el caché solo sustituye la construcción inicial y no participa en actualizaciones posteriores.
func import_baked_static_collision(
	shape: VoxelShape3D, records: Array
) -> void:
	if state == State.DYNAMIC or not collision_enabled:
		return
	last_faces_ms = 0.0
	for record: Dictionary in records:
		var faces: PackedVector3Array = record.get("faces", PackedVector3Array())
		if faces.is_empty():
			continue
		_install_static_collision_faces(
			shape, record.get("macro", Vector3i.ZERO) as Vector3i, faces
		)


static func _static_collision_key(shape: VoxelShape3D, macro: Vector3i) -> String:
	return "%d:%d:%d:%d" % [shape.get_instance_id(), macro.x, macro.y, macro.z]


static func _static_collision_shard_key(shape: VoxelShape3D, macro: Vector3i) -> String:
	var region := Vector3i(
		macro.x / STATIC_COLLISION_SHARD_SPAN,
		macro.y / STATIC_COLLISION_SHARD_SPAN,
		macro.z / STATIC_COLLISION_SHARD_SPAN
	)
	return "%d:%d:%d:%d" % [shape.get_instance_id(), region.x, region.y, region.z]


func _static_collision_shard(shape: VoxelShape3D, macro: Vector3i) -> StaticBody3D:
	var key := _static_collision_shard_key(shape, macro)
	var existing := _static_collision_shards.get(key) as StaticBody3D
	if existing != null and is_instance_valid(existing):
		return existing
	var shard := StaticBody3D.new()
	shard.name = "StaticCollisionRegion"
	if _physics_body is CollisionObject3D:
		shard.collision_layer = (_physics_body as CollisionObject3D).collision_layer
		shard.collision_mask = (_physics_body as CollisionObject3D).collision_mask
	add_child(shard)
	_static_collision_shards[key] = shard
	return shard


func _find_voxel_world() -> VoxelWorld3D:
	var node: Node = get_parent()
	while node != null:
		if node is VoxelWorld3D:
			return node
		node = node.get_parent()
	return null


func rebuild_dynamic_collision(max_boxes := 128) -> void:
	if not _physics_body is RigidBody3D or not collision_enabled:
		return
	if _physics_body is VoxelVehicle3D:
		max_boxes = mini(max_boxes, VoxelVehicle3D.COLLISION_BOX_BUDGET)
	_pending_dynamic_collision = false
	var started := Time.get_ticks_usec()
	_clear_collisions()
	var shapes := get_shapes()
	var installed: Dictionary = _collision_installer.install_dynamic_boxes(
		_physics_body, shapes, max_boxes
	)
	for collision_variant: Variant in installed.nodes:
		var collision := collision_variant as CollisionShape3D
		if collision != null:
			_collision_nodes.append(collision)
	compound_boxes = int(installed.count)
	_apply_mass_properties()
	# Se sella cada Shape del cuerpo, no solo las que el instalador llego a meter: una Shape truncada
	# por el presupuesto de cajas se quedaba en revision 0 y el registro la reportaba desincronizada
	# para siempre.
	for shape in shapes:
		shape.collision_revision = shape.content_revision()
	collision_rebuild_ms = (Time.get_ticks_usec() - started) / 1000.0
	runtime_state_changed.emit(self)


## Recalcula masa, centro e inercia sin tocar el compound. Es deliberadamente público para ajustes
## semánticos de importación —por ejemplo, una puerta voxel representa una hoja hueca, no un bloque
## macizo— que no cambian ni una celda ni una caja de colisión.
func refresh_mass_properties() -> void:
	_apply_mass_properties()


func apply_explosion_impulse(center: Vector3, energy: float, radius: float) -> void:
	if not _physics_body is RigidBody3D:
		return
	if collision_handoff_pending:
		_handoff_impulses.append({"center": center, "energy": energy, "radius": radius})
		return
	var rigid := _physics_body as RigidBody3D
	# Fragment Bodies keep Shapes in world-preserving local transforms, so the RigidBody origin can
	# remain at the VoxelWorld origin. Use its actual center of mass or distant buildings never
	# receive the impulse that should make a newly fractured support topple.
	var world_center_of_mass := rigid.to_global(rigid.center_of_mass)
	var offset := world_center_of_mass - center
	var distance := offset.length()
	var structural_detachment := structural and continuous_collision
	var surface_distance := INF
	if structural_detachment:
		for shape in get_shapes():
			var bounds := shape.world_bounds()
			surface_distance = minf(
				surface_distance,
				center.distance_to(center.clamp(bounds.position, bounds.end))
			)
	var effective_distance := minf(distance, surface_distance) \
		if structural_detachment else distance
	if effective_distance >= radius or distance < 0.001:
		return
	var falloff := 1.0 - effective_distance / radius
	rigid.apply_central_impulse(offset / distance * energy * rigid.mass * falloff * 0.12)
	if structural_detachment:
		# Un poste perfectamente vertical puede aterrizar otra vez sobre su tocón si solo recibe fuerza
		# central. Una componente horizontal determinista representa la asimetría real del corte y le da
		# el par mínimo para volcar, sin depender del orden de los Bodies ni de ruido aleatorio.
		var horizontal := Vector3(offset.x, 0.0, offset.z)
		if horizontal.length_squared() < 0.0001:
			var angle := float(get_instance_id() % 6283) * 0.001
			horizontal = Vector3(cos(angle), 0.0, sin(angle))
		var tip_axis := Vector3.UP.cross(horizontal.normalized()).normalized()
		rigid.apply_torque_impulse(tip_axis * energy * rigid.mass * falloff * 0.25)
	rigid.sleeping = false
	last_interaction_msec = Time.get_ticks_msec()
	runtime_state_changed.emit(self)


## El RigidBody solo captura datos del solver. La mutación voxel se difiere y pasa por el World,
## que elimina contactos duplicados y limita cuántos cráteres físicos pueden cocinarse por frame.
func report_physics_impact(
	collider: Object, point: Vector3, impulse: float, relative_speed: float
) -> void:
	if state != State.DYNAMIC or collision_handoff_pending or impulse <= 0.0:
		return
	var voxel_world := _find_voxel_world()
	if voxel_world != null:
		voxel_world.queue_physics_impact(self, collider, point, impulse, relative_speed)


func _create_physics_body(dynamic: bool) -> void:
	if dynamic:
		if not _vehicle_descriptor.is_empty():
			var vehicle := VoxelVehicle3D.new()
			vehicle.voxel_owner = self
			vehicle.continuous_cd = continuous_collision
			_physics_body = vehicle
		else:
			var impact_body := VoxelImpactRigidBody3D.new()
			impact_body.voxel_owner = self
			impact_body.continuous_cd = continuous_collision
			# Ocho contactos bastan para sumar una cara completa de un compound sin el coste de reportar
			# las decenas de puntos que genera una torre al aterrizar.
			impact_body.contact_monitor = true
			impact_body.max_contacts_reported = 8
			_physics_body = impact_body
	else:
		_physics_body = StaticBody3D.new()
	_physics_body.name = "JoltBody"
	add_child(_physics_body)
	physics_generation += 1


func _replace_physics_body(dynamic: bool) -> void:
	var shapes := get_shapes()
	for shape in shapes:
		shape.reparent(self, true)
	_clear_collisions()
	# La colision que sellaba estas revisiones acaba de irse con el cuerpo anterior.
	for shape in shapes:
		shape.collision_revision = 0
	if _physics_body != null:
		_physics_body.queue_free()
	_create_physics_body(dynamic)
	if dynamic and not _vehicle_descriptor.is_empty():
		var vehicle_transform: Transform3D = _vehicle_descriptor.get(
			"physics_transform", Transform3D.IDENTITY
		)
		_physics_body.global_transform = vehicle_transform
	for shape in shapes:
		shape.reparent(_physics_body, true)


func _clear_collisions() -> void:
	_collision_installer.queue_free_nodes(_collision_nodes)
	for shard: StaticBody3D in _static_collision_shards.values():
		if is_instance_valid(shard):
			shard.queue_free()
	_collision_nodes.clear()
	_macro_collisions.clear()
	_static_collision_shards.clear()
	_pending_static_collisions.clear()
	_pending_static_collision_keys.clear()
	compound_boxes = 0


func _apply_mass_properties() -> void:
	if not _physics_body is RigidBody3D:
		return
	_mass_properties.apply(
		_physics_body as RigidBody3D, get_shapes(), _physics_body is VoxelVehicle3D
	)


## Los postes tienen una inercia diminuta alrededor de su eje largo y enorme alrededor de los otros
## dos. Esa anisotropía permite reconocerlos sin tags del mapa y disipar el péndulo de cables/choques
## sin amortiguar cajas, vehículos ni cascotes compactos.
static func structural_damping_for_inertia(body_inertia: Vector3) -> Vector2:
	return VoxelMassProperties.damping_for_inertia(body_inertia)


func _on_shape_voxels_changed(
	_world_aabb: AABB, dirty_min: Vector3i, dirty_max: Vector3i, shape: VoxelShape3D
) -> void:
	last_interaction_msec = Time.get_ticks_msec()
	# Que a un prop le arranquen voxeles lo despierta: perder masa cambia su equilibrio.
	if state == State.DYNAMIC:
		(_physics_body as RigidBody3D).sleeping = false
		queue_dynamic_collision_rebuild()
	else:
		queue_static_collision_rebuild(shape, dirty_min, dirty_max)
	runtime_state_changed.emit(self)
