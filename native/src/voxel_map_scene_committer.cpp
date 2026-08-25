#include "voxel_map_scene_committer.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

void VoxelMapSceneCommitter::_bind_methods() {
    ClassDB::bind_method(D_METHOD("attach", "body_script", "shape_script", "data", "transform",
                                 "voxel_size", "palette", "context", "collides", "baked_faces",
                                 "use_baked_collision", "density_scale", "collision_enabled",
                                 "eager_cache", "dynamic_fill_scale", "body_index",
                                 "vehicle_visual_index"),
            &VoxelMapSceneCommitter::attach);
}

Dictionary VoxelMapSceneCommitter::attach(Object *p_body_script, Object *p_shape_script,
        const Ref<VoxelShapeData> &p_data, const Transform3D &p_transform,
        double p_voxel_size, const Ref<VoxelPalette> &p_palette, const Dictionary &p_context,
        bool p_collides, const Array &p_baked_faces, bool p_use_baked_collision,
        double p_density_scale, bool p_collision_enabled, bool p_eager_cache,
        double p_dynamic_fill_scale, int p_body_index, int p_vehicle_visual_index) const {
    Dictionary result;
    result["ok"] = false;
    if (p_body_script == nullptr || p_shape_script == nullptr || p_data.is_null()) {
        return result;
    }
    Node3D *shape = Object::cast_to<Node3D>(
            static_cast<Object *>(p_shape_script->call("new")));
    Node *world = Object::cast_to<Node>(static_cast<Object *>(p_context.get("world", Variant())));
    if (shape == nullptr || world == nullptr) {
        if (shape != nullptr) {
            shape->queue_free();
        }
        return result;
    }
    const bool dynamic_context = p_context.get("dynamic", false);
    const double density = std::max(0.001, p_density_scale);
    shape->set("data", p_data);
    shape->set("palette", p_palette);
    shape->set("voxel_size", p_voxel_size);
    shape->set("density_scale", density);
    shape->set("physical_fill_scale",
            dynamic_context && p_collides ? p_dynamic_fill_scale : 1.0);
    shape->set("anchored", false);
    shape->set_transform(p_transform);

    Dictionary vehicle = p_context.get("vehicle", Dictionary());
    Dictionary wheel = p_context.get("vehicle_wheel", Dictionary());
    const bool wheel_visual = !vehicle.is_empty() && !wheel.is_empty();
    Node *body = Object::cast_to<Node>(static_cast<Object *>(p_context.get("body", Variant())));
    int bodies_created = 0;
    int visual_bodies_created = 0;
    int no_collide = 0;
    if (wheel_visual) {
        body = Object::cast_to<Node>(static_cast<Object *>(vehicle.get("visual_body", Variant())));
        if (body == nullptr) {
            body = Object::cast_to<Node>(static_cast<Object *>(p_body_script->call("new")));
            if (body == nullptr) {
                shape->queue_free();
                return result;
            }
            body->set_name(String("TeardownVehicleWheels") + String::num_int64(p_vehicle_visual_index));
            body->set("state", 1);
            body->set("structural", false);
            body->set("collision_enabled", false);
            world->add_child(body);
            vehicle["visual_body"] = body;
            bodies_created++;
            visual_bodies_created++;
        }
        shape->set_meta("vehicle_wheel_visual", true);
        Array wheel_shapes = wheel.get("shapes", Array());
        wheel_shapes.append(shape);
        wheel["shapes"] = wheel_shapes;
        no_collide++;
    } else if (!p_collides) {
        body = nullptr;
        no_collide++;
    }
    if (body == nullptr) {
        body = Object::cast_to<Node>(static_cast<Object *>(p_body_script->call("new")));
        if (body == nullptr) {
            shape->queue_free();
            return result;
        }
        body->set_name(String("TeardownBody") + String::num_int64(p_body_index));
        body->set("state", dynamic_context && p_collides ? 1 : 0);
        body->set("collision_enabled", p_collision_enabled && p_collides);
        world->add_child(body);
        bodies_created++;
        if (dynamic_context && p_collides) {
            Dictionary mutable_context = p_context;
            mutable_context["body"] = body;
        }
    }
    if (!wheel_visual && !vehicle.is_empty() && dynamic_context && p_collides &&
            static_cast<Object *>(vehicle.get("body", Variant())) == nullptr) {
        vehicle["body"] = body;
    }
    const auto started = std::chrono::steady_clock::now();
    const bool dynamic_body = static_cast<int>(body->get("state")) == 1;
    body->call("add_voxel_shape", shape, false,
            !dynamic_body && !p_use_baked_collision);
    if (!dynamic_body && p_use_baked_collision) {
        if (p_eager_cache) {
            body->call("import_baked_static_collision", shape, p_baked_faces);
            // Eager mode installs the complete cached record set in this call. Streaming mode
            // acknowledges only after its final block; leaving eager at revision zero made the
            // diagnostics report the same false collision DESYNC fixed for empty cached Shapes.
            body->call("acknowledge_static_collision_revision", shape);
        } else {
            world->call("queue_baked_static_collision", body, shape, p_baked_faces);
        }
    }
    const auto elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
    const Vector3 dimensions = Vector3(p_data->get_dimensions()) * p_voxel_size;
    result["ok"] = true;
    result["body"] = body;
    result["shape"] = shape;
    result["bodies_created"] = bodies_created;
    result["visual_bodies_created"] = visual_bodies_created;
    result["no_collide"] = no_collide;
    result["density_override"] = std::abs(density - 1.0) > 0.00001;
    result["collision_ms"] = elapsed;
    result["faces_ms"] = body->get("last_faces_ms");
    result["voxels"] = p_data->get_occupied_count();
    result["bounds"] = p_transform.xform(AABB(-dimensions * 0.5, dimensions));
    return result;
}

} // namespace godot
