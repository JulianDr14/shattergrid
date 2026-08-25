#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class VoxelStructuralGraph;

// Orchestrates support routes and unsupported-body grouping over ObjectIDs. Geometry discovery is
// still delegated to the world's spatial index, but route materialization and drop planning no
// longer live in the world script.
class VoxelSupportPlanner : public Resource {
    GDCLASS(VoxelSupportPlanner, Resource)

protected:
    static void _bind_methods();

public:
    Dictionary route(const Ref<VoxelStructuralGraph> &p_graph, int64_t p_start_id,
            int64_t p_excluded_id, const Callable &p_foundation_provider,
            const Callable &p_contact_provider,
            const Callable &p_direct_foundation_provider) const;
    Dictionary plan_drop_chains(const Array &p_shapes,
            const Ref<VoxelStructuralGraph> &p_graph,
            const Callable &p_body_provider,
            const Callable &p_foundation_provider,
            const Callable &p_contact_provider,
            const Callable &p_direct_foundation_provider) const;
};

} // namespace godot
