extends SceneTree
## Busca láminas: Shapes grandes en planta y de muy pocos voxeles de grosor.
##
## El síntoma es una superficie oscura que se ve por una cara, no por la otra, y que colisiona. Eso
## es geometría plana, no una sombra. Aquí salen con su posición, su grosor real y el color que les
## toca en la paleta, para poder cruzarlas con lo que se ve en pantalla.

var MAP := VoxelProjectPaths.teardown_map_path()


func _init() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)

	var laminas: Array[Dictionary] = []
	for body in world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			var cells := shape.data.get_dimensions()
			var thin := mini(cells.x, mini(cells.y, cells.z))
			if thin > 4:
				continue
			var size := Vector3(cells) * shape.voxel_size
			var bounds := (body as Node3D).transform * shape.transform * AABB(-size * 0.5, size)
			var area := maxf(bounds.size.x * bounds.size.z,
				maxf(bounds.size.x * bounds.size.y, bounds.size.y * bounds.size.z))
			if area < 60.0:
				continue
			laminas.append({
				"body": body.name,
				"area": area,
				"grosor": thin,
				"celdas": cells,
				"centro": bounds.get_center(),
				"tamano": bounds.size,
				"colisiona": (body as VoxelBody3D).collision_enabled,
				"color": _dominant_color(shape),
			})
	laminas.sort_custom(func(a, b): return a.area > b.area)
	print("LAMINAS=%d" % laminas.size())
	for entry in laminas.slice(0, 20):
		print("  %-16s area=%7.0f  grosor=%d vox  tam=%5.1f x %5.1f x %5.1f  centro=%s  color=%s  colisiona=%s"
			% [entry.body, entry.area, entry.grosor, entry.tamano.x, entry.tamano.y,
				entry.tamano.z, str(entry.centro), entry.color, entry.colisiona])
	quit(0)


func _dominant_color(shape: VoxelShape3D) -> String:
	var counts := {}
	var size := shape.data.get_dimensions()
	# Muestreo: recorrer entera una lámina de decenas de metros no aporta nada al color dominante.
	for z in range(0, size.z, maxi(1, size.z / 16)):
		for y in range(0, size.y, maxi(1, size.y / 16)):
			for x in range(0, size.x, maxi(1, size.x / 16)):
				var index := shape.data.get_cell(x, y, z)
				if index != 0:
					counts[index] = int(counts.get(index, 0)) + 1
	if counts.is_empty():
		return "vacia"
	var best := 0
	var best_count := 0
	for index: int in counts:
		if counts[index] > best_count:
			best_count = counts[index]
			best = index
	var material: Dictionary = shape.palette.get_material(best)
	var color: Color = material.get("color", Color.MAGENTA)
	var imap: PackedByteArray = shape.palette.get_meta("imap", PackedByteArray())
	return "#%s %s" % [color.to_html(false), TeardownPalette.material_name(best, imap)]
