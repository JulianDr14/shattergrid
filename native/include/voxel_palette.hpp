#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

namespace godot {

class VoxelPalette : public Resource {
    GDCLASS(VoxelPalette, Resource)

    PackedColorArray colors;
    PackedFloat32Array opacity;
    PackedFloat32Array roughness;
    PackedFloat32Array metallic;
    PackedFloat32Array emission;
    PackedFloat32Array hardness;
    PackedFloat32Array density;
    PackedFloat32Array friction;
    PackedFloat32Array restitution;

    void initialize_defaults();

protected:
    static void _bind_methods();

public:
    VoxelPalette();

    bool set_material(int p_index, const Dictionary &p_properties);
    Dictionary get_material(int p_index) const;
    PackedColorArray get_colors() const;
    PackedColorArray get_render_properties() const;
    PackedFloat32Array get_hardnesses() const;
    PackedFloat32Array get_densities() const;
    int get_capacity() const;
};

} // namespace godot
