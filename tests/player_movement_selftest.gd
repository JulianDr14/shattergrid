extends SceneTree

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


static func _box(parent: Node3D, position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)
	body.position = position


func _run() -> void:
	print("movimiento: recuperación, snap y escaleras")
	var level := Node3D.new()
	root.add_child(level)
	_box(level, Vector3(0.0, -0.1, 0.0), Vector3(12.0, 0.2, 12.0))
	# Four 20 cm voxel risers. The last box continues as a landing so floor snap also has a stable
	# surface after the ascent.
	for step in 4:
		var top := 0.2 * float(step + 1)
		var depth := 0.65 if step < 3 else 3.0
		var center_z := 0.95 - float(step) * 0.65
		if step == 3:
			center_z -= 1.15
		_box(level, Vector3(0.0, top * 0.5, center_z), Vector3(2.2, top, depth))

	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/player.gd"))
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	player.add_child(collision)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.position.y = 1.65
	player.add_child(camera)
	level.add_child(player)
	player.position = Vector3(0.0, 0.03, 2.0)

	for _frame in 8:
		await physics_frame
	Input.action_press("move_forward")
	var body_jump := 0.0
	var view_jump := 0.0
	var max_horizontal_step := 0.0
	var previous_body := player.global_position.y
	var previous_view := camera.global_position.y
	var previous_horizontal := Vector2(player.global_position.x, player.global_position.z)
	for _frame in 45:
		await physics_frame
		body_jump = maxf(body_jump, absf(player.global_position.y - previous_body))
		view_jump = maxf(view_jump, absf(camera.global_position.y - previous_view))
		previous_body = player.global_position.y
		previous_view = camera.global_position.y
		var horizontal := Vector2(player.global_position.x, player.global_position.z)
		max_horizontal_step = maxf(max_horizontal_step, horizontal.distance_to(previous_horizontal))
		previous_horizontal = horizontal
	Input.action_release("move_forward")
	print("  posición final ", player.position)
	_check(player.position.z < -0.65, "el controlador supera una escalera voxel de cuatro peldaños")
	_check(player.position.y > 0.68, "termina sobre el rellano y no empotrado en el suelo")
	# `safe_margin` es diminuto a proposito: ver el comentario de `_ready` en `player.gd`.
	_check(player.floor_snap_length >= 0.3 and player.safe_margin <= 0.01,
		"floor snap activo y margen diminuto para la sonda de escalon")
	print("  avance horizontal máximo por frame %.3f m" % max_horizontal_step)
	_check(max_horizontal_step <= 0.11,
		"la sonda de peldaño no añade distancia ni aceleración al movimiento")
	print("  salto por frame  cuerpo %.3f  vista %.3f" % [body_jump, view_jump])
	_check(body_jump > 0.1, "el cuerpo sube el peldaño de golpe, como debe")
	_check(view_jump < body_jump * 0.6, "la vista reparte ese peldaño en varios frames")

	if failures == 0:
		print("VOXEL_PLAYER_MOVEMENT_SELFTEST_OK")
	else:
		printerr("VOXEL_PLAYER_MOVEMENT_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
