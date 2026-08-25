#pragma once

#include <cstdint>
#include <unordered_map>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Bounded 30 Hz contact scanner for fast voxel bodies versus non-colliding static geometry.
// Exact voxel tests and impact ownership are invoked on the world adapter on the main thread.
class VoxelMotionDamageScanner : public Resource {
    GDCLASS(VoxelMotionDamageScanner, Resource)

    struct BodyPair {
        uint64_t moving = 0;
        uint64_t target = 0;

        bool operator==(const BodyPair &p_other) const {
            return moving == p_other.moving && target == p_other.target;
        }
    };
    struct BodyPairHash {
        size_t operator()(const BodyPair &p_pair) const {
            size_t value = std::hash<uint64_t>{}(p_pair.moving);
            value ^= std::hash<uint64_t>{}(p_pair.target) + 0x9e3779b9 +
                    (value << 6) + (value >> 2);
            return value;
        }
    };
    std::unordered_map<BodyPair, int64_t, BodyPairHash> cooldown_by_pair;

protected:
    static void _bind_methods();

public:
    void reset();
    Dictionary scan(Object *p_world, Object *p_static_grid, const Array &p_awake_bodies,
            int64_t p_now_msec, double p_min_speed, double p_margin,
            int p_max_bodies, int p_max_tests, int64_t p_cooldown_msec);
};

} // namespace godot
