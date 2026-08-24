class_name VoxelJoints
extends Node
## Los `<joint>` del mapa: sobreviven a que un cuerpo cambie de `PhysicsBody` por debajo, se
## transfieren al trozo que se queda el anclaje cuando algo se parte, y se rompen solo cuando
## desaparecen los voxeles que los sujetan o cuando la fuerza los revienta.
##
## Es el modelo de Teardown: al destruir, "los joints pueden transferirse a otras Shapes, soltarse o
## desactivarse del todo", y cada rotura viaja como una orden explicita. Transferirse era la mitad
## que faltaba. Un `Joint3D` de Godot guarda dos NodePath a dos `PhysicsBody3D`, y
## `VoxelBody3D.make_dynamic()` reemplaza el suyo entero: volar la base de un poste lo pasaba a
## dinamico y con eso mataba en silencio la union con la tuberia, aunque el punto de union estuviera
## intacto tres metros mas arriba. Ahora se reata al cuerpo nuevo en el mismo frame.
##
## Las puertas ya rompian sus bisagras por su cuenta ([VoxelDoor3D]) y comparten este mismo registro,
## asi que lo que rompa uno lo ve el otro.

signal record_broken(record: Dictionary)

## Separacion entre los dos anclajes a partir de la cual se da la union por reventada. Un joint sano
## los mantiene encima; que se separen tanto solo pasa cuando el solver no puede con la carga, que es
## el `strength` de Teardown medido por lo unico que Godot expone de una restriccion: cuanto la viola.
const BREAK_SEPARATION := 0.5

## Registros `{joint, attributes, transform, owner_body, other_body, broken}` que crea el importador,
## mas `local_a`/`local_b`: el anclaje en el espacio de cada `PhysicsBody3D`, para saber donde esta
## cuando el cuerpo se ha movido y para reconstruir el marco al reatar.
var _records: Array[Dictionary] = []
var _by_body := {}
var broken_by_destruction := 0
var broken_by_force := 0


func setup(world: VoxelWorld3D) -> void:
	world.body_split.connect(_on_body_split)
	world.body_unregistered.connect(_on_body_unregistered)
	world.voxel_impact.connect(
		func(center: Vector3, _removed: int, blast_radius: float) -> void:
			on_impact(center, blast_radius)
	)


func add_records(records: Array[Dictionary]) -> void:
	for record in records:
		_bind(record)
	_records.append_array(records)


func count() -> int:
	return _records.size()


func live_count() -> int:
	var live := 0
	for record in _records:
		if VoxelDoor3D._record_joint_is_live(record):
			live += 1
	return live


## Rompe los joints que la onda alcanza y que ya no tienen material a los dos lados. Solo mira los
## que caen dentro del radio, asi que un disparo cuesta lo que cuestan los joints de al lado.
func on_impact(center: Vector3, blast_radius: float) -> int:
	var broken := 0
	for record in _records:
		if not VoxelDoor3D._record_joint_is_live(record):
			continue
		var point := VoxelDoor3D._record_position(record)
		var size := VoxelDoor3D._record_size(record)
		if center.distance_to(point) > blast_radius + size:
			continue
		# Un joint sigue vivo mientras quede material a los dos lados. Si un lado se quedo sin
		# voxeles alrededor del anclaje, ya no hay nada de que agarrarse.
		if _side_has_material(record.get("owner_body"), point, size) \
				and _side_has_material(record.get("other_body"), point, size):
			continue
		break_record(record)
		broken_by_destruction += 1
		broken += 1
	return broken


## Lo unico que revienta una union intacta es la fuerza. Godot no expone la fuerza de una
## restriccion, pero si su violacion: cuanto se separan los dos anclajes es proporcional a la carga
## que el solver no consigue aguantar.
func _physics_process(_delta: float) -> void:
	for record in _records:
		if not VoxelDoor3D._record_joint_is_live(record):
			continue
		var owner_body := record.get("owner_body") as VoxelBody3D
		var other_body := record.get("other_body") as VoxelBody3D
		if owner_body == null or other_body == null:
			continue
		# Dos cuerpos dormidos no se estan separando de nada.
		if not owner_body.is_awake() and not other_body.is_awake():
			continue
		var a := _anchor_world(owner_body, record.get("local_a"))
		var b := _anchor_world(other_body, record.get("local_b"))
		if a.distance_to(b) <= BREAK_SEPARATION:
			continue
		break_record(record)
		broken_by_force += 1


func break_record(record: Dictionary) -> bool:
	if bool(record.get("broken", false)):
		return false
	var joint: Joint3D = record.get("joint")
	if joint != null and is_instance_valid(joint):
		joint.queue_free()
	record["joint"] = null
	record["broken"] = true
	# Los dos cuerpos tienen que enterarse: el que se suelta cae, y el que lo sujetaba pierde peso.
	# Dormidos no notarian nada, que es como se quedaban flotando.
	for side in [record.get("owner_body"), record.get("other_body")]:
		var body := side as VoxelBody3D
		if body != null and is_instance_valid(body):
			body.release_physics_hold(record.get("physics_hold_key", ""))
			_unindex(record, body)
			body.wake_for_interaction()
	record_broken.emit(record)
	return true


## Un cuerpo que pasa a dinamico -o que se retira a estatico- estrena `PhysicsBody3D`, y los NodePath
## del joint apuntan al viejo, que acaba de morir. Se reatan en el acto, antes de que el cuerpo se
## haya movido, asi que el marco sigue siendo el bueno.
func _on_body_state_changed(body: VoxelBody3D) -> void:
	for record: Dictionary in _by_body.get(body.get_instance_id(), []):
		_rebind(record)


## Al partirse un cuerpo, el anclaje se va con el trozo que se quedo su material. Es el "los joints
## pueden transferirse a otras Shapes" de Teardown: la union no muere por haberse partido el cuerpo,
## cambia de dueño.
func _on_body_split(source: VoxelBody3D, created: Array[VoxelBody3D]) -> void:
	if source == null:
		return
	for record: Dictionary in _by_body.get(source.get_instance_id(), []).duplicate():
		if not VoxelDoor3D._record_joint_is_live(record):
			continue
		var point := VoxelDoor3D._record_position(record)
		var size := VoxelDoor3D._record_size(record)
		var heir := source
		if not VoxelDoor3D._body_has_material_near(source, point, size):
			heir = null
			for candidate in created:
				if VoxelDoor3D._body_has_material_near(candidate, point, size):
					heir = candidate
					break
		if heir == null or heir == source:
			continue
		var side := "owner_body" if record.get("owner_body") == source else "other_body"
		record[side] = heir
		source.release_physics_hold(record.get("physics_hold_key", ""))
		_unindex(record, source)
		heir.acquire_physics_hold(record.get("physics_hold_key", ""))
		_index(record, heir)
		_rebind(record)


func _on_body_unregistered(body: VoxelBody3D) -> void:
	if body == null:
		return
	# Un registro que sobrevivió al `body_split` no tiene heredero material. Mantenerlo dejaría un
	# NodePath y una retención apuntando a un Body que está a punto de desaparecer.
	for record: Dictionary in _by_body.get(body.get_instance_id(), []).duplicate():
		break_record(record)
	_by_body.erase(body.get_instance_id())


func _bind(record: Dictionary) -> void:
	var owner_body := record.get("owner_body") as VoxelBody3D
	var other_body := record.get("other_body") as VoxelBody3D
	if owner_body == null or other_body == null:
		return
	var frame: Transform3D = record.get("transform", Transform3D.IDENTITY)
	if not record.has("physics_hold_key"):
		var joint := record.get("joint") as Joint3D
		record["physics_hold_key"] = "joint:%d" % (
			joint.get_instance_id() if joint != null else Time.get_ticks_usec()
		)
	record["local_a"] = _to_local(owner_body, frame)
	record["local_b"] = _to_local(other_body, frame)
	for body in [owner_body, other_body]:
		body.acquire_physics_hold(record.physics_hold_key)
		_index(record, body)
		if not body.body_state_changed.is_connected(_on_body_state_changed):
			body.body_state_changed.connect(_on_body_state_changed)


func _index(record: Dictionary, body: VoxelBody3D) -> void:
	var key := body.get_instance_id()
	var records: Array = _by_body.get(key, [])
	if not records.has(record):
		records.append(record)
	_by_body[key] = records


func _unindex(record: Dictionary, body: VoxelBody3D) -> void:
	var key := body.get_instance_id()
	var records: Array = _by_body.get(key, [])
	records.erase(record)
	if records.is_empty():
		_by_body.erase(key)
	else:
		_by_body[key] = records


func _rebind(record: Dictionary) -> void:
	var joint := record.get("joint") as Joint3D
	if joint == null or not is_instance_valid(joint):
		return
	var owner_body := record.get("owner_body") as VoxelBody3D
	var other_body := record.get("other_body") as VoxelBody3D
	if owner_body == null or other_body == null:
		return
	var a := owner_body.get_physics_body()
	var b := other_body.get_physics_body()
	if a == null or b == null or a == b:
		break_record(record)
		return
	# El marco se saca del anclaje tal y como esta AHORA, no de donde estaba al importar: Godot
	# reconstruye la restriccion con la transformada que el nodo tenga al asignar los NodePath, y
	# reatar con el marco viejo daria un tiron para recolocar los cuerpos en la pose de origen.
	joint.global_transform = (a.global_transform * (record.get("local_a") as Transform3D)) \
		.orthonormalized()
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)


static func _to_local(body: VoxelBody3D, frame: Transform3D) -> Transform3D:
	var physics := body.get_physics_body()
	return frame if physics == null else physics.global_transform.affine_inverse() * frame


static func _anchor_world(body: VoxelBody3D, local: Variant) -> Vector3:
	var physics := body.get_physics_body()
	if physics == null or not (local is Transform3D):
		return Vector3.ZERO
	return (physics.global_transform * (local as Transform3D)).origin


static func _side_has_material(side: Variant, point: Vector3, radius: float) -> bool:
	var body := side as VoxelBody3D
	return VoxelDoor3D._body_has_material_near(body, point, radius)
