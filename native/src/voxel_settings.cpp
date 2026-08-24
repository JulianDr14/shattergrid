#include "voxel_settings.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>

using namespace godot;

void VoxelPhysicsBudget::_bind_methods() {
#define BIND_INT(name) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &VoxelPhysicsBudget::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &VoxelPhysicsBudget::get_##name); \
    ADD_PROPERTY(PropertyInfo(Variant::INT, #name), "set_" #name, "get_" #name)
    BIND_INT(target_awake_bodies);
    BIND_INT(burst_awake_bodies);
    BIND_INT(max_boxes_per_body);
    BIND_INT(max_active_boxes);
    BIND_INT(particle_voxel_limit);
    BIND_INT(structural_voxel_threshold);
#undef BIND_INT
    ClassDB::bind_method(D_METHOD("set_retire_after_seconds", "value"), &VoxelPhysicsBudget::set_retire_after_seconds);
    ClassDB::bind_method(D_METHOD("get_retire_after_seconds"), &VoxelPhysicsBudget::get_retire_after_seconds);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "retire_after_seconds", PROPERTY_HINT_RANGE, "0.1,30.0,0.1"),
            "set_retire_after_seconds", "get_retire_after_seconds");
}

void VoxelPhysicsBudget::set_target_awake_bodies(int v) { target_awake_bodies = std::max(1, v); }
int VoxelPhysicsBudget::get_target_awake_bodies() const { return target_awake_bodies; }
void VoxelPhysicsBudget::set_burst_awake_bodies(int v) { burst_awake_bodies = std::max(target_awake_bodies, v); }
int VoxelPhysicsBudget::get_burst_awake_bodies() const { return burst_awake_bodies; }
void VoxelPhysicsBudget::set_max_boxes_per_body(int v) { max_boxes_per_body = std::max(1, v); }
int VoxelPhysicsBudget::get_max_boxes_per_body() const { return max_boxes_per_body; }
void VoxelPhysicsBudget::set_max_active_boxes(int v) { max_active_boxes = std::max(1, v); }
int VoxelPhysicsBudget::get_max_active_boxes() const { return max_active_boxes; }
void VoxelPhysicsBudget::set_particle_voxel_limit(int v) { particle_voxel_limit = std::max(0, v); }
int VoxelPhysicsBudget::get_particle_voxel_limit() const { return particle_voxel_limit; }
void VoxelPhysicsBudget::set_structural_voxel_threshold(int v) { structural_voxel_threshold = std::max(1, v); }
int VoxelPhysicsBudget::get_structural_voxel_threshold() const { return structural_voxel_threshold; }
void VoxelPhysicsBudget::set_retire_after_seconds(double v) { retire_after_seconds = std::max(0.1, v); }
double VoxelPhysicsBudget::get_retire_after_seconds() const { return retire_after_seconds; }

void VoxelRendererSettings::_bind_methods() {
#define BIND_INT(name) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &VoxelRendererSettings::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &VoxelRendererSettings::get_##name); \
    ADD_PROPERTY(PropertyInfo(Variant::INT, #name), "set_" #name, "get_" #name)
    BIND_INT(clipmap_resolution);
    BIND_INT(clipmap_levels);
    BIND_INT(local_light_volume_resolution);
    BIND_INT(max_local_shadow_lights);
#undef BIND_INT
	ClassDB::bind_method(D_METHOD("set_sun_shadows_enabled", "value"),
			&VoxelRendererSettings::set_sun_shadows_enabled);
	ClassDB::bind_method(D_METHOD("get_sun_shadows_enabled"),
			&VoxelRendererSettings::get_sun_shadows_enabled);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "sun_shadows_enabled"),
			"set_sun_shadows_enabled", "get_sun_shadows_enabled");
#define BIND_FLOAT(name) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &VoxelRendererSettings::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &VoxelRendererSettings::get_##name); \
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, #name), "set_" #name, "get_" #name)
    BIND_FLOAT(voxel_size);
    BIND_FLOAT(target_gpu_ms);
    BIND_FLOAT(p95_gpu_ms);
#undef BIND_FLOAT
}

void VoxelRendererSettings::set_clipmap_resolution(int v) { clipmap_resolution = std::max(32, v); }
int VoxelRendererSettings::get_clipmap_resolution() const { return clipmap_resolution; }
void VoxelRendererSettings::set_clipmap_levels(int v) { clipmap_levels = std::clamp(v, 1, 8); }
int VoxelRendererSettings::get_clipmap_levels() const { return clipmap_levels; }
void VoxelRendererSettings::set_local_light_volume_resolution(int v) { local_light_volume_resolution = std::max(32, v); }
int VoxelRendererSettings::get_local_light_volume_resolution() const { return local_light_volume_resolution; }
void VoxelRendererSettings::set_max_local_shadow_lights(int v) { max_local_shadow_lights = std::clamp(v, 0, 32); }
int VoxelRendererSettings::get_max_local_shadow_lights() const { return max_local_shadow_lights; }
void VoxelRendererSettings::set_sun_shadows_enabled(bool v) { sun_shadows_enabled = v; }
bool VoxelRendererSettings::get_sun_shadows_enabled() const { return sun_shadows_enabled; }
void VoxelRendererSettings::set_voxel_size(double v) { voxel_size = std::max(0.001, v); }
double VoxelRendererSettings::get_voxel_size() const { return voxel_size; }
void VoxelRendererSettings::set_target_gpu_ms(double v) { target_gpu_ms = std::max(0.1, v); }
double VoxelRendererSettings::get_target_gpu_ms() const { return target_gpu_ms; }
void VoxelRendererSettings::set_p95_gpu_ms(double v) { p95_gpu_ms = std::max(target_gpu_ms, v); }
double VoxelRendererSettings::get_p95_gpu_ms() const { return p95_gpu_ms; }
