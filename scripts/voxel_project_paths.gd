class_name VoxelProjectPaths
extends RefCounted
## Rutas portables para recursos opcionales que no forman parte del repositorio.

const DEFAULT_TEARDOWN_ROOT := "res://external/teardown_maps/lee"
const DEFAULT_TEARDOWN_MAP := DEFAULT_TEARDOWN_ROOT + "/main.xml"
## Disposición usada durante desarrollo: ambos repositorios viven como carpetas hermanas dentro de
## `Documents/Godot`. Se globaliza porque `res://..` queda fuera del árbol de recursos del proyecto.
const DEVELOPMENT_TEARDOWN_MAP := "res://../teardown_maps/lee/main.xml"
const DEFAULT_TEARDOWN_VOX_DIR := DEFAULT_TEARDOWN_ROOT + "/vox/"
const TEARDOWN_MAP_ENV := "SHATTERGRID_MAP"


static func teardown_map_path() -> String:
	var configured := OS.get_environment(TEARDOWN_MAP_ENV).strip_edges()
	if not configured.is_empty():
		return configured
	if FileAccess.file_exists(DEFAULT_TEARDOWN_MAP):
		return DEFAULT_TEARDOWN_MAP
	var development_map := ProjectSettings.globalize_path(DEVELOPMENT_TEARDOWN_MAP)
	return development_map if FileAccess.file_exists(development_map) else DEFAULT_TEARDOWN_MAP


static func teardown_vox_dir() -> String:
	return teardown_map_path().get_base_dir().path_join("vox") + "/"
