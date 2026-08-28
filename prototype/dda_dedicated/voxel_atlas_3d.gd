class_name VoxelAtlas3D
extends RefCounted
## A 3D R8UI atlas backed by the global RenderingDevice.
##
## Damage uploads a compact storage buffer and a compute kernel writes only the dirty cuboid. The
## non-integer prototype keeps a texture-copy fallback; the product R8UI path never replaces the
## full volume, so a small crater does not scale with the complete asset.

const REGION_UPLOAD_SHADER := preload("res://shaders/voxel/voxel_region_upload.glsl")

var texture: Texture3DRD
var dimensions := Vector3i.ZERO
var last_uploaded_bytes := 0

var _rd: RenderingDevice
var _texture_rid := RID()
var _staging_textures := {}
var _staging_buffers := {}
var _upload_shader := RID()
var _upload_pipeline := RID()
var _integer_texture := false
var _deferred_updates := false
var _pending_uploads: Array[Dictionary] = []
var _upload_mutex := Mutex.new()


func get_rd_rid() -> RID:
	return _texture_rid


func enable_deferred_updates() -> void:
	_deferred_updates = true


func create(size: Vector3i, bytes: PackedByteArray, integer_texture := false) -> bool:
	var keep_deferred_updates := _deferred_updates
	release()
	_deferred_updates = keep_deferred_updates
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		push_error("VoxelAtlas3D: invalid dimensions %s" % size)
		return false
	if bytes.size() != size.x * size.y * size.z:
		push_error("VoxelAtlas3D: %d bytes for dimensions %s" % [bytes.size(), size])
		return false

	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_error("VoxelAtlas3D requires a RenderingDevice renderer")
		return false

	dimensions = size
	_integer_texture = integer_texture
	var format := _format_for(
		size,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
		integer_texture
	)
	var initial: Array[PackedByteArray] = [bytes]
	_texture_rid = _rd.texture_create(format, RDTextureView.new(), initial)
	if not _texture_rid.is_valid():
		push_error("VoxelAtlas3D: RenderingDevice rejected the 3D texture")
		return false

	# Godot's high-level Texture3DRD wrapper cannot publish integer image formats. The spatial
	# prototype therefore uses normalized R8, while the dedicated winner consumes R8UI directly.
	if not integer_texture:
		texture = Texture3DRD.new()
		texture.texture_rd_rid = _texture_rid
	last_uploaded_bytes = bytes.size()
	return true


func update_region(full_bytes: PackedByteArray, dirty_min: Vector3i, dirty_max: Vector3i) -> bool:
	if not _texture_rid.is_valid() or _rd == null:
		return false
	if dirty_min.x < 0 or dirty_max.x < dirty_min.x:
		last_uploaded_bytes = 0
		return true
	dirty_min = dirty_min.max(Vector3i.ZERO)
	dirty_max = dirty_max.min(dimensions - Vector3i.ONE)
	var region_size := dirty_max - dirty_min + Vector3i.ONE
	if region_size.x <= 0 or region_size.y <= 0 or region_size.z <= 0:
		last_uploaded_bytes = 0
		return true

	var packed := PackedByteArray()
	packed.resize(region_size.x * region_size.y * region_size.z)
	var destination := 0
	var source_plane := dimensions.x * dimensions.y
	for z in region_size.z:
		for y in region_size.y:
			var source := dirty_min.x \
				+ (dirty_min.y + y) * dimensions.x \
				+ (dirty_min.z + z) * source_plane
			for x in region_size.x:
				packed[destination] = full_bytes[source + x]
				destination += 1

	return update_compact_region(packed, dirty_min, region_size)


## Uploads bytes that are already tightly packed for the destination cuboid. Clipmap scrolling
## uses this path so it never extracts hundreds of thousands of bytes from a 16 MiB CPU mirror in
## GDScript merely to clear or replace a toroidal slab.
func update_compact_region(
	packed: PackedByteArray, destination: Vector3i, region_size: Vector3i
) -> bool:
	return update_compact_regions(packed, region_size, [{
		"source": Vector3i.ZERO,
		"destination": destination,
		"size": region_size,
	}])


## Uploads one tightly packed source and copies any number of cuboids out of it. Toroidal
## clipmaps use this to wrap at texture borders without repacking every byte in GDScript.
func update_compact_regions(
	packed: PackedByteArray, source_size: Vector3i, copies: Array[Dictionary]
) -> bool:
	if not _texture_rid.is_valid() or _rd == null:
		return false
	if source_size.x <= 0 or source_size.y <= 0 or source_size.z <= 0 \
		or packed.size() != source_size.x * source_size.y * source_size.z:
		last_uploaded_bytes = 0
		return false
	for copy: Dictionary in copies:
		var source: Vector3i = copy.source
		var destination: Vector3i = copy.destination
		var region_size: Vector3i = copy.size
		if source.x < 0 or source.y < 0 or source.z < 0 \
			or source.x + region_size.x > source_size.x \
			or source.y + region_size.y > source_size.y \
			or source.z + region_size.z > source_size.z \
			or destination.x < 0 or destination.y < 0 or destination.z < 0 \
			or destination.x + region_size.x > dimensions.x \
			or destination.y + region_size.y > dimensions.y \
			or destination.z + region_size.z > dimensions.z:
			push_error("VoxelAtlas3D: compact copy outside source or texture bounds")
			return false
	last_uploaded_bytes = packed.size()
	var upload_size := Vector3i(
		_next_power_of_two(source_size.x),
		_next_power_of_two(source_size.y),
		_next_power_of_two(source_size.z)
	)
	var upload_bytes := packed if upload_size == source_size \
		else _pad_compact_source(packed, source_size, upload_size)
	if _deferred_updates:
		_upload_mutex.lock()
		_pending_uploads.append({
			"bytes": upload_bytes,
			"source_size": upload_size,
			"copies": copies.duplicate(true),
		})
		_upload_mutex.unlock()
	else:
		# Prototype/setup fallback. Product atlases are drained directly by the compositor callback.
		RenderingServer.call_on_render_thread(
			_update_compact_regions_render_thread.bind(
				upload_bytes, upload_size, copies.duplicate(true)
			)
		)
	return true


## Called by DedicatedVoxelDDAEffect from inside its render callback. This avoids the implicit
## main/render-thread rendezvous caused by `call_on_render_thread` during camera movement.
func flush_pending_render_thread() -> void:
	_upload_mutex.lock()
	var uploads := _pending_uploads.duplicate()
	_pending_uploads.clear()
	_upload_mutex.unlock()
	for upload: Dictionary in uploads:
		_update_compact_regions_render_thread(upload.bytes, upload.source_size, upload.copies)


func _update_compact_regions_render_thread(
	packed: PackedByteArray, source_size: Vector3i, copies: Array
) -> void:
	if _rd == null or not _texture_rid.is_valid():
		return
	if _integer_texture and _update_compact_compute(packed, source_size, copies):
		return
	var integer_texture := _integer_texture
	var staging := _staging_texture(source_size, integer_texture, packed)
	if not staging.is_valid():
		return
	for copy: Dictionary in copies:
		var error := _rd.texture_copy(
			staging,
			_texture_rid,
			Vector3(copy.source),
			Vector3(copy.destination),
			Vector3(copy.size),
			0,
			0,
			0,
			0
		)
		if error != OK:
			push_error("VoxelAtlas3D: regional texture copy failed (%s)" % error)


func release() -> void:
	texture = null
	_upload_mutex.lock()
	_pending_uploads.clear()
	_upload_mutex.unlock()
	if _rd != null:
		for entry: Dictionary in _staging_textures.values():
			for staging: RID in entry.rids:
				if staging.is_valid():
					_rd.free_rid(staging)
	_staging_textures.clear()
	if _rd != null:
		for entry: Dictionary in _staging_buffers.values():
			for staging: RID in entry.rids:
				if staging.is_valid():
					_rd.free_rid(staging)
	_staging_buffers.clear()
	if _rd != null and _upload_pipeline.is_valid():
		_rd.free_rid(_upload_pipeline)
	if _rd != null and _upload_shader.is_valid():
		_rd.free_rid(_upload_shader)
	_upload_pipeline = RID()
	_upload_shader = RID()
	if _rd != null and _texture_rid.is_valid():
		_rd.free_rid(_texture_rid)
	_texture_rid = RID()
	_rd = null
	dimensions = Vector3i.ZERO
	last_uploaded_bytes = 0
	_integer_texture = false
	_deferred_updates = false


func _staging_texture(
	size: Vector3i, integer_texture: bool, bytes: PackedByteArray
) -> RID:
	var key := "%dx%dx%d:%d" % [size.x, size.y, size.z, int(integer_texture)]
	var entry: Dictionary = _staging_textures.get(key, {"rids": [], "cursor": 0})
	var rids: Array = entry.rids
	var cursor := int(entry.cursor)
	var staging := RID()
	if rids.is_empty():
		var staging_format := _format_for(
			size,
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
				| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
			integer_texture
		)
		var staging_data: Array[PackedByteArray] = [bytes]
		# Allocate the ring in one warm-up event. With lazy allocation, the first three impacts of
		# every region size each paid a driver allocation on a different visible frame.
		for ring_index in 3:
			var ring_staging := _rd.texture_create(
				staging_format, RDTextureView.new(), staging_data
			)
			if not ring_staging.is_valid():
				push_error("VoxelAtlas3D: could not allocate the staging texture")
				return RID()
			rids.append(ring_staging)
		staging = rids[0]
		cursor = 0
	else:
		cursor = cursor % rids.size()
		staging = rids[cursor]
		var error := _rd.texture_update(staging, 0, bytes)
		if error != OK:
			push_error("VoxelAtlas3D: could not refresh staging texture (%s)" % error)
			return RID()
	entry.rids = rids
	entry.cursor = (cursor + 1) % 3
	_staging_textures[key] = entry
	return staging


func _update_compact_compute(
	packed: PackedByteArray, source_size: Vector3i, copies: Array
) -> bool:
	if not _ensure_compute_resources():
		return false
	var upload_bytes := packed
	while upload_bytes.size() % 4 != 0:
		upload_bytes.append(0)
	var staging := _staging_buffer(source_size, upload_bytes)
	if not staging.is_valid():
		return false
	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(_texture_rid)
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	source_uniform.binding = 1
	source_uniform.add_id(staging)
	var uniform_set := UniformSetCacheRD.get_cache(
		_upload_shader, 0, [image_uniform, source_uniform]
	)
	if not uniform_set.is_valid():
		return false
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, _upload_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	for copy: Dictionary in copies:
		var destination: Vector3i = copy.destination
		var source: Vector3i = copy.source
		var size: Vector3i = copy.size
		var push := PackedInt32Array([
			destination.x, destination.y, destination.z, size.x,
			source_size.x, source_size.y, source_size.z, size.y,
			source.x, source.y, source.z, size.z,
		])
		_rd.compute_list_set_push_constant(compute_list, push.to_byte_array(), 48)
		_rd.compute_list_dispatch(
			compute_list, ceili(size.x / 4.0), ceili(size.y / 4.0), ceili(size.z / 4.0)
		)
		_rd.compute_list_add_barrier(compute_list)
	_rd.compute_list_end()
	return true


func _ensure_compute_resources() -> bool:
	if _upload_shader.is_valid() and _upload_pipeline.is_valid():
		return true
	var spirv: RDShaderSPIRV = REGION_UPLOAD_SHADER.get_spirv()
	if spirv == null or not spirv.compile_error_compute.is_empty():
		push_error("VoxelAtlas3D: regional compute shader failed: %s" % (
			"missing SPIR-V" if spirv == null else spirv.compile_error_compute
		))
		return false
	_upload_shader = _rd.shader_create_from_spirv(spirv, "Voxel regional upload")
	if not _upload_shader.is_valid():
		return false
	_upload_pipeline = _rd.compute_pipeline_create(_upload_shader)
	return _upload_pipeline.is_valid()


func _staging_buffer(size: Vector3i, bytes: PackedByteArray) -> RID:
	var key := "%dx%dx%d" % [size.x, size.y, size.z]
	var entry: Dictionary = _staging_buffers.get(key, {"rids": [], "cursor": 0})
	var rids: Array = entry.rids
	var cursor := int(entry.cursor)
	var staging := RID()
	if rids.is_empty():
		for ring_index in 3:
			var ring_staging := _rd.storage_buffer_create(bytes.size(), bytes)
			if not ring_staging.is_valid():
				return RID()
			rids.append(ring_staging)
		staging = rids[0]
		cursor = 0
	else:
		cursor = cursor % rids.size()
		staging = rids[cursor]
		var error := _rd.buffer_update(staging, 0, bytes.size(), bytes)
		if error != OK:
			return RID()
	entry.rids = rids
	entry.cursor = (cursor + 1) % 3
	_staging_buffers[key] = entry
	return staging


static func _pad_compact_source(
	source: PackedByteArray, source_size: Vector3i, padded_size: Vector3i
) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(padded_size.x * padded_size.y * padded_size.z)
	for z in source_size.z:
		for y in source_size.y:
			var source_offset := y * source_size.x + z * source_size.x * source_size.y
			var target_offset := y * padded_size.x + z * padded_size.x * padded_size.y
			for x in source_size.x:
				result[target_offset + x] = source[source_offset + x]
	return result


static func _next_power_of_two(value: int) -> int:
	var result := 1
	while result < value:
		result <<= 1
	return result


func _format_for(size: Vector3i, usage: int, integer_texture: bool) -> RDTextureFormat:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R8_UINT if integer_texture \
		else RenderingDevice.DATA_FORMAT_R8_UNORM
	format.width = size.x
	format.height = size.y
	format.depth = size.z
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = usage
	return format
