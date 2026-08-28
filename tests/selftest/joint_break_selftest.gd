extends SceneTree
## Un joint deja de sujetar cuando le vuelan los voxeles del anclaje. Sin esto, un `Joint3D` de Godot
## es eterno: destruyes el tramo de tuberia entero y la restriccion sigue sosteniendo los pedazos en
## el aire, que es justo lo que se veia en el mapa.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _make_body(world: VoxelWorld3D, origin: Vector3, dimensions: Vector3i,
		dynamic: bool) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC if dynamic else VoxelBody3D.State.STATIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	# Dureza baja: el disparo tiene que llevarse el anclaje entero de una.
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _height(body: VoxelBody3D) -> float:
	return body.get_shapes()[0].world_bounds().get_center().y


func _run() -> void:
	print("rotura de joints")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	# Un soporte fijo y un tramo colgando de el por un joint, como una tuberia de Lee.
	var mount := _make_body(world, Vector3(0, 4, 0), Vector3i(8, 8, 8), false)
	var pipe := _make_body(world, Vector3(1.2, 4, 0), Vector3i(20, 6, 6), true)
	var anchor := Vector3(0.35, 4, 0)

	var joint := PinJoint3D.new()
	world.add_child(joint)
	joint.global_transform = Transform3D(Basis.IDENTITY, anchor)
	joint.node_a = joint.get_path_to(mount.get_physics_body())
	joint.node_b = joint.get_path_to(pipe.get_physics_body())

	var joints := VoxelJoints.new()
	world.add_child(joints)
	joints.setup(world)
	joints.add_records([{
		"joint": joint, "attributes": {"size": "0.3"},
		"transform": Transform3D(Basis.IDENTITY, anchor),
		"owner_body": mount, "other_body": pipe, "broken": false,
	}] as Array[Dictionary])

	for _frame in 30:
		await physics_frame
	_check(joints.live_count() == 1, "el joint entra vivo")
	_check(mount.physics_hold_count() == 1 and pipe.physics_hold_count() == 1,
		"el joint protege ambos Bodies frente al retiro por presupuesto")
	var hanging := _height(pipe)

	# Un disparo lejos no puede romperlo.
	world.damage_sphere(Vector3(6.0, 4.0, 0.0), 0.6, 40.0)
	for _frame in 5:
		await physics_frame
	_check(joints.live_count() == 1, "un impacto lejos del anclaje no rompe el joint")

	# Y ahora al anclaje: se lleva los voxeles del soporte y el tramo tiene que soltarse.
	world.damage_sphere(anchor, 1.2, 40.0)
	for _frame in 5:
		await physics_frame
	print("  joints vivos tras reventar el anclaje: %d" % joints.live_count())
	_check(joints.live_count() == 0, "sin voxeles alrededor, el joint se rompe")
	_check(mount.physics_hold_count() == 0 and pipe.physics_hold_count() == 0,
		"la rotura libera las retenciones contadas")
	_check(not joints._by_body.has(mount.get_instance_id()) \
		and not joints._by_body.has(pipe.get_instance_id()),
		"el índice inverso no conserva registros rotos")
	_check(pipe.is_awake(), "y el tramo suelto se entera, no se queda dormido flotando")

	for _frame in 90:
		await physics_frame
	var fallen := hanging - _height(pipe)
	print("  el tramo bajo %.2f m tras soltarse" % fallen)
	_check(fallen > 0.5, "el tramo cae de verdad")

	# Transferencia de ownership: el registro debe salir del índice anterior, no solo añadirse al nuevo.
	var source2 := _make_body(world, Vector3(3, 6, 0), Vector3i(4, 4, 4), true)
	var heir := _make_body(world, Vector3(3, 6, 0), Vector3i(4, 4, 4), true)
	var joint2 := PinJoint3D.new()
	world.add_child(joint2)
	var anchor2 := Vector3(3, 6, 0)
	joint2.global_position = anchor2
	joint2.node_a = joint2.get_path_to(source2.get_physics_body())
	joint2.node_b = joint2.get_path_to(mount.get_physics_body())
	var transfer_record := {
		"joint": joint2, "attributes": {"size": "0.2"},
		"transform": Transform3D(Basis.IDENTITY, anchor2),
		"owner_body": source2, "other_body": mount, "broken": false,
	}
	joints.add_records([transfer_record] as Array[Dictionary])
	var source2_shape := source2.get_shapes()[0]
	for z in 4:
		for y in 4:
			for x in 4:
				source2_shape.data.set_cell(x, y, z, 0)
	world.body_split.emit(source2, [heir] as Array[VoxelBody3D])
	_check(transfer_record.owner_body == heir,
		"el anclaje cambia al Body que conserva el material")
	_check(not joints._by_body.has(source2.get_instance_id()) \
		and joints._by_body.get(heir.get_instance_id(), []).has(transfer_record),
		"el índice inverso elimina al dueño anterior durante la transferencia")
	_check(source2.physics_hold_count() == 0 and heir.physics_hold_count() == 1,
		"la retención física se transfiere junto con el joint")
	world.unregister_body(heir)
	_check(bool(transfer_record.broken) and heir.physics_hold_count() == 0 \
		and mount.physics_hold_count() == 0 \
		and not joints._by_body.has(heir.get_instance_id()),
		"unregister_body rompe atómicamente la restricción sin heredero")

	if failures == 0:
		print("VOXEL_JOINT_BREAK_SELFTEST_OK")
	else:
		printerr("VOXEL_JOINT_BREAK_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
