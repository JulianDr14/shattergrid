#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/transform3d.hpp>

#include "voxel_palette.hpp"
#include "voxel_shape_data.hpp"

namespace godot {

// Main-thread SceneTree commit for an imported voxel shape. Script resources supply the two
// project-specific node classes, while allocation, configuration, parenting and attachment live here.
class VoxelMapSceneCommitter : public Resource {
    GDCLASS(VoxelMapSceneCommitter, Resource)

protected:
    static void _bind_methods();

public:
    Dictionary attach(Object *p_body_script, Object *p_shape_script,
            const Ref<VoxelShapeData> &p_data, const Transform3D &p_transform,
            double p_voxel_size, const Ref<VoxelPalette> &p_palette,
            const Dictionary &p_context, bool p_collides, const Array &p_baked_faces,
            bool p_use_baked_collision, double p_density_scale,
            bool p_collision_enabled, bool p_eager_cache, double p_dynamic_fill_scale,
            int p_body_index, int p_vehicle_visual_index) const;
};

} // namespace godot
