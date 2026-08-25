#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

class RigidBody3D;

// Aggregates per-shape mass properties and applies the compound result to a rigid body.
// This remains a main-thread operation because it mutates a live PhysicsBody3D.
class VoxelMassProperties : public Resource {
    GDCLASS(VoxelMassProperties, Resource)

protected:
    static void _bind_methods();

public:
    Dictionary calculate(const Array &p_shapes, bool p_vehicle) const;
    bool apply(RigidBody3D *p_body, const Array &p_shapes, bool p_vehicle) const;
    static Vector2 damping_for_inertia(const Vector3 &p_inertia);
};

} // namespace godot
