extends SceneTree
## Cuanto fusiona de verdad el greedy merge. El area total de las caras dividida entre el area de
## una cara de voxel da cuantas caras de voxel se estan cubriendo; comparada con el numero de quads
## emitidos sale el factor de fusion. Si es ~1, no se esta fusionando nada y la malla se puede
## reducir mucho; si es alto, la malla ya es minima y hay que hornearla o dejar de mallar.

var XML := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 60.0, Vector3.ZERO, false)
	var quads := 0
	var voxel_faces := 0.0
	for body in world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			if shape.data == null or shape.voxel_count() == 0:
				continue
			var block := VoxelBody3D.collision_block_for(shape)
			var mask := TeardownPalette.mask_for(shape)
			var area := shape.voxel_size * shape.voxel_size
			for macro: Vector3i in _blocks(shape, block):
				var faces := shape.data.build_macro_faces(
					macro, shape.voxel_size, block, 1, mask
				)
				quads += faces.size() / 6
				for i in range(0, faces.size(), 3):
					voxel_faces += (faces[i + 1] - faces[i]).cross(
						faces[i + 2] - faces[i]
					).length() * 0.5 / area
	print("quads=%d  caras de voxel cubiertas=%.0f  fusion=%.2fx" % [
		quads, voxel_faces, voxel_faces / maxf(quads, 1)
	])
	quit()


func _blocks(shape: VoxelShape3D, block: int) -> Array:
	var found := {}
	var d := shape.data.get_macro_dimensions()
	var plane := d.x * d.y
	for m in shape.data.get_occupied_macros():
		found[Vector3i((m % d.x) / block, ((m / d.x) % d.y) / block, (m / plane) / block)] = true
	return found.keys()
