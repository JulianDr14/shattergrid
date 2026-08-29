extends "res://tests/selftest/selftest.gd"
## Lo que ya no llega al cimiento cae; lo que llega, no. Es el modelo de Teardown: no hay analisis
## de tensiones, solo alcance INDIRECTO hasta algo que no se puede caer.
##
## Una Shape del mapa entra con `anchored = false`, y una Shape no anclada que sigue siendo una sola
## isla conectada salia de `_split_disconnected` sin mirar nada. Por eso las rejas, las secciones de
## tuberia y las torres se quedaban flotando en Lee.
##
## El caso decisivo es la cadena de tubos: cada seccion toca a sus vecinas, asi que preguntar solo
## "toco algo?" las daba por apoyadas a todas. Hace falta seguir la cadena hasta el suelo.
##
## El ultimo escenario es la isla LEJOS del crater: `_split_disconnected` solo evaluaba las
## componentes cercanas al impacto, asi que el trozo de pared sin uniones se quedaba soldado al aire
## para siempre.


func _slab(world: VoxelWorld3D, position: Vector3, size: Vector3i,
		hardness := 1.0) -> VoxelBody3D:
	var body := VoxelBody3D.new()
	world.add_child(body)
	body.position = position
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	cells.fill(1)
	shape.data.set_cells(size, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.GRAY, "hardness": hardness, "density": 1000.0})
	# Como las Shapes del mapa: sin anclas. Es la condicion que hacia que nada cayera.
	shape.anchored = false
	body.add_voxel_shape(shape)
	world.register_body(body)
	return body


## El fragmento nace en el origen y la altura vive en la Shape, no en el nodo.
static func _body_height(body: VoxelBody3D) -> float:
	var shapes := body.get_shapes()
	return shapes[0].world_bounds().get_center().y if not shapes.is_empty() else 0.0


## Un muro con su base de roca en un extremo y un tramo suelto de ladrillo en el otro, sin nada en
## medio: dos componentes desde el primer frame, separadas mucho mas que el radio del disparo.
func _island_wall(world: VoxelWorld3D) -> VoxelShape3D:
	var shape := VoxelShape3D.new()
	shape.data = VoxelShapeData.new()
	var dimensions := Vector3i(40, 8, 4)
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	for z in dimensions.z:
		for y in dimensions.y:
			for x in dimensions.x:
				var material := 0
				if x < 4:
					material = 2 if y < 3 else 1
				elif x >= 30:
					material = 1
				cells[x + y * dimensions.x + z * dimensions.x * dimensions.y] = material
	shape.data.set_cells(dimensions, cells)
	shape.palette = VoxelPalette.new()
	shape.palette.set_material(1, {"color": Color.RED, "hardness": 0.4, "density": 400.0})
	shape.palette.set_material(2, {
		"color": Color.GRAY, "hardness": VoxelWorld3D.FOUNDATION_HARDNESS, "density": 2400.0,
	})
	shape.anchored = false
	shape.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 6.0, 0.0))
	var body := VoxelBody3D.new()
	body.state = VoxelBody3D.State.STATIC
	world.add_child(body)
	body.add_voxel_shape(shape)
	world.register_body(body)
	return shape


func _run() -> void:
	print("caida de lo que no toca nada")
	var world := make_world()

	# Suelo de roca: el cimiento. Dureza 1e6 es lo que trae `rock` en la paleta de Teardown.
	var ground := _slab(world, Vector3(0.0, 0.0, 0.0), Vector3i(60, 4, 60), 1000000.0)
	var resting := _slab(world, Vector3(0.0, 0.5, 0.0), Vector3i(8, 6, 8))
	var floating := _slab(world, Vector3(1.5, 4.0, 0.0), Vector3i(24, 4, 24))
	for _frame in 6:
		await physics_frame
	# El `RigidBody3D` es hijo del `VoxelBody3D` y las Shapes cuelgan de el: lo que se mueve es la
	# Shape, no el nodo envoltorio.
	var height := floating.get_shapes()[0].world_bounds().get_center().y
	_check(ground.state == VoxelBody3D.State.STATIC
		and resting.state == VoxelBody3D.State.STATIC
		and floating.state == VoxelBody3D.State.STATIC, "las tres empiezan estaticas")

	# Un impacto cerca de la reja: es lo que dispara la comprobacion de apoyo.
	# Un mordisco en una esquina: la reja sobrevive, que es lo que se quiere comprobar.
	world.damage_sphere(Vector3(0.6, 4.0, -0.9), 0.2, 20.0)
	_check(floating.get_shapes()[0].voxel_count() > 0, "la reja sobrevive al mordisco")
	_check(floating.state == VoxelBody3D.State.DYNAMIC, "la reja flotante pasa a dinamica")
	_check(resting.state == VoxelBody3D.State.STATIC, "la losa apoyada en el suelo no se mueve")
	_check(ground.state == VoxelBody3D.State.STATIC, "el suelo tampoco")

	for _frame in 40:
		await physics_frame
	var fallen := height - floating.get_shapes()[0].world_bounds().get_center().y
	print("  la reja bajo %.2f m" % fallen)
	_check(fallen > 0.3, "y ademas cae de verdad")
	# Cada escenario necesita un espacio limpio. Dejar la reja dinámica del primero en el mismo
	# World3D hacía que golpeara y destruyera los tubos del siguiente mientras se preparaba el test.
	world.queue_free()
	await process_frame
	await physics_frame

	# La cadena de tubos: seis secciones seguidas que se tocan. La primera se apoya en el suelo, asi
	# que la cadena entera esta sostenida; si se corta el enlace, el resto tiene que caer.
	var world2 := make_world()
	# Un pilar de roca de 4,4 m y una tuberia en voladizo: solo la primera seccion toca el pilar, las
	# otras cinco cuelgan en el aire y solo llegan al suelo por la cadena.
	_slab(world2, Vector3(0.0, 0.0, 0.0), Vector3i(6, 44, 6), 1000000.0)
	# La coalescencia puede absorber los Bodies authored antes de esta comprobación. Las Shapes son
	# la identidad estable; su Body actual se resuelve al usarla, igual que hace gameplay.
	var pipe_shapes: Array[VoxelShape3D] = []
	for section in 6:
		var pipe := _slab(world2, Vector3(0.55 + float(section) * 1.0, 2.0, 0.0),
			Vector3i(10, 3, 6))
		pipe_shapes.append(pipe.get_shapes()[0])
	for _frame in 6:
		await physics_frame
	var all_static := true
	for pipe_shape in pipe_shapes:
		var pipe_owner := world2._body_of(pipe_shape)
		all_static = all_static and pipe_owner != null \
			and pipe_owner.state == VoxelBody3D.State.STATIC
	_check(all_static, "la cadena de tubos apoyada en la roca se queda quieta")

	# Se parte el tercer tubo: los tres de la punta pierden el camino al suelo.
	var tail_shapes: Array[VoxelShape3D] = []
	for section in range(3, 6):
		tail_shapes.append(pipe_shapes[section])
	var cut := pipe_shapes[2]
	world2.damage_sphere(cut.world_bounds().get_center(), 1.2, 100.0)
	var tail_dynamic := 0
	var hosts := {}
	for shape in tail_shapes:
		var owner_body := world2._body_of(shape)
		if owner_body != null and owner_body.state == VoxelBody3D.State.DYNAMIC:
			tail_dynamic += 1
			hosts[owner_body] = true
	_check(tail_dynamic == 3, "los tubos de la punta caen al cortar la cadena (%d/3)" % tail_dynamic)
	# Y caen juntos. Lo que la destruccion no ha separado sigue siendo una pieza: con un cuerpo por
	# Shape, la cabeza de una torre se quedaba flotando mientras el mastil se iba.
	_check(hosts.size() == 1, "como un solo cuerpo, no cada trozo por su lado (%d)" % hosts.size())
	var root_pipe_owner := world2._body_of(pipe_shapes[0])
	_check(root_pipe_owner != null and root_pipe_owner.state == VoxelBody3D.State.STATIC,
		"el tubo que toca la roca sigue en su sitio")

	# Lo mismo, pero lejos del origen. El test de contacto recibe la transformada relativa entre las
	# dos Shapes, y construirla al reves da un resultado correcto cerca del origen y basura lejos: en
	# Lee, una torre de 24 m a 70 m del centro no "tocaba" el suelo que tenia debajo ni con dos metros
	# de margen, asi que ninguna prueba montada alrededor del origen lo habria visto.
	var world3 := make_world()
	var far := Vector3(-3.9, 0.0, 70.9)
	_slab(world3, far, Vector3i(20, 20, 20), 1000000.0)
	var mast := _slab(world3, far + Vector3(0.0, 2.05, 0.0), Vector3i(4, 20, 4))
	for _frame in 6:
		await physics_frame
	_check(mast.state == VoxelBody3D.State.STATIC,
		"una torre lejos del origen se reconoce apoyada en la roca de debajo")
	world3.damage_sphere(far + Vector3(0.0, 1.05, 0.0), 1.4, 1000000.0)
	for _frame in 4:
		await physics_frame
	_check(mast.state == VoxelBody3D.State.DYNAMIC,
		"y cae cuando se le vuela lo que la sostenia")

	# Poste unificado y no anclado explícitamente, como los importados. La parte superior es mayor
	# que la base: conservar "la componente más grande" dejaba arriba estático y soltaba precisamente
	# el pie que aún tocaba el mundo. La raíz externa debe decidirlo al revés.
	var world_post := make_world()
	_slab(world_post, Vector3.ZERO, Vector3i(20, 4, 20), 1000000.0)
	var post := _slab(world_post, Vector3(0.0, 0.8, 0.0), Vector3i(1, 12, 1))
	var post_shape := post.get_shapes()[0]
	# Shape separada que toca la punta, equivalente a la cabeza authored de la torre eléctrica. No
	# está cerca del cráter y por eso debe propagarse desde el fragmento superior recién creado.
	var post_head := _slab(world_post, Vector3(0.0, 1.5, 0.0), Vector3i(5, 2, 5))
	var post_head_shape := post_head.get_shapes()[0]
	var post_cut := world_post.damage_sphere(
		post_shape.voxel_center_world(3), 0.075, 100.0
	)
	var post_fragments: Array = post_cut[0].new_bodies if not post_cut.is_empty() else []
	_check(post.state == VoxelBody3D.State.STATIC and post_shape.voxel_count() == 3,
		"la base pequeña del poste conserva su anclaje al suelo")
	_check(post_fragments.size() == 1 \
		and (post_fragments[0] as VoxelBody3D).get_total_voxels() == 58 \
		and (post_fragments[0] as VoxelBody3D).state == VoxelBody3D.State.DYNAMIC,
		"solo la sección superior sin ruta se vuelve dinámica")
	_check(world_post._body_of(post_head_shape) == post_fragments[0],
		"la cabeza lejana se transfiere al mismo cuerpo que el tramo que la sostenía")

	# Una Shape puede mezclar el material de raíz con la estructura que sostiene. Consultar una vez
	# `es cimiento` y después destruir toda la roca no debe dejar esa respuesta cacheada para siempre.
	var world_brick := make_world()
	var brick_body := VoxelBody3D.new()
	world_brick.add_child(brick_body)
	var brick_shape := VoxelShape3D.new()
	brick_shape.data = VoxelShapeData.new()
	var brick_cells := PackedByteArray()
	brick_cells.resize(3 * 8 * 3)
	brick_cells.fill(1)
	for z in 3:
		for x in 3:
			brick_cells[x + z * 3 * 8] = 2
	brick_shape.data.set_cells(Vector3i(3, 8, 3), brick_cells)
	brick_shape.palette = VoxelPalette.new()
	brick_shape.palette.set_material(1, {
		"color": Color(0.5, 0.2, 0.1), "hardness": 1.0, "density": 1800.0,
	})
	brick_shape.palette.set_material(2, {
		"color": Color.GRAY, "hardness": 1000.0, "density": 2600.0,
	})
	brick_body.add_voxel_shape(brick_shape)
	world_brick.register_body(brick_body)
	_check(world_brick._is_foundation(brick_shape),
		"la base de roca de la torre de ladrillos se reconoce inicialmente")
	var root_center := brick_shape.voxel_center_world(1)
	var brick_damage := world_brick.damage_sphere(root_center, 0.5, 1000000000.0)
	var brick_fragments: Array = brick_damage[0].new_bodies \
		if not brick_damage.is_empty() else []
	_check(not world_brick._is_foundation(brick_shape),
		"al borrar toda la roca se invalida la raíz cacheada")
	_check(brick_fragments.size() == 1 \
		and (brick_fragments[0] as VoxelBody3D).state == VoxelBody3D.State.DYNAMIC,
		"la torre de ladrillos sin ninguna raíz cae en ese mismo impacto")

	# Un apoyo al que se le rompe el contacto, sin llegar a desaparecer. La cache de contactos es por
	# Shape y la busqueda de cimiento corta en cuanto lo descubre, asi que el apoyo puede no tener
	# entrada propia mientras la viga si lo tiene en la suya: le haces el boquete y la viga sigue
	# creyendose apoyada hasta que otro impacto cualquiera le tira la cache.
	var world4 := make_world()
	_slab(world4, Vector3(0.0, 0.0, 0.0), Vector3i(40, 10, 40), 1000000.0)
	var column := _slab(world4, Vector3(0.0, 1.05, 0.0), Vector3i(4, 20, 4))
	var beam := _slab(world4, Vector3(0.0, 2.25, 0.0), Vector3i(30, 4, 4))
	var beam_shape := beam.get_shapes()[0] as VoxelShape3D
	for _frame in 6:
		await physics_frame
	_check(beam.state == VoxelBody3D.State.STATIC, "la viga sobre la columna se queda quieta")
	# Un raspon en la punta de la viga, lejos de la columna: no rompe nada, pero deja la cache de
	# contactos poblada, que es la situacion en la que aparecia el fallo.
	world4.damage_sphere(Vector3(1.35, 2.25, 0.0), 0.2, 60.0)
	for _frame in 4:
		await physics_frame
	_check(beam.state == VoxelBody3D.State.STATIC, "y sigue quieta tras un raspon en su punta")
	# Ahora se rompe el contacto columna-viga, sin tocar la viga y sin borrar la columna.
	var top := column.get_shapes()[0].world_bounds().end.y
	# El centro queda suficientemente bajo para borrar toda la sección del pilar sin alcanzar los
	# centros voxel de la viga: la prueba debe medir pérdida de soporte, no destruir el sujeto.
	world4.damage_sphere(Vector3(0.0, top - 0.35, 0.0), 0.38, 100.0)
	for _frame in 4:
		await physics_frame
	print("  columna: quedan %d voxeles" % column.get_shapes()[0].voxel_count())
	_check(column.get_shapes()[0].voxel_count() > 0, "la columna sigue ahi, solo sin su remate")
	var beam_owner := world4._body_of(beam_shape)
	_check(beam_owner != null and beam_owner.state == VoxelBody3D.State.DYNAMIC,
		"y la viga cae en ese mismo disparo, no en el siguiente")

	# La reserva de cajas de colision de un cuerpo que acaba de volverse dinamico se calcula sobre lo
	# que esta DESPIERTO. Contando todos los dinamicos, los 632 props dormidos de Lee ya sumaban
	# 13 761 cajas contra un techo de 8 192, asi que la reserva salia 1: una torre de 24 m caia
	# convertida en una sola caja, que ni cae bien ni se puede tocar.
	world4.compound_boxes = 20_000
	world4.awake_compound_boxes = 0
	_check(world4._box_allowance_for_new_body() == world4.physics_budget.max_boxes_per_body,
		"un cuerpo que cae estrena colision con forma aunque los dormidos pasen del techo")

	# Más larga que el antiguo límite fail-open de 32 Shapes. Una búsqueda inconclusa no puede
	# responder "soportado": la cadena entera carece de raíz y debe caer aunque el componente sea
	# grande. Solo se explora esta isla nacida de la arista modificada, no el mapa completo.
	var world5 := make_world()
	var long_chain: Array[VoxelBody3D] = []
	var long_chain_shapes: Array[VoxelShape3D] = []
	for section in 40:
		var section_body := _slab(
			world5, Vector3(float(section), 8.0, 0.0), Vector3i(10, 3, 3)
		)
		long_chain.append(section_body)
		long_chain_shapes.append(section_body.get_shapes()[0])
	var last_shape := long_chain[-1].get_shapes()[0]
	world5.damage_sphere(last_shape.world_bounds().get_center(), 0.12, 20.0)
	var dynamic_sections := 0
	var long_chain_hosts := {}
	for section_shape in long_chain_shapes:
		var owner := world5._body_of(section_shape)
		if owner != null and owner.state == VoxelBody3D.State.DYNAMIC:
			dynamic_sections += 1
			long_chain_hosts[owner] = true
	_check(dynamic_sections == 40,
		"una cadena sin raíz de más de 32 Shapes cae completa (%d/40)" % dynamic_sections)
	_check(long_chain_hosts.size() == 1,
		"la cadena larga usa un único RigidBody en vez de cuarenta (%d)" % long_chain_hosts.size())

	# La reja de Lee: una barra authored que solo se sostiene metida en un pilar de roca. El jugador
	# vuela el voxel de union y la reja se queda en el aire. El contacto se pregunta con un alcance de
	# `ceil(CONTACT_MARGIN / voxel_size)` voxeles: con 0.12 sobre voxeles de 0.1 el alcance era DOS, o
	# sea que una capa entera de aire entre las dos piezas seguia contando como union. Volar la union
	# no soltaba nada porque nunca habia nada que soltar.
	var world_fence := make_world()
	_slab(world_fence, Vector3.ZERO, Vector3i(20, 4, 20), 1000000.0)
	_slab(world_fence, Vector3(0.0, 2.2, 0.0), Vector3i(4, 40, 4), 1000000.0)
	# Barra de 3 m pegada a la cara del pilar, a 3 m del suelo: su unico camino al cimiento es el pilar.
	var fence := _slab(world_fence, Vector3(1.7, 3.0, 0.0), Vector3i(30, 2, 2))
	var fence_shape := fence.get_shapes()[0]
	for _frame in 6:
		await physics_frame
	var fence_height := fence_shape.world_bounds().get_center().y
	_check(fence.state == VoxelBody3D.State.STATIC, "la reja empotrada en el pilar se queda quieta")
	# Se borra exactamente la columna de union (0,25 m), sin tocar el pilar de roca.
	world_fence.damage_sphere(Vector3(0.25, 3.0, 0.0), 0.11, 100.0)
	for _frame in 4:
		await physics_frame
	var fence_owner := world_fence._body_of(fence_shape)
	_check(fence_owner != null and fence_owner.state == VoxelBody3D.State.DYNAMIC,
		"y cae al volarle la union, con el pilar todavia en pie")
	for _frame in 40:
		await physics_frame
	var fence_fallen := fence_height - fence_shape.world_bounds().get_center().y
	print("  la reja bajo %.2f m" % fence_fallen)
	_check(fence_fallen > 0.3, "cae de verdad, no solo de estado")

	# Isla desconectada LEJOS del crater: el tramo suelto esta a 26 voxeles del disparo, muy fuera del
	# alcance local que antes filtraba las componentes a reclasificar.
	var world_island := make_world()
	var wall := _island_wall(world_island)
	world_island.finalize_spatial_index()
	for _frame in 5:
		await physics_frame
	_check(world_island.get_dynamic_bodies().is_empty(), "el muro con isla entra entero como estatica")
	# Se raspa la roca: quita cimiento, asi que la clasificacion se dispara seguro.
	world_island.damage_sphere(wall.voxel_center_world(0), 0.15, 1.0e6)
	for _frame in 30:
		await physics_frame
		world_island._process(1.0 / 60.0)
	var islands := world_island.get_dynamic_bodies()
	_check(not islands.is_empty(), "el tramo lejano al crater se desprende en su propio cuerpo")
	_check(is_instance_valid(wall) and wall.voxel_count() > 0,
		"y la base sobre la roca se queda donde estaba")
	var island_heights: Array[float] = []
	for body: VoxelBody3D in islands:
		island_heights.append(_body_height(body))
	for _frame in 90:
		await physics_frame
		world_island._process(1.0 / 60.0)
	var fell := 0
	for index in islands.size():
		var body := islands[index]
		if is_instance_valid(body) and island_heights[index] - _body_height(body) > 0.3:
			fell += 1
	_check(fell > 0, "la isla lejana cae de verdad, no se queda flotando")
	var snapshot: Dictionary = world_island._runtime_registry.get_coherence_snapshot()
	print("  isla lejana: %d cuerpos, coherencia %s" % [islands.size(), snapshot.get("status", "?")])
	_check(String(snapshot.get("status", "")) != "DESYNC",
		"ninguna Shape queda con colision desincronizada tras cambiar de cuerpo")

	if failures == 0:
		print("VOXEL_UNSUPPORTED_DROP_SELFTEST_OK")
	else:
		printerr("VOXEL_UNSUPPORTED_DROP_SELFTEST_FAIL count=", failures)
	quit(1 if failures > 0 else 0)
