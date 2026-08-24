extends SceneTree
## Cuanto cuesta la busqueda de cimiento en el mapa real, y cuanto suelta.
##
## El riesgo es `touches`: recorre los voxeles del solape entre dos Shapes, y en Lee hay Shapes de
## 25 M de voxeles. Si el coste por disparo se dispara, se ve aqui y no en la partida.
var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.verify_connectivity_in_debug = "--verify-connectivity" in OS.get_cmdline_user_args()
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	var report := TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	world.finalize_spatial_index()
	for _frame in 4:
		await physics_frame
	var spawn: Vector3 = report.get("spawnpoint", Vector3.ZERO)
	print("spawn ", spawn)
	# Desglose con las metricas que el mundo ya publica, para no adivinar donde se va el tiempo.
	print("%-22s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %7s %5s %6s %6s" % [
		"disparo", "total", "busq", "consul", "conect", "raices", "fill", "extern",
		"contact", "fragm", "detach", "cuerpo", "calls", "macro", "vox"])
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var worst := 0.0
	for shot in 12:
		var center := spawn + Vector3(
			rng.randf_range(-30.0, 30.0), rng.randf_range(0.0, 8.0), rng.randf_range(-30.0, 30.0)
		)
		var started := Time.get_ticks_usec()
		var affected := world.damage_sphere(center, 1.0, 20.0)
		var total := (Time.get_ticks_usec() - started) / 1000.0
		worst = maxf(worst, total)
		var removed := 0
		for entry: Dictionary in affected:
			removed += int((entry.damage as Dictionary).get("removed", 0))
		print("%-22s %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f %5d %6d %6d" % [
			"(%.0f, %.0f, %.0f)" % [center.x, center.y, center.z], total,
			world.support_search_ms, world.damage_query_ms, world.damage_connectivity_ms,
			world.damage_external_support_ms, world.damage_component_fill_ms,
			world.damage_support_routes_ms, world.damage_support_contacts_ms,
			world.damage_fragment_ms,
			world.damage_detach_ms, world.damage_body_ms,
			world.damage_component_contact_calls,
			world.connectivity_macros_visited, world.connectivity_voxels_materialized])
		for _frame in 3:
			await physics_frame
	print("\npeor disparo %.2f ms  (presupuesto a 60 fps: 16,7 ms)" % worst)
	quit()
