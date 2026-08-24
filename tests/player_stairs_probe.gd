extends SceneTree
## Sube al jugador por escaleras de distintos peldanos y comprueba que no trepa muros.
##
## El mapa de Teardown esta a 10 cm por voxel, asi que un peldano real son 1, 2 o 3 voxeles. Si el
## controlador no sube 20 cm no sube ninguna escalera del mapa, que es justo lo que pasaba. Tambien
## comprueba que la camara tiene el mismo campo de vision que Teardown: 90 grados horizontales.

const TREAD := 0.3
const STEPS := 10
const SECONDS := 3.0


func _initialize() -> void:
	_run()


func _run() -> void:
	var results := []
	for riser: float in [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.45, 2.0]:
		results.append(await _climb(riser))
	_check_fov()
	print("peldano  esperado  alcanzado  veredicto")
	for row: Dictionary in results:
		var ok: bool = row.reached < 0.2 if row.riser >= 1.0 \
			else row.reached >= row.expected - 0.05
		print("%5.0f cm  %7.2f m  %8.2f m  %s" % [
			row.riser * 100.0, row.expected, row.reached,
			"OK" if ok else ("TREPA MUROS" if row.riser >= 1.0 else "FALLA")
		])
		assert(ok, "peldano de %.0f cm" % (row.riser * 100.0))
	print("OK")
	quit()


## Teardown usa 90 grados HORIZONTALES. Godot por defecto interpreta `fov` como vertical, y 75
## verticales en 16:9 son 107 horizontales — mucho mas ancho de lo que se ve en Teardown. Con
## `keep_aspect = KEEP_WIDTH` el numero pasa a ser el horizontal, igual que en el juego.
func _check_fov() -> void:
	var scene: PackedScene = load("res://main.tscn")
	var state := scene.get_state()
	var found := false
	for i in state.get_node_count():
		if state.get_node_name(i) != "Camera3D":
			continue
		var properties := {}
		for p in state.get_node_property_count(i):
			properties[state.get_node_property_name(i, p)] = state.get_node_property_value(i, p)
		found = true
		assert(properties.get("fov", 75.0) == 90.0, "el fov no es 90")
		assert(properties.get("keep_aspect", 1) == Camera3D.KEEP_WIDTH,
			"con KEEP_HEIGHT el fov seria vertical y saldrian 107 grados horizontales")
		print("camara: fov=%.0f horizontal (Teardown: 90)" % properties.fov)
	assert(found, "no se encontro la camara en main.tscn")


func _climb(riser: float) -> Dictionary:
	var world := Node3D.new()
	root.add_child(world)
	var stairs := StaticBody3D.new()
	world.add_child(stairs)
	# Suelo generoso mas la escalera, cada peldano un cajon macizo hasta el suelo.
	var ground := CollisionShape3D.new()
	var ground_box := BoxShape3D.new()
	ground_box.size = Vector3(20.0, 1.0, 20.0)
	ground.shape = ground_box
	ground.position = Vector3(0.0, -0.5, 0.0)
	stairs.add_child(ground)
	for i in STEPS:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var height := riser * (i + 1)
		box.size = Vector3(4.0, height, TREAD)
		shape.shape = box
		shape.position = Vector3(0.0, height * 0.5, -1.0 - TREAD * i)
		stairs.add_child(shape)

	var player: CharacterBody3D = load("res://scripts/player.gd").new()
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	collision.position = Vector3(0.0, 0.9, 0.0)
	player.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0.0, 1.65, 0.0)
	player.add_child(camera)
	world.add_child(player)
	player.global_position = Vector3(0.0, 0.1, 0.5)

	Input.action_press("move_forward")
	var highest := 0.0
	for frame in int(SECONDS * 60.0):
		await physics_frame
		highest = maxf(highest, player.global_position.y)
	Input.action_release("move_forward")
	var result := {"riser": riser, "expected": riser * STEPS, "reached": highest}
	world.queue_free()
	await physics_frame
	return result
