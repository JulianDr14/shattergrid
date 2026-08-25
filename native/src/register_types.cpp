#include "voxel_settings.hpp"
#include "voxel_palette.hpp"
#include "voxel_shape_data.hpp"
#include "voxel_brick_pool.hpp"
#include "voxel_runtime_registry.hpp"
#include "voxel_rope_solver.hpp"
#include "voxel_rope_physics_bridge.hpp"
#include "voxel_transform_tracker.hpp"
#include "voxel_collision_installer.hpp"
#include "voxel_map_import_planner.hpp"
#include "voxel_impact_queue.hpp"
#include "voxel_collision_handoff_queue.hpp"
#include "voxel_support_planner.hpp"
#include "voxel_structural_graph.hpp"
#include "voxel_damage_planner.hpp"
#include "voxel_mass_properties.hpp"
#include "voxel_asset_decoder.hpp"
#include "voxel_shadow_update_planner.hpp"
#include "voxel_motion_damage_scanner.hpp"
#include "voxel_map_scene_traversal.hpp"
#include "voxel_map_scene_committer.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_shattergrid_core(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(VoxelShapeData);
    GDREGISTER_CLASS(VoxelBrickPool);
    GDREGISTER_CLASS(VoxelPalette);
    GDREGISTER_CLASS(VoxelPhysicsBudget);
    GDREGISTER_CLASS(VoxelRendererSettings);
    GDREGISTER_CLASS(VoxelRuntimeRegistry);
    GDREGISTER_CLASS(VoxelRopeSolver);
    GDREGISTER_CLASS(VoxelRopePhysicsBridge);
    GDREGISTER_CLASS(VoxelTransformTracker);
    GDREGISTER_CLASS(VoxelCollisionInstaller);
    GDREGISTER_CLASS(VoxelMapImportPlanner);
    GDREGISTER_CLASS(VoxelImpactQueue);
    GDREGISTER_CLASS(VoxelCollisionHandoffQueue);
    GDREGISTER_CLASS(VoxelSupportPlanner);
    GDREGISTER_CLASS(VoxelStructuralGraph);
    GDREGISTER_CLASS(VoxelDamagePlanner);
    GDREGISTER_CLASS(VoxelMassProperties);
    GDREGISTER_CLASS(VoxelAssetDecoder);
    GDREGISTER_CLASS(VoxelShadowUpdatePlanner);
    GDREGISTER_CLASS(VoxelMotionDamageScanner);
    GDREGISTER_CLASS(VoxelMapSceneTraversal);
    GDREGISTER_CLASS(VoxelMapSceneCommitter);
}

static void uninitialize_shattergrid_core(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
}

extern "C" {
GDExtensionBool GDE_EXPORT shattergrid_core_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_shattergrid_core);
    init_obj.register_terminator(uninitialize_shattergrid_core);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}
}
