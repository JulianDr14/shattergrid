#include "voxel_shadow_update_planner.hpp"

#include <algorithm>
#include <vector>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

namespace godot {

namespace {

Node *body_of(Node *p_shape) {
    Node *node = p_shape == nullptr ? nullptr : p_shape->get_parent();
    while (node != nullptr) {
        if (node->has_method("get_shapes") && node->has_method("get_physics_body")) {
            return node;
        }
        node = node->get_parent();
    }
    return nullptr;
}

bool moved_beyond_deadband(const AABB &p_previous, const AABB &p_current, double p_squared) {
    return p_previous.position.distance_squared_to(p_current.position) > p_squared ||
            p_previous.get_end().distance_squared_to(p_current.get_end()) > p_squared;
}

} // namespace

void VoxelShadowUpdatePlanner::_bind_methods() {
    ClassDB::bind_method(D_METHOD("reset", "shapes", "bounds", "dynamic"),
            &VoxelShadowUpdatePlanner::reset);
    ClassDB::bind_method(D_METHOD("plan", "movable", "current_bounds", "frame", "budget",
                                 "deadband_squared", "region_growth", "sweep_every",
                                 "merge_max_side"),
            &VoxelShadowUpdatePlanner::plan);
    ClassDB::bind_method(D_METHOD("coalesce", "regions", "max_side"),
            &VoxelShadowUpdatePlanner::coalesce);
}

void VoxelShadowUpdatePlanner::reset(
        const Array &p_shapes, const Array &p_bounds, const Array &p_dynamic) {
    bounds_by_shape.clear();
    dynamic_by_shape.clear();
    dynamic_shapes.clear();
    const int count = std::min(p_shapes.size(), std::min(p_bounds.size(), p_dynamic.size()));
    for (int index = 0; index < count; ++index) {
        Object *shape = p_shapes[index];
        if (shape == nullptr) {
            continue;
        }
        const uint64_t id = shape->get_instance_id();
        bounds_by_shape[id] = p_bounds[index];
        const bool dynamic = p_dynamic[index];
        dynamic_by_shape[id] = dynamic;
        if (dynamic) {
            dynamic_shapes.insert(id);
        }
    }
    round_robin = 0;
    sweep_countdown = 0;
}

Dictionary VoxelShadowUpdatePlanner::plan(const Array &p_movable,
        const Dictionary &p_current_bounds, int64_t p_frame, int p_budget,
        double p_deadband_squared, double p_region_growth, int p_sweep_every,
        double p_merge_max_side) {
    Array grid_updates;
    Array removals;
    Array dirty;
    const int movable_count = p_movable.size();
    const int start = movable_count > 0 ? static_cast<int>(round_robin % movable_count) : 0;
    if (movable_count > 0) {
        round_robin += std::max(1, p_budget);
    }
    for (int ordered = 0; ordered < movable_count; ++ordered) {
        Object *shape_object = p_movable[(start + ordered) % movable_count];
        Node *shape = Object::cast_to<Node>(shape_object);
        if (shape == nullptr) {
            continue;
        }
        const uint64_t id = shape->get_instance_id();
        Node *body = body_of(shape);
        const bool dynamic = body != nullptr && static_cast<int>(body->get("state")) == 1;
        const int interval = body == nullptr ? 1 :
                std::max(1, static_cast<int>(body->get_meta("voxel_shadow_interval_frames", 1)));
        const int phase = body == nullptr ? 0 :
                static_cast<int>(body->get_meta("voxel_shadow_phase", 0));
        const auto previous_it = bounds_by_shape.find(id);
        if (interval > 1 && previous_it != bounds_by_shape.end() &&
                p_frame % interval != phase) {
            continue;
        }
        AABB current;
        if (p_current_bounds.has(static_cast<int64_t>(id))) {
            current = p_current_bounds[static_cast<int64_t>(id)];
        } else if (shape->has_method("world_bounds")) {
            current = shape->call("world_bounds");
        }
        const bool known = previous_it != bounds_by_shape.end();
        const AABB previous = known ? previous_it->second : current;
        const auto dynamic_it = dynamic_by_shape.find(id);
        const bool was_dynamic = dynamic_it != dynamic_by_shape.end() && dynamic_it->second;
        const bool needs_refresh = dynamic != was_dynamic || !known ||
                (dynamic && moved_beyond_deadband(previous, current, p_deadband_squared));
        if (needs_refresh) {
            Dictionary update;
            update["shape"] = shape;
            update["bounds"] = current;
            grid_updates.append(update);
            if (dirty.size() >= std::max(0, p_budget)) {
                continue;
            }
            dirty.append(previous.merge(current).grow(p_region_growth));
        } else if (dynamic) {
            dynamic_by_shape[id] = true;
            dynamic_shapes.insert(id);
            continue;
        }
        bounds_by_shape[id] = current;
        dynamic_by_shape[id] = dynamic;
        if (dynamic) {
            dynamic_shapes.insert(id);
        } else {
            dynamic_shapes.erase(id);
        }
    }
    sweep_countdown--;
    if (sweep_countdown <= 0) {
        sweep_countdown = std::max(1, p_sweep_every);
        std::vector<uint64_t> stale;
        for (const uint64_t id : dynamic_shapes) {
            Object *shape = ObjectDB::get_instance(id);
            if (shape != nullptr && shape->has_method("voxel_count") &&
                    static_cast<int64_t>(shape->call("voxel_count")) > 0) {
                continue;
            }
            const auto bounds = bounds_by_shape.find(id);
            if (bounds != bounds_by_shape.end()) {
                dirty.append(bounds->second);
            }
            stale.push_back(id);
            removals.append(static_cast<int64_t>(id));
        }
        for (const uint64_t id : stale) {
            bounds_by_shape.erase(id);
            dynamic_by_shape.erase(id);
            dynamic_shapes.erase(id);
        }
    }
    Dictionary result;
    result["grid_updates"] = grid_updates;
    result["removals"] = removals;
    result["dirty"] = coalesce(dirty, p_merge_max_side);
    return result;
}

Array VoxelShadowUpdatePlanner::coalesce(const Array &p_regions, double p_max_side) const {
    Array result;
    for (int region_index = 0; region_index < p_regions.size(); ++region_index) {
        const AABB region = p_regions[region_index];
        bool merged = false;
        for (int result_index = 0; result_index < result.size(); ++result_index) {
            const AABB candidate = static_cast<AABB>(result[result_index]).merge(region);
            const Vector3 side = candidate.size;
            if (std::max(side.x, std::max(side.y, side.z)) <= p_max_side) {
                result[result_index] = candidate;
                merged = true;
                break;
            }
        }
        if (!merged) {
            result.append(region);
        }
    }
    return result;
}

} // namespace godot
