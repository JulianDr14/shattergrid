extends SceneTree
## Regresion: al bajarse, el jugador nunca puede aparecer dentro del compound del vehiculo.
## Si los 7 candidates fallan, el fallback antiguo era la posicion de entrada -sin validar-, y con
## el vehiculo ya encima de ella la capsula nacia empotrada: Jolt separaba el contacto lanzando al
## jugador y clavando el vehiculo contra el suelo.

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


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		printerr("VEHICLE_EXIT_OVERLAP_SELFTEST_SKIP falta copia local de Lee")
		quit(0)
		return
	var world := VoxelWorld3D.new()
	world.name = "World"
	world.show_diagnostics = false
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, SUV_CENTER, 8.0, Vector3.ZERO, true)
	var vehicles := get_nodes_in_group(VoxelVehicle3D.GROUP)
	if vehicles.is_empty():
		printerr("VEHICLE_EXIT_OVERLAP_SELFTEST_SKIP sin vehiculo conducible")
		quit(0)
		return
	var vehicle := vehicles[0] as VoxelVehicle3D
	var road := StaticBody3D.new()
	var road_collision := CollisionShape3D.new()
	var road_shape := BoxShape3D.new()
	road_shape.size = Vector3(60.0, 0.4, 60.0)
	road_collision.shape = road_shape
	road.position = Vector3(vehicle.global_position.x, 0.9, vehicle.global_position.z)
	road.add_child(road_collision)
	root.add_child(road)

	var level := Node3D.new()
	var player: CharacterBody3D = load("res://scripts/core/player.gd").new()
	player.collision_layer = 1
	player.collision_mask = 1
	var player_camera := Camera3D.new()
	player_camera.name = "Camera3D"
	player.add_child(player_camera)
	var player_collision := CollisionShape3D.new()
	player_collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	player_collision.shape = capsule
	player_collision.position.y = 0.9
	player.add_child(player_collision)
	level.add_child(player)
	root.add_child(level)
	await process_frame

	player.global_position = vehicle.get_seat_position()
	var entry := player.global_position
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")), "el jugador entra al vehiculo")

	# "Conducir": el vehiculo acaba justo encima del punto de entrada, que es el fallback antiguo.
	vehicle.freeze = true
	await physics_frame
	vehicle.global_position += Vector3(0.0, 0.0, 0.0)
	# Muros a los cuatro costados para tumbar todos los candidates laterales.
	var bounds := vehicle.get_world_bounds()
	var radius := maxf(2.1, maxf(bounds.size.x, bounds.size.z) * 0.5 + 0.75)
	for offset in [Vector3(radius, 0, 0), Vector3(-radius, 0, 0),
			Vector3(0, 0, radius), Vector3(0, 0, -radius)]:
		var wall := StaticBody3D.new()
		var wall_collision := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = Vector3(radius * 2.4, 12.0, radius * 2.4)
		wall_collision.shape = wall_box
		wall.add_child(wall_collision)
		wall.position = bounds.get_center() + offset * 2.05
		root.add_child(wall)
	await physics_frame

	player.call("_toggle_vehicle")
	_check(not bool(player.call("is_driving_vehicle")), "el jugador se baja")
	var exit_position := player.global_position
	print("     entry=", entry, " exit=", exit_position)
	var compound := vehicle.get_world_bounds().grow(0.3)
	_check(not compound.has_point(exit_position)
			and not compound.has_point(exit_position + Vector3.UP * 0.9),
		"la posicion de salida cae fuera del compound del vehiculo")
	vehicle.freeze = false
	_finish()


func _finish() -> void:
	print("VEHICLE_EXIT_OVERLAP_SELFTEST ", "OK" if failures == 0 else "FALLOS: %d" % failures)
	quit(1 if failures > 0 else 0)
