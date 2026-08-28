extends SceneTree
## Un Body sin voxeles no puede conservar masa, compound ni referencias en el World.

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
	print("limpieza de Bodies físicos vacíos")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(2 * 2 * 2)
	cells.fill(1)
	shape.data.set_cells(Vector3i(2, 2, 2), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 1000.0,
	})
	body.add_voxel_shape(shape)
	world.register_body(body)
	_check(body.compound_boxes > 0 and body.get_total_voxels() == 8,
		"el fixture empieza como Body físico real")
	var affected := world.damage_sphere(shape.world_bounds().get_center(), 1.0, 100.0)
	_check(not affected.is_empty(), "el impacto vacía la Shape dinámica")
	_check(not world.get_dynamic_bodies().has(body),
		"la transacción desregistra el Body vacío inmediatamente")
	await process_frame
	_check(not is_instance_valid(body),
		"el nodo con masa y compound antiguos sale del árbol")

	# Barrera defensiva: un escritor futuro puede registrar accidentalmente un Body ya vacío. La
	# actualización de métricas debe repararlo sin contarlo como física activa.
	var stale := VoxelBody3D.new()
	stale.state = VoxelBody3D.State.DYNAMIC
	world.add_child(stale)
	var empty_shape := VoxelShape3D.new()
	empty_shape.data = VoxelShapeData.new()
	empty_shape.data.set_cells(Vector3i(1, 1, 1), PackedByteArray([0]))
	empty_shape.palette = VoxelPalette.new()
	stale.add_voxel_shape(empty_shape)
	world.register_body(stale)
	world._update_metrics()
	_check(not world.get_dynamic_bodies().has(stale),
		"la barrera de métricas elimina también un fantasma inyectado")

	if failures == 0:
		print("VOXEL_EMPTY_BODY_CLEANUP_SELFTEST_OK")
	else:
		printerr("VOXEL_EMPTY_BODY_CLEANUP_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
