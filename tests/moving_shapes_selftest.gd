extends SceneTree
## Un cuerpo que se vuelve dinamico DESPUES de registrarse -una torre que pierde su apoyo, un tramo
## de tuberia que se suelta- tiene que entrar en la lista de Shapes que el render vigila cada frame.
##
## Cuando no entraba, el cuerpo caia de verdad pero su transformada no volvia a subir a la GPU:
## quedaba un fantasma de pie en el sitio de antes, atravesable e indestructible, mientras los
## voxeles reales ya estaban en el suelo. La sombra si se movia, que era la pista.

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
	print("Shapes que el render vigila")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var render := VoxelRenderSystem.new()
	render.world = world
	root.add_child(render)

	# Lejos del origen, que es donde vivian los postes y la torre del mapa.
	var tower := VoxelBody3D.new()
	world.add_child(tower)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(4, 20, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(-3.9, 14.7, 70.9))
	tower.add_voxel_shape(shape)
	world.register_body(tower)
	await physics_frame

	_check(render.movable_shapes().is_empty(), "una Shape estatica no se vigila")

	var before := shape.global_transform.origin
	tower.make_dynamic()
	await physics_frame
	_check(render.movable_shapes().has(shape), "al volverse dinamica, si")

	for _frame in 30:
		await physics_frame
	var fell := before.y - shape.global_transform.origin.y
	print("  cayo %.2f m" % fell)
	_check(fell > 0.5, "y se mueve de verdad, asi que el render tenia que enterarse")

	if failures == 0:
		print("VOXEL_MOVING_SHAPES_SELFTEST_OK")
	else:
		printerr("VOXEL_MOVING_SHAPES_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
