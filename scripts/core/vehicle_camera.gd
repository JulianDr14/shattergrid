class_name VehicleCamera
extends RefCounted
## Cámara de puntería arcade al estilo World of Tanks, aislada del jugador a pie.
##
## Reglas del rig, en orden de importancia:
##  1. El pivote solo hereda la POSICIÓN y el yaw del casco. El roll y el pitch del chasis se
##     descartan: cada bache rotaba la base entera y trasladaba el pivote, y ese temblor entraba en
##     la mira por la puerta de atrás aunque la orientación no se suavizara.
##  2. La altura vive DENTRO del pivote, no como un offset de mundo sumado tras la órbita. Así el
##     encuadre es el mismo a cualquier pitch y la retícula pasa por el punto que orbita.
##  3. El yaw es absoluto en el mundo: girar el tanque no arrastra la vista.

const DISTANCE := 6.2
const MAX_DISTANCE := 9.0
const ZOOM_STEP := 0.9
const HEIGHT := 2.0
const SMOOTH := 11.0
const ZOOM_SMOOTH := 13.0
const COCKPIT_BLEND_START := 1.45
const COCKPIT_BLEND_END := 0.45
const COCKPIT_FOV := 82.0
const PITCH_MIN := -0.42
const PITCH_MAX := 0.72

## FOV de referencia de la sensibilidad. Al alejar el FOV real de este valor, el ratón mueve menos
## radianes por píxel: sin esto, apuntar de lejos con el mismo gesto que de cerca es imposible.
const SENSITIVITY_REFERENCE_FOV := 78.0

var yaw := 0.0
var pitch := 0.12
var distance := DISTANCE
var target_distance := DISTANCE
var max_distance := MAX_DISTANCE
var height := HEIGHT
var fov := 90.0


## Un turismo cabe en los 6,2 m por defecto; un tanque mide 7,8 m de casco y 9,6 con el cañón, y con
## la distancia fija la cámara se metía dentro del propio vehículo. Se encuadra por la huella real
## -que ya incluye torreta y remolque- al subirse, una vez.
func fit(vehicle: VoxelVehicle3D, fallback_fov: float) -> void:
	var bounds := vehicle.get_world_bounds()
	var span := maxf(bounds.size.x, bounds.size.z)
	var profile := vehicle.get_camera_profile()
	var authored_distance := float(profile.get("distance", -1.0))
	var authored_height := float(profile.get("height", -1.0))
	var authored_max := float(profile.get("max_distance", -1.0))
	var authored_fov := float(profile.get("fov", -1.0))
	target_distance = authored_distance if authored_distance > 0.0 \
		else clampf(span * 0.95, DISTANCE, 16.0)
	max_distance = authored_max if authored_max > 0.0 \
		else maxf(MAX_DISTANCE, target_distance * 1.6)
	height = authored_height if authored_height > 0.0 else maxf(HEIGHT, bounds.size.y * 0.9)
	fov = authored_fov if authored_fov > 0.0 else fallback_fov
	distance = target_distance


## Coloca la cámara sin suavizado, al subirse al vehículo.
func snap(camera: Camera3D, vehicle: VoxelVehicle3D) -> void:
	yaw = yaw_from_forward(vehicle.forward_direction())
	pitch = 0.12
	distance = target_distance
	camera.top_level = true
	var aim := aim_direction(yaw, pitch)
	camera.global_position = pivot(vehicle.get_camera_pivot(vehicle.global_transform), height) \
		- aim * distance
	camera.look_at(camera.global_position + aim * 100.0, Vector3.UP)
	camera.fov = fov
	camera.reset_physics_interpolation()


## Devuelve `true` si el evento era del orbitador y ya está consumido.
func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		var amount := ZOOM_STEP * maxf(0.25, absf(button.factor))
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_distance = maxf(0.0, target_distance - amount)
			return true
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_distance = minf(max_distance, target_distance + amount)
			return true
		return false
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var sensitivity := aim_sensitivity(fov)
		yaw -= motion.relative.x * sensitivity
		# El controlador anterior tenía el eje vertical invertido respecto a la cámara a pie: bajar
		# el ratón metía la cámara debajo del coche y obligaba a mirar hacia arriba.
		pitch = pitch_after_input(pitch, motion.relative.y, sensitivity)
		return true
	return false


func update(delta: float, camera: Camera3D, vehicle: VoxelVehicle3D, exclude: Array[RID]) -> void:
	var zoom_blend := 1.0 - exp(-ZOOM_SMOOTH * delta)
	distance = lerpf(distance, target_distance, zoom_blend)
	if absf(distance - target_distance) < 0.002:
		distance = target_distance
	var vehicle_transform := vehicle.get_global_transform_interpolated()
	var orbit := pivot(vehicle.get_camera_pivot(vehicle_transform), height)
	var aim := aim_direction(yaw, pitch)
	var exterior := orbit - aim * distance
	# La vista interior usa el `<location tags="player">` authored del XML, no el centro de masa.
	# El blend evita el salto de cámara cuando la rueda cruza el último paso de zoom.
	var cockpit := vehicle.get_driver_view_from_transform(vehicle_transform)
	var interior_weight := 1.0 - smoothstep(COCKPIT_BLEND_END, COCKPIT_BLEND_START, distance)
	var desired := exterior.lerp(cockpit, interior_weight)
	var smoothed := camera.global_position.lerp(desired, 1.0 - exp(-SMOOTH * delta))
	if interior_weight < 0.999:
		# Resolver la colisión después del suavizado impide que el resorte atraviese una pared un par
		# de frames aunque el destino final ya estuviera correctamente recortado.
		var query := PhysicsRayQueryParameters3D.create(orbit, smoothed)
		query.collide_with_areas = false
		query.exclude = exclude
		var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			smoothed = (hit.position as Vector3) + (hit.normal as Vector3) * 0.22
	# El encuadre se suaviza; la dirección de mira no. Un lerp sobre la orientación convierte cada
	# bache del casco en un temblor de la mira y es lo que hacía imposible apuntar.
	camera.global_position = smoothed
	camera.look_at(camera.global_position + aim * 100.0, Vector3.UP)
	camera.fov = lerpf(fov, COCKPIT_FOV, interior_weight)


func is_interior() -> bool:
	return target_distance <= COCKPIT_BLEND_END


## El punto que se ve en el centro de la pantalla: el pivote plano del casco, elevado. La altura va
## aquí y no tras la órbita, o el offset vertical se queda fijo en mundo y el encuadre se desliza
## solo al cambiar el pitch.
static func pivot(flat_pivot: Vector3, pivot_height: float) -> Vector3:
	return flat_pivot + Vector3.UP * pivot_height


## Dirección a la que mira la cámara. Yaw absoluto en el mundo: girar el tanque no arrastra la mira,
## que es lo que obligaba a recolocar el ratón en cada curva.
static func aim_direction(camera_yaw: float, camera_pitch: float) -> Vector3:
	return Vector3(
		-sin(camera_yaw) * cos(camera_pitch),
		-sin(camera_pitch),
		-cos(camera_yaw) * cos(camera_pitch)
	).normalized()


static func yaw_from_forward(forward: Vector3) -> float:
	return atan2(-forward.x, -forward.z)


## Radianes por píxel de ratón. Escala con `tan(fov/2)` para que el gesto tape siempre la misma
## fracción de pantalla: al hacer zoom el mundo se agranda y el mismo píxel debe girar menos.
static func aim_sensitivity(current_fov: float) -> float:
	var reference := tan(deg_to_rad(SENSITIVITY_REFERENCE_FOV) * 0.5)
	var actual := tan(deg_to_rad(clampf(current_fov, 5.0, 170.0)) * 0.5)
	return 0.0022 * (actual / reference)


static func pitch_after_input(current: float, relative_y: float, sensitivity: float) -> float:
	return clampf(current + relative_y * sensitivity, PITCH_MIN, PITCH_MAX)
