#include "voxel_motion_damage_scanner.hpp"

#include <algorithm>
#include <vector>

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rigid_body3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/aabb.hpp>

namespace godot {

namespace {

struct MovingBody {
    Object *body = nullptr;
    RigidBody3D *rigid = nullptr;
    double energy_order = 0.0;
};

} // namespace

void VoxelMotionDamageScanner::_bind_methods() {
    ClassDB::bind_method(D_METHOD("reset"), &VoxelMotionDamageScanner::reset);
    ClassDB::bind_method(D_METHOD("scan", "world", "static_grid", "awake_bodies", "now_msec",
                                 "min_speed", "margin", "max_bodies", "max_tests",
                                 "cooldown_msec"),
            &VoxelMotionDamageScanner::scan);
}

void VoxelMotionDamageScanner::reset() {
    cooldown_by_pair.clear();
}

Dictionary VoxelMotionDamageScanner::scan(Object *p_world, Object *p_static_grid,
        const Array &p_awake_bodies, int64_t p_now_msec, double p_min_speed,
        double p_margin, int p_max_bodies, int p_max_tests, int64_t p_cooldown_msec) {
    int tests = 0;
    int hits = 0;
    std::vector<MovingBody> moving;
    moving.reserve(static_cast<size_t>(p_awake_bodies.size()));
    if (p_world == nullptr || p_static_grid == nullptr) {
        Dictionary empty;
        empty["tests"] = tests;
        empty["hits"] = hits;
        return empty;
    }
    for (int index = 0; index < p_awake_bodies.size(); ++index) {
        Object *body = p_awake_bodies[index];
        if (body == nullptr || static_cast<bool>(body->get("collision_handoff_pending"))) {
            continue;
        }
        if (body->has_method("update_adaptive_ccd")) {
            body->call("update_adaptive_ccd");
        }
        RigidBody3D *rigid = body->has_method("get_physics_body")
                ? Object::cast_to<RigidBody3D>(static_cast<Object *>(body->call("get_physics_body")))
                : nullptr;
        if (rigid == nullptr || rigid->get_linear_velocity().length() < p_min_speed) {
            continue;
        }
        MovingBody entry;
        entry.body = body;
        entry.rigid = rigid;
        entry.energy_order = rigid->get_mass() * rigid->get_linear_velocity().length_squared();
        moving.push_back(entry);
    }
    std::sort(moving.begin(), moving.end(), [](const MovingBody &p_a, const MovingBody &p_b) {
        return p_a.energy_order > p_b.energy_order;
    });
    const int body_count = std::min(std::max(0, p_max_bodies), static_cast<int>(moving.size()));
    for (int body_index = 0; body_index < body_count && tests < p_max_tests; ++body_index) {
        const MovingBody &entry = moving[body_index];
        const double speed = entry.rigid->get_linear_velocity().length();
        const Vector3 center = entry.rigid->to_global(entry.rigid->get_center_of_mass());
        const Array shapes = entry.body->has_method("get_shapes")
                ? static_cast<Array>(entry.body->call("get_shapes")) : Array();
        for (int shape_index = 0; shape_index < shapes.size() && tests < p_max_tests; ++shape_index) {
            Object *moving_shape = shapes[shape_index];
            if (moving_shape == nullptr || !moving_shape->has_method("world_bounds")) {
                continue;
            }
            const AABB moving_bounds = moving_shape->call("world_bounds");
            Array candidates = p_static_grid->call("query", moving_bounds.grow(p_margin));
            std::vector<Object *> ordered;
            ordered.reserve(static_cast<size_t>(candidates.size()));
            for (int candidate_index = 0; candidate_index < candidates.size(); ++candidate_index) {
                Object *candidate = candidates[candidate_index];
                if (candidate != nullptr && candidate->has_method("world_bounds")) {
                    ordered.push_back(candidate);
                }
            }
            std::sort(ordered.begin(), ordered.end(), [center](Object *p_a, Object *p_b) {
                const AABB a = p_a->call("world_bounds");
                const AABB b = p_b->call("world_bounds");
                return a.get_center().distance_squared_to(center) <
                        b.get_center().distance_squared_to(center);
            });
            for (Object *target_shape : ordered) {
                if (tests >= p_max_tests) {
                    break;
                }
                Object *target = p_world->call("_body_of", target_shape);
                if (target == nullptr || target == entry.body ||
                        static_cast<int>(target->get("state")) != 0 ||
                        static_cast<bool>(target->get("collision_enabled")) ||
                        static_cast<bool>(p_world->call("_is_foundation", target_shape))) {
                    continue;
                }
                const BodyPair key{entry.body->get_instance_id(), target->get_instance_id()};
                const auto cooldown = cooldown_by_pair.find(key);
                if (cooldown != cooldown_by_pair.end() &&
                        p_now_msec - cooldown->second < p_cooldown_msec) {
                    continue;
                }
                tests++;
                if (!static_cast<bool>(p_world->call("_shapes_touch_with_margin",
                            moving_shape, target_shape, p_margin))) {
                    continue;
                }
                cooldown_by_pair[key] = p_now_msec;
                const AABB target_bounds = target_shape->call("world_bounds");
                const Vector3 point_on_target = center.clamp(
                        target_bounds.position, target_bounds.get_end());
                const Vector3 point_on_mover = target_bounds.get_center().clamp(
                        moving_bounds.position, moving_bounds.get_end());
                Object *target_physics = target->has_method("get_physics_body")
                        ? static_cast<Object *>(target->call("get_physics_body")) : nullptr;
                p_world->call("queue_physics_impact", entry.body, target_physics,
                        (point_on_target + point_on_mover) * 0.5,
                        entry.rigid->get_mass() * speed * 0.35, speed);
                hits++;
            }
        }
    }
    // Bound stale cooldown memory during long sessions.
    if (cooldown_by_pair.size() > 4096) {
        for (auto iterator = cooldown_by_pair.begin(); iterator != cooldown_by_pair.end();) {
            if (p_now_msec - iterator->second > p_cooldown_msec * 8) {
                iterator = cooldown_by_pair.erase(iterator);
            } else {
                ++iterator;
            }
        }
    }
    Dictionary result;
    result["tests"] = tests;
    result["hits"] = hits;
    result["moving_bodies"] = body_count;
    return result;
}

} // namespace godot
