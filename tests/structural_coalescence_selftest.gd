extends SceneTree
## Piezas authored intactas del mismo colapso comparten Body; fragmentos separados por corte no.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _body(world: VoxelWorld3D, center: Vector3, dimensions: Vector3i,
		epoch: int, lineage := 0, family := 9001) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	body.structural = true
	body.set_meta("damage_epoch", epoch)
	body.set_meta("structural_family", family)
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.structural_lineage = lineage
	shape.position = center
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("coalescencia estructural por batch")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	_body(world, Vector3(-0.2, 2.0, 0.0), Vector3i(4, 1, 1), 42)
	_body(world, Vector3(0.2, 2.0, 0.0), Vector3i(4, 1, 1), 42)
	world._pending_structural_coalesce[42] = true
	world._coalesce_ready_structural_bodies()
	_check(world.get_dynamic_bodies().size() == 1,
		"dos piezas authored que aún se tocan usan un solo RigidBody")
	_check(world.get_dynamic_bodies()[0].get_total_voxels() == 8,
		"el merge conserva todo el material")

	# Dos mitades del mismo volumen con un voxel retirado entre ellas tienen una separación de 10 cm.
	# CONTACT_MARGIN las volvería a soldar; el linaje obliga a usar solo tolerancia numérica.
	_body(world, Vector3(2.85, 2.0, 0.0), Vector3i(2, 1, 1), 43, 777)
	_body(world, Vector3(3.15, 2.0, 0.0), Vector3i(2, 1, 1), 43, 777)
	world._pending_structural_coalesce[43] = true
	world._coalesce_ready_structural_bodies()
	_check(world.get_dynamic_bodies().size() == 3,
		"dos fragmentos del mismo linaje separados por el corte no se vuelven a soldar")

	if failures == 0:
		print("VOXEL_STRUCTURAL_COALESCENCE_SELFTEST_OK")
	else:
		printerr("VOXEL_STRUCTURAL_COALESCENCE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
