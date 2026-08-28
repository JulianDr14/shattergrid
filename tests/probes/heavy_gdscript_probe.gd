extends SceneTree
## Las dos rutas de carga que quedaban repartidas entre GDScript y C++: las caras de colisión
## estática y la subida de bricks al atlas. Mide las dos y comprueba que el lote de bricks entrega
## exactamente lo mismo que la subida de uno en uno que sustituye.

var XML := VoxelProjectPaths.teardown_map_path()
const BRICK := 8
const BRICK_CELLS := BRICK * BRICK * BRICK
## Malla de colisión del mapa entero medida con el barrido completo, antes de recortarlo a las
## macroceldas ocupadas. Son 72 M de triángulos: la referencia va aquí porque no hay forma barata de
## recalcularla desde GDScript, y sin ella el recorte pasaría sin que nadie note un agujero.
const REFERENCE_VERTICES := 216533046
const REFERENCE_CHECKSUM := 2452818599.3419


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	TeardownMapImporter.import_map(world, XML, Vector3.INF, 1.0e9, Vector3.ZERO, false)
	var shapes := []
	for body in world.get_children():
		if body is VoxelBody3D:
			for shape in (body as VoxelBody3D).get_shapes():
				if shape.voxel_count() > 0:
					shapes.append(shape)
	print("shapes=%d" % shapes.size())

	print("--- caras de colisión ---")
	var blocks_usec := 0
	var faces_usec := 0
	var block_count := 0
	# Huella de la malla entregada a Jolt. Recortar el barrido a las macroceldas ocupadas no puede
	# cambiar ni un triángulo — las celdas que se saltan son aire — así que esto tiene que salir
	# idéntico antes y después, y es lo único que separa un recorte correcto de un suelo con
	# agujeros por los que se cae el jugador.
	var vertices := 0
	var checksum := 0.0
	var masked_vertices := 0
	var masked_usec := 0
	var empty_blocks := 0
	for shape: VoxelShape3D in shapes:
		var block := VoxelBody3D.collision_block_for(shape)
		var started := Time.get_ticks_usec()
		var macros := _blocks(shape, block)
		blocks_usec += Time.get_ticks_usec() - started
		var mask := TeardownPalette.mask_for(shape)
		for macro: Vector3i in macros:
			started = Time.get_ticks_usec()
			var faces := shape.data.build_macro_faces(macro, shape.voxel_size, block, 1)
			faces_usec += Time.get_ticks_usec() - started
			block_count += 1
			vertices += faces.size()
			for point: Vector3 in faces:
				checksum += absf(point.x) + absf(point.y) + absf(point.z)
			started = Time.get_ticks_usec()
			var walkable := shape.data.build_macro_faces(macro, shape.voxel_size, block, 1, mask)
			masked_usec += Time.get_ticks_usec() - started
			masked_vertices += walkable.size()
			if walkable.is_empty():
				empty_blocks += 1
	print("bloques=%d  listar=%.0f ms  caras=%.0f ms" % [
		block_count, blocks_usec / 1000.0, faces_usec / 1000.0
	])
	print("HUELLA vertices=%d checksum=%.4f" % [vertices, checksum])
	assert(vertices == REFERENCE_VERTICES, "el recorte por macroceldas cambió la malla de colisión")
	assert(is_equal_approx(checksum, REFERENCE_CHECKSUM), "las caras cambiaron de sitio")
	print("CON MASCARA vertices=%d (-%.1f %%)  caras=%.0f ms  bloques que desaparecen=%d" % [
		masked_vertices, 100.0 * (vertices - masked_vertices) / float(vertices),
		masked_usec / 1000.0, empty_blocks
	])
	assert(masked_vertices > 0 and masked_vertices < vertices, "la máscara no quitó nada")
	# 29,7 s medidos al empezar. Lo que queda es el barrido, no emitir triángulos: con la máscara
	# salen un 74 % menos de vértices y cuesta casi lo mismo. La ganancia de la máscara está en lo
	# que viene después — Jolt construye 18,7 M de triángulos en vez de 72 M — no aquí.
	assert(faces_usec / 1000.0 < 25000.0, "las caras siguen costando demasiado")

	print("--- subida de bricks ---")
	var pool := VoxelBrickPool.new()
	pool.configure(Vector3i(64, 64, 64))
	var batched_usec := 0
	var single_usec := 0
	var uploads := 0
	var bricks := 0
	for shape: VoxelShape3D in shapes:
		var base := pool.get_used()
		var table := pool.append_shape(shape.data)
		if table.is_empty():
			break
		var count := pool.get_used() - base
		var started := Time.get_ticks_usec()
		var batches: Array = pool.extract_uploads(base, count)
		batched_usec += Time.get_ticks_usec() - started
		uploads += batches.size()
		bricks += count
		_verify(pool, shape, table, base, batches)
		# La ruta que sustituye, para comparar: una vuelta por macrocelda y un brick suelto por cada
		# una ocupada. El coste real estaba en la GPU, no aquí, pero el reparto se ve igual.
		var macro_dimensions := shape.data.get_macro_dimensions()
		started = Time.get_ticks_usec()
		for index in macro_dimensions.x * macro_dimensions.y * macro_dimensions.z:
			var slot: int = table[index]
			if slot < 0:
				continue
			pool.refresh_brick(shape.data, slot, Vector3i(
				index % macro_dimensions.x,
				(index / macro_dimensions.x) % macro_dimensions.y,
				index / (macro_dimensions.x * macro_dimensions.y)
			))
			pool.get_slot_origin(slot)
		single_usec += Time.get_ticks_usec() - started
	print("bricks=%d  subidas a la GPU: %d en tandas frente a %d sueltas" % [
		bricks, uploads, bricks
	])
	print("empaquetar %.0f ms frente a %.0f ms del bucle por macrocelda" % [
		batched_usec / 1000.0, single_usec / 1000.0
	])
	print("OK")
	quit()


## Cada brick de la tanda tiene que salir byte a byte igual que el que devolvía `refresh_brick`, y
## en el mismo sitio de la textura. Si esto se desalinea, el mapa se dibuja con la textura de otra
## Shape y no hay error en ningún sitio.
func _verify(
	pool: VoxelBrickPool, shape: VoxelShape3D, table: PackedInt32Array, base: int, batches: Array
) -> void:
	var macro_dimensions := shape.data.get_macro_dimensions()
	var macro_of := {}
	for index in table.size():
		if table[index] >= 0:
			macro_of[table[index]] = Vector3i(
				index % macro_dimensions.x,
				(index / macro_dimensions.x) % macro_dimensions.y,
				index / (macro_dimensions.x * macro_dimensions.y)
			)
	var cursor := 0
	for batch: Dictionary in batches:
		var bytes: PackedByteArray = batch.bytes
		var copies: Array = batch.copies
		assert(batch.source_size == Vector3i(BRICK, BRICK, copies.size() * BRICK))
		assert(bytes.size() == copies.size() * BRICK_CELLS)
		for i in copies.size():
			var slot := base + cursor
			cursor += 1
			var copy: Dictionary = copies[i]
			assert(copy.source == Vector3i(0, 0, i * BRICK), "la fuente del brick %d no cuadra" % i)
			assert(copy.destination == pool.get_slot_origin(slot), "destino del slot %d" % slot)
			assert(copy.size == Vector3i(BRICK, BRICK, BRICK))
			var expected := pool.refresh_brick(shape.data, slot, macro_of[slot])
			assert(
				bytes.slice(i * BRICK_CELLS, (i + 1) * BRICK_CELLS) == expected,
				"el brick del slot %d no coincide con refresh_brick" % slot
			)
	assert(cursor == pool.get_used() - base, "faltan bricks en las tandas")


func _blocks(shape: VoxelShape3D, block: int) -> Array:
	var found := {}
	var dimensions := shape.data.get_macro_dimensions()
	var plane := dimensions.x * dimensions.y
	for macro_index in shape.data.get_occupied_macros():
		found[Vector3i(
			(macro_index % dimensions.x) / block,
			((macro_index / dimensions.x) % dimensions.y) / block,
			(macro_index / plane) / block
		)] = true
	return found.keys()
