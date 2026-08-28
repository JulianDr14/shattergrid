extends SceneTree
## Un poste estructural rápido no debe cruzar una chapa/apoyo delgado entre dos physics ticks.

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
	print("CCD de postes y fragmentos estructurales")
	var support := StaticBody3D.new()
	var support_collision := CollisionShape3D.new()
	var support_box := BoxShape3D.new()
	support_box.size = Vector3(8.0, 0.04, 8.0)
	support_collision.shape = support_box
	support.add_child(support_collision)
	root.add_child(support)

	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_impact_damage_enabled = false
	root.add_child(world)
	var body := VoxelBody3D.new()
	body.position = Vector3(0.0, 3.0, 0.0)
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(2 * 20 * 2)
	cells.fill(1)
	shape.data.set_cells(Vector3i(2, 20, 2), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 7800.0,
	})
	body.add_voxel_shape(shape)
	world.register_body(body)
	body.make_dynamic(16)
	var rigid := body.get_physics_body() as RigidBody3D
	for _frame in 8:
		await process_frame
		await physics_frame
		if not body.collision_handoff_pending:
			break
	_check(not body.collision_handoff_pending and rigid.continuous_cd,
		"el poste entra al solver después del handoff con CCD activo")
	rigid.linear_velocity = Vector3(0.0, -80.0, 0.0)
	rigid.sleeping = false
	var minimum_y := rigid.global_position.y
	for _frame in 10:
		await physics_frame
		minimum_y = minf(minimum_y, rigid.global_position.y)
	print("  centro mínimo del poste: %.3f m" % minimum_y)
	_check(minimum_y > 0.8,
		"un poste a 80 m/s no atraviesa un apoyo de 4 cm")
	_check(rigid.global_position.y > 0.8,
		"el poste permanece del lado correcto del soporte")

	if failures == 0:
		print("VOXEL_STRUCTURAL_CCD_SELFTEST_OK")
	else:
		printerr("VOXEL_STRUCTURAL_CCD_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
