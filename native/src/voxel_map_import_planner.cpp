#include "voxel_map_import_planner.hpp"

#include <cmath>
#include <limits>
#include <vector>

#include <godot_cpp/classes/xml_parser.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

namespace godot {

namespace {

constexpr double PI_VALUE = 3.14159265358979323846;

Vector3 record_position(const Dictionary &p_record) {
    const Transform3D transform = p_record.get("transform", Transform3D());
    return transform.origin;
}

Transform3D element_transform(const Dictionary &p_element, const Transform3D &p_parent) {
    const Dictionary attributes = p_element.get("attributes", Dictionary());
    const String rotation_text = attributes.get("rot", String());
    const PackedStringArray rotation = rotation_text.split(" ", false);
    Quaternion quaternion;
    if (rotation.size() == 3) {
        const double roll = rotation[0].to_float() * PI_VALUE / 360.0;
        const double yaw = rotation[1].to_float() * PI_VALUE / 360.0;
        const double pitch = rotation[2].to_float() * PI_VALUE / 360.0;
        const double c1 = std::cos(roll), s1 = std::sin(roll);
        const double c2 = std::cos(yaw), s2 = std::sin(yaw);
        const double c3 = std::cos(pitch), s3 = std::sin(pitch);
        quaternion = Quaternion(s1 * c2 * c3 + c1 * s2 * s3,
                c1 * s2 * c3 + s1 * c2 * s3,
                c1 * c2 * s3 - s1 * s2 * c3,
                c1 * c2 * c3 - s1 * s2 * s3);
    }
    const PackedStringArray position_parts =
            static_cast<String>(attributes.get("pos", String())).split(" ", false);
    Vector3 position;
    if (position_parts.size() >= 2) {
        position = Vector3(position_parts[0].to_float(), position_parts[1].to_float(),
                position_parts.size() > 2 ? position_parts[2].to_float() : 0.0);
    }
    return p_parent * Transform3D(Basis(quaternion), position);
}

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
    const int32_t requested = std::max(0, read_i32(p_bytes, r_cursor));
    const int64_t end = std::min(static_cast<int64_t>(p_bytes.size()), r_cursor + requested);
    const String value = p_bytes.slice(r_cursor, end).get_string_from_utf8();
    r_cursor = end;
    return value;
}

Dictionary read_dictionary(const PackedByteArray &p_bytes, int64_t &r_cursor) {
    Dictionary result;
    const int32_t count = std::max(0, read_i32(p_bytes, r_cursor));
    for (int index = 0; index < count; ++index) {
        const String key = read_string(p_bytes, r_cursor);
        const String value = read_string(p_bytes, r_cursor);
        result[key] = value;
    }
    return result;
}

} // namespace

void VoxelMapImportPlanner::_bind_methods() {
    ClassDB::bind_method(D_METHOD("parse_xml", "path"), &VoxelMapImportPlanner::parse_xml);
    ClassDB::bind_method(D_METHOD("parse_named_vox", "path"),
            &VoxelMapImportPlanner::parse_named_vox);
    ClassDB::bind_method(D_METHOD("parse_vec3", "text"), &VoxelMapImportPlanner::parse_vec3);
    ClassDB::bind_method(D_METHOD("parse_rotation", "text"),
            &VoxelMapImportPlanner::parse_rotation);
    ClassDB::bind_method(D_METHOD("parse_float_values", "text", "count"),
            &VoxelMapImportPlanner::parse_float_values);
    ClassDB::bind_method(D_METHOD("centroid", "root", "parent_transform"),
            &VoxelMapImportPlanner::centroid);
    ClassDB::bind_method(D_METHOD("find_boundary_points", "root", "parent_transform"),
            &VoxelMapImportPlanner::find_boundary_points);
    ClassDB::bind_method(D_METHOD("classify_door_joint_records", "records", "body_bounds"),
            &VoxelMapImportPlanner::classify_door_joint_records);
}

Dictionary VoxelMapImportPlanner::parse_xml(const String &p_path) const {
    Ref<XMLParser> parser;
    parser.instantiate();
    if (parser->open(p_path) != OK) {
        return Dictionary();
    }
    Dictionary root;
    root["tag"] = "";
    root["attributes"] = Dictionary();
    root["children"] = Array();
    std::vector<Dictionary> stack;
    stack.push_back(root);
    while (parser->read() == OK) {
        if (parser->get_node_type() == XMLParser::NODE_ELEMENT) {
            Dictionary attributes;
            for (int index = 0; index < parser->get_attribute_count(); ++index) {
                attributes[parser->get_attribute_name(index)] =
                        parser->get_attribute_value(index);
            }
            Dictionary element;
            element["tag"] = parser->get_node_name();
            element["attributes"] = attributes;
            element["children"] = Array();
            Array children = stack.back()["children"];
            children.append(element);
            stack.back()["children"] = children;
            if (!parser->is_empty()) {
                stack.push_back(element);
            }
        } else if (parser->get_node_type() == XMLParser::NODE_ELEMENT_END && stack.size() > 1) {
            stack.pop_back();
        }
    }
    const Array children = root["children"];
    return children.is_empty() ? Dictionary() : static_cast<Dictionary>(children[0]);
}

Dictionary VoxelMapImportPlanner::parse_named_vox(const String &p_path) const {
    Dictionary output;
    output["ok"] = false;
    if (!FileAccess::file_exists(p_path)) {
        return output;
    }
    const PackedByteArray bytes = FileAccess::get_file_as_bytes(p_path);
    if (bytes.size() < 20 || bytes.slice(0, 4).get_string_from_ascii() != "VOX ") {
        return output;
    }
    PackedColorArray colors;
    colors.resize(256);
    Dictionary material_attributes;
    PackedByteArray imap;
    Array sizes;
    Array payloads;
    Array names;
    Vector3i pending;
    int64_t offset = 20;
    while (offset + 12 <= bytes.size()) {
        const String chunk = bytes.slice(offset, offset + 4).get_string_from_ascii();
        const int32_t size = bytes.decode_s32(offset + 4);
        const int64_t start = offset + 12;
        if (size < 0 || start + size > bytes.size()) {
            break;
        }
        if (chunk == "SIZE" && size >= 12) {
            pending = Vector3i(bytes.decode_s32(start), bytes.decode_s32(start + 4),
                    bytes.decode_s32(start + 8));
        } else if (chunk == "XYZI" && size >= 4) {
            const int32_t count = std::min(
                    static_cast<int32_t>(bytes.decode_s32(start)), (size - 4) / 4);
            sizes.append(pending);
            payloads.append(bytes.slice(start + 4, start + 4 + std::max(0, count) * 4));
        } else if (chunk == "RGBA") {
            const int color_count = std::min(255, size / 4);
            for (int index = 0; index < color_count; ++index) {
                const int64_t at = start + index * 4;
                colors.set(index + 1, Color::from_rgba8(
                        bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]));
            }
        } else if (chunk == "IMAP") {
            imap = bytes.slice(start, start + std::min(size, 256));
        } else if (chunk == "MATL" && size >= 8) {
            int64_t cursor = start + 4;
            material_attributes[bytes.decode_s32(start)] = read_dictionary(bytes, cursor);
        } else if (chunk == "nTRN" && size >= 4) {
            int64_t cursor = start + 4;
            const Dictionary attributes = read_dictionary(bytes, cursor);
            if (attributes.has("_name")) {
                names.append(attributes["_name"]);
            }
        }
        offset = start + size;
    }
    Dictionary models;
    const int model_count = std::min(sizes.size(), std::min(payloads.size(), names.size()));
    for (int index = 0; index < model_count; ++index) {
        Dictionary model;
        model["size"] = sizes[index];
        model["xyzi"] = payloads[index];
        models[names[index]] = model;
    }
    output["ok"] = true;
    output["models"] = models;
    output["colors"] = colors;
    output["material_attributes"] = material_attributes;
    output["imap"] = imap;
    return output;
}

Vector3 VoxelMapImportPlanner::parse_vec3(const String &p_text) const {
    const PackedStringArray parts = p_text.split(" ", false);
    if (parts.size() < 2) {
        return Vector3();
    }
    return Vector3(parts[0].to_float(), parts[1].to_float(),
            parts.size() > 2 ? parts[2].to_float() : 0.0);
}

Quaternion VoxelMapImportPlanner::parse_rotation(const String &p_text) const {
    const PackedStringArray parts = p_text.split(" ", false);
    if (parts.size() != 3) {
        return Quaternion();
    }
    const double roll = parts[0].to_float() * PI_VALUE / 360.0;
    const double yaw = parts[1].to_float() * PI_VALUE / 360.0;
    const double pitch = parts[2].to_float() * PI_VALUE / 360.0;
    const double c1 = std::cos(roll), s1 = std::sin(roll);
    const double c2 = std::cos(yaw), s2 = std::sin(yaw);
    const double c3 = std::cos(pitch), s3 = std::sin(pitch);
    return Quaternion(s1 * c2 * c3 + c1 * s2 * s3,
            c1 * s2 * c3 + s1 * c2 * s3,
            c1 * c2 * s3 - s1 * s2 * c3,
            c1 * c2 * c3 - s1 * s2 * s3);
}

PackedFloat32Array VoxelMapImportPlanner::parse_float_values(
        const String &p_text, int p_count) const {
    PackedFloat32Array result;
    result.resize(std::max(0, p_count));
    const PackedStringArray parts = p_text.split(" ", false);
    for (int index = 0; index < std::min(result.size(), parts.size()); ++index) {
        result.set(index, parts[index].to_float());
    }
    return result;
}

void VoxelMapImportPlanner::accumulate_centroid(const Dictionary &p_element,
        const Transform3D &p_parent, Vector3 &r_sum, int64_t &r_count) {
    const Transform3D transform = element_transform(p_element, p_parent);
    const String tag = p_element.get("tag", String());
    if (tag == "vox" || tag == "voxbox") {
        r_sum += transform.origin;
        r_count++;
    }
    const Array children = p_element.get("children", Array());
    for (int index = 0; index < children.size(); ++index) {
        accumulate_centroid(children[index], transform, r_sum, r_count);
    }
}

Vector3 VoxelMapImportPlanner::centroid(
        const Dictionary &p_root, const Transform3D &p_parent) const {
    Vector3 sum;
    int64_t count = 0;
    accumulate_centroid(p_root, p_parent, sum, count);
    return count > 0 ? sum / static_cast<double>(count) : Vector3();
}

PackedVector3Array VoxelMapImportPlanner::find_boundary_recursive(
        const Dictionary &p_element, const Transform3D &p_parent) {
    const Transform3D transform = element_transform(p_element, p_parent);
    const String tag = p_element.get("tag", String());
    const Array children = p_element.get("children", Array());
    if (tag == "boundary") {
        PackedVector3Array result;
        for (int index = 0; index < children.size(); ++index) {
            const Dictionary child = children[index];
            if (static_cast<String>(child.get("tag", String())) != "vertex") {
                continue;
            }
            const Dictionary attributes = child.get("attributes", Dictionary());
            const PackedStringArray parts =
                    static_cast<String>(attributes.get("pos", String())).split(" ", false);
            if (parts.size() >= 2) {
                result.append(transform.xform(Vector3(
                        parts[0].to_float(), 0.0, parts[1].to_float())));
            }
        }
        return result;
    }
    for (int index = 0; index < children.size(); ++index) {
        PackedVector3Array found = find_boundary_recursive(children[index], transform);
        if (!found.is_empty()) {
            return found;
        }
    }
    return PackedVector3Array();
}

PackedVector3Array VoxelMapImportPlanner::find_boundary_points(
        const Dictionary &p_root, const Transform3D &p_parent) const {
    return find_boundary_recursive(p_root, p_parent);
}

Dictionary VoxelMapImportPlanner::classify_door_joint_records(
        const Array &p_records, const AABB &p_body_bounds) const {
    if (p_records.is_empty()) {
        return Dictionary();
    }
    const Vector3 size = p_body_bounds.size;
    const double horizontal_long = std::max(size.x, size.z);
    const double horizontal_short = std::min(size.x, size.z);
    if (size.y < 1.15 || size.y > 3.4 || horizontal_long < 0.4 ||
            horizontal_long > 2.7 || horizontal_short > 1.25) {
        return Dictionary();
    }
    Array hinges;
    std::vector<bool> hinge_indices(static_cast<size_t>(p_records.size()), false);
    for (int index = 0; index < p_records.size(); ++index) {
        const Dictionary record = p_records[index];
        const Dictionary attributes = record.get("attributes", Dictionary());
        if (static_cast<String>(attributes.get("type", String("ball"))) == "hinge") {
            hinges.append(record);
            hinge_indices[static_cast<size_t>(index)] = true;
        }
    }
    if (hinges.is_empty()) {
        int best_a = -1;
        int best_b = -1;
        double best_score = -std::numeric_limits<double>::infinity();
        for (int a = 0; a < p_records.size(); ++a) {
            const Vector3 a_position = record_position(p_records[a]);
            for (int b = a + 1; b < p_records.size(); ++b) {
                const Vector3 b_position = record_position(p_records[b]);
                const double vertical = std::abs(a_position.y - b_position.y);
                const double horizontal = Vector2(a_position.x, a_position.z).distance_to(
                        Vector2(b_position.x, b_position.z));
                if (vertical < 0.55 || horizontal > 0.36) {
                    continue;
                }
                const double score = vertical - horizontal * 2.0;
                if (score > best_score) {
                    best_score = score;
                    best_a = a;
                    best_b = b;
                }
            }
        }
        if (best_a < 0) {
            return Dictionary();
        }
        hinges.append(p_records[best_a]);
        hinges.append(p_records[best_b]);
        hinge_indices[static_cast<size_t>(best_a)] = true;
        hinge_indices[static_cast<size_t>(best_b)] = true;
    }
    Vector3 hinge_center;
    for (int index = 0; index < hinges.size(); ++index) {
        hinge_center += record_position(hinges[index]);
    }
    hinge_center /= hinges.size();
    Dictionary latch;
    double farthest = std::max(0.34, horizontal_long * 0.34);
    for (int index = 0; index < p_records.size(); ++index) {
        if (hinge_indices[static_cast<size_t>(index)]) {
            continue;
        }
        const Vector3 position = record_position(p_records[index]);
        const double distance = Vector2(position.x, position.z).distance_to(
                Vector2(hinge_center.x, hinge_center.z));
        if (distance > farthest) {
            farthest = distance;
            latch = p_records[index];
        }
    }
    Dictionary result;
    result["hinges"] = hinges;
    result["latch"] = latch;
    return result;
}

} // namespace godot
