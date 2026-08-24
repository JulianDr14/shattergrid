#include "voxel_settings.hpp"
#include "voxel_palette.hpp"
#include "voxel_shape_data.hpp"
#include "voxel_brick_pool.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_voxel_teardown_core(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(VoxelShapeData);
    GDREGISTER_CLASS(VoxelBrickPool);
    GDREGISTER_CLASS(VoxelPalette);
    GDREGISTER_CLASS(VoxelPhysicsBudget);
    GDREGISTER_CLASS(VoxelRendererSettings);
}

static void uninitialize_voxel_teardown_core(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT voxel_teardown_core_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_voxel_teardown_core);
    init_obj.register_terminator(uninitialize_voxel_teardown_core);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
