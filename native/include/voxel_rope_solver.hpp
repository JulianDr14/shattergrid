#pragma once

#include <vector>

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

namespace godot {

// Data-only Verlet solver. Godot physics queries and force application are intentionally kept in
// the scene-facing adapter so this resource never owns Nodes or crosses thread-safety boundaries.
class VoxelRopeSolver : public Resource {
    GDCLASS(VoxelRopeSolver, Resource)

    struct Span {
        int start = 0;
        int count = 0;
        double segment_rest = 0.0;
        double span_rest = 0.0;
        double strength = 1.0;
        double max_stretch = 0.75;
        bool pin_a = true;
        bool pin_b = true;
        bool awake = true;
        bool dead = false;
        int still_frames = 0;
        Vector3 center;
        double reach = 0.0;
    };

    int segment_count = 8;
    int iterations = 6;
    double gravity = 9.8;
    double pinned_drag_per_second = 3.7;
    double loose_drag_per_second = 0.28;
    double sleep_epsilon = 0.0015;
    int sleep_frames = 20;
    int awake_spans = 0;
    bool mesh_topology_dirty = true;
    bool mesh_positions_dirty = false;
    std::vector<Span> spans;
    std::vector<Vector3> points;
    std::vector<Vector3> previous;
    PackedVector2Array cached_uvs;
    PackedInt32Array cached_indices;

    void rebuild_topology();
    bool valid_span(int p_span) const;

protected:
    static void _bind_methods();

public:
    void configure(int p_segments, int p_iterations, double p_gravity,
            double p_pinned_drag_per_second, double p_loose_drag_per_second,
            double p_sleep_epsilon, int p_sleep_frames);
    int add_span(const Vector3 &p_from, const Vector3 &p_to, double p_slack,
            double p_strength = 1.0, double p_max_stretch = 0.75);
    bool simulate(double p_delta);
    void sleep_all();
    void force_all_awake(const Vector3 &p_previous_offset = Vector3());
    void wake_span(int p_span, const Vector3 &p_previous_offset = Vector3());
    void set_span_awake(int p_span, bool p_awake);
    void release_pin(int p_span, bool p_side_a);
    bool move_anchor(int p_span, bool p_side_a, const Vector3 &p_target);
    void set_span_rigid_points(int p_span, const PackedVector3Array &p_points);

    Dictionary get_collision_queries() const;
    void resolve_collision(int p_point_index, const Vector3 &p_landed,
            const Vector3 &p_normal, double p_friction);
    Dictionary evaluate_tensions(const PackedVector3Array &p_velocity_a,
            const PackedVector3Array &p_velocity_b, double p_tension_slack, double p_stiffness,
            double p_tension_damping, double p_force_per_strength) const;
    Dictionary build_mesh_data(const Vector3 &p_dead_point);

    int get_span_count() const;
    int get_awake_count() const;
    int get_segments() const;
    Vector3 get_point(int p_span, int p_step) const;
    PackedVector3Array get_span_points(int p_span) const;
    Vector3 get_span_center(int p_span) const;
    double get_span_reach(int p_span) const;
    double get_maximum_separation(int p_span) const;
    bool is_pin_a(int p_span) const;
    bool is_pin_b(int p_span) const;
    bool is_span_awake(int p_span) const;
    bool is_span_dead(int p_span) const;
    bool consume_mesh_dirty();
};

} // namespace godot
