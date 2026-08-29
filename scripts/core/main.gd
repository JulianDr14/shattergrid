extends Node3D
## Bootstrap de la escena: monta las piezas en orden y las conecta entre si. Escenario, HUD, tanque,
## ambiente y herramientas de diagnostico tienen controlador propio; aqui solo se decide quien nace
## antes que quien.
##
## El orden importa y no es negociable: el escenario primero -es lo unico que tarda y lo que fija la
## posicion de entrada del jugador-, el renderer despues -necesita el mundo ya poblado para construir
## atlas y BVH-, y el HUD al final, cuando ya hay algo que contar.

@onready var _voxel_world: VoxelWorld3D = $VoxelWorld
@onready var _hud: GameHud = $HUD

var _scenario: ScenarioLoader
var _voxel_renderer: VoxelRenderSystem
var _diagnostics: MainDiagnostics
var _tank: VoxelTank3D


func _ready() -> void:
	if "--debug-colliders" in OS.get_cmdline_user_args():
		var collider_debug := ColliderDebug3D.new()
		collider_debug.name = "ColliderDebug"
		add_child(collider_debug)
		collider_debug.setup($Player/Camera3D, [($Player as CollisionObject3D).get_rid()])
	# Sin esto `trace_sun_shadow` devuelve 1.0 siempre y no hay una sola sombra en pantalla. Es la
	# misma idea que usa Teardown: trazar el rayo al sol contra un volumen de bits del mundo con
	# mips, no un shadow map. Llenar ese volumen costaba 201 s en el mapa entero cuando lo hacia
	# GDScript voxel a voxel; en C++ y con las macroceldas la rasterizacion pura son 2,9 s
	# (`tests/clipmap_raster_selftest.gd`); repartida entre los cuatro niveles y con los bytes como
	# datos iniciales de la textura, en la escena real son ~2,6 s. Eso y 134 MB cuesta al cargar.
	_voxel_world.renderer_settings.sun_shadows_enabled = \
		not "--no-voxel-sun-shadows" in OS.get_cmdline_user_args()
	_scenario = ScenarioLoader.new()
	_scenario.name = "ScenarioLoader"
	add_child(_scenario)
	_scenario.setup(
		_voxel_world, $Player, $Player/Camera3D, $Ground, $WorldEnvironment, $Sun, _hud
	)
	await _scenario.build()
	_tank = VoxelTank3D.spawn(
		_voxel_world,
		($Player as Node3D).global_position + Vector3(0, 0.2, -14),
		$Player as Node3D
	)
	_voxel_renderer = VoxelRenderSystem.new()
	_voxel_renderer.name = "VoxelRenderSystem"
	add_child(_voxel_renderer)
	var renderer_started := false
	if _scenario.loading != null:
		_scenario.loading.set_range(0.30, 1.0)
		renderer_started = await _voxel_renderer.setup_progressive(
			_voxel_world, $Player/Camera3D, _scenario.loading.report
		)
	else:
		renderer_started = _voxel_renderer.setup(_voxel_world, $Player/Camera3D)
	if not renderer_started:
		push_error("No se pudo iniciar el renderer DDA dedicado")
	_scenario.close_loading()
	_scenario.apply_environment_to(_voxel_renderer)
	# El HUD usa estas metricas tambien fuera de los benchmarks.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_hud.setup(_voxel_world, _voxel_renderer, $Player, $Player/Camera3D)
	_diagnostics = MainDiagnostics.new()
	_diagnostics.name = "MainDiagnostics"
	add_child(_diagnostics)
	_diagnostics.setup(_voxel_world, _voxel_renderer, $Player, _hud)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		get_tree().reload_current_scene()
