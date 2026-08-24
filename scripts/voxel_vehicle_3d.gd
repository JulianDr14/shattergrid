class_name VoxelVehicle3D
extends VehicleBody3D
## Vehiculo conducible construido directamente desde un `<vehicle>` de Teardown.
##
## La carroceria sigue perteneciendo a VoxelBody3D, de modo que conserva masa voxel, destruccion,
## agua y danos por impacto. Las ruedas son los raycasts de VehicleWheel3D: cuatro constraints
## baratos en un unico Body, no cuatro RigidBodies y joints adicionales por coche.

signal driver_changed(vehicle: VoxelVehicle3D, occupied: bool)

const GROUP := "voxel_vehicles"
const ENTER_DISTANCE := 3.6
const MAX_HEADLIGHTS := 2
const MAX_BRAKE_LIGHTS := 2
const MAX_REVERSE_LIGHTS := 2
const IMPACT_MIN_IMPULSE := 24.0
const IMPACT_MIN_SPEED := 2.6
const IMPACT_COOLDOWN_FRAMES := 12
## La carroceria del SUV de Lee producía 42 subshapes. Con CCD permanente contra los BVH estáticos,
## eso elevó el paso físico medido hasta 41,5 ms aun después de detenerse contra un obstáculo.
const COLLISION_BOX_BUDGET := 16
const CCD_MIN_SPEED := 14.0
const SHADOW_UPDATE_INTERVAL_FRAMES := 4

var voxel_owner: VoxelBody3D
var display_name := "vehiculo"
var max_speed_kmh := 80.0
var acceleration := 4.0
## Resistencia authored por `<vehicle strength="…">`. Ademas de describir la robustez del coche,
## acota el perfil de apertura que necesita su frontal para no detenerse contra una pared blanda de
## 10 cm como si fuese hormigon. No sustituye la energia del choque ni perfora materiales duros.
var impact_strength := 4.0
var max_steer := 0.46
var min_steer := 0.12
var steer_speed := 4.5
var service_brake := 90.0
var coast_brake := 8.0

var _driver: Node3D
var _seat_local := Vector3(0.0, 1.4, 0.0)
var _wheels: Array[VehicleWheel3D] = []
var _wheel_visuals: Array[Dictionary] = []
var _visual_body: VoxelBody3D
var _headlights: Array[Light3D] = []
var _brake_lights: Array[Light3D] = []
var _reverse_lights: Array[Light3D] = []
var _last_report_frame := {}
var _control_override := false
var _override_throttle := 0.0
var _override_steer := 0.0
var _override_handbrake := false
var _last_mass := -1.0


func configure(owner: VoxelBody3D, descriptor: Dictionary) -> void:
	voxel_owner = owner
	voxel_owner.acquire_physics_hold("vehicle_runtime:%d" % get_instance_id())
	add_to_group(GROUP)
	contact_monitor = true
	max_contacts_reported = 8
	# CCD es una capacidad del vehículo, no un estado permanente; `VoxelBody3D` lo enciende cuando
	# recorre más que el grosor de una pared delgada por varios ticks.
	continuous_cd = false
	if not sleeping_state_changed.is_connected(_on_sleeping_state_changed):
		sleeping_state_changed.connect(_on_sleeping_state_changed)
	var attributes: Dictionary = descriptor.get("attributes", {})
	var tags := String(attributes.get("tags", "")).strip_edges()
	display_name = _vehicle_name(tags, String(attributes.get("sound", "")))
	max_speed_kmh = clampf(float(attributes.get("topspeed", 80.0)), 8.0, 180.0)
	acceleration = clampf(float(attributes.get("acceleration", 4.0)), 0.4, 12.0)
	impact_strength = clampf(float(attributes.get("strength", 4.0)), 0.5, 16.0)
	var steer_assist := clampf(float(attributes.get("steerassist", 0.15)), 0.0, 1.0)
	steer_speed = lerpf(3.4, 6.2, steer_assist)
	_visual_body = descriptor.get("visual_body") as VoxelBody3D
	# La transformada visible sigue subiendo cada frame. Solo la ocupación de sombra volumétrica se
	# actualiza a 15 Hz: rasterizar carrocería+ruedas en los cuatro niveles medía 5,7 ms/frame en Lee.
	# Ambos Bodies comparten fase para que sus cinco cajas se fusionen en una sola región pequeña.
	var shadow_phase := get_instance_id() % SHADOW_UPDATE_INTERVAL_FRAMES
	voxel_owner.set_meta("voxel_shadow_interval_frames", SHADOW_UPDATE_INTERVAL_FRAMES)
	voxel_owner.set_meta("voxel_shadow_phase", shadow_phase)
	if _visual_body != null and is_instance_valid(_visual_body):
		_visual_body.set_meta("voxel_shadow_interval_frames", SHADOW_UPDATE_INTERVAL_FRAMES)
		_visual_body.set_meta("voxel_shadow_phase", shadow_phase)
	var seat_transform: Transform3D = descriptor.get("seat_transform", Transform3D.IDENTITY)
	if seat_transform != Transform3D.IDENTITY:
		_seat_local = global_transform.affine_inverse() * seat_transform.origin
	_create_wheels(descriptor)
	_create_lights(descriptor.get("lights", []))
	_retune_for_mass(true)
	_set_lights(false, false, false)
	if _visual_body != null and is_instance_valid(_visual_body):
		var visual_rigid := _visual_body.get_physics_body() as RigidBody3D
		if visual_rigid != null:
			visual_rigid.freeze = true
			visual_rigid.can_sleep = true
			visual_rigid.sleeping = true


func _create_wheels(descriptor: Dictionary) -> void:
	var spring := clampf(float((descriptor.attributes as Dictionary).get("spring", 1.0)), 0.1, 3.0)
	var damping := clampf(float((descriptor.attributes as Dictionary).get("damping", 1.0)), 0.1, 3.0)
	var friction := clampf(float((descriptor.attributes as Dictionary).get("friction", 1.0)), 0.5, 2.5)
	var antiroll := clampf(float((descriptor.attributes as Dictionary).get("antiroll", 0.25)), 0.0, 1.0)
	for index in (descriptor.get("wheels", []) as Array).size():
		var record: Dictionary = descriptor.wheels[index]
		var wheel := VehicleWheel3D.new()
		wheel.name = "Wheel%d" % index
		var source_transform: Transform3D = record.get("transform", global_transform)
		var local_position := global_transform.affine_inverse() * source_transform.origin
		var visual_shapes: Array = record.get("shapes", [])
		var radius := _wheel_radius(visual_shapes)
		if not visual_shapes.is_empty() and is_instance_valid(visual_shapes[0]):
			local_position = global_transform.affine_inverse() * (
				(visual_shapes[0] as VoxelShape3D).world_bounds().get_center()
			)
		wheel.position = local_position
		wheel.wheel_radius = radius
		var travel := _travel(record.attributes as Dictionary)
		wheel.wheel_rest_length = clampf(maxf(0.16, travel.y), 0.16, 0.42)
		wheel.suspension_travel = clampf(travel.x + travel.y, 0.18, 0.48)
		wheel.use_as_steering = String((record.attributes as Dictionary).get("steer", "0")) != "0"
		wheel.use_as_traction = String((record.attributes as Dictionary).get("drive", "0")) != "0"
		wheel.wheel_friction_slip = friction * 1.25
		wheel.suspension_stiffness = 23.0 + spring * 7.0
		wheel.damping_compression = 3.0 + damping
		wheel.damping_relaxation = 5.0 + damping * 1.6
		wheel.wheel_roll_influence = lerpf(0.48, 0.24, antiroll)
		add_child(wheel)
		_wheels.append(wheel)
		for shape_variant: Variant in visual_shapes:
			var shape := shape_variant as VoxelShape3D
			if shape == null or not is_instance_valid(shape):
				continue
			_wheel_visuals.append({
				"wheel": wheel,
				"shape": shape,
				"local": source_transform.affine_inverse() * shape.global_transform,
			})
	# Algunos mods no escriben `drive`. Un coche sin rueda motriz parece roto aunque su XML solo sea
	# incompleto; se adopta traccion trasera, sin inventar ruedas ni hacer conducible un `nodrive`.
	if not _wheels.any(func(candidate: VehicleWheel3D) -> bool: return candidate.use_as_traction):
		for wheel in _wheels:
			wheel.use_as_traction = wheel.position.z < 0.0


func _create_lights(records: Array) -> void:
	for record_variant: Variant in records:
		var record := record_variant as Dictionary
		var attributes: Dictionary = record.get("attributes", {})
		var type := String(attributes.get("type", "area"))
		var color := _parse_color(String(attributes.get("color", "1 1 1")))
		if type == "cone" and _headlights.size() < MAX_HEADLIGHTS:
			var spot := SpotLight3D.new()
			spot.name = "Headlight%d" % _headlights.size()
			spot.light_color = color
			spot.light_energy = clampf(float(attributes.get("scale", 20.0)) * 0.14, 2.2, 6.5)
			spot.spot_range = clampf(float(attributes.get("reach", 20.0)), 12.0, 34.0)
			spot.spot_angle = clampf(float(attributes.get("angle", 42.0)) * 0.5, 18.0, 38.0)
			spot.spot_angle_attenuation = 1.2
			_setup_projected_light(spot, record.get("transform", global_transform), true)
			_headlights.append(spot)
		elif color.r > color.g * 1.8 and color.r > color.b * 1.8 \
				and _brake_lights.size() < MAX_BRAKE_LIGHTS:
			var tail := OmniLight3D.new()
			tail.name = "BrakeLight%d" % _brake_lights.size()
			tail.light_color = Color(1.0, 0.035, 0.02)
			tail.light_energy = 3.2
			tail.omni_range = clampf(float(attributes.get("reach", 4.5)), 3.0, 7.0)
			_setup_projected_light(tail, record.get("transform", global_transform), false)
			_brake_lights.append(tail)
		elif color.r > 0.65 and color.g > 0.65 and color.b > 0.65 \
				and _reverse_lights.size() < MAX_REVERSE_LIGHTS:
			var reverse := OmniLight3D.new()
			reverse.name = "ReverseLight%d" % _reverse_lights.size()
			reverse.light_color = Color(0.82, 0.9, 1.0)
			reverse.light_energy = 2.1
			reverse.omni_range = clampf(float(attributes.get("reach", 4.5)), 3.0, 6.0)
			_setup_projected_light(reverse, record.get("transform", global_transform), false)
			_reverse_lights.append(reverse)


func _setup_projected_light(light: Light3D, source_transform: Transform3D, cone: bool) -> void:
	add_child(light)
	# Teardown dirige los conos sobre +Z; SpotLight3D ilumina sobre -Z.
	light.global_transform = source_transform * Transform3D(
		Basis(Quaternion(Vector3.UP, PI)) if cone else Basis.IDENTITY, Vector3.ZERO
	)
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 26.0 if cone else 12.0
	light.distance_fade_length = 12.0 if cone else 6.0
	light.set_meta("voxel_shadowless", true)
	light.add_to_group("voxel_shadow_lights")


func set_driver(driver: Node3D) -> bool:
	if driver == null or _driver != null or _wheels.size() < 2:
		return false
	_driver = driver
	set_physics_process(true)
	can_sleep = false
	sleeping = false
	if voxel_owner != null:
		voxel_owner.acquire_physics_hold("vehicle_driver:%d" % get_instance_id())
	_set_lights(true, false, false)
	driver_changed.emit(self, true)
	return true


func clear_driver(driver: Node3D = null) -> void:
	if _driver == null or (driver != null and driver != _driver):
		return
	_driver = null
	engine_force = 0.0
	brake = coast_brake
	can_sleep = true
	if voxel_owner != null and is_instance_valid(voxel_owner):
		voxel_owner.release_physics_hold("vehicle_driver:%d" % get_instance_id())
	_set_lights(false, false, false)
	driver_changed.emit(self, false)


func has_driver() -> bool:
	return _driver != null and is_instance_valid(_driver)


func can_enter(point: Vector3, maximum_distance := ENTER_DISTANCE) -> bool:
	return not has_driver() and _wheels.size() >= 2 \
		and get_seat_position().distance_to(point) <= maximum_distance


func get_seat_position() -> Vector3:
	return to_global(_seat_local)


func get_exit_position() -> Vector3:
	return get_seat_position() + global_basis.x.normalized() * 2.1 + Vector3.UP * 0.25


func get_camera_target() -> Vector3:
	return get_seat_position() + Vector3.UP * 0.35


func get_driver_view_position() -> Vector3:
	# `player` ya suele estar a la altura de la cabeza en los XML de Teardown (1,25–2,2 m).
	# Un pequeño avance evita z-fighting con el respaldo sin colocar la vista sobre el capot.
	return get_seat_position() + forward_direction() * 0.08


func get_camera_collision_rids() -> Array[RID]:
	var result: Array[RID] = []
	if voxel_owner != null and is_instance_valid(voxel_owner):
		result.append_array(voxel_owner.get_collision_rids())
	if _visual_body != null and is_instance_valid(_visual_body):
		result.append_array(_visual_body.get_collision_rids())
	return result


func forward_direction() -> Vector3:
	return global_basis.z.normalized()


func speed_kmh() -> float:
	return linear_velocity.length() * 3.6


func set_control_override(enabled: bool, throttle := 0.0, steer_input := 0.0, handbrake := false) -> void:
	_control_override = enabled
	_override_throttle = clampf(throttle, -1.0, 1.0)
	_override_steer = clampf(steer_input, -1.0, 1.0)
	_override_handbrake = handbrake
	set_physics_process(enabled or has_driver() or not sleeping)


func headlights_active() -> bool:
	return not _headlights.is_empty() and _headlights[0].visible


func brake_lights_active() -> bool:
	return not _brake_lights.is_empty() and _brake_lights[0].visible


func reverse_lights_active() -> bool:
	return not _reverse_lights.is_empty() and _reverse_lights[0].visible


func projected_light_count() -> int:
	return _headlights.size() + _brake_lights.size() + _reverse_lights.size()


func get_wheel_telemetry() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for wheel in _wheels:
		result.append({
			"position": wheel.position,
			"radius": wheel.wheel_radius,
			"rest": wheel.wheel_rest_length,
			"contact": wheel.is_in_contact(),
			"steer": wheel.use_as_steering,
			"drive": wheel.use_as_traction,
		})
	return result


func park_after_sleep() -> void:
	if has_driver() or _control_override:
		return
	engine_force = 0.0
	brake = coast_brake
	_set_lights(false, false, false)
	_sync_wheel_visuals()
	set_physics_process(false)


func _physics_process(delta: float) -> void:
	_retune_for_mass(false)
	if not has_driver() and not _control_override:
		engine_force = 0.0
		brake = coast_brake
		_set_lights(false, false, false)
		_sync_wheel_visuals()
		return
	var throttle := _override_throttle if _control_override else (
		Input.get_action_strength("move_forward") - Input.get_action_strength("move_back")
	)
	var steer_input := _override_steer if _control_override else (
		Input.get_action_strength("move_left") - Input.get_action_strength("move_right")
	)
	var handbrake := _override_handbrake if _control_override else Input.is_action_pressed("jump")
	var longitudinal_speed := linear_velocity.dot(forward_direction())
	var opposing := absf(longitudinal_speed) > 1.0 and throttle * longitudinal_speed < -0.15
	var speed_fraction := clampf(speed_kmh() / max_speed_kmh, 0.0, 1.0)
	var engine_limit := mass * acceleration * 0.52
	engine_force = 0.0 if opposing or handbrake \
		else throttle * engine_limit * maxf(0.0, 1.0 - speed_fraction)
	if handbrake:
		brake = service_brake * 1.35
	elif opposing:
		brake = service_brake
	elif is_zero_approx(throttle):
		brake = coast_brake
	else:
		brake = 0.0
	var steer_limit := lerpf(max_steer, min_steer, speed_fraction)
	steering = move_toward(steering, steer_input * steer_limit, steer_speed * delta)
	sleeping = false
	_set_lights(true, handbrake or opposing, throttle < -0.05 and longitudinal_speed < 1.0)
	_sync_wheel_visuals()


func _on_sleeping_state_changed() -> void:
	# Un coche estacionado no necesita ejecutar GDScript. Jolt lo vuelve a despertar por contacto y
	# esta señal reactiva entonces el controlador/seguimiento visual sin polling global.
	set_physics_process(has_driver() or _control_override or not sleeping)


func _sync_wheel_visuals() -> void:
	if _wheel_visuals.is_empty():
		return
	var moving := has_driver() or _control_override or not sleeping
	var visual_rigid := _visual_body.get_physics_body() as RigidBody3D \
		if _visual_body != null and is_instance_valid(_visual_body) else null
	if visual_rigid != null:
		visual_rigid.sleeping = not moving
	if not moving:
		return
	for record: Dictionary in _wheel_visuals:
		var wheel := record.wheel as VehicleWheel3D
		var shape := record.shape as VoxelShape3D
		if is_instance_valid(wheel) and is_instance_valid(shape):
			shape.global_transform = wheel.global_transform * (record.local as Transform3D)


func _set_lights(headlights: bool, braking: bool, reversing: bool) -> void:
	for light in _headlights:
		light.visible = headlights
	for light in _brake_lights:
		light.visible = braking
	for light in _reverse_lights:
		light.visible = reversing


func _retune_for_mass(force := false) -> void:
	if not force and is_equal_approx(_last_mass, mass):
		return
	_last_mass = mass
	service_brake = clampf(mass * 0.055, 55.0, 260.0)
	coast_brake = clampf(mass * 0.0045, 5.0, 24.0)
	var per_wheel := mass * 9.8 / maxf(1.0, float(_wheels.size()))
	for wheel in _wheels:
		wheel.suspension_max_force = maxf(6000.0, per_wheel * 4.0)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if voxel_owner == null or not is_instance_valid(voxel_owner) \
			or voxel_owner.collision_handoff_pending:
		return
	if state.get_contact_count() == 0:
		return
	var contacts := {}
	for index in state.get_contact_count():
		var collider := state.get_contact_collider_object(index)
		var collider_id := collider.get_instance_id() if collider != null else 0
		var relative_velocity := state.get_contact_local_velocity_at_position(index) \
			- state.get_contact_collider_velocity_at_position(index)
		var speed := contact_normal_speed(relative_velocity, state.get_contact_local_normal(index))
		if speed < IMPACT_MIN_SPEED:
			continue
		var impulse := state.get_contact_impulse(index).length()
		if impulse <= 0.0:
			continue
		# A pesar del nombre histórico, Godot documenta esta posición en coordenadas globales.
		# Transformarla otra vez desplazaba el cráter lejos de un coche rotado/alejado del origen.
		var point := state.get_contact_local_position(index)
		var record: Dictionary = contacts.get(collider_id, {
			"collider": collider, "impulse": 0.0, "speed": 0.0, "point": point,
		})
		record.impulse = float(record.impulse) + impulse
		if speed > float(record.speed):
			record.speed = speed
			record.point = point
		contacts[collider_id] = record
	var frame := Engine.get_physics_frames()
	for collider_id: int in contacts:
		var record: Dictionary = contacts[collider_id]
		if float(record.impulse) < IMPACT_MIN_IMPULSE \
				or frame - int(_last_report_frame.get(collider_id, -IMPACT_COOLDOWN_FRAMES)) \
				< IMPACT_COOLDOWN_FRAMES:
			continue
		_last_report_frame[collider_id] = frame
		voxel_owner.report_physics_impact.call_deferred(
			record.collider, record.point, float(record.impulse), float(record.speed)
		)


## Solo la componente que cierra el contacto puede romper voxeles. Usar `velocity.length()` hacia
## que un coche a 60 km/h sobre una carretera horizontal generase daño cada 12 frames aunque su
## velocidad contra la normal del suelo fuese casi cero: esa cola de cráteres era la caída de FPS.
static func contact_normal_speed(
	relative_velocity: Vector3, contact_normal: Vector3
) -> float:
	# En esta API "local" identifica el lado local del par de contacto; el vector ya comparte el
	# marco global de las velocidades (igual que `get_contact_local_position`, documentada global).
	return absf(relative_velocity.dot(contact_normal.normalized()))


func _exit_tree() -> void:
	if has_driver() and _driver.has_method("on_vehicle_removed"):
		_driver.call_deferred("on_vehicle_removed", self)


static func _travel(attributes: Dictionary) -> Vector2:
	var parts := String(attributes.get("travel", "-0.1 0.2")).split(" ", false)
	if parts.size() < 2:
		return Vector2(0.1, 0.2)
	return Vector2(absf(float(parts[0])), absf(float(parts[1])))


static func _wheel_radius(shapes: Array) -> float:
	if shapes.is_empty() or not is_instance_valid(shapes[0]):
		return 0.42
	var bounds := (shapes[0] as VoxelShape3D).world_bounds()
	return clampf(maxf(bounds.size.y, minf(bounds.size.x, bounds.size.z)) * 0.5, 0.24, 0.78)


static func _parse_color(text: String) -> Color:
	var parts := text.split(" ", false)
	return Color(
		float(parts[0]) if parts.size() > 0 else 1.0,
		float(parts[1]) if parts.size() > 1 else 1.0,
		float(parts[2]) if parts.size() > 2 else 1.0,
		1.0
	)


static func _vehicle_name(tags: String, sound: String) -> String:
	for candidate in ["suv", "truck", "van", "car", "bus", "tractor"]:
		if candidate in tags.to_lower():
			return candidate.to_upper() if candidate == "suv" else candidate
	var clean := sound.get_slice(" ", 0).strip_edges()
	return clean if not clean.is_empty() else "vehiculo"
