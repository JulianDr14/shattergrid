extends "res://tests/selftest/selftest.gd"

const FIXTURE := "res://tests/fixtures/mass_policy_map.xml"


func _run() -> void:
	print("política de masa: props huecos frente a estructura sólida")
	var world := make_world(false)
	TeardownMapImporter.import_map(world, ProjectSettings.globalize_path(FIXTURE),
		Vector3.ZERO, 100.0, Vector3.ZERO, true)
	var by_tag := {}
	for body: VoxelBody3D in world.get_dynamic_bodies():
		var attributes := body.get_meta("teardown_body_attributes", {}) as Dictionary
		by_tag[String(attributes.get("tags", ""))] = body
	_check(by_tag.size() == 3, "los tres props authored siguen siendo dinámicos")
	var crate := by_tag.get("mass_crate") as VoxelBody3D
	var tank := by_tag.get("mass_tank") as VoxelBody3D
	var overridden := by_tag.get("mass_override") as VoxelBody3D
	if crate != null and tank != null and overridden != null:
		var crate_mass := (crate.get_physics_body() as RigidBody3D).mass
		var tank_mass := (tank.get_physics_body() as RigidBody3D).mass
		var override_mass := (overridden.get_physics_body() as RigidBody3D).mass
		print("  masas: caja=%.3f kg tanque=%.3f kg density=.25=%.3f kg" % [
			crate_mass, tank_mass, override_mass])
		_check(is_equal_approx(crate_mass, 17.5),
			"una caja de 1 m³ visual no pesa 700 kg: representa 17,5 kg de tablas")
		_check(is_equal_approx(tank_mass, 48.75),
			"un tanque metálico visual no integra 10 cm de acero macizo")
		_check(is_equal_approx(override_mass, 4.375),
			"el density authored sigue multiplicando la masa efectiva")
		var shape := overridden.get_shapes()[0] as VoxelShape3D
		_check(is_equal_approx(shape.density_scale, 0.25) \
			and is_equal_approx(shape.physical_fill_scale, 0.025),
			"autoría XML y volumen efectivo permanecen como estados separados")
		var detached := shape.detach_component(shape.data.get_live_indices())
		_check(detached != null and is_equal_approx(
			(detached as VoxelShape3D).physical_fill_scale, shape.physical_fill_scale
		), "un fragmento del prop hereda su escala de masa")
		if detached != null:
			detached.free()
	var static_mass := -1.0
	var static_body: VoxelBody3D
	var static_shape: VoxelShape3D
	for child: Node in world.get_children():
		if not child is VoxelBody3D:
			continue
		var body := child as VoxelBody3D
		if body.state != VoxelBody3D.State.STATIC:
			continue
		for shape: VoxelShape3D in body.get_shapes():
			if shape.has_meta("teardown_source"):
				static_mass = float(shape.mass_properties().mass)
				static_body = body
				static_shape = shape
	_check(is_equal_approx(static_mass, 700.0),
		"la estructura soportada conserva densidad volumétrica canónica")
	if static_body != null and static_shape != null:
		static_body.make_dynamic(world.physics_budget.max_boxes_per_body)
		var falling_mass := (static_body.get_physics_body() as RigidBody3D).mass
		print("  estructura al caer: %.3f kg (antes %.3f kg)" % [falling_mass, static_mass])
		_check(is_equal_approx(static_shape.physical_fill_scale, 0.10) \
			and is_equal_approx(falling_mass, 70.0),
			"un fragmento estructural usa 10 % de llenado físico al volverse dinámico")
		_check(static_body.continuous_collision \
			and (static_body.get_physics_body() as RigidBody3D).continuous_cd,
			"los fragmentos estructurales largos activan CCD contra soportes delgados")
	if failures == 0:
		print("VOXEL_PROP_MASS_POLICY_SELFTEST_OK")
	else:
		printerr("VOXEL_PROP_MASS_POLICY_SELFTEST_FAIL count=", failures)
	world.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)
