class_name VoxelShapeGrid
extends RefCounted
## Rejilla uniforme de Shapes, para preguntar "quien toca esta caja" sin recorrerlas todas.
##
## El refresco del volumen de ocupacion barria las 2312 Shapes de Lee pidiendo `world_bounds()` una
## por una: medido, 10 ms fijos por region, y hasta cuatro regiones por frame. Ese barrido era el
## coste entero — rasterizar de verdad una caja de 4 m son 0,05 ms, y una region de 1 m con cero
## Shapes dentro costaba lo mismo que una con cuatro. La rejilla se construye una vez y solo se
## reinserta lo que se mueve, que son los cuerpos despiertos.

## 8 m: una Shape corriente de Lee cae en una o dos celdas y un escombro en una.
const CELL_SIZE := 8.0
## Una Shape que ocupe mas celdas que esto se guarda aparte y se comprueba en toda consulta:
## reinsertarla costaria mas que el barrido que evitamos. En Lee la mayor son 22x9x18 m, 12 celdas.
const MAX_CELLS := 512

var _cells := {}
## id de instancia -> celdas que ocupa, para poder sacarla sin recorrer la rejilla.
var _placed := {}
var _oversized := {}


static func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(
		floori(point.x / CELL_SIZE), floori(point.y / CELL_SIZE), floori(point.z / CELL_SIZE)
	)


func insert(shape: VoxelShape3D, bounds: AABB) -> void:
	var key := shape.get_instance_id()
	remove_id(key)
	var low := _cell_of(bounds.position)
	var high := _cell_of(bounds.end)
	var span := high - low + Vector3i.ONE
	if span.x * span.y * span.z > MAX_CELLS:
		_oversized[key] = shape
		return
	var occupied: Array[Vector3i] = []
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var cell := Vector3i(x, y, z)
				if not _cells.has(cell):
					_cells[cell] = []
				(_cells[cell] as Array).append(shape)
				occupied.append(cell)
	_placed[key] = occupied


func remove_id(key: int) -> void:
	_oversized.erase(key)
	if not _placed.has(key):
		return
	for cell: Vector3i in _placed[key]:
		var bucket: Array = _cells.get(cell, [])
		for position in range(bucket.size() - 1, -1, -1):
			# El Variant conserva el id de un Object liberado, pero intentar castearlo ya lanza error
			# antes de que una variable tipada pueda comprobar null. Validar el Variant primero permite
			# limpiar la celda sin tocar el objeto muerto.
			var candidate: Variant = bucket[position]
			if not is_instance_valid(candidate):
				bucket.remove_at(position)
				continue
			var shape := candidate as VoxelShape3D
			if shape == null or shape.get_instance_id() == key:
				bucket.remove_at(position)
		if bucket.is_empty():
			_cells.erase(cell)
	_placed.erase(key)


func has_id(key: int) -> bool:
	return _placed.has(key) or _oversized.has(key)


func size() -> int:
	return _placed.size() + _oversized.size()


## Las Shapes que solapan la caja de verdad, ya filtradas por `world_bounds()`.
func query(region: AABB) -> Array[VoxelShape3D]:
	var result: Array[VoxelShape3D] = []
	var seen := {}
	var candidates: Array = _oversized.values()
	var low := _cell_of(region.position)
	var high := _cell_of(region.end)
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var bucket: Array = _cells.get(Vector3i(x, y, z), [])
				if not bucket.is_empty():
					candidates.append_array(bucket)
	for candidate: Variant in candidates:
		if not is_instance_valid(candidate):
			continue
		var shape := candidate as VoxelShape3D
		if shape == null:
			continue
		var key := shape.get_instance_id()
		if seen.has(key):
			continue
		seen[key] = true
		if shape.voxel_count() > 0 and shape.world_bounds().intersects(region):
			result.append(shape)
	return result
