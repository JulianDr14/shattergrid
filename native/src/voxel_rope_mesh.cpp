#include "voxel_rope_solver.hpp"

#include <algorithm>

namespace godot {

Dictionary VoxelRopeSolver::build_mesh_data(const Vector3 &p_dead_point) {
	if (mesh_topology_dirty) {
		rebuild_topology();
	}
	PackedVector3Array vertices;
	PackedVector3Array normals;
	vertices.resize(static_cast<int>(points.size()) * 2);
	normals.resize(static_cast<int>(points.size()) * 2);
	for (const Span &span : spans) {
		if (span.dead) {
			for (int step = 0; step < span.count; ++step) {
				const int vertex = (span.start + step) * 2;
				vertices.set(vertex, p_dead_point);
				vertices.set(vertex + 1, p_dead_point);
			}
			continue;
		}
		for (int step = 0; step < span.count; ++step) {
			const int point_index = span.start + step;
			const Vector3 ahead = points[static_cast<size_t>(std::min(
					point_index + 1, span.start + span.count - 1))];
			const Vector3 behind = points[static_cast<size_t>(std::max(
					point_index - 1, span.start))];
			const Vector3 delta = ahead - behind;
			const Vector3 tangent = delta.length_squared() > 0.000001
					? delta.normalized() : Vector3(0, 1, 0);
			const int vertex = point_index * 2;
			vertices.set(vertex, points[static_cast<size_t>(point_index)]);
			vertices.set(vertex + 1, points[static_cast<size_t>(point_index)]);
			normals.set(vertex, tangent);
			normals.set(vertex + 1, tangent);
		}
	}
	mesh_positions_dirty = false;
	Dictionary result;
	result["vertices"] = vertices;
	result["normals"] = normals;
	result["uvs"] = cached_uvs;
	result["indices"] = cached_indices;
	return result;
}

void VoxelRopeSolver::rebuild_topology() {
	cached_uvs.resize(static_cast<int>(points.size()) * 2);
	cached_indices.clear();
	for (const Span &span : spans) {
		for (int step = 0; step < span.count; ++step) {
			const int vertex = (span.start + step) * 2;
			const double ratio = static_cast<double>(step) / std::max(1, span.count - 1);
			cached_uvs.set(vertex, Vector2(0.0, ratio));
			cached_uvs.set(vertex + 1, Vector2(1.0, ratio));
		}
		for (int step = 0; step < span.count - 1; ++step) {
			const int quad = (span.start + step) * 2;
			cached_indices.append(quad);
			cached_indices.append(quad + 1);
			cached_indices.append(quad + 2);
			cached_indices.append(quad + 1);
			cached_indices.append(quad + 3);
			cached_indices.append(quad + 2);
		}
	}
	mesh_topology_dirty = false;
}

bool VoxelRopeSolver::consume_mesh_dirty() {
	const bool dirty = mesh_topology_dirty || mesh_positions_dirty;
	mesh_positions_dirty = false;
	return dirty;
}

} // namespace godot
