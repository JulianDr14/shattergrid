extends "res://tests/selftest/selftest.gd"
## Fogonazo de boca: sale por el bocacho, mirando por el ánima, y el cañón respeta su cadencia.

class Gunner:
	extends Node3D
	var camera: Camera3D
	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


func _run() -> void:
	print("fogonazo del tanque")
	var world := make_world()
	make_box_body(world, Vector3(80, 1, 80), Vector3(0, -0.5, 0))
	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null and tank.barrel != null, "el tanque se importa con cañón")
	if tank == null or tank.barrel == null:
		quit(1)
		return
	for _frame in 120:
		await physics_frame

	var muzzle := tank.muzzle_transform()
	var turret_center := tank.turret.get_shapes()[0].world_bounds().get_center()
	var barrel_center := tank.barrel.get_shapes()[0].world_bounds().get_center()
	var forward := -muzzle.basis.z
	print("  bocacho: %v  eje: %v" % [muzzle.origin, forward])
	# El bocacho está más lejos de la torreta que el propio centro del ánima: si el signo del eje
	# se invierte, la llamarada sale por dentro de la torreta y hacia el conductor.
	_check(
		muzzle.origin.distance_to(turret_center) > barrel_center.distance_to(turret_center) + 1.0,
		"el bocacho está por delante del cañón, no detrás"
	)
	_check(
		forward.dot((barrel_center - turret_center).normalized()) > 0.9,
		"el eje del fogonazo sigue el ánima"
	)
	_check(absf(forward.y) < 0.45, "el cañón en reposo no apunta al cielo ni al suelo")

	var before := int(world.get_metrics().get("active_particles", 0))
	var hull_physics := tank.hull.get_physics_body()
	var rest_pitch := tank.hull_transform().basis.x.y
	_check(tank.fire(), "el cañón dispara")
	await process_frame
	var after := int(world.get_metrics().get("active_particles", 0))
	print("  puffs: %d -> %d" % [before, after])
	# Pocos y grandes: fuego, anillo, humo y cortina de suelo. Si esto se dispara a los cientos es
	# que alguien ha vuelto a los cubitos, y los cubitos parecen bichos.
	_check(after > before + 200 and after < before + 500, "el disparo llena la boca de fuego y humo")

	var kick := 0.0
	for _frame in 30:
		await physics_frame
		kick = maxf(kick, absf(tank.hull_transform().basis.x.y - rest_pitch))
	print("  masa del casco: %.0f kg; encabritado: %.3f" % [hull_physics.mass, kick])
	# Un culatazo que se lee sin llegar a lanzar el carro: entre uno y siete grados de encabritado.
	_check(kick > 0.015 and kick < 0.13, "el culatazo encabrita el carro sin despegarlo")
	_check(not tank.fire(), "el cañón no vuelve a disparar mientras recarga")

	print("fallos: ", failures)
	quit(1 if failures > 0 else 0)
