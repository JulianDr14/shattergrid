#include "voxel_support_planner.hpp"

#include <unordered_set>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include "voxel_structural_graph.hpp"

namespace godot {

namespace {

bool eligible_static_shape(Object *p_shape, Object *p_body) {
    if (p_shape == nullptr || p_body == nullptr) {
        return false;
    }
    const int state = p_body->get("state");
    const bool collision_enabled = p_body->get("collision_enabled");
    const bool anchored = p_shape->get("anchored");
    const int64_t voxels = p_shape->has_method("voxel_count")
            ? static_cast<int64_t>(p_shape->call("voxel_count")) : 0;
    return state == 0 && collision_enabled && !anchored && voxels > 0;
}

} // namespace

void VoxelSupportPlanner::_bind_methods() {
    ClassDB::bind_method(D_METHOD("route", "graph", "start_id", "excluded_id",
                                 "foundation_provider", "contact_provider",
                                 "direct_foundation_provider"),
            &VoxelSupportPlanner::route);
    ClassDB::bind_method(D_METHOD("plan_drop_chains", "shapes", "graph", "body_provider",
                                 "foundation_provider", "contact_provider",
                                 "direct_foundation_provider"),
            &VoxelSupportPlanner::plan_drop_chains);
}

Dictionary VoxelSupportPlanner::route(const Ref<VoxelStructuralGraph> &p_graph,
        int64_t p_start_id, int64_t p_excluded_id, const Callable &p_foundation_provider,
        const Callable &p_contact_provider, const Callable &p_direct_foundation_provider) const {
    Dictionary result;
    Dictionary visited;
    if (p_graph.is_null()) {
        result["grounded"] = false;
        result["visited"] = visited;
        return result;
    }
    const Dictionary native = p_graph->reaches_foundation(p_start_id, p_excluded_id,
            p_foundation_provider, p_contact_provider, p_direct_foundation_provider);
    const PackedInt64Array ids = native.get("visited_ids", PackedInt64Array());
    for (int index = 0; index < ids.size(); ++index) {
        Object *candidate = ObjectDB::get_instance(static_cast<uint64_t>(ids[index]));
        if (candidate != nullptr) {
            visited[ids[index]] = candidate;
        }
    }
    result["grounded"] = native.get("grounded", false);
    result["visited"] = visited;
    return result;
}

Dictionary VoxelSupportPlanner::plan_drop_chains(const Array &p_shapes,
        const Ref<VoxelStructuralGraph> &p_graph, const Callable &p_body_provider,
        const Callable &p_foundation_provider, const Callable &p_contact_provider,
        const Callable &p_direct_foundation_provider) const {
    Array chains;
    std::unordered_set<int64_t> decided;
    int searches = 0;
    if (p_graph.is_null() || !p_body_provider.is_valid() ||
            !p_foundation_provider.is_valid()) {
        Dictionary empty;
        empty["chains"] = chains;
        empty["searches"] = searches;
        return empty;
    }
    for (int shape_index = 0; shape_index < p_shapes.size(); ++shape_index) {
        Object *shape = p_shapes[shape_index];
        if (shape == nullptr) {
            continue;
        }
        const int64_t shape_id = static_cast<int64_t>(shape->get_instance_id());
        Object *body = p_body_provider.call(shape_id);
        if (!eligible_static_shape(shape, body) || decided.count(shape_id) != 0 ||
                static_cast<bool>(p_foundation_provider.call(shape_id))) {
            continue;
        }
        searches++;
        const Dictionary native = p_graph->reaches_foundation(shape_id, 0,
                p_foundation_provider, p_contact_provider, p_direct_foundation_provider);
        const PackedInt64Array visited = native.get("visited_ids", PackedInt64Array());
        for (int index = 0; index < visited.size(); ++index) {
            decided.insert(visited[index]);
        }
        if (static_cast<bool>(native.get("grounded", false))) {
            continue;
        }
        Array chain;
        std::unordered_set<uint64_t> body_ids;
        for (int index = 0; index < visited.size(); ++index) {
            Object *loose_shape = ObjectDB::get_instance(static_cast<uint64_t>(visited[index]));
            Object *loose_body = p_body_provider.call(visited[index]);
            if (!eligible_static_shape(loose_shape, loose_body)) {
                continue;
            }
            const uint64_t body_id = loose_body->get_instance_id();
            if (body_ids.insert(body_id).second) {
                chain.append(loose_body);
            }
        }
        if (!chain.is_empty()) {
            chains.append(chain);
        }
    }
    Dictionary result;
    result["chains"] = chains;
    result["searches"] = searches;
    result["decided"] = static_cast<int64_t>(decided.size());
    return result;
}

} // namespace godot
