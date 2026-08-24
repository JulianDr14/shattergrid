extends SceneTree
## Comprueba que el atlas de bricks devuelve el mismo voxel que la Shape original.
##
## Es la parte que el shader no puede chequear por sí sola: si la tabla `macrocelda -> slot` o el
## empaquetado de 8x8x8 estuvieran torcidos, el mapa se vería mal pero sin ningún error en consola.
## Aquí se repite la indirección tal cual la hace el shader y se compara con `get_cell`.

const BRICK := 8


func _init() -> void:
	var failures := 0
	var pool := VoxelBrickPool.new()
	var shapes: Array[VoxelShapeData] = [
		_noise_shape(Vector3i(17, 9, 23), 7), # dimensiones que no son múltiplo de 8: bricks a medias
		_noise_shape(Vector3i(32, 32, 32), 3),
		_noise_shape(Vector3i(8, 8, 8), 11),
	]
	# Tres bricks de capacidad justa por Shape sería frágil; se pide de sobra y se comprueba el uso.
	assert(pool.configure(Vector3i(4, 4, 8)))
	var tables: Array[PackedInt32Array] = []
	for shape in shapes:
		var table := pool.append_shape(shape)
		if table.is_empty():
			print("BRICK_POOL_FAIL append_shape devolvió una tabla vacía")
			failures += 1
		tables.append(table)

	var bytes := pool.get_bytes()
	var texture := pool.get_dimensions()
	for index in shapes.size():
		var shape := shapes[index]
		var table := tables[index]
		if table.is_empty():
			continue
		var size := shape.get_dimensions()
		var macro_size := shape.get_macro_dimensions()
		for z in size.z:
			for y in size.y:
				for x in size.x:
					var macro := Vector3i(x, y, z) / BRICK
					var slot: int = table[
						macro.x + macro_size.x * (macro.y + macro_size.y * macro.z)
					]
					var expected := shape.get_cell(x, y, z)
					if slot < 0:
						# Sin brick reservado: el shader ni siquiera llega aquí, la macrocelda da vacía.
						if expected != 0:
							print("BRICK_POOL_FAIL voxel lleno en macrocelda sin brick %v" % Vector3i(x, y, z))
							failures += 1
						continue
					var origin := pool.get_slot_origin(slot)
					var texel := origin + Vector3i(x % BRICK, y % BRICK, z % BRICK)
					var found: int = bytes[
						texel.x + texel.y * texture.x + texel.z * texture.x * texture.y
					]
					if found != expected:
						print("BRICK_POOL_FAIL shape=%d %v esperaba %d y hay %d"
							% [index, Vector3i(x, y, z), expected, found])
						failures += 1
						if failures > 8:
							quit(1)
							return

	# Tras un impacto el brick se reescribe: el pool tiene que reflejar el hueco nuevo.
	var damaged := shapes[1]
	damaged.set_cell(9, 9, 9, 0)
	var macro_hit := Vector3i(9, 9, 9) / BRICK
	var slot_hit: int = tables[1][
		macro_hit.x + damaged.get_macro_dimensions().x
			* (macro_hit.y + damaged.get_macro_dimensions().y * macro_hit.z)
	]
	var brick := pool.refresh_brick(damaged, slot_hit, macro_hit)
	if brick.size() != BRICK * BRICK * BRICK:
		print("BRICK_POOL_FAIL refresh_brick devolvió %d bytes" % brick.size())
		failures += 1
	elif brick[1 + 1 * BRICK + 1 * BRICK * BRICK] != 0:
		print("BRICK_POOL_FAIL el brick reescrito sigue con el voxel destruido")
		failures += 1

	print("BRICK_POOL_SELFTEST failures=%d used=%d capacity=%d dimensions=%v"
		% [failures, pool.get_used(), pool.get_capacity(), texture])
	quit(0 if failures == 0 else 1)


func _noise_shape(size: Vector3i, seed_step: int) -> VoxelShapeData:
	var data := VoxelShapeData.new()
	var cells := PackedByteArray()
	cells.resize(size.x * size.y * size.z)
	for index in cells.size():
		# Patrón disperso a propósito: deja macroceldas enteras vacías, que es el caso que el atlas
		# denso desperdiciaba y el de bricks tiene que saltarse.
		cells[index] = ((index * seed_step) % 13) if (index / 64) % 3 != 0 else 0
	data.set_cells(size, cells)
	return data
