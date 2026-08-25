extends SceneTree
## Las conexiones entre cuerpos: joints que sobreviven a que un cuerpo cambie de `PhysicsBody`, y
## cables que van clavados a un cuerpo, tiran de el y se rompen si se pasan de estiramiento.
##
## Los dos fallos que cubre se veian igual en el mapa: volabas la base de un poste, el poste caia y
## se soltaba de la tuberia aunque el punto de union estuviera intacto; y volabas un poste con cables
## y los cables se quedaban colgados en el aire, sin enterarse.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _slab(world: VoxelWorld3D, origin: Vector3, dimensions: Vector3i,
		dynamic := false) -> VoxelBody3D:
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
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("uniones entre cuerpos")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	# Un poste estatico y una tuberia dinamica unidos por un joint a media altura.
	var post := _slab(world, Vector3(0.0, 2.0, 0.0), Vector3i(4, 40, 4))
	var pipe := _slab(world, Vector3(1.0, 3.5, 0.0), Vector3i(30, 4, 4), true)
	var junction := Transform3D(Basis.IDENTITY, Vector3(0.3, 3.5, 0.0))
	var joint := PinJoint3D.new()
	world.add_child(joint)
	joint.global_transform = junction
	joint.node_a = joint.get_path_to(post.get_physics_body())
	joint.node_b = joint.get_path_to(pipe.get_physics_body())
	var record := {
		"joint": joint, "attributes": {"size": "0.3"}, "transform": junction,
		"owner_body": post, "other_body": pipe, "broken": false,
	}
	var joints := VoxelJoints.new()
	world.add_child(joints)
	joints.setup(world)
	joints.add_records([record] as Array[Dictionary])
	await physics_frame
	_check(joints.live_count() == 1, "el joint entra vivo")

	# Se le vuela la base al poste: pasa a dinamico y estrena `PhysicsBody`. La union esta intacta.
	var old_physics := post.get_physics_body()
	post.make_dynamic()
	await physics_frame
	_check(post.get_physics_body() != old_physics, "el poste estrena cuerpo rigido al caer")
	_check(joints.live_count() == 1, "y la union con la tuberia sigue viva")
	_check(joint.node_a != NodePath() and joint.get_node_or_null(joint.node_a)
			== post.get_physics_body(), "reatada al cuerpo nuevo, no al muerto")
	var post_rigid := post.get_physics_body() as RigidBody3D
	var center := post_rigid.to_global(post_rigid.center_of_mass)
	post_rigid.linear_velocity = Vector3.ZERO
	post_rigid.angular_velocity = Vector3(0.0, 0.0, 2.0)
	_check(VoxelRopes._velocity_at(post, center + Vector3.UP * 2.0).x < -3.9,
		"el amortiguador del cable ve la velocidad angular en la punta del poste")
	post_rigid.angular_velocity = Vector3.ZERO
	_check(VoxelBody3D.structural_damping_for_inertia(Vector3(120.0, 4.0, 120.0)).y >= 2.0,
		"un cuerpo alargado recibe amortiguación angular de poste")
	(post.get_physics_body() as RigidBody3D).sleeping = true
	(pipe.get_physics_body() as RigidBody3D).sleeping = true
	_check(joints.wake_connected(post) == 2 \
			and not (post.get_physics_body() as RigidBody3D).sleeping \
			and not (pipe.get_physics_body() as RigidBody3D).sleeping,
		"despertar el tractor activa también el cuerpo unido del remolque")

	# Un cable entre el poste y un anclaje lejano.
	var far := _slab(world, Vector3(12.0, 6.0, 0.0), Vector3i(6, 6, 6))
	var ropes := VoxelRopes.new()
	world.add_child(ropes)
	ropes.setup(world)
	var top := Vector3(0.0, 4.0, 0.0)
	ropes.add_span(top, Vector3(12.0, 6.0, 0.0), -0.15, post, far)
	ropes.settle()
	_check(ropes.attached_count() == 1, "el cable sabe de que cuerpos cuelga")
	_check(ropes.anchor_pinned(0, "a") and ropes.anchor_pinned(0, "b"),
		"y entra clavado por los dos extremos")
	_check(post.physics_hold_count() == 2 and far.physics_hold_count() == 1,
		"joint y cable acumulan retenciones sin pisarse")

	# El poste cae. El extremo del cable tiene que irse con el, no quedarse en el aire.
	post.wake_for_interaction()
	for _frame in 20:
		await physics_frame
	var anchor := ropes.point(0, 0)
	print("  el extremo bajo %.2f m con el poste" % (top.y - anchor.y))
	_check(top.y - anchor.y > 0.1, "el extremo sigue al cuerpo al que esta clavado")

	# Se suelta del todo de la tuberia: ahora lo unico que lo sujeta es el cable. Un cable no frena
	# la caida, la convierte en pendulo: lo que garantiza es que el cuerpo no se aleje de su anclaje
	# mas de lo que da de si.
	joints.break_record(record)
	_check(post.physics_hold_count() == 1,
		"romper el joint conserva la retención del cable todavía vivo")
	var far_point := Vector3(12.0, 6.0, 0.0)
	var rest := top.distance_to(far_point)
	var worst := 0.0
	var peak_angular_speed := 0.0
	for _frame in 180:
		await physics_frame
		worst = maxf(worst, ropes.point(0, 0).distance_to(far_point))
		peak_angular_speed = maxf(
			peak_angular_speed, (post.get_physics_body() as RigidBody3D).angular_velocity.length()
		)
	print("  colgando del cable: separacion maxima %.2f m sobre %.2f de reposo" % [worst, rest])
	_check(worst <= ropes.maximum_separation(0) + 0.05,
		"el cable tira del poste y no lo deja pasar de su estiramiento maximo")
	_check(ropes.anchor_pinned(0, "a"), "y sigue clavado mientras aguanta")
	_check(peak_angular_speed < 20.0 \
			and (post.get_physics_body() as RigidBody3D).angular_velocity.length() < 4.0,
		"el poste sujeto por cable cae sin ganar un baile angular inestable")

	# Un tiron mas fuerte de lo que soporta si tiene que romperlo.
	var rigid := post.get_physics_body() as RigidBody3D
	rigid.apply_central_impulse(Vector3(-1.0, 0.0, 0.0) * rigid.mass * 40.0)
	for _frame in 120:
		await physics_frame
	var still_pinned := ropes.anchor_pinned(0, "a") and ropes.anchor_pinned(0, "b")
	print("  clavado por los dos extremos tras el tiron: %s" % still_pinned)
	_check(not still_pinned, "y revienta cuando se pasa del estiramiento maximo")
	_check(post.physics_hold_count() == 0,
		"el extremo roto libera su retención física")
	world.unregister_body(far)
	_check(not ropes.anchor_pinned(0, "a") and not ropes.anchor_pinned(0, "b") \
		and ropes.attached_count() == 0 and far.physics_hold_count() == 0,
		"desregistrar el último endpoint elimina la referencia y su retención")

	if failures == 0:
		print("VOXEL_CABLE_LINK_SELFTEST_OK")
	else:
		printerr("VOXEL_CABLE_LINK_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
