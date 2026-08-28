class_name VoxelSurfaceAnimation
extends RefCounted
## Parámetros visuales por Shape para materiales que simulan movimiento sobre una superficie.
##
## Las distancias y los offsets están en celdas voxel. El componente no conoce vehículos ni el
## renderer: los productores avanzan los offsets y el renderer observa `revision` para subirlos.

var material_index := 0
var cell_bounds := AABB()
## Paso del patrón, en celdas. El shader reparte un número entero de eslabones sobre el perímetro
## para que el bucle cierre sin junta partida, así que este valor es el paso nominal.
var link_pitch := 4.0
## Chaflán de las esquinas del perfil, en celdas. El shader lo usa para reconocer la capa exterior del
## anillo, que es la única que puede vaciar sin abrir un agujero al hueco interior.
var profile_chamfer := 0.0
var offsets := Vector2.ZERO
var revision := 0


static func create(
	material: int, bounds: AABB, pitch := 4.0, chamfer := 0.0
) -> VoxelSurfaceAnimation:
	var animation := VoxelSurfaceAnimation.new()
	animation.material_index = clampi(material, 0, 255)
	animation.cell_bounds = bounds
	animation.link_pitch = maxf(pitch, 1.0)
	animation.profile_chamfer = maxf(chamfer, 0.0)
	animation.revision = 1
	return animation


## Longitud del bucle que recorre el patrón: el perímetro del perfil, que vive en el plano largo/alto
## del volumen y es un octágono (extremos achaflanados a 45°). Tiene que coincidir al milímetro con el
## que calcula el shader: envolver el offset en otro valor mete un salto de fase en cada vuelta.
func perimeter_cells() -> float:
	var extent := Vector2(cell_bounds.size.x, cell_bounds.size.y) * 0.5 - Vector2.ONE * 0.5
	var chamfer := minf(profile_chamfer, minf(extent.x, extent.y))
	return 2.0 * (2.0 * (extent.x - chamfer) + 2.0 * (extent.y - chamfer)) + 4.0 * chamfer * sqrt(2.0)


func advance(left_cells: float, right_cells: float) -> void:
	var loop := maxf(perimeter_cells(), 1.0)
	set_offsets(
		fposmod(offsets.x + left_cells, loop), fposmod(offsets.y + right_cells, loop)
	)


func set_offsets(left: float, right: float) -> void:
	var next := Vector2(left, right)
	if offsets.is_equal_approx(next):
		return
	offsets = next
	revision += 1


func gpu_parameters() -> Dictionary:
	return {
		"animation": Vector4(offsets.x, offsets.y, float(material_index), 1.0),
		"bounds_min": cell_bounds.position,
		"bounds_max": cell_bounds.end,
		"link_pitch": link_pitch,
		"profile_chamfer": profile_chamfer,
	}
