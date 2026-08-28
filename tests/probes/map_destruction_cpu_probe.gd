extends SceneTree
## CPU-only probe over the complete licensed Lee map. It deliberately skips collision and rendering
## so a regression in AABB queries or connectivity can be measured without stressing the GPU.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if not FileAccess.file_exists(MAP):
		print("MAP_DESTRUCTION_CPU_PROBE_SKIPPED missing_map")
		quit(0)
		return
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.impact_particles_enabled = false
	root.add_child(world)
	var collision := "--with-collision" in OS.get_cmdline_user_args()
	var focused_collision := "--focused-collision" in OS.get_cmdline_user_args()
	var import_started := Time.get_ticks_usec()
	var report := TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, collision
	)
	var import_ms := (Time.get_ticks_usec() - import_started) / 1000.0
	var process_started := Time.get_ticks_usec()
	for _frame in 600:
		world._process(1.0 / 60.0)
	var world_process_average_us := (Time.get_ticks_usec() - process_started) / 600.0
	var maintenance_started := Time.get_ticks_usec()
	for _sample in 20:
		world._enforce_physics_budget(false)
	var budget_average_us := (Time.get_ticks_usec() - maintenance_started) / 20.0
	maintenance_started = Time.get_ticks_usec()
	for _sample in 2000:
		world._update_metrics()
	var metrics_average_us := (Time.get_ticks_usec() - maintenance_started) / 2000.0
	maintenance_started = Time.get_ticks_usec()
	for _sample in 2000:
		world._refresh_awake_dynamic_grid()
	var awake_grid_average_us := (Time.get_ticks_usec() - maintenance_started) / 2000.0
	var largest: VoxelShape3D
	var collision_blocks_current := 0
	var collision_blocks_max4 := 0
	for node in world.get_children():
		if not node is VoxelBody3D or (node as VoxelBody3D).state != VoxelBody3D.State.STATIC:
			continue
		for shape: VoxelShape3D in (node as VoxelBody3D).get_shapes():
			if largest == null or shape.voxel_count() > largest.voxel_count():
				largest = shape
			var block := VoxelBody3D.collision_block_for(shape)
			collision_blocks_current += _occupied_collision_blocks(shape, block)
			collision_blocks_max4 += _occupied_collision_blocks(shape, mini(4, block))
	assert(largest != null)
	var focused_collision_build_ms := 0.0
	if focused_collision:
		var largest_body := largest.get_parent().get_parent() as VoxelBody3D
		largest_body.collision_enabled = true
		var focused_started := Time.get_ticks_usec()
		largest_body.rebuild_static_collision(largest)
		focused_collision_build_ms = (Time.get_ticks_usec() - focused_started) / 1000.0
	var dense_target := _dense_target(largest)
	var dense_started := Time.get_ticks_usec()
	world.damage_sphere(dense_target, 0.72, 10.0)
	var dense_call_ms := (Time.get_ticks_usec() - dense_started) / 1000.0
	var dense_profile := world.get_metrics()
	var targets := [
		_target_in_macro(largest, 0.33),
		_target_in_macro(largest, 0.67),
	]
	var calls := PackedFloat64Array()
	var profiles: Array[Dictionary] = []
	var created_bodies := 0
	for target: Vector3 in targets:
		var started := Time.get_ticks_usec()
		var affected := world.damage_sphere(target, 0.72, 10.0)
		calls.append((Time.get_ticks_usec() - started) / 1000.0)
		profiles.append(world.get_metrics())
		for record: Dictionary in affected:
			created_bodies += (record.new_bodies as Array).size()
	var collision_frames := PackedFloat64Array()
	var collision_frame_limit := 256
	while int(world.get_metrics().pending_collision_rebuilds) > 0 \
			and collision_frames.size() < collision_frame_limit:
		var collision_started := Time.get_ticks_usec()
		world._process(1.0 / 60.0)
		collision_frames.append((Time.get_ticks_usec() - collision_started) / 1000.0)
	var collision_update_max_ms := 0.0
	for sample in collision_frames:
		collision_update_max_ms = maxf(collision_update_max_ms, sample)
	print("MAP_DESTRUCTION_CPU_PROBE ", JSON.stringify({
		"import_ms": snappedf(import_ms, 0.001),
		"collision_enabled": collision,
		"focused_collision": focused_collision,
		"focused_collision_build_ms": snappedf(focused_collision_build_ms, 0.001),
		"collision_blocks_current": collision_blocks_current,
		"collision_blocks_max4": collision_blocks_max4,
		"collision_update_frames": collision_frames.size(),
		"collision_update_max_ms": snappedf(collision_update_max_ms, 0.001),
		"world_process_average_us": snappedf(world_process_average_us, 0.001),
		"budget_average_us": snappedf(budget_average_us, 0.001),
		"metrics_average_us": snappedf(metrics_average_us, 0.001),
		"awake_grid_average_us": snappedf(awake_grid_average_us, 0.001),
		"map_voxels": int(report.get("voxels", 0)),
		"map_shapes": int(report.get("shapes", 0)),
		"target_dimensions": largest.data.get_dimensions(),
		"target_voxels": largest.voxel_count(),
		"dense_crater_ms": snappedf(dense_call_ms, 0.001),
		"dense_guard_ms": snappedf(float(dense_profile.damage_connectivity_guard_ms), 0.001),
		"dense_skipped": int(dense_profile.connectivity_skipped),
		"first_call_ms": snappedf(calls[0], 0.001),
		"steady_call_ms": snappedf(calls[1], 0.001),
		"first_guard_ms": snappedf(float(profiles[0].damage_connectivity_guard_ms), 0.001),
		"steady_guard_ms": snappedf(float(profiles[1].damage_connectivity_guard_ms), 0.001),
		"first_split_ms": snappedf(float(profiles[0].damage_split_ms), 0.001),
		"steady_split_ms": snappedf(float(profiles[1].damage_split_ms), 0.001),
		"first_external_support_ms": snappedf(
			float(profiles[0].damage_external_support_ms), 0.001
		),
		"steady_external_support_ms": snappedf(
			float(profiles[1].damage_external_support_ms), 0.001
		),
		"first_component_fill_ms": snappedf(
			float(profiles[0].damage_component_fill_ms), 0.001
		),
		"steady_component_fill_ms": snappedf(
			float(profiles[1].damage_component_fill_ms), 0.001
		),
		"steady_support_contacts_ms": snappedf(
			float(profiles[1].damage_support_contacts_ms), 0.001
		),
		"steady_support_routes_ms": snappedf(
			float(profiles[1].damage_support_routes_ms), 0.001
		),
		"connectivity_skipped": int(profiles[0].connectivity_skipped)
			+ int(profiles[1].connectivity_skipped),
		"created_bodies": created_bodies,
	}))
	quit(0)


static func _occupied_collision_blocks(shape: VoxelShape3D, block: int) -> int:
	var unique := {}
	var dimensions := shape.data.get_macro_dimensions()
	var plane := dimensions.x * dimensions.y
	for index in shape.data.get_occupied_macros():
		unique[Vector3i(
			(index % dimensions.x) / block,
			((index / dimensions.x) % dimensions.y) / block,
			(index / plane) / block
		)] = true
	return unique.size()


static func _dense_target(shape: VoxelShape3D) -> Vector3:
	var occupied := shape.data.get_occupied_macros()
	var dimensions := shape.data.get_dimensions()
	var macro_dimensions := shape.data.get_macro_dimensions()
	var hardnesses := shape.palette.get_hardnesses()
	var stride := maxi(1, occupied.size() / 512)
	for slot in range(0, occupied.size(), stride):
		var index := occupied[slot]
		var macro := Vector3i(
			index % macro_dimensions.x,
			(index / macro_dimensions.x) % macro_dimensions.y,
			index / (macro_dimensions.x * macro_dimensions.y)
		)
		for z in range(maxi(1, macro.z * 8), mini(dimensions.z - 1, macro.z * 8 + 8)):
			for y in range(maxi(1, macro.y * 8), mini(dimensions.y - 1, macro.y * 8 + 8)):
				for x in range(maxi(1, macro.x * 8), mini(dimensions.x - 1, macro.x * 8 + 8)):
					var material := shape.data.get_cell(x, y, z)
					if material == 0 or hardnesses[material] > 10.0:
						continue
					if shape.data.get_cell(x - 1, y, z) != 0 \
							and shape.data.get_cell(x + 1, y, z) != 0 \
							and shape.data.get_cell(x, y - 1, z) != 0 \
							and shape.data.get_cell(x, y + 1, z) != 0 \
							and shape.data.get_cell(x, y, z - 1) != 0 \
							and shape.data.get_cell(x, y, z + 1) != 0:
						return shape.voxel_center_world(
							x + y * dimensions.x + z * dimensions.x * dimensions.y
						)
	return _target_in_macro(shape, 0.5)


static func _target_in_macro(shape: VoxelShape3D, fraction: float) -> Vector3:
	var occupied := shape.data.get_occupied_macros()
	var dimensions := shape.data.get_dimensions()
	var macro_dimensions := shape.data.get_macro_dimensions()
	var slot := clampi(int(occupied.size() * fraction), 0, occupied.size() - 1)
	var index := occupied[slot]
	var macro := Vector3i(
		index % macro_dimensions.x,
		(index / macro_dimensions.x) % macro_dimensions.y,
		index / (macro_dimensions.x * macro_dimensions.y)
	)
	for z in range(macro.z * 8, mini(dimensions.z, macro.z * 8 + 8)):
		for y in range(macro.y * 8, mini(dimensions.y, macro.y * 8 + 8)):
			for x in range(macro.x * 8, mini(dimensions.x, macro.x * 8 + 8)):
				if shape.data.get_cell(x, y, z) != 0:
					return shape.voxel_center_world(
						x + y * dimensions.x + z * dimensions.x * dimensions.y
					)
	return shape.world_bounds().get_center()
