extends SceneTree
## Por que el juego va a tirones con la GPU al 10 %: cuanto cuesta un frame en CPU con el mapa
## entero cargado y el jugador andando. Mide el _process de la clipmap de sombras, que es lo unico
## que reacciona al movimiento de la camara.

var XML := VoxelProjectPaths.teardown_map_path()
const FRAMES := 30
const SPEED := 5.5


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	var started := Time.get_ticks_msec()
	var report: Dictionary = TeardownMapImporter.import_map(
		world, XML, Vector3.INF, INF, Vector3.ZERO, true
	)
	print("importar %d ms" % (Time.get_ticks_msec() - started))

	var camera := Camera3D.new()
	root.add_child(camera)
	camera.global_position = report.get("drop_in", Vector3.ZERO)

	var clipmaps := VoxelShadowClipmaps.new()
	root.add_child(clipmaps)
	started = Time.get_ticks_msec()
	if not clipmaps.setup(world, camera):
		print("sin RenderingDevice: no se puede medir")
		quit()
		return
	print("clipmap inicial %d ms" % (Time.get_ticks_msec() - started))

	var shapes_started := Time.get_ticks_usec()
	var shapes: Array = clipmaps.call("_all_shapes")
	var shapes_ms := (Time.get_ticks_usec() - shapes_started) / 1000.0
	print("_all_shapes(): %d shapes en %.2f ms" % [shapes.size(), shapes_ms])

	var total := 0.0
	var worst := 0.0
	for frame in FRAMES:
		camera.global_position += Vector3.FORWARD * SPEED / 60.0
		var frame_started := Time.get_ticks_usec()
		clipmaps._process(1.0 / 60.0)
		var frame_ms := (Time.get_ticks_usec() - frame_started) / 1000.0
		total += frame_ms
		worst = maxf(worst, frame_ms)
	print("clipmap por frame andando: media %.1f ms  peor %.1f ms  -> %.0f fps de techo"
		% [total / FRAMES, worst, 1000.0 / maxf(total / FRAMES, 0.001)])
	quit()
