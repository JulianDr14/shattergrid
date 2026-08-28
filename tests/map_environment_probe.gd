extends SceneTree
## Comprueba que el `<environment>` del mapa llega al informe y que los nombres de propiedad que usa
## `TeardownEnvironment.apply` existe de verdad en Godot.

var XML := VoxelProjectPaths.teardown_map_path()


func _initialize() -> void:
	var world := VoxelWorld3D.new()
	root.add_child(world)
	# Radio 0: no interesa la geometría, solo el `<environment>`, que es hijo de la raíz del XML.
	var report := TeardownMapImporter.import_map(world, XML, Vector3.ZERO, 0.0, Vector3.ZERO, false)
	var attributes: Dictionary = report.get("environment", {})
	assert(not attributes.is_empty(), "el informe no trae <environment>")
	print("ENVIRONMENT ", attributes)

	var environment := Environment.new()
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_depth_begin = 80.0
	environment.fog_depth_end = 280.0
	environment.fog_depth_curve = 6.0
	environment.fog_density = 1.0
	environment.fog_light_color = Color(0.3, 0.2, 0.08)
	assert(is_equal_approx(environment.fog_depth_end, 280.0))

	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color(0.35, 0.17, 0.07)
	sky.ground_bottom_color = Color(0.25, 0.12, 0.05)
	var sun := DirectionalLight3D.new()
	sun.light_angular_distance = 4.5
	sun.basis = Basis.looking_at(Vector3(-0.58, -0.14, -0.80))
	assert(is_equal_approx(sun.light_angular_distance, 4.5))
	environment.sky = Sky.new()
	environment.sky.sky_material = PanoramaSkyMaterial.new()
	environment.sky_rotation.y = deg_to_rad(130.0)

	# El panorama convertido: mismo sol que reportó el conversor, 7,8° de elevación y 143,9° de
	# azimut antes de aplicar el `skyboxrot`.
	var panorama := XML.get_base_dir() + "/sky_%s.png" % String(attributes.skybox).get_basename()
	assert(FileAccess.file_exists(panorama), "falta el panorama convertido")
	var image := Image.load_from_file(panorama)
	var direction := TeardownEnvironment.brightest_direction(image)
	var elevation := rad_to_deg(asin(direction.y))
	var azimuth := rad_to_deg(atan2(direction.x, -direction.z))
	print("SOL elevacion=%.1f azimut=%.1f" % [elevation, azimuth])
	assert(absf(elevation - 7.8) < 3.0, "el sol no está donde dijo el conversor")
	assert(absf(azimuth - 143.9) < 3.0, "azimut equivocado")

	# La iluminación que se le pasa al shader de voxeles: tono del sol y ambiente por hemisferios.
	var small := image.duplicate() as Image
	small.resize(128, 64, Image.INTERPOLATE_BILINEAR)
	var sun_color := TeardownEnvironment.brightest_color(small)
	var sky_ambient := TeardownEnvironment.average_color(small, 0, 32)
	var night := TeardownEnvironment.night_ambient_pair(sky_ambient)
	var graded_sky: Color = night.sky
	var ground_ambient: Color = night.ground
	print("SOL color=%.2f %.2f %.2f" % [sun_color.r, sun_color.g, sun_color.b])
	print("AMBIENTE cielo=%.3f %.3f %.3f suelo=%.3f %.3f %.3f" % [
		graded_sky.r, graded_sky.g, graded_sky.b,
		ground_ambient.r, ground_ambient.g, ground_ambient.b,
	])
	# Reescalado a la exposición nocturna elegida para el shader.
	var mixed := (graded_sky + ground_ambient) * 0.5
	assert(absf(mixed.get_luminance() - TeardownEnvironment.AMBIENT_LEVEL) < 0.01,
		"exposición movida")
	# El cielo tiene que quedar por encima del rebote del suelo, que es lo que da el relieve.
	assert(graded_sky.get_luminance() > ground_ambient.get_luminance(), "cielo más oscuro que el suelo")
	assert(graded_sky.b > graded_sky.r, "el ambiente nocturno no quedó azulado")
	# El hemisferio inferior del HDRI sí es más brillante que el superior; comprobarlo deja
	# constancia de por qué no se usa como rebote.
	assert(TeardownEnvironment.average_color(small, 32, 64).get_luminance()
		> sky_ambient.get_luminance(), "la neblina de abajo ya no es más brillante")
	print("OK")
	quit()
