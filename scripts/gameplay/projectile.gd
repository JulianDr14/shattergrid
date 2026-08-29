class_name Projectile
extends Node3D
## Proyectil de cañón: dardo de voxeles con balística integrada a mano y trazado por barrido.
##
## No es un `RigidBody3D`: a cientos de m/s Jolt tendría que hacer CCD contra medio mapa cada paso
## para un objeto que no rebota, no rueda y no se apila. Aquí la trayectoria se integra (gravedad
## más rozamiento cuadrático) y cada frame se lanza un rayo del punto anterior al nuevo, así que no
## puede atravesar una pared por ir rápido.
##
## El "tipo" de proyectil es su ficha de datos, no una subclase: velocidad de boca, rozamiento,
## penetración y carga. Con esos cuatro números salen las tres familias reales sin una línea de
## código extra: el AP de aquí es agujero estrecho + mucha penetración; un HE sería `penetration`
## casi cero y un radio de estallido grande; un HEAT, penetración corta y carga media. Añadir uno
## es añadir una entrada a `AMMO`.

## Fichas. `pierce_*` y `blast_*` hablan el idioma de `VoxelShapeData::damage_sphere`: el radio es
## el del hueco en material blando y la energía es cuánto empuja la herramienta frente a la dureza
## (`radio * min(1, energía/dureza)`). Un AP es por tanto radio de dardo y energía muy por encima
## de cualquier dureza —perfora hormigón igual que madera—, y la carga que va detrás es lo
## contrario: radio ancho y energía de bomba.
const AMMO := {
	"ap": {
		"label": "AP 120 mm",
		## Velocidad de boca. La real de un 120 mm de energía cinética son 1.750 m/s, con la que
		## un blanco a 200 m se recibe en 0,11 s: ni se ve el trazador ni la caída llega al
		## centímetro. A 420 m/s el disparo tarda medio segundo, cae metro y pico en esos 200 m y
		## la elevación pasa a importar. Es EL número que se toca para calibrar el tiro.
		"speed": 420.0,
		## Retardo aerodinámico k de `a = k·v²`, en 1/m. Sale de `0,5·ρ·Cd·A/m` con el aire a
		## 1,225 kg/m³, Cd 0,3 (supersónico), 120 mm de calibre y 10 kg de proyectil.
		"drag_k": 0.0002,
		## Metros de material que atraviesa a velocidad de boca y en impacto perpendicular.
		"penetration": 2.2,
		"pierce_radius": 0.34,
		"pierce_energy": 90.0,
		"blast_radius": 3.2,
		"blast_energy": 14.0,
		## Calibre real, en metros. Es lo que mide la barra del modelo `.vox`, así que de ahí sale
		## el tamaño del voxel con el que se dibuja el dardo entero.
		"caliber": 0.12,
		"tracer_color": Color(1.0, 0.62, 0.22),
		## Largo de la llama del trazador que va detrás del culote, no del proyectil.
		"tracer_length": 0.55,
	},
}

const GRAVITY := 9.81
## Un disparo que no le da a nada acaba cayendo, pero si sale hacia arriba tarda en volver. Sin
## esto se quedan proyectiles integrando para siempre fuera del mapa.
const MAX_LIFE := 12.0

var _stats := {}
var _velocity := Vector3.ZERO
var _muzzle_speed := 1.0
var _drag_k := 0.0
var _exclude: Array[RID] = []
var _age := 0.0


## Mete un proyectil en el mundo saliendo por `muzzle` (convenio de Godot: `-basis.z` adelante).
## `exclude` son los cuerpos del que dispara: el bocacho está a medio metro del cañón y sin esto el
## primer rayo se clava en la propia torreta. `carrier_velocity` es la del arma, que el proyectil
## hereda como cualquier cosa disparada desde un vehículo en marcha.
static func spawn(
	world: VoxelWorld3D, muzzle: Transform3D, kind := "ap",
	exclude: Array[RID] = [], carrier_velocity := Vector3.ZERO
) -> Projectile:
	var stats: Dictionary = AMMO.get(kind, {})
	if world == null or not is_instance_valid(world) or stats.is_empty():
		return null
	var shell := Projectile.new()
	shell.name = "Projectile"
	shell._stats = stats
	shell._exclude = exclude
	shell._muzzle_speed = float(stats.speed)
	shell._drag_k = float(stats.drag_k)
	shell._velocity = -muzzle.basis.z * shell._muzzle_speed + carrier_velocity
	world.add_child(shell)
	shell.global_position = muzzle.origin
	shell._orient()
	return shell


## El modelo del dardo, hecho en MagicaVoxel: punta endurecida, barra de tungsteno, aletas y
## trazador, cada tramo con su índice de paleta. La silueta se cambia en el `.vox`, no aquí.
const MODEL_PATH := "res://assets/models/tank/proyectil_ap.vox"
## Voxeles de ancho que tiene la barra en el modelo. El calibre de la ficha se reparte entre ellos,
## así que un 120 mm sale con la barra de 120 mm sin números mágicos sueltos.
const MODEL_BODY_VOXELS := 5

## Se decodifica una vez por partida, no una por disparo: parsear el `.vox` cuesta milisegundos y
## salen decenas de proyectiles por minuto.
static var _model: Dictionary = {}


static func model() -> Dictionary:
	if _model.is_empty():
		_model = VoxelAssetImporter.load_asset(MODEL_PATH)
	return _model


func _ready() -> void:
	var caliber := float(_stats.get("caliber", 0.12))
	var unit := caliber / float(MODEL_BODY_VOXELS)
	var length := unit
	for view in _build_dart(unit):
		add_child(view)
		if view.has_meta("dart_length"):
			length = float(view.get_meta("dart_length"))
	add_child(_build_tracer(caliber, length))


## El dardo en dos MultiMesh —acero y trazador— porque lo emisivo no puede ir con lo sombreado en el
## mismo material, y con eso todo el proyectil son dos dibujados. El decodificador ya deja el modelo
## en ejes de Godot, con la proa del `.vox` en -Z, que es lo que `_orient` alinea con la marcha.
func _build_dart(unit: float) -> Array[MultiMeshInstance3D]:
	var asset := model()
	var shapes: Array = asset.get("shapes", [])
	var palette: VoxelPalette = asset.get("palette")
	if shapes.is_empty() or palette == null:
		push_error("Projectile: no se pudo cargar %s" % MODEL_PATH)
		return []
	var data: VoxelShapeData = shapes[0].data
	var dimensions := data.get_dimensions()
	var cells := data.get_cells()
	var center := Vector3(dimensions - Vector3i.ONE) * 0.5
	var steel: Array[Vector3] = []
	var steel_tint: PackedColorArray = []
	var glow: Array[Vector3] = []
	var glow_tint: PackedColorArray = []
	for index in data.get_live_indices():
		var material := int(cells[index])
		var cell := Vector3i(
			index % dimensions.x,
			(index / dimensions.x) % dimensions.y,
			index / (dimensions.x * dimensions.y)
		)
		var properties := palette.get_material(material)
		var offset := (Vector3(cell) - center) * unit
		if float(properties.get("emission", 0.0)) > 0.0:
			glow.append(offset)
			glow_tint.append(properties.get("color", Color.WHITE))
		else:
			steel.append(offset)
			steel_tint.append(properties.get("color", Color.WHITE))

	var metal := StandardMaterial3D.new()
	metal.vertex_color_use_as_albedo = true
	metal.metallic = 0.85
	metal.roughness = 0.4
	var burning := StandardMaterial3D.new()
	burning.vertex_color_use_as_albedo = true
	burning.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var views: Array[MultiMeshInstance3D] = [_batch(steel, steel_tint, unit, metal)]
	views[0].set_meta("dart_length", float(dimensions.z) * unit)
	if not glow.is_empty():
		views.append(_batch(glow, glow_tint, unit, burning))
	return views


func _batch(
	offsets: Array[Vector3], colors: PackedColorArray, unit: float, material: Material
) -> MultiMeshInstance3D:
	var cube := BoxMesh.new()
	cube.size = Vector3.ONE * unit
	cube.material = material
	var grid := MultiMesh.new()
	grid.transform_format = MultiMesh.TRANSFORM_3D
	grid.use_colors = true
	grid.mesh = cube
	grid.instance_count = offsets.size()
	for index in offsets.size():
		grid.set_instance_transform(index, Transform3D(Basis.IDENTITY, offsets[index]))
		grid.set_instance_color(index, colors[index])
	var view := MultiMeshInstance3D.new()
	view.multimesh = grid
	# Ni proyecta ni recibe sombra: son 12 cm que cruzan la pantalla en dos frames y no valen un
	# dibujado extra del sol.
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return view


## El trazador: la llama que arde detrás del culote. Va aparte del modelo porque no es parte del
## proyectil sino su estela, y es lo único que deja seguir el tiro a ojo.
func _build_tracer(caliber: float, dart_length: float) -> MeshInstance3D:
	var color: Color = _stats.get("tracer_color", Color(1.0, 0.6, 0.2))
	var length := float(_stats.get("tracer_length", 0.5))
	var flame := BoxMesh.new()
	flame.size = Vector3(caliber * 0.55, caliber * 0.55, length)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = color
	glow.emission_enabled = true
	glow.emission = color
	glow.emission_energy_multiplier = 6.0
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var view := MeshInstance3D.new()
	view.mesh = flame
	view.material_override = glow
	view.position = Vector3(0.0, 0.0, (dart_length + length) * 0.5)
	view.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return view


func _physics_process(delta: float) -> void:
	_age += delta
	if _age > MAX_LIFE:
		queue_free()
		return
	# A estas velocidades el rozamiento que manda es el cuadrático; el lineal de Stokes solo vale
	# para gotas de niebla. Integración explícita: con paso de física fijo y v² el error queda muy
	# por debajo de la dispersión que tendría el cañón de verdad.
	_velocity += (Vector3.DOWN * GRAVITY - _velocity * (_velocity.length() * _drag_k)) * delta
	var from := global_position
	var to := from + _velocity * delta
	var hit := _cast(from, to)
	if not hit.is_empty():
		_detonate(hit.get("position", to), hit.get("normal", Vector3.UP))
		return
	global_position = to
	_orient()


func _cast(from: Vector3, to: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = _exclude
	query.collide_with_areas = false
	# ponytail: el mundo hornea la colisión estática alrededor del jugador
	# (`BAKED_COLLISION_PREFETCH_RADIUS`, 80 m). Un disparo más largo que eso puede atravesar un
	# edificio que todavía no tiene cajas. Si aparece, aquí va un `prime_baked_static_collision`
	# sobre el segmento antes del rayo.
	return space.intersect_ray(query)


## Impacto: perfora y detona detrás. Es lo que hace un AP con espoleta de culote —la de retardo
## real ronda el milisegundo, o sea menos de un frame a 60 Hz, así que el retardo no se simula con
## un temporizador: se simula con la distancia a la que se pone el centro de la carga.
func _detonate(point: Vector3, normal: Vector3) -> void:
	var world := get_parent() as VoxelWorld3D
	if world == null or not is_instance_valid(world):
		queue_free()
		return
	var direction := _velocity.normalized()
	# Penetración: la energía cinética va con v², y el impacto oblicuo obliga a atravesar más
	# blindaje para avanzar lo mismo. De refilón el dardo apenas muerde y la carga revienta en la
	# cara del blanco, que es exactamente lo que pasa en la realidad.
	var punch := clampf(_velocity.length() / _muzzle_speed, 0.0, 1.0)
	var bite := clampf(-direction.dot(normal), 0.0, 1.0)
	var depth: float = float(_stats.penetration) * punch * punch * bite
	var pierce_radius := float(_stats.pierce_radius)
	var pierce_energy := float(_stats.pierce_energy)
	# El canal de entrada, no un cráter: esferas encadenadas a lo largo del eje del disparo. Cuatro
	# como mucho, porque cada `damage_sphere` arrastra su análisis estructural.
	var steps := clampi(ceili(depth / maxf(pierce_radius * 1.6, 0.01)), 1, 4)
	for step in steps:
		var along := depth * float(step) / float(steps)
		world.damage_sphere(
			point + direction * along, pierce_radius, pierce_energy, {"cause": "impact"}
		)
	Explosion.at(
		world, point + direction * depth, float(_stats.blast_radius), float(_stats.blast_energy)
	)
	queue_free()


## Alinea el trazador con la marcha. `looking_at` revienta si la dirección es paralela al eje que
## se le da de referencia, y un disparo antiaéreo vertical es justo ese caso.
func _orient() -> void:
	if _velocity.length_squared() < 0.0001:
		return
	var forward := _velocity.normalized()
	var reference := Vector3.UP if absf(forward.y) < 0.99 else Vector3.FORWARD
	global_basis = Basis.looking_at(forward, reference)
