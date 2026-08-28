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
	assert(VoxelRenderSystem._grow_macro_atlas(Vector3i(32, 32, 256)) \
		== Vector3i(32, 32, 512))
	print("VOXEL_RENDERER_TOPOLOGY_GROWTH_SELFTEST_OK")
	quit()
