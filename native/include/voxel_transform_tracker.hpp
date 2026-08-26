#pragma once

#include <cstdint>
#include <unordered_set>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

namespace godot {

// Collects moving voxel shapes and render snapshots from the runtime registry's awake IDs. The
// tracker keeps exactly one frame of grace for bodies that have just gone to sleep.
class VoxelTransformTracker : public Resource {
    GDCLASS(VoxelTransformTracker, Resource)

    std::unordered_set<uint64_t> previous_awake;
    // Un segundo frame captura la pose posterior a la aplicación diferida de sleeping/freeze en
    // Jolt. Con uno solo, el Body podía avanzar todavía un tick y dejar el render 9,8 cm atrás.
    std::unordered_set<uint64_t> grace_awake;

protected:
    static void _bind_methods();

public:
    void reset();
    Dictionary collect(const PackedInt64Array &p_awake_body_ids);
};

} // namespace godot
