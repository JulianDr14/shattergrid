#include "voxel_runtime_registry.hpp"

#include <algorithm>

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void VoxelRuntimeRegistry::_bind_methods() {
    ClassDB::bind_method(D_METHOD("clear"), &VoxelRuntimeRegistry::clear);
    ClassDB::bind_method(D_METHOD("upsert_body", "body_id", "dynamic", "awake", "structural",
                                 "persistent", "boxes", "voxels", "last_interaction_msec"),
            &VoxelRuntimeRegistry::upsert_body);
    ClassDB::bind_method(D_METHOD("remove_body", "body_id"), &VoxelRuntimeRegistry::remove_body);
    ClassDB::bind_method(D_METHOD("upsert_shape", "shape_id", "data", "body_id",
								 "canonical_revision", "notified_revision", "collision_revision", "collision_enabled",
                                 "collision_rebuild_pending", "collision_handoff_pending"),
            &VoxelRuntimeRegistry::upsert_shape);
    ClassDB::bind_method(D_METHOD("remove_shape", "shape_id"), &VoxelRuntimeRegistry::remove_shape);
    ClassDB::bind_method(D_METHOD("set_baked_collision_pending", "shape_id", "pending"),
            &VoxelRuntimeRegistry::set_baked_collision_pending);
    ClassDB::bind_method(D_METHOD("get_metrics"), &VoxelRuntimeRegistry::get_metrics);
    ClassDB::bind_method(D_METHOD("get_coherence_snapshot"),
            &VoxelRuntimeRegistry::get_coherence_snapshot);
    ClassDB::bind_method(D_METHOD("get_awake_body_ids"),
            &VoxelRuntimeRegistry::get_awake_body_ids);
    ClassDB::bind_method(D_METHOD("get_zero_voxel_body_ids"),
            &VoxelRuntimeRegistry::get_zero_voxel_body_ids);
    ClassDB::bind_method(D_METHOD("plan_budget", "target_awake_bodies", "burst_awake_bodies",
                                 "max_active_boxes", "max_boxes_per_body", "burst"),
            &VoxelRuntimeRegistry::plan_budget);
}

void VoxelRuntimeRegistry::remove_body_totals(const BodyRecord &p_record) {
    if (!p_record.dynamic) {
        return;
    }
    dynamic_bodies--;
    compound_boxes -= p_record.boxes;
    if (p_record.awake) {
        awake_bodies--;
        awake_compound_boxes -= p_record.boxes;
    }
}

void VoxelRuntimeRegistry::add_body_totals(const BodyRecord &p_record) {
    if (!p_record.dynamic) {
        return;
    }
    dynamic_bodies++;
    compound_boxes += p_record.boxes;
    if (p_record.awake) {
        awake_bodies++;
        awake_compound_boxes += p_record.boxes;
    }
}

void VoxelRuntimeRegistry::clear() {
    bodies.clear();
    shapes.clear();
    baked_collision_pending.clear();
    dynamic_bodies = 0;
    awake_bodies = 0;
    compound_boxes = 0;
    awake_compound_boxes = 0;
}

void VoxelRuntimeRegistry::upsert_body(int64_t p_body_id, bool p_dynamic, bool p_awake,
        bool p_structural, bool p_persistent, int p_boxes, int p_voxels,
        int64_t p_last_interaction_msec) {
    const auto existing = bodies.find(p_body_id);
    if (existing != bodies.end()) {
        remove_body_totals(existing->second);
    }
    BodyRecord record;
    record.dynamic = p_dynamic;
    record.awake = p_dynamic && p_awake;
    record.structural = p_structural;
    record.persistent = p_persistent;
    record.boxes = std::max(0, p_boxes);
    record.voxels = std::max(0, p_voxels);
    record.last_interaction_msec = p_last_interaction_msec;
    bodies[p_body_id] = record;
    add_body_totals(record);
}

void VoxelRuntimeRegistry::remove_body(int64_t p_body_id) {
    const auto existing = bodies.find(p_body_id);
    if (existing == bodies.end()) {
        return;
    }
    remove_body_totals(existing->second);
    bodies.erase(existing);
}

void VoxelRuntimeRegistry::upsert_shape(int64_t p_shape_id, const Ref<VoxelShapeData> &p_data,
		int64_t p_body_id,
        int64_t p_canonical_revision, int64_t p_notified_revision, int64_t p_collision_revision,
        bool p_collision_enabled, bool p_collision_rebuild_pending,
        bool p_collision_handoff_pending) {
    ShapeRecord record;
	record.data = p_data;
    record.body_id = p_body_id;
    record.canonical_revision = p_canonical_revision;
    record.notified_revision = p_notified_revision;
    record.collision_revision = p_collision_revision;
    record.collision_enabled = p_collision_enabled;
    record.collision_rebuild_pending = p_collision_rebuild_pending;
    record.collision_handoff_pending = p_collision_handoff_pending;
    shapes[p_shape_id] = record;
}

void VoxelRuntimeRegistry::remove_shape(int64_t p_shape_id) {
    shapes.erase(p_shape_id);
    baked_collision_pending.erase(p_shape_id);
}

void VoxelRuntimeRegistry::set_baked_collision_pending(int64_t p_shape_id, bool p_pending) {
    if (p_pending) {
        baked_collision_pending.insert(p_shape_id);
    } else {
        baked_collision_pending.erase(p_shape_id);
    }
}

Dictionary VoxelRuntimeRegistry::get_metrics() const {
    Dictionary result;
    result["dynamic_bodies"] = dynamic_bodies;
    result["awake_bodies"] = awake_bodies;
    result["compound_boxes"] = compound_boxes;
    result["awake_compound_boxes"] = awake_compound_boxes;
    result["registered_shapes"] = static_cast<int64_t>(shapes.size());
    result["baked_pending_shapes"] = static_cast<int64_t>(baked_collision_pending.size());
    return result;
}

Dictionary VoxelRuntimeRegistry::get_coherence_snapshot() const {
	int64_t first_pending_shape = 0;
	int64_t first_pending_canonical = 0;
	auto make_entry = [](int64_t p_shape_id, const ShapeRecord &p_record,
			int64_t p_canonical, const char *p_status, const char *p_consumer) {
		Dictionary entry;
		entry["shape"] = p_shape_id;
		entry["body"] = p_record.body_id;
		entry["canonical_revision"] = p_canonical;
		entry["notified_revision"] = p_record.notified_revision;
		entry["collision_revision"] = p_record.collision_revision;
		entry["status"] = p_status;
		entry["consumer"] = p_consumer;
		return entry;
	};
    for (const auto &[shape_id, record] : shapes) {
		const int64_t canonical_revision = record.data.is_valid()
				? record.data->get_content_revision() : record.canonical_revision;
		if (record.notified_revision != canonical_revision) {
			return make_entry(shape_id, record, canonical_revision,
					"DESYNC", "voxel_change_signal");
        }
		if (!record.collision_enabled || record.collision_revision == canonical_revision) {
            continue;
        }
        const bool pending = record.collision_rebuild_pending || record.collision_handoff_pending ||
                baked_collision_pending.count(shape_id) != 0;
        if (!pending) {
			return make_entry(shape_id, record, canonical_revision, "DESYNC", "collision");
        }
		if (first_pending_shape == 0) {
			first_pending_shape = shape_id;
			first_pending_canonical = canonical_revision;
        }
    }
	if (first_pending_shape != 0) {
		return make_entry(first_pending_shape, shapes.at(first_pending_shape),
				first_pending_canonical, "PENDING", "collision");
    }
    Dictionary coherent;
    coherent["status"] = "COHERENT";
    coherent["shape"] = "-";
    coherent["body"] = "-";
    coherent["consumer"] = "-";
    return coherent;
}

PackedInt64Array VoxelRuntimeRegistry::get_awake_body_ids() const {
    PackedInt64Array result;
    result.resize(awake_bodies);
    int cursor = 0;
    for (const auto &[body_id, record] : bodies) {
        if (record.dynamic && record.awake) {
            result.set(cursor++, body_id);
        }
    }
    return result;
}

PackedInt64Array VoxelRuntimeRegistry::get_zero_voxel_body_ids() const {
    PackedInt64Array result;
    for (const auto &[body_id, record] : bodies) {
        if (record.dynamic && record.voxels == 0) {
            result.append(body_id);
        }
    }
    return result;
}

Dictionary VoxelRuntimeRegistry::plan_budget(int p_target_awake_bodies, int p_burst_awake_bodies,
        int p_max_active_boxes, int p_max_boxes_per_body, bool p_burst) const {
    const int awake_limit = p_burst ? p_burst_awake_bodies : p_target_awake_bodies;
    const int allowance = awake_bodies > 0
            ? std::min(p_max_boxes_per_body, std::max(1, p_max_active_boxes / awake_bodies))
            : p_max_boxes_per_body;
	const bool over_budget = awake_bodies > awake_limit || awake_compound_boxes > p_max_active_boxes;
    PackedInt64Array simplify_ids;
	if (awake_compound_boxes > p_max_active_boxes) {
		for (const auto &[body_id, record] : bodies) {
			if (record.dynamic && record.awake && record.boxes > allowance) {
				simplify_ids.append(body_id);
			}
		}
	}
	Dictionary result;
	result["awake_limit"] = std::max(1, awake_limit);
	result["awake"] = awake_bodies;
	result["boxes"] = awake_compound_boxes;
	result["allowance"] = allowance;
	result["simplify_ids"] = simplify_ids;
	result["over_budget"] = over_budget;
	if (!over_budget) {
		result["retirement_order"] = PackedInt64Array();
		return result;
	}
    struct Candidate {
        int64_t id = 0;
        bool structural = false;
        bool persistent = false;
        int64_t last_interaction = 0;
    };
    std::vector<Candidate> candidates;
    candidates.reserve(bodies.size());
    for (const auto &[body_id, record] : bodies) {
        if (!record.dynamic) {
            continue;
        }
        candidates.push_back({ body_id, record.structural, record.persistent,
                record.last_interaction_msec });
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        if (a.structural != b.structural) {
            return !a.structural;
        }
        return a.last_interaction < b.last_interaction;
    });
    PackedInt64Array retirement_order;
    for (const Candidate &candidate : candidates) {
        if (!candidate.persistent) {
            retirement_order.append(candidate.id);
        }
    }
    result["retirement_order"] = retirement_order;
    return result;
}

} // namespace godot
