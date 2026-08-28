extends SceneTree
## Regresión completa del tanque: puntería, control diferencial, corona bajo carga y desprendimiento
## exclusivo por explosión.

const Player := preload("res://scripts/core/player.gd")

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


func _discard_test_tank(world: VoxelWorld3D, tank: VoxelTank3D) -> void:
	# Cada escenario debe dejar el espacio físico libre para el siguiente; los Bodies son hermanos
	# del controlador dentro de VoxelWorld, no hijos que desaparezcan al borrar `tank`.
	if tank._joints != null and is_instance_valid(tank._joints):
		tank._joints.break_record(tank._joint_record)
	for body in [tank.hull, tank.turret]:
		if body != null and is_instance_valid(body):
			world.unregister_body(body)
	for node in [tank.hull, tank.turret, tank]:
		if node != null and is_instance_valid(node):
			node.queue_free()


func _run() -> void:
	print("torreta del tanque")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
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

	for _frame in 20:
		await physics_frame
	var joints := world.get_node_or_null("VoxelTankJoints") as VoxelJoints
	_check(joints != null, "el tanque es dueño de su registro de corona")
	_check(joints.live_count() == 1, "la corona entra viva")
	_check(tank.vehicle.attached_bodies().size() == 2,
		"cámara y colisiones reconocen casco y torreta como un solo tanque")
	var camera_profile := tank.vehicle.get_camera_profile()
	_check(is_equal_approx(float(camera_profile.distance), 8.4)
		and is_equal_approx(float(camera_profile.fov), 78.0),
		"el tanque expone su perfil de cámara arcade")
	# Se comprueba la punteria, no el angulo crudo: el marco fisico del casco esta rotado respecto
	# al modelo, asi que `yaw()` es un numero interno. Lo que tiene que cumplirse es que el canon
	# acabe siguiendo la línea de la cámara que mueve el ratón.
	var target := Vector3(20, 1, -14)
	gunner.camera.global_position = Vector3(-10, 5, 12)
	gunner.camera.look_at(target)
	_check(tank.vehicle.set_driver(gunner), "el artillero ocupa el tanque")
	for _frame in 420:
		await physics_frame
	# El canon del modelo mira al +X de la torreta, que entra sin rotar.
	var barrel := tank.turret.get_physics_body().global_basis.x
	var wanted := target - tank.hull_transform().origin
	barrel.y = 0.0
	wanted.y = 0.0
	var off := absf(barrel.normalized().angle_to(wanted.normalized()))
	print("  desvio del canon: %.1f grados" % rad_to_deg(off))
	_check(off < 0.15, "la torreta sigue la mira de la cámara")
	tank.vehicle.clear_driver(gunner)

	# El cañón sigue horizontal: si el eje de la bisagra fuese el equivocado, la torreta habría
	# cabeceado en vez de rotar.
	var up := tank.turret.get_physics_body().global_basis.y
	_check(up.dot(Vector3.UP) > 0.95, "la torreta no cabecea: el eje es el vertical")

	# El mapa deja caer al jugador desde 30 m y el tanque cae con el. Si el golpe separa los dos
	# anclajes mas de `BREAK_SEPARATION`, `VoxelJoints` da la corona por reventada y el tanque
	# aterriza sin torreta.
	var dropped := VoxelTank3D.spawn(world, Vector3(12, 30.0, 0))
	for _frame in 300:
		if not is_instance_valid(dropped.hull) or not is_instance_valid(dropped.turret):
			break
		# Sin jugador, el presupuesto de física retira los cuerpos lejanos: hay que mantenerlos
		# despiertos a mano para que la caída ocurra de verdad.
		dropped.hull.wake_for_interaction()
		dropped.turret.wake_for_interaction()
		await physics_frame
	_check(joints.live_count() == 2, "la corona aguanta una caida de 30 m")
	print("  altura tras caer: %.2f" % dropped.hull_transform().origin.y)

	# Un control diferencial debe poder pivotar parado. El override usa exactamente la misma entrada
	# efectiva que A/D durante el juego; antes el tanque releía Input y esta ruta no era verificable.
	var driver := Node3D.new()
	root.add_child(driver)
	_check(tank.vehicle.set_driver(driver), "el conductor ocupa el tanque")
	var forward_before := tank.vehicle.forward_direction()
	tank.vehicle.set_control_override(true, 0.0, 1.0, false)
	var worst_separation := 0.0
	for _frame in 120:
		await physics_frame
		worst_separation = maxf(worst_separation, tank.turret_anchor_separation())
	var turn_angle := forward_before.angle_to(tank.vehicle.forward_direction())
	print("  giro A/D: %.1f grados; separacion corona: %.3f m" % [
		rad_to_deg(turn_angle), worst_separation,
	])
	_check(turn_angle > 0.7, "A/D hacen pivotar las orugas incluso desde parado")
	_check(tank.is_turret_attached(), "girar no desprende la torreta")
	_check(worst_separation < VoxelJoints.BREAK_SEPARATION,
		"la corona permanece físicamente cerrada durante el giro")

	# W transmite tracción sin convertir A/D en dirección de automóvil.
	var drive_start := tank.vehicle.global_position
	tank.vehicle.set_control_override(true, 1.0, 0.0, false)
	for _frame in 120:
		await physics_frame
	_check(tank.vehicle.global_position.distance_to(drive_start) > 0.5,
		"W hace avanzar el tanque")
	_check(tank.is_turret_attached(), "acelerar no desprende la torreta")
	tank.vehicle.set_control_override(false)
	tank.vehicle.clear_driver(driver)
	_discard_test_tank(world, tank)
	_discard_test_tank(world, dropped)
	for _frame in 3:
		await physics_frame

	# Prueba de producto: el muro se construye perpendicular a la orientación física que tenga el
	# tanque una vez asentado. Así la prueba mide el choque real, sin asumir el eje del modelo VOX.
	var rammer := VoxelTank3D.spawn(world, Vector3(-10.0, 1.0, -10.0))
	for _frame in 60:
		await physics_frame
	rammer.vehicle.linear_velocity = Vector3.ZERO
	rammer.vehicle.angular_velocity = Vector3.ZERO
	var crash_forward := rammer.vehicle.forward_direction()
	var crash_right := Vector3.UP.cross(crash_forward).normalized()
	var wall_basis := Basis(crash_right, Vector3.UP, crash_forward).orthonormalized()
	# El cañón sobresale bastante más que el casco. Se deja un hueco desde el extremo del conjunto
	# completo para que la prueba no nazca con la torreta empotrada en el muro.
	var wall_center := rammer.vehicle.get_world_bounds().get_support(crash_forward) \
		+ crash_forward * 1.5
	wall_center.y = 1.2
	var wall_parts := _make_wood_wall(world, wall_center, wall_basis)
	var wall := wall_parts.body as VoxelBody3D
	var wall_shape := wall_parts.shape as VoxelShape3D
	var wall_voxels := wall_shape.voxel_count()
	var hull_voxels := rammer.hull.get_total_voxels()
	var impacts_before := world.physics_impacts
	var rammer_driver := Node3D.new()
	root.add_child(rammer_driver)
	_check(rammer.vehicle.set_driver(rammer_driver), "se puede ocupar el tanque de ariete")
	rammer.vehicle.set_control_override(true, 1.0, 0.0, false)
	var crossed_wall := false
	for _frame in 360:
		await physics_frame
		var beyond := (rammer.vehicle.global_position - wall_center).dot(crash_forward)
		crossed_wall = crossed_wall or beyond > 0.5
		if crossed_wall and (not is_instance_valid(wall_shape) \
				or wall_shape.voxel_count() < wall_voxels):
			break
	var wall_after := wall_shape.voxel_count() if is_instance_valid(wall_shape) else 0
	print("  muro: %d -> %d voxeles; tanque=%s; impacto=%s" % [
		wall_voxels, wall_after, rammer.vehicle.global_position,
		JSON.stringify(world.last_physics_impact),
	])
	_check(world.physics_impacts > impacts_before and wall_after < wall_voxels,
		"el tanque abre un boquete mediante un contacto Jolt real")
	_check(String(world.last_physics_impact.get("kind", "")) == "vehicle",
		"el choque usa el perfil fuerte del tanque")
	_check(rammer.hull.get_total_voxels() == hull_voxels,
		"abrir el muro no perfora el propio casco")
	_check(crossed_wall,
		"el tanque atraviesa la pared y no queda clavado")
	_check(rammer.is_turret_attached(), "atravesar una pared no desprende la torreta")
	rammer.vehicle.set_control_override(false)
	rammer.vehicle.clear_driver(rammer_driver)

	# Una explosión que toca el conjunto sí libera la corona y le da el golpe vertical de lectura.
	var explosive := VoxelTank3D.spawn(world, Vector3(10.0, 1.0, 12.0))
	for _frame in 24:
		await physics_frame
	var turret_rigid := explosive.turret.get_physics_body() as RigidBody3D
	var blast := explosive.vehicle.get_world_bounds().get_center()
	world.damage_sphere(blast, 0.4, 0.01, {"cause": "explosion"})
	for _frame in 4:
		await physics_frame
	print("  velocidad Y tras explosión: casco %.2f, torreta %.2f" % [
		explosive.vehicle.linear_velocity.y, turret_rigid.linear_velocity.y,
	])
	_check(not explosive.is_turret_attached(), "una explosión sí desprende la torreta")
	_check(turret_rigid.linear_velocity.y - explosive.vehicle.linear_velocity.y > 1.0,
		"la torreta sale despedida respecto al casco al explotar")

	# La camara de puntería es yaw de mundo: girar el casco no puede arrastrar la mira.
	var yaw := Player.camera_yaw_from_forward(Vector3(0.6, 0.0, -0.8))
	var back := Player.camera_aim_direction(yaw, 0.0)
	_check(back.distance_to(Vector3(0.6, 0.0, -0.8)) < 0.01, "el yaw de camara va y vuelve")
	_check(Player.camera_aim_direction(0.0, 0.5).y < -0.4, "pitch positivo mira hacia abajo")

	print("fallos: %d" % failures)
	quit(1 if failures > 0 else 0)
