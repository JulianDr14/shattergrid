extends SceneTree
## Regresión de importación y batching. No necesita el mapa con licencia ni construye voxeles.

const XML := "res://tests/fixtures/water_map.xml"


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	var report := TeardownMapImporter.import_map(
		world, XML, Vector3.ZERO, INF, Vector3.ZERO, false
	)
	assert(int(report.water_surfaces) == 3, "no se importaron las tres superficies")
	assert(int(report.water_triangles) == 6, "triangulación inesperada")
	assert(absf(float(report.water_area_m2) - 16.0) < 0.01, "área de agua incorrecta")
	assert(int(report.authored_dynamic_bodies) == 1 \
		and int(report.imported_dynamic_bodies) == 1,
		"dynamic=true del XML no llegó al estado inicial del Body")
	assert(int(report.density_overrides) == 1,
		"el multiplicador density authored no llegó a la Shape")
	var imported_prop: VoxelBody3D
	for candidate: VoxelBody3D in world.get_dynamic_bodies():
		imported_prop = candidate
		break
	assert(imported_prop != null and is_equal_approx(
		(imported_prop.get_shapes()[0] as VoxelShape3D).density_scale, 0.25
	), "el prop dinámico perdió density=0.25")

	var water := world.get_node_or_null("TeardownWater") as VoxelWaterSystem
	assert(water != null, "el importador no creó VoxelWaterSystem")
	assert(water.mesh is ArrayMesh, "el agua no usa ArrayMesh")
	assert((water.mesh as ArrayMesh).get_surface_count() == 1,
		"las superficies del mapa no quedaron en un solo draw call")
	var shore := water.get_node_or_null("ShoreFoam") as MeshInstance3D
	assert(shore != null and shore.mesh is ArrayMesh \
		and (shore.mesh as ArrayMesh).get_surface_count() == 1,
		"las orillas no quedaron agrupadas en una sola banda de espuma")
	var arrays := (water.mesh as ArrayMesh).surface_get_arrays(0)
	assert((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 12,
		"se perdieron vértices al agrupar")
	assert((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() == 18,
		"índices de agua incorrectos")
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	for index in 4:
		assert(is_equal_approx(vertices[index].y, 2.0),
			"la rotación Y inclinó una superficie horizontal")

	var material := water.material_override as ShaderMaterial
	assert(material != null and material.shader != null, "falta el shader de agua")
	var normal_texture := material.get_shader_parameter("wave_normal") as Texture2D
	assert(normal_texture != null and normal_texture.get_width() == 128,
		"falta la normal procedural compacta")
	var normal_image := normal_texture.get_image()
	var transpose_difference := 0.0
	for y in range(0, 128, 8):
		for x in range(0, 128, 8):
			var a := normal_image.get_pixel(x, y)
			var b := normal_image.get_pixel(y, x)
			transpose_difference += absf(a.r - b.r) + absf(a.b - b.b)
	assert(transpose_difference > 4.0,
		"la normal conserva una simetría diagonal/cuadrada demasiado visible")
	water.set_reflections_enabled(false)
	assert(not bool(material.get_shader_parameter("reflections_enabled")),
		"el modo económico no desactiva SSR")
	water.configure_environment(Color(0.2, 0.3, 0.4), Vector3.UP, Color(1, 0.8, 0.5))
	assert((material.get_shader_parameter("sky_reflection_color") as Vector3).is_equal_approx(
		Vector3(0.2, 0.3, 0.4)
	), "el fallback no recibe el cielo del mapa")
	var surface := water.sample_surface(Vector3(10.0, 8.0, 20.0))
	assert(not surface.is_empty() and is_equal_approx(float(surface.surface_y), 2.0),
		"la consulta física no encuentra la altura exacta del agua")
	assert(water.is_point_in_water(Vector3(10.0, 1.5, 20.0)) \
		and not water.is_point_in_water(Vector3(10.0, 0.5, 20.0)),
		"IsPointInWater no respeta depth=1")
	assert(water.sample_surface(Vector3(100.0, 0.0, 100.0)).is_empty(),
		"la consulta de agua se sale del polígono")
	water.emit_splash(Vector3(10.0, 2.02, 20.0), 1.0)
	water._process(0.1)
	assert(water.splash_count == 1 \
		and (water.get_node("WaterRipples") as MultiMeshInstance3D).visible,
		"una entrada al agua no crea splash y onda en el pool")

	# Radio cero se usa en varias pruebas que solo leen environment: no debe crear agua ni obligar
	# a compilar el shader en esos procesos auxiliares.
	var empty_world := VoxelWorld3D.new()
	root.add_child(empty_world)
	var cropped := TeardownMapImporter.import_map(
		empty_world, XML, Vector3.ZERO, 0.0, Vector3.ZERO, false
	)
	assert(int(cropped.water_surfaces) == 0, "el recorte espacial no excluyó el agua")
	assert(empty_world.get_node_or_null("TeardownWater") == null,
		"se creó un renderer vacío fuera del recorte")
	print("WATER_SYSTEM_OK surfaces=%d triangles=%d area=%.1f water_draw=1 shore_draw=1 normal=128"
		% [report.water_surfaces, report.water_triangles, report.water_area_m2])
	quit()
