extends SceneTree
## Los props del mapa nacen dormidos, no congelados. Dormido significa que Jolt no lo simula hasta
## que algo lo toca; congelado significaba estatica muerta que no reaccionaba a nada. La diferencia
## es todo el mundo vivo: cajas que se empujan, tuberias que cuelgan de sus joints, bidones que salen
## volando con una explosion al lado.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _make_body(world: VoxelWorld3D, origin: Vector3, dynamic: bool) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC if dynamic else VoxelBody3D.State.STATIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(6, 6, 6)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 5.0, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _height(body: VoxelBody3D) -> float:
	return body.get_shapes()[0].world_bounds().get_center().y


func _run() -> void:
	print("props vivos")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var floor_body := _make_body(world, Vector3(0, 0, 0), false)
	floor_body.name = "Suelo"
	var crate := _make_body(world, Vector3(0, 1.2, 0), true)
	crate.sleep()
	for _frame in 10:
		await physics_frame
	_check(not crate.is_awake(), "el prop importado arranca dormido y no cuesta simulacion")
	var resting := _height(crate)

	# Lo decisivo: algo lo toca. Congelado no pasaba nada; dormido, Jolt lo reactiva por contacto.
	var hammer := _make_body(world, Vector3(0, 5.0, 0), true)
	hammer.name = "Martillo"
	for _frame in 90:
		await physics_frame
	_check(crate.is_awake() or absf(_height(crate) - resting) > 0.02,
		"un cuerpo que le cae encima lo despierta y lo mueve")
	print("  altura del prop: reposo %.3f  tras el golpe %.3f" % [resting, _height(crate)])

	# Y una explosion al lado tiene que tirarlo aunque no le quite ni un voxel.
	var other := _make_body(world, Vector3(20, 1.2, 0), true)
	other.sleep()
	for _frame in 10:
		await physics_frame
	var before := other.get_shapes()[0].world_bounds().get_center()
	world.damage_sphere(Vector3(18.0, 1.2, 0), 1.0, 3.0)
	for _frame in 60:
		await physics_frame
	var moved := before.distance_to(other.get_shapes()[0].world_bounds().get_center())
	print("  desplazado por la onda: %.3f m" % moved)
	_check(moved > 0.05, "una explosion al lado empuja el prop dormido")

	# Un volumen largo puede solapar la esfera amplia de candidatos aunque toda su masa esté fuera
	# de la onda. Despertarlo sin aplicarle fuerza era el burst fantasma de postes/cables en Lee.
	var distant_pole := VoxelBody3D.new()
	distant_pole.state = VoxelBody3D.State.DYNAMIC
	world.add_child(distant_pole)
	var pole_shape := VoxelShape3D.new()
	pole_shape.data = VoxelShapeData.new()
	var pole_cells := PackedByteArray()
	pole_cells.resize(2 * 100 * 2)
	pole_cells.fill(1)
	pole_shape.data.set_cells(Vector3i(2, 100, 2), pole_cells)
	pole_shape.palette = VoxelPalette.new()
	pole_shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 100.0, "density": 400.0,
	})
	pole_shape.transform = Transform3D(Basis.IDENTITY, Vector3(30.0, 7.0, 0.0))
	distant_pole.add_voxel_shape(pole_shape)
	world.register_body(distant_pole)
	distant_pole.sleep()
	for _frame in 4:
		await physics_frame
	world.damage_sphere(Vector3(30.0, 0.0, 0.0), 1.0, 3.0)
	for _frame in 3:
		await physics_frame
	_check(not distant_pole.is_awake(),
		"un AABB largo fuera del radio de impulso no crea un Body despierto fantasma")

	# El presupuesto no puede degradar la colision de props dormidos: eso convertia cada caja del
	# mapa en un bloque de 40 cm ya en el primer tick.
	world.physics_budget.max_active_boxes = 1
	var boxes_before := crate.compound_boxes
	crate.sleep()
	for _frame in 4:
		await physics_frame
	world._enforce_physics_budget(false)
	_check(crate.compound_boxes == boxes_before,
		"un prop dormido conserva su colision fina (%d cajas)" % boxes_before)

	if failures == 0:
		print("VOXEL_LIVE_PROPS_SELFTEST_OK")
	else:
		printerr("VOXEL_LIVE_PROPS_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
