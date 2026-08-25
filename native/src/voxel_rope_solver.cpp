#include "voxel_rope_solver.hpp"

#include <algorithm>
#include <cmath>

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void VoxelRopeSolver::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "segments", "iterations", "gravity",
                                 "pinned_drag_per_second", "loose_drag_per_second",
                                 "sleep_epsilon", "sleep_frames"),
            &VoxelRopeSolver::configure);
    ClassDB::bind_method(D_METHOD("add_span", "from", "to", "slack", "strength", "max_stretch"),
            &VoxelRopeSolver::add_span, DEFVAL(1.0), DEFVAL(0.75));
    ClassDB::bind_method(D_METHOD("simulate", "delta"), &VoxelRopeSolver::simulate);
    ClassDB::bind_method(D_METHOD("sleep_all"), &VoxelRopeSolver::sleep_all);
    ClassDB::bind_method(D_METHOD("force_all_awake", "previous_offset"),
            &VoxelRopeSolver::force_all_awake, DEFVAL(Vector3()));
    ClassDB::bind_method(D_METHOD("wake_span", "span", "previous_offset"),
            &VoxelRopeSolver::wake_span, DEFVAL(Vector3()));
    ClassDB::bind_method(D_METHOD("set_span_awake", "span", "awake"),
            &VoxelRopeSolver::set_span_awake);
    ClassDB::bind_method(D_METHOD("release_pin", "span", "side_a"),
            &VoxelRopeSolver::release_pin);
    ClassDB::bind_method(D_METHOD("move_anchor", "span", "side_a", "target"),
            &VoxelRopeSolver::move_anchor);
    ClassDB::bind_method(D_METHOD("set_span_rigid_points", "span", "points"),
            &VoxelRopeSolver::set_span_rigid_points);
    ClassDB::bind_method(D_METHOD("get_collision_queries"),
            &VoxelRopeSolver::get_collision_queries);
    ClassDB::bind_method(D_METHOD("resolve_collision", "point_index", "landed", "normal", "friction"),
            &VoxelRopeSolver::resolve_collision);
    ClassDB::bind_method(D_METHOD("evaluate_tensions", "velocity_a", "velocity_b",
                                 "tension_slack", "stiffness", "tension_damping",
                                 "force_per_strength"),
            &VoxelRopeSolver::evaluate_tensions);
    ClassDB::bind_method(D_METHOD("build_mesh_data", "dead_point"),
            &VoxelRopeSolver::build_mesh_data);
    ClassDB::bind_method(D_METHOD("get_span_count"), &VoxelRopeSolver::get_span_count);
    ClassDB::bind_method(D_METHOD("get_awake_count"), &VoxelRopeSolver::get_awake_count);
    ClassDB::bind_method(D_METHOD("get_segments"), &VoxelRopeSolver::get_segments);
    ClassDB::bind_method(D_METHOD("get_point", "span", "step"), &VoxelRopeSolver::get_point);
    ClassDB::bind_method(D_METHOD("get_span_points", "span"), &VoxelRopeSolver::get_span_points);
    ClassDB::bind_method(D_METHOD("get_span_center", "span"), &VoxelRopeSolver::get_span_center);
    ClassDB::bind_method(D_METHOD("get_span_reach", "span"), &VoxelRopeSolver::get_span_reach);
    ClassDB::bind_method(D_METHOD("get_maximum_separation", "span"),
            &VoxelRopeSolver::get_maximum_separation);
    ClassDB::bind_method(D_METHOD("is_pin_a", "span"), &VoxelRopeSolver::is_pin_a);
    ClassDB::bind_method(D_METHOD("is_pin_b", "span"), &VoxelRopeSolver::is_pin_b);
    ClassDB::bind_method(D_METHOD("is_span_awake", "span"), &VoxelRopeSolver::is_span_awake);
    ClassDB::bind_method(D_METHOD("is_span_dead", "span"), &VoxelRopeSolver::is_span_dead);
    ClassDB::bind_method(D_METHOD("consume_mesh_dirty"), &VoxelRopeSolver::consume_mesh_dirty);
}

void VoxelRopeSolver::configure(int p_segments, int p_iterations, double p_gravity,
        double p_pinned_drag_per_second, double p_loose_drag_per_second,
        double p_sleep_epsilon, int p_sleep_frames) {
    if (!spans.empty()) {
        return;
    }
    segment_count = std::max(1, p_segments);
    iterations = std::max(1, p_iterations);
    gravity = std::max(0.0, p_gravity);
    pinned_drag_per_second = std::max(0.0, p_pinned_drag_per_second);
    loose_drag_per_second = std::max(0.0, p_loose_drag_per_second);
    sleep_epsilon = std::max(0.0, p_sleep_epsilon);
    sleep_frames = std::max(1, p_sleep_frames);
}

int VoxelRopeSolver::add_span(const Vector3 &p_from, const Vector3 &p_to, double p_slack,
        double p_strength, double p_max_stretch) {
    Span span;
    span.start = static_cast<int>(points.size());
    span.count = segment_count + 1;
    const double separation = p_from.distance_to(p_to);
    span.segment_rest = std::max(0.01, separation + p_slack) / segment_count;
    span.span_rest = std::max(0.01, separation);
    span.strength = std::max(0.01, p_strength);
    span.max_stretch = std::max(0.01, p_max_stretch);
    span.center = (p_from + p_to) * 0.5;
    span.reach = separation * 0.5 + 1.0;
    for (int step = 0; step <= segment_count; ++step) {
        const Vector3 point = p_from.lerp(p_to, static_cast<double>(step) / segment_count);
        points.push_back(point);
        previous.push_back(point);
    }
    spans.push_back(span);
    awake_spans++;
    mesh_topology_dirty = true;
    mesh_positions_dirty = true;
    return static_cast<int>(spans.size()) - 1;
}

bool VoxelRopeSolver::simulate(double p_delta) {
    if (awake_spans <= 0 || p_delta <= 0.0) {
        return false;
    }
    const double fall = gravity * p_delta * p_delta;
    bool changed = false;
    for (Span &span : spans) {
        if (!span.awake || span.dead) {
            continue;
        }
        const int start = span.start;
        const int last = start + span.count - 1;
        const double drag = span.pin_a && span.pin_b
                ? pinned_drag_per_second : loose_drag_per_second;
        const double damping = std::exp(-drag * p_delta);
        double moved = 0.0;
        for (int index = start; index <= last; ++index) {
            if ((index == start && span.pin_a) || (index == last && span.pin_b)) {
                continue;
            }
            const Vector3 current = points[static_cast<size_t>(index)];
            const Vector3 step = (current - previous[static_cast<size_t>(index)]) * damping;
            previous[static_cast<size_t>(index)] = current;
            points[static_cast<size_t>(index)] = current + step - Vector3(0.0, fall, 0.0);
            moved = std::max(moved, static_cast<double>(step.length()));
        }
        for (int iteration = 0; iteration < iterations; ++iteration) {
            for (int index = start; index < last; ++index) {
                Vector3 delta_vector = points[static_cast<size_t>(index + 1)] -
                        points[static_cast<size_t>(index)];
                const double distance = delta_vector.length();
                if (distance < 0.000001) {
                    continue;
                }
                const bool free_low = index > start || !span.pin_a;
                const bool free_high = index + 1 < last || !span.pin_b;
                if (!free_low && !free_high) {
                    continue;
                }
                const Vector3 correction = delta_vector * ((distance - span.segment_rest) / distance);
                if (free_low && free_high) {
                    points[static_cast<size_t>(index)] += correction * 0.5;
                    points[static_cast<size_t>(index + 1)] -= correction * 0.5;
                } else if (free_low) {
                    points[static_cast<size_t>(index)] += correction;
                } else {
                    points[static_cast<size_t>(index + 1)] -= correction;
                }
            }
        }
        if (moved < sleep_epsilon) {
            span.still_frames++;
            if (span.still_frames >= sleep_frames) {
                span.awake = false;
                awake_spans--;
            }
        } else {
            span.still_frames = 0;
        }
        changed = true;
    }
    mesh_positions_dirty = mesh_positions_dirty || changed;
    return changed;
}

void VoxelRopeSolver::sleep_all() {
    awake_spans = 0;
    for (Span &span : spans) {
        if (span.dead) {
            continue;
        }
        span.awake = false;
        span.still_frames = sleep_frames;
        for (int index = span.start; index < span.start + span.count; ++index) {
            previous[static_cast<size_t>(index)] = points[static_cast<size_t>(index)];
        }
    }
}

void VoxelRopeSolver::force_all_awake(const Vector3 &p_previous_offset) {
    awake_spans = 0;
    for (int index = 0; index < static_cast<int>(spans.size()); ++index) {
        wake_span(index, p_previous_offset);
    }
}

void VoxelRopeSolver::wake_span(int p_span, const Vector3 &p_previous_offset) {
    if (!valid_span(p_span)) {
        return;
    }
    Span &span = spans[static_cast<size_t>(p_span)];
    if (span.dead) {
        return;
    }
    if (!span.awake) {
        span.awake = true;
        awake_spans++;
    }
    span.still_frames = 0;
    for (int index = span.start + 1; index < span.start + span.count - 1; ++index) {
        previous[static_cast<size_t>(index)] -= p_previous_offset;
    }
}

void VoxelRopeSolver::set_span_awake(int p_span, bool p_awake) {
    if (!valid_span(p_span) || spans[static_cast<size_t>(p_span)].dead) {
        return;
    }
    Span &span = spans[static_cast<size_t>(p_span)];
    if (span.awake == p_awake) {
        return;
    }
    span.awake = p_awake;
    span.still_frames = p_awake ? 0 : sleep_frames;
    awake_spans += p_awake ? 1 : -1;
}

void VoxelRopeSolver::release_pin(int p_span, bool p_side_a) {
    if (!valid_span(p_span)) {
        return;
    }
    Span &span = spans[static_cast<size_t>(p_span)];
    bool &pin = p_side_a ? span.pin_a : span.pin_b;
    if (!pin) {
        return;
    }
    pin = false;
    span.still_frames = 0;
    if (!span.awake && !span.dead) {
        span.awake = true;
        awake_spans++;
    }
    if (!span.pin_a && !span.pin_b) {
        span.dead = true;
        if (span.awake) {
            span.awake = false;
            awake_spans--;
        }
    }
    mesh_positions_dirty = true;
}

bool VoxelRopeSolver::move_anchor(int p_span, bool p_side_a, const Vector3 &p_target) {
    if (!valid_span(p_span)) {
        return false;
    }
    Span &span = spans[static_cast<size_t>(p_span)];
    const int point_index = p_side_a ? span.start : span.start + span.count - 1;
    if (points[static_cast<size_t>(point_index)].distance_squared_to(p_target) < 0.000001) {
        return false;
    }
    points[static_cast<size_t>(point_index)] = p_target;
    previous[static_cast<size_t>(point_index)] = p_target;
    span.center = (points[static_cast<size_t>(span.start)] +
            points[static_cast<size_t>(span.start + span.count - 1)]) * 0.5;
    if (!span.awake && !span.dead) {
        span.awake = true;
        span.still_frames = 0;
        awake_spans++;
    }
    mesh_positions_dirty = true;
    return true;
}

void VoxelRopeSolver::set_span_rigid_points(
        int p_span, const PackedVector3Array &p_points) {
    if (!valid_span(p_span)) {
        return;
    }
    Span &span = spans[static_cast<size_t>(p_span)];
    if (p_points.size() != span.count) {
        return;
    }
    bool moved = false;
    for (int step = 0; step < span.count; ++step) {
        const int point_index = span.start + step;
        const Vector3 target = p_points[step];
        moved = moved || points[static_cast<size_t>(point_index)].distance_squared_to(target) > 0.000001;
        points[static_cast<size_t>(point_index)] = target;
        previous[static_cast<size_t>(point_index)] = target;
    }
    span.center = (p_points[0] + p_points[p_points.size() - 1]) * 0.5;
    set_span_awake(p_span, false);
    mesh_positions_dirty = mesh_positions_dirty || moved;
}

Dictionary VoxelRopeSolver::get_collision_queries() const {
    PackedInt32Array point_indices;
    PackedInt32Array span_indices;
    PackedVector3Array from_points;
    PackedVector3Array to_points;
    for (int span_index = 0; span_index < static_cast<int>(spans.size()); ++span_index) {
        const Span &span = spans[static_cast<size_t>(span_index)];
        if (!span.awake || span.dead) {
            continue;
        }
        const int last = span.start + span.count - 1;
        for (int point_index = span.start; point_index <= last; ++point_index) {
            if ((point_index == span.start && span.pin_a) || (point_index == last && span.pin_b)) {
                continue;
            }
            const Vector3 from = previous[static_cast<size_t>(point_index)];
            const Vector3 to = points[static_cast<size_t>(point_index)];
            if (from.distance_squared_to(to) < 0.000001) {
                continue;
            }
            point_indices.append(point_index);
            span_indices.append(span_index);
            from_points.append(from);
            to_points.append(to);
        }
    }
    Dictionary result;
    result["point_indices"] = point_indices;
    result["span_indices"] = span_indices;
    result["from"] = from_points;
    result["to"] = to_points;
    return result;
}

void VoxelRopeSolver::resolve_collision(int p_point_index, const Vector3 &p_landed,
        const Vector3 &p_normal, double p_friction) {
    if (p_point_index < 0 || p_point_index >= static_cast<int>(points.size())) {
        return;
    }
    const Vector3 from = previous[static_cast<size_t>(p_point_index)];
    const Vector3 velocity = p_landed - from;
    points[static_cast<size_t>(p_point_index)] = p_landed;
    previous[static_cast<size_t>(p_point_index)] = p_landed -
            (velocity - p_normal * velocity.dot(p_normal)) * p_friction;
    mesh_positions_dirty = true;
}

Dictionary VoxelRopeSolver::evaluate_tensions(const PackedVector3Array &p_velocity_a,
        const PackedVector3Array &p_velocity_b, double p_tension_slack, double p_stiffness,
        double p_tension_damping, double p_force_per_strength) const {
    PackedInt32Array span_indices;
    PackedInt32Array break_indices;
    PackedVector3Array force_a;
    PackedVector3Array force_b;
    int pulling = 0;
    const int count = std::min({ static_cast<int>(spans.size()),
            static_cast<int>(p_velocity_a.size()), static_cast<int>(p_velocity_b.size()) });
    for (int span_index = 0; span_index < count; ++span_index) {
        const Span &span = spans[static_cast<size_t>(span_index)];
        if (span.dead || !span.awake) {
            continue;
        }
        const Vector3 a = points[static_cast<size_t>(span.start)];
        const Vector3 b = points[static_cast<size_t>(span.start + span.count - 1)];
        const double separation = a.distance_to(b);
        if (separation <= span.span_rest + p_tension_slack) {
            continue;
        }
        const double extension = separation - span.span_rest;
        if (extension > span.max_stretch) {
            break_indices.append(span_index);
            continue;
        }
        const Vector3 direction = (b - a) / separation;
        const double separating = (p_velocity_b[span_index] - p_velocity_a[span_index]).dot(direction);
        const double elastic = std::max(0.0, extension - p_tension_slack) * p_stiffness;
        const double breaking_force = span.strength * p_force_per_strength;
        if (elastic >= breaking_force) {
            break_indices.append(span_index);
            continue;
        }
        const double magnitude = std::clamp(
                elastic + separating * p_tension_damping, 0.0, breaking_force);
        span_indices.append(span_index);
        force_a.append(direction * magnitude);
        force_b.append(-direction * magnitude);
        pulling++;
    }
    Dictionary result;
    result["span_indices"] = span_indices;
    result["break_indices"] = break_indices;
    result["force_a"] = force_a;
    result["force_b"] = force_b;
    result["pulling"] = pulling;
    return result;
}

bool VoxelRopeSolver::valid_span(int p_span) const {
    return p_span >= 0 && p_span < static_cast<int>(spans.size());
}

int VoxelRopeSolver::get_span_count() const { return static_cast<int>(spans.size()); }
int VoxelRopeSolver::get_awake_count() const { return awake_spans; }
int VoxelRopeSolver::get_segments() const { return segment_count; }

Vector3 VoxelRopeSolver::get_point(int p_span, int p_step) const {
    if (!valid_span(p_span)) {
        return Vector3();
    }
    const Span &span = spans[static_cast<size_t>(p_span)];
    const int step = std::clamp(p_step, 0, span.count - 1);
    return points[static_cast<size_t>(span.start + step)];
}

PackedVector3Array VoxelRopeSolver::get_span_points(int p_span) const {
    PackedVector3Array result;
    if (!valid_span(p_span)) {
        return result;
    }
    const Span &span = spans[static_cast<size_t>(p_span)];
    result.resize(span.count);
    for (int step = 0; step < span.count; ++step) {
        result.set(step, points[static_cast<size_t>(span.start + step)]);
    }
    return result;
}

Vector3 VoxelRopeSolver::get_span_center(int p_span) const {
    return valid_span(p_span) ? spans[static_cast<size_t>(p_span)].center : Vector3();
}

double VoxelRopeSolver::get_span_reach(int p_span) const {
    return valid_span(p_span) ? spans[static_cast<size_t>(p_span)].reach : 0.0;
}

double VoxelRopeSolver::get_maximum_separation(int p_span) const {
    return valid_span(p_span) ? spans[static_cast<size_t>(p_span)].span_rest +
            spans[static_cast<size_t>(p_span)].max_stretch : 0.0;
}

bool VoxelRopeSolver::is_pin_a(int p_span) const {
    return valid_span(p_span) && spans[static_cast<size_t>(p_span)].pin_a;
}
bool VoxelRopeSolver::is_pin_b(int p_span) const {
    return valid_span(p_span) && spans[static_cast<size_t>(p_span)].pin_b;
}
bool VoxelRopeSolver::is_span_awake(int p_span) const {
    return valid_span(p_span) && spans[static_cast<size_t>(p_span)].awake;
}
bool VoxelRopeSolver::is_span_dead(int p_span) const {
    return !valid_span(p_span) || spans[static_cast<size_t>(p_span)].dead;
}

} // namespace godot
