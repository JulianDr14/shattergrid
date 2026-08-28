class_name VoxelAssetImporter
extends RefCounted
## MagicaVoxel importer for the 10 cm runtime representation.
##
## SIZE/XYZI/RGBA/MATL provide dense voxel and material data. nTRN/nGRP/nSHP are parsed into
## Shape transforms instead of baking multiple objects into one wasteful bounding volume.

const VOXEL_SIZE := 0.1

## Cuántos voxeles de 10 cm ocupa cada voxel del `.vox` de origen.
##
## La escala del proyecto es 1 voxel = 10 cm y vale para todo el mapa por igual: casas, props y
## tanque comparten rejilla, así que un modelo de 64 voxeles de alto mide 6,4 m y el tanque, de 78
## voxeles de largo, mide 7,8 m. Antes las casas entraban a 2 (20 cm por voxel de origen) y salían
## de 12,8 m: cuatro veces la altura del tanque, que es lo que hacía irreconocible el barrio.
##
## Contrapartida conocida de los Metro Minis: están modelados como maqueta, con puertas de 12
## voxeles, y a esta escala miden 1,2 m — el jugador de 1,8 m no entra por ellas. Es un defecto del
## arte de origen, no de la escala; el `.voxel.json` de un modelo concreto puede fijar otro valor.
const MODEL_SCALE := 1

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
	var sidecar := _load_sidecar(path)
	var decoded: Dictionary = VoxelAssetDecoder.new().decode(
		path, int(sidecar.get("scale", MODEL_SCALE)), SHELL_THICKNESS, VOXEL_SIZE
	)
	if not bool(decoded.get("ok", false)):
		push_error("VoxelAssetImporter: no se pudo decodificar %s (%s)" % [
			path, decoded.get("error", "unknown")
		])
		return {}
	var shapes: Array = decoded.get("shapes", [])
	for shape: Dictionary in shapes:
		shape["anchored"] = bool(sidecar.get("anchored", true))
	return {
		"shapes": shapes,
		"palette": _build_palette(decoded.colors, decoded.material_attributes, sidecar),
		"sidecar": sidecar,
		"source": path,
		"voxel_size": VOXEL_SIZE,
	}


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


static func _load_sidecar(path: String) -> Dictionary:
	var sidecar_path := path.get_basename() + ".voxel.json"
	if not FileAccess.file_exists(sidecar_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(sidecar_path))
	if parsed is Dictionary:
		return parsed
	push_warning("VoxelAssetImporter: sidecar inválido %s" % sidecar_path)
	return {}
