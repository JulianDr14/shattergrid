extends SceneTree
## Que cuestan los cables de Lee: parados (que es como estan casi siempre) y con todos despiertos a
## la vez, que es el peor caso imaginable y no ocurre nunca.
var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)
	var started := Time.get_ticks_usec()
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)
	var import_ms := (Time.get_ticks_usec() - started) / 1000.0
	var ropes := world.get_node_or_null("TeardownRopes") as VoxelRopes
	if ropes == null:
		print("sin cables")
		quit(1)
		return
	print("%d tramos, importados con el mapa en %.0f ms" % [ropes.span_count(), import_ms])

	# Parados: lo unico que corre es el `if` que comprueba que no hay nada despierto.
	for _frame in 10:
		await physics_frame
	print("despiertos en reposo: %d" % ropes.awake_count())
	var quiet := Time.get_ticks_usec()
	for _step in 600:
		ropes._physics_process(1.0 / 60.0)
	print("  parados      %.4f ms por frame" % ((Time.get_ticks_usec() - quiet) / 1000.0 / 600.0))

	# Peor caso: los 79 tramos vivos, simulando y reconstruyendo la malla cada frame.
	# Empujados de verdad: marcarlos despiertos sin moverlos los dormia a los 20 frames y la medida
	# salia falsa (mas barata que el caso real de cuatro cables oscilando).
	ropes.force_all_awake_for_probe(Vector3(0.0, 0.0, 0.02))
	var busy := Time.get_ticks_usec()
	for _step in 120:
		ropes._physics_process(1.0 / 60.0)
	print("  todos vivos  %.4f ms por frame  (%d puntos, %d iteraciones)" % [
		(Time.get_ticks_usec() - busy) / 1000.0 / 120.0,
		ropes.span_count() * (VoxelRopes.SEGMENTS + 1), VoxelRopes.ITERATIONS])

	# Y lo que de verdad pasa: una explosion en medio del mapa.
	ropes.sleep_all_for_probe()
	var spawn := Vector3(-64.4, 3.0, -81.0)
	ropes.on_impact(spawn, 1.0)
	print("  una explosion despierta %d de %d tramos" % [ropes.awake_count(), ropes.span_count()])
	var shot := Time.get_ticks_usec()
	for _step in 60:
		ropes._physics_process(1.0 / 60.0)
	print("  tras el disparo %.4f ms por frame" % ((Time.get_ticks_usec() - shot) / 1000.0 / 60.0))
	quit()
