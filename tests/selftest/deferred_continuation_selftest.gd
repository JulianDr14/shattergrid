extends SceneTree
## Regresión del techo suspendido: la continuación toca el cuarto componente, que necesariamente
## pasa por la cola de fragmentos. Antes esa cola creaba el RigidBody pero omitía la propagación de
## soporte que sí ejecutaban los tres fragmentos inmediatos.

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   ", message)
	else:
		failures += 1
		printerr("  FALLO ", message)


func _shape_body(world: VoxelWorld3D, dimensions: Vector3i, cells: PackedByteArray,
		position := Vector3.ZERO) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	body.position = position
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {
		"color": Color.GRAY, "hardness": 1.0, "density": 1000.0,
	})
	shape.anchored = false
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


func _run() -> void:
	print("continuación estática en fragmento diferido")
	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	world.physics_budget = VoxelPhysicsBudget.new()
	root.add_child(world)

	var dimensions := Vector3i(32, 4, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	cells.fill(0)
	var put := func(x: int, y: int, z: int) -> void:
		cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = 1
	# Base anclada y cuatro componentes de 32 voxeles, por encima del límite cosmético. El cuarto
	# es x=20 y por eso debe pasar por la cola de Bodies diferidos.
	for x in range(0, 3):
		for y in 2:
			for z in 2:
				put.call(x, y, z)
	for start in [5, 10, 15, 20]:
		for x in range(start, start + 2):
			for y in 4:
				for z in 4:
					put.call(x, y, z)
	put.call(30, 1, 1) # voxel sacrificial que dispara la clasificación
	var source := _shape_body(world, dimensions, cells)
	var source_shape := source.get_shapes()[0]
	source_shape.anchored = true
	source_shape.anchor_indices = PackedInt32Array([0])

	var roof_cells := PackedByteArray()
	roof_cells.resize(4 * 2 * 4)
	roof_cells.fill(1)
	var roof := _shape_body(world, Vector3i(4, 2, 4), roof_cells,
		Vector3(0.5, 0.1, -0.1))
	var roof_shape := roof.get_shapes()[0]
	for _frame in 3:
		await physics_frame

	var damage := world.damage_sphere(source_shape.voxel_center_world(
		30 + dimensions.x + dimensions.x * dimensions.y
	), 0.075, 100.0)
	var immediate: Array = damage[0].new_bodies if not damage.is_empty() else []
	_check(immediate.size() == VoxelWorld3D.FRAGMENTS_PER_FRAME,
		"los primeros %d componentes se crean en el frame del impacto" \
			% VoxelWorld3D.FRAGMENTS_PER_FRAME)
	_check(world._body_of(roof_shape) == roof,
		"el techo que toca el cuarto componente aún espera su fragmento")

	for _frame in 16:
		await physics_frame
		world._process(1.0 / 60.0)
	var roof_owner := world._body_of(roof_shape)
	_check(roof_owner != null and roof_owner != roof,
		"la ruta diferida transfiere la continuación estática")
	_check(roof_owner != null and roof_owner.state == VoxelBody3D.State.DYNAMIC,
		"el techo termina en un Body dinámico")
	_check(world._pending_fragments.is_empty(), "la cola de fragmentos queda drenada")
	_check(world.get_metrics().pending_collision_handoffs == 0,
		"el handoff de colisión también queda drenado")

	if failures == 0:
		print("VOXEL_DEFERRED_CONTINUATION_SELFTEST_OK")
	else:
		printerr("VOXEL_DEFERRED_CONTINUATION_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
