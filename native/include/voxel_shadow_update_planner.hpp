#pragma once

#include <cstdint>
#include <unordered_map>
#include <unordered_set>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Stateful planner for bursty shadow-volume updates. SceneTree and GPU mutation are intentionally
// left to the caller; tracking, deadband, scheduling, stale-object sweep and region merging live here.
class VoxelShadowUpdatePlanner : public Resource {
    GDCLASS(VoxelShadowUpdatePlanner, Resource)

    std::unordered_map<uint64_t, AABB> bounds_by_shape;
    std::unordered_map<uint64_t, bool> dynamic_by_shape;
    std::unordered_set<uint64_t> dynamic_shapes;
    int64_t round_robin = 0;
    int sweep_countdown = 0;

protected:
    static void _bind_methods();

public:
    void reset(const Array &p_shapes, const Array &p_bounds, const Array &p_dynamic);
    Dictionary plan(const Array &p_movable, const Dictionary &p_current_bounds,
            int64_t p_frame, int p_budget, double p_deadband_squared,
            double p_region_growth, int p_sweep_every, double p_merge_max_side);
    Array coalesce(const Array &p_regions, double p_max_side) const;
};

} // namespace godot
