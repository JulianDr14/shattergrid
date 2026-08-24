extends SceneTree
## El fragmento no entra al solver hasta que la colisión estática de origen refleja el corte.

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
	print("handoff y coherencia de colisión")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	var body := VoxelBody3D.new()
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(26, 2, 2)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 1000.0,
	})
	shape.anchored = true
	shape.anchor_indices = PackedInt32Array([0])
	body.add_voxel_shape(shape)
	world.register_body(body)
	for _frame in 3:
		await physics_frame

	# x=12 es el cuello; aun retirando varias capas, la derecha supera el límite cosmético.
	var result := world.damage_sphere(shape.voxel_center_world(12), 0.25, 100.0)
	var created: Array = result[0].new_bodies if not result.is_empty() else []
	_check(created.size() == 1, "el corte crea un fragmento estructural")
	if created.is_empty():
		quit(1)
		return
	var fragment := created[0] as VoxelBody3D
	var rigid := fragment.get_physics_body() as RigidBody3D
	_check(fragment.collision_handoff_pending and rigid.freeze,
		"el fragmento nace congelado mientras existe colisión antigua")
	_check(rigid.collision_layer == 0 and rigid.collision_mask == 0,
		"no puede colisionar contra sus propios voxeles estáticos")
	_check(world.get_physics_coherence_snapshot().status == "PENDING",
		"el desfase con trabajo en cola se informa como PENDING")
	var initial_y := fragment.get_shapes()[0].world_bounds().get_center().y

	for _frame in 20:
		await physics_frame
		world._process(1.0 / 60.0)
	_check(not fragment.collision_handoff_pending and not rigid.freeze,
		"se activa después de drenar y cruzar un physics tick")
	_check(rigid.collision_layer != 0 and rigid.collision_mask != 0,
		"recupera sus filtros de colisión originales")
	_check(world.get_physics_coherence_snapshot().status == "COHERENT",
		"la revisión física alcanza a la revisión voxel")
	var final_y := fragment.get_shapes()[0].world_bounds().get_center().y
	_check(final_y <= initial_y + 0.05,
		"no recibe un rebote ascendente de la colisión fantasma")

	# La ruta completa STATIC -> DYNAMIC (torres y postes que caen enteros) reemplaza el
	# StaticBody. También debe esperar a que el nodo viejo abandone el servidor físico.
	var transition_body := VoxelBody3D.new()
	world.add_child(transition_body)
	var transition_shape := VoxelShape3D.new()
	transition_shape.data = VoxelShapeData.new()
	var transition_cells := PackedByteArray()
	transition_cells.resize(4 * 12 * 4)
	transition_cells.fill(1)
	transition_shape.data.set_cells(Vector3i(4, 12, 4), transition_cells)
	transition_shape.palette = shape.palette
	transition_shape.position = Vector3(4.0, 3.0, 0.0)
	transition_body.add_voxel_shape(transition_shape)
	world.register_body(transition_body)
	await physics_frame
	transition_body.make_dynamic(16)
	var transition_rigid := transition_body.get_physics_body() as RigidBody3D
	_check(transition_body.collision_handoff_pending and transition_rigid.freeze \
		and transition_rigid.collision_layer == 0 and transition_rigid.collision_mask == 0,
		"una torre completa tampoco coincide un frame con su StaticBody antiguo")
	_check(transition_rigid.continuous_cd,
		"la torre que cae usa CCD para no atravesar un poste o apoyo delgado")
	for _frame in 4:
		await physics_frame
	_check(not transition_body.collision_handoff_pending and not transition_rigid.freeze \
		and transition_rigid.collision_layer != 0 and transition_rigid.collision_mask != 0,
		"la transición completa se activa tras un physics tick seguro")

	# Una escritura directa al Resource no emite la señal del wrapper: debe verse al instante.
	var direct_changed := shape.data.set_cell(0, 0, 0, 0)
	var desync := world.get_physics_coherence_snapshot()
	_check(direct_changed and desync.status == "DESYNC" \
		and desync.consumer == "voxel_change_signal",
		"una mutación que evita el wrapper se diagnostica como DESYNC")
	# Consultar el snapshot programa la reparación completa en diferido; la prueba no llama al
	# wrapper ni reconstruye la colisión manualmente.
	for _frame in 6:
		await process_frame
		await physics_frame
		world._process(1.0 / 60.0)
	_check(world.get_physics_coherence_snapshot().status == "COHERENT",
		"la recuperación automática vuelve a COHERENT")

	if failures == 0:
		print("VOXEL_COLLISION_HANDOFF_SELFTEST_OK")
	else:
		printerr("VOXEL_COLLISION_HANDOFF_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
