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


## Voxeles retirados de una losa de un voxel de grosor por un disparo de radio 10 y penetración 1,5.
## La losa plana convierte el radio alcanzado en un área comparable entre durezas.
func _crater(hardness: float) -> int:
	var data := VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(61 * 61)
	cells.fill(1)
	data.set_cells(Vector3i(61, 1, 61), cells)
	var hardnesses := PackedFloat32Array()
	hardnesses.resize(256)
	hardnesses.fill(hardness)
	var result: Dictionary = data.damage_sphere_material(
		Vector3(30.5, 0.5, 30.5), 10.0, 1.5, hardnesses
	)
	return int(result.removed)


func _run() -> void:
	print("arquitectura World -> Body -> Shape")
	var imported := VoxelAssetImporter.load_asset("res://models/casa_dos_plantas.vox")
	_check(not imported.is_empty(), "importa .vox a volumen denso de 10 cm")
	_check(imported.shapes.size() >= 1, "crea Shapes desde SIZE/XYZI y grafo de escena")
	var imported_shape: Dictionary = imported.shapes[0]
	_check((imported_shape.data as VoxelShapeData).get_occupied_count() > 1000,
		"conserva los voxeles fuente sin reducción runtime")
	_check((imported.palette as VoxelPalette).get_capacity() == 255,
		"paleta separada de 8 bits")

	var legacy := VoxelAssetImporter.load_legacy_blueprint("casa")
	var legacy_count := (legacy.shapes[0].data as VoxelShapeData).get_occupied_count()
	_check(legacy_count == Blueprints.of("casa").size() * 27,
		"cada celda heredada de 30 cm se expande una vez a 3x3x3")

	var world := VoxelWorld3D.new()
	world.show_diagnostics = false
	root.add_child(world)
	var body := VoxelBody3D.new()
	world.add_child(body)
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var bridge_cells := PackedByteArray()
	bridge_cells.resize(81)
	bridge_cells.fill(1)
	shape.data.set_cells(Vector3i(81, 1, 1), bridge_cells)
	shape.palette = VoxelPalette.new()
	shape.anchor_indices = PackedInt32Array([0])
	shape.anchored = true
	shape.position = Vector3(0, 0.05, 0)
	body.add_voxel_shape(shape)
	world.register_body(body)
	var affected := world.damage_sphere(shape.voxel_center_world(40), 0.075, 100.0)
	_check(affected.size() == 1, "damage_sphere localiza la Shape por la rejilla estatica")
	if affected.is_empty():
		quit(1)
		return
	var created: Array = affected[0].new_bodies
	_check(created.size() == 1 and (created[0] as VoxelBody3D).get_total_voxels() == 40,
		"conectividad solo por caras separa el fragmento no anclado")
	if not created.is_empty():
		var fragment := created[0] as VoxelBody3D
		_check(fragment.state == VoxelBody3D.State.DYNAMIC \
			and fragment.get_physics_body() is RigidBody3D,
			"el fragmento nace realmente como RigidBody Jolt")
		_check(fragment.compound_boxes <= world.physics_budget.max_boxes_per_body,
			"respeta 128 cajas por Body")
	var metrics := world.get_metrics()
	_check(int(metrics.awake_compound_boxes) <= world.physics_budget.max_active_boxes,
		"respeta el presupuesto global de cajas activas")
	_check(int(metrics.pending_collision_rebuilds) == 1,
		"la colisión estática destructiva se difiere y deduplica")
	var pending_blocks := int(metrics.pending_collision_blocks)
	world._process(1.0 / 60.0)
	_check(int(world.get_metrics().pending_collision_blocks) < pending_blocks,
		"la colisión progresa y un handoff puede consumir su presupuesto prioritario")
	for _unused in 8:
		world._process(1.0 / 60.0)
	_check(int(world.get_metrics().pending_collision_rebuilds) == 0,
		"la cola de colisión destructiva termina de vaciarse")

	# Regression: removing the last foundation from a still-connected structure must make the
	# complete remainder dynamic, even though flood fill finds only one component.
	var foundation_body := VoxelBody3D.new()
	world.add_child(foundation_body)
	var foundation_shape := VoxelShape3D.new()
	foundation_shape.data = VoxelShapeData.new()
	var tower_cells := PackedByteArray()
	tower_cells.resize(40)
	tower_cells.fill(1)
	foundation_shape.data.set_cells(Vector3i(1, 40, 1), tower_cells)
	foundation_shape.palette = VoxelPalette.new()
	foundation_shape.anchor_indices = PackedInt32Array([0])
	foundation_shape.anchored = true
	foundation_shape.position = Vector3(10.0, 0.05, 0.0)
	foundation_body.add_voxel_shape(foundation_shape)
	world.register_body(foundation_body)
	var collapse := world.damage_sphere(
		foundation_shape.voxel_center_world(0), 0.075, 100.0
	)
	var collapsed_bodies: Array = collapse[0].new_bodies if not collapse.is_empty() else []
	var collapse_rigid: RigidBody3D
	var collapse_body: VoxelBody3D
	_check(collapsed_bodies.size() == 1,
		"cortar el último anclaje desprende una estructura todavía conectada")
	if not collapsed_bodies.is_empty():
		var collapsed := collapsed_bodies[0] as VoxelBody3D
		collapse_body = collapsed
		collapse_rigid = collapsed.get_physics_body() as RigidBody3D
		_check(collapsed.state == VoxelBody3D.State.DYNAMIC and collapsed.get_total_voxels() == 39,
			"la estructura completa cae como un Body dinámico")
	_check(foundation_shape.voxel_count() == 0,
		"la Shape estática no conserva una copia flotante")

	# Reproduce the real legacy house from the playable scene, not only a synthetic column.
	var house_asset := VoxelAssetImporter.load_legacy_blueprint("casa")
	var house_body := VoxelBody3D.new()
	world.add_child(house_body)
	var house_shape := VoxelShape3D.from_asset(house_asset.shapes[0], house_asset.palette)
	house_shape.position += Vector3(20.0, 0.0, 0.0)
	house_body.add_voxel_shape(house_shape)
	world.register_body(house_body)
	var foundation_piece := house_shape.detach_component(house_shape.anchor_indices)
	if foundation_piece != null:
		foundation_piece.free()
	var house_components := house_shape.classified_components()
	var live_anchor_components := 0
	for component: Dictionary in house_components:
		live_anchor_components += 1 if bool(component.anchored) else 0
	_check(live_anchor_components == 0,
		"la casa real no conserva anclajes fantasma tras retirar la base")
	var fallen_house := world._split_disconnected(house_body, house_shape, Vector3.ZERO, 0.1)
	_check(not fallen_house.is_empty(),
		"la casa real genera Bodies dinámicos al perder toda la cimentación")
	_check(house_shape.voxel_count() == 0,
		"ninguna parte grande de la casa real permanece estática en el aire")

	# Regression de pared/poste: mientras quede una ruta material a cualquier ancla viva, la
	# componente completa sigue integrada al mundo. La resistencia mecánica no se aproxima con un
	# porcentaje de cimentación; sería una simulación distinta y soltaba bases todavía conectadas.
	var weak_asset := VoxelAssetImporter.load_legacy_blueprint("casa")
	var weak_body := VoxelBody3D.new()
	world.add_child(weak_body)
	var weak_shape := VoxelShape3D.from_asset(weak_asset.shapes[0], weak_asset.palette)
	weak_shape.position += Vector3(30.0, 0.0, 0.0)
	weak_body.add_voxel_shape(weak_shape)
	world.register_body(weak_body)
	var anchors_to_remove := PackedInt32Array()
	var anchors_to_keep := ceili(weak_shape.anchor_indices.size() * 0.25)
	for anchor_offset in range(anchors_to_keep, weak_shape.anchor_indices.size()):
		anchors_to_remove.append(weak_shape.anchor_indices[anchor_offset])
	var removed_foundation := weak_shape.detach_component(anchors_to_remove)
	if removed_foundation != null:
		removed_foundation.free()
	var weak_components := weak_shape.classified_components()
	_check(not weak_components.is_empty() and bool(weak_components[0].anchored),
		"el caso visual conserva restos de anclaje conectados")
	var weak_remaining := weak_shape.voxel_count()
	var weak_collapse := world._split_disconnected(weak_body, weak_shape, Vector3.ZERO, 0.1)
	_check(weak_collapse.is_empty() and weak_shape.voxel_count() == weak_remaining \
		and weak_body.state == VoxelBody3D.State.STATIC,
		"la pared no se desprende mientras conserve una ruta material al mundo")

	# Un cuello de un voxel sigue siendo conectividad geométrica válida. No es realista como cálculo
	# de tensiones, pero sí es el invariante binario solicitado: cae únicamente al desaparecer la
	# última ruta, nunca por una heurística de grosor.
	var neck_body := VoxelBody3D.new()
	world.add_child(neck_body)
	var neck_shape := VoxelShape3D.new()
	neck_shape.data = VoxelShapeData.new()
	var neck_cells := PackedByteArray()
	neck_cells.resize(12 * 12 * 12)
	neck_cells.fill(1)
	neck_shape.data.set_cells(Vector3i(12, 12, 12), neck_cells)
	neck_shape.palette = VoxelPalette.new()
	var neck_anchors := PackedInt32Array()
	for z in 12:
		for x in 12:
			neck_anchors.append(x + z * 12 * 12)
	neck_shape.anchor_indices = neck_anchors
	neck_shape.anchored = true
	neck_shape.position = Vector3(45.0, 0.6, 0.0)
	neck_body.add_voxel_shape(neck_shape)
	world.register_body(neck_body)
	var severed_layer := PackedInt32Array()
	for z in 12:
		for x in 12:
			if x != 6 or z != 6:
				severed_layer.append(x + 12 + z * 12 * 12)
	var discarded_layer := neck_shape.detach_component(severed_layer)
	if discarded_layer != null:
		discarded_layer.free()
	var neck_components := neck_shape.classified_components()
	_check(not neck_components.is_empty() and int(neck_components[0].anchor_count) == 144,
		"la cimentación oculta puede seguir intacta bajo el suelo")
	_check(int(neck_components[0].support_cross_section) == 1,
		"detecta el cuello estructural que conecta la casa con esa cimentación")
	var neck_remaining := neck_shape.voxel_count()
	var neck_collapse := world._split_disconnected(neck_body, neck_shape, Vector3.ZERO, 0.1)
	_check(neck_collapse.is_empty() and neck_shape.voxel_count() == neck_remaining \
		and neck_body.state == VoxelBody3D.State.STATIC,
		"una unión residual real mantiene la componente anclada")

	if collapse_rigid != null and collapse_body != null:
		for _handoff_frame in 60:
			if not collapse_body.collision_handoff_pending:
				break
			await physics_frame
		_check(not collapse_body.collision_handoff_pending,
			"el handoff termina antes de entregar el edificio al solver")
		var falling_shape := collapse_body.get_shapes()[0] as VoxelShape3D
		var initial_fall_y := falling_shape.world_bounds().get_center().y
		for _physics_step in 8:
			await physics_frame
		_check(falling_shape.world_bounds().get_center().y < initial_fall_y - 0.001,
			"Jolt aplica gravedad al edificio desprendido en frames reales")

	# El cráter escalonado de `MakeHole`: un mismo disparo abre mucho en blando, poco en duro y nada
	# en indestructible. Antes el umbral `energy * atenuación >= dureza` se saturaba y las cuatro
	# durezas daban la misma esfera.
	var soft_crater := _crater(1.0)
	var medium_crater := _crater(2.4)
	var hard_crater := _crater(4.0)
	_check(soft_crater > medium_crater and medium_crater > hard_crater and hard_crater > 0
		and _crater(1000000.0) == 0,
		"el boquete se estrecha con la dureza y el material indestructible aguanta")
	_check(soft_crater < int(PI * 100.0 * 0.95),
		"el borde del cráter queda mordido y no es una esfera analítica")

	# La malla estatica tiene que frenar por FUERA. Con caras de un solo lado y el devanado que
	# genera `build_macro_faces`, la cara solida miraba hacia dentro y se caia uno por el suelo.
	var floor_world := VoxelWorld3D.new()
	floor_world.show_diagnostics = false
	root.add_child(floor_world)
	var floor_body := VoxelBody3D.new()
	floor_world.add_child(floor_body)
	var floor_shape := VoxelShape3D.new()
	floor_shape.data = VoxelShapeData.new()
	var slab := PackedByteArray()
	slab.resize(16 * 16 * 16)
	slab.fill(1)
	floor_shape.data.set_cells(Vector3i(16, 16, 16), slab)
	floor_shape.palette = VoxelPalette.new()
	floor_body.add_voxel_shape(floor_shape)
	floor_world.register_body(floor_body)
	for _frame in 4:
		await physics_frame
	# El cubo de 16 voxeles de 10 cm centrado en el origen llega hasta y = +0,8.
	var down := PhysicsRayQueryParameters3D.create(Vector3(0, 3, 0), Vector3(0, -3, 0))
	var hit := root.world_3d.direct_space_state.intersect_ray(down)
	_check(not hit.is_empty() and absf(float(hit.get("position", Vector3.ZERO).y) - 0.8) < 0.01,
		"la malla estatica frena por su cara exterior")

	# El follaje no colisiona: en el original se camina por el suelo y la hierba no levanta la camara.
	var mask := TeardownPalette.collide_mask(TeardownPalette.WALK_THROUGH)
	var foliage_walkable := true
	var masonry_solid := true
	for index in range(1, 256):
		match TeardownPalette.material_name(index):
			"foliage": foliage_walkable = foliage_walkable and mask[index] == 0
			"masonry": masonry_solid = masonry_solid and mask[index] == 1
	_check(foliage_walkable, "el follaje sale de la malla de colision")
	_check(masonry_solid, "la mamposteria sigue colisionando")

	print("")
	if failures == 0:
		print("TEARDOWN_ARCHITECTURE_SELFTEST_OK")
	else:
		printerr("TEARDOWN_ARCHITECTURE_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
