extends "res://tests/selftest/selftest.gd"
## Un choque real de Jolt debe dañar a los dos volúmenes, una sola vez por contacto dominante, sin
## convertirlo en explosión radial ni ejecutar mutaciones dentro de `_integrate_forces`.


func _make_body(
	world: VoxelWorld3D, dimensions: Vector3i, origin: Vector3,
	dynamic: bool, hardness: float, density: float, fill_scale := 1.0
) -> Dictionary:
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
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": hardness, "density": density,
	})
	shape.anchored = false
	shape.physical_fill_scale = fill_scale
	shape.transform = Transform3D(Basis.IDENTITY, origin)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return {"body": body, "shape": shape}


func _run() -> void:
	print("daño voxel bidireccional por impacto")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.impact_particles_enabled = false
	root.add_child(world)
	var target := _make_body(
		world, Vector3i(20, 5, 20), Vector3(0, 0, 0), false, 1.0, 700.0
	)
	var hammer := _make_body(
		world, Vector3i(10, 10, 10), Vector3(0, 5.0, 0), true, 2.4, 7800.0, 0.025
	)
	var target_before := (target.shape as VoxelShape3D).voxel_count()
	var hammer_before := (hammer.shape as VoxelShape3D).voxel_count()
	var rigid := (hammer.body as VoxelBody3D).get_physics_body() as RigidBody3D
	rigid.continuous_cd = true
	rigid.sleeping = false
	for _frame in 240:
		await physics_frame
		if world.physics_impacts > 0 and world.get_metrics().pending_physics_impacts == 0:
			for _settle in 12:
				await process_frame
				await physics_frame
			break
	var target_after := (target.shape as VoxelShape3D).voxel_count() \
		if is_instance_valid(target.shape) else 0
	var hammer_after := (hammer.shape as VoxelShape3D).voxel_count() \
		if is_instance_valid(hammer.shape) else 0
	print("  objetivo %d→%d  martillo %d→%d  impactos=%d coste=%.2f ms" % [
		target_before, target_after, hammer_before, hammer_after,
		world.physics_impacts, world.physics_impact_damage_ms,
	])
	print("  último contacto: ", world.last_physics_impact)
	_check(world.physics_impacts > 0, "Jolt reporta el contacto dominante al World")
	_check(target_after < target_before, "el objeto golpeado pierde voxeles")
	_check(hammer_after < hammer_before, "el objeto que golpea también recibe daño")
	_check(int(world.get_metrics().pending_physics_impacts) == 0,
		"la cola de impactos queda drenada")

	# Follaje/unphysical no tiene caras Jolt. Aun así, un cuerpo veloz debe detectarlo por contacto
	# voxel exacto y abrirse paso; esta es la ruta torre metálica contra árbol.
	var foliage := _make_body(
		world, Vector3i(5, 12, 5), Vector3(0, 4.0, 5.0), false, 0.6, 300.0
	)
	(foliage.body as VoxelBody3D).collision_enabled = false
	(foliage.body as VoxelBody3D).rebuild_all_collision()
	var projectile := _make_body(
		world, Vector3i(6, 6, 6), Vector3(-3.0, 4.0, 5.0), true, 2.4, 7800.0, 0.025
	)
	var projectile_rigid := (projectile.body as VoxelBody3D).get_physics_body() as RigidBody3D
	projectile_rigid.gravity_scale = 0.0
	projectile_rigid.linear_velocity = Vector3(9.0, 0.0, 0.0)
	world.motion_contact_hits = 0
	var foliage_before := (foliage.shape as VoxelShape3D).voxel_count()
	var aabb_overlap_seen := false
	var exact_touch_seen := false
	for _frame in 90:
		await physics_frame
		var projectile_shape := projectile.shape as VoxelShape3D
		var foliage_shape := foliage.shape as VoxelShape3D
		if is_instance_valid(projectile_shape) and is_instance_valid(foliage_shape) \
				and projectile_shape.world_bounds().grow(0.08).intersects(foliage_shape.world_bounds()):
			aabb_overlap_seen = true
			exact_touch_seen = exact_touch_seen or world._shapes_touch_with_margin(
				projectile_shape, foliage_shape, 0.08
			)
		if (foliage.shape as VoxelShape3D).voxel_count() < foliage_before:
			break
	var foliage_after := (foliage.shape as VoxelShape3D).voxel_count()
	print("  follaje no-colisionable %d→%d  contactos=%d aabb=%s exacto=%s pos=%s" % [
		foliage_before, foliage_after, world.motion_contact_hits,
		aabb_overlap_seen, exact_touch_seen, projectile_rigid.global_position,
	])
	_check(foliage_after < foliage_before,
		"metal veloz destruye follaje aunque este no bloquee al jugador")
	if failures == 0:
		print("VOXEL_IMPACT_DAMAGE_SELFTEST_OK")
	else:
		printerr("VOXEL_IMPACT_DAMAGE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
