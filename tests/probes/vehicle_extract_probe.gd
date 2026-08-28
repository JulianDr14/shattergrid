extends SceneTree
## Que `TeardownMapImporter.load_named_shape` saca los tres vehiculos de prueba (coche pequeño, SUV,
## muscle car) del .vox compartido del mapa real, con voxeles de verdad y sin tocar el flujo de
## importacion completo.
var VOX_DIR := VoxelProjectPaths.teardown_vox_dir()


func _init() -> void:
	for triple in [
		["coche pequeño", "palette22.vox", "shape473"],
		["suv", "palette24.vox", "shape500"],
		["muscle car", "palette25.vox", "shape527"],
	]:
		var shape := TeardownMapImporter.load_named_shape(VOX_DIR + triple[1], triple[2])
		if shape == null:
			printerr("FALLO  %s (%s): no encontrado" % [triple[0], triple[2]])
			continue
		var bounds := shape.local_bounds()
		print("ok     %-14s %-10s voxeles=%d  tamaño=%.2f x %.2f x %.2f m" % [
			triple[0], triple[2], shape.voxel_count(),
			bounds.size.x, bounds.size.y, bounds.size.z])
	quit(0)
