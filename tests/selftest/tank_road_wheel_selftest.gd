extends SceneTree
## Rodillos del tren de rodaje: giran con el avance y suben/bajan con la suspensión, sin que sacar
## su arte del casco cambie la altura a la que el tanque descansa.

class Gunner:
	extends Node3D
	var camera: Camera3D

	func _init() -> void:
		camera = Camera3D.new()
		add_child(camera)


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
	print("rodillos del tanque")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(60, 1, 60)
	floor_shape.shape = box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)

	var gunner := Gunner.new()
	root.add_child(gunner)
	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0), gunner)
	_check(tank != null, "el tanque se importa")
	if tank == null:
		quit(1)
		return

	for _frame in 150:
		await physics_frame
	var bottom := tank.hull.get_shapes()[0].world_bounds().position.y
	print("  altura de reposo del casco: %.3f m" % bottom)
	# Referencia medida con el tren de rodaje horneado en el casco, antes de sacarlo a visuales.
	_check(absf(bottom - 0.154) < 0.06, "el tanque descansa a la misma altura que antes")

	var visuals: Array = tank.vehicle._wheel_visuals
	_check(visuals.size() == 14, "los catorce rodillos del arte son visuales de rueda")
	if visuals.is_empty():
		quit(1)
		return
	var probe := visuals[0].shape as VoxelShape3D
	var rest_basis := probe.global_basis
	var rest_height := probe.global_position.y - bottom

	# El disco está pintado en el casco entre 0.20 y 1.10 m sobre su suelo: si el muelle lo deja en
	# otro sitio, los rodillos cuelgan por debajo de la oruga y el tanque se ve roto.
	print("  altura del rodillo asentado: %.3f m sobre el casco" % rest_height)
	_check(absf(rest_height - 0.65) < 0.08, "el rodillo asentado queda donde lo pintó el arte")
	var start := tank.hull_transform().origin
	tank.vehicle.set_control_override(true, 1.0, 0.0, false)
	var spin := 0.0
	var travel := 0.0
	for _frame in 300:
		await physics_frame
		var now := probe.global_basis
		spin = maxf(spin, maxf(
			rest_basis.x.angle_to(now.x),
			maxf(rest_basis.y.angle_to(now.y), rest_basis.z.angle_to(now.z))
		))
		travel = maxf(travel, absf(
			probe.global_position.y - tank.hull.get_shapes()[0].world_bounds().position.y
			- rest_height
		))
	tank.vehicle.set_control_override(false)
	print("  avance del tanque: %.2f m" % start.distance_to(tank.hull_transform().origin))
	print("  giro máximo del rodillo: %.1f grados; recorrido: %.3f m" % [
		rad_to_deg(spin), travel
	])
	_check(spin > 0.5, "los rodillos ruedan al avanzar")
	_check(travel > 0.01, "los rodillos se mueven con la suspensión respecto al casco")

	print("fallos: ", failures)
	quit(1 if failures > 0 else 0)
