extends SceneTree
## Regresión: bajarse del vehículo no puede empujarlo.
##
## La cápsula del jugador viaja pegada al asiento, dentro del casco, con la colisión apagada. Si al
## salir se le devuelve la colisión en el mismo frame en que se la teletransporta fuera, Jolt lee
## ese salto como movimiento cinemático y la cápsula barre el vehículo de dentro afuera: medido, un
## pico de 220 m/s que mandaba el tanque por los aires y lo hundía en el suelo.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _make_player() -> CharacterBody3D:
	var player: CharacterBody3D = load("res://scripts/core/player.gd").new()
	player.collision_layer = 1
	player.collision_mask = 1
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	player.add_child(camera)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	player.add_child(collision)
	return player


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(80, 1, 80)
	floor_shape.shape = box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)

	var player := _make_player()
	root.add_child(player)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), player)
	if tank == null:
		printerr("TANK_EXIT_KICK_SELFTEST_SKIP no se pudo importar el tanque")
		quit(0)
		return
	for _frame in 90:
		await physics_frame

	player.global_position = tank.vehicle.get_seat_position()
	player.call("_toggle_vehicle")
	_check(bool(player.call("is_driving_vehicle")), "el jugador conduce el tanque")
	for _frame in 60:
		await physics_frame

	var before_y := tank.vehicle.global_position.y
	player.call("_toggle_vehicle")
	_check(not bool(player.call("is_driving_vehicle")), "el jugador se baja")
	var exit_position := player.global_position
	_check(bool(player.call("_vehicle_exit_is_clear", exit_position,
			[player.get_rid()] as Array[RID])),
		"la salida elegida no solapa con nada")

	var peak_speed := 0.0
	for _frame in 90:
		await physics_frame
		peak_speed = maxf(peak_speed, tank.vehicle.linear_velocity.length())
	print("     y antes=%.3f  y despues=%.3f  pico de velocidad=%.3f" % [
		before_y, tank.vehicle.global_position.y, peak_speed
	])
	_check(peak_speed < 1.5, "el tanque no recibe un empujón al bajarse el conductor")
	_check(absf(tank.vehicle.global_position.y - before_y) < 0.35,
		"el tanque no se clava ni salta en cota al bajarse el conductor")
	_check(player.global_position.distance_to(exit_position) < 0.5,
		"el jugador se queda donde se le dejó, no sale despedido")
	print("TANK_EXIT_KICK_SELFTEST ", "OK" if failures == 0 else "FALLOS: %d" % failures)
	quit(1 if failures > 0 else 0)
