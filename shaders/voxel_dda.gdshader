shader_type spatial;
render_mode cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform sampler3D voxel_texture : filter_nearest, repeat_disable;
uniform sampler3D macro_texture : filter_nearest, repeat_disable;
uniform sampler2D palette_texture : source_color, filter_nearest, repeat_disable;
uniform ivec3 volume_dimensions = ivec3(64, 64, 64);
uniform ivec3 macro_dimensions = ivec3(8, 8, 8);
uniform float voxel_size = 0.1;
uniform int max_steps = 512;
uniform bool visualize_steps = false;

varying vec3 local_proxy_position;
varying vec3 local_camera_position;


void vertex() {
	local_proxy_position = VERTEX;
	local_camera_position = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}


vec2 intersect_volume(vec3 ray_origin, vec3 ray_direction, vec3 volume_size) {
	vec3 safe_direction = mix(
		-vec3(1.0),
		vec3(1.0),
		greaterThanEqual(ray_direction, vec3(0.0))
	) * max(abs(ray_direction), vec3(1e-7));
	vec3 inverse_direction = 1.0 / safe_direction;
	vec3 a = (vec3(0.0) - ray_origin) * inverse_direction;
	vec3 b = (volume_size - ray_origin) * inverse_direction;
	vec3 near_axis = min(a, b);
	vec3 far_axis = max(a, b);
	return vec2(
		max(near_axis.x, max(near_axis.y, near_axis.z)),
		min(far_axis.x, min(far_axis.y, far_axis.z))
	);
}


vec3 entry_normal(vec3 point, vec3 direction, vec3 volume_size) {
	const float epsilon = 0.002;
	if (abs(point.x) < epsilon) return vec3(-1.0, 0.0, 0.0);
	if (abs(point.x - volume_size.x) < epsilon) return vec3(1.0, 0.0, 0.0);
	if (abs(point.y) < epsilon) return vec3(0.0, -1.0, 0.0);
	if (abs(point.y - volume_size.y) < epsilon) return vec3(0.0, 1.0, 0.0);
	if (abs(point.z) < epsilon) return vec3(0.0, 0.0, -1.0);
	if (abs(point.z - volume_size.z) < epsilon) return vec3(0.0, 0.0, 1.0);
	vec3 axis = abs(direction);
	if (axis.x > axis.y && axis.x > axis.z) return vec3(-sign(direction.x), 0.0, 0.0);
	if (axis.y > axis.z) return vec3(0.0, -sign(direction.y), 0.0);
	return vec3(0.0, 0.0, -sign(direction.z));
}


void fragment() {
	vec3 dimensions = vec3(volume_dimensions);
	vec3 ray_origin = local_camera_position / voxel_size + dimensions * 0.5;
	vec3 ray_direction = normalize(local_proxy_position - local_camera_position);
	vec2 bounds = intersect_volume(ray_origin, ray_direction, dimensions);
	if (bounds.y < max(bounds.x, 0.0)) {
		discard;
	}

	float current_t = max(bounds.x, 0.0) + 0.0005;
	vec3 entry_point = ray_origin + ray_direction * current_t;
	ivec3 cell = clamp(ivec3(floor(entry_point)), ivec3(0), volume_dimensions - ivec3(1));
	ivec3 step_direction = ivec3(sign(ray_direction));
	vec3 safe_direction = mix(
		-vec3(1.0),
		vec3(1.0),
		greaterThanEqual(ray_direction, vec3(0.0))
	) * max(abs(ray_direction), vec3(1e-7));
	vec3 delta_t = abs(1.0 / safe_direction);
	vec3 next_boundary = vec3(cell) + mix(
		vec3(0.0),
		vec3(1.0),
		greaterThan(ray_direction, vec3(0.0))
	);
	vec3 side_t = (next_boundary - ray_origin) / safe_direction;

	int material_index = 0;
	int steps_taken = 0;
	vec3 hit_normal = entry_normal(entry_point, ray_direction, dimensions);
	float hit_t = current_t;

	for (int iteration = 0; iteration < 192; iteration++) {
		if (iteration >= max_steps || current_t > bounds.y) {
			break;
		}
		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, volume_dimensions))) {
			break;
		}
		steps_taken = iteration + 1;
		ivec3 macro_cell = clamp(cell / 8, ivec3(0), macro_dimensions - ivec3(1));
		int macro_occupied = int(round(texelFetch(macro_texture, macro_cell, 0).r * 255.0));
		if (macro_occupied == 0) {
			vec3 macro_minimum = vec3(macro_cell * 8);
			vec3 macro_maximum = min(macro_minimum + vec3(8.0), dimensions);
			vec3 macro_boundary = mix(
				macro_minimum,
				macro_maximum,
				greaterThan(ray_direction, vec3(0.0))
			);
			vec3 macro_side_t = (macro_boundary - ray_origin) / safe_direction;
			current_t = min(macro_side_t.x, min(macro_side_t.y, macro_side_t.z)) + 0.0005;
			if (current_t > bounds.y) {
				break;
			}
			vec3 skipped_point = ray_origin + ray_direction * current_t;
			cell = ivec3(floor(skipped_point));
			if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, volume_dimensions))) {
				break;
			}
			next_boundary = vec3(cell) + mix(
				vec3(0.0),
				vec3(1.0),
				greaterThan(ray_direction, vec3(0.0))
			);
			side_t = (next_boundary - ray_origin) / safe_direction;
			continue;
		}
		material_index = int(round(texelFetch(voxel_texture, cell, 0).r * 255.0));
		if (material_index != 0) {
			hit_t = current_t;
			break;
		}

		if (side_t.x <= side_t.y && side_t.x <= side_t.z) {
			current_t = side_t.x;
			side_t.x += delta_t.x;
			cell.x += step_direction.x;
			hit_normal = vec3(-float(step_direction.x), 0.0, 0.0);
		} else if (side_t.y <= side_t.z) {
			current_t = side_t.y;
			side_t.y += delta_t.y;
			cell.y += step_direction.y;
			hit_normal = vec3(0.0, -float(step_direction.y), 0.0);
		} else {
			current_t = side_t.z;
			side_t.z += delta_t.z;
			cell.z += step_direction.z;
			hit_normal = vec3(0.0, 0.0, -float(step_direction.z));
		}
	}

	if (material_index == 0) {
		discard;
	}

	vec3 local_hit = (ray_origin + ray_direction * hit_t - dimensions * 0.5) * voxel_size;
	vec4 world_hit = MODEL_MATRIX * vec4(local_hit, 1.0);
	vec4 clip_hit = PROJECTION_MATRIX * VIEW_MATRIX * world_hit;
	DEPTH = clip_hit.z / clip_hit.w;

	vec3 view_normal = normalize(mat3(VIEW_MATRIX) * MODEL_NORMAL_MATRIX * hit_normal);
	NORMAL = view_normal;
	vec4 material_color = texelFetch(palette_texture, ivec2(material_index, 0), 0);
	ALBEDO = visualize_steps
		? mix(vec3(0.05, 0.2, 0.8), vec3(1.0, 0.12, 0.02), float(steps_taken) / float(max_steps))
		: material_color.rgb;
	ROUGHNESS = material_index == 3 ? 0.35 : 0.82;
	METALLIC = material_index == 3 ? 0.55 : 0.0;
}
