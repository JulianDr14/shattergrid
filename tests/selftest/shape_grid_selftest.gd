extends SceneTree
## La rejilla tiene que dar exactamente lo mismo que barrer todas las Shapes, tambien despues de
## mover y de borrar. Y `_coalesce` no puede juntar cajas lejanas: esa fusion a ciegas era la que
## convertia dos escombros en extremos opuestos del mapa en una region de 250 m.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _shape(parent: Node3D, position: Vector3, size: Vector3i) -> VoxelShape3D:
	var body := VoxelBody3D.new()
	parent.add_child(body)
	body.position = position
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	cells.fill(1)
	shape.data.set_cells(size, cells)
	shape.palette = VoxelPalette.new()
	body.add_voxel_shape(shape)
	return shape


func _brute(shapes: Array, region: AABB) -> Array:
	var result := []
	for shape: VoxelShape3D in shapes:
		if shape.voxel_count() > 0 and shape.world_bounds().intersects(region):
			result.append(shape.get_instance_id())
	result.sort()
	return result


func _ids(shapes: Array) -> Array:
	var result := []
	for shape: VoxelShape3D in shapes:
		result.append(shape.get_instance_id())
	result.sort()
	return result


func _run() -> void:
	print("rejilla de Shapes")
	var level := Node3D.new()
	root.add_child(level)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var shapes: Array[VoxelShape3D] = []
	# Mezcla de tamanos, incluida una que rebasa el techo de celdas y va a la lista de siempre.
	for _i in 60:
		shapes.append(_shape(level, Vector3(
			rng.randf_range(-60.0, 60.0), rng.randf_range(-10.0, 10.0), rng.randf_range(-60.0, 60.0)
		), Vector3i(rng.randi_range(2, 40), rng.randi_range(2, 40), rng.randi_range(2, 40))))
	shapes.append(_shape(level, Vector3.ZERO, Vector3i(300, 60, 300)))
	await physics_frame

	var grid := VoxelShapeGrid.new()
	for shape in shapes:
		grid.insert(shape, shape.world_bounds())
	_check(grid.size() == shapes.size(), "entran todas las Shapes")

	var mismatches := 0
	for _consulta in 300:
		var center := Vector3(
			rng.randf_range(-70.0, 70.0), rng.randf_range(-15.0, 15.0), rng.randf_range(-70.0, 70.0)
		)
		var side := rng.randf_range(0.5, 30.0)
		var region := AABB(center - Vector3.ONE * side * 0.5, Vector3.ONE * side)
		if _ids(grid.query(region)) != _brute(shapes, region):
			mismatches += 1
	_check(mismatches == 0, "300 consultas coinciden con el barrido (%d fallos)" % mismatches)

	# Mover: reinsertar tiene que dejar la rejilla igual que si se construyera de cero.
	for index in range(0, shapes.size(), 3):
		shapes[index].get_parent().position += Vector3(
			rng.randf_range(-40.0, 40.0), 0.0, rng.randf_range(-40.0, 40.0)
		)
	await physics_frame
	for index in range(0, shapes.size(), 3):
		grid.insert(shapes[index], shapes[index].world_bounds())
	mismatches = 0
	for _consulta in 300:
		var center := Vector3(
			rng.randf_range(-90.0, 90.0), rng.randf_range(-15.0, 15.0), rng.randf_range(-90.0, 90.0)
		)
		var region := AABB(center - Vector3.ONE * 8.0, Vector3.ONE * 16.0)
		if _ids(grid.query(region)) != _brute(shapes, region):
			mismatches += 1
	_check(mismatches == 0, "300 consultas tras mover un tercio (%d fallos)" % mismatches)

	# Borrar: el hueco no puede quedar en ningun cubo.
	var doomed := shapes[7]
	grid.remove_id(doomed.get_instance_id())
	_check(not grid.has_id(doomed.get_instance_id()), "una Shape borrada sale de la rejilla")
	var still := grid.query(doomed.world_bounds())
	_check(not _ids(still).has(doomed.get_instance_id()),
		"y no la devuelve una consulta sobre su propia caja")

	# Un Node puede liberarse antes del barrido periódico de sombras. La rejilla debe poder consultar
	# y retirar ese Variant muerto sin intentar convertirlo primero a VoxelShape3D.
	var stale := shapes[8]
	var stale_id := stale.get_instance_id()
	var stale_bounds := stale.world_bounds()
	(stale.get_parent().get_parent() as VoxelBody3D).free()
	var after_unexpected_free := grid.query(stale_bounds)
	_check(not _ids(after_unexpected_free).has(stale_id),
		"una referencia liberada inesperadamente no sale de la consulta")
	grid.remove_id(stale_id)
	_check(not grid.has_id(stale_id), "una referencia liberada se puede retirar por id")

	# `_coalesce`: junta lo que se toca, no junta lo que esta lejos.
	var clipmaps := VoxelShadowClipmaps.new()
	var juntas: Array[AABB] = [
		AABB(Vector3.ZERO, Vector3.ONE), AABB(Vector3(0.5, 0.5, 0.5), Vector3.ONE)
	]
	var lejanas: Array[AABB] = [
		AABB(Vector3.ZERO, Vector3.ONE), AABB(Vector3(200.0, 0.0, 200.0), Vector3.ONE)
	]
	_check((clipmaps.call("_coalesce", juntas) as Array).size() == 1,
		"dos cajas solapadas se juntan en una")
	var separadas: Array = clipmaps.call("_coalesce", lejanas)
	_check(separadas.size() == 2, "dos cajas a 200 m siguen siendo dos regiones")
	clipmaps.free()

	if failures == 0:
		print("VOXEL_SHAPE_GRID_SELFTEST_OK")
	else:
		printerr("VOXEL_SHAPE_GRID_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
