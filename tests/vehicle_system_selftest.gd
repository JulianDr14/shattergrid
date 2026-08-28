extends SceneTree
## Regresion sobre el SUV authored de Lee: XML -> VehicleBody -> suspension -> luces DDA.

var MAP := VoxelProjectPaths.teardown_map_path()
const SUV_CENTER := Vector3(-16.1, 0.0, 21.5)

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _make_wood_wall(
	world: VoxelWorld3D, origin: Vector3, basis := Basis.IDENTITY
) -> Dictionary:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.STATIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(30, 24, 3)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color(0.42, 0.25, 0.11), "hardness": 1.0, "density": 700.0,
	})
	shape.anchored = false
	shape.transform = Transform3D(basis, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return {"body": body, "shape": shape}


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		printerr("VOXEL_VEHICLE_SELFTEST_SKIP falta copia local de Lee")
		quit(0)
		return
	var world := VoxelWorld3D.new()
	world.name = "World"
	world.show_diagnostics = false
	root.add_child(world)
	var report := TeardownMapImporter.import_map(world, MAP, SUV_CENTER, 8.0, Vector3.ZERO, true)
	_check(int(report.get("vehicles_declared", 0)) >= 20, "se censan los vehicle del main.xml")
	_check(int(report.get("vehicles_drivable", 0)) >= 1, "el SUV recortado se promueve a conducible")
	var vehicles := get_nodes_in_group(VoxelVehicle3D.GROUP)
	_check(not vehicles.is_empty(), "existe un VehicleBody3D real")
	if vehicles.is_empty():
		_finish()
		return
	var vehicle := vehicles[0] as VoxelVehicle3D
	# El recorte por origen de Shape puede excluir el gran terreno que atraviesa esta zona aunque el
	# SUV sí entre. Un plano local a la cota authored aísla la prueba del tren motriz de ese detalle.
	var road := StaticBody3D.new()
	var road_collision := CollisionShape3D.new()
	var road_shape := BoxShape3D.new()
	road_shape.size = Vector3(30.0, 0.4, 30.0)
	road_collision.shape = road_shape
	road.position.y = 0.9
	road.add_child(road_collision)
	root.add_child(road)
	_check(vehicle.get_child_count() >= 4, "se crearon los cuatro raycasts de suspension")
	_check(vehicle.voxel_owner != null and vehicle.voxel_owner.get_physics_body() == vehicle,
		"la carroceria destructible y el vehiculo comparten una sola verdad fisica")
	var wheel_visual_body := vehicle.voxel_owner.get_meta(
		"teardown_vehicle_visual_body"
	) as VoxelBody3D
	var wheel_visual_shapes := wheel_visual_body.get_shapes() \
		if wheel_visual_body != null else [] as Array[VoxelShape3D]
	_check(wheel_visual_shapes.size() >= 4,
		"las cuatro ruedas authored conservan sus Shapes visuales")
	_check(wheel_visual_body != null and world.get_transform_tracked_body_ids().has(
		wheel_visual_body.get_instance_id()
	), "el renderer sigue las ruedas aunque su Body auxiliar este congelado")
	var transform_probe := VoxelTransformTracker.new()
	var tracked_snapshot := transform_probe.collect(world.get_transform_tracked_body_ids())
	var tracked_wheel_shapes := 0
	var initial_wheel_origins := {}
	for shape_variant: Variant in tracked_snapshot.shapes:
		if wheel_visual_shapes.has(shape_variant):
			tracked_wheel_shapes += 1
			initial_wheel_origins[(shape_variant as VoxelShape3D).get_instance_id()] = (
				shape_variant as VoxelShape3D
			).global_position
	_check(tracked_wheel_shapes == wheel_visual_shapes.size(),
		"todas las Shapes de rueda llegan al lote nativo de transformadas")
	_check(vehicle.wheel_visual_faces_outward(),
		"llantas y tapacubos authored quedan orientados hacia fuera")
	_check(vehicle.voxel_owner.continuous_collision,
		"el vehículo conserva la capacidad de CCD contra paredes delgadas")
	_check(vehicle.voxel_owner.compound_boxes <= VoxelVehicle3D.COLLISION_BOX_BUDGET,
		"la carrocería usa como máximo %d cajas Jolt (usa %d)" % [
			VoxelVehicle3D.COLLISION_BOX_BUDGET, vehicle.voxel_owner.compound_boxes,
		])
	_check(int(vehicle.voxel_owner.get_meta("voxel_shadow_interval_frames", 1)) \
			== VoxelVehicle3D.SHADOW_UPDATE_INTERVAL_FRAMES,
		"la sombra volumétrica vehicular se limita a 10 Hz sin limitar la geometría")
	vehicle.linear_velocity = Vector3(2.0, 0.0, 0.0)
	vehicle.voxel_owner.update_adaptive_ccd()
	_check(not vehicle.continuous_cd, "CCD permanece apagado a baja velocidad")
	vehicle.linear_velocity = Vector3(VoxelVehicle3D.CCD_MIN_SPEED + 1.0, 0.0, 0.0)
	vehicle.voxel_owner.update_adaptive_ccd()
	_check(vehicle.continuous_cd, "CCD se activa cuando existe riesgo de atravesar una pared")
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.voxel_owner.update_adaptive_ccd()
	_check(vehicle.mass > 900.0 and vehicle.mass < 2600.0,
		"la masa vehicular queda en un rango plausible (%.1f kg)" % vehicle.mass)
	_check(is_equal_approx(vehicle.impact_strength, 8.0),
		"se conserva strength=8 authored para el perfil de choque del SUV")
	_check(vehicle.center_of_mass.y < 0.7,
		"el centro de masa queda bajo para no volcar en giros")
	_check(vehicle.projected_light_count() >= 6,
		"faros, freno y reversa son Light3D proyectadas")
	var driver := Node3D.new()
	root.add_child(driver)
	_check(vehicle.set_driver(driver), "un conductor puede ocupar el asiento")
	_check(vehicle.headlights_active(), "al entrar se encienden los faros")
	vehicle.set_control_override(true, 1.0, 0.35, false)
	for _frame in 3:
		await physics_frame
	_check(vehicle.engine_force > 0.0, "W acelera y entrega fuerza al tren motriz")
	_check(absf(vehicle.steering) > 0.01, "A/D mueven la direccion")
	var drive_start := Vector2(vehicle.global_position.x, vehicle.global_position.z)
	for _frame in 90:
		await physics_frame
	var planar_distance := drive_start.distance_to(
		Vector2(vehicle.global_position.x, vehicle.global_position.z)
	)
	_check(planar_distance > 0.35,
		"la suspension transmite la fuerza al suelo (avance %.2f m)" % planar_distance)
	var moved_snapshot := transform_probe.collect(world.get_transform_tracked_body_ids())
	var moved_wheel_visuals := 0
	for index in mini(moved_snapshot.shapes.size(), moved_snapshot.transforms.size()):
		var moved_shape := moved_snapshot.shapes[index] as VoxelShape3D
		if moved_shape == null or not initial_wheel_origins.has(moved_shape.get_instance_id()):
			continue
		var moved_transform := moved_snapshot.transforms[index] as Transform3D
		if moved_transform.origin.distance_to(initial_wheel_origins[moved_shape.get_instance_id()]) \
				> 0.35:
			moved_wheel_visuals += 1
	_check(moved_wheel_visuals == wheel_visual_shapes.size(),
		"los visuales de rueda avanzan con el coche hasta el renderer")
	var contacts := 0
	for wheel: Dictionary in vehicle.get_wheel_telemetry():
		contacts += 1 if bool(wheel.contact) else 0
	_check(contacts >= 2, "al menos dos ruedas conservan contacto al girar")
	_check(vehicle.global_basis.y.normalized().dot(Vector3.UP) > 0.55,
		"el centro de masa rebajado evita un vuelco inmediato")
	_check(is_zero_approx(VoxelVehicle3D.contact_normal_speed(
		Vector3(14.0, 0.0, 0.0), Vector3.UP
	)), "rodar tangencialmente sobre el suelo no genera daño voxel")
	_check(is_equal_approx(VoxelVehicle3D.contact_normal_speed(
		Vector3(0.0, -4.0, 0.0), Vector3.UP
	), 4.0), "la velocidad que cierra la normal sí se reconoce como impacto")
	var impact_profile := VoxelWorld3D.physics_impact_profile(
		vehicle.voxel_owner, 400.0, 3.0
	)
	_check(bool(impact_profile.get("vehicle", false)) \
			and float(impact_profile.get("radius", 0.0)) >= 1.0,
		"el SUV abre un paso frontal de tamaño vehicular a velocidad urbana")
	vehicle.set_control_override(true, 0.0, 0.0, true)
	await physics_frame
	_check(vehicle.brake > vehicle.coast_brake and vehicle.brake_lights_active(),
		"el freno de mano aplica fuerza y proyecta luz roja")
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.set_control_override(true, -1.0, 0.0, false)
	await physics_frame
	_check(vehicle.engine_force < 0.0 and vehicle.reverse_lights_active(),
		"la marcha atras entrega fuerza e ilumina en blanco")

	# Choque real (no una llamada directa al daño): acelera el SUV contra un paño de madera de 30 cm.
	# Esto cubre contacto Jolt -> velocidad normal -> cola diferida -> perfil vehicular -> cráter.
	vehicle.linear_velocity = Vector3.ZERO
	vehicle.angular_velocity = Vector3.ZERO
	var crash_forward := vehicle.forward_direction()
	var crash_right := Vector3.UP.cross(crash_forward).normalized()
	var wall_basis := Basis(crash_right, Vector3.UP, crash_forward).orthonormalized()
	var wall_center := vehicle.global_position + crash_forward * 4.2
	wall_center.y = 2.1
	var wall := _make_wood_wall(world, wall_center, wall_basis)
	var wall_shape := wall.shape as VoxelShape3D
	var wall_before := wall_shape.voxel_count()
	var vehicle_before := vehicle.voxel_owner.get_total_voxels()
	var impacts_before := world.physics_impacts
	vehicle.set_control_override(true, 1.0, 0.0, false)
	for _frame in 180:
		await physics_frame
		if is_instance_valid(wall_shape) and wall_shape.voxel_count() < wall_before:
			break
	var wall_after := wall_shape.voxel_count() if is_instance_valid(wall_shape) else 0
	print("  choque vehículo: pared %d→%d posición=%s pared_pos=%s velocidad=%.2f" % [
		wall_before, wall_after, vehicle.global_position, wall_center, vehicle.linear_velocity.length(),
	])
	_check(world.physics_impacts > impacts_before and wall_after < wall_before,
		"el coche atraviesa madera normal mediante un contacto Jolt real")
	_check(vehicle.voxel_owner.get_total_voxels() == vehicle_before,
		"el perfil frontal no perfora la propia carrocería al abrir madera")
	_check(String(world.last_physics_impact.get("kind", "")) == "vehicle",
		"el diagnóstico distingue el impacto vehicular")
	vehicle.set_control_override(true, 0.0, 0.0, true)
	await physics_frame

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = vehicle.global_position + Vector3.UP * 3.0
	var pool := VoxelLocalShadowPool.new()
	root.add_child(pool)
	pool.setup(world, camera)
	for _frame in 3:
		await process_frame
	var metadata := pool.get_shader_metadata()
	_check(int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16]) >= 2,
		"los faros llegan al pase DDA voxel")
	_check(int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16 + 1]) == 0,
		"los faros moviles no recocinan volumenes 128^3 por frame")
	vehicle.clear_driver(driver)
	vehicle.set_control_override(false)
	_check(not vehicle.headlights_active(), "al salir se apagan las luces")
	var level := Node3D.new()
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	var interaction := Label.new()
	interaction.name = "Interaction"
	hud.add_child(interaction)
	level.add_child(hud)
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/core/player.gd"))
	var player_camera := Camera3D.new()
	player_camera.name = "Camera3D"
	player_camera.position = Vector3(0.0, 1.65, 0.0)
	player.add_child(player_camera)
	var player_collision := CollisionShape3D.new()
	player_collision.position.y = 0.9
	var player_capsule := CapsuleShape3D.new()
	player_capsule.radius = 0.38
	player_capsule.height = 1.8
	player_collision.shape = player_capsule
	player.add_child(player_collision)
	level.add_child(player)
	root.add_child(level)
	await process_frame
	player.global_position = vehicle.get_seat_position()
	var original_fov := player_camera.fov
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")) and player.collision_layer == 0,
		"E ocupa el vehículo y desactiva la cápsula del jugador")
	_check(vehicle.headlights_active(), "la ruta real de E también enciende faros")
	var pitch_before := float(player.get("_vehicle_camera_pitch"))
	_check(float(player.call(
		"vehicle_camera_pitch_after_input", pitch_before, 12.0
	)) > pitch_before,
		"el eje vertical del orbitador quedó invertido")
	var zoom_in := InputEventMouseButton.new()
	zoom_in.button_index = MOUSE_BUTTON_WHEEL_UP
	zoom_in.pressed = true
	for _step in 8:
		player.call("_unhandled_input", zoom_in)
	_check(bool(player.call("vehicle_camera_is_interior")),
		"la rueda lleva el zoom hasta la vista interior")
	player.call("_update_vehicle_camera", 1.0)
	_check(player_camera.global_position.distance_to(vehicle.get_driver_view_position()) < 0.15,
		"la vista interior usa el punto de conductor authored del XML")
	player.call("_toggle_vehicle")
	_check(not bool(player.call("is_driving_vehicle")) and player.collision_layer != 0,
		"un segundo E deja al jugador junto al vehículo")
	_check(is_equal_approx(player_camera.fov, original_fov),
		"salir restaura el FOV de la cámara a pie")

	# Regresión de la captura: con el coche de lado, su eje local X apunta contra el suelo. La salida
	# antigua sumaba ese eje al asiento y colocaba la cápsula debajo del mapa al pulsar E en marcha.
	vehicle.freeze = true
	vehicle.global_position = Vector3(0.0, 2.0, 0.0)
	vehicle.rotation = Vector3(0.0, 0.0, PI * 0.5)
	await physics_frame
	player.global_position = vehicle.get_seat_position()
	player.call("_toggle_vehicle")
	vehicle.linear_velocity = Vector3(9.0, 0.0, 0.0)
	player.call("_toggle_vehicle")
	_check(player.global_position.y >= 1.1 \
			and player.global_position.distance_to(vehicle.global_position) > 1.5,
		"salir de un coche volcado en movimiento deja al jugador sobre el piso y fuera del compound")
	vehicle.freeze = false

	vehicle.sleeping = true
	vehicle.park_after_sleep()
	_check(not vehicle.is_physics_processing(),
		"el coche estacionado suspende su controlador GDScript")
	vehicle.apply_central_impulse(Vector3(120.0, 0.0, 0.0))
	for _frame in 2:
		await physics_frame
	_check(vehicle.is_physics_processing(), "un contacto/despertar reactiva el controlador")
	world.unregister_body(vehicle.voxel_owner)
	vehicle.voxel_owner.queue_free()
	await process_frame
	_check(not is_instance_valid(wheel_visual_body),
		"destruir la carrocería limpia también las ruedas visuales")
	_finish()


func _finish() -> void:
	if failures == 0:
		print("VOXEL_VEHICLE_SELFTEST_OK")
	else:
		printerr("VOXEL_VEHICLE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
