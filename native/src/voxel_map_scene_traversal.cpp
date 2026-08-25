#include "voxel_map_scene_traversal.hpp"

#include <cmath>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

namespace {

constexpr double PI_VALUE = 3.14159265358979323846;

Transform3D local_transform(const Dictionary &p_element) {
    const Dictionary attributes = p_element.get("attributes", Dictionary());
    const PackedStringArray rotation =
            static_cast<String>(attributes.get("rot", String())).split(" ", false);
    Quaternion quaternion;
    if (rotation.size() == 3) {
        const double roll = rotation[0].to_float() * PI_VALUE / 360.0;
        const double yaw = rotation[1].to_float() * PI_VALUE / 360.0;
        const double pitch = rotation[2].to_float() * PI_VALUE / 360.0;
        const double c1 = std::cos(roll), s1 = std::sin(roll);
        const double c2 = std::cos(yaw), s2 = std::sin(yaw);
        const double c3 = std::cos(pitch), s3 = std::sin(pitch);
        quaternion = Quaternion(s1 * c2 * c3 + c1 * s2 * s3,
                c1 * s2 * c3 + s1 * c2 * s3,
                c1 * c2 * s3 - s1 * s2 * c3,
                c1 * c2 * c3 - s1 * s2 * s3);
    }
    const PackedStringArray position =
            static_cast<String>(attributes.get("pos", String())).split(" ", false);
    Vector3 origin;
    if (position.size() >= 2) {
        origin = Vector3(position[0].to_float(), position[1].to_float(),
                position.size() > 2 ? position[2].to_float() : 0.0);
    }
    return Transform3D(Basis(quaternion), origin);
}

} // namespace

void VoxelMapSceneTraversal::_bind_methods() {
    ClassDB::bind_method(D_METHOD("traverse", "roots", "parent_transform", "context", "visitor"),
            &VoxelMapSceneTraversal::traverse);
}

int VoxelMapSceneTraversal::visit(const Dictionary &p_element, const Transform3D &p_parent,
        const Dictionary &p_context, const Callable &p_visitor) {
    const Transform3D transform = p_parent * local_transform(p_element);
    Dictionary decision = p_visitor.call(p_element, transform, p_context);
    const bool visit_children = decision.get("visit_children", true);
    if (!visit_children) {
        return 1;
    }
    const Dictionary child_context = decision.get("context", p_context);
    const Array children = p_element.get("children", Array());
    int visited = 1;
    for (int index = 0; index < children.size(); ++index) {
        visited += visit(children[index], transform, child_context, p_visitor);
    }
    return visited;
}

int VoxelMapSceneTraversal::traverse(const Array &p_roots, const Transform3D &p_parent,
        const Dictionary &p_context, const Callable &p_visitor) const {
    if (!p_visitor.is_valid()) {
        return 0;
    }
    int visited = 0;
    for (int index = 0; index < p_roots.size(); ++index) {
        visited += visit(p_roots[index], p_parent, p_context, p_visitor);
    }
    return visited;
}

} // namespace godot
