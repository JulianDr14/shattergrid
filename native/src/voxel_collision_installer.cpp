#include "voxel_collision_installer.hpp"

#include <algorithm>

#include <godot_cpp/classes/box_shape3d.hpp>
#include <godot_cpp/classes/collision_shape3d.hpp>
#include <godot_cpp/classes/concave_polygon_shape3d.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

void VoxelCollisionInstaller::_bind_methods() {
    ClassDB::bind_method(D_METHOD("install_concave", "parent", "existing", "voxel_shape",
                                 "faces", "shard_key", "macro"),
            &VoxelCollisionInstaller::install_concave);
    ClassDB::bind_method(D_METHOD("install_dynamic_boxes", "physics_body", "voxel_shapes",
                                 "max_boxes"),
            &VoxelCollisionInstaller::install_dynamic_boxes);
    ClassDB::bind_method(D_METHOD("queue_free_nodes", "nodes"),
            &VoxelCollisionInstaller::queue_free_nodes);
}

CollisionShape3D *VoxelCollisionInstaller::install_concave(Node *p_parent,
        CollisionShape3D *p_existing, Node3D *p_voxel_shape,
        const PackedVector3Array &p_faces, const String &p_shard_key,
        const Vector3i &p_macro) {
    if (p_parent == nullptr || p_voxel_shape == nullptr || p_faces.is_empty()) {
        return p_existing;
    }
    CollisionShape3D *collision = p_existing;
    if (collision == nullptr) {
        collision = memnew(CollisionShape3D);
        p_parent->add_child(collision);
        collision->set_meta("static_shard_key", p_shard_key);
        collision->set_meta("static_macro", p_macro);
    }
    Ref<ConcavePolygonShape3D> concave;
    concave.instantiate();
    // Destructible shells must collide from both sides once a hole exposes their interior.
    concave->set_backface_collision_enabled(true);
    concave->set_faces(p_faces);
    collision->set_shape(concave);
    collision->set_transform(p_voxel_shape->get_transform());
    return collision;
}

Dictionary VoxelCollisionInstaller::install_dynamic_boxes(
        Node *p_physics_body, const Array &p_voxel_shapes, int p_max_boxes) {
    Array nodes;
    PackedInt64Array shape_ids;
    PackedInt64Array revisions;
    int count = 0;
    int remaining = std::max(1, p_max_boxes);
    if (p_physics_body == nullptr) {
        Dictionary empty;
        empty["nodes"] = nodes;
        empty["shape_ids"] = shape_ids;
        empty["revisions"] = revisions;
        empty["count"] = 0;
        return empty;
    }
    for (int shape_index = 0; shape_index < p_voxel_shapes.size(); ++shape_index) {
        Object *shape_object = p_voxel_shapes[shape_index];
        Node3D *shape = Object::cast_to<Node3D>(shape_object);
        if (shape == nullptr || !shape->has_method("build_collision_boxes")) {
            continue;
        }
        const int shapes_left = std::max(1, static_cast<int>(p_voxel_shapes.size()) - shape_index);
        const int allowance = std::max(1, remaining / shapes_left);
        const Dictionary decomposition = shape->call("build_collision_boxes", allowance);
        const Array boxes = decomposition.get("boxes", Array());
        for (int box_index = 0; box_index < boxes.size(); ++box_index) {
            const Dictionary box = boxes[box_index];
            Ref<BoxShape3D> box_shape;
            box_shape.instantiate();
            box_shape->set_size(box.get("size", Vector3()));
            CollisionShape3D *collision = memnew(CollisionShape3D);
            collision->set_shape(box_shape);
            const Vector3 position = box.get("position", Vector3());
            collision->set_transform(shape->get_transform() *
                    Transform3D(Basis(), position));
            collision->set_meta("voxel_shape", shape);
            p_physics_body->add_child(collision);
            nodes.append(collision);
            count++;
        }
        remaining = std::max(0, p_max_boxes - count);
        shape_ids.append(static_cast<int64_t>(shape->get_instance_id()));
        revisions.append(shape->has_method("content_revision")
                ? static_cast<int64_t>(shape->call("content_revision")) : 0);
    }
    Dictionary result;
    result["nodes"] = nodes;
    result["shape_ids"] = shape_ids;
    result["revisions"] = revisions;
    result["count"] = count;
    return result;
}

void VoxelCollisionInstaller::queue_free_nodes(const Array &p_nodes) {
    for (int index = 0; index < p_nodes.size(); ++index) {
        Node *node = Object::cast_to<Node>(static_cast<Object *>(p_nodes[index]));
        if (node != nullptr) {
            node->queue_free();
        }
    }
}

} // namespace godot
