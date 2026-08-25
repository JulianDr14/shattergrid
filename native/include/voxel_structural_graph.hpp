#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

// Native graph traversal over Shape IDs. Geometry/contact discovery is supplied by the world,
// while visited sets, queues, grouping and predecessor tracking stay allocation-efficient in C++.
class VoxelStructuralGraph : public Resource {
    GDCLASS(VoxelStructuralGraph, Resource)

protected:
    static void _bind_methods();

public:
    Dictionary reaches_foundation(int64_t p_start_id, int64_t p_excluded_id,
            const Callable &p_foundation_provider, const Callable &p_contact_provider,
            const Callable &p_direct_foundation_provider) const;
    Array connected_groups(int p_item_count, const PackedInt32Array &p_edge_pairs) const;
};

} // namespace godot
