cmake_minimum_required(VERSION 3.22)

project(shattergrid_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)

set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot extension API version" FORCE)
set(GODOTCPP_BUILD_PROFILE "${CMAKE_SOURCE_DIR}/native/build_profile.json" CACHE FILEPATH "Trimmed godot-cpp API" FORCE)

# Pinned instead of following master so a future godot-cpp change cannot silently
# alter the extension ABI. This revision is the current Godot 4.7-compatible head.
FetchContent_Declare(
	godot_cpp
	GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
	GIT_TAG d7b6162249ed52796a8301d216c24ee71d68c2bf
	GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(godot_cpp)

add_library(shattergrid_core SHARED
	native/src/register_types.cpp
	native/src/voxel_shape_data.cpp
	native/src/voxel_brick_pool.cpp
	native/src/voxel_palette.cpp
	native/src/voxel_settings.cpp
)

target_include_directories(shattergrid_core PRIVATE native/include)
target_link_libraries(shattergrid_core PRIVATE godot::cpp)
target_compile_definitions(shattergrid_core PRIVATE GODOT_CPP_NO_THREAD_LOCAL)

if(APPLE)
	set_target_properties(shattergrid_core PROPERTIES
		OUTPUT_NAME "shattergrid_core"
		LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/native/bin"
		BUILD_RPATH "@loader_path"
		INSTALL_RPATH "@loader_path"
	)
endif()
