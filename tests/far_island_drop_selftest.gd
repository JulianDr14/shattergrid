extends SceneTree
## Una isla desconectada LEJOS del crater tampoco tiene ruta a tierra.
##
## `_split_disconnected` solo evaluaba las componentes cercanas al impacto, y `_drop_unsupported`
## trabaja por Shape, no por componente: el trozo lejano se quedaba soldado al aire para siempre.
## Es el pedazo de pared sin uniones que no caia.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


## Un muro con su base de roca en un extremo y un tramo suelto de ladrillo en el otro, sin nada en
## medio: dos componentes desde el primer frame, separadas mucho mas que el radio del disparo.
func _build_wall(world: VoxelWorld3D) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(40, 8, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var material := 0
				if x < 4:
					material = 2 if y < 3 else 1
				elif x >= 30:
					material = 1
				cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = material
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.RED, "hardness": 0.4, "density": 400.0})
	shape.palette.set_material(2, {
		"color": Color.GRAY, "hardness": VoxelWorld3D.FOUNDATION_HARDNESS, "density": 2400.0,
	})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 6.0, 0.0))
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.STATIC
	world.add_child(body)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return shape


## El fragmento nace en el origen y la altura vive en la Shape, no en el nodo.
static func _body_height(body: VoxelBody3D) -> float:
	var shapes := body.get_shapes()
	return shapes[0].world_bounds().get_center().y if not shapes.is_empty() else 0.0


func _run() -> void:
	print("isla desconectada lejos del impacto")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	var wall := _build_wall(world)
	world.finalize_spatial_index()
	for _frame in 5:
		await physics_frame
	_check(world.get_dynamic_bodies().is_empty(), "el muro entra entero como estatica")

	# Se raspa la roca: quita cimiento, asi que la clasificacion se dispara seguro. La componente
	# lejana esta a 26 voxeles del crater, muy fuera del alcance local que antes la filtraba.
	var far_before := wall.voxel_count()
	var rock := wall.voxel_center_world(0)
	world.damage_sphere(rock, 0.15, 1.0e6)
	for _frame in 30:
		await physics_frame
		world._process(1.0 / 60.0)

	var dynamic_bodies := world.get_dynamic_bodies()
	print("  cuerpos dinamicos: %d   voxeles restantes en el muro: %d de %d" % [
		dynamic_bodies.size(), wall.voxel_count() if is_instance_valid(wall) else 0, far_before,
	])
	_check(not dynamic_bodies.is_empty(), "el tramo lejano se desprende en su propio cuerpo")
	_check(is_instance_valid(wall) and wall.voxel_count() > 0,
		"y la base sobre la roca se queda donde estaba")

	var heights: Array[float] = []
	for body: VoxelBody3D in dynamic_bodies:
		heights.append(_body_height(body))
	for _frame in 90:
		await physics_frame
		world._process(1.0 / 60.0)
	var fell := 0
	for index in dynamic_bodies.size():
		var body := dynamic_bodies[index]
		if is_instance_valid(body) and heights[index] - _body_height(body) > 0.3:
			fell += 1
	_check(fell > 0, "y cae de verdad, no se queda flotando")
	var snapshot: Dictionary = world._runtime_registry.get_coherence_snapshot()
	print("  coherencia: %s" % snapshot.get("status", "?"))
	_check(String(snapshot.get("status", "")) != "DESYNC",
		"ninguna Shape queda con colision desincronizada tras cambiar de cuerpo")

	if failures == 0:
		print("VOXEL_FAR_ISLAND_DROP_SELFTEST_OK")
	else:
		printerr("VOXEL_FAR_ISLAND_DROP_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
