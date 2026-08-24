extends SceneTree
## Los tres arreglos sobre los datos reales de Lee: cables clavados a cuerpos, la torre que cae de
## una pieza y los joints del poste de tuberias que sobreviven a que el poste se vuelva dinamico.
var MAP := VoxelProjectPaths.teardown_map_path()
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _bodies_near(world: VoxelWorld3D, probe: Vector3, radius: float) -> Array[VoxelBody3D]:
	var near: Array[VoxelBody3D] = []
	for body in world.get_children():
		if not body is VoxelBody3D or not is_instance_valid(body):
			continue
		for shape in (body as VoxelBody3D).get_shapes():
			var bounds := shape.world_bounds()
			if probe.distance_to(probe.clamp(bounds.position, bounds.end)) < radius \
					and not near.has(body):
				near.append(body)
	return near


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	for _frame in 10:
		await physics_frame

	var ropes := world.get_node_or_null("TeardownRopes") as VoxelRopes
	print("\ncables: %d tramos, %d con algun extremo clavado a un cuerpo" % [
		ropes.span_count(), ropes.attached_count()])
	var joints := world.get_node_or_null("TeardownJoints") as VoxelJoints
	print("joints: %d registrados, %d vivos" % [joints.count(), joints.live_count()])

	# La torre electrica: mastil (Body35) y cabeza (Body34) son `<vox>` distintos, cada uno con su
	# cuerpo. Al volar la base tienen que caer juntos, no cada uno por su lado.
	print("\n=== torre electrica ===")
	var tower := _bodies_near(world, Vector3(-3.9, 14.7, 70.9), 2.0)
	var head := _bodies_near(world, Vector3(-3.9, 25.5, 70.9), 1.0)
	print("  antes: mastil=%s cabeza=%s" % [tower[0].name, head[0].name])
	var head_shape := head[0].get_shapes()[0]
	var head_y := head_shape.world_bounds().get_center().y
	for step in 3:
		world.damage_sphere(Vector3(-3.92, 3.0 + float(step) * 0.8, 70.95), 3.2, 400.0)
	for _frame in 30:
		await physics_frame
	var mast_after := _bodies_near(world, Vector3(-3.9, 14.7, 70.9), 3.0)
	var mast_body: VoxelBody3D = mast_after[0] if not mast_after.is_empty() else null
	var head_body := world._body_of(head_shape)
	var head_rigid := head_body.get_physics_body() as RigidBody3D if head_body != null else null
	print("  despues: mastil estado=%d  cabeza estado=%d  mismo cuerpo=%s" % [
		mast_body.state if mast_body != null else -1,
		head_body.state if head_body != null else -1,
		mast_body == head_body])
	print("  handoff=%s freeze=%s sleeping=%s cajas=%d holds=%d colas=%s" % [
		head_body.collision_handoff_pending if head_body != null else false,
		head_rigid.freeze if head_rigid != null else false,
		head_rigid.sleeping if head_rigid != null else false,
		head_body.compound_boxes if head_body != null else -1,
		head_body.physics_hold_count() if head_body != null else -1,
		world.get_metrics(),
	])
	var tower_mass := head_rigid.mass if head_rigid != null else -1.0
	print("  masa dinamica=%.1f kg  CCD=%s  cajas activas mundo=%d/%d" % [
		tower_mass,
		head_rigid.continuous_cd if head_rigid != null else false,
		int(world.get_metrics().awake_compound_boxes),
		world.physics_budget.max_active_boxes,
	])
	var awake_records: Array[Dictionary] = []
	for awake_body: VoxelBody3D in world.get_dynamic_bodies():
		if not awake_body.is_awake():
			continue
		var awake_rigid := awake_body.get_physics_body() as RigidBody3D
		awake_records.append({
			"name": awake_body.name,
			"boxes": awake_body.compound_boxes,
			"voxels": awake_body.get_total_voxels(),
			"mass": snappedf(awake_rigid.mass, 0.1) if awake_rigid != null else -1.0,
			"holds": awake_body.physics_hold_count(),
			"structural": awake_body.structural,
		})
	awake_records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.boxes) > int(b.boxes)
	)
	print("  Bodies despiertos: ", JSON.stringify(awake_records))
	_check(head_body != null and head_body.state == VoxelBody3D.State.DYNAMIC,
		"la cabeza pierde el estado estático al destruir todos sus apoyos")
	_check(mast_body == head_body,
		"la cabeza y el tramo que la sostenía conservan un único Body")
	_check(not head_body.collision_handoff_pending,
		"el handoff no queda abandonado")
	_check(head_rigid != null and not head_rigid.continuous_cd,
		"la torre grande y lenta no barre 29 cajas con CCD permanentemente")
	_check(tower_mass > 500.0 and tower_mass < 20_000.0,
		"el remanente de torre queda por debajo de 20 t, no supera 100 t como bloque macizo")
	_check(head_body.compound_boxes <= world.physics_budget.max_boxes_per_body,
		"la colisión móvil queda dentro del presupuesto por Body")
	for _frame in 90:
		await physics_frame
	var head_drop := head_y - head_shape.world_bounds().get_center().y
	var recovery_physics_ms := PackedFloat64Array()
	for _frame in 60:
		await physics_frame
		recovery_physics_ms.append(
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		)
	var recovery_p95 := _percentile(recovery_physics_ms, 0.95)
	var rope_diagnostics := ropes.get_diagnostics()
	print("  la cabeza bajo %.2f m; física min/mediana/P95/max %.2f/%.2f/%.2f/%.2f ms; cables %s" % [
		head_drop, Array(recovery_physics_ms).min(), _percentile(recovery_physics_ms, 0.50),
		recovery_p95, Array(recovery_physics_ms).max(), JSON.stringify(rope_diagnostics),
	])
	_check(int(rope_diagnostics.same_body_awake) == 0,
		"ningún cable interno simula un resorte ni inyecta torque a la torre")
	_check(head_drop > 0.5, "la cabeza cae físicamente, no solo cambia de estado")
	_check(world.get_metrics().pending_fragments == 0 \
		and world.get_metrics().pending_collision_handoffs == 0,
		"las colas críticas quedan drenadas")
	var empty_dynamic := 0
	for dynamic_body: VoxelBody3D in world.get_dynamic_bodies():
		empty_dynamic += 1 if dynamic_body.get_total_voxels() == 0 else 0
	_check(empty_dynamic == 0,
		"no sobrevive ningún Body fantasma con cero voxeles y colisión antigua")

	# El poste de tuberias: dos joints en el punto de union, que esta intacto.
	print("\n=== poste de tuberia ===")
	var post := _bodies_near(world, Vector3(4.22, 6.4, -27.0), 0.3)[0]
	var mine: Array[Dictionary] = []
	for record in joints._records:
		if record.get("owner_body") == post or record.get("other_body") == post:
			mine.append(record)
	print("  joints del poste: %d" % mine.size())
	world.damage_sphere(Vector3(4.22, 2.2, -27.0), 1.6, 200.0)
	for _frame in 30:
		await physics_frame
	var live := 0
	for record in mine:
		if VoxelDoor3D._record_joint_is_live(record):
			live += 1
	print("  tras volar la base: %d de %d siguen vivos" % [live, mine.size()])
	_check(live == mine.size(), "los joints intactos sobreviven a la transición del poste")
	for _drain_frame in 120:
		var metrics := world.get_metrics()
		if int(metrics.pending_fragments) == 0 \
				and int(metrics.pending_collision_handoffs) == 0 \
				and int(metrics.pending_collision_rebuilds) == 0 \
				and int(metrics.pending_collision_blocks) == 0:
			break
		await physics_frame
	var drained := world.get_metrics()
	_check(int(drained.pending_fragments) == 0 \
		and int(drained.pending_collision_handoffs) == 0 \
		and int(drained.pending_collision_rebuilds) == 0 \
		and int(drained.pending_collision_blocks) == 0,
		"no quedan handoffs ni rebuilds abandonados al drenar Lee")
	if failures == 0:
		print("VOXEL_LEE_PHYSICS_REGRESSION_OK")
	else:
		printerr("VOXEL_LEE_PHYSICS_REGRESSION_FAIL count=", failures)
	quit(1 if failures > 0 else 0)


static func _percentile(source: PackedFloat64Array, fraction: float) -> float:
	if source.is_empty():
		return INF
	var sorted := Array(source)
	sorted.sort()
	return float(sorted[clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)])
