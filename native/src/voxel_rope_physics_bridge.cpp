#include "voxel_rope_physics_bridge.hpp"

#include <algorithm>
#include <vector>

#include <godot_cpp/classes/physics_direct_space_state3d.hpp>
#include <godot_cpp/classes/physics_ray_query_parameters3d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include "voxel_rope_solver.hpp"

namespace godot {

void VoxelRopePhysicsBridge::_bind_methods() {
    ClassDB::bind_method(D_METHOD("step", "world", "solver", "spans", "collision_skin",
                                 "collision_friction", "tension_slack", "stiffness",
                                 "tension_damping", "force_per_strength", "max_acceleration"),
            &VoxelRopePhysicsBridge::step);
    ClassDB::bind_method(D_METHOD("velocity_at", "owner", "world_point"),
            &VoxelRopePhysicsBridge::velocity_at);
}

RigidBody3D *VoxelRopePhysicsBridge::physics_body(Object *p_owner) {
    if (p_owner == nullptr || !p_owner->has_method("get_physics_body")) {
        return nullptr;
    }
    Object *candidate = p_owner->call("get_physics_body");
    return Object::cast_to<RigidBody3D>(candidate);
}

Vector3 VoxelRopePhysicsBridge::body_velocity_at(
        Object *p_owner, const Vector3 &p_world_point) {
    RigidBody3D *rigid = physics_body(p_owner);
    if (rigid == nullptr) {
        return Vector3();
    }
    const Vector3 center = rigid->get_global_transform().xform(rigid->get_center_of_mass());
    return rigid->get_linear_velocity() +
            rigid->get_angular_velocity().cross(p_world_point - center);
}

Vector3 VoxelRopePhysicsBridge::velocity_at(
        Object *p_owner, const Vector3 &p_world_point) const {
    return body_velocity_at(p_owner, p_world_point);
}

Dictionary VoxelRopePhysicsBridge::step(const Ref<World3D> &p_world,
        const Ref<VoxelRopeSolver> &p_solver, const Array &p_spans, double p_collision_skin,
        double p_collision_friction, double p_tension_slack, double p_stiffness,
        double p_tension_damping, double p_force_per_strength, double p_max_acceleration) {
    Dictionary output;
    output["break_indices"] = PackedInt32Array();
    output["pulling"] = 0;
    output["raycasts"] = 0;
    output["hits"] = 0;
    if (p_solver.is_null()) {
        return output;
    }

    int raycasts = 0;
    int hits = 0;
    PhysicsDirectSpaceState3D *space = p_world.is_valid()
            ? p_world->get_direct_space_state() : nullptr;
    if (space != nullptr) {
        const Dictionary queries = p_solver->get_collision_queries();
        const PackedInt32Array point_indices = queries["point_indices"];
        const PackedInt32Array span_indices = queries["span_indices"];
        const PackedVector3Array from_points = queries["from"];
        const PackedVector3Array to_points = queries["to"];
        std::vector<TypedArray<RID>> excludes(static_cast<size_t>(p_spans.size()));
        std::vector<bool> excludes_ready(static_cast<size_t>(p_spans.size()), false);
        const int query_count = std::min(
                std::min(point_indices.size(), span_indices.size()),
                std::min(from_points.size(), to_points.size()));
        for (int query_index = 0; query_index < query_count; ++query_index) {
            const int span_index = span_indices[query_index];
            if (span_index < 0 || span_index >= p_spans.size()) {
                continue;
            }
            if (!excludes_ready[static_cast<size_t>(span_index)]) {
                const Dictionary span = p_spans[span_index];
                for (const char *side : { "body_a", "body_b" }) {
                    Object *owner = span.get(side, Variant());
                    if (owner == nullptr || !owner->has_method("get_collision_rids")) {
                        continue;
                    }
                    const Array body_rids = owner->call("get_collision_rids");
                    for (int rid_index = 0; rid_index < body_rids.size(); ++rid_index) {
                        excludes[static_cast<size_t>(span_index)].append(body_rids[rid_index]);
                    }
                }
                excludes_ready[static_cast<size_t>(span_index)] = true;
            }
            Ref<PhysicsRayQueryParameters3D> query = PhysicsRayQueryParameters3D::create(
                    from_points[query_index], to_points[query_index], 0xffffffff,
                    excludes[static_cast<size_t>(span_index)]);
            const Dictionary hit = space->intersect_ray(query);
            raycasts++;
            if (hit.is_empty()) {
                continue;
            }
            const Vector3 normal = hit["normal"];
            const Vector3 position = hit["position"];
            p_solver->resolve_collision(point_indices[query_index],
                    position + normal * p_collision_skin, normal, p_collision_friction);
            hits++;
        }
    }

    PackedVector3Array velocity_a;
    PackedVector3Array velocity_b;
    velocity_a.resize(p_spans.size());
    velocity_b.resize(p_spans.size());
    for (int span_index = 0; span_index < p_spans.size(); ++span_index) {
        if (p_solver->is_span_dead(span_index) || !p_solver->is_span_awake(span_index)) {
            continue;
        }
        const Dictionary span = p_spans[span_index];
        Object *body_a = span.get("body_a", Variant());
        Object *body_b = span.get("body_b", Variant());
        const bool pin_a = span.get("pin_a", false);
        const bool pin_b = span.get("pin_b", false);
        if (pin_a && pin_b && body_a != nullptr && body_a == body_b) {
            continue;
        }
        velocity_a.set(span_index, body_velocity_at(body_a, p_solver->get_point(span_index, 0)));
        velocity_b.set(span_index, body_velocity_at(body_b,
                p_solver->get_point(span_index, p_solver->get_segments())));
    }

    const Dictionary tensions = p_solver->evaluate_tensions(velocity_a, velocity_b,
            p_tension_slack, p_stiffness, p_tension_damping, p_force_per_strength);
    const PackedInt32Array force_indices = tensions["span_indices"];
    const PackedVector3Array force_a = tensions["force_a"];
    const PackedVector3Array force_b = tensions["force_b"];
    const int force_count = std::min(force_indices.size(),
            std::min(force_a.size(), force_b.size()));
    for (int force_index = 0; force_index < force_count; ++force_index) {
        const int span_index = force_indices[force_index];
        if (span_index < 0 || span_index >= p_spans.size()) {
            continue;
        }
        const Dictionary span = p_spans[span_index];
        for (int side = 0; side < 2; ++side) {
            const char *body_key = side == 0 ? "body_a" : "body_b";
            const char *pin_key = side == 0 ? "pin_a" : "pin_b";
            if (!static_cast<bool>(span.get(pin_key, false))) {
                continue;
            }
            Object *owner = span.get(body_key, Variant());
            RigidBody3D *rigid = physics_body(owner);
            if (rigid == nullptr) {
                continue;
            }
            Vector3 force = side == 0 ? force_a[force_index] : force_b[force_index];
            const double limit = rigid->get_mass() * std::max(0.0, p_max_acceleration);
            if (limit > 0.0 && force.length_squared() > limit * limit) {
                force = force.normalized() * limit;
            }
            const Vector3 at = p_solver->get_point(span_index,
                    side == 0 ? 0 : p_solver->get_segments());
            rigid->apply_force(force, at - rigid->get_global_position());
        }
    }

    output["break_indices"] = tensions.get("break_indices", PackedInt32Array());
    output["pulling"] = tensions.get("pulling", 0);
    output["raycasts"] = raycasts;
    output["hits"] = hits;
    return output;
}

} // namespace godot
