#pragma once

#include <godot_cpp/classes/resource.hpp>

namespace godot {

class VoxelPhysicsBudget : public Resource {
    GDCLASS(VoxelPhysicsBudget, Resource)

    int target_awake_bodies = 128;
    int burst_awake_bodies = 192;
    // Un colapso grande pasa de 84 a 28 hijos Jolt al pedir 64 cajas (la descomposición elige el
    // siguiente pitch exacto). En Lee conservó la caída y redujo el P95 físico de 7,14 a 6,46 ms.
    // El límite evita que un árbol/poste recién desprendido monopolice el narrow phase al tocar
    // simultáneamente suelo y vehículo.
    int max_boxes_per_body = 64;
    int max_active_boxes = 8192;
    // Hasta 31 voxeles son chips cosméticos. Desde 32 siguen siendo escombros rígidos,
    // seleccionables y agarrables.
    int particle_voxel_limit = 31;
    int structural_voxel_threshold = 64;
    double retire_after_seconds = 1.5;

protected:
    static void _bind_methods();

public:
    void set_target_awake_bodies(int p_value);
    int get_target_awake_bodies() const;
    void set_burst_awake_bodies(int p_value);
    int get_burst_awake_bodies() const;
    void set_max_boxes_per_body(int p_value);
    int get_max_boxes_per_body() const;
    void set_max_active_boxes(int p_value);
    int get_max_active_boxes() const;
    void set_particle_voxel_limit(int p_value);
    int get_particle_voxel_limit() const;
    void set_structural_voxel_threshold(int p_value);
    int get_structural_voxel_threshold() const;
    void set_retire_after_seconds(double p_value);
    double get_retire_after_seconds() const;
};

class VoxelRendererSettings : public Resource {
    GDCLASS(VoxelRendererSettings, Resource)

    int clipmap_resolution = 512;
    int clipmap_levels = 4;
    int local_light_volume_resolution = 256;
    int max_local_shadow_lights = 8;
    bool sun_shadows_enabled = false;
    double voxel_size = 0.1;
    double target_gpu_ms = 8.0;
    double p95_gpu_ms = 10.0;

protected:
    static void _bind_methods();

public:
    void set_clipmap_resolution(int p_value);
    int get_clipmap_resolution() const;
    void set_clipmap_levels(int p_value);
    int get_clipmap_levels() const;
    void set_local_light_volume_resolution(int p_value);
    int get_local_light_volume_resolution() const;
    void set_max_local_shadow_lights(int p_value);
    int get_max_local_shadow_lights() const;
    void set_sun_shadows_enabled(bool p_value);
    bool get_sun_shadows_enabled() const;
    void set_voxel_size(double p_value);
    double get_voxel_size() const;
    void set_target_gpu_ms(double p_value);
    double get_target_gpu_ms() const;
    void set_p95_gpu_ms(double p_value);
    double get_p95_gpu_ms() const;
};

} // namespace godot
