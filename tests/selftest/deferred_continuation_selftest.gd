extends "res://tests/selftest/selftest.gd"
## La cola de fragmentos: un disparo que parte algo en muchos trozos no puede crear todos los
## RigidBody en el mismo frame -medido en Lee, ocho con su compound son 37 ms, mas del doble del
## presupuesto a 60 fps-, asi que se crean unos cuantos y el resto espera turno.
##
## Dos regresiones sobre esa cola:
## - El techo suspendido: la continuación toca el cuarto componente, que necesariamente pasa por la
##   cola. Antes esa cola creaba el RigidBody pero omitía la propagación de soporte que sí
##   ejecutaban los tres fragmentos inmediatos.
## - El reparto no puede perder trozos: los mismos que antes, repartidos en varios frames.


func _shape_body(world: VoxelWorld3D, dimensions: Vector3i, cells: PackedByteArray,
		position := Vector3.ZERO, hardness := 1.0) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.position = position
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": hardness, "density": 1000.0,
	})
	shape.anchored = false
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("continuación estática en fragmento diferido")
	var world := make_world()

	var dimensions := Vector3i(32, 4, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(0)
	var put := func(x: int, y: int, z: int) -> void:
		cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = 1
	# Base anclada y cuatro componentes de 32 voxeles, por encima del límite cosmético. El cuarto
	# es x=20 y por eso debe pasar por la cola de Bodies diferidos.
	for x in range(0, 3):
		for y in 2:
			for z in 2:
				put.call(x, y, z)
	for start in [5, 10, 15, 20]:
		for x in range(start, start + 2):
			for y in 4:
				for z in 4:
					put.call(x, y, z)
	put.call(30, 1, 1) # voxel sacrificial que dispara la clasificación
	var source := _shape_body(world, dimensions, cells)
	var source_shape := source.get_shapes()[0]
	source_shape.anchored = true
	source_shape.anchor_indices = PackedInt32Array([0])

	var roof_cells := PackedByteArray()
	roof_cells.resize(4 * 2 * 4)
	roof_cells.fill(1)
	var roof := _shape_body(world, Vector3i(4, 2, 4), roof_cells,
		Vector3(0.5, 0.1, -0.1))
	var roof_shape := roof.get_shapes()[0]
	for _frame in 3:
		await physics_frame

	var damage := world.damage_sphere(source_shape.voxel_center_world(
		30 + dimensions.x + dimensions.x * dimensions.y
	), 0.075, 100.0)
	var immediate: Array = damage[0].new_bodies if not damage.is_empty() else []
	_check(immediate.size() == VoxelWorld3D.FRAGMENTS_PER_FRAME,
		"los primeros %d componentes se crean en el frame del impacto" \
			% VoxelWorld3D.FRAGMENTS_PER_FRAME)
	_check(world._body_of(roof_shape) == roof,
		"el techo que toca el cuarto componente aún espera su fragmento")

	for _frame in 16:
		await physics_frame
		world._process(1.0 / 60.0)
	var roof_owner := world._body_of(roof_shape)
	_check(roof_owner != null and roof_owner != roof,
		"la ruta diferida transfiere la continuación estática")
	_check(roof_owner != null and roof_owner.state == VoxelBody3D.State.DYNAMIC,
		"el techo termina en un Body dinámico")
	_check(world._pending_fragments.is_empty(), "la cola de fragmentos queda drenada")
	_check(world.get_metrics().pending_collision_handoffs == 0,
		"el handoff de colisión también queda drenado")

	# Reparto sin perdidas: un nucleo macizo con una cola fina y ocho islas de 32 voxeles alrededor.
	# Al cortar la cola se sueltan tambien las islas cercanas: nueve trozos de golpe, y todos tienen
	# que acabar existiendo aunque el frame del disparo solo pueda crear FRAGMENTS_PER_FRAME.
	var world_budget := make_world()
	var budget_dimensions := Vector3i(25, 3, 25)
	var budget_cells := PackedByteArray()
	budget_cells.resize(budget_dimensions.x * budget_dimensions.y * budget_dimensions.z)
	var put_budget := func(x: int, y: int, z: int) -> void:
		budget_cells[x + y * budget_dimensions.x
			+ z * budget_dimensions.x * budget_dimensions.y] = 1
	for x in range(10, 15):
		for y in 3:
			for z in range(10, 15):
				put_budget.call(x, y, z)
	for x in range(15, 18):
		put_budget.call(x, 1, 12)
	var islands := 0
	for corner: Vector2i in [
		Vector2i(19, 3), Vector2i(19, 15), Vector2i(6, 3), Vector2i(6, 15),
		Vector2i(3, 3), Vector2i(3, 15), Vector2i(22, 3), Vector2i(22, 15),
	]:
		islands += 1
		for x in range(corner.x, corner.x + 2):
			for y in 2:
				for z in range(corner.y, corner.y + 8):
					put_budget.call(x, y, z)
	# Dureza alta y energia baja: el crater es de un voxel, asi que corta la cola y no toca las islas,
	# pero el radio -que es lo que decide que trozos cuentan como "cerca"- sigue siendo grande.
	var chunk := _shape_body(world_budget, budget_dimensions, budget_cells, Vector3.ZERO, 20.0)
	var chunk_shape := chunk.get_shapes()[0]
	for _frame in 4:
		await physics_frame
	var crater := chunk_shape.voxel_center_world(
		15 + budget_dimensions.x + 12 * budget_dimensions.x * budget_dimensions.y
	)
	var spawned := 0
	for entry: Dictionary in world_budget.damage_sphere(crater, 1.0, 2.0):
		spawned += (entry.new_bodies as Array).size()
	_check(spawned > 0 and spawned <= VoxelWorld3D.FRAGMENTS_PER_FRAME,
		"el frame del disparo no crea mas de %d cuerpos" % VoxelWorld3D.FRAGMENTS_PER_FRAME)
	for _frame in 12:
		await physics_frame
		world_budget._process(1.0 / 60.0)
	var total := world_budget.get_dynamic_bodies().size()
	print("  reparto: %d en el frame del disparo, %d tras vaciar la cola (islas sueltas: %d)" % [
		spawned, total, islands,
	])
	_check(total > spawned, "los trozos que faltaban llegan en los frames siguientes")
	_check(total >= islands, "no se pierde ningun trozo por el camino (%d de %d)" % [total, islands])

	if failures == 0:
		print("VOXEL_DEFERRED_CONTINUATION_SELFTEST_OK")
	else:
		printerr("VOXEL_DEFERRED_CONTINUATION_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
