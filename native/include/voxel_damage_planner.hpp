#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "voxel_shape_data.hpp"

namespace godot {

// Pure damage decisions. Node creation, signals and PhysicsServer changes stay in VoxelWorld3D.
class VoxelDamagePlanner : public Resource {
    GDCLASS(VoxelDamagePlanner, Resource)

protected:
    static void _bind_methods();

public:
    Dictionary damage_shape(const Ref<VoxelShapeData> &p_data, const Vector3 &p_center_voxels,
            double p_radius_voxels, double p_energy, const PackedFloat32Array &p_hardnesses,
            double p_foundation_threshold, bool p_anchored, int p_guard_margin = 16) const;
    Array plan_detached_components(const Array &p_components, int p_particle_voxel_limit) const;
};

} // namespace godot
