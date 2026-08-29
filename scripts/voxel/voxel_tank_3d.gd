class_name VoxelTank3D
extends Node
## Tanque conducible de tres piezas: el casco lleva el tren de orugas, la torreta persigue la mira
## en su eje vertical y el cañón cabecea sobre sus muñones.
##
## Corona y muñones son bisagras físicas para que torreta y cañón tengan colisión y masa reales,
## pero ninguna es una unión estructural rompible: el tanque nunca se desarma. Acelerar, pivotar,
## atravesar una pared o comerse una explosión dejan la torreta donde está.

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

## Distancia minima a la que converge la mira. La camara esta por encima del canon, asi que apuntar a
## un muro a tres metros pedia una elevacion absurda y el canon se iba al cielo: es el defecto de
## paralaje clasico de la vista arcade. Por debajo de este radio se ignora el impacto y se apunta a la
## linea de vision, que es lo que el jugador cree estar viendo.
const AIM_MIN_CONVERGENCE := 15.0
const AIM_MAX_CONVERGENCE := 500.0

## Constante de tiempo del suavizado del punto de mira. Sin ella, cruzar el borde de un muro salta de
## 4 m a 500 m en un frame y la torreta pega un latigazo.
const AIM_SMOOTH := 9.0

## Control de orugas: A/D piden velocidad angular directamente. Limitar aceleración conserva peso,
## pero no depende de que un par pequeño consiga vencer de casualidad la fricción de seis ruedas.
const TURN_MAX_YAW_SPEED := 1.05
const TURN_ACCELERATION := 2.8
const TURN_BRAKING := 4.2
const TRACK_FORWARD_SPEED := 10.5
const TRACK_REVERSE_SPEED := 5.5
const TRACK_ACCELERATION := 3.8
const TRACK_BRAKING := 5.0
## Los rodillos de rodaje ya están dibujados en el casco: siete discos de 9 celdas por banda, con
## paso de 9 celdas. Se sacan a Shapes propias para que la suspensión pueda moverlos. Las celdas van
## en el orden del decoder: largo, alto, lateral.
const ROAD_WHEEL_SIZE_CELLS := Vector3i(9, 9, 5)
const ROAD_WHEEL_FIRST_CELL := Vector3i(10, 2, 1)
const ROAD_WHEEL_PITCH_CELLS := 9
const ROAD_WHEEL_COUNT := 7
## Esquina lateral de cada banda. La celda de fuera es el faldón plano de la oruga, no el rodillo.
const ROAD_WHEEL_LATERAL_CELLS := [1, 32]
## Llanta y buje del rodillo. Las cajas del primero y del último rozan el anillo de la banda y el
## piñón; filtrando por material sale el disco y la oruga se queda entera.
const ROAD_WHEEL_MATERIALS := [124, 125]
const ROAD_WHEEL_TRAVEL := "-0.08 0.42"
## El rodillo dibujado no llega al suelo: quien apoya es la banda. El raycast necesita un radio mayor
## que el disco para sostener el casco a su altura de marcha de siempre (0.154 m sobre el suelo).
const ROAD_WHEEL_RADIUS := 0.804
## Hundimiento del muelle con el tanque parado en llano. El eje físico se monta ese tanto por encima
## del disco dibujado para que, ya asentado, el rodillo vuelva justo a donde lo pintó el arte. Es un
## calibrado: si cambian masa, muelle o número de rodillos, se vuelve a medir con
## `tests/selftest/tank_road_wheel_selftest.gd`.
const ROAD_WHEEL_SAG := 0.364

## Agarre lateral de las orugas. Una oruga no patina de costado: sin esto el casco conservaba toda
## su velocidad transversal al girar y el tanque derrapaba como un coche sobre hielo. Es la misma
## idea que el `sideways slip` de una rueda, pero acotada por una deceleración para que un impacto
## lateral fuerte siga empujando el tanque en vez de quedar anulado en un tick.
const TRACK_LATERAL_GRIP := 26.0
## El 122 es la cinta continua de las dos orugas, y solo ella: el faldón lateral y los detalles del
## casco que compartían ese índice pasaron al 123, mismo color y mismas propiedades, para que el
## patrón no se derramase fuera del bucle.
const TRACK_MATERIAL := 122
## Celdas del casco recortado, en el orden que usa el decoder: largo, alto, lateral. El bucle de la
## banda ocupa las 13 primeras alturas; por encima ya es casco.
const TRACK_CELL_BOUNDS := AABB(Vector3(0, 0, 0), Vector3(78, 13, 38))
const TRACK_LINK_PITCH_CELLS := 4.0
## Los extremos del anillo no son curvas sino chaflanes a 45° de 4 celdas: |dx|+|dy| es constante en
## toda la diagonal. Con eso el shader distingue la capa exterior del anillo de la interior.
const TRACK_PROFILE_CHAMFER_CELLS := 4.0
const TRACK_CELLS_PER_METRE := 10.0

const YAW_SPEED := 0.72
const YAW_GAIN := 3.4
const YAW_MAX_IMPULSE := 90000.0
const MOTOR_SIGN := -1.0
## Tope de la compensacion de guiñada del casco. No es velocidad de punteria -eso es `YAW_SPEED`-
## sino lo que la corona puede pedir solo para quedarse quieta en el mundo mientras el casco gira,
## asi que tiene que superar a `TURN_MAX_YAW_SPEED`. Se acota para que un bache que sacuda el casco
## no dispare la torreta de golpe.
const YAW_COMPENSATION_LIMIT := 1.6

## Corte del cañón dentro del modelo de torreta: de x=61 en adelante solo queda el ánima de 6x6
## voxeles y el bocacho. Todo lo anterior (mantelete, cesta, techo) se queda en la torreta.
const BARREL_SPLIT_X := 61
## Muñones, medidos desde la esquina mínima del volumen de la torreta igual que los otros pivotes:
## dentro del mantelete y en el eje del ánima.
const TURRET_TRUNNION_OFFSET := Vector3(5.6, 0.50, 1.60)
const BARREL_FILL := 0.20
## Recorrido de un carro de combate real: mucha elevación, poca depresión.
const BARREL_MIN_PITCH_DEG := -9.0
const BARREL_MAX_PITCH_DEG := 20.0
const PITCH_SPEED := 0.55
const PITCH_GAIN := 3.2
const PITCH_MAX_IMPULSE := 90000.0
## El ángulo interno de la bisagra crece al revés que la elevación medida, igual que le pasa a la
## corona con `MOTOR_SIGN`. Afecta al motor y a los topes por igual, así que ambos se niegan aquí.
const PITCH_MOTOR_SIGN := -1.0

## Cadencia. Un carro real tarda más en recargar, pero de momento el disparo solo saca el fogonazo y
## esperar seis segundos para volver a verlo no ayuda a nadie.
const FIRE_COOLDOWN := 1.2
## Culatazo. El impulso real de un cañón de 120 mm sobre 60 toneladas mueve el carro veinte
## centímetros por segundo: correcto y absolutamente invisible. Esto está exagerado a propósito, y se
## aplica a la altura del bocacho para que el carro se encabrite sobre la suspensión en vez de
## limitarse a deslizarse hacia atrás, que es lo que se lee como potencia.
const RECOIL_IMPULSE := 45000.0
## El propio cañón retrocede aparte: el motor de los muñones lo devuelve solo a su elevación.
const BARREL_RECOIL_IMPULSE := 9000.0

var target_yaw := 0.0
var target_pitch := 0.0
var hull: VoxelBody3D
var turret: VoxelBody3D
var barrel: VoxelBody3D
var vehicle: VoxelVehicle3D

var _aim_distance := AIM_MAX_CONVERGENCE
var _joint: HingeJoint3D
var _joint_record := {}
var _pitch_joint: HingeJoint3D
var _pitch_record := {}
var _joints: VoxelJoints
var _gunner: Node3D
var _track_surface: VoxelSurfaceAnimation
## Avance (m/s) y giro (rad/s) que ha pedido el conductor, con las mismas rampas que la tracción.
## La banda se anima con esto y no con la velocidad del casco.
var _track_command := Vector2.ZERO
var _fire_cooldown := 0.0


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

	# El .vox trae torreta y cañón en una sola pieza; el cañón se separa aquí para que pueda cabecear
	# en sus muñones. Se mide el punto de giro antes de cortar: al detachar, la Shape de la torreta
	# deja de contener los voxeles del ánima y sus límites ya no sirven de referencia.
	var trunnion := _shape_point(tank.turret, TURRET_TRUNNION_OFFSET)
	tank.barrel = _split_barrel(world, tank.turret)

	var road_wheels := _detach_road_wheels(tank.hull)
	_make_dynamic(tank.hull, HULL_FILL)
	tank._configure_track_surface()
	_make_dynamic(tank.turret, TURRET_FILL)
	if tank.barrel != null:
		_make_dynamic(tank.barrel, BARREL_FILL)
	tank.vehicle = tank.hull.configure_vehicle(
		_tank_vehicle_descriptor(tank.hull, road_wheels)
	)
	if tank.vehicle != null:
		tank.vehicle.display_name = "tanque"
		tank.vehicle.set_joint_registry(tank._joints)
		# Las dos orugas apoyan muchas cajas contra el suelo. Ocho contactos se consumían enteros en
		# esa base plana y Jolt no alcanzaba a informar el morro contra un muro.
		tank.vehicle.max_contacts_reported = 32
		tank.turret.vehicle_impact_owner = tank.hull
		if tank.barrel != null:
			tank.barrel.vehicle_impact_owner = tank.hull
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
		# La corona no se rompe nunca: ni por separación, ni por daño de material, ni por explosión.
		"breakable": false,
	}
	tank._joints.add_records([tank._joint_record] as Array[Dictionary])
	tank._mount_barrel(world, trunnion)

	world.add_child(tank)
	tank.set_process(gunner != null)
	# La puntería necesita `_process` solo con jugador; las orugas siempre necesitan su reloj físico,
	# incluso si el tanque nació vacío y se ocupa varios segundos después.
	tank.set_physics_process(true)
	return tank


## Separa el ánima del resto de la torreta y le da su propio Body. `detach_component` ya devuelve la
## Shape colocada en coordenadas de mundo, así que el Body nace con transformada identidad.
static func _split_barrel(world: VoxelWorld3D, turret: VoxelBody3D) -> VoxelBody3D:
	var shape := turret.get_shapes()[0]
	var barrel_shape := shape.detach_component(
		shape.data.get_live_indices_region(
			Vector3i(BARREL_SPLIT_X, 0, 0), shape.data.get_dimensions()
		)
	)
	if barrel_shape == null:
		push_warning("VoxelTank3D: la torreta no tiene cañón que separar")
		return null
	var body := VoxelBody3D.new()
	body.name = "TanqueCanon"
	world.add_child(body)
	body.add_voxel_shape(barrel_shape)
	world.register_body(body)
	return body


## Monta el cañón sobre los muñones. Es una bisagra con tope: el motor persigue la mira dentro del
## recorrido y los límites impiden que la gravedad lo deje colgando.
func _mount_barrel(world: VoxelWorld3D, trunnion: Vector3) -> void:
	if barrel == null or not is_instance_valid(barrel):
		return
	var turret_physics := turret.get_physics_body()
	var barrel_physics := barrel.get_physics_body()
	if turret_physics == null or barrel_physics == null:
		return
	# Cañón y mantelete quedan pegados tras el corte. Sin excepción, Jolt resuelve ese contacto cara
	# a cara contra la propia bisagra y el cañón vibra.
	barrel_physics.add_collision_exception_with(turret_physics)
	var hull_physics := hull.get_physics_body()
	if hull_physics != null:
		barrel_physics.add_collision_exception_with(hull_physics)

	var hinge := HingeJoint3D.new()
	hinge.name = "CanonHinge"
	# El eje de una bisagra de Godot es su +Z local, y el cabeceo ocurre sobre el eje lateral del
	# modelo, que es justo el +Z de la torreta: aquí el marco entra sin rotar.
	var frame := Transform3D(Basis.IDENTITY, trunnion)
	world.add_child(hinge)
	hinge.global_transform = frame
	hinge.node_a = hinge.get_path_to(turret_physics)
	hinge.node_b = hinge.get_path_to(barrel_physics)
	hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-BARREL_MAX_PITCH_DEG))
	hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(-BARREL_MIN_PITCH_DEG))
	hinge.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	hinge.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, PITCH_MAX_IMPULSE)
	_pitch_joint = hinge
	_pitch_record = {
		"joint": hinge,
		"attributes": {"type": "hinge", "size": "0.4"},
		"transform": frame,
		"owner_body": turret,
		"other_body": barrel,
		"broken": false,
		"breakable": false,
	}
	_joints.add_records([_pitch_record] as Array[Dictionary])


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


## Guiñada del casco en rad/s. `_plane_yaw` mide sobre el plano XZ, asi que su derivada es justo la
## componente vertical de la velocidad angular del casco.
func _hull_yaw_rate() -> float:
	if hull == null or not is_instance_valid(hull):
		return 0.0
	var physics := hull.get_physics_body() as RigidBody3D
	if physics == null:
		return 0.0
	return clampf(physics.angular_velocity.y, -YAW_COMPENSATION_LIMIT, YAW_COMPENSATION_LIMIT)


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


## Saca los rodillos del arte del casco a Shapes propias del mismo Body. Siguen siendo geometría del
## casco para render, masa y destrucción; lo único que gana cada disco es un transform propio que
## `_sync_wheel_visuals` puede mover. Se devuelven en el orden en que se declaran las ruedas.
static func _detach_road_wheels(hull: VoxelBody3D) -> Array:
	var shape := hull.get_shapes()[0]
	var discs: Array = []
	for lateral: int in ROAD_WHEEL_LATERAL_CELLS:
		for index in ROAD_WHEEL_COUNT:
			var low := Vector3i(
				ROAD_WHEEL_FIRST_CELL.x + index * ROAD_WHEEL_PITCH_CELLS,
				ROAD_WHEEL_FIRST_CELL.y,
				lateral
			)
			var cells := shape.data.get_cells()
			var indices := PackedInt32Array()
			for cell_index in shape.data.get_live_indices_region(
				low, low + ROAD_WHEEL_SIZE_CELLS
			):
				if ROAD_WHEEL_MATERIALS.has(cells[cell_index]):
					indices.append(cell_index)
			var disc := shape.detach_component(indices)
			if disc == null:
				push_warning("VoxelTank3D: falta el rodillo %d del casco" % discs.size())
				continue
			# El disco se monta hundido: `_create_wheels` clava el eje en su centro y el nodo de la
			# rueda cuelga lo que mida el muelle, así que subirlo aquí lo devuelve a su sitio en
			# cuanto el tanque se asienta.
			disc.transform.origin += Vector3.UP * ROAD_WHEEL_SAG
			hull.add_voxel_shape(disc, true, false)
			discs.append(disc)
	return discs


## Cada rodillo del arte es la rueda: `VehicleWheel3D` lo coloca en el centro de su Shape y
## `_sync_wheel_visuals` lo devuelve pegado a ella, así que rueda y acompaña a la suspensión sin
## código propio.
static func _tank_vehicle_descriptor(body: VoxelBody3D, road_wheels: Array) -> Dictionary:
	var bounds := body.get_shapes()[0].world_bounds()
	var wheels: Array = []
	for disc: VoxelShape3D in road_wheels:
		wheels.append({
			"attributes": {
				"steer": "0", "drive": "1", "travel": ROAD_WHEEL_TRAVEL,
				"radius": str(ROAD_WHEEL_RADIUS),
			},
			"transform": Transform3D(Basis.IDENTITY, disc.world_bounds().get_center()),
			"shapes": [disc],
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


func _process(delta: float) -> void:
	if _gunner == null or not is_instance_valid(_gunner) or not is_turret_attached():
		return
	if vehicle == null or not is_instance_valid(vehicle) or not vehicle.has_driver():
		return
	# El disparo se lee aquí y no en `Player`: dentro de un vehículo el jugador ignora "fire" a
	# propósito, y quien sabe dónde está el bocacho es el tanque.
	_fire_cooldown = maxf(0.0, _fire_cooldown - delta)
	if Input.is_action_just_pressed("fire"):
		fire()
	var camera := _gunner.get("camera") as Camera3D
	if camera == null or not is_instance_valid(camera):
		return
	var hull_now := hull_transform()
	var aim_point := _camera_aim_point(camera, delta)
	target_yaw = aim_yaw(aim_point - hull_now.origin, hull_now.basis)
	target_pitch = _aim_pitch(aim_point)


func _physics_process(delta: float) -> void:
	_drive_tracks(delta)
	if not is_turret_attached() or not is_instance_valid(hull) or not is_instance_valid(turret):
		return
	var error := wrapf(target_yaw - yaw(), -PI, PI)
	# El motor de la corona manda velocidad RELATIVA al casco, y `target_yaw` tambien es relativo:
	# con la mira fija en el mundo, girar el casco a omega hace que el objetivo se mueva a -omega.
	# Un proporcional puro solo puede seguir eso arrastrando un error permanente de omega/YAW_GAIN
	# -a 1 rad/s son 17 grados- y por eso la torreta se veia girar con el cuerpo. Se le suma la
	# guiñada del casco con el signo contrario, que la cancela exactamente, y el proporcional se
	# queda solo con el error de punteria. Los dos terminos se acotan por separado: el de punteria
	# a la velocidad de la corona, y el de compensacion a un tope mayor, porque si no el casco gira
	# mas rapido (1,05 rad/s) de lo que la torreta puede compensar (0,72).
	var command := clampf(error * YAW_GAIN, -YAW_SPEED, YAW_SPEED) - _hull_yaw_rate()
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, MOTOR_SIGN * command)
	if absf(error) > 0.01 or absf(command) > 0.01:
		hull.wake_for_interaction()
		turret.wake_for_interaction()
	_aim_barrel()


## Munición cargada. Una sola ficha por ahora; el día que haya HE o HEAT esto es lo que cambia
## el selector del artillero, no el código del disparo.
const AMMO_KIND := "ap"


## Dispara: fogonazo, culatazo y proyectil. Devuelve `false` si el cañón sigue recargando.
func fire() -> bool:
	if _fire_cooldown > 0.0 or barrel == null or not is_instance_valid(barrel):
		return false
	var world := hull.get_parent() as VoxelWorld3D if is_instance_valid(hull) else null
	if world == null:
		return false
	var muzzle := muzzle_transform()
	var forward := -muzzle.basis.z
	# El suelo: el fondo del casco está apoyado en él, así que no hace falta un raycast para saber a
	# qué altura levantar el polvo.
	world.emit_muzzle_blast(
		muzzle.origin, forward, 1.0, hull.get_shapes()[0].world_bounds().position.y
	)
	_apply_recoil(forward, muzzle.origin)
	Projectile.spawn(world, muzzle, AMMO_KIND, _own_collision_rids(), _hull_velocity())
	_fire_cooldown = FIRE_COOLDOWN
	return true


## Todo lo que es el propio carro. El bocacho está a medio metro del cañón, dentro de la envolvente
## de la torreta: sin esta lista el primer rayo del proyectil impacta en el que dispara.
func _own_collision_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for part: VoxelBody3D in [hull, turret, barrel]:
		if part != null and is_instance_valid(part):
			rids.append_array(part.get_collision_rids())
	return rids


## Velocidad del arma, que el proyectil hereda. Disparar en marcha desvía el tiro tanto como en la
## realidad, y es gratis: ya la lleva el casco.
func _hull_velocity() -> Vector3:
	var hull_physics := hull.get_physics_body() as RigidBody3D if is_instance_valid(hull) else null
	return hull_physics.linear_velocity if hull_physics != null else Vector3.ZERO


func _apply_recoil(forward: Vector3, muzzle_origin: Vector3) -> void:
	var hull_physics := hull.get_physics_body()
	if hull_physics != null:
		hull.wake_for_interaction()
		hull_physics.apply_impulse(
			-forward * RECOIL_IMPULSE, muzzle_origin - hull_physics.global_position
		)
	var barrel_physics := barrel.get_physics_body()
	if barrel_physics != null:
		barrel.wake_for_interaction()
		barrel_physics.apply_impulse(
			-forward * BARREL_RECOIL_IMPULSE, muzzle_origin - barrel_physics.global_position
		)


## Bocacho del cañón, mirando por el ánima según el convenio de Godot (`-basis.z` hacia adelante).
func muzzle_transform() -> Transform3D:
	if barrel == null or not is_instance_valid(barrel):
		return Transform3D.IDENTITY
	var shape := barrel.get_shapes()[0]
	var bounds := shape.local_bounds()
	var center := shape.global_transform * bounds.get_center()
	# El ánima se cortó por el eje x del modelo, pero el signo depende de cómo quedase orientada la
	# torreta: el bocacho es sin más el extremo que se aleja de ella.
	var half := shape.global_basis.x * (bounds.size.x * 0.5)
	if is_instance_valid(turret) and (center - turret.get_shapes()[0].world_bounds().get_center()) \
			.dot(half) < 0.0:
		half = -half
	var forward := half.normalized()
	# Medio metro por delante del bocacho: nacido justo en la boca, el primer frame de la llamarada
	# se queda medio metido dentro del propio cañón.
	return Transform3D(Basis.looking_at(forward, Vector3.UP), center + half + forward * 0.5)


## Sigue `target_pitch` con el motor de los muñones. El cañón vive fuera del casco, así que hay que
## despertarlo aparte para que el presupuesto de física no lo deje dormido a media elevación.
func _aim_barrel() -> void:
	if _pitch_joint == null or not is_instance_valid(_pitch_joint) \
			or barrel == null or not is_instance_valid(barrel):
		return
	var error := target_pitch - barrel_pitch()
	_pitch_joint.set_param(
		HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
		PITCH_MOTOR_SIGN * clampf(error * PITCH_GAIN, -PITCH_SPEED, PITCH_SPEED)
	)
	if absf(error) > 0.01:
		barrel.wake_for_interaction()
		turret.wake_for_interaction()


## Elevación actual del cañón respecto a la torreta, en radianes y positiva hacia arriba.
func barrel_pitch() -> float:
	if turret == null or barrel == null or not is_instance_valid(turret) \
			or not is_instance_valid(barrel):
		return 0.0
	var turret_physics := turret.get_physics_body()
	var barrel_physics := barrel.get_physics_body()
	if turret_physics == null or barrel_physics == null:
		return 0.0
	return _pitch_in_frame(barrel_physics.global_basis.x, turret_physics.global_basis)


## Elevación que hay que pedirle a los muñones para apuntar a `aim_point`, ya recortada al recorrido
## real del carro. Se mide desde el propio cañón: con un objetivo cercano, medirla desde el casco
## dejaba el disparo un par de grados alto.
## La línea de tiro sale del centro de masas de la torreta, no del origen del Body del cañón: ese
## Body nace con transformada identidad (`detach_component` deja los voxeles en mundo) y su origen
## queda bajo el suelo, con lo que apuntar al suelo de al lado pedía elevación en vez de depresión.
func _aim_pitch(aim_point: Vector3) -> float:
	if turret == null or not is_instance_valid(turret):
		return 0.0
	var turret_physics := turret.get_physics_body()
	if turret_physics == null:
		return 0.0
	return clampf(
		_pitch_in_frame(aim_point - turret_physics.global_position, turret_physics.global_basis),
		deg_to_rad(BARREL_MIN_PITCH_DEG), deg_to_rad(BARREL_MAX_PITCH_DEG)
	)


static func _pitch_in_frame(direction: Vector3, turret_basis: Basis) -> float:
	var local := turret_basis.inverse() * direction
	return atan2(local.y, Vector2(local.x, local.z).length())


## Diferencial de orugas: W/S son tracción longitudinal; A/D piden yaw aun desde parado.
func _drive_tracks(delta: float) -> void:
	if vehicle == null or not is_instance_valid(vehicle) or not vehicle.has_active_controls():
		_command_tracks(delta, 0.0, 0.0, TRACK_BRAKING, TURN_BRAKING)
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
	# Agarre de oruga: la componente transversal se disipa a un ritmo acotado en lugar de conservarse.
	# Sin esto el tanque salía de cada giro deslizándose de lado con la trayectoria anterior intacta.
	var right := vehicle.global_basis.x.normalized()
	var lateral := vehicle.linear_velocity.dot(right)
	vehicle.linear_velocity += right * (
		move_toward(lateral, 0.0, TRACK_LATERAL_GRIP * delta) - lateral
	)
	var steer := vehicle.control_steer_input()
	var up := vehicle.global_basis.y.normalized()
	var current := vehicle.angular_velocity.dot(up)
	var target := steer * TURN_MAX_YAW_SPEED
	var acceleration := TURN_ACCELERATION if not is_zero_approx(steer) else TURN_BRAKING
	var next := move_toward(current, target, acceleration * delta)
	if not is_equal_approx(current, next):
		vehicle.angular_velocity += up * (next - current)
		vehicle.sleeping = false
	_command_tracks(delta, target_speed, target, drive_acceleration, acceleration)


func _configure_track_surface() -> void:
	if hull == null or not is_instance_valid(hull):
		return
	_track_surface = VoxelSurfaceAnimation.create(
		TRACK_MATERIAL, TRACK_CELL_BOUNDS, TRACK_LINK_PITCH_CELLS,
		TRACK_PROFILE_CHAMFER_CELLS
	)
	for shape in hull.get_shapes():
		shape.surface_animation = _track_surface


## La banda sigue la orden del conductor, no el movimiento del casco. Integrar la velocidad real
## hacía correr las orugas cada vez que una explosión lanzaba el tanque o lo empujaba un muro, con
## el motor parado: el efecto se leía como un error, no como tracción. Las rampas son las mismas que
## usa `_drive_tracks`, así que soltar el mando frena la cinta al mismo ritmo que frena el tanque.
func _command_tracks(
	delta: float, target_speed: float, target_yaw: float,
	drive_acceleration: float, yaw_acceleration: float
) -> void:
	_track_command = Vector2(
		move_toward(_track_command.x, target_speed, drive_acceleration * delta),
		move_toward(_track_command.y, target_yaw, yaw_acceleration * delta)
	)
	# Sin mando, la banda no puede correr más que el casco: estamparse contra un muro la para en seco,
	# como una oruga engranada al piñón, en vez de dejarla frenar sola durante dos segundos. El recorte
	# solo baja la magnitud, nunca la sube, así que una explosión con el motor parado sigue sin
	# moverla. Con gas mantenido contra el muro sí patina, que es lo que hace un tanque de verdad.
	if vehicle != null and is_instance_valid(vehicle):
		if is_zero_approx(target_speed):
			var speed := absf(vehicle.linear_velocity.dot(vehicle.forward_direction()))
			_track_command.x = clampf(_track_command.x, -speed, speed)
		if is_zero_approx(target_yaw):
			var spin := absf(vehicle.angular_velocity.dot(vehicle.global_basis.y.normalized()))
			_track_command.y = clampf(_track_command.y, -spin, spin)
	if _track_surface == null:
		return
	# Un pivote parado suma velocidad a una banda y se la resta a la otra, así que las orugas corren
	# en sentidos opuestos. El signo sale de v = v_avance + ω × r con r sobre el eje lateral del
	# casco: la banda de +Z gana ω·semiancho, y `offsets.x` es la de índice lateral bajo, la de -Z.
	var half_width := TRACK_CELL_BOUNDS.size.z * 0.5 / TRACK_CELLS_PER_METRE
	var cells := delta * TRACK_CELLS_PER_METRE
	_track_surface.advance(
		(_track_command.x - _track_command.y * half_width) * cells,
		(_track_command.x + _track_command.y * half_width) * cells
	)


func _camera_aim_point(camera: Camera3D, delta: float) -> Vector3:
	var from := camera.global_position
	var direction := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(
		from, from + direction * AIM_MAX_CONVERGENCE
	)
	query.collide_with_areas = false
	if vehicle != null and is_instance_valid(vehicle):
		query.exclude = vehicle.get_camera_collision_rids()
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	var raw := AIM_MAX_CONVERGENCE if hit.is_empty() \
		else from.distance_to(hit.position as Vector3)
	_aim_distance = lerpf(
		_aim_distance,
		clampf(raw, AIM_MIN_CONVERGENCE, AIM_MAX_CONVERGENCE),
		1.0 - exp(-AIM_SMOOTH * delta)
	)
	return from + direction * _aim_distance


## Yaw que hay que pedirle a la corona para que el cañón (+X del modelo) mire hacia `aim`.
static func aim_yaw(aim: Vector3, hull_basis: Basis) -> float:
	return wrapf(_plane_yaw(aim) - _plane_yaw(hull_basis.x), -PI, PI)


static func _shape_point(body: VoxelBody3D, offset: Vector3) -> Vector3:
	return body.get_shapes()[0].world_bounds().position + offset


static func _make_dynamic(body: VoxelBody3D, fill: float) -> void:
	for shape in body.get_shapes():
		shape.physical_fill_scale = fill
	body.make_dynamic()
