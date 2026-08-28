extends SceneTree
## Un disparo que parte algo en muchos trozos no puede crear todos los cuerpos rigidos en el mismo
## frame: medido en Lee, ocho `RigidBody3D` con su compound de cajas son 37 ms, mas del doble del
## presupuesto a 60 fps. Se crean unos cuantos y el resto espera turno.
##
## Lo que se comprueba es que el reparto no pierde trozos: los mismos que antes, repartidos.

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
	print("reparto de trozos por frame")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	# Un nucleo macizo con una cola fina, y ocho islas sueltas alrededor. Cada isla tiene 32 voxeles:
	# queda justo por encima del límite cosmético de 31 y ejercita Bodies diferidos reales. Al cortar
	# la cola se sueltan también las islas cercanas: nueve trozos de golpe.
	var dimensions := Vector3i(25, 3, 25)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(0)
	var put := func(x: int, y: int, z: int) -> void:
		cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = 1
	for x in range(10, 15):
		for y in 3:
			for z in range(10, 15):
				put.call(x, y, z)
	for x in range(15, 18):
		put.call(x, 1, 12)
	var islands := 0
	for corner: Vector2i in [
		Vector2i(19, 3), Vector2i(19, 15), Vector2i(6, 3), Vector2i(6, 15),
		Vector2i(3, 3), Vector2i(3, 15), Vector2i(22, 3), Vector2i(22, 15),
	]:
		islands += 1
		for x in range(corner.x, corner.x + 2):
			for y in 2:
				for z in range(corner.y, corner.y + 8):
					put.call(x, y, z)

	var body := VoxelBody3D.new()
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	# Dureza alta y energia baja: el crater es de un voxel, asi que corta la cola y no toca las islas,
	# pero el radio -que es lo que decide que trozos cuentan como "cerca"- sigue siendo grande.
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 20.0, "density": 1000.0})
	shape.anchored = false
	body.add_voxel_shape(shape)
	world.register_body(body)
	for _frame in 4:
		await physics_frame

	var crater := shape.voxel_center_world(15 + 1 * dimensions.x + 12 * dimensions.x * dimensions.y)
	var affected := world.damage_sphere(crater, 1.0, 2.0)
	var immediate := 0
	for entry: Dictionary in affected:
		immediate += (entry.new_bodies as Array).size()
	print("  trozos en el frame del disparo: %d" % immediate)
	_check(immediate > 0 and immediate <= VoxelWorld3D.FRAGMENTS_PER_FRAME,
		"el frame del disparo no crea mas de %d cuerpos" % VoxelWorld3D.FRAGMENTS_PER_FRAME)

	# Y en los frames siguientes llegan los que faltaban.
	for _frame in 12:
		await physics_frame
		world._process(1.0 / 60.0)
	var total := world.get_dynamic_bodies().size()
	print("  trozos totales tras vaciar la cola: %d  (islas sueltas: %d)" % [total, islands])
	_check(total > immediate, "los trozos que faltaban llegan en los frames siguientes")
	_check(total >= islands, "no se pierde ningun trozo por el camino (%d de %d)" % [total, islands])

	if failures == 0:
		print("VOXEL_FRAGMENT_BUDGET_SELFTEST_OK")
	else:
		printerr("VOXEL_FRAGMENT_BUDGET_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
