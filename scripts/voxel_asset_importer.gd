class_name VoxelAssetImporter
extends RefCounted
## MagicaVoxel importer for the 10 cm runtime representation.
##
## SIZE/XYZI/RGBA/MATL provide dense voxel and material data. nTRN/nGRP/nSHP are parsed into
## Shape transforms instead of baking multiple objects into one wasteful bounding volume.

const VOXEL_SIZE := 0.1

## Cuántos voxeles de 10 cm ocupa cada voxel del `.vox` de origen.
##
## Teardown modela a 10 cm con el jugador midiendo 18 voxeles, así que una casa de dos plantas ronda
## los 85-90 voxeles de alto y su puerta los 20. Los Metro Minis están modelados como maquetas: 64
## voxeles de alto y puertas de 12, o sea una casa de 6,4 m con una puerta de 1,2 m por la que el
## jugador de 1,8 m no cabe. A 2 la casa sube a 12,8 m y la puerta a 2,4 m, que ya es una fachada
## urbana por la que se entra andando. El `.voxel.json` puede fijar otro valor por modelo.
const MODEL_SCALE := 2

## Grosor en voxeles de 10 cm de la cáscara que sobrevive al vaciado. Dos deja muros de 20 cm.
const SHELL_THICKNESS := 2


static func load_legacy_blueprint(name: String) -> Dictionary:
	var plan: Dictionary = Blueprints.of(name)
	if plan.is_empty():
		return {}
	var fine := {}
	for source_key: Vector3i in plan:
		var material := int(plan[source_key]) + 1 # Runtime reserves palette index 0 for air.
		for dy in 3:
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					fine[Vector3i(source_key.x * 3 + dx, source_key.y * 3 + dy,
						source_key.z * 3 + dz)] = material
	var low := Vector3i(1 << 30, 1 << 30, 1 << 30)
	var high := Vector3i(-(1 << 30), -(1 << 30), -(1 << 30))
	for key: Vector3i in fine:
		low = low.min(key)
		high = high.max(key)
	var dimensions := high - low + Vector3i.ONE
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	var anchors := PackedInt32Array()
	for key: Vector3i in fine:
		var local := key - low
		var index := local.x + local.y * dimensions.x + local.z * dimensions.x * dimensions.y
		cells[index] = fine[key]
		if key.y == 0:
			anchors.append(index)
	var data := VoxelShapeData.new()
	data.set_cells(dimensions, cells)
	var palette := VoxelPalette.new()
	for kind in Vox.COLOR_HEX.size():
		palette.set_material(kind + 1, {
			"color": Vox.color_of(kind),
			"hardness": Vox.TOUGHNESS[kind],
			"density": Vox.MASS_PER_M3 * Vox.DENSITY[kind],
			"friction": 0.9,
			"restitution": 0.02,
			"opacity": 0.35 if kind == Vox.Kind.VIDRIO else 1.0,
			"roughness": 0.12 if kind == Vox.Kind.VIDRIO else 0.85,
			"metallic": 0.55 if kind == Vox.Kind.METAL else 0.0,
		})
	var origin := Vector3(
		(low.x + high.x) * 0.5 * VOXEL_SIZE,
		((low.y + high.y) * 0.5 + 0.5) * VOXEL_SIZE,
		(low.z + high.z) * 0.5 * VOXEL_SIZE
	)
	return {
		"shapes": [{
			"data": data,
			"transform": Transform3D(Basis.IDENTITY, origin),
			"anchors": anchors,
			"anchored": true,
			"model_id": 0,
		}],
		"palette": palette,
		"sidecar": {},
		"source": "blueprint:%s" % name,
		"voxel_size": VOXEL_SIZE,
	}


static func load_asset(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("VoxelAssetImporter: no se pudo abrir %s" % path)
		return {}
	var bytes := file.get_buffer(file.get_length())
	if bytes.size() < 20 or bytes.slice(0, 4).get_string_from_ascii() != "VOX ":
		push_error("VoxelAssetImporter: %s no es un archivo VOX" % path)
		return {}

	var models: Array[Dictionary] = []
	var nodes := {}
	var material_attributes := {}
	var palette := PackedColorArray()
	palette.resize(256)
	palette[0] = Color.TRANSPARENT
	for index in range(1, 256):
		palette[index] = Color(float(index) / 255.0, float(index) / 255.0, float(index) / 255.0)
	var pending_size := Vector3i.ZERO
	var offset := 20
	while offset + 12 <= bytes.size():
		var chunk_id := bytes.slice(offset, offset + 4).get_string_from_ascii()
		var content_size := bytes.decode_s32(offset + 4)
		var content_start := offset + 12
		if content_size < 0 or content_start + content_size > bytes.size():
			push_error("VoxelAssetImporter: chunk %s truncado" % chunk_id)
			return {}
		match chunk_id:
			"SIZE":
				if content_size >= 12:
					pending_size = Vector3i(
						bytes.decode_s32(content_start),
						bytes.decode_s32(content_start + 4),
						bytes.decode_s32(content_start + 8)
					)
			"XYZI":
				if pending_size != Vector3i.ZERO and content_size >= 4:
					var dense := PackedByteArray()
					dense.resize(pending_size.x * pending_size.y * pending_size.z)
					var count := mini(bytes.decode_s32(content_start), (content_size - 4) / 4)
					for voxel_index in count:
						var at := content_start + 4 + voxel_index * 4
						var x: int = bytes[at]
						var y: int = bytes[at + 1]
						var z: int = bytes[at + 2]
						if x < pending_size.x and y < pending_size.y and z < pending_size.z:
							dense[x + y * pending_size.x + z * pending_size.x * pending_size.y] = bytes[at + 3]
					models.append({"size": pending_size, "cells": dense})
					pending_size = Vector3i.ZERO
			"RGBA":
				for color_index in mini(255, content_size / 4):
					var at := content_start + color_index * 4
					palette[color_index + 1] = Color8(
						bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]
					)
			"MATL":
				if content_size >= 8:
					var cursor := {"value": content_start + 4}
					material_attributes[bytes.decode_s32(content_start)] = _read_dictionary(bytes, cursor)
			"nTRN":
				_parse_transform_node(bytes, content_start, nodes)
			"nGRP":
				_parse_group_node(bytes, content_start, nodes)
			"nSHP":
				_parse_shape_node(bytes, content_start, nodes)
		offset = content_start + content_size

	if models.is_empty():
		push_error("VoxelAssetImporter: %s no contiene modelos XYZI" % path)
		return {}
	var sidecar := _load_sidecar(path)
	var runtime_palette := _build_palette(palette, material_attributes, sidecar)
	var instances := _resolve_instances(nodes, models.size())
	var shapes: Array[Dictionary] = []
	for instance: Dictionary in instances:
		var model_id := int(instance.get("model", 0))
		if model_id < 0 or model_id >= models.size():
			continue
		var converted := _convert_and_crop(models[model_id], int(sidecar.get("scale", MODEL_SCALE)))
		if converted.is_empty():
			continue
		var model_transform: Transform3D = instance.get("transform", Transform3D.IDENTITY)
		var dimensions: Vector3i = converted.dimensions
		# The runtime Shape origin is its volume center; y is lifted so its lowest voxel rests at 0.
		model_transform.origin += Vector3(0.0, dimensions.y * VOXEL_SIZE * 0.5, 0.0)
		shapes.append({
			"data": converted.data,
			"transform": model_transform,
			"anchors": converted.anchors,
			"anchored": bool(sidecar.get("anchored", true)),
			"model_id": model_id,
		})
	return {
		"shapes": shapes,
		"palette": runtime_palette,
		"sidecar": sidecar,
		"source": path,
		"voxel_size": VOXEL_SIZE,
	}


static func _convert_and_crop(model: Dictionary, scale: int) -> Dictionary:
	var source_size: Vector3i = model.size
	var source: PackedByteArray = model.cells
	var low := source_size
	var high := Vector3i(-1, -1, -1)
	for z in source_size.z:
		for y in source_size.y:
			for x in source_size.x:
				if source[x + y * source_size.x + z * source_size.x * source_size.y] == 0:
					continue
				# MagicaVoxel z-up -> Godot y-up; its y becomes runtime z.
				var runtime := Vector3i(x, z, y)
				low = low.min(runtime)
				high = high.max(runtime)
	if high.x < low.x:
		return {}
	scale = maxi(1, scale)
	var dimensions := (high - low + Vector3i.ONE) * scale
	var cells := PackedByteArray()
	cells.resize(dimensions.x * dimensions.y * dimensions.z)
	for z in source_size.z:
		for y in source_size.y:
			for x in source_size.x:
				var material: int = source[x + y * source_size.x + z * source_size.x * source_size.y]
				if material == 0:
					continue
				var local := (Vector3i(x, z, y) - low) * scale
				for dy in scale:
					for dz in scale:
						for dx in scale:
							cells[(local.x + dx) + (local.y + dy) * dimensions.x
								+ (local.z + dz) * dimensions.x * dimensions.y] = material
	var data := VoxelShapeData.new()
	if not data.set_cells(dimensions, cells):
		return {}
	# Un edificio se vacía; una farola o un bidón no tienen dentro. El umbral separa los dos casos sin
	# pedirle al artista que marque nada.
	if dimensions.min_axis_index() >= 0 and dimensions[dimensions.min_axis_index()] >= 24:
		data.hollow(SHELL_THICKNESS)
	var anchors := PackedInt32Array()
	for z in dimensions.z:
		for x in dimensions.x:
			var index := x + z * dimensions.x * dimensions.y
			if cells[index] != 0:
				anchors.append(index)
	return {"data": data, "dimensions": dimensions, "anchors": anchors}


static func _build_palette(
	colors: PackedColorArray, material_attributes: Dictionary, sidecar: Dictionary
) -> VoxelPalette:
	var palette := VoxelPalette.new()
	var material_overrides: Dictionary = sidecar.get("materials", {})
	for index in range(1, 256):
		var source: Dictionary = material_attributes.get(index, {})
		var toughness := _toughness_of(colors[index])
		var visual := TeardownPalette.appearance(source, colors[index].a)
		var properties := {
			"color": colors[index],
			"opacity": visual.opacity,
			"roughness": visual.roughness,
			"metallic": visual.metallic,
			"emission": visual.emission,
			"hardness": toughness.hardness,
			"density": toughness.density,
			"friction": 0.9,
			"restitution": 0.02,
		}
		var override: Dictionary = material_overrides.get(str(index), {})
		properties.merge(override, true)
		palette.set_material(index, properties)
	return palette


## Teardown resolves the material from the palette index, which its own art authors on purpose.
## Third-party `.vox` carry arbitrary palettes, so colour is the only signal left: saturation tells
## painted material from bare masonry and value tells dark slate from plaster. Without this every
## imported voxel shared hardness 1.0 and the layered crater degenerated into a single sphere.
static func _toughness_of(color: Color) -> Dictionary:
	if color.s < 0.15:
		if color.v < 0.62:
			return {"hardness": 2.4, "density": 2400.0} # hormigón, pizarra
		return {"hardness": 1.0, "density": 1500.0} # yeso, revoco
	var hue := color.h * 360.0
	if hue >= 170.0 and hue <= 265.0:
		return {"hardness": 0.5, "density": 2500.0} # vidrio
	if hue >= 60.0 and hue < 170.0:
		return {"hardness": 0.6, "density": 500.0} # vegetación, plástico
	if hue >= 15.0 and hue <= 55.0:
		return {"hardness": 1.0, "density": 700.0} # madera
	return {"hardness": 2.0, "density": 2000.0} # ladrillo, teja


static func _resolve_instances(nodes: Dictionary, model_count: int) -> Array[Dictionary]:
	if nodes.is_empty():
		var direct: Array[Dictionary] = []
		for model_id in model_count:
			direct.append({"model": model_id, "transform": Transform3D.IDENTITY})
		return direct
	var referenced := {}
	for node: Dictionary in nodes.values():
		if node.has("child"):
			referenced[node.child] = true
		for child in node.get("children", []):
			referenced[child] = true
	var roots: Array[int] = []
	for node_id: int in nodes:
		if not referenced.has(node_id):
			roots.append(node_id)
	var out: Array[Dictionary] = []
	for root in roots:
		_walk_scene_node(root, Transform3D.IDENTITY, nodes, out)
	return out


static func _walk_scene_node(
	node_id: int, parent_transform: Transform3D, nodes: Dictionary, output: Array[Dictionary]
) -> void:
	if not nodes.has(node_id):
		return
	var node: Dictionary = nodes[node_id]
	var transform := parent_transform * (node.get("transform", Transform3D.IDENTITY) as Transform3D)
	match node.get("type", ""):
		"transform":
			_walk_scene_node(int(node.child), transform, nodes, output)
		"group":
			for child in node.children:
				_walk_scene_node(int(child), transform, nodes, output)
		"shape":
			for model_id in node.models:
				output.append({"model": int(model_id), "transform": transform})


static func _parse_transform_node(bytes: PackedByteArray, start: int, nodes: Dictionary) -> void:
	var cursor := {"value": start}
	var node_id := _read_i32(bytes, cursor)
	_read_dictionary(bytes, cursor)
	var child := _read_i32(bytes, cursor)
	_read_i32(bytes, cursor) # reserved
	_read_i32(bytes, cursor) # layer
	var frame_count := maxi(0, _read_i32(bytes, cursor))
	var transform := Transform3D.IDENTITY
	for frame_index in frame_count:
		var frame := _read_dictionary(bytes, cursor)
		if frame_index == 0:
			transform = _frame_transform(frame)
	nodes[node_id] = {"type": "transform", "child": child, "transform": transform}


static func _parse_group_node(bytes: PackedByteArray, start: int, nodes: Dictionary) -> void:
	var cursor := {"value": start}
	var node_id := _read_i32(bytes, cursor)
	_read_dictionary(bytes, cursor)
	var count := maxi(0, _read_i32(bytes, cursor))
	var children: Array[int] = []
	for _index in count:
		children.append(_read_i32(bytes, cursor))
	nodes[node_id] = {"type": "group", "children": children}


static func _parse_shape_node(bytes: PackedByteArray, start: int, nodes: Dictionary) -> void:
	var cursor := {"value": start}
	var node_id := _read_i32(bytes, cursor)
	_read_dictionary(bytes, cursor)
	var count := maxi(0, _read_i32(bytes, cursor))
	var models: Array[int] = []
	for _index in count:
		models.append(_read_i32(bytes, cursor))
		_read_dictionary(bytes, cursor)
	nodes[node_id] = {"type": "shape", "models": models}


static func _frame_transform(frame: Dictionary) -> Transform3D:
	var translation := Vector3.ZERO
	var encoded: String = frame.get("_t", "")
	var parts := encoded.split(" ", false)
	if parts.size() == 3:
		translation = Vector3(float(parts[0]), float(parts[2]), float(parts[1])) * VOXEL_SIZE
	# Rotation data is preserved by the scene graph parser; identity is used for malformed values.
	var basis := _decode_rotation(int(frame.get("_r", "4")))
	return Transform3D(basis, translation)


static func _decode_rotation(encoded: int) -> Basis:
	var first_axis := encoded & 0x3
	var second_axis := (encoded >> 2) & 0x3
	if first_axis > 2 or second_axis > 2 or first_axis == second_axis:
		return Basis.IDENTITY
	var third_axis := 3 - first_axis - second_axis
	var rows := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	rows[0][first_axis] = -1.0 if encoded & 0x10 else 1.0
	rows[1][second_axis] = -1.0 if encoded & 0x20 else 1.0
	rows[2][third_axis] = -1.0 if encoded & 0x40 else 1.0
	# Convert source z-up basis into Godot y-up by swapping source y/z on both sides.
	var source := Basis(rows[0], rows[1], rows[2]).transposed()
	var swap := Basis(Vector3.RIGHT, Vector3.BACK, Vector3.UP)
	return swap * source * swap.inverse()


static func _read_dictionary(bytes: PackedByteArray, cursor: Dictionary) -> Dictionary:
	var result := {}
	var count := maxi(0, _read_i32(bytes, cursor))
	for _index in count:
		# Las dos lecturas van a variables aparte a propósito: en `result[a()] = b()` GDScript
		# evalúa primero la derecha, y sobre un cursor compartido eso intercambia clave y valor.
		# Con las claves invertidas ni `_t`/`_r` ni `_alpha`/`_rough` se encontraban nunca.
		var key := _read_string(bytes, cursor)
		var value := _read_string(bytes, cursor)
		result[key] = value
	return result


static func _read_string(bytes: PackedByteArray, cursor: Dictionary) -> String:
	var length := maxi(0, _read_i32(bytes, cursor))
	var start: int = cursor.value
	cursor.value = mini(bytes.size(), start + length)
	return bytes.slice(start, cursor.value).get_string_from_utf8()


static func _read_i32(bytes: PackedByteArray, cursor: Dictionary) -> int:
	var position: int = cursor.value
	if position + 4 > bytes.size():
		cursor.value = bytes.size()
		return 0
	cursor.value = position + 4
	return bytes.decode_s32(position)


static func _load_sidecar(path: String) -> Dictionary:
	var sidecar_path := path.get_basename() + ".voxel.json"
	if not FileAccess.file_exists(sidecar_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	if parsed is Dictionary:
		return parsed
	push_warning("VoxelAssetImporter: sidecar inválido %s" % sidecar_path)
	return {}
