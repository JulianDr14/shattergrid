extends SceneTree
## Regresión de gameplay: entrada de un RigidBody, flotación/drag y jugador retenido en superficie.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _make_water(parent: Node) -> VoxelWaterSystem:
	var water := VoxelWaterSystem.new()
	parent.add_child(water)
	water.add_polygon(PackedVector3Array([
		Vector3(-10, 0, -10), Vector3(10, 0, -10),
		Vector3(10, 0, 10), Vector3(-10, 0, 10),
	]), Color(0.02, 0.08, 0.1), 3.0, 1.0, 10.0, 1.0)
	water.finish()
	return water


func _make_prop(world: VoxelWorld3D) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.DYNAMIC
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(6 * 6 * 6)
	cells.fill(1)
	shape.data.set_cells(Vector3i(6, 6, 6), cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.BROWN, "hardness": 1.0, "density": 700.0,
	})
	shape.physical_fill_scale = 0.025
	shape.anchored = false
	shape.position = Vector3(0, 3.0, 0)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("interacción con agua")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var water := _make_water(world)
	water.setup(world)
	var prop := _make_prop(world)
	var rigid := prop.get_physics_body() as RigidBody3D
	rigid.sleeping = false
	var minimum_y := INF
	for _frame in 240:
		await physics_frame
		minimum_y = minf(minimum_y, prop.get_shapes()[0].world_bounds().get_center().y)
	_check(water.splash_count >= 1, "un objeto que entra genera splash y onda")
	_check(minimum_y > -4.0 and rigid.linear_velocity.length() < 4.0,
		"flotación y drag frenan el objeto dentro del volumen")

	# El jugador empieza sumergido y cayendo. Sin natación estaría a -6 m tras un segundo; el
	# controlador lo lleva al objetivo de superficie (origen ≈ -1,15 m, cámara fuera del agua).
	var player := CharacterBody3D.new()
	player.name = "PlayerSwimProbe"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 1.65, 0)
	player.add_child(camera)
	player.set_script(load("res://scripts/player.gd"))
	root.add_child(player)
	player.global_position = Vector3(4.0, -1.0, 0.0)
	player.velocity = Vector3(0.0, -5.0, 0.0)
	var splashes_before := water.splash_count
	for _frame in 90:
		await physics_frame
	_check(player.global_position.y > -1.8,
		"el jugador permanece nadando cerca de la superficie")
	_check(water.splash_count > splashes_before,
		"la entrada del jugador también genera feedback de agua")

	if failures == 0:
		print("VOXEL_WATER_INTERACTION_SELFTEST_OK")
	else:
		printerr("VOXEL_WATER_INTERACTION_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
