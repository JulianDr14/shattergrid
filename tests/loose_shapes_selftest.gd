extends SceneTree
## Un `<body dynamic>` de Teardown puede traer varias Shapes en un solo cuerpo rigido. Si el disparo
## se lleva la del medio, las de los extremos ya no se tocan y tienen que separarse en cuerpos
## distintos. Sin esto se quedan soldadas, flotando en formacion con el hueco en medio.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _add_section(body: VoxelBody3D, origin: Vector3) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(10, 4, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	return shape


func _run() -> void:
	print("cuerpos con varias Shapes")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	# Tres tramos de tuberia pegados, un solo cuerpo rigido, como los importa el mapa.
	var pipe := VoxelBody3D.new()
	pipe.state = VoxelBody3D.State.DYNAMIC
	world.add_child(pipe)
	_add_section(pipe, Vector3(0.0, 8.0, 0.0))
	var middle := _add_section(pipe, Vector3(1.0, 8.0, 0.0))
	_add_section(pipe, Vector3(2.0, 8.0, 0.0))
	world.register_body(pipe)
	for _frame in 5:
		await physics_frame
	_check(pipe.get_shapes().size() == 3, "el cuerpo entra con tres tramos")
	_check(world.get_dynamic_bodies().size() == 1, "y un solo cuerpo rigido")

	# Se revienta el tramo del medio: los extremos dejan de tocarse.
	var center := middle.world_bounds().get_center()
	world.damage_sphere(center, 1.2, 60.0)
	for _frame in 10:
		await physics_frame
		world._process(1.0 / 60.0)
	print("  tramo del medio: %d voxeles restantes" % (
		middle.voxel_count() if is_instance_valid(middle) else 0
	))
	var bodies := world.get_dynamic_bodies().size()
	print("  cuerpos dinamicos tras el corte: %d" % bodies)
	_check(bodies >= 2, "los tramos que ya no se tocan se separan en cuerpos distintos")

	# Y cada cuerpo tiene que caer por su cuenta, no en formacion.
	var heights: Array[float] = []
	for body: VoxelBody3D in world.get_dynamic_bodies():
		var shapes := body.get_shapes()
		if not shapes.is_empty():
			heights.append(shapes[0].world_bounds().get_center().y)
	for _frame in 60:
		await physics_frame
	var moved := 0
	var index := 0
	for body: VoxelBody3D in world.get_dynamic_bodies():
		var shapes := body.get_shapes()
		if shapes.is_empty() or index >= heights.size():
			continue
		if heights[index] - shapes[0].world_bounds().get_center().y > 0.5:
			moved += 1
		index += 1
	print("  cuerpos que cayeron: %d de %d" % [moved, heights.size()])
	_check(moved >= 2, "y caen, no se quedan flotando")

	# Y al reves: dos Shapes del mismo cuerpo que NUNCA se tocaron estan soldadas por quien hizo el
	# mapa. Romper voxeles en una no puede separarlas, porque entre ellas no habia nada que romper.
	var welded := VoxelBody3D.new()
	welded.state = VoxelBody3D.State.DYNAMIC
	world.add_child(welded)
	var left := _add_section(welded, Vector3(20.0, 8.0, 0.0))
	var right := _add_section(welded, Vector3(24.0, 8.0, 0.0))
	world.register_body(welded)
	for _frame in 5:
		await physics_frame
	world.damage_sphere(left.world_bounds().position + Vector3(0.05, 0.05, 0.05), 0.2, 60.0)
	for _frame in 5:
		await physics_frame
		world._process(1.0 / 60.0)
	_check(world._body_of(left) == world._body_of(right),
		"lo que nunca se toco no se separa al recibir un impacto")

	if failures == 0:
		print("VOXEL_LOOSE_SHAPES_SELFTEST_OK")
	else:
		printerr("VOXEL_LOOSE_SHAPES_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
