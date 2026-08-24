#include "voxel_palette.hpp"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>

using namespace godot;

namespace {
constexpr int PALETTE_SIZE = 256;

double number_or(const Dictionary &dictionary, const StringName &key, double fallback) {
    return dictionary.has(key) ? static_cast<double>(dictionary[key]) : fallback;
}
} // namespace

VoxelPalette::VoxelPalette() {
    initialize_defaults();
}

void VoxelPalette::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_material", "index", "properties"), &VoxelPalette::set_material);
    ClassDB::bind_method(D_METHOD("get_material", "index"), &VoxelPalette::get_material);
    ClassDB::bind_method(D_METHOD("get_colors"), &VoxelPalette::get_colors);
    ClassDB::bind_method(D_METHOD("get_render_properties"),
            &VoxelPalette::get_render_properties);
    ClassDB::bind_method(D_METHOD("get_hardnesses"), &VoxelPalette::get_hardnesses);
    ClassDB::bind_method(D_METHOD("get_densities"), &VoxelPalette::get_densities);
    ClassDB::bind_method(D_METHOD("get_capacity"), &VoxelPalette::get_capacity);
    ADD_PROPERTY(PropertyInfo(Variant::PACKED_COLOR_ARRAY, "colors", PROPERTY_HINT_NONE, "",
                         PROPERTY_USAGE_READ_ONLY),
            "", "get_colors");
}

void VoxelPalette::initialize_defaults() {
    colors.resize(PALETTE_SIZE);
    opacity.resize(PALETTE_SIZE);
    roughness.resize(PALETTE_SIZE);
    metallic.resize(PALETTE_SIZE);
    emission.resize(PALETTE_SIZE);
    hardness.resize(PALETTE_SIZE);
    density.resize(PALETTE_SIZE);
    friction.resize(PALETTE_SIZE);
    restitution.resize(PALETTE_SIZE);
    for (int i = 0; i < PALETTE_SIZE; ++i) {
        colors.set(i, i == 0 ? Color(0, 0, 0, 0) : Color(0.65, 0.65, 0.65, 1));
        opacity.set(i, i == 0 ? 0.0f : 1.0f);
        roughness.set(i, 0.82f);
        metallic.set(i, 0.0f);
        emission.set(i, 0.0f);
        hardness.set(i, i == 0 ? 0.0f : 1.0f);
        density.set(i, i == 0 ? 0.0f : 1800.0f);
        friction.set(i, 0.9f);
        restitution.set(i, 0.02f);
    }
    colors.set(1, Color("b85a36"));
    colors.set(2, Color("a8a9ad"));
    colors.set(3, Color("59636e"));
    density.set(2, 2520.0f);
    density.set(3, 7200.0f);
    hardness.set(2, 1.3f);
    hardness.set(3, 1.6f);
    metallic.set(3, 0.55f);
    roughness.set(3, 0.35f);
}

bool VoxelPalette::set_material(int p_index, const Dictionary &p_properties) {
    if (p_index <= 0 || p_index >= PALETTE_SIZE) {
        return false;
    }
    if (p_properties.has("color")) {
        colors.set(p_index, p_properties["color"]);
    }
    opacity.set(p_index, static_cast<float>(std::clamp(number_or(p_properties, "opacity", opacity[p_index]), 0.0, 1.0)));
    Color material_color = colors[p_index];
    material_color.a = opacity[p_index];
    colors.set(p_index, material_color);
    roughness.set(p_index, static_cast<float>(std::clamp(number_or(p_properties, "roughness", roughness[p_index]), 0.0, 1.0)));
    metallic.set(p_index, static_cast<float>(std::clamp(number_or(p_properties, "metallic", metallic[p_index]), 0.0, 1.0)));
    emission.set(p_index, static_cast<float>(std::max(0.0, number_or(p_properties, "emission", emission[p_index]))));
    hardness.set(p_index, static_cast<float>(std::max(0.001, number_or(p_properties, "hardness", hardness[p_index]))));
    density.set(p_index, static_cast<float>(std::max(0.0, number_or(p_properties, "density", density[p_index]))));
    friction.set(p_index, static_cast<float>(std::clamp(number_or(p_properties, "friction", friction[p_index]), 0.0, 2.0)));
    restitution.set(p_index, static_cast<float>(std::clamp(number_or(p_properties, "restitution", restitution[p_index]), 0.0, 1.0)));
    return true;
}

Dictionary VoxelPalette::get_material(int p_index) const {
    Dictionary result;
    if (p_index < 0 || p_index >= PALETTE_SIZE) {
        return result;
    }
    result["color"] = colors[p_index];
    result["opacity"] = opacity[p_index];
    result["roughness"] = roughness[p_index];
    result["metallic"] = metallic[p_index];
    result["emission"] = emission[p_index];
    result["hardness"] = hardness[p_index];
    result["density"] = density[p_index];
    result["friction"] = friction[p_index];
    result["restitution"] = restitution[p_index];
    return result;
}

PackedColorArray VoxelPalette::get_colors() const { return colors; }
PackedColorArray VoxelPalette::get_render_properties() const {
    PackedColorArray result;
    result.resize(PALETTE_SIZE);
    for (int index = 0; index < PALETTE_SIZE; ++index) {
        // The GPU palette is RGBA8. Emission is normalized from Teardown's 0..32 material
        // range and expanded again in the shader; the other channels are already normalized.
        result.set(index, Color(roughness[index], metallic[index],
                std::clamp(emission[index] / 32.0f, 0.0f, 1.0f), 0.0f));
    }
    return result;
}
PackedFloat32Array VoxelPalette::get_hardnesses() const { return hardness; }
PackedFloat32Array VoxelPalette::get_densities() const { return density; }
int VoxelPalette::get_capacity() const { return PALETTE_SIZE - 1; }
