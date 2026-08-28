extends SceneTree
## Un cuerpo que se vuelve dinamico DESPUES de registrarse -una torre que pierde su apoyo, un tramo
## de tuberia que se suelta- tiene que entrar en la lista de Shapes que el render vigila cada frame.
##
## Cuando no entraba, el cuerpo caia de verdad pero su transformada no volvia a subir a la GPU:
## quedaba un fantasma de pie en el sitio de antes, atravesable e indestructible, mientras los
## voxeles reales ya estaban en el suelo. La sombra si se movia, que era la pista.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _run() -> void:
	print("Shapes que el render vigila")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	world.renderer_settings = VoxelRendererSettings.new()
	world.renderer_settings.sun_shadows_enabled = false
	root.add_child(world)

	# Lejos del origen, que es donde vivian los postes y la torre del mapa.
	var tower := VoxelBody3D.new()
	world.add_child(tower)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(4, 20, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(1)
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": 0.4, "density": 400.0})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(-3.9, 14.7, 70.9))
	tower.add_voxel_shape(shape)
	world.register_body(tower)
	await physics_frame
	var camera := Camera3D.new()
	root.add_child(camera)
	var render := VoxelRenderSystem.new()
	root.add_child(render)
	var renderer_ready := RenderingServer.get_rendering_device() != null
	if renderer_ready:
		renderer_ready = render.setup(world, camera)
		_check(renderer_ready, "el renderer real acepta la Shape")
	else:
		render.world = world
		print("  omite pose GPU: --headless no crea RenderingDevice")
	await process_frame

	_check(render.movable_shapes().is_empty(), "una Shape estatica no se vigila")

	var before := shape.global_transform.origin
	tower.make_dynamic()
	await physics_frame
	_check(render.movable_shapes().has(shape), "al volverse dinamica, si")

	for _frame in 30:
		await physics_frame
		await process_frame
	# Ejecuta el muestreo una última vez antes de comparar las tres etapas de la pose.
	if renderer_ready:
		render._process(0.0)
	var fell := before.y - shape.global_transform.origin.y
	print("  cayo %.2f m" % fell)
	_check(fell > 0.5, "y se mueve de verdad, asi que el render tenia que enterarse")
	if renderer_ready:
		var pose := render.get_shape_pose_snapshot(shape)
		print("  error pose scene=%.4f m effect=%.4f m" % [
			float(pose.get("scene_error_m", INF)), float(pose.get("effect_error_m", INF)),
		])
		_check(bool(pose.get("valid", false)) and float(pose.scene_error_m) < 0.02,
			"la pose seguida coincide con la transformada interpolada de Jolt")
		_check(float(pose.get("effect_error_m", INF)) < 0.001,
			"la hoja del compositor recibe esa misma pose, no conserva el poste de pie")
		# El espejo cambia síncronamente; el callback POST_OPAQUE consume ese batch al renderizar el
		# frame siguiente. Se mide aparte porque el cuerpo puede avanzar otro tick durante la espera.
		await process_frame
		var delivered := render.get_shape_pose_snapshot(shape)
		_check(int(delivered.get("pending_gpu_updates", -1)) == 0,
			"el callback de render consume la actualización antes de declarar coherencia")
		# Fuerza la transición awake -> sleeping. El frame de gracia debe sellar la pose canónica y no
		# dejar como final una muestra interpolada anterior.
		var rigid := tower.get_physics_body() as RigidBody3D
		rigid.freeze = true
		rigid.sleeping = true
		tower.runtime_state_changed.emit(tower)
		for _frame in 3:
			await physics_frame
			await process_frame
		render._process(0.0)
		var settled := render.get_shape_pose_snapshot(shape)
		print("  reposo sleeping=%s canonical_error=%.4f m tracked=%s" % [
			rigid.sleeping, float(settled.get("canonical_error_m", INF)),
			str(world.get_transform_tracked_body_ids()),
		])
		_check(float(settled.get("canonical_error_m", INF)) < 0.02,
			"al dormir sella la pose canónica final en vez de una interpolación vieja")
		_check(int(settled.get("pending_gpu_updates", -1)) == 0,
			"la pose final también queda drenada hacia Vulkan")

	if failures == 0:
		print("VOXEL_MOVING_SHAPES_SELFTEST_OK")
	else:
		printerr("VOXEL_MOVING_SHAPES_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
