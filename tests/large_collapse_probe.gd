extends SceneTree
## Perfil de la torre eléctrica real convertida en un único Body. Aísla el coste de Jolt: no crea
## renderer, pero conserva toda la colisión estática de Lee y deja que el compound golpee el mapa.

var MAP := VoxelProjectPaths.teardown_map_path()
const MAST_PROBE := Vector3(-3.9, 14.7, 70.9)
const HEAD_PROBE := Vector3(-3.9, 25.5, 70.9)
const SAMPLE_FRAMES := 240


func _init() -> void:
	_run.call_deferred()


func _body_near(world: VoxelWorld3D, probe: Vector3, radius: float) -> VoxelBody3D:
	for body in world.get_children():
		if not body is VoxelBody3D:
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			var bounds := shape.world_bounds()
			if probe.distance_to(probe.clamp(bounds.position, bounds.end)) <= radius:
				return body
	return null


func _run() -> void:
	var requested_boxes := 128
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--collapse-boxes="):
			requested_boxes = maxi(1, int(argument.get_slice("=", 1)))
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.impact_particles_enabled = false
	# Este probe aísla solver/compound. La destrucción mutua al tocar el mapa tiene su regresión en
	# `voxel_impact_damage_selftest`; dejarla activa cambiaría masa y composición durante la medida.
	world.physics_impact_damage_enabled = false
	world.physics_budget = VoxelPhysicsBudget.new()
	world.physics_budget.max_boxes_per_body = requested_boxes
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	for _frame in 10:
		await physics_frame

	var mast := _body_near(world, MAST_PROBE, 2.0)
	var head := _body_near(world, HEAD_PROBE, 1.0)
	assert(mast != null and head != null and mast != head)
	var head_shape := head.get_shapes()[0]
	var start_y := head_shape.world_bounds().get_center().y
	var host := world._merge_dropped_chain([mast, head] as Array[VoxelBody3D])
	var rigid := host.get_physics_body() as RigidBody3D
	assert(rigid != null)
	# Espera la salida del StaticBody viejo y limpia del monitor el frame de importación. Así el
	# perfil mide el colapso, no la construcción completa de Lee.
	for _frame in 12:
		await process_frame
		await physics_frame
		if not host.collision_handoff_pending:
			break
	assert(not host.collision_handoff_pending)
	rigid.freeze = true
	for _frame in 60:
		await process_frame
		await physics_frame
	# Velocidad inicial reproducible: fuerza impacto y vuelco sin depender de dónde quedó el último
	# voxel de la base durante una sesión manual.
	rigid.position.y += 2.0
	var raised_start_y := head_shape.world_bounds().get_center().y
	rigid.freeze = false
	rigid.linear_velocity = Vector3(0.0, -4.0, 0.0)
	rigid.angular_velocity = Vector3(0.0, 0.0, 0.55)
	rigid.sleeping = false

	var physics_ms := PackedFloat64Array()
	var pairs := PackedFloat64Array()
	var active := PackedFloat64Array()
	var minimum_y := raised_start_y
	for _frame in SAMPLE_FRAMES:
		await physics_frame
		minimum_y = minf(minimum_y, head_shape.world_bounds().get_center().y)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		pairs.append(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		active.append(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var physics_p95 := _percentile(physics_ms, 0.95)
	var passed := host.compound_boxes <= requested_boxes \
		and rigid.mass > 5000.0 and rigid.mass < 20_000.0 \
		and raised_start_y - minimum_y > 1.5 and physics_p95 <= 20.0
	print("VOXEL_LARGE_COLLAPSE_PROBE ", JSON.stringify({
		"requested_boxes": requested_boxes,
		"compound_boxes": host.compound_boxes,
		"mass": snappedf(rigid.mass, 0.1),
		"head_drop_m": snappedf(raised_start_y - minimum_y, 0.001),
		"state": host.state,
		"awake_final": host.is_awake(),
		"linear_speed_final": snappedf(rigid.linear_velocity.length(), 0.001),
		"physics_p50_ms": snappedf(_percentile(physics_ms, 0.50), 0.001),
		"physics_p95_ms": snappedf(physics_p95, 0.001),
		"physics_max_ms": snappedf(_percentile(physics_ms, 1.0), 0.001),
		"pairs_p95": int(_percentile(pairs, 0.95)),
		"pairs_max": int(_percentile(pairs, 1.0)),
		"active_max": int(_percentile(active, 1.0)),
		"pass": passed,
	}))
	quit(0 if passed else 1)


static func _percentile(source: PackedFloat64Array, fraction: float) -> float:
	var sorted := Array(source)
	sorted.sort()
	return float(sorted[clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)])
