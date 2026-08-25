#include "voxel_impact_queue.hpp"

#include <algorithm>
#include <cmath>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

namespace godot {

void VoxelImpactQueue::_bind_methods() {
    ClassDB::bind_method(D_METHOD("clear"), &VoxelImpactQueue::clear);
    ClassDB::bind_method(D_METHOD("size"), &VoxelImpactQueue::size);
    ClassDB::bind_method(D_METHOD("is_empty"), &VoxelImpactQueue::is_empty);
    ClassDB::bind_method(D_METHOD("enqueue", "source", "target", "collider", "point",
                                 "impulse", "speed", "capacity"),
            &VoxelImpactQueue::enqueue);
    ClassDB::bind_method(D_METHOD("pop_front"), &VoxelImpactQueue::pop_front);
}

void VoxelImpactQueue::clear() {
    records.clear();
}

int VoxelImpactQueue::size() const {
    return static_cast<int>(records.size());
}

bool VoxelImpactQueue::is_empty() const {
    return records.empty();
}

bool VoxelImpactQueue::enqueue(Object *p_source, Object *p_target, Object *p_collider,
        const Vector3 &p_point, double p_impulse, double p_speed, int p_capacity) {
    if (p_source == nullptr || p_capacity <= 0) {
        return false;
    }
    const uint64_t source_id = p_source->get_instance_id();
    const uint64_t target_id = p_target != nullptr ? p_target->get_instance_id() : 0;
    const uint64_t collider_id = p_collider != nullptr ? p_collider->get_instance_id() : 0;
    const int64_t other_id = static_cast<int64_t>(target_id != 0 ? target_id : collider_id);
    const int64_t low_id = std::min(static_cast<int64_t>(source_id), other_id);
    const int64_t high_id = std::max(static_cast<int64_t>(source_id), other_id);
    const Vector3 scaled = p_point / 0.35;
    const Vector3i cell(static_cast<int64_t>(std::floor(scaled.x)),
            static_cast<int64_t>(std::floor(scaled.y)),
            static_cast<int64_t>(std::floor(scaled.z)));
    for (Record &record : records) {
        if (record.low_id != low_id || record.high_id != high_id || record.cell != cell) {
            continue;
        }
        if (p_impulse > record.impulse) {
            record.source_id = source_id;
            record.target_id = target_id;
            record.collider_id = collider_id;
            record.point = p_point;
            record.impulse = p_impulse;
            record.speed = p_speed;
        }
        return false;
    }
    if (records.size() >= static_cast<size_t>(p_capacity)) {
        return false;
    }
    records.push_back({ source_id, target_id, collider_id, p_point, p_impulse, p_speed,
            low_id, high_id, cell });
    return true;
}

Dictionary VoxelImpactQueue::pop_front() {
    if (records.empty()) {
        return Dictionary();
    }
    const Record record = records.front();
    records.erase(records.begin());
    Dictionary result;
    result["source"] = ObjectDB::get_instance(record.source_id);
    result["target"] = ObjectDB::get_instance(record.target_id);
    result["collider"] = ObjectDB::get_instance(record.collider_id);
    result["point"] = record.point;
    result["impulse"] = record.impulse;
    result["speed"] = record.speed;
    return result;
}

} // namespace godot
