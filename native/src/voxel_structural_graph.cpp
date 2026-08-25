#include "voxel_structural_graph.hpp"

#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

namespace godot {

void VoxelStructuralGraph::_bind_methods() {
    ClassDB::bind_method(D_METHOD("reaches_foundation", "start_id", "excluded_id",
                                 "foundation_provider", "contact_provider",
                                 "direct_foundation_provider"),
            &VoxelStructuralGraph::reaches_foundation);
    ClassDB::bind_method(D_METHOD("connected_groups", "item_count", "edge_pairs"),
            &VoxelStructuralGraph::connected_groups);
}

Dictionary VoxelStructuralGraph::reaches_foundation(int64_t p_start_id, int64_t p_excluded_id,
        const Callable &p_foundation_provider, const Callable &p_contact_provider,
        const Callable &p_direct_foundation_provider) const {
    Dictionary result;
    PackedInt64Array visited_result;
    if (p_start_id == 0 || !p_foundation_provider.is_valid() || !p_contact_provider.is_valid()) {
        result["grounded"] = false;
        result["visited_ids"] = visited_result;
        return result;
    }
    if (static_cast<bool>(p_foundation_provider.call(p_start_id))) {
        result["grounded"] = true;
        result["visited_ids"] = visited_result;
        return result;
    }

    std::unordered_set<int64_t> visited;
    std::vector<int64_t> frontier;
    visited.insert(p_start_id);
    frontier.push_back(p_start_id);
    if (p_excluded_id != 0) {
        visited.insert(p_excluded_id);
    }
    bool grounded = false;
    while (!frontier.empty() && !grounded) {
        const int64_t current = frontier.back();
        frontier.pop_back();
        if (p_direct_foundation_provider.is_valid() &&
                static_cast<bool>(p_direct_foundation_provider.call(current, p_excluded_id))) {
            grounded = true;
            break;
        }
        const Variant contacts_variant = p_contact_provider.call(current);
        const PackedInt64Array contacts = contacts_variant;
        for (int index = 0; index < contacts.size(); ++index) {
            const int64_t neighbour = contacts[index];
            if (visited.count(neighbour) != 0) {
                continue;
            }
            if (static_cast<bool>(p_foundation_provider.call(neighbour))) {
                grounded = true;
                break;
            }
            visited.insert(neighbour);
            frontier.push_back(neighbour);
        }
    }
    visited.erase(p_excluded_id);
    visited_result.resize(static_cast<int>(visited.size()));
    int cursor = 0;
    for (const int64_t id : visited) {
        visited_result.set(cursor++, id);
    }
    result["grounded"] = grounded;
    result["visited_ids"] = visited_result;
    return result;
}

Array VoxelStructuralGraph::connected_groups(
        int p_item_count, const PackedInt32Array &p_edge_pairs) const {
    Array result;
    if (p_item_count <= 0) {
        return result;
    }
    std::vector<std::vector<int>> adjacency(static_cast<size_t>(p_item_count));
    for (int offset = 0; offset + 1 < p_edge_pairs.size(); offset += 2) {
        const int a = p_edge_pairs[offset];
        const int b = p_edge_pairs[offset + 1];
        if (a < 0 || b < 0 || a >= p_item_count || b >= p_item_count || a == b) {
            continue;
        }
        adjacency[static_cast<size_t>(a)].push_back(b);
        adjacency[static_cast<size_t>(b)].push_back(a);
    }
    std::vector<uint8_t> assigned(static_cast<size_t>(p_item_count), 0);
    std::vector<int> frontier;
    for (int seed = 0; seed < p_item_count; ++seed) {
        if (assigned[static_cast<size_t>(seed)] != 0) {
            continue;
        }
        PackedInt32Array group;
        frontier.clear();
        frontier.push_back(seed);
        assigned[static_cast<size_t>(seed)] = 1;
        while (!frontier.empty()) {
            const int current = frontier.back();
            frontier.pop_back();
            group.append(current);
            for (const int neighbour : adjacency[static_cast<size_t>(current)]) {
                if (assigned[static_cast<size_t>(neighbour)] != 0) {
                    continue;
                }
                assigned[static_cast<size_t>(neighbour)] = 1;
                frontier.push_back(neighbour);
            }
        }
        result.append(group);
    }
    return result;
}

} // namespace godot
