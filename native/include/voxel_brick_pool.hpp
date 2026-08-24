#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "voxel_shape_data.hpp"

namespace godot {

/// Almacén de bricks de 8x8x8 para el atlas de voxeles.
///
/// El atlas denso reservaba el volumen entero de cada Shape: en el mapa de Teardown son 453 M de
/// celdas para 79 M de voxeles llenos, un 17 % de relleno, y no cabía en la GPU. Aquí solo se
/// reserva una macrocelda cuando tiene algo dentro, y el shader llega a ella por una tabla
/// `macrocelda -> slot`. El resto del aire deja de ocupar VRAM.
///
/// El buffer vive en C++ a propósito: los `PackedByteArray` de GDScript son copy-on-write, así que
/// pasar un pool de 150 MB a una función para que escriba dentro lo copiaría entero en cada Shape.
class VoxelBrickPool : public RefCounted {
    GDCLASS(VoxelBrickPool, RefCounted)

public:
    static constexpr int BRICK = VoxelShapeData::MACRO_SIZE;
    static constexpr int BRICK_CELLS = BRICK * BRICK * BRICK;

private:
    PackedByteArray bytes;
    Vector3i grid;
    int used = 0;

    void write_brick_cells(const VoxelShapeData &p_data, int p_slot, int p_mx, int p_my, int p_mz);

protected:
    static void _bind_methods();

public:
    bool configure(const Vector3i &p_grid);
    void reset();

    Vector3i get_grid() const;
    /// Tamaño de la textura 3D, en texeles.
    Vector3i get_dimensions() const;
    int get_capacity() const;
    int get_used() const;
    PackedByteArray get_bytes() const;
    Vector3i get_slot_origin(int p_slot) const;

    /// Reserva un brick por cada macrocelda ocupada de la Shape y devuelve la tabla
    /// `índice de macrocelda -> slot` (-1 donde no hay nada). Vacía si el pool se ha llenado.
    PackedInt32Array append_shape(const Ref<VoxelShapeData> &p_data);

    /// Reescribe un brick tras un impacto y devuelve sus 512 bytes ya empaquetados para subirlos.
    PackedByteArray refresh_brick(const Ref<VoxelShapeData> &p_data, int p_slot, const Vector3i &p_macro);

    /// Empaqueta los bricks `[p_base, p_base + p_count)` — los de una Shape recién añadida, que van
    /// seguidos — en tandas listas para `VoxelAtlas3D.update_compact_regions`.
    Array extract_uploads(int p_base, int p_count) const;
};

} // namespace godot
