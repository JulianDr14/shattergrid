class_name DedicatedVoxelBVH
extends RefCounted
## CPU builder for the prototype's GPU broad phase.
##
## Nodes are a balanced binary AABB tree. Leaves refer to one Shape; internal nodes only carry
## child indices. The packed representation deliberately uses vec4-only records so its std430
## layout is identical on Metal-through-MoltenVK and native Vulkan drivers.


static func build(transforms: Array[Transform3D], local_size: Vector3) -> Dictionary:
	var entries: Array[Dictionary] = []
	var dimensions := Vector3i(
		roundi(local_size.x / 0.1), roundi(local_size.y / 0.1), roundi(local_size.z / 0.1)
	)
	for transform in transforms:
		entries.append({
			"transform": transform,
			"dimensions": dimensions,
			"voxel_size": 0.1,
			"atlas_origin": Vector3i.ZERO,
			"macro_origin": Vector3i.ZERO,
			"macro_dimensions": Vector3i(
				(dimensions.x + 7) / 8, (dimensions.y + 7) / 8, (dimensions.z + 7) / 8
			),
			"palette_row": 0,
		})
	return build_entries(entries)


static func build_entries(entries: Array[Dictionary]) -> Dictionary:
	if entries.is_empty():
		return {}

	var records: Array[Dictionary] = []
	for shape_index in entries.size():
		var entry: Dictionary = entries[shape_index]
		var local_size := Vector3(entry.dimensions) * float(entry.voxel_size)
		var world_bounds := _transformed_bounds(entry.transform, local_size)
		records.append({
			"shape": shape_index,
			"minimum": world_bounds.position,
			"maximum": world_bounds.end,
			"center": world_bounds.get_center(),
		})

	var indices: Array[int] = []
	indices.assign(range(entries.size()))
	var nodes: Array[Dictionary] = []
	_build_node(records, indices, nodes)
	return _pack(entries, nodes)


static func refit_entries(entries: Array[Dictionary], topology: Array[Dictionary]) -> Dictionary:
	if entries.is_empty() or topology.is_empty():
		return {}
	var nodes: Array[Dictionary] = topology.duplicate(true)
	for node_index in range(nodes.size() - 1, -1, -1):
		var node: Dictionary = nodes[node_index]
		var shape_index := int(node.shape)
		if shape_index >= 0:
			if shape_index >= entries.size():
				return {}
			var entry: Dictionary = entries[shape_index]
			var bounds := _transformed_bounds(
				entry.transform, Vector3(entry.dimensions) * float(entry.voxel_size)
			)
			node.minimum = bounds.position
			node.maximum = bounds.end
		else:
			var left: Dictionary = nodes[int(node.left)]
			var right: Dictionary = nodes[int(node.right)]
			node.minimum = (left.minimum as Vector3).min(right.minimum as Vector3)
			node.maximum = (left.maximum as Vector3).max(right.maximum as Vector3)
		nodes[node_index] = node
	return _pack(entries, nodes)


## Lookup tables for refitting one moving Shape without copying the complete tree.
static func build_refit_index(
	topology: Array[Dictionary], shape_count: int
) -> Dictionary:
	var parents := PackedInt32Array()
	parents.resize(topology.size())
	parents.fill(-1)
	var leaves := PackedInt32Array()
	leaves.resize(shape_count)
	leaves.fill(-1)
	for node_index in topology.size():
		var node: Dictionary = topology[node_index]
		var shape_index := int(node.shape)
		if shape_index >= 0:
			if shape_index < leaves.size():
				leaves[shape_index] = node_index
			continue
		var left := int(node.left)
		var right := int(node.right)
		if left >= 0:
			parents[left] = node_index
		if right >= 0:
			parents[right] = node_index
	return {"parents": parents, "leaves": leaves}


## Mutates one leaf and its ancestors. Only these records need a GPU buffer update.
static func refit_entry(
	entry: Dictionary, shape_index: int, topology: Array[Dictionary],
	parents: PackedInt32Array, leaves: PackedInt32Array
) -> PackedInt32Array:
	var changed := PackedInt32Array()
	if shape_index < 0 or shape_index >= leaves.size():
		return changed
	var node_index := leaves[shape_index]
	if node_index < 0 or node_index >= topology.size():
		return changed
	var bounds := entry_bounds(entry)
	var leaf: Dictionary = topology[node_index]
	leaf.minimum = bounds.position
	leaf.maximum = bounds.end
	topology[node_index] = leaf
	changed.append(node_index)
	while node_index >= 0 and node_index < parents.size():
		node_index = parents[node_index]
		if node_index < 0:
			break
		var node: Dictionary = topology[node_index]
		var left: Dictionary = topology[int(node.left)]
		var right: Dictionary = topology[int(node.right)]
		node.minimum = (left.minimum as Vector3).min(right.minimum as Vector3)
		node.maximum = (left.maximum as Vector3).max(right.maximum as Vector3)
		topology[node_index] = node
		changed.append(node_index)
	return changed


static func pack_entry(entry: Dictionary) -> PackedByteArray:
	var shape_floats := PackedFloat32Array()
	shape_floats.resize(48)
	_pack_entry_into(shape_floats, 0, entry)
	return shape_floats.to_byte_array()


static func pack_node(node: Dictionary) -> PackedByteArray:
	var node_floats := PackedFloat32Array()
	node_floats.resize(12)
	_pack_node_into(node_floats, 0, node)
	return node_floats.to_byte_array()


static func entry_bounds(entry: Dictionary) -> AABB:
	return _transformed_bounds(
		entry.transform, Vector3(entry.dimensions) * float(entry.voxel_size)
	)


static func _pack(entries: Array[Dictionary], nodes: Array[Dictionary]) -> Dictionary:

	var node_floats := PackedFloat32Array()
	node_floats.resize(nodes.size() * 12)
	for node_index in nodes.size():
		_pack_node_into(node_floats, node_index * 12, nodes[node_index])

	var shape_floats := PackedFloat32Array()
	shape_floats.resize(entries.size() * 48)
	for shape_index in entries.size():
		_pack_entry_into(shape_floats, shape_index * 48, entries[shape_index])

	return {
		"node_bytes": node_floats.to_byte_array(),
		"shape_bytes": shape_floats.to_byte_array(),
		"node_count": nodes.size(),
		"shape_count": entries.size(),
		"nodes": nodes,
	}


static func _pack_node_into(
	target: PackedFloat32Array, offset: int, node: Dictionary
) -> void:
	var minimum: Vector3 = node.minimum
	var maximum: Vector3 = node.maximum
	target[offset + 0] = minimum.x
	target[offset + 1] = minimum.y
	target[offset + 2] = minimum.z
	target[offset + 3] = float(node.left)
	target[offset + 4] = maximum.x
	target[offset + 5] = maximum.y
	target[offset + 6] = maximum.z
	target[offset + 7] = float(node.right)
	target[offset + 8] = float(node.shape)
	target[offset + 9] = 0.0
	target[offset + 10] = 0.0
	target[offset + 11] = 0.0


static func _pack_entry_into(
	target: PackedFloat32Array, base: int, entry: Dictionary
) -> void:
	var transform: Transform3D = entry.transform
	_pack_transform(target, base, transform.affine_inverse())
	_pack_transform(target, base + 16, transform)
	var atlas_origin: Vector3i = entry.atlas_origin
	var dimensions: Vector3i = entry.dimensions
	var macro_origin: Vector3i = entry.macro_origin
	var macro_dimensions: Vector3i = entry.macro_dimensions
	_pack_vec4(target, base + 32, Vector4(
		atlas_origin.x, atlas_origin.y, atlas_origin.z, float(entry.get("palette_row", 0))
	))
	_pack_vec4(target, base + 36, Vector4(
		dimensions.x, dimensions.y, dimensions.z, float(entry.voxel_size)
	))
	_pack_vec4(target, base + 40, Vector4(
		macro_origin.x, macro_origin.y, macro_origin.z,
		1.0 if bool(entry.get("has_glass", false)) else 0.0
	))
	_pack_vec4(target, base + 44, Vector4(
		macro_dimensions.x, macro_dimensions.y, macro_dimensions.z,
		float(entry.get("brick_table_base", 0))
	))


static func _build_node(
	records: Array[Dictionary], indices: Array[int], nodes: Array[Dictionary]
) -> int:
	var node_index := nodes.size()
	nodes.append({})
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	var centers_min := minimum
	var centers_max := maximum
	for record_index in indices:
		var record: Dictionary = records[record_index]
		minimum = minimum.min(record.minimum)
		maximum = maximum.max(record.maximum)
		centers_min = centers_min.min(record.center)
		centers_max = centers_max.max(record.center)

	if indices.size() == 1:
		nodes[node_index] = {
			"minimum": minimum,
			"maximum": maximum,
			"left": -1,
			"right": -1,
			"shape": int(records[indices[0]].shape),
		}
		return node_index

	var center_extent := centers_max - centers_min
	var axis := 0
	if center_extent.y > center_extent.x and center_extent.y >= center_extent.z:
		axis = 1
	elif center_extent.z > center_extent.x:
		axis = 2
	indices.sort_custom(func(a: int, b: int) -> bool:
		return float(records[a].center[axis]) < float(records[b].center[axis])
	)
	var midpoint := indices.size() / 2
	var left_indices: Array[int] = []
	var right_indices: Array[int] = []
	left_indices.assign(indices.slice(0, midpoint))
	right_indices.assign(indices.slice(midpoint))
	var left := _build_node(records, left_indices, nodes)
	var right := _build_node(records, right_indices, nodes)
	nodes[node_index] = {
		"minimum": minimum,
		"maximum": maximum,
		"left": left,
		"right": right,
		"shape": -1,
	}
	return node_index


static func _transformed_bounds(transform: Transform3D, local_size: Vector3) -> AABB:
	var half := local_size * 0.5
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for corner_index in 8:
		var corner := Vector3(
			half.x if corner_index & 1 else -half.x,
			half.y if corner_index & 2 else -half.y,
			half.z if corner_index & 4 else -half.z
		)
		var world_corner := transform * corner
		minimum = minimum.min(world_corner)
		maximum = maximum.max(world_corner)
	return AABB(minimum, maximum - minimum)


static func _pack_transform(target: PackedFloat32Array, offset: int, transform: Transform3D) -> void:
	# GLSL mat4 constructors and storage buffers are column-major.
	var columns: Array[Vector4] = [
		Vector4(transform.basis.x.x, transform.basis.x.y, transform.basis.x.z, 0.0),
		Vector4(transform.basis.y.x, transform.basis.y.y, transform.basis.y.z, 0.0),
		Vector4(transform.basis.z.x, transform.basis.z.y, transform.basis.z.z, 0.0),
		Vector4(transform.origin.x, transform.origin.y, transform.origin.z, 1.0),
	]
	for column_index in 4:
		var column := columns[column_index]
		target[offset + column_index * 4 + 0] = column.x
		target[offset + column_index * 4 + 1] = column.y
		target[offset + column_index * 4 + 2] = column.z
		target[offset + column_index * 4 + 3] = column.w


static func _pack_vec4(target: PackedFloat32Array, offset: int, value: Vector4) -> void:
	target[offset + 0] = value.x
	target[offset + 1] = value.y
	target[offset + 2] = value.z
	target[offset + 3] = value.w
