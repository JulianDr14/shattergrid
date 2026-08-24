extends Node3D
## Escena principal, HUD, carga de mapas y herramientas de diagnóstico.

## El mapa opcional de Teardown se resuelve mediante `VOXEL_DESTRUCTION_MAP`,
## `res://external/teardown_maps/lee/main.xml` o `--teardown-map=<ruta>`. Los datos originales no
## forman parte del proyecto. `--no-teardown-map` fuerza el escenario incluido.
## Sin recorte: el mapa entero son 2312 Shapes y 79,3 M de voxeles, y con el atlas por bricks entra
## en 296 MB usando 37 de las 256 capas disponibles. La primera carga compila la colisión en
## `user://`; las siguientes restauran la región inicial y precargan el resto por cercanía.
## `--teardown-radius=<metros>` sigue estando para volver a recortar cuando haga falta medir algo.
const TEARDOWN_MAP_RADIUS := INF
const TEARDOWN_NOTICE := "ESTO ES PROPIEDAD DE TUXEDO LABS — solo investigación, no distribuir"

@onready var _counter: Label = $HUD/Counter
@onready var _voxel_world: VoxelWorld3D = $VoxelWorld

## Alcance del visor de colisiones: es a la vez la distancia a la que se planta el cubo delante de la
## cámara y su medio lado, así que cubre desde los pies hasta el doble de esa distancia hacia donde
## se mira. Se dibuja la malla de triángulos real, cientos de vértices por forma, así que va corto.
const DEBUG_COLLIDER_REACH := 4.0

## Tope de vértices del visor, para que un sitio muy poblado no congele el frame.
const DEBUG_COLLIDER_VERTICES := 300_000

## Nivel nocturno del ambiente voxel. El Lee original llega como atardecer naranja; conservar 0,30
## hacía que bajar el cielo solo oscureciera el fondo mientras los edificios seguían a plena luz.
## 0,12 mantiene siluetas/lectura jugable y deja que las lámparas authored sean las protagonistas.
const AMBIENT_LEVEL := 0.12
const DAYLIGHT_AMBIENT_LEVEL := 0.30

## Cuánto del cielo devuelve el suelo. No se promedia el hemisferio inferior del HDRI aunque esté
## ahí: los cielos de Teardown rellenan la mitad de abajo con una neblina clara — en el atardecer de
## Lee sale al doble de brillo que el cenit — y usarla como rebote deja los bajos de las cosas más
## iluminados que las caras al cielo, que es el relieve al revés. Un rebote es siempre más oscuro
## que lo que lo ilumina.
const GROUND_BOUNCE := 0.45
const NIGHT_BACKGROUND_ENERGY := 0.18
const NIGHT_TONEMAP_EXPOSURE := 0.78
const NIGHT_SUN_ENERGY := 0.22
const NIGHT_FOG_COLOR := Color(0.035, 0.055, 0.105, 1.0)
const NIGHT_MOON_COLOR := Color(0.42, 0.57, 0.92, 1.0)
const NIGHT_AMBIENT_TARGET := Color(0.075, 0.14, 0.31, 1.0)

var _voxel_renderer: VoxelRenderSystem
var _collider_debug: MeshInstance3D
var _collider_debug_origin := Vector3.INF
var _sun_direction := Vector3.INF
var _sun_color := Color.WHITE
var _ambient_sky := Color.BLACK
var _ambient_ground := Color.BLACK
var _benchmark_gpu := PackedFloat64Array()
var _benchmark_cpu := PackedFloat64Array()
var _benchmark_frame_times := PackedFloat64Array()
var _benchmark_process_times := PackedFloat64Array()
var _benchmark_physics_times := PackedFloat64Array()
var _benchmark_physics_active := PackedFloat64Array()
var _benchmark_physics_pairs := PackedFloat64Array()
var _benchmark_physics_islands := PackedFloat64Array()
var _benchmark_frame := 0
var _walk_frame_times := PackedFloat64Array()
var _walk_scroll_times := PackedFloat64Array()
var _walk_upload_bytes := PackedFloat64Array()
var _walk_allocate_times := PackedFloat64Array()
var _walk_raster_times := PackedFloat64Array()
var _walk_region_upload_times := PackedFloat64Array()
var _destruction_frame := 0
var _destruction_frame_times := PackedFloat64Array()
var _destruction_impact_frame_times := PackedFloat64Array()
var _destruction_call_times := PackedFloat64Array()
var _destruction_impact_window := 0
var _destruction_impacts := 0
var _destruction_removed := 0
var _destruction_particles_peak := 0
var _destruction_gpu_times := PackedFloat64Array()
var _destruction_cpu_times := PackedFloat64Array()
var _destruction_transform_sync_times := PackedFloat64Array()
var _destruction_metadata_sync_times := PackedFloat64Array()
var _destruction_collision_flush_times := PackedFloat64Array()
var _shadow_probe_elapsed := 0.0
var _hud_elapsed := 0.0
var _voxel_recount_elapsed := 0.0
var _cached_voxel_total := 0


func _ready() -> void:
	# `debug_collisions_hint` no sirve aquí: el escenario estático lleva una CollisionShape3D por
	# macrocelda, casi un millón en el mapa entero, y pedirle a Godot el wireframe de todas cuelga el
	# arranque. Se dibujan solo las que rodean al jugador, preguntándole a Jolt cuáles son.
	if "--debug-colliders" in OS.get_cmdline_user_args():
		_collider_debug = MeshInstance3D.new()
		_collider_debug.name = "ColliderDebug"
		add_child(_collider_debug)
	# Sin esto `trace_sun_shadow` devuelve 1.0 siempre y no hay una sola sombra en pantalla. Es la
	# misma idea que usa Teardown: trazar el rayo al sol contra un volumen de bits del mundo con
	# mips, no un shadow map. Llenar ese volumen costaba 201 s en el mapa entero cuando lo hacía
	# GDScript voxel a voxel; en C++ y con las macroceldas son 2,7 s, medidos en
	# `tests/clipmap_raster_selftest.gd`. Eso y 134 MB es lo que cuesta, y se paga al cargar.
	_voxel_world.renderer_settings.sun_shadows_enabled = \
		not "--no-voxel-sun-shadows" in OS.get_cmdline_user_args()
	if not _load_teardown_map():
		# Calle en el eje z con el jugador entrando por el sur. Las fachadas miden 12,8 m, así que
		# los 28 m entre aceras dejan una calzada de ancho creíble en vez de casas pegadas.
		for placement: Array in [
			["casa_dos_plantas", Vector3(-14, 0, -8)],
			["casa_barrio", Vector3(-14, 0, 10)],
			["casa_garaje", Vector3(14, 0, -6)],
			["casa_moderna", Vector3(16, 0, 12)],
			["casa_buhardilla", Vector3(-2, 0, -26)],
		]:
			_voxel_world.create_body_from_asset(
				"res://models/%s.vox" % placement[0], Transform3D(Basis.IDENTITY, placement[1])
			)
	_cached_voxel_total = _total_voxel_count()
	_voxel_world.voxel_impact.connect(_on_voxel_impact)
	_voxel_renderer = VoxelRenderSystem.new()
	_voxel_renderer.name = "VoxelRenderSystem"
	add_child(_voxel_renderer)
	if not _voxel_renderer.setup(_voxel_world, $Player/Camera3D):
		push_error("No se pudo iniciar el renderer DDA dedicado")
	# El renderer nace después de importar el mapa, así que la iluminación leída del cielo se guarda
	# y se entrega aquí. Sin mapa no se toca nada y el efecto conserva sus valores por defecto.
	if _sun_direction != Vector3.INF:
		_voxel_renderer.effect.sun_direction = _sun_direction
		_voxel_renderer.effect.sun_color = _sun_color
		# El 1,05 lo llevaba el shader dentro del término difuso; se conserva para no cambiar la
		# exposición al mismo tiempo que se cambia de dónde sale la luz.
		_voxel_renderer.effect.sun_energy = $Sun.light_energy * 1.05
		_voxel_renderer.effect.ambient_sky = _ambient_sky
		_voxel_renderer.effect.ambient_ground = _ambient_ground
	# Activa las métricas GPU que consumen los modos de benchmark.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_refresh.call_deferred()
	if "--capture" in OS.get_cmdline_user_args():
		_capture_migrated_scene.call_deferred()
	if "--visibility-capture" in OS.get_cmdline_user_args():
		_capture_map_visibility.call_deferred()
	if "--water-capture" in OS.get_cmdline_user_args():
		_capture_water.call_deferred()
	if "--benchmark-main" in OS.get_cmdline_user_args():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# Safe by default: the old uncapped benchmark saturated the GPU and made the whole desktop
		# unresponsive. Explicitly add --benchmark-uncapped only on a dedicated profiling run.
		Engine.max_fps = 0 if "--benchmark-uncapped" in OS.get_cmdline_user_args() else 60
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if "--benchmark-walk" in OS.get_cmdline_user_args():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0 if "--benchmark-uncapped" in OS.get_cmdline_user_args() else 60
	if "--benchmark-destruction" in OS.get_cmdline_user_args():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0 if "--benchmark-uncapped" in OS.get_cmdline_user_args() else 60
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if "--benchmark-destruction-no-particles" in OS.get_cmdline_user_args():
		_voxel_world.impact_particles_enabled = false
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0 if "--benchmark-uncapped" in OS.get_cmdline_user_args() else 60
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if "--benchmark-destruction-no-uploads" in OS.get_cmdline_user_args():
		_voxel_world.impact_particles_enabled = false
		_voxel_renderer.damage_uploads_enabled = false
		_voxel_renderer.shadow_clipmaps.damage_updates_enabled = false
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0 if "--benchmark-uncapped" in OS.get_cmdline_user_args() else 60
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if "--clipmap-test" in OS.get_cmdline_user_args():
		_test_clipmaps.call_deferred()
	if "--damage-capture" in OS.get_cmdline_user_args():
		_capture_damage.call_deferred()
	if "--local-shadow-test" in OS.get_cmdline_user_args():
		_test_local_shadows.call_deferred()


## Carga un mapa convertido con `--teardown-map=<ruta a main.xml>`, la variable de entorno
## `VOXEL_DESTRUCTION_MAP` o la ruta local ignorada por Git. `--teardown-radius=<metros>` limita la
## importación. Si no existe el recurso opcional, se conserva el escenario incluido.


func _load_teardown_map() -> bool:
	var path := VoxelProjectPaths.teardown_map_path()
	var radius := TEARDOWN_MAP_RADIUS
	var collision := true
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--teardown-map="):
			path = argument.trim_prefix("--teardown-map=")
		elif argument.begins_with("--teardown-radius="):
			radius = float(argument.trim_prefix("--teardown-radius="))
		elif argument == "--no-teardown-map":
			return false
		elif argument == "--teardown-no-collision":
			collision = false
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var started := Time.get_ticks_msec()
	var report := TeardownMapImporter.import_map(
		_voxel_world, path, Vector3.INF, radius, Vector3.ZERO, collision
	)
	if report.is_empty():
		return false
	# El suelo del banco de pruebas estorba en un mapa real: su malla es un cuadrado de 400 m del
	# mismo gris y su colision un plano infinito en y=0, y el terreno de Lee sube y baja alrededor de
	# esa altura, asi que asomaba por encima en losas de bordes rectos. Pero el plano en si vale como
	# lecho de roca: se le quita la malla y se hunde bajo el punto mas bajo del mapa. Teardown no
	# mete un voxel indestructible — su suelo es `rock`, que ya es indestructible aqui —, pero
	# tampoco deja caer al vacio, y un plano infinito es la red mas barata que hay en Jolt.
	$Ground/Mesh.queue_free()
	$Ground.position.y = _lowest_voxel_y() - 5.0
	_apply_teardown_environment(report.get("environment", {}), path.get_base_dir())
	print("[%s] mapa importado en %d ms: %s"
		% [TEARDOWN_NOTICE, Time.get_ticks_msec() - started, JSON.stringify(report)])
	# Se entra cayendo: el centro de recorte suele caer dentro de un edificio y aterrizar por
	# gravedad evita quedarse encajado en la geometría.
	$Player.global_position = report.get("drop_in", Vector3.UP * 30.0)
	var boundary := _voxel_world.get_node_or_null("TeardownBoundary")
	if boundary != null and boundary.has_method("set_tracked_actor"):
		boundary.set_tracked_actor($Player)
	# La entrada está 30 m sobre el centro para no aparecer dentro de un edificio. Mirar horizontal
	# desde esa altura solo enseña cielo y el Ground, y parecía que el atlas se activaba con el primer
	# disparo cuando en realidad el movimiento de ratón acababa apuntando hacia el mapa.
	$Player/Camera3D.rotation.x = deg_to_rad(-35.0)
	_show_teardown_notice()
	if "--teardown-vehicles" in OS.get_cmdline_user_args():
		_spawn_test_vehicles(path.get_base_dir())
	return true


## Prueba puntual de física: saca tres vehículos del `.vox` compartido del mapa -coche pequeño, SUV
## y muscle car- y los deja caer delante del punto de entrada, ya como cuerpos dinámicos de verdad.
## Solo con `--teardown-vehicles`: no cambia el arranque normal. Igual que el resto del mapa, lee el
## archivo desde su carpeta original fuera del repositorio; no copia ni guarda nada del vehículo.
func _spawn_test_vehicles(map_folder: String) -> void:
	var vox_dir := map_folder.path_join("vox")
	# {etiqueta: [archivo, objeto]}. Cada vehículo de Teardown trae su propio `.vox` -no comparten
	# archivo aunque el nombre del objeto (`shapeNNN`) sea un contador global del mapa.
	var vehicles := {
		"coche pequeño": ["palette22.vox", "shape473", 1.5],
		"suv": ["palette24.vox", "shape500", 2.0],
		"muscle car": ["palette25.vox", "shape527", 2.0],
	}
	var drop: Vector3 = $Player.global_position + $Player.global_transform.basis.z * -4.0
	var offset := 0
	for label: String in vehicles:
		var entry: Array = vehicles[label]
		var vox_path := vox_dir.path_join(entry[0])
		var shape := TeardownMapImporter.load_named_shape(vox_path, entry[1], float(entry[2]))
		if shape == null:
			push_warning("--teardown-vehicles: no se encontró %s (%s) en %s"
				% [label, entry[1], vox_path])
			continue
		var body := VoxelBody3D.new()
		body.name = "TestVehicle_%s" % entry[1]
		body.state = VoxelBody3D.State.DYNAMIC
		_voxel_world.add_child(body)
		body.add_voxel_shape(shape)
		body.global_position = drop + Vector3(float(offset) * 3.5, 3.0, 0.0)
		_voxel_world.register_body(body)
		body.wake_for_interaction()
		offset += 1
	print("[%s] --teardown-vehicles: %d vehículos de prueba soltados junto al punto de entrada"
		% [TEARDOWN_NOTICE, offset])


## Traduce el `<environment>` de Teardown al WorldEnvironment y al sol de la escena.
##
## El `skybox="sunset.dds"` es un HDRI cubemap que vive dentro del juego, no en el volcado del mapa.
## Si al lado del XML hay un `sky_<nombre>.png` — el panorama equirectangular ya convertido, con el
## `skyboxtint` horneado — se usa ese; si no, se tinta el ProceduralSky que la escena trae de serie.
func _apply_teardown_environment(attributes: Dictionary, folder: String) -> void:
	if attributes.is_empty():
		return
	var environment: Environment = $WorldEnvironment.environment
	var night := not "--daylight" in OS.get_cmdline_user_args()
	environment.background_energy_multiplier = NIGHT_BACKGROUND_ENERGY if night else 1.0
	environment.tonemap_exposure = NIGHT_TONEMAP_EXPOSURE if night else 1.0
	var tint := _color(attributes.get("skyboxtint", "1 1 1"))
	var panorama := "%s/sky_%s.png" % [
		folder, attributes.get("skybox", "").get_file().get_basename()
	]
	if FileAccess.file_exists(panorama):
		var texture := ImageTexture.create_from_image(Image.load_from_file(panorama))
		var sky := PanoramaSkyMaterial.new()
		sky.panorama = texture
		environment.sky.sky_material = sky
		# `skyboxrot` gira el cielo entero; Godot lo hace en el Environment, no en el material.
		environment.sky_rotation.y = deg_to_rad(float(attributes.get("skyboxrot", "0")))
		_aim_sun_at_brightest(texture.get_image(), environment.sky_rotation.y)
	else:
		var sky := environment.sky.sky_material as ProceduralSkyMaterial
		if night:
			sky.sky_top_color = Color(0.006, 0.012, 0.035)
			sky.sky_horizon_color = Color(0.025, 0.055, 0.12)
			sky.ground_horizon_color = Color(0.018, 0.032, 0.064)
			sky.ground_bottom_color = Color(0.004, 0.007, 0.015)
		else:
			sky.sky_top_color = tint * 0.35
			sky.sky_horizon_color = tint
			sky.ground_horizon_color = tint * 0.6
			sky.ground_bottom_color = tint * 0.25
	# `fogParams` es "inicio fin intensidad exponente", en metros. Los 0,002 de densidad exponencial
	# que traía la escena tapaban Lee entero: el mapa mide 400 m de lado y la niebla no debe empezar
	# hasta los 80.
	var fog := _floats(attributes.get("fogParams", ""))
	if fog.size() == 4:
		environment.fog_mode = Environment.FOG_MODE_DEPTH
		environment.fog_depth_begin = fog[0]
		environment.fog_depth_end = fog[1]
		environment.fog_density = fog[2]
		environment.fog_depth_curve = fog[3]
	var authored_fog := _color(attributes.get("fogColor", "1 1 1"))
	environment.fog_light_color = authored_fog.lerp(NIGHT_FOG_COLOR, 0.88) \
		if night else authored_fog
	# En Godot la niebla tapa también el cielo, y a distancia infinita lo deja del color de la niebla
	# — el skybox entero convertido en una plancha marrón. En Teardown la niebla es solo del terreno.
	environment.fog_sky_affect = 0.16 if night else 0.0
	# `constant` es la luz ambiente que Teardown suma en las zonas sin sol. En Lee va a cero.
	var ambient := _color(attributes.get("constant", "0 0 0"))
	if night:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = NIGHT_MOON_COLOR
		environment.ambient_light_energy = AMBIENT_LEVEL
	else:
		environment.ambient_light_color = ambient
		environment.ambient_light_energy = maxf(ambient.r, maxf(ambient.g, ambient.b))
	var sun: DirectionalLight3D = $Sun
	# Se ignora `sunColorTint`. En Lee vale "0.2 0.3 1", azul intenso, y aplicado como
	# multiplicador sobre un atardecer da un sol morado. El color creíble es el del propio HDRI, que
	# es de donde Teardown saca también la dirección; si algún mapa lo necesita, aquí es donde entra.
	sun.light_energy = float(attributes.get("sunBrightness", "1")) * (
		NIGHT_SUN_ENERGY if night else 1.0
	)
	if night:
		_sun_color = NIGHT_MOON_COLOR
		sun.light_color = _sun_color
	# `sunSpread` es el radio angular de la fuente en fracción de vuelta; Godot lo quiere en grados.
	sun.light_angular_distance = float(attributes.get("sunSpread", "0")) * 90.0
	var water := _voxel_world.get_node_or_null("TeardownWater") as VoxelWaterSystem
	if water != null:
		# El SSR solo devuelve geometría visible; este color es el fallback cuando el rayo sale de
		# pantalla y debe reflejar cielo. Se deriva del mismo panorama/ProceduralSky, no de una
		# constante azul que rompería el atardecer de Lee.
		var reflected_sky := tint * 0.38
		if _ambient_sky.get_luminance() > 0.001:
			reflected_sky = _ambient_sky * 1.35
		var water_sun_direction := _sun_direction \
			if _sun_direction != Vector3.INF else sun.global_basis.z
		water.configure_environment(
			reflected_sky, water_sun_direction, _sun_color * sun.light_energy
		)


## Teardown no guarda la dirección del sol en el XML: la saca del píxel más brillante del skybox. Se
## hace lo mismo, sobre una copia reducida — buscar en 2048×1024 desde GDScript son dos millones de
## lecturas y el sol ocupa muchos píxeles, así que a 128×64 sale el mismo sitio y es instantáneo.
func _aim_sun_at_brightest(panorama: Image, sky_rotation: float) -> void:
	var image := panorama.duplicate() as Image
	image.resize(128, 64, Image.INTERPOLATE_BILINEAR)
	var direction := Basis(Vector3.UP, sky_rotation) * brightest_direction(panorama)
	var sun: DirectionalLight3D = $Sun
	# La luz viaja hacia la escena, o sea en sentido contrario al sol.
	sun.basis = Basis.looking_at(-direction)
	_sun_direction = direction
	_sun_color = _brightest_color(image)
	sun.light_color = _sun_color
	# Ambiente por hemisferios, promediando el cielo por encima y por debajo del horizonte. Es lo
	# que hace Teardown, que ilumina el ambiente con el skybox, pero sin la oclusión trazada: sin
	# AO el promedio a pelo lava la escena, así que se reescala a la misma exposición que tenía la
	# constante de antes y solo se aprovechan el color y la diferencia arriba/abajo.
	var source_sky := _average_color(image, 0, image.get_height() / 2)
	if "--daylight" in OS.get_cmdline_user_args():
		var source_ground := source_sky * GROUND_BOUNCE
		var source_level := (
			source_sky.get_luminance() + source_ground.get_luminance()
		) * 0.5
		var daylight_scale := DAYLIGHT_AMBIENT_LEVEL / maxf(source_level, 0.001)
		_ambient_sky = source_sky * daylight_scale
		_ambient_ground = source_ground * daylight_scale
	else:
		var ambient := night_ambient_pair(source_sky)
		_ambient_sky = ambient.sky
		_ambient_ground = ambient.ground
	print("[%s] sol a %.1f° de elevación, azimut %.1f°" % [
		TEARDOWN_NOTICE, rad_to_deg(asin(direction.y)),
		rad_to_deg(atan2(direction.x, -direction.z)),
	])


## Conserva parte de la variación del panorama, pero mueve su cromaticidad hacia azul lunar y
## vuelve a normalizar la luminancia. Así la noche no depende de oscurecer albedo o exposición dos
## veces y el hemisferio inferior sigue siendo un rebote más débil.
static func night_ambient_pair(source_sky: Color) -> Dictionary:
	var sky := source_sky.lerp(NIGHT_AMBIENT_TARGET, 0.78)
	var ground := sky * GROUND_BOUNCE * Color(0.62, 0.72, 0.92, 1.0)
	var level := (sky.get_luminance() + ground.get_luminance()) * 0.5
	var scale := AMBIENT_LEVEL / maxf(level, 0.001)
	return {"sky": sky * scale, "ground": ground * scale}


## Color del píxel más brillante, normalizado para que su componente mayor valga 1: el brillo del sol
## es cosa de `sunBrightness`, aquí solo interesa el tono.
static func _brightest_color(image: Image) -> Color:
	var best := Color.BLACK
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.r + pixel.g + pixel.b > best.r + best.g + best.b:
				best = pixel
	var peak := maxf(best.r, maxf(best.g, best.b))
	if peak <= 0.0:
		return Color.WHITE
	return (best / peak).srgb_to_linear()


## Media de un tramo de filas, en lineal. El panorama está en sRGB y el shader trabaja en lineal.
static func _average_color(image: Image, from_row: int, to_row: int) -> Color:
	var total := Color(0, 0, 0)
	var count := 0
	for y in range(from_row, to_row):
		for x in image.get_width():
			total += image.get_pixel(x, y).srgb_to_linear()
			count += 1
	return total / maxi(count, 1)


## Dirección del píxel más brillante de un panorama equirectangular.
static func brightest_direction(panorama: Image) -> Vector3:
	var image := panorama.duplicate() as Image
	image.resize(128, 64, Image.INTERPOLATE_BILINEAR)
	var best := Vector2i.ZERO
	var best_luminance := -1.0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			var luminance := pixel.r + pixel.g + pixel.b
			if luminance > best_luminance:
				best_luminance = luminance
				best = Vector2i(x, y)
	# Equirectangular: la fila va del cenit al nadir y la columna da la vuelta empezando en -Z, que
	# es donde Godot pone el borde izquierdo del panorama.
	var theta := (best.y + 0.5) / float(image.get_height()) * PI
	var phi := (best.x + 0.5) / float(image.get_width()) * TAU
	return Vector3(sin(theta) * sin(phi), cos(theta), sin(theta) * -cos(phi))


## Un "r g b" de Teardown a Color. Vienen en lineal y sin alfa.
static func _color(text: String) -> Color:
	var parts := _floats(text)
	if parts.size() < 3:
		return Color.WHITE
	return Color(parts[0], parts[1], parts[2])


static func _floats(text: String) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for part in text.split(" ", false):
		values.append(float(part))
	return values


## Marca de agua en pantalla mientras el mapa importado esté cargado.
func _show_teardown_notice() -> void:
	var label := Label.new()
	label.text = TEARDOWN_NOTICE
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3, 0.85))
	label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.position -= Vector2(16, 12)
	$HUD.add_child(label)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		get_tree().reload_current_scene()


func _refresh() -> void:
	var metrics := _voxel_world.get_metrics()
	_counter.text = "%d voxeles · %d Bodies despiertos · %d cajas activas (%d total) · %d fps" % [
		_cached_voxel_total,
		int(metrics.awake_bodies),
		int(metrics.awake_compound_boxes),
		int(metrics.compound_boxes),
		Engine.get_frames_per_second(),
	]
	if "--physics-probe" in OS.get_cmdline_user_args():
		_counter.text += "\n" + _probe_under_crosshair()


## Dice qué hay bajo la mira: el cuerpo físico que devuelve Jolt y, aparte, si ahí hay voxeles de
## verdad. Sirve para separar las dos causas de una mancha rara: si Jolt golpea pero no hay voxeles,
## es un collider suelto; si hay voxeles pero Jolt no golpea, es geometría que se dibuja mal.
func _probe_under_crosshair() -> String:
	var camera: Camera3D = $Player/Camera3D
	var from := camera.global_position
	var to := from - camera.global_basis.z * 60.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [$Player.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return "mira: nada a 60 m · pos %.1f %.1f %.1f" % [from.x, from.y, from.z]
	var collider: Node = hit.collider
	var owner_name := collider.name
	var parent := collider.get_parent()
	if parent != null:
		owner_name = "%s/%s" % [parent.name, owner_name]
	var point: Vector3 = hit.position
	return "mira: %s a %.1f m · punto %.1f %.1f %.1f · pos %.1f %.1f %.1f" % [
		owner_name, from.distance_to(point), point.x, point.y, point.z, from.x, from.y, from.z
	]


## Dibuja en verde la malla de colisión que hay delante de la mira. Si una mancha del suelo sale
## enrejada, ahí hay geometría con colisión y lo que falla es el dibujado; si sale limpia, al revés.
##
## El volumen va delante de la cámara y no centrado en el jugador: lo que queda a la espalda no se
## ve, y gastarlo ahí obliga a recortar el alcance justo donde sí se está mirando.
func _refresh_collider_debug() -> void:
	var camera: Camera3D = $Player/Camera3D
	var center := camera.global_position - camera.global_basis.z * DEBUG_COLLIDER_REACH
	# Se rehace al moverse o al girar, que mueven el centro igual: reconstruir la malla en cada frame
	# cuesta bastante más que la consulta.
	if _collider_debug_origin.distance_to(center) < 1.0:
		return
	_collider_debug_origin = center
	var query := PhysicsShapeQueryParameters3D.new()
	var region := BoxShape3D.new()
	region.size = Vector3.ONE * DEBUG_COLLIDER_REACH * 2.0
	query.shape = region
	query.transform = Transform3D(Basis.IDENTITY, center)
	query.exclude = [$Player.get_rid()]
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.1, 1.0, 0.35)
	var vertices := PackedVector3Array()
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 4096):
		var collider := hit.collider as CollisionObject3D
		if collider == null:
			continue
		var node := collider.shape_owner_get_owner(collider.shape_find_owner(int(hit.shape)))
		var collision := node as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		# El escenario estático no son cajas sino una malla de triángulos por macrocelda, así que
		# filtrar por BoxShape3D dejaba el visor vacío. Se dibuja el contorno real y no su caja
		# envolvente: la caja de una malla irregular no dice dónde está la superficie, que es
		# justamente lo que hay que comparar contra lo que se ve.
		var outline: ArrayMesh = collision.shape.get_debug_mesh()
		if outline.get_surface_count() == 0:
			continue
		var transform := collision.global_transform
		for point: Vector3 in outline.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array:
			vertices.append(transform * point)
		if vertices.size() >= DEBUG_COLLIDER_VERTICES:
			break
	if vertices.is_empty():
		_collider_debug.mesh = null
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for point in vertices:
		mesh.surface_add_vertex(point)
	mesh.surface_end()
	_collider_debug.mesh = mesh


func _ropes_node() -> VoxelRopes:
	return _voxel_world.get_node_or_null("TeardownRopes") as VoxelRopes if _voxel_world != null \
		else null


func _ropes_pulling() -> int:
	var ropes := _ropes_node()
	return 0 if ropes == null else ropes.pulling


func _ropes_awake() -> int:
	var ropes := _ropes_node()
	return 0 if ropes == null else ropes.awake_count()


func _process(delta: float) -> void:
	_shadow_probe_elapsed += delta
	if _shadow_probe_elapsed >= 3.0:
		_shadow_probe_elapsed = 0.0
		var rid := get_viewport().get_viewport_rid()
		var clip := _voxel_renderer.shadow_clipmaps if _voxel_renderer != null else null
		var vw := _voxel_world
		print(("PERF fps=%.0f gpu=%.2f cpu_render=%.2f | clipmap scroll=%.2f raster=%.2f subir=%.2f"
			+ " dinamico=%.2f | despiertos=%d cables=%d/%d") % [
			Engine.get_frames_per_second(),
			RenderingServer.viewport_get_measured_render_time_gpu(rid),
			RenderingServer.viewport_get_measured_render_time_cpu(rid)
				+ RenderingServer.get_frame_setup_time_cpu(),
			clip.last_scroll_update_ms if clip != null else 0.0,
			clip.last_region_raster_ms if clip != null else 0.0,
			clip.last_region_upload_ms if clip != null else 0.0,
			clip.last_dynamic_update_ms if clip != null else 0.0,
			vw.awake_bodies if vw != null else 0,
			_ropes_pulling(), _ropes_awake(),
		])
	_hud_elapsed += delta
	if _hud_elapsed >= 0.25:
		_hud_elapsed = 0.0
		_refresh()
	_voxel_recount_elapsed += delta
	if _voxel_recount_elapsed >= 2.0:
		_voxel_recount_elapsed = 0.0
		_cached_voxel_total = _total_voxel_count()
	if _collider_debug != null:
		_refresh_collider_debug()
	if "--benchmark-main" in OS.get_cmdline_user_args():
		_benchmark_frame += 1
		if _benchmark_frame >= 120 and _benchmark_frame < 420:
			var viewport_rid := get_viewport().get_viewport_rid()
			_benchmark_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid))
			_benchmark_cpu.append(
				RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
					+ RenderingServer.get_frame_setup_time_cpu()
			)
			_benchmark_frame_times.append(delta * 1000.0)
			_benchmark_process_times.append(
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			)
			_benchmark_physics_times.append(
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			)
			_benchmark_physics_active.append(
				PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)
			)
			_benchmark_physics_pairs.append(
				PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_COLLISION_PAIRS)
			)
			_benchmark_physics_islands.append(
				PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ISLAND_COUNT)
			)
		elif _benchmark_frame == 420:
			_finish_main_benchmark.call_deferred()
	if "--benchmark-walk" in OS.get_cmdline_user_args():
		_benchmark_frame += 1
		if _benchmark_frame >= 60 and _benchmark_frame < 360:
			$Player.global_position.x += 0.08
			_walk_frame_times.append(delta * 1000.0)
			_walk_scroll_times.append(_voxel_renderer.shadow_clipmaps.last_scroll_update_ms)
			_walk_upload_bytes.append(_voxel_renderer.shadow_clipmaps.last_upload_bytes)
			_walk_allocate_times.append(_voxel_renderer.shadow_clipmaps.last_region_allocate_ms)
			_walk_raster_times.append(_voxel_renderer.shadow_clipmaps.last_region_raster_ms)
			_walk_region_upload_times.append(_voxel_renderer.shadow_clipmaps.last_region_upload_ms)
		elif _benchmark_frame == 360:
			_finish_walk_benchmark.call_deferred()
	if "--benchmark-destruction" in OS.get_cmdline_user_args() \
		or "--benchmark-destruction-no-particles" in OS.get_cmdline_user_args() \
		or "--benchmark-destruction-no-uploads" in OS.get_cmdline_user_args():
		_destruction_frame += 1
		if _destruction_frame >= 90 and _destruction_frame < 330:
			var frame_ms := delta * 1000.0
			_destruction_frame_times.append(frame_ms)
			var viewport_rid := get_viewport().get_viewport_rid()
			_destruction_gpu_times.append(
				RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
			)
			_destruction_cpu_times.append(
				RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
					+ RenderingServer.get_frame_setup_time_cpu()
			)
			_destruction_transform_sync_times.append(_voxel_renderer.last_transform_sync_ms)
			_destruction_metadata_sync_times.append(_voxel_renderer.last_metadata_sync_ms)
			_destruction_collision_flush_times.append(_voxel_world.collision_rebuild_ms)
			if _destruction_impact_window > 0:
				_destruction_impact_frame_times.append(frame_ms)
				_destruction_impact_window -= 1
			var metrics := _voxel_world.get_metrics()
			_destruction_particles_peak = maxi(
				_destruction_particles_peak, int(metrics.active_particles)
			)
			if _destruction_frame <= 222 and (_destruction_frame - 90) % 12 == 0:
				_run_benchmark_impact()
		elif _destruction_frame == 330:
			_finish_destruction_benchmark.call_deferred()


func _capture_migrated_scene() -> void:
	var warmup_frames := 12 if "--capture-fast" in OS.get_cmdline_user_args() else 180
	for _frame in warmup_frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://benchmark/main_migrated.png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("VOXEL_MAIN_CAPTURE path=%s error=%s metrics=%s" % [
		path, error, JSON.stringify(_voxel_world.get_metrics())
	])
	get_tree().quit(0 if error == OK else 20)


func _capture_water() -> void:
	var water := _voxel_world.get_node_or_null("TeardownWater") as VoxelWaterSystem
	if water == null or water.get_surface_count_imported() == 0:
		push_error("--water-capture: el mapa no contiene superficies de agua")
		get_tree().quit(23)
		return
	var water_bounds := water.get_smallest_surface_bounds()
	var target := water_bounds.get_center()
	var player: CharacterBody3D = $Player
	var camera: Camera3D = $Player/Camera3D
	$HUD.visible = false
	_voxel_world.show_diagnostics = false
	player.set_process(false)
	player.set_physics_process(false)
	# La cámara queda justo fuera de la orilla. Antes se colocaba dentro del estanque y la captura
	# era un rectángulo de agua sin referencias: no permitía ver ni espuma, ni refracción, ni tiling.
	var shore_distance := water_bounds.size.z * 0.5 + maxf(3.5, water_bounds.size.z * 0.12)
	var camera_height := clampf(maxf(water_bounds.size.x, water_bounds.size.z) * 0.13, 2.8, 5.5)
	camera.global_position = target + Vector3(0.0, camera_height, shore_distance)
	camera.look_at(target + Vector3(0.0, 0.08, 0.0))
	for _frame in 45:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var capture_name := "water_lee_no_reflections.png" \
		if "--water-no-reflections" in OS.get_cmdline_user_args() else "water_lee.png"
	var path := ProjectSettings.globalize_path("res://benchmark/" + capture_name)
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("VOXEL_WATER_CAPTURE path=%s target=%s error=%s surfaces=%d triangles=%d" % [
		path, target, error, water.get_surface_count_imported(), water.get_triangle_count(),
	])
	get_tree().quit(0 if error == OK else 24)


func _capture_map_visibility() -> void:
	for _frame in 4:
		await get_tree().process_frame
	var best_shape: VoxelShape3D = null
	var best_distance := INF
	for body: VoxelBody3D in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		for shape in body.get_shapes():
			var distance := shape.world_bounds().get_center().distance_squared_to(Vector3.ZERO)
			if distance < best_distance:
				best_distance = distance
				best_shape = shape
	if best_shape == null:
		get_tree().quit(21)
		return
	var target := best_shape.world_bounds().get_center()
	var player: CharacterBody3D = $Player
	var camera: Camera3D = $Player/Camera3D
	# `Player._process` restaura la posicion local de la camara para el trauma. Una captura de
	# diagnostico debe congelar ambos ticks antes de colocarla, o al frame siguiente vuelve a la
	# entrada aerea y deja de servir para revisar materiales.
	player.set_process(false)
	player.set_physics_process(false)
	camera.global_position = target + Vector3(0.0, 3.0, 9.0)
	camera.look_at(target)
	for _frame in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://benchmark/map_visibility.png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("VOXEL_VISIBILITY_CAPTURE path=%s shape=%s error=%s" % [
		path, best_shape.name, error,
	])
	get_tree().quit(0 if error == OK else 22)


func _finish_main_benchmark() -> void:
	var gpu_median := _percentile(_benchmark_gpu, 0.5)
	var gpu_p95 := _percentile(_benchmark_gpu, 0.95)
	var cpu_median := _percentile(_benchmark_cpu, 0.5)
	var frame_median := _percentile(_benchmark_frame_times, 0.5)
	var frame_p95 := _percentile(_benchmark_frame_times, 0.95)
	var result := {
		"resolution": get_viewport().get_visible_rect().size,
		"render_scale": get_viewport().scaling_3d_scale,
		"gpu_median_ms": snappedf(gpu_median, 0.001),
		"gpu_p95_ms": snappedf(gpu_p95, 0.001),
		"cpu_render_median_ms": snappedf(cpu_median, 0.001),
		"process_median_ms": snappedf(_percentile(_benchmark_process_times, 0.5), 0.001),
		"process_p95_ms": snappedf(_percentile(_benchmark_process_times, 0.95), 0.001),
		"physics_median_ms": snappedf(_percentile(_benchmark_physics_times, 0.5), 0.001),
		"physics_p95_ms": snappedf(_percentile(_benchmark_physics_times, 0.95), 0.001),
		"physics_active_median": int(_percentile(_benchmark_physics_active, 0.5)),
		"physics_active_max": int(_percentile(_benchmark_physics_active, 1.0)),
		"physics_pairs_median": int(_percentile(_benchmark_physics_pairs, 0.5)),
		"physics_pairs_max": int(_percentile(_benchmark_physics_pairs, 1.0)),
		"physics_islands_median": int(_percentile(_benchmark_physics_islands, 0.5)),
		"physics_islands_max": int(_percentile(_benchmark_physics_islands, 1.0)),
		"frame_median_ms": snappedf(frame_median, 0.001),
		"frame_p95_ms": snappedf(frame_p95, 0.001),
		"voxel_count": _total_voxel_count(),
		"clipmap_memory_bytes": _voxel_renderer.shadow_clipmaps.total_memory_bytes,
		"pass": gpu_p95 <= 16.7 and frame_p95 <= 16.7,
	}
	print("VOXEL_MAIN_BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0 if result.pass else 30)


func _finish_walk_benchmark() -> void:
	var result := {
		"distance_m": 24.0,
		"frame_median_ms": snappedf(_percentile(_walk_frame_times, 0.5), 0.001),
		"frame_p95_ms": snappedf(_percentile(_walk_frame_times, 0.95), 0.001),
		"frame_max_ms": snappedf(_percentile(_walk_frame_times, 1.0), 0.001),
		"scroll_p95_ms": snappedf(_percentile(_walk_scroll_times, 0.95), 0.001),
		"scroll_max_ms": snappedf(_percentile(_walk_scroll_times, 1.0), 0.001),
		"upload_p95_bytes": int(_percentile(_walk_upload_bytes, 0.95)),
		"allocate_p95_ms": snappedf(_percentile(_walk_allocate_times, 0.95), 0.001),
		"raster_p95_ms": snappedf(_percentile(_walk_raster_times, 0.95), 0.001),
		"region_upload_p95_ms": snappedf(_percentile(_walk_region_upload_times, 0.95), 0.001),
	}
	result["pass"] = result.frame_p95_ms <= 16.7 and result.frame_max_ms <= 33.3
	print("VOXEL_WALK_BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0 if result.pass else 80)


func _run_benchmark_impact() -> void:
	var bodies := get_tree().get_nodes_in_group(VoxelBody3D.GROUP)
	if bodies.is_empty():
		return
	var body := bodies[_destruction_impacts % bodies.size()] as VoxelBody3D
	var shapes := body.get_shapes()
	if shapes.is_empty():
		return
	var shape := shapes[_destruction_impacts % shapes.size()]
	var live := shape.data.get_live_indices()
	if live.is_empty():
		return
	var fraction := float((_destruction_impacts * 37) % 89 + 5) / 100.0
	var voxel_index := live[clampi(int(live.size() * fraction), 0, live.size() - 1)]
	var target := shape.voxel_center_world(voxel_index)
	var started := Time.get_ticks_usec()
	var affected := _voxel_world.damage_sphere(target, 0.72, 10.0)
	var call_ms := (Time.get_ticks_usec() - started) / 1000.0
	_destruction_call_times.append(call_ms)
	var profile := _voxel_world.get_metrics()
	print("VOXEL_DESTRUCTION_IMPACT_PROFILE ", JSON.stringify({
		"body": body.name,
		"dimensions": shape.data.get_dimensions(),
		"call_ms": snappedf(call_ms, 0.001),
		"query_ms": snappedf(float(profile.damage_query_ms), 0.001),
		"native_ms": snappedf(float(profile.damage_native_ms), 0.001),
		"notify_ms": snappedf(float(profile.damage_notify_ms), 0.001),
		"particles_ms": snappedf(float(profile.damage_particles_ms), 0.001),
		"split_ms": snappedf(float(profile.damage_split_ms), 0.001),
		"connectivity_ms": snappedf(float(profile.damage_connectivity_ms), 0.001),
		"external_support_ms": snappedf(
			float(profile.damage_external_support_ms), 0.001
		),
		"component_fill_ms": snappedf(float(profile.damage_component_fill_ms), 0.001),
		"support_contacts_ms": snappedf(float(profile.damage_support_contacts_ms), 0.001),
		"support_routes_ms": snappedf(float(profile.damage_support_routes_ms), 0.001),
		"support_seed_ms": snappedf(float(profile.damage_support_seed_ms), 0.001),
		"support_search_ms": snappedf(float(profile.support_search_ms), 0.001),
		"support_touch_ms": snappedf(float(profile.support_touch_ms), 0.001),
		"support_grid_ms": snappedf(float(profile.support_grid_ms), 0.001),
		"support_touch_calls": int(profile.support_touch_calls),
		"support_nodes": int(profile.support_nodes),
		"support_candidates": int(profile.support_candidates),
		"fragment_ms": snappedf(float(profile.damage_fragment_ms), 0.001),
		"connectivity_guard_ms": snappedf(
			float(profile.damage_connectivity_guard_ms), 0.001
		),
		"connectivity_skipped": int(profile.connectivity_skipped),
		"impulse_ms": snappedf(float(profile.damage_impulse_ms), 0.001),
		"budget_ms": snappedf(float(profile.damage_budget_ms), 0.001),
		"clipmap_ms": snappedf(_voxel_renderer.shadow_clipmaps.last_damage_update_ms, 0.001),
		"atlas_ms": snappedf(_voxel_renderer.last_damage_update_ms, 0.001),
		"collision_ms": snappedf(body.collision_rebuild_ms, 0.001),
		"pending_collision_rebuilds": int(profile.pending_collision_rebuilds),
	}))
	if not affected.is_empty():
		_destruction_impacts += 1
		for record: Dictionary in affected:
			_destruction_removed += int((record.damage as Dictionary).get("removed", 0))
		_destruction_impact_window = 4


func _finish_destruction_benchmark() -> void:
	var frame_p95 := _percentile(_destruction_frame_times, 0.95)
	var frame_max := _percentile(_destruction_frame_times, 1.0)
	var impact_p95 := _percentile(_destruction_impact_frame_times, 0.95)
	var call_p95 := _percentile(_destruction_call_times, 0.95)
	var result := {
		"impacts": _destruction_impacts,
		"removed_voxels": _destruction_removed,
		"particles_peak": _destruction_particles_peak,
		"frame_median_ms": snappedf(_percentile(_destruction_frame_times, 0.5), 0.001),
		"frame_p95_ms": snappedf(frame_p95, 0.001),
		"frame_max_ms": snappedf(frame_max, 0.001),
		"impact_window_p95_ms": snappedf(impact_p95, 0.001),
		"damage_call_p95_ms": snappedf(call_p95, 0.001),
		"gpu_p95_ms": snappedf(_percentile(_destruction_gpu_times, 0.95), 0.001),
		"gpu_max_ms": snappedf(_percentile(_destruction_gpu_times, 1.0), 0.001),
		"cpu_render_p95_ms": snappedf(_percentile(_destruction_cpu_times, 0.95), 0.001),
		"transform_sync_p95_ms": snappedf(
			_percentile(_destruction_transform_sync_times, 0.95), 0.001
		),
		"transform_sync_max_ms": snappedf(
			_percentile(_destruction_transform_sync_times, 1.0), 0.001
		),
		"metadata_sync_max_ms": snappedf(
			_percentile(_destruction_metadata_sync_times, 1.0), 0.001
		),
		"metadata_fallback_reason": _voxel_renderer.last_metadata_fallback_reason,
		"collision_flush_p95_ms": snappedf(
			_percentile(_destruction_collision_flush_times, 0.95), 0.001
		),
		"collision_flush_max_ms": snappedf(
			_percentile(_destruction_collision_flush_times, 1.0), 0.001
		),
		"awake_bodies": int(_voxel_world.get_metrics().awake_bodies),
		"awake_compound_boxes": int(_voxel_world.get_metrics().awake_compound_boxes),
		"total_compound_boxes": int(_voxel_world.get_metrics().compound_boxes),
	}
	result["pass"] = _destruction_impacts >= 8 and _destruction_removed > 0 \
		and _destruction_particles_peak > 0 and impact_p95 <= 33.3 \
		and frame_max <= 66.7 and call_p95 <= 33.3
	print("VOXEL_DESTRUCTION_BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0 if result.pass else 81)


func _percentile(source: PackedFloat64Array, fraction: float) -> float:
	var sorted := Array(source)
	sorted.sort()
	return float(sorted[clampi(ceili((sorted.size() - 1) * fraction), 0, sorted.size() - 1)])


func _total_voxel_count() -> int:
	var total := 0
	for body: VoxelBody3D in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		total += body.get_total_voxels()
	return total


func _on_voxel_impact(_center: Vector3, removed_voxels: int, _radius: float) -> void:
	_cached_voxel_total = maxi(0, _cached_voxel_total - removed_voxels)


func _test_clipmaps() -> void:
	var clipmaps := _voxel_renderer.shadow_clipmaps
	var camera: Camera3D = $Player/Camera3D
	# One metre crosses a snapped 8-cell boundary in L0 without replacing any full volume.
	camera.global_position += Vector3(1.0, 0.0, 0.0)
	for _frame in 3:
		await get_tree().process_frame
	var scroll_bytes := clipmaps.last_scroll_upload_bytes
	var first_body := get_tree().get_nodes_in_group(VoxelBody3D.GROUP)[0] as VoxelBody3D
	var first_shape := first_body.get_shapes()[0]
	var live := first_shape.data.get_live_indices()
	var damage_center := first_shape.voxel_center_world(live[live.size() / 2])
	_voxel_world.damage_sphere(damage_center, 0.25, 20.0)
	var damage_bytes := clipmaps.last_damage_upload_bytes
	var passed := (scroll_bytes > 0 or clipmaps.last_scroll_elided_regions > 0) \
		and scroll_bytes < clipmaps.total_memory_bytes \
		and damage_bytes > 0 and damage_bytes < clipmaps.total_memory_bytes
	print("VOXEL_CLIPMAP_TEST_RESULT ", JSON.stringify({
		"scroll_upload_bytes": scroll_bytes,
		"scroll_elided_regions": clipmaps.last_scroll_elided_regions,
		"damage_upload_bytes": damage_bytes,
		"full_memory_bytes": clipmaps.total_memory_bytes,
		"pass": passed,
	}))
	get_tree().quit(0 if passed else 40)


func _capture_damage() -> void:
	for _frame in 90:
		await get_tree().process_frame
	var camera: Camera3D = $Player/Camera3D
	var target_body := get_tree().get_nodes_in_group(VoxelBody3D.GROUP)[0] as VoxelBody3D
	var target_shape := target_body.get_shapes()[0]
	var live := target_shape.data.get_live_indices()
	var target := target_shape.voxel_center_world(live[live.size() / 2])
	camera.global_position = target + Vector3(0, 2.5, 12.0)
	camera.look_at(target)
	var affected := _voxel_world.damage_sphere(target, 1.0, 20.0)
	for _frame in 18:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://benchmark/main_damage.png")
	var error := get_viewport().get_texture().get_image().save_png(path)
	var metrics := _voxel_world.get_metrics()
	print("VOXEL_DAMAGE_CAPTURE affected=%d bodies=%d particles=%d active=%d error=%s" % [
		affected.size(), get_tree().get_nodes_in_group(VoxelBody3D.GROUP).size(),
		int(metrics.impact_particles), int(metrics.active_particles), error,
	])
	get_tree().quit(0 if error == OK and not affected.is_empty() \
		and int(metrics.impact_particles) > 0 and int(metrics.active_particles) > 0 else 51)


func _test_local_shadows() -> void:
	for index in 9:
		var light := OmniLight3D.new()
		light.position = Vector3(-20.0 + index * 5.0, 3.0, 3.0)
		light.omni_range = 14.0
		light.light_color = Color(1.0, 0.55, 0.25)
		light.light_energy = 2.0
		light.shadow_enabled = false
		add_child(light)
		light.add_to_group("voxel_shadow_lights")
	for _frame in 8:
		await get_tree().process_frame
	var pool := _voxel_renderer.local_shadow_pool
	var textures := pool.get_texture_rids()
	var metadata := pool.get_shader_metadata()
	var passed := textures.size() == VoxelLocalShadowPool.MAX_VOLUMES \
		and textures.all(func(texture: RID) -> bool: return texture.is_valid()) \
		and int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16]) == 9 \
		and int(metadata[VoxelLocalShadowPool.MAX_LIGHTS * 16 + 1]) \
			== VoxelLocalShadowPool.MAX_VOLUMES
	print("VOXEL_LOCAL_SHADOW_TEST_RESULT ", JSON.stringify({
		"lights": 9,
		"active_volumes": textures.size(),
		"logical_resolution": VoxelLocalShadowPool.LOGICAL_RESOLUTION,
		"packed_resolution": VoxelLocalShadowPool.PACKED_RESOLUTION,
		"pass": passed,
	}))
	get_tree().quit(0 if passed else 60)


## El punto mas bajo del mapa ya importado, para colocar el lecho de roca por debajo.
func _lowest_voxel_y() -> float:
	var lowest := INF
	for body in _voxel_world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			lowest = minf(lowest, shape.world_bounds().position.y)
	return 0.0 if is_inf(lowest) else lowest
