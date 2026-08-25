#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace godot {

// Data-only front-end for Teardown maps. It parses XML and performs recursive spatial planning;
// the importer keeps the main-thread SceneTree commit and asset ownership.
class VoxelMapImportPlanner : public Resource {
    GDCLASS(VoxelMapImportPlanner, Resource)

    static void accumulate_centroid(const Dictionary &p_element,
            const Transform3D &p_parent, Vector3 &r_sum, int64_t &r_count);
    static PackedVector3Array find_boundary_recursive(const Dictionary &p_element,
            const Transform3D &p_parent);

protected:
    static void _bind_methods();

public:
    Dictionary parse_xml(const String &p_path) const;
    Dictionary parse_named_vox(const String &p_path) const;
    Vector3 parse_vec3(const String &p_text) const;
    Quaternion parse_rotation(const String &p_text) const;
    PackedFloat32Array parse_float_values(const String &p_text, int p_count) const;
    Vector3 centroid(const Dictionary &p_root, const Transform3D &p_parent) const;
    PackedVector3Array find_boundary_points(
            const Dictionary &p_root, const Transform3D &p_parent) const;
    Dictionary classify_door_joint_records(
            const Array &p_records, const AABB &p_body_bounds) const;
};

} // namespace godot
