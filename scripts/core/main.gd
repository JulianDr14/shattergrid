extends Node3D
## Bootstrap de la escena, HUD y carga de mapas. Tanques, ambiente y herramientas de diagnóstico
## tienen controladores propios para que este archivo solo coordine su ciclo de vida.

## El mapa opcional de Teardown se resuelve mediante `SHATTERGRID_MAP`,
## `res://external/teardown_maps/lee/main.xml` o `--teardown-map=<ruta>`. Los datos originales no
## forman parte del proyecto. `--no-teardown-map` fuerza el escenario incluido.
## Sin recorte: el mapa entero son 2312 Shapes y 79,3 M de voxeles, y con el atlas por bricks entra
## en 296 MB usando 37 de las 256 capas disponibles. La primera carga compila la colisión en
## `user://`; las siguientes restauran la región inicial y precargan el resto por cercanía.
## `--teardown-radius=<metros>` sigue estando para volver a recortar cuando haga falta medir algo.
const TEARDOWN_MAP_RADIUS := INF
const LoadingScreenScene := preload("res://scripts/core/loading_screen.gd")
const TEARDOWN_NOTICE := "ESTO ES PROPIEDAD DE TUXEDO LABS — solo investigación, no distribuir"

var _loading: Node

@onready var _counter: Label = $HUD/Counter
@onready var _voxel_world: VoxelWorld3D = $VoxelWorld

## Alcance del visor de colisiones: es a la vez la distancia a la que se planta el cubo delante de la
## cámara y su medio lado, así que cubre desde los pies hasta el doble de esa distancia hacia donde
## se mira. Se dibuja la malla de triángulos real, cientos de vértices por forma, así que va corto.
const DEBUG_COLLIDER_REACH := 4.0

## Tope de vértices del visor, para que un sitio muy poblado no congele el frame.
const DEBUG_COLLIDER_VERTICES := 300_000

var _voxel_renderer: VoxelRenderSystem
var _collider_debug: MeshInstance3D
var _collider_debug_origin := Vector3.INF
var _environment := TeardownEnvironment.new()
var _diagnostics: MainDiagnostics
var _tank: VoxelTank3D
var _shadow_probe_elapsed := 0.0
var _hud_elapsed := 0.0
var _render_audit_elapsed := 0.0
var _cached_render_audit := {}
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
	# GDScript voxel a voxel; en C++ y con las macroceldas la rasterización pura son 2,9 s
	# (`tests/clipmap_raster_selftest.gd`); repartida entre los cuatro niveles y con los bytes como
	# datos iniciales de la textura, en la escena real son ~2,6 s. Eso y 134 MB cuesta al cargar.
	_voxel_world.renderer_settings.sun_shadows_enabled = \
		not "--no-voxel-sun-shadows" in OS.get_cmdline_user_args()
	if not await _load_teardown_map():
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
				"res://assets/models/houses/%s.vox" % placement[0], Transform3D(Basis.IDENTITY, placement[1])
			)
	_tank = VoxelTank3D.spawn(
		_voxel_world,
		($Player as Node3D).global_position + Vector3(0, 0.2, -14),
		$Player as Node3D
	)
	_cached_voxel_total = _total_voxel_count()
	_voxel_world.voxel_impact.connect(_on_voxel_impact)
	_voxel_renderer = VoxelRenderSystem.new()
	_voxel_renderer.name = "VoxelRenderSystem"
	add_child(_voxel_renderer)
	var renderer_started := false
	if _loading != null:
		_loading.set_range(0.30, 1.0)
		renderer_started = await _voxel_renderer.setup_progressive(
			_voxel_world, $Player/Camera3D, _loading.report
		)
	else:
		renderer_started = _voxel_renderer.setup(_voxel_world, $Player/Camera3D)
	if not renderer_started:
		push_error("No se pudo iniciar el renderer DDA dedicado")
	_close_loading_screen()
	# El renderer nace después de importar el mapa, así que la iluminación leída del cielo se guarda
	# y se entrega aquí. Sin mapa no se toca nada y el efecto conserva sus valores por defecto.
	if _environment.sun_direction != Vector3.INF:
		_voxel_renderer.effect.sun_direction = _environment.sun_direction
		_voxel_renderer.effect.sun_color = _environment.sun_color
		# El 1,05 lo llevaba el shader dentro del término difuso; se conserva para no cambiar la
		# exposición al mismo tiempo que se cambia de dónde sale la luz.
		_voxel_renderer.effect.sun_energy = $Sun.light_energy * 1.05
		_voxel_renderer.effect.ambient_sky = _environment.ambient_sky
		_voxel_renderer.effect.ambient_ground = _environment.ambient_ground
	# El HUD usa estas métricas también fuera de los benchmarks.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_refresh.call_deferred()
	_diagnostics = MainDiagnostics.new()
	_diagnostics.name = "MainDiagnostics"
	add_child(_diagnostics)
	_diagnostics.setup(_voxel_world, _voxel_renderer, $Player, $HUD)


## Carga un mapa convertido con `--teardown-map=<ruta a main.xml>`, la variable de entorno
## `SHATTERGRID_MAP` o la ruta local ignorada por Git. `--teardown-radius=<metros>` limita la
## importación. Si no existe el recurso opcional, se conserva el escenario incluido.


## La pantalla tapa el arranque entero: importar el mapa y montar el renderer. Hasta aquí el árbol
## estaba en pausa y la cámara apagada para que los frames cedidos no repintasen un mundo a medias.
func _close_loading_screen() -> void:
	if _loading == null:
		return
	$Player/Camera3D.current = true
	get_tree().paused = false
	_loading.queue_free()
	_loading = null


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
	# La importación bloquea el hilo principal durante segundos. La pantalla se dibuja en los frames
	# que el importador cede entre etapas; el árbol se pausa para que nada simule con el mapa a
	# medias, y la cámara se apaga para que esos frames no repinten el mundo a medio construir.
	_loading = LoadingScreenScene.new()
	add_child(_loading)
	get_tree().paused = true
	$Player/Camera3D.current = false
	await get_tree().process_frame
	# El importador es un tercio del arranque; el resto es el renderer, y lo reparte `_ready`.
	_loading.set_range(0.0, 0.30)
	var report := await TeardownMapImporter.import_map_progressive(
		_voxel_world, path, _loading.report, Vector3.INF, radius, Vector3.ZERO, collision
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
	_environment.apply(
		$WorldEnvironment,
		$Sun,
		_voxel_world,
		report.get("environment", {}),
		path.get_base_dir(),
		TEARDOWN_NOTICE
	)
	print("[%s] mapa importado en %d ms: %s"
		% [TEARDOWN_NOTICE, Time.get_ticks_msec() - started, JSON.stringify(report)])
	# Se entra cayendo: el centro de recorte suele caer dentro de un edificio y aterrizar por
	# gravedad evita quedarse encajado en la geometría.
	$Player.global_position = report.get("drop_in", Vector3.UP * 30.0)
	$Player.reset_physics_interpolation()
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
	var viewport_rid := get_viewport().get_viewport_rid()
	var fps := Engine.get_frames_per_second()
	_counter.text = ("%d voxeles · %d Bodies despiertos · %d cajas activas (%d total) · %d fps\n"
		+ "frame %.1f ms · física %.1f ms · GPU %.1f ms · CPU render %.1f ms · cables %d activos/%d tirando") % [
		_cached_voxel_total,
		int(metrics.awake_bodies),
		int(metrics.awake_compound_boxes),
		int(metrics.compound_boxes),
		fps,
		1000.0 / maxf(1.0, float(fps)),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
		RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
			+ RenderingServer.get_frame_setup_time_cpu(),
		_ropes_awake(),
		_ropes_pulling(),
	]
	if _voxel_renderer != null:
		# El censo recorre las 2.321 entradas de Lee y consulta sus poses. Se conserva a 1 Hz; el HUD
		# se repinta a 4 Hz, pero repetir el mismo diagnóstico cuatro veces solo fabrica picos de CPU.
		if _cached_render_audit.is_empty():
			_cached_render_audit = _voxel_renderer.get_coherence_snapshot()
		var render_audit := _cached_render_audit
		_counter.text += "\nrender %s · Shapes %d/%d · poses %d/%d" % [
			String(render_audit.get("status", "DESYNC")),
			int(render_audit.get("renderer_entries", 0)),
			int(render_audit.get("live_shapes", 0)),
			(render_audit.get("effect_pose_mismatches", []) as Array).size(),
			(render_audit.get("settled_pose_mismatches", []) as Array).size(),
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
		print(("PERF fps=%.0f gpu=%.2f cpu_render=%.2f | clipmap raster=%.2f subir=%.2f"
			+ " dinamico=%.2f | despiertos=%d cables=%d/%d") % [
			Engine.get_frames_per_second(),
			RenderingServer.viewport_get_measured_render_time_gpu(rid),
			RenderingServer.viewport_get_measured_render_time_cpu(rid)
				+ RenderingServer.get_frame_setup_time_cpu(),
			clip.last_region_raster_ms if clip != null else 0.0,
			clip.last_region_upload_ms if clip != null else 0.0,
			clip.last_dynamic_update_ms if clip != null else 0.0,
			vw.awake_bodies if vw != null else 0,
			_ropes_pulling(), _ropes_awake(),
		])
	_hud_elapsed += delta
	_render_audit_elapsed += delta
	if _voxel_renderer != null and _render_audit_elapsed >= 1.0:
		_render_audit_elapsed = 0.0
		_cached_render_audit = _voxel_renderer.get_coherence_snapshot()
	if _hud_elapsed >= 0.25:
		_hud_elapsed = 0.0
		_refresh()
	_voxel_recount_elapsed += delta
	if _voxel_recount_elapsed >= 2.0:
		_voxel_recount_elapsed = 0.0
		_cached_voxel_total = _total_voxel_count()
	if _collider_debug != null:
		_refresh_collider_debug()

func _total_voxel_count() -> int:
	var total := 0
	for body: VoxelBody3D in get_tree().get_nodes_in_group(VoxelBody3D.GROUP):
		total += body.get_total_voxels()
	return total


func _on_voxel_impact(_center: Vector3, removed_voxels: int, _radius: float) -> void:
	_cached_voxel_total = maxi(0, _cached_voxel_total - removed_voxels)

## El punto mas bajo del mapa ya importado, para colocar el lecho de roca por debajo.
func _lowest_voxel_y() -> float:
	var lowest := INF
	for body in _voxel_world.get_children():
		if not (body is VoxelBody3D):
			continue
		for shape: VoxelShape3D in (body as VoxelBody3D).get_shapes():
			lowest = minf(lowest, shape.world_bounds().position.y)
	return 0.0 if is_inf(lowest) else lowest
