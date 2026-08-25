#include "voxel_asset_decoder.hpp"

#include "voxel_shape_data.hpp"

#include <algorithm>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>

namespace godot {

namespace {

constexpr int MAX_VOXEL_CELLS = 512 * 1024 * 1024;

int32_t read_i32(const PackedByteArray &p_bytes, int64_t &r_cursor) {
    if (r_cursor < 0 || r_cursor + 4 > p_bytes.size()) {
        r_cursor = p_bytes.size();
        return 0;
    }
    const int32_t value = p_bytes.decode_s32(r_cursor);
    r_cursor += 4;
    return value;
}

String read_string(const PackedByteArray &p_bytes, int64_t &r_cursor) {
    const int32_t length = std::max(0, read_i32(p_bytes, r_cursor));
    const int64_t end = std::min(static_cast<int64_t>(p_bytes.size()), r_cursor + length);
    const String result = p_bytes.slice(r_cursor, end).get_string_from_utf8();
    r_cursor = end;
    return result;
}

Dictionary read_dictionary(const PackedByteArray &p_bytes, int64_t &r_cursor) {
    Dictionary result;
    const int32_t count = std::max(0, read_i32(p_bytes, r_cursor));
    for (int index = 0; index < count && r_cursor < p_bytes.size(); ++index) {
        const String key = read_string(p_bytes, r_cursor);
        result[key] = read_string(p_bytes, r_cursor);
    }
    return result;
}

Basis decode_rotation(int p_encoded) {
    const int first_axis = p_encoded & 0x3;
    const int second_axis = (p_encoded >> 2) & 0x3;
    if (first_axis > 2 || second_axis > 2 || first_axis == second_axis) {
        return Basis();
    }
    const int third_axis = 3 - first_axis - second_axis;
    Vector3 rows[3];
    rows[0][first_axis] = (p_encoded & 0x10) != 0 ? -1.0 : 1.0;
    rows[1][second_axis] = (p_encoded & 0x20) != 0 ? -1.0 : 1.0;
    rows[2][third_axis] = (p_encoded & 0x40) != 0 ? -1.0 : 1.0;
    const Basis source = Basis(rows[0], rows[1], rows[2]).transposed();
    const Basis swap(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0),
            Vector3(0.0, 1.0, 0.0));
    return swap * source * swap.inverse();
}

Transform3D frame_transform(const Dictionary &p_frame, double p_voxel_size) {
    Vector3 translation;
    const PackedStringArray parts =
            static_cast<String>(p_frame.get("_t", String())).split(" ", false);
    if (parts.size() == 3) {
        translation = Vector3(parts[0].to_float(), parts[2].to_float(),
                parts[1].to_float()) * p_voxel_size;
    }
    return Transform3D(decode_rotation(
            static_cast<String>(p_frame.get("_r", String("4"))).to_int()), translation);
}

void walk_node(int p_node_id, const Transform3D &p_parent, const Dictionary &p_nodes,
        Array &r_instances, std::unordered_set<int> &r_path) {
    if (!p_nodes.has(p_node_id) || !r_path.insert(p_node_id).second) {
        return;
    }
    const Dictionary node = p_nodes[p_node_id];
    const Transform3D transform = p_parent *
            static_cast<Transform3D>(node.get("transform", Transform3D()));
    const String type = node.get("type", String());
    if (type == "transform") {
        walk_node(static_cast<int>(node.get("child", -1)), transform, p_nodes,
                r_instances, r_path);
    } else if (type == "group") {
        const Array children = node.get("children", Array());
        for (int index = 0; index < children.size(); ++index) {
            walk_node(children[index], transform, p_nodes, r_instances, r_path);
        }
    } else if (type == "shape") {
        const Array models = node.get("models", Array());
        for (int index = 0; index < models.size(); ++index) {
            Dictionary instance;
            instance["model"] = models[index];
            instance["transform"] = transform;
            r_instances.append(instance);
        }
    }
    r_path.erase(p_node_id);
}

Array resolve_instances(const Dictionary &p_nodes, int p_model_count) {
    Array result;
    if (p_nodes.is_empty()) {
        for (int model = 0; model < p_model_count; ++model) {
            Dictionary instance;
            instance["model"] = model;
            instance["transform"] = Transform3D();
            result.append(instance);
        }
        return result;
    }
    std::unordered_set<int> referenced;
    const Array values = p_nodes.values();
    for (int index = 0; index < values.size(); ++index) {
        const Dictionary node = values[index];
        if (node.has("child")) {
            referenced.insert(node["child"]);
        }
        const Array children = node.get("children", Array());
        for (int child = 0; child < children.size(); ++child) {
            referenced.insert(children[child]);
        }
    }
    const Array keys = p_nodes.keys();
    for (int index = 0; index < keys.size(); ++index) {
        const int root = keys[index];
        if (referenced.count(root) != 0) {
            continue;
        }
        std::unordered_set<int> path;
        walk_node(root, Transform3D(), p_nodes, result, path);
    }
    return result;
}

Dictionary convert_model(const Dictionary &p_model, int p_scale, int p_shell) {
    const Vector3i source_size = p_model.get("size", Vector3i());
    const PackedByteArray source = p_model.get("cells", PackedByteArray());
    const int64_t source_cells = static_cast<int64_t>(source_size.x) * source_size.y * source_size.z;
    if (source_size.x <= 0 || source_size.y <= 0 || source_size.z <= 0 ||
            source_cells > source.size()) {
        return Dictionary();
    }
    Vector3i low = source_size;
    Vector3i high(-1, -1, -1);
    for (int z = 0; z < source_size.z; ++z) {
        for (int y = 0; y < source_size.y; ++y) {
            for (int x = 0; x < source_size.x; ++x) {
                const int64_t source_index = x + y * source_size.x +
                        static_cast<int64_t>(z) * source_size.x * source_size.y;
                if (source[source_index] != 0) {
                    const Vector3i runtime(x, z, y);
                    low = low.min(runtime);
                    high = high.max(runtime);
                }
            }
        }
    }
    if (high.x < low.x) {
        return Dictionary();
    }
    p_scale = std::max(1, p_scale);
    const Vector3i dimensions = (high - low + Vector3i(1, 1, 1)) * p_scale;
    const int64_t target_count =
            static_cast<int64_t>(dimensions.x) * dimensions.y * dimensions.z;
    if (target_count <= 0 || target_count > MAX_VOXEL_CELLS) {
        return Dictionary();
    }
    PackedByteArray cells;
    cells.resize(target_count);
    for (int z = 0; z < source_size.z; ++z) {
        for (int y = 0; y < source_size.y; ++y) {
            for (int x = 0; x < source_size.x; ++x) {
                const int64_t source_index = x + y * source_size.x +
                        static_cast<int64_t>(z) * source_size.x * source_size.y;
                const uint8_t material = source[source_index];
                if (material == 0) {
                    continue;
                }
                const Vector3i local = (Vector3i(x, z, y) - low) * p_scale;
                for (int dy = 0; dy < p_scale; ++dy) {
                    for (int dz = 0; dz < p_scale; ++dz) {
                        for (int dx = 0; dx < p_scale; ++dx) {
                            const int64_t target = local.x + dx +
                                    static_cast<int64_t>(local.y + dy) * dimensions.x +
                                    static_cast<int64_t>(local.z + dz) * dimensions.x * dimensions.y;
                            cells.set(target, material);
                        }
                    }
                }
            }
        }
    }
    Ref<VoxelShapeData> data;
    data.instantiate();
    if (!data->set_cells(dimensions, cells)) {
        return Dictionary();
    }
    if (std::min(dimensions.x, std::min(dimensions.y, dimensions.z)) >= 24) {
        data->hollow(std::max(0, p_shell));
    }
    PackedInt32Array anchors;
    for (int z = 0; z < dimensions.z; ++z) {
        for (int x = 0; x < dimensions.x; ++x) {
            const int index = x + z * dimensions.x * dimensions.y;
            if (cells[index] != 0) {
                anchors.append(index);
            }
        }
    }
    Dictionary result;
    result["data"] = data;
    result["dimensions"] = dimensions;
    result["anchors"] = anchors;
    return result;
}

} // namespace

void VoxelAssetDecoder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("decode", "path", "scale", "shell", "voxel_size"),
            &VoxelAssetDecoder::decode, DEFVAL(2), DEFVAL(2), DEFVAL(0.1));
}

Dictionary VoxelAssetDecoder::decode(
        const String &p_path, int p_scale, int p_shell, double p_voxel_size) const {
    Dictionary output;
    output["ok"] = false;
    if (!FileAccess::file_exists(p_path)) {
        output["error"] = "missing";
        return output;
    }
    const PackedByteArray bytes = FileAccess::get_file_as_bytes(p_path);
    if (bytes.size() < 20 || bytes.slice(0, 4).get_string_from_ascii() != "VOX ") {
        output["error"] = "invalid_header";
        return output;
    }
    Array models;
    Dictionary nodes;
    Dictionary materials;
    PackedColorArray palette;
    palette.resize(256);
    palette.set(0, Color(0.0, 0.0, 0.0, 0.0));
    for (int index = 1; index < 256; ++index) {
        const double gray = static_cast<double>(index) / 255.0;
        palette.set(index, Color(gray, gray, gray));
    }
    Vector3i pending_size;
    int64_t offset = 20;
    while (offset + 12 <= bytes.size()) {
        const String chunk = bytes.slice(offset, offset + 4).get_string_from_ascii();
        const int32_t content_size = bytes.decode_s32(offset + 4);
        const int64_t start = offset + 12;
        if (content_size < 0 || start + content_size > bytes.size()) {
            output["error"] = "truncated_chunk";
            return output;
        }
        if (chunk == "SIZE" && content_size >= 12) {
            pending_size = Vector3i(bytes.decode_s32(start), bytes.decode_s32(start + 4),
                    bytes.decode_s32(start + 8));
        } else if (chunk == "XYZI" && pending_size != Vector3i() && content_size >= 4) {
            PackedByteArray dense;
            const int64_t dense_count = static_cast<int64_t>(pending_size.x) *
                    pending_size.y * pending_size.z;
            if (dense_count > 0 && dense_count <= MAX_VOXEL_CELLS) {
                dense.resize(dense_count);
                const int count = std::min(std::max(0,
                        static_cast<int>(bytes.decode_s32(start))), (content_size - 4) / 4);
                for (int voxel = 0; voxel < count; ++voxel) {
                    const int64_t at = start + 4 + voxel * 4;
                    const int x = bytes[at], y = bytes[at + 1], z = bytes[at + 2];
                    if (x < pending_size.x && y < pending_size.y && z < pending_size.z) {
                        dense.set(x + y * pending_size.x +
                                static_cast<int64_t>(z) * pending_size.x * pending_size.y,
                                bytes[at + 3]);
                    }
                }
                Dictionary model;
                model["size"] = pending_size;
                model["cells"] = dense;
                models.append(model);
            }
            pending_size = Vector3i();
        } else if (chunk == "RGBA") {
            const int count = std::min(255, content_size / 4);
            for (int index = 0; index < count; ++index) {
                const int64_t at = start + index * 4;
                palette.set(index + 1, Color::from_rgba8(
                        bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]));
            }
        } else if (chunk == "MATL" && content_size >= 8) {
            int64_t cursor = start + 4;
            materials[bytes.decode_s32(start)] = read_dictionary(bytes, cursor);
        } else if (chunk == "nTRN" && content_size >= 4) {
            int64_t cursor = start;
            const int node_id = read_i32(bytes, cursor);
            read_dictionary(bytes, cursor);
            const int child = read_i32(bytes, cursor);
            read_i32(bytes, cursor);
            read_i32(bytes, cursor);
            const int frames = std::max(0, read_i32(bytes, cursor));
            Transform3D transform;
            for (int frame = 0; frame < frames; ++frame) {
                const Dictionary attributes = read_dictionary(bytes, cursor);
                if (frame == 0) {
                    transform = frame_transform(attributes, p_voxel_size);
                }
            }
            Dictionary node;
            node["type"] = "transform";
            node["child"] = child;
            node["transform"] = transform;
            nodes[node_id] = node;
        } else if (chunk == "nGRP" && content_size >= 4) {
            int64_t cursor = start;
            const int node_id = read_i32(bytes, cursor);
            read_dictionary(bytes, cursor);
            const int count = std::max(0, read_i32(bytes, cursor));
            Array children;
            for (int index = 0; index < count; ++index) {
                children.append(read_i32(bytes, cursor));
            }
            Dictionary node;
            node["type"] = "group";
            node["children"] = children;
            nodes[node_id] = node;
        } else if (chunk == "nSHP" && content_size >= 4) {
            int64_t cursor = start;
            const int node_id = read_i32(bytes, cursor);
            read_dictionary(bytes, cursor);
            const int count = std::max(0, read_i32(bytes, cursor));
            Array model_ids;
            for (int index = 0; index < count; ++index) {
                model_ids.append(read_i32(bytes, cursor));
                read_dictionary(bytes, cursor);
            }
            Dictionary node;
            node["type"] = "shape";
            node["models"] = model_ids;
            nodes[node_id] = node;
        }
        offset = start + content_size;
    }
    if (models.is_empty()) {
        output["error"] = "no_models";
        return output;
    }
    const Array instances = resolve_instances(nodes, models.size());
    Array shapes;
    for (int index = 0; index < instances.size(); ++index) {
        const Dictionary instance = instances[index];
        const int model_id = instance.get("model", 0);
        if (model_id < 0 || model_id >= models.size()) {
            continue;
        }
        // Each scene instance must own independent mutable voxel data: sharing the converted
        // Resource would make damage to one repeated model appear in every copy.
        const Dictionary converted = convert_model(models[model_id], p_scale, p_shell);
        if (converted.is_empty()) {
            continue;
        }
        Transform3D transform = instance.get("transform", Transform3D());
        const Vector3i dimensions = converted["dimensions"];
        transform.origin += Vector3(0.0, dimensions.y * p_voxel_size * 0.5, 0.0);
        Dictionary shape;
        shape["data"] = converted["data"];
        shape["transform"] = transform;
        shape["anchors"] = converted["anchors"];
        shape["model_id"] = model_id;
        shapes.append(shape);
    }
    output["ok"] = true;
    output["shapes"] = shapes;
    output["colors"] = palette;
    output["material_attributes"] = materials;
    return output;
}

} // namespace godot
