#pragma once

#include <cstdint>
#include <vector>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Small bounded contact queue with native spatial deduplication. ObjectIDs are stored instead of
// Node references so a body can be freed while its deferred impact waits safely.
class VoxelImpactQueue : public Resource {
    GDCLASS(VoxelImpactQueue, Resource)

    struct Record {
        uint64_t source_id = 0;
        uint64_t target_id = 0;
        uint64_t collider_id = 0;
        Vector3 point;
        double impulse = 0.0;
        double speed = 0.0;
        int64_t low_id = 0;
        int64_t high_id = 0;
        Vector3i cell;
    };

    std::vector<Record> records;

protected:
    static void _bind_methods();

public:
    void clear();
    int size() const;
    bool is_empty() const;
    bool enqueue(Object *p_source, Object *p_target, Object *p_collider,
            const Vector3 &p_point, double p_impulse, double p_speed, int p_capacity);
    Dictionary pop_front();
};

} // namespace godot
