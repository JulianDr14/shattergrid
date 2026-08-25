#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace godot {

// Deterministic main-thread traversal for imported map dictionaries. The visitor owns gameplay
// policy; recursion, transform composition and child-context propagation stay native.
class VoxelMapSceneTraversal : public Resource {
    GDCLASS(VoxelMapSceneTraversal, Resource)

    static int visit(const Dictionary &p_element, const Transform3D &p_parent,
            const Dictionary &p_context, const Callable &p_visitor);

protected:
    static void _bind_methods();

public:
    int traverse(const Array &p_roots, const Transform3D &p_parent,
            const Dictionary &p_context, const Callable &p_visitor) const;
};

} // namespace godot
