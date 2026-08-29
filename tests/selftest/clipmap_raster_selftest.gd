extends SceneTree
## Comprueba el rasterizador de la clipmap en C++ contra el bucle en GDScript que sustituye, y mide
## lo que tarda el mapa entero.
##
## El nivel fino tiene que dar el bit a bit exacto. Los niveles gruesos van por macrocelda y son
## conservadores a propósito — marcan de más, nunca de menos — así que ahí se exige superconjunto.

var XML := VoxelProjectPaths.teardown_map_path()
## Rejilla pequeña para la comparación: contar bits de los 16 MB de la rejilla real desde GDScript
## tarda más que todo lo que se está midiendo. Se ejercitan los mismos caminos de código.
const LOGICAL := 64
const PACKED := 32
const FULL_LOGICAL := 512
const FULL_PACKED := 256
const BASE_CELL := 0.1


func _initialize() -> void:
	# SceneTree todavía no ha entrado al árbol durante `_initialize`. Importar ahí hacía que las
	# consultas de transform global y el sueño inicial de los props escribieran miles de errores sin
	# que el test fallara. El diferido ejercita el mismo importador en su estado runtime real.
	_run.call_deferred()


func _run() -> void:
	var world: VoxelWorld3D = VoxelWorld3D.new()
	root.add_child(world)

	print("--- correctitud, recorte de 25 m ---")
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 25.0, Vector3.ZERO, false)
	assert(world.physics_budget != null, "el importador debe inicializar su presupuesto antes de _ready")
	var group := _collect(world)
	print("shapes=%d voxeles=%d" % [group.shapes.size(), _count_voxels(group)])
	# Una Shape entra por la vía de macroceldas cuando la celda del nivel cubre sus 8 voxeles. Con
	# celda de 10 cm eso son las Shapes de voxel <= 1,25 cm, que en Teardown existen: `scale` en el
	# XML es el tamaño de voxel por diez.
	var tiny := 0
	for size in group.voxel_sizes:
		if size <= BASE_CELL / 8.0:
			tiny += 1
	print("shapes con voxel <= 1,25 cm (van por macrocelda ya en el nivel 0): %d" % tiny)
	# Origen centrado en la geometría para que el nivel 0 no salga vacío.
	var origin := Vector3i(-LOGICAL / 2, -LOGICAL / 2, -LOGICAL / 2)
	for level in 4:
		var cell: float = BASE_CELL * float(1 << level)
		var fast: PackedByteArray = VoxelShapeData.rasterize_occupancy_level(
			group.shapes, group.transforms, group.voxel_sizes,
			origin, Vector3i.ONE * LOGICAL, cell, Vector3i.ONE * PACKED
		)
		var reference := _reference(group, origin, cell)
		var missing := 0
		var extra := 0
		var reference_bits := 0
		for index in reference.size():
			var a: int = reference[index]
			var b: int = fast[index]
			reference_bits += _popcount(a)
			missing += _popcount(a & ~b)
			extra += _popcount(b & ~a)
		# El invariante que importa para una sombra es no perder ocluyentes. Marcar de más solo
		# engorda la sombra; marcar de menos deja pasar luz por dentro de una pared.
		assert(missing == 0, "el nivel %d pierde %d celdas" % [level, missing])
		print("nivel %d celda=%.1f cm  referencia=%d  faltan=%d  sobran=%d (+%.1f %%)" % [
			level, cell * 100.0, reference_bits, missing, extra,
			100.0 * extra / maxf(reference_bits, 1.0),
		])
		if level == 0 and tiny == 0:
			assert(fast == reference, "sin Shapes diminutas el nivel 0 debe salir idéntico")

	print("--- velocidad, mapa entero ---")
	# No se reutiliza el World: sus indices espaciales y caches conservan referencias a los Bodies
	# registrados, como deben hacerlo durante una partida. Liberar solo los hijos creaba referencias
	# muertas artificiales y ocultaba los resultados bajo errores de cast.
	world.free()
	world = VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 1.0e9, Vector3.ZERO, false)
	var full := _collect(world)
	var voxels := _count_voxels(full)
	var started := Time.get_ticks_usec()
	for level in 4:
		VoxelShapeData.rasterize_occupancy_level(
			full.shapes, full.transforms, full.voxel_sizes,
			Vector3i.ONE * (-FULL_LOGICAL / 2), Vector3i.ONE * FULL_LOGICAL,
			BASE_CELL * float(1 << level), Vector3i.ONE * FULL_PACKED
		)
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	print("shapes=%d voxeles=%d  4 niveles en %.0f ms" % [full.shapes.size(), voxels, elapsed])
	print("antes en GDScript: 201000 ms  ->  %.0fx" % (201000.0 / maxf(elapsed, 1.0)))
	assert(elapsed < 3000.0, "sigue costando demasiado para encenderlo por defecto")
	print("OK")
	quit()


## Se compone a mano para que el raster use explícitamente la transformada de Body y Shape.
func _collect(world: VoxelWorld3D) -> Dictionary:
	var group := {"shapes": [], "transforms": [], "voxel_sizes": PackedFloat32Array()}
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				if shape.voxel_count() == 0:
					continue
				group.shapes.append(shape.data)
				group.transforms.append((body as Node3D).transform * shape.transform)
				group.voxel_sizes.append(shape.voxel_size)
	return group


func _count_voxels(group: Dictionary) -> int:
	var total := 0
	for data: VoxelShapeData in group.shapes:
		total += data.get_occupied_count()
	return total


## El bucle que había en `_rasterize_shape_level`, tal cual, como referencia.
func _reference(group: Dictionary, origin: Vector3i, cell_size: float) -> PackedByteArray:
	var target := PackedByteArray()
	target.resize(PACKED * PACKED * PACKED)
	for shape_index in group.shapes.size():
		var data: VoxelShapeData = group.shapes[shape_index]
		var transform: Transform3D = group.transforms[shape_index]
		var voxel_size: float = group.voxel_sizes[shape_index]
		var dimensions := data.get_dimensions()
		var plane := dimensions.x * dimensions.y
		for index in data.get_live_indices():
			var z := index / plane
			var rest := index - z * plane
			var y := rest / dimensions.x
			var x := rest - y * dimensions.x
			var local := (Vector3(x + 0.5, y + 0.5, z + 0.5) - Vector3(dimensions) * 0.5) \
				* voxel_size
			var world: Vector3 = transform * local
			var world_cell := Vector3i(
				floori(world.x / cell_size), floori(world.y / cell_size), floori(world.z / cell_size)
			)
			var logical := world_cell - origin
			if logical.x < 0 or logical.y < 0 or logical.z < 0 \
				or logical.x >= LOGICAL or logical.y >= LOGICAL or logical.z >= LOGICAL:
				continue
			var packed := logical / 2
			var bit := (logical.x & 1) | ((logical.y & 1) << 1) | ((logical.z & 1) << 2)
			target[packed.x + packed.y * PACKED + packed.z * PACKED * PACKED] |= 1 << bit
	return target


func _popcount(value: int) -> int:
	var total := 0
	while value != 0:
		total += value & 1
		value >>= 1
	return total
