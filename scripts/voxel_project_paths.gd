class_name VoxelProjectPaths
extends RefCounted
## Rutas portables para recursos opcionales que no forman parte del repositorio.

const DEFAULT_TEARDOWN_ROOT := "res://external/teardown_maps/lee"
const DEFAULT_TEARDOWN_MAP := DEFAULT_TEARDOWN_ROOT + "/main.xml"
const DEFAULT_TEARDOWN_VOX_DIR := DEFAULT_TEARDOWN_ROOT + "/vox/"
const TEARDOWN_MAP_ENV := "VOXEL_DESTRUCTION_MAP"


static func teardown_map_path() -> String:
	var configured := OS.get_environment(TEARDOWN_MAP_ENV).strip_edges()
	return configured if not configured.is_empty() else DEFAULT_TEARDOWN_MAP


static func teardown_vox_dir() -> String:
	return teardown_map_path().get_base_dir().path_join("vox") + "/"
