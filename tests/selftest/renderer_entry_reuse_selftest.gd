extends SceneTree
## Regresión del presupuesto visual: una hoja liberada se reutiliza sin perder los metadatos del
## pase transparente. No necesita RenderingDevice; valida la topología y los registros CPU.


func _entry(dimensions: Vector3i, has_glass: bool) -> Dictionary:
	return {
		"transform": Transform3D.IDENTITY,
		"dimensions": dimensions,
		"voxel_size": 0.1,
		"atlas_origin": Vector3i.ZERO,
		"macro_origin": Vector3i.ZERO,
		"macro_dimensions": Vector3i.ONE,
		"brick_table_base": 0,
		"palette_row": 0,
		"has_glass": has_glass,
	}


func _initialize() -> void:
	var renderer := VoxelRenderSystem.new()
	renderer._free_entry_indices = PackedInt32Array([3, 7])
	renderer._entry_glass_capable = {3: false, 7: true}
	assert(renderer._find_free_entry_offset(false) == 1,
		"un opaco puede reutilizar cualquier hoja libre")
	renderer._free_entry_indices = PackedInt32Array([7, 3])
	assert(renderer._find_free_entry_offset(true) == 0,
		"un vidrio no puede entrar en una hoja ausente del BVH transparente")

	var placeholder := VoxelRenderSystem._placeholder_entry(1)
	var fragment := _entry(Vector3i(9, 5, 3), true)
	fragment.atlas_origin = Vector3i(4, 6, 8)
	fragment.brick_table_base = 123
	var glass_entry := DedicatedVoxelDDAEffect._glass_entry_after_update(
		placeholder, fragment, true
	)
	assert(glass_entry.dimensions == fragment.dimensions \
		and glass_entry.atlas_origin == fragment.atlas_origin \
		and int(glass_entry.brick_table_base) == 123,
		"activar la reserva copia todos los metadatos al BVH transparente")
	renderer.free()
	print("VOXEL_RENDERER_ENTRY_REUSE_SELFTEST_OK")
	quit()
