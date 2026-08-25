#pragma once

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

namespace godot {

class CollisionShape3D;
class Node;
class Node3D;

// Owns CollisionShape3D/Shape3D allocation and the dynamic box install loop. Body/shard lifetime
// stays with VoxelBody3D, which is the scene owner and decides when queue_free is safe.
class VoxelCollisionInstaller : public Resource {
    GDCLASS(VoxelCollisionInstaller, Resource)

protected:
    static void _bind_methods();

public:
    CollisionShape3D *install_concave(Node *p_parent, CollisionShape3D *p_existing,
            Node3D *p_voxel_shape, const PackedVector3Array &p_faces,
            const String &p_shard_key, const Vector3i &p_macro);
    Dictionary install_dynamic_boxes(Node *p_physics_body, const Array &p_voxel_shapes,
            int p_max_boxes);
    void queue_free_nodes(const Array &p_nodes);
};

} // namespace godot
