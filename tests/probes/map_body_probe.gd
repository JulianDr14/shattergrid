extends SceneTree
## Describe los cuerpos que rodean un punto del mapa y compara su volumen visible con su colisión.
##
## Cuando el HUD acusa a un cuerpo concreto de frenar al jugador, esto dice qué es realmente: dónde
## está, cuánto ocupa, cuántos voxeles tiene dentro y si su caja de colisión coincide con lo que se
## dibuja. Un cuerpo casi vacío con una caja grande es exactamente el "muro invisible".

var MAP := VoxelProjectPaths.teardown_map_path()
const PUNTO := Vector3(-5.2, 1.2, -2.7)
const RADIO := 8.0


func _init() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, MAP, Vector3.INF, 1.0e9, Vector3.ZERO, true)

	for body in world.get_children():
		if not (body is VoxelBody3D):
			continue
		var total := AABB()
		var primero := true
		var voxeles := 0
		var celdas := 0
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			var size := Vector3(shape.data.get_dimensions()) * shape.voxel_size
			var bounds := (body as Node3D).transform * shape.transform * AABB(-size * 0.5, size)
			total = bounds if primero else total.merge(bounds)
			primero = false
			voxeles += shape.data.get_occupied_count()
			var cells := shape.data.get_dimensions()
			celdas += cells.x * cells.y * cells.z
		if primero or not total.grow(RADIO).has_point(PUNTO):
			continue
		print("%-16s  tam=%5.1f x %5.1f x %5.1f  centro=%s  y=[%.1f .. %.1f]  llenado=%.1f%%  colisiona=%s  estado=%d"
			% [body.name, total.size.x, total.size.y, total.size.z, str(total.get_center()),
				total.position.y, total.end.y, 100.0 * voxeles / maxi(1, celdas),
				(body as VoxelBody3D).collision_enabled, (body as VoxelBody3D).state])
	quit(0)
