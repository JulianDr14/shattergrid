extends SceneTree
## Regresión: girar el casco no puede arrastrar la torreta.
##
## El motor de la corona manda velocidad relativa al casco y `target_yaw` también es relativo, así
## que con la mira clavada en un punto del mundo el objetivo se mueve a -omega mientras el casco
## gira a omega. Un proporcional puro sólo sigue eso con un error permanente de omega/YAW_GAIN, y la
## torreta se veía girar con el cuerpo. El control lleva feedforward de la guiñada del casco.

const AIM_POINT := Vector3(0.0, 1.5, -60.0)
const HULL_YAW_RATE := 0.9

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


## Rumbo absoluto de la torreta en el mundo, con el mismo convenio que `VoxelTank3D._plane_yaw`.
func _turret_world_yaw(tank: VoxelTank3D) -> float:
	var basis := tank.turret.get_physics_body().global_basis
	return atan2(-basis.x.z, basis.x.x)


func _hull_world_yaw(tank: VoxelTank3D) -> float:
	var basis := tank.hull_transform().basis
	return atan2(-basis.x.z, basis.x.x)


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(120, 1, 120)
	floor_shape.shape = box
	floor_shape.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_shape)
	world.add_child(floor_body)

	var tank := VoxelTank3D.spawn(world, Vector3(0, 1.0, 0))
	if tank == null:
		printerr("TANK_TURRET_HULL_YAW_SELFTEST_SKIP no se pudo importar el tanque")
		quit(0)
		return
	for _frame in 90:
		await physics_frame

	# La corona parte ya encarada al punto de mira: lo que se mide es la deriva mientras el casco
	# gira, no el tiempo que tarda en apuntar.
	var hull_body := tank.hull.get_physics_body() as RigidBody3D
	for _frame in 120:
		var hull_now := tank.hull_transform()
		tank.target_yaw = VoxelTank3D.aim_yaw(AIM_POINT - hull_now.origin, hull_now.basis)
		await physics_frame
	var settled_yaw := _turret_world_yaw(tank)
	var hull_start_yaw := _hull_world_yaw(tank)

	# El casco gira sobre su eje a 0,9 rad/s: por encima de lo que un proporcional puro puede seguir
	# sin desfase, y por debajo del tope de compensación.
	var peak_drift := 0.0
	for _frame in 150:
		hull_body.angular_velocity = Vector3(0.0, HULL_YAW_RATE, 0.0)
		var hull_now := tank.hull_transform()
		tank.target_yaw = VoxelTank3D.aim_yaw(AIM_POINT - hull_now.origin, hull_now.basis)
		await physics_frame
		peak_drift = maxf(peak_drift, absf(wrapf(_turret_world_yaw(tank) - settled_yaw, -PI, PI)))

	var hull_turned := absf(wrapf(_hull_world_yaw(tank) - hull_start_yaw, -PI, PI))
	print("     el casco giró %.1f grados · deriva máxima de la torreta %.1f grados" % [
		rad_to_deg(hull_turned), rad_to_deg(peak_drift)
	])
	_check(hull_turned > 0.7, "el casco llegó a girar de verdad durante la prueba")
	_check(peak_drift < deg_to_rad(4.0),
		"la torreta se mantiene sobre el punto del mundo mientras gira el casco")
	print("TANK_TURRET_HULL_YAW_SELFTEST ", "OK" if failures == 0 else "FALLOS: %d" % failures)
	quit(1 if failures > 0 else 0)
