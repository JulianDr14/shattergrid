#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class RigidBody3D;
class VoxelRopeSolver;
class World3D;

// Scene-facing rope physics bridge. It stays on the physics thread, batches ray queries and
// applies the forces produced by VoxelRopeSolver without a per-point GDScript round trip.
class VoxelRopePhysicsBridge : public Resource {
    GDCLASS(VoxelRopePhysicsBridge, Resource)

    static RigidBody3D *physics_body(Object *p_owner);
    static Vector3 body_velocity_at(Object *p_owner, const Vector3 &p_world_point);

protected:
    static void _bind_methods();

public:
    Dictionary step(const Ref<World3D> &p_world, const Ref<VoxelRopeSolver> &p_solver,
            const Array &p_spans, double p_collision_skin, double p_collision_friction,
            double p_tension_slack, double p_stiffness, double p_tension_damping,
            double p_force_per_strength, double p_max_acceleration);
    Vector3 velocity_at(Object *p_owner, const Vector3 &p_world_point) const;
};

} // namespace godot
