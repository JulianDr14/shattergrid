extends SceneTree
## Importa el mapa entero sin recorte y dice qué se pierde por el camino y si el atlas lo aguanta.
##
## Sirve para separar dos causas que se ven igual en pantalla: que el importador descarte Shapes
## (radio, presupuesto de celdas) o que el atlas de bricks se quede sin sitio y el renderer no las
## coloque. Sin colisión, que es el 96 % del tiempo y aquí no aporta nada.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	var started := Time.get_ticks_msec()
	var report := TeardownMapImporter.import_map(
		world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true
	)
	print("IMPORT_MS ", Time.get_ticks_msec() - started)
	print("REPORT ", JSON.stringify(report))

	# El decorado atravesable de Teardown tiene que llegar a Jolt con la colisión apagada de verdad:
	# si se cuela, son paredes invisibles repartidas por el mapa.
	var sin_colision := 0
	var cables := 0
	for node in world.get_children():
		if node is VoxelBody3D and not (node as VoxelBody3D).collision_enabled:
			# Las cuatro ruedas visuales de un coche comparten ahora un Body sin colisión. La métrica
			# del importador siempre contó Shapes, no Bodies, así que se compara la misma unidad.
			sin_colision += (node as VoxelBody3D).get_shapes().size()
		elif node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			cables += (node as MeshInstance3D).mesh.get_surface_count()
	assert(sin_colision == int(report.no_collide),
		"Shapes sin colisión %d != no_collide %d" % [sin_colision, report.no_collide])
	assert(int(report.ropes) == 0 or world.get_node_or_null("TeardownRopes") is VoxelRopes,
		"los cables no llegaron a la escena")
	assert(int(report.skipped_far) == 0 and int(report.skipped_budget) == 0,
		"el importador está descartando Shapes")
	print("CHECKS ok sin_colision=%d cables=%d" % [sin_colision, report.ropes])

	var shapes := 0
	var bricks := 0
	var macros := 0
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
				shapes += 1
				bricks += shape.data.get_occupied_macros().size()
				var macro := shape.data.get_macro_dimensions()
				macros += macro.x * macro.y * macro.z
	var per_layer := VoxelRenderSystem.BRICK_GRID_SIDE * VoxelRenderSystem.BRICK_GRID_SIDE
	var layers := (bricks * VoxelRenderSystem.BRICK_HEADROOM / 10 + per_layer - 1) / per_layer
	var cap := VoxelRenderSystem.MAX_ATLAS_DEPTH / 8
	print("ATLAS shapes=%d bricks=%d macroceldas=%d capas=%d tope=%d mb=%.1f"
		% [shapes, bricks, macros, layers, cap,
			per_layer * mini(layers, cap) * 512.0 / 1048576.0])

	# El empaquetado del atlas de macroceldas es CPU pura, así que se puede repetir aquí sin GPU. Lo
	# que no entra deja de dibujarse pero conserva su collider: es la firma de un "muro invisible".
	print("PACKER ", JSON.stringify(_simulate_packer(world)))
	quit(0)


func _simulate_packer(world: VoxelWorld3D) -> Dictionary:
	var sizes: Array[Vector3i] = []
	var max_x := 1
	var max_y := 1
	var volume := 0
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
				var macro := shape.data.get_macro_dimensions()
				sizes.append(macro)
				max_x = maxi(max_x, macro.x)
				max_y = maxi(max_y, macro.y)
				volume += macro.x * macro.y * macro.z
	var atlas := VoxelRenderSystem._plan_atlas(
		max_x, max_y, volume * 4, VoxelRenderSystem.MAX_MACRO_ATLAS_CELLS, 512
	)
	var cursor := Vector3i.ZERO
	var shelf := 0
	var layer := 0
	var dropped := 0
	for size in sizes:
		if cursor.x + size.x > atlas.x:
			cursor = Vector3i(0, cursor.y + shelf, cursor.z)
			shelf = 0
		if cursor.y + size.y > atlas.y:
			cursor = Vector3i(0, 0, cursor.z + layer)
			layer = 0
		if cursor.z + size.z > atlas.z or cursor.x + size.x > atlas.x \
				or cursor.y + size.y > atlas.y:
			dropped += 1
			continue
		shelf = maxi(shelf, size.y)
		layer = maxi(layer, size.z)
		cursor = Vector3i(cursor.x + size.x, cursor.y, cursor.z)
	return {
		"atlas": "%dx%dx%d" % [atlas.x, atlas.y, atlas.z],
		"celdas": atlas.x * atlas.y * atlas.z,
		"volumen_util": volume,
		"shapes": sizes.size(),
		"invisibles_con_collider": dropped,
	}
