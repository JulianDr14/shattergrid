extends SceneTree
## Regresión de gameplay: entrada de un RigidBody, flotación/drag y jugador retenido en superficie.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _make_water(parent: Node) -> VoxelWaterSystem:
	var water := VoxelWaterSystem.new()
	parent.add_child(water)
	water.add_polygon(PackedVector3Array([
		Vector3(-10, 0, -10), Vector3(10, 0, -10),
		Vector3(10, 0, 10), Vector3(-10, 0, 10),
	]), Color(0.02, 0.08, 0.1), 3.0, 1.0, 10.0, 1.0)
	water.finish()
	return water


func _make_prop(world: VoxelWorld3D) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(6 * 6 * 6)
	cells.fill(1)
	shape.data.set_cells(Vector3i(6, 6, 6), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.BROWN, "hardness": 1.0, "density": 700.0,
	})
	shape.physical_fill_scale = 0.025
	shape.anchored = false
	shape.position = Vector3(0, 3.0, 0)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("interacción con agua")
	var vehicle_weight := 1500.0 * 9.8
	_check(VoxelWaterSystem.buoyancy_force_newtons(20.0, 1500.0, 9.8, true) \
			< vehicle_weight,
		"una carrocería abierta conserva peso descendente aun totalmente sumergida")
	_check(is_equal_approx(
		VoxelWaterSystem.buoyancy_force_newtons(0.001, 10.0, 9.8, false), 9.8
	), "la flotación normal depende del volumen de agua desplazado, no del peso del Body")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var water := _make_water(world)
	water.setup(world)
	var prop := _make_prop(world)
	var rigid := prop.get_physics_body() as RigidBody3D
	rigid.sleeping = false
	var minimum_y := INF
	for _frame in 240:
		await physics_frame
		minimum_y = minf(minimum_y, prop.get_shapes()[0].world_bounds().get_center().y)
	_check(water.splash_count >= 1, "un objeto que entra genera splash y onda")
	_check(minimum_y > -4.0 and rigid.linear_velocity.length() < 4.0,
		"flotación y drag frenan el objeto dentro del volumen")

	# El jugador empieza sumergido y cayendo. Sin natación estaría a -6 m tras un segundo; el
	# controlador lo lleva al objetivo de superficie (origen ≈ -1,15 m, cámara fuera del agua).
	var player := CharacterBody3D.new()
	player.name = "PlayerSwimProbe"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 1.65, 0)
	player.add_child(camera)
	var player_collision := CollisionShape3D.new()
	player_collision.name = "Collision"
	var player_capsule := CapsuleShape3D.new()
	player_capsule.radius = 0.4
	player_capsule.height = 1.8
	player_collision.position.y = 0.9
	player_collision.shape = player_capsule
	player.add_child(player_collision)
	player.set_script(load("res://scripts/player.gd"))
	root.add_child(player)
	player.global_position = Vector3(4.0, -1.0, 0.0)
	player.velocity = Vector3(0.0, -5.0, 0.0)
	var splashes_before := water.splash_count
	for _frame in 90:
		await physics_frame
	_check(player.global_position.y > -1.8,
		"el jugador permanece nadando cerca de la superficie")
	_check(water.splash_count > splashes_before,
		"la entrada del jugador también genera feedback de agua")

	# Un coche con el asiento bajo la lámina se cala de forma permanente y expulsa al jugador a una
	# posición de natación. Dos ruedas mínimas bastan para probar el estado sin importar un mapa entero.
	var vehicle := VoxelVehicle3D.new()
	vehicle.position = Vector3(-3.0, -0.25, 0.0)
	vehicle.rotation.z = PI
	var vehicle_collision := CollisionShape3D.new()
	var vehicle_box := BoxShape3D.new()
	vehicle_box.size = Vector3(2.0, 1.0, 4.0)
	vehicle_collision.shape = vehicle_box
	vehicle.add_child(vehicle_collision)
	root.add_child(vehicle)
	vehicle.add_to_group(VoxelVehicle3D.GROUP)
	for index in 2:
		var wheel := VehicleWheel3D.new()
		wheel.position.x = -0.7 if index == 0 else 0.7
		vehicle.add_child(wheel)
		vehicle._wheels.append(wheel)
	player.global_position = vehicle.get_seat_position()
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")), "el jugador ocupa el vehículo de prueba")
	vehicle.engine_force = 5000.0
	vehicle.update_water_submersion(0.7, 0.0)
	await process_frame
	await physics_frame
	_check(vehicle.is_water_disabled() and is_zero_approx(vehicle.engine_force),
		"al inundarse el motor queda apagado")
	_check(is_zero_approx(vehicle.brake) \
			and vehicle._wheels.all(func(wheel: VehicleWheel3D) -> bool:
				return is_zero_approx(wheel.suspension_max_force)),
		"el tren inundado no pelea contra el fondo con suspensión o freno de rueda")
	_check(not bool(player.call("is_driving_vehicle")) and player.global_position.is_finite() \
			and player.global_position.y > -1.5,
		"el conductor sale de un carro volcado dentro del volumen de natación, no bajo el mapa")
	_check(not vehicle.can_enter(player.global_position, 20.0),
		"un vehículo inundado no se puede volver a conducir")

	var seabed := StaticBody3D.new()
	var seabed_collision := CollisionShape3D.new()
	var seabed_box := BoxShape3D.new()
	seabed_box.size = Vector3(20.0, 0.4, 20.0)
	seabed_collision.shape = seabed_box
	seabed.add_child(seabed_collision)
	seabed.position.y = -2.8
	root.add_child(seabed)
	var late_angular_peak := 0.0
	for frame in 240:
		await physics_frame
		if frame >= 180:
			late_angular_peak = maxf(late_angular_peak, vehicle.angular_velocity.length())
	_check(vehicle.global_position.is_finite() and vehicle.global_position.y > -2.3,
		"la carrocería se apoya sobre el lecho sin quedar incrustada")
	_check(late_angular_peak < 1.0,
		"el vehículo inundado se asienta sin bailar contra el lecho")

	if failures == 0:
		print("VOXEL_WATER_INTERACTION_SELFTEST_OK")
	else:
		printerr("VOXEL_WATER_INTERACTION_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
