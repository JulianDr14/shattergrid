extends SceneTree
## Regresión del flujo completo XML -> recentrado -> colisión -> revelado localizado.

const XML := "res://tests/fixtures/boundary_map.xml"
var LEE_XML := VoxelProjectPaths.teardown_map_path()
const TeardownBoundary := preload("res://scripts/teardown_boundary_3d.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var level := Node3D.new()
	root.add_child(level)
	var player := CharacterBody3D.new()
	player.name = "Player"
	var player_collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	player_collision.shape = capsule
	player_collision.position.y = 0.9
	player.add_child(player_collision)
	level.add_child(player)
	var world := VoxelWorld3D.new()
	world.name = "VoxelWorld"
	world.show_diagnostics = false
	level.add_child(world)

	# El cuadrado raw [0,10] se recentra restando (2,3) y luego suma el offset (10,-5).
	var report := TeardownMapImporter.import_map(
		world, XML, Vector3(2.0, 0.0, 3.0), INF, Vector3(10.0, 0.0, -5.0), true
	)
	assert(int(report.boundary_vertices) == 4 and int(report.boundary_segments) == 4,
		"el boundary no produjo sus cuatro paredes")
	assert(is_equal_approx(float(report.boundary_area_m2), 100.0),
		"el área authored cambió al recentrar")
	assert(is_equal_approx(float(report.boundary_width), 10.0) \
		and is_equal_approx(float(report.boundary_depth), 10.0),
		"los bounds importados no miden 10 x 10")
	var boundary := world.get_node_or_null("TeardownBoundary") as TeardownBoundary
	assert(boundary != null, "no se creó TeardownBoundary3D")
	assert(boundary.get_collision_segment_count() == 4,
		"la barrera física no coincide con el polígono")
	var warning := boundary.get_node_or_null("BoundaryWarning") as MeshInstance3D
	assert(warning != null and warning.mesh is ArrayMesh \
		and (warning.mesh as ArrayMesh).get_surface_count() == 1,
		"el warning no quedó agrupado en un draw call")
	var warning_arrays := (warning.mesh as ArrayMesh).surface_get_arrays(0)
	assert((warning_arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array).size() == 16,
		"cada vértice visual perdió el índice de su arista")
	assert(boundary.contains_world_point(Vector3(13.0, 0.0, -3.0)) \
		and not boundary.contains_world_point(Vector3(19.0, 0.0, -3.0)),
		"el punto-en-polígono no usa las coordenadas recentradas")

	player.global_position = Vector3(16.4, 0.0, -3.0)
	player.velocity = Vector3(5.0, 0.0, 0.0)
	boundary._process(0.1)
	assert(boundary.get_reveal_strength() > 0.2 and warning.visible,
		"al acercarse no aparece el tramo local")
	assert(absf(boundary.get_reveal_point().x - 18.0) < 0.05,
		"el warning no marca el punto donde chocará el jugador")
	var warning_material := warning.material_override as ShaderMaterial
	assert(is_equal_approx(float(warning_material.get_shader_parameter("active_segment")), 1.0),
		"el shader no descartó las aristas alejadas")

	player.global_position = Vector3(13.0, 0.0, -6.4)
	await physics_frame
	var collision := player.move_and_collide(Vector3(0.0, 0.0, -4.0))
	assert(collision != null and player.global_position.z > -8.1,
		"la cápsula atravesó la pared invisible")

	# Censa el archivo real sin decodificar su geometría (radio cero y colisión apagada). Así la
	# regresión también avisa si Lee cambia de boundary o si volvemos a confundir shadowVolume.
	if FileAccess.file_exists(LEE_XML):
		var lee_world := VoxelWorld3D.new()
		lee_world.show_diagnostics = false
		root.add_child(lee_world)
		var lee := TeardownMapImporter.import_map(
			lee_world, LEE_XML, Vector3.INF, 0.0, Vector3.ZERO, false
		)
		assert(int(lee.boundary_vertices) == 31,
			"Lee dejó de importar los 31 vértices del boundary")
		assert(absf(float(lee.boundary_width) - 222.8) < 0.02 \
			and absf(float(lee.boundary_depth) - 217.9) < 0.02,
			"los límites de Lee no corresponden al main.xml")
		var lee_boundary := lee_world.get_node("TeardownBoundary") as TeardownBoundary
		assert(lee_boundary.contains_world_point(Vector3.ZERO),
			"el recentrado por defecto dejó el punto de entrada fuera de Lee")
	print("BOUNDARY_SYSTEM_OK vertices=4 area=100 draw_calls=1 collision_segments=4 lee=31")
	quit()
