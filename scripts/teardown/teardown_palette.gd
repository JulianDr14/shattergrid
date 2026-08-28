class_name TeardownPalette
extends RefCounted
## Índice de paleta -> material, tal y como lo hace Teardown.
##
## Teardown no adivina el material por el color: reserva bandas fijas de 8 índices en la paleta y
## el índice manda. Teardown-Converter reordena la paleta al exportar (`FIX_PALETTE_MAPPING`) para
## que cada material caiga en su banda, con la fila 31 en los índices bajos:
##
##     fila = 31 - (índice - 1) / 8
##
## Es una señal exacta, no una inferencia, así que para los `.vox` del mapa sustituye a la
## heurística HSV de `VoxelAssetImporter._toughness_of`, que solo existe porque los `.vox` de
## terceros traen paletas arbitrarias.

## Las 32 filas en el orden en que las escribe el conversor (fila 0 abajo del todo en MagicaVoxel).
const ROWS := [
	"none", "reserved", "unphysical", "unphysical", "reserved", "reserved", "reserved", "reserved",
	"ice", "hardmasonry", "hardmetal", "plastic", "plastic", "heavymetal", "heavymetal", "metal",
	"metal", "plaster", "plaster", "masonry", "masonry", "masonry", "masonry", "wood",
	"wood", "rock", "rock", "dirt", "dirt", "foliage", "foliage", "glass",
]

## `hardness` en la escala de `damage_sphere_material`: divide el radio del boquete, con 1.0 como
## material blando de referencia. Las cuatro clases de `MakeHole` de Teardown (blando, medio, duro,
## indestructible) salen de agrupar estas filas. `density` va en kg/m3.
const MATERIALS := {
	"glass": {"hardness": 0.5, "density": 2500.0, "opacity": 0.35, "roughness": 0.1},
	"foliage": {"hardness": 0.6, "density": 300.0},
	"dirt": {"hardness": 0.7, "density": 1500.0},
	"ice": {"hardness": 0.7, "density": 900.0, "opacity": 0.6, "roughness": 0.15},
	"plastic": {"hardness": 0.8, "density": 900.0},
	"wood": {"hardness": 1.0, "density": 700.0},
	"plaster": {"hardness": 1.0, "density": 1200.0},
	"masonry": {"hardness": 2.0, "density": 2000.0},
	"metal": {"hardness": 2.4, "density": 7800.0, "metallic": 0.8, "roughness": 0.35},
	"hardmasonry": {"hardness": 4.0, "density": 2600.0},
	"hardmetal": {"hardness": 4.5, "density": 7900.0, "metallic": 0.9, "roughness": 0.25},
	# Teardown deja roca y metal pesado fuera de las tres esferas de `MakeHole`: no se agujerean.
	"rock": {"hardness": 1000000.0, "density": 2700.0},
	"heavymetal": {"hardness": 1000000.0, "density": 8000.0, "metallic": 0.9, "roughness": 0.3},
	# Decorado sin física propia (vallas de fondo, letreros). Se trata como yeso para que ceda.
	"unphysical": {"hardness": 1.0, "density": 1200.0},
	"none": {"hardness": 1.0, "density": 1200.0},
	"reserved": {"hardness": 1.0, "density": 1200.0},
}


## `IMAP` es la tabla de reindexado de MagicaVoxel, y en los `.vox` del conversor NO es la
## identidad: los voxeles llevan indices compactados desde el 1 y el indice real de la banda esta en
## `IMAP`. Sin traducirlo, el terreno de Lee (16 M de voxeles en el indice 1) entraba como `glass` de
## dureza 0,5 en vez de `rock` indestructible — el suelo del mapa se abria de un click. Los ficheros
## cuya paleta ya venia ordenada por bandas traen IMAP identidad, asi que esto no los cambia.
static func banded_index(index: int, imap: PackedByteArray) -> int:
	if imap.size() < 255 or index < 1 or index > 255:
		return index
	return imap[index - 1]


static func material_name(index: int, imap := PackedByteArray()) -> String:
	var banded := banded_index(index, imap)
	if banded < 1 or banded > 255:
		return "none"
	return ROWS[31 - (banded - 1) / 8]


## La apariencia y el material fisico son dos ejes independientes en Teardown. El indice decide
## dureza/densidad; `MATL` decide si esa misma muestra se ve mate, metalica, emisiva o como vidrio.
## Es valido, por ejemplo, que el indice fisico 1 (glass) tenga apariencia `_metal` y sea opaco.
static func appearance(attributes: Dictionary, fallback_alpha := 1.0) -> Dictionary:
	var kind: String = attributes.get("_type", "_diffuse")
	var roughness := clampf(float(attributes.get("_rough", 1.0)), 0.0, 1.0)
	var result := {
		"opacity": 1.0,
		"roughness": roughness,
		"metallic": 0.0,
		"emission": 0.0,
	}
	match kind:
		"_glass":
			# MagicaVoxel stores 100 % transparency as alpha=1. Teardown explicitly treats that
			# value as opaque; any lower value enables una unica apariencia de vidrio, sin
			# graduar la transparencia entre 0 y 99.
			var alpha := clampf(float(attributes.get("_alpha", fallback_alpha)), 0.0, 1.0)
			result.opacity = 1.0 if alpha >= 0.999 else 0.35
			result.roughness = 0.08
		"_metal":
			result.metallic = clampf(float(
				attributes.get("_metal", attributes.get("_weight", 0.0))
			), 0.0, 1.0)
		"_emit":
			# `_emit` is the emissive amount and `_flux` its power. Keep the runtime value in
			# Teardown's documented 0..32 material range.
			result.emission = clampf(
				float(attributes.get("_emit", attributes.get("_weight", 0.0)))
					* maxf(1.0, float(attributes.get("_flux", 1.0))) * 8.0,
				0.0, 32.0
			)
		"_diffuse":
			result.roughness = 1.0
	return result


## Materiales que el jugador atraviesa siempre. `unphysical` es la categoria del propio Teardown
## para el decorado sin fisica: vallas de fondo, letreros, y esas imperfecciones que alguien puso de
## adorno en el suelo y que nunca se penso que se pisaran. Darles malla no solo pesa — convierte un
## adorno del suelo en un escalon. Se siguen dibujando y rompiendo igual; solo salen de la malla
## que recibe Jolt.
##
## `foliage` entra entero: en el original el jugador camina por el suelo y la hierba no le levanta
## la camara. Se intento distinguir hierba de arbusto por la altura de la Shape y no vale — en Lee
## los hierbajos vienen dentro de Shapes altas y seguian colisionando.
##
## Limitación conocida: los arbustos grandes tampoco bloquean al jugador. Distinguirlos exige
## medir la altura de cada columna de follaje, una consulta reservada para la ruta nativa.
const WALK_THROUGH := ["unphysical", "foliage"]


## Una entrada por indice de paleta, 0 = atravesable. Va como metadato de la paleta porque solo vale
## para las paletas convertidas de Teardown: en un `.vox` de terceros la banda del indice no
## significa nada, y sin metadato `build_macro_faces` colisiona con todo, como hasta ahora.
static func collide_mask(walk_through: Array, imap := PackedByteArray()) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(256)
	for index in range(1, 256):
		mask[index] = 0 if material_name(index, imap) in walk_through else 1
	return mask


static func mask_for(shape: VoxelShape3D) -> PackedByteArray:
	if shape.palette == null:
		return PackedByteArray()
	return shape.palette.get_meta("collide_mask", PackedByteArray())


## Construye la `VoxelPalette` de un `.vox` del mapa: color/apariencia de RGBA+MATL y propiedades
## fisicas de la banda de indice oficial de Teardown.
static func build(colors: PackedColorArray, material_attributes: Dictionary,
		imap := PackedByteArray()) -> VoxelPalette:
	var palette := VoxelPalette.new()
	palette.set_meta("collide_mask", collide_mask(WALK_THROUGH, imap))
	# Se guarda para que las sondas puedan nombrar el material de un voxel sin volver a abrir el
	# `.vox`: sin el IMAP, `material_name` de un indice crudo miente.
	palette.set_meta("imap", imap)
	for index in range(1, 256):
		var traits: Dictionary = MATERIALS[material_name(index, imap)]
		var visual := appearance(material_attributes.get(index, {}), 1.0)
		palette.set_material(index, {
			"color": colors[index],
			"opacity": visual.opacity,
			"roughness": visual.roughness,
			"metallic": visual.metallic,
			"emission": visual.emission,
			"hardness": traits.hardness,
			"density": traits.density,
			"friction": 0.9,
			"restitution": 0.02,
		})
	return palette
