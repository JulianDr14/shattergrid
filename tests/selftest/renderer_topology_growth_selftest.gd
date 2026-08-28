extends SceneTree
## Regresión del fallo de escombros con colisión pero sin imagen: el BVH debe aceptar más hojas que
## la reserva inicial y reconstruir también el subconjunto transparente cuando cambia su tamaño.


func _initialize() -> void:
	var initial: Array[Dictionary] = []
	for index in 8:
		initial.append(VoxelRenderSystem._placeholder_entry(index))
	var grown: Array[Dictionary] = []
	for index in 520:
		grown.append(VoxelRenderSystem._placeholder_entry(index))
	assert(DedicatedVoxelDDAEffect._topology_must_rebuild(
		false, initial.size(), grown.size(), false
	),
		"cambiar el número de hojas debe reconstruir la topología aunque la paleta no cambie")
	var built := DedicatedVoxelBVH.build_entries(grown)
	assert(not built.is_empty() and int(built.node_count) == grown.size() * 2 - 1,
		"el BVH ampliado debe contener todas sus hojas")
	var animation := VoxelSurfaceAnimation.create(
		122, AABB(Vector3(0, 0, 0), Vector3(78, 13, 38)), 4.0, 4.0
	)
	# El bucle envuelve en el perímetro del octógono del perfil, no en el paso del eslabón ni en el
	# rectángulo: el shader calcula ese mismo valor y cualquier desajuste salta de fase cada vuelta.
	var perimeter := animation.perimeter_cells()
	assert(is_equal_approx(perimeter, 168.627417),
		"el perímetro del perfil achaflanado coincide con el que deriva el shader")
	animation.advance(perimeter + 1.25, 2.5)
	assert(is_equal_approx(animation.offsets.x, 1.25),
		"el offset da la vuelta al perímetro del perfil")
	var animated_entry := VoxelRenderSystem._placeholder_entry(0)
	animated_entry.surface_animation = animation.gpu_parameters()
	var packed := DedicatedVoxelBVH.pack_entry(animated_entry)
	assert(packed.size() == 240, "el ABI de Shape reserva 240 bytes con animación superficial")
	var floats := packed.to_float32_array()
	assert(is_equal_approx(floats[48], 1.25) and is_equal_approx(floats[49], 2.5)
		and roundi(floats[50]) == 122 and is_equal_approx(floats[51], 1.0),
		"offsets, material y activación conservan su posición en el ABI")
	assert(Vector3(floats[52], floats[53], floats[54]) == Vector3.ZERO
		and is_equal_approx(floats[55], 4.0)
		and Vector3(floats[56], floats[57], floats[58]) == Vector3(78, 13, 38)
		and is_equal_approx(floats[59], 4.0),
		"límites, paso del eslabón y chaflán del perfil llegan completos al shader")
	assert(VoxelRenderSystem._grow_macro_atlas(Vector3i(32, 32, 256)) \
		== Vector3i(32, 32, 512))
	print("VOXEL_RENDERER_TOPOLOGY_GROWTH_SELFTEST_OK")
	quit()
