extends "res://tests/selftest/selftest.gd"
## Igual que `vehicle_extract_probe.gd` pero sobre el flujo completo: Shape -> VoxelBody3D dinamico
## registrado en un VoxelWorld3D real, cayendo por gravedad. Es lo que hace `--teardown-vehicles` en
## main.gd para las pruebas de fisica.
var VOX_DIR := VoxelProjectPaths.teardown_vox_dir()


func _run() -> void:
	print("vehiculos extraidos del mapa como cuerpos de prueba")
	var world := make_world()

	var floor_shape := VoxelShape3D.new()
	floor_shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(60, 4, 60)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	floor_shape.data.set_cells(dimensions, cells)
	floor_shape.palette = VoxelPalette.new()
	floor_shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 1000000.0, "density": 2700.0})
	floor_shape.anchored = false
	var ground := VoxelBody3D.new()
	world.add_child(ground)
	ground.add_voxel_shape(floor_shape)
	world.register_body(ground)

	var vehicles := [
		["coche pequeño", "palette22.vox", "shape473", 1.5],
		["suv", "palette24.vox", "shape500", 2.0],
		["muscle car", "palette25.vox", "shape527", 2.0],
	]
	var bodies: Array[VoxelBody3D] = []
	var offset := 0
	for entry in vehicles:
		var shape := TeardownMapImporter.load_named_shape(
			VOX_DIR + entry[1], entry[2], float(entry[3])
		)
		_check(shape != null and shape.voxel_count() > 500,
			"%s decodifica con voxeles de verdad" % entry[0])
		if shape == null:
			continue
		var body := VoxelBody3D.new()
		body.state = VoxelBody3D.State.DYNAMIC
		world.add_child(body)
		body.add_voxel_shape(shape)
		body.global_position = Vector3(float(offset) * 6.0, 6.0, 0.0)
		world.register_body(body)
		body.wake_for_interaction()
		bodies.append(body)
		offset += 1
	_check(bodies.size() == 3, "los tres cuerpos se registraron")
	var expected_masses := [846.7, 1532.9, 1820.0]
	for index in bodies.size():
		var measured := (bodies[index].get_physics_body() as RigidBody3D).mass
		print("  masa %s: %.1f kg" % [vehicles[index][0], measured])
		_check(absf(measured - expected_masses[index]) < expected_masses[index] * 0.02,
			"%s conserva una masa vehicular plausible" % vehicles[index][0])

	var before: Array[float] = []
	for body in bodies:
		before.append(body.get_physics_body().global_position.y)
	for _frame in 90:
		await physics_frame
	var landed := 0
	for index in bodies.size():
		var fell := before[index] - bodies[index].get_physics_body().global_position.y
		if fell > 1.0:
			landed += 1
	print("  cayeron %d de %d" % [landed, bodies.size()])
	_check(landed == bodies.size(), "y los tres caen sobre el suelo, como cuerpos dinamicos normales")

	if failures == 0:
		print("VOXEL_VEHICLE_EXTRACT_SELFTEST_OK")
	else:
		printerr("VOXEL_VEHICLE_EXTRACT_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
