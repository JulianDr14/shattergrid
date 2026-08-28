class_name VoxelTank3D
extends Node
## Tanque conducible de dos piezas: el casco lleva el tren de orugas y la torreta persigue la mira.
##
## La corona sigue siendo una bisagra física para que la torreta tenga colisión y masa reales, pero
## no es una unión estructural rompible. El controlador la libera únicamente al recibir una
## explosión; acelerar, pivotar o atravesar una pared nunca puede arrancarla por error.

const GROUP := "voxel_tanks"
const HULL_PATH := "res://assets/models/tank/tanque_casco.vox"
const TURRET_PATH := "res://assets/models/tank/tanque_torreta.vox"

## Punto de giro medido desde la esquina mínima del volumen, no desde el origen del `.vox`: el
## decoder recorta cada modelo a su contenido, así que el origen del archivo se pierde al importar.
## Los imprime `tools/make_tank_vox.py` si cambia la geometría.
const HULL_RING_OFFSET := Vector3(4.15, 1.85, 1.90)
const TURRET_PIVOT_OFFSET := Vector3(3.35, 0.05, 1.60)

## El arte voxel de 10 cm es macizo; estos factores dejan el conjunto cerca de 60 t.
const HULL_FILL := 0.13
const TURRET_FILL := 0.17

## Control de orugas: A/D piden velocidad angular directamente. Limitar aceleración conserva peso,
## pero no depende de que un par pequeño consiga vencer de casualidad la fricción de seis ruedas.
const TURN_MAX_YAW_SPEED := 1.05
const TURN_ACCELERATION := 2.8
const TURN_BRAKING := 4.2
const TRACK_FORWARD_SPEED := 10.5
const TRACK_REVERSE_SPEED := 5.5
const TRACK_ACCELERATION := 3.8
const TRACK_BRAKING := 5.0
const WHEEL_X := [1.6, 4.0, 6.4]
const WHEEL_Z := [0.65, 3.15]
const WHEEL_Y := 0.30

const YAW_SPEED := 0.72
const YAW_GAIN := 3.4
const YAW_MAX_IMPULSE := 90000.0
const MOTOR_SIGN := -1.0

## La torreta sale hacia arriba y hereda el movimiento del casco cuando la onda rompe la corona.
const TURRET_POP_SPEED := 5.2
const TURRET_POP_SPIN := 2.4

var target_yaw := 0.0
var hull: VoxelBody3D
var turret: VoxelBody3D
var vehicle: VoxelVehicle3D

var _joint: HingeJoint3D
var _joint_record := {}
var _joints: VoxelJoints
var _gunner: Node3D


## Crea el tanque y toda su infraestructura dentro de `world`. La escena principal solo decide dónde
## aparece; cámara, puntería, tren de orugas, corona y reacción a explosiones pertenecen al tanque.
static func spawn(
	world: VoxelWorld3D, origin: Vector3, gunner: Node3D = null
) -> VoxelTank3D:
	var tank := VoxelTank3D.new()
	tank.name = "VoxelTank3D"
	tank.add_to_group(GROUP)
	tank._gunner = gunner
	tank._joints = _tank_joints(world)
	tank.hull = world.create_body_from_asset(
		HULL_PATH, Transform3D(Basis.IDENTITY, origin)
	)
	tank.turret = world.create_body_from_asset(TURRET_PATH)
	if tank.hull == null or tank.turret == null or tank._joints == null:
		tank.free()
		return null

	var pivot := _shape_point(tank.hull, HULL_RING_OFFSET)
	tank.turret.transform.origin += pivot - _shape_point(tank.turret, TURRET_PIVOT_OFFSET)
	tank.turret.force_update_transform()

	_make_dynamic(tank.hull, HULL_FILL)
	_make_dynamic(tank.turret, TURRET_FILL)
	tank.vehicle = tank.hull.configure_vehicle(_tank_vehicle_descriptor(tank.hull))
	if tank.vehicle != null:
		tank.vehicle.display_name = "tanque"
		tank.vehicle.set_joint_registry(tank._joints)
		# Las dos orugas apoyan muchas cajas contra el suelo. Ocho contactos se consumían enteros en
		# esa base plana y Jolt no alcanzaba a informar el morro contra un muro.
		tank.vehicle.max_contacts_reported = 32
		tank.turret.vehicle_impact_owner = tank.hull
		# Las orugas forman parte del arte/collider voxel y rozan el suelo además de las ruedas de
		# suspensión invisibles. Un material de casco deslizante evita que ese contacto doble clave el
		# tanque; el agarre longitudinal sigue viniendo de las seis ruedas motrices.
		var skid_material := PhysicsMaterial.new()
		skid_material.friction = 0.12
		skid_material.bounce = 0.0
		tank.vehicle.physics_material_override = skid_material

	var hinge := HingeJoint3D.new()
	hinge.name = "TorretaHinge"
	world.add_child(hinge)
	# El eje de una bisagra de Godot es su +Z local; la torreta gira sobre el +Y del mundo.
	var frame := Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), pivot)
	hinge.global_transform = frame
	hinge.node_a = hinge.get_path_to(tank.hull.get_physics_body())
	hinge.node_b = hinge.get_path_to(tank.turret.get_physics_body())
	hinge.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	hinge.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, YAW_MAX_IMPULSE)
	tank._joint = hinge

	tank._joint_record = {
		"joint": hinge,
		"attributes": {"type": "hinge", "size": "0.9"},
		"transform": frame,
		"owner_body": tank.hull,
		"other_body": tank.turret,
		"broken": false,
		# No se rompe por separación ni por daño de material: `_on_explosion_started` es la única
		# transición válida de torreta montada a torreta libre.
		"breakable": false,
	}
	tank._joints.add_records([tank._joint_record] as Array[Dictionary])
	if not world.explosion_started.is_connected(tank._on_explosion_started):
		world.explosion_started.connect(tank._on_explosion_started)

	world.add_child(tank)
	tank.set_process(gunner != null)
	# La puntería necesita `_process` solo con jugador; las orugas siempre necesitan su reloj físico,
	# incluso si el tanque nació vacío y se ocupa varios segundos después.
	tank.set_physics_process(true)
	return tank


static func _tank_joints(world: VoxelWorld3D) -> VoxelJoints:
	var joints := world.get_node_or_null("VoxelTankJoints") as VoxelJoints
	if joints != null:
		return joints
	joints = VoxelJoints.new()
	joints.name = "VoxelTankJoints"
	world.add_child(joints)
	joints.setup(world)
	return joints


func hull_transform() -> Transform3D:
	if hull == null or not is_instance_valid(hull):
		return Transform3D.IDENTITY
	var physics := hull.get_physics_body()
	return Transform3D.IDENTITY if physics == null else physics.global_transform


func yaw() -> float:
	if hull == null or turret == null or not is_instance_valid(hull) \
			or not is_instance_valid(turret):
		return 0.0
	var a := hull.get_physics_body()
	var b := turret.get_physics_body()
	if a == null or b == null:
		return 0.0
	return wrapf(_plane_yaw(b.global_basis.x) - _plane_yaw(a.global_basis.x), -PI, PI)


func is_turret_attached() -> bool:
	return not _joint_record.is_empty() and not bool(_joint_record.get("broken", false)) \
		and _joint != null and is_instance_valid(_joint)


## Distancia entre los dos anclajes físicos de la corona, útil para verificar el tanque bajo carga.
func turret_anchor_separation() -> float:
	if _joint_record.is_empty() or not is_instance_valid(hull) or not is_instance_valid(turret):
		return INF
	var hull_physics := hull.get_physics_body()
	var turret_physics := turret.get_physics_body()
	if hull_physics == null or turret_physics == null:
		return INF
	var local_a: Transform3D = _joint_record.get("local_a", Transform3D.IDENTITY)
	var local_b: Transform3D = _joint_record.get("local_b", Transform3D.IDENTITY)
	return (hull_physics.global_transform * local_a).origin.distance_to(
		(turret_physics.global_transform * local_b).origin
	)


static func _plane_yaw(direction: Vector3) -> float:
	return atan2(-direction.z, direction.x)


static func _tank_vehicle_descriptor(body: VoxelBody3D) -> Dictionary:
	var bounds := body.get_shapes()[0].world_bounds()
	var wheels: Array = []
	for x in WHEEL_X:
		for z in WHEEL_Z:
			wheels.append({
				"attributes": {"steer": "0", "drive": "1", "travel": "-0.08 0.16"},
				"transform": Transform3D(
					Basis.IDENTITY, bounds.position + Vector3(x, WHEEL_Y, z)
				),
				"shapes": [],
			})
	return {
		"attributes": {
			"topspeed": 45.0,
			"acceleration": 7.2,
			"strength": 12.0,
			# El casco mide 3,8 m de ancho: el perfil de coche (hasta 2,9 m de diámetro) deja
			# dos jambas invisibles agarrando las orugas aunque el centro del muro desaparezca.
			"impact_radius": 2.35,
			"spring": 2.2,
			"damping": 2.0,
			"friction": 2.2,
			"antiroll": 0.9,
			# Perfil arcade específico: suficientemente cerca para sentir el peso, con FOV menos
			# deformado y zoom amplio. Los coches authored conservan el perfil automático.
			"camera_distance": 8.4,
			"camera_height": 1.55,
			"camera_max_distance": 14.0,
			"camera_fov": 78.0,
		},
		# El morro del modelo mira a +X y `VehicleBody3D` avanza hacia el +Z de este marco.
		"physics_transform": Transform3D(
			Basis(Quaternion(Vector3.UP, PI * 0.5)), bounds.get_center()
		),
		"seat_transform": Transform3D(Basis.IDENTITY, bounds.position + Vector3(
			bounds.size.x * 0.5, bounds.size.y + 0.6, bounds.size.z * 0.5
		)),
		"body": body,
		"visual_body": null,
		"wheels": wheels,
		"lights": [],
		"drivable": true,
	}


func _process(_delta: float) -> void:
	if _gunner == null or not is_instance_valid(_gunner) or not is_turret_attached():
		return
	if vehicle == null or not is_instance_valid(vehicle) or not vehicle.has_driver():
		return
	var camera := _gunner.get("camera") as Camera3D
	if camera == null or not is_instance_valid(camera):
		return
	var hull_now := hull_transform()
	target_yaw = aim_yaw(_camera_aim_point(camera) - hull_now.origin, hull_now.basis)


func _physics_process(delta: float) -> void:
	_drive_tracks(delta)
	if not is_turret_attached() or not is_instance_valid(hull) or not is_instance_valid(turret):
		return
	var error := wrapf(target_yaw - yaw(), -PI, PI)
	_joint.set_param(
		HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
		MOTOR_SIGN * clampf(error * YAW_GAIN, -YAW_SPEED, YAW_SPEED)
	)
	if absf(error) > 0.01:
		hull.wake_for_interaction()
		turret.wake_for_interaction()


## Diferencial de orugas: W/S son tracción longitudinal; A/D piden yaw aun desde parado.
func _drive_tracks(delta: float) -> void:
	if vehicle == null or not is_instance_valid(vehicle) or not vehicle.has_active_controls():
		return
	# VehicleWheel3D aporta suspensión y contacto, pero una oruga no transmite fuerza como una rueda
	# libre. Aplicar una aceleración longitudinal acotada al casco da salida fiable desde parado y
	# conserva masa, inercia y respuesta a impactos del rigid body (no teletransporta el tanque).
	var throttle := vehicle.control_throttle_input()
	var forward := vehicle.forward_direction()
	var longitudinal_speed := vehicle.linear_velocity.dot(forward)
	var speed_limit := TRACK_FORWARD_SPEED if throttle >= 0.0 else TRACK_REVERSE_SPEED
	var target_speed := throttle * speed_limit
	var drive_acceleration := TRACK_ACCELERATION \
		if not is_zero_approx(throttle) else TRACK_BRAKING
	var next_speed := move_toward(
		longitudinal_speed, target_speed, drive_acceleration * delta
	)
	vehicle.linear_velocity += forward * (next_speed - longitudinal_speed)
	var steer := vehicle.control_steer_input()
	var up := vehicle.global_basis.y.normalized()
	var current := vehicle.angular_velocity.dot(up)
	var target := steer * TURN_MAX_YAW_SPEED
	var acceleration := TURN_ACCELERATION if not is_zero_approx(steer) else TURN_BRAKING
	var next := move_toward(current, target, acceleration * delta)
	if not is_equal_approx(current, next):
		vehicle.angular_velocity += up * (next - current)
		vehicle.sleeping = false


func _camera_aim_point(camera: Camera3D) -> Vector3:
	var from := camera.global_position
	var direction := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * 500.0)
	query.collide_with_areas = false
	if vehicle != null and is_instance_valid(vehicle):
		query.exclude = vehicle.get_camera_collision_rids()
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if not hit.is_empty() else from + direction * 500.0


func _on_explosion_started(center: Vector3, radius: float, _energy: float) -> void:
	if not is_turret_attached() or vehicle == null or not is_instance_valid(vehicle):
		return
	var bounds := vehicle.get_world_bounds()
	var nearest := center.clamp(bounds.position, bounds.end)
	if center.distance_to(nearest) > radius:
		return
	_detach_turret(center)


func _detach_turret(blast_center: Vector3) -> void:
	if not is_turret_attached():
		return
	_joints.break_record(_joint_record)
	_joint = null
	_launch_turret_after_release(blast_center)


func _launch_turret_after_release(blast_center: Vector3) -> void:
	# `Joint3D.queue_free()` se materializa al cerrar el frame. Esperar un tick evita que el solver
	# de la bisagra todavía viva cancele el impulso que debe hacer legible la explosión.
	await get_tree().physics_frame
	if turret == null or not is_instance_valid(turret) \
			or vehicle == null or not is_instance_valid(vehicle):
		return
	var rigid := turret.get_physics_body() as RigidBody3D
	if rigid == null:
		return
	var away := rigid.global_position - blast_center
	away.y = 0.0
	if away.length_squared() < 0.01:
		away = vehicle.global_basis.x
	away = away.normalized()
	# La torreta hereda la velocidad del casco y suma el pop. Asignar el estado de separación evita
	# heredar la corrección violenta que el solver de la bisagra pudo acumular en su último tick.
	rigid.linear_velocity = vehicle.linear_velocity + Vector3.UP * TURRET_POP_SPEED + away * 2.0
	rigid.angular_velocity = vehicle.angular_velocity \
		+ vehicle.global_basis.z.normalized() * TURRET_POP_SPIN
	rigid.sleeping = false


## Yaw que hay que pedirle a la corona para que el cañón (+X del modelo) mire hacia `aim`.
static func aim_yaw(aim: Vector3, hull_basis: Basis) -> float:
	return wrapf(_plane_yaw(aim) - _plane_yaw(hull_basis.x), -PI, PI)


static func _shape_point(body: VoxelBody3D, offset: Vector3) -> Vector3:
	return body.get_shapes()[0].world_bounds().position + offset


static func _make_dynamic(body: VoxelBody3D, fill: float) -> void:
	for shape in body.get_shapes():
		shape.physical_fill_scale = fill
	body.make_dynamic()
