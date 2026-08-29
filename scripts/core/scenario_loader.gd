class_name ScenarioLoader
extends Node
## Puebla el mundo al arrancar: intenta el mapa de Teardown y, si no esta disponible, levanta el
## barrio incluido. Tambien es el dueño de la pantalla de carga, porque es lo unico que tarda.
##
## El mapa opcional de Teardown se resuelve mediante `SHATTERGRID_MAP`,
## `res://external/teardown_maps/lee/main.xml` o `--teardown-map=<ruta>`. Los datos originales no
## forman parte del proyecto. `--no-teardown-map` fuerza el escenario incluido.

## Sin recorte: el mapa entero son 2312 Shapes y 79,3 M de voxeles, y con el atlas por bricks entra
## en 296 MB usando 37 de las 256 capas disponibles. La primera carga compila la colision en
## `user://`; las siguientes restauran la region inicial y precargan el resto por cercania.
## `--teardown-radius=<metros>` sigue estando para volver a recortar cuando haga falta medir algo.
const TEARDOWN_MAP_RADIUS := INF
const TEARDOWN_NOTICE := "ESTO ES PROPIEDAD DE TUXEDO LABS — solo investigación, no distribuir"

## Calle en el eje z con el jugador entrando por el sur. A 10 cm por voxel las fachadas miden 6,4 m y
## los ejes a x=±7 dejan 7,6 m de calzada, por la que pasa el tanque (3,8 m de ancho).
##
## Solo se repiten estos tres modelos: `casa_moderna` mide 2,4 m de alto y `casa_buhardilla` 3,0 m, o
## sea menos que los 3,31 m del tanque. Son maquetas achatadas de los Metro Minis y junto a ellas el
## tanque parecia gigante; repetir una casa creible engaña menos que alinear un barrio de casetas.
const NEIGHBORHOOD := [
	["casa_dos_plantas", Vector3(-7, 0, -4)],
	["casa_barrio", Vector3(-7, 0, 5)],
	["casa_barrio", Vector3(-7, 0, 14)],
	["casa_garaje", Vector3(7, 0, -3)],
	["casa_dos_plantas", Vector3(7, 0, 6)],
]

## Viva mientras dure el arranque. El renderer la sigue usando despues de importar el mapa, asi que
## el bootstrap la lee y la cierra con `close_loading()` cuando ya no queda nada que tapar.
var loading: LoadingScreen

var _world: VoxelWorld3D
var _player: Node3D
var _camera: Camera3D
var _ground: Node3D
var _world_environment: WorldEnvironment
var _sun: DirectionalLight3D
var _hud: GameHud
var _environment := TeardownEnvironment.new()


func setup(
	world: VoxelWorld3D,
	player: Node3D,
	camera: Camera3D,
	ground: Node3D,
	world_environment: WorldEnvironment,
	sun: DirectionalLight3D,
	hud: GameHud
) -> void:
	_world = world
	_player = player
	_camera = camera
	_ground = ground
	_world_environment = world_environment
	_sun = sun
	_hud = hud


## Devuelve true si quedo cargado el mapa de Teardown, false si se levanto el barrio incluido.
func build() -> bool:
	if await _load_teardown_map():
		return true
	for placement: Array in NEIGHBORHOOD:
		_world.create_body_from_asset(
			"res://assets/models/houses/%s.vox" % placement[0],
			Transform3D(Basis.IDENTITY, placement[1])
		)
	return false


## La iluminacion leida del cielo del mapa se guarda al importar y se entrega al renderer aqui,
## porque el renderer nace despues. Sin mapa no se toca nada y el efecto conserva sus valores por
## defecto.
func apply_environment_to(renderer: VoxelRenderSystem) -> void:
	if _environment.sun_direction == Vector3.INF:
		return
	renderer.effect.sun_direction = _environment.sun_direction
	renderer.effect.sun_color = _environment.sun_color
	# El 1,05 lo llevaba el shader dentro del termino difuso; se conserva para no cambiar la
	# exposicion al mismo tiempo que se cambia de donde sale la luz.
	renderer.effect.sun_energy = _sun.light_energy * 1.05
	renderer.effect.ambient_sky = _environment.ambient_sky
	renderer.effect.ambient_ground = _environment.ambient_ground


## La pantalla tapa el arranque entero: importar el mapa y montar el renderer. Hasta aqui el arbol
## estaba en pausa y la camara apagada para que los frames cedidos no repintasen un mundo a medias.
func close_loading() -> void:
	if loading == null:
		return
	_camera.current = true
	get_tree().paused = false
	loading.queue_free()
	loading = null


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
	# La importacion bloquea el hilo principal durante segundos. La pantalla se dibuja en los frames
	# que el importador cede entre etapas; el arbol se pausa para que nada simule con el mapa a
	# medias, y la camara se apaga para que esos frames no repinten el mundo a medio construir.
	loading = LoadingScreen.new()
	add_child(loading)
	get_tree().paused = true
	_camera.current = false
	await get_tree().process_frame
	# El importador es un tercio del arranque; el resto es el renderer, y lo reparte el bootstrap.
	loading.set_range(0.0, 0.30)
	var report := await TeardownMapImporter.import_map_progressive(
		_world, path, loading.report, Vector3.INF, radius, Vector3.ZERO, collision
	)
	if report.is_empty():
		return false
	# El suelo del banco de pruebas estorba en un mapa real: su malla es un cuadrado de 400 m del
	# mismo gris y su colision un plano infinito en y=0, y el terreno de Lee sube y baja alrededor de
	# esa altura, asi que asomaba por encima en losas de bordes rectos. Pero el plano en si vale como
	# lecho de roca: se le quita la malla y se hunde bajo el punto mas bajo del mapa. Teardown no
	# mete un voxel indestructible — su suelo es `rock`, que ya es indestructible aqui —, pero
	# tampoco deja caer al vacio, y un plano infinito es la red mas barata que hay en Jolt.
	_ground.get_node("Mesh").queue_free()
	_ground.position.y = _lowest_voxel_y() - 5.0
	_environment.apply(
		_world_environment, _sun, _world, report.get("environment", {}), path.get_base_dir(),
		TEARDOWN_NOTICE
	)
	print("[%s] mapa importado en %d ms: %s"
		% [TEARDOWN_NOTICE, Time.get_ticks_msec() - started, JSON.stringify(report)])
	# Se entra cayendo: el centro de recorte suele caer dentro de un edificio y aterrizar por
	# gravedad evita quedarse encajado en la geometria.
	_player.global_position = report.get("drop_in", Vector3.UP * 30.0)
	_player.reset_physics_interpolation()
	var boundary := _world.get_node_or_null("TeardownBoundary")
	if boundary != null and boundary.has_method("set_tracked_actor"):
		boundary.set_tracked_actor(_player)
	# La entrada esta 30 m sobre el centro para no aparecer dentro de un edificio. Mirar horizontal
	# desde esa altura solo enseña cielo y el Ground, y parecia que el atlas se activaba con el
	# primer disparo cuando en realidad el movimiento de raton acababa apuntando hacia el mapa.
	_camera.rotation.x = deg_to_rad(-35.0)
	_hud.show_watermark(TEARDOWN_NOTICE)
	if "--teardown-vehicles" in OS.get_cmdline_user_args():
		_spawn_test_vehicles(path.get_base_dir())
	return true


## Prueba puntual de fisica: saca tres vehiculos del `.vox` compartido del mapa -coche pequeño, SUV
## y muscle car- y los deja caer delante del punto de entrada, ya como cuerpos dinamicos de verdad.
## Solo con `--teardown-vehicles`: no cambia el arranque normal. Igual que el resto del mapa, lee el
## archivo desde su carpeta original fuera del repositorio; no copia ni guarda nada del vehiculo.
func _spawn_test_vehicles(map_folder: String) -> void:
	var vox_dir := map_folder.path_join("vox")
	# {etiqueta: [archivo, objeto]}. Cada vehiculo de Teardown trae su propio `.vox` -no comparten
	# archivo aunque el nombre del objeto (`shapeNNN`) sea un contador global del mapa.
	var vehicles := {
		"coche pequeño": ["palette22.vox", "shape473", 1.5],
		"suv": ["palette24.vox", "shape500", 2.0],
		"muscle car": ["palette25.vox", "shape527", 2.0],
	}
	var drop: Vector3 = _player.global_position + _player.global_transform.basis.z * -4.0
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
		_world.add_child(body)
		body.add_voxel_shape(shape)
		body.global_position = drop + Vector3(float(offset) * 3.5, 3.0, 0.0)
		_world.register_body(body)
		body.wake_for_interaction()
		offset += 1
	print("[%s] --teardown-vehicles: %d vehículos de prueba soltados junto al punto de entrada"
		% [TEARDOWN_NOTICE, offset])


## El punto mas bajo del mapa ya importado, para colocar el lecho de roca por debajo.
func _lowest_voxel_y() -> float:
	var lowest := INF
	for body in _world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			lowest = minf(lowest, shape.world_bounds().position.y)
	return 0.0 if is_inf(lowest) else lowest
