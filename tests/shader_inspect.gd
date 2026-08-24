extends SceneTree


const SOURCE := "res://shaders/voxel_dda_dedicated.glsl"


func _init() -> void:
	# `load()` de un .glsl no compila el fuente: devuelve el RDShaderFile que dejó el importador. Si
	# el .glsl se editó fuera del editor, esto valida la versión anterior y da un falso OK — pasó, y
	# el juego se quedó sin dibujar un solo voxel porque el push constant del .res viejo medía 48
	# bytes y el código ya empujaba 112. Arreglo: `godot --headless --import`.
	# Se compara por md5 y no por fecha, que es el criterio del propio importador: reimportar no
	# toca el .res si el contenido no cambió, así que la fecha da falsos positivos.
	var prefix := SOURCE.get_file()
	for file in DirAccess.get_files_at("res://.godot/imported"):
		if file.begins_with(prefix) and file.ends_with(".md5"):
			var record := FileAccess.get_file_as_string("res://.godot/imported/" + file)
			var recorded := record.split('source_md5="')[-1].split('"')[0]
			var actual := FileAccess.get_md5(SOURCE)
			if recorded != actual:
				print("DEDICATED_SHADER_STALE importado=%s fuente=%s — falta `godot --headless "
					% [recorded.left(8), actual.left(8)] + "--import`")
				quit(1)
	var shader_file: RDShaderFile = load(SOURCE)
	print("DEDICATED_SHADER_VERSIONS ", shader_file.get_version_list())
	print("DEDICATED_SHADER_ERROR ", shader_file.base_error)
	for version in shader_file.get_version_list():
		var spirv := shader_file.get_spirv(version)
		print("DEDICATED_SHADER_STAGE_ERRORS version=", version,
			" vertex=", spirv.compile_error_vertex,
			" fragment=", spirv.compile_error_fragment)
	quit(0)
