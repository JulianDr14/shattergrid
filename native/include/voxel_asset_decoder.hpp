#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Generic MagicaVoxel decoder. It owns binary chunk parsing, scene traversal and dense runtime
// expansion; palette policy and optional project sidecars remain in the GDScript adapter.
class VoxelAssetDecoder : public Resource {
    GDCLASS(VoxelAssetDecoder, Resource)

protected:
    static void _bind_methods();

public:
    Dictionary decode(const String &p_path, int p_scale = 2, int p_shell = 2,
            double p_voxel_size = 0.1) const;
};

} // namespace godot
