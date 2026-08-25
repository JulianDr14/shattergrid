#include "voxel_mass_properties.hpp"

#include <algorithm>
#include <vector>

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

namespace {

struct ShapeMass {
    double mass = 0.0;
    Vector3 center;
    Vector3 inertia;
    Basis axes;
};

} // namespace

void VoxelMassProperties::_bind_methods() {
    ClassDB::bind_method(D_METHOD("calculate", "shapes", "vehicle"),
            &VoxelMassProperties::calculate);
    ClassDB::bind_method(D_METHOD("apply", "body", "shapes", "vehicle"),
            &VoxelMassProperties::apply);
    ClassDB::bind_static_method("VoxelMassProperties",
            D_METHOD("damping_for_inertia", "inertia"),
            &VoxelMassProperties::damping_for_inertia);
}

Dictionary VoxelMassProperties::calculate(const Array &p_shapes, bool p_vehicle) const {
    std::vector<ShapeMass> entries;
    entries.reserve(static_cast<size_t>(p_shapes.size()));
    double total_mass = 0.0;
    Vector3 weighted_center;
    for (int index = 0; index < p_shapes.size(); ++index) {
        Node3D *shape = Object::cast_to<Node3D>(p_shapes[index]);
        if (shape == nullptr || !shape->has_method("mass_properties")) {
            continue;
        }
        const Dictionary properties = shape->call("mass_properties");
        ShapeMass entry;
        entry.mass = static_cast<double>(properties.get("mass", 0.0));
        entry.center = shape->get_transform().xform(
                static_cast<Vector3>(properties.get("center", Vector3())));
        entry.inertia = properties.get("inertia", Vector3(1.0, 1.0, 1.0));
        entry.axes = shape->get_transform().basis.orthonormalized();
        total_mass += entry.mass;
        weighted_center += entry.center * entry.mass;
        entries.push_back(entry);
    }
    Dictionary result;
    result["valid"] = total_mass > 0.0;
    if (total_mass <= 0.0) {
        return result;
    }
    Vector3 center = weighted_center / total_mass;
    if (p_vehicle) {
        center.y -= std::min(0.35, std::max(0.0, static_cast<double>(center.y) - 0.45));
    }
    Vector3 summed;
    for (const ShapeMass &entry : entries) {
        const Basis &axes = entry.axes;
        Vector3 rotated(
                axes.get_column(0).x * axes.get_column(0).x * entry.inertia.x +
                        axes.get_column(1).x * axes.get_column(1).x * entry.inertia.y +
                        axes.get_column(2).x * axes.get_column(2).x * entry.inertia.z,
                axes.get_column(0).y * axes.get_column(0).y * entry.inertia.x +
                        axes.get_column(1).y * axes.get_column(1).y * entry.inertia.y +
                        axes.get_column(2).y * axes.get_column(2).y * entry.inertia.z,
                axes.get_column(0).z * axes.get_column(0).z * entry.inertia.x +
                        axes.get_column(1).z * axes.get_column(1).z * entry.inertia.y +
                        axes.get_column(2).z * axes.get_column(2).z * entry.inertia.z);
        const Vector3 offset = entry.center - center;
        rotated += entry.mass * Vector3(
                offset.y * offset.y + offset.z * offset.z,
                offset.x * offset.x + offset.z * offset.z,
                offset.x * offset.x + offset.y * offset.y);
        summed += rotated;
    }
    const Vector3 inertia = summed.max(Vector3(0.0001, 0.0001, 0.0001));
    result["mass"] = total_mass;
    result["center"] = center;
    result["inertia"] = inertia;
    result["damping"] = p_vehicle ? Vector2() : damping_for_inertia(inertia);
    return result;
}

bool VoxelMassProperties::apply(
        RigidBody3D *p_body, const Array &p_shapes, bool p_vehicle) const {
    if (p_body == nullptr) {
        return false;
    }
    const Dictionary properties = calculate(p_shapes, p_vehicle);
    if (!static_cast<bool>(properties.get("valid", false))) {
        return false;
    }
    p_body->set_mass(properties["mass"]);
    p_body->set_center_of_mass_mode(RigidBody3D::CENTER_OF_MASS_MODE_CUSTOM);
    p_body->set_center_of_mass(properties["center"]);
    p_body->set_inertia(properties["inertia"]);
    if (!p_vehicle) {
        const Vector2 damping = properties["damping"];
        if (damping.y > 0.0) {
            p_body->set_linear_damp(damping.x);
            p_body->set_angular_damp(damping.y);
        }
    }
    return true;
}

Vector2 VoxelMassProperties::damping_for_inertia(const Vector3 &p_inertia) {
    const double smallest = std::max(0.0001,
            static_cast<double>(std::min(p_inertia.x, std::min(p_inertia.y, p_inertia.z))));
    const double largest = std::max(p_inertia.x, std::max(p_inertia.y, p_inertia.z));
    const double ratio = largest / smallest;
    if (ratio >= 8.0) {
        return Vector2(0.36, 3.8);
    }
    if (ratio >= 4.0) {
        return Vector2(0.20, 1.5);
    }
    return Vector2();
}

} // namespace godot
