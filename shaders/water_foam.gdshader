shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float along = world_position.x * 0.73 + world_position.z * 1.17;
	float coarse = sin(along * 3.1 + TIME * 1.8) * 0.5 + 0.5;
	float fine = sin(along * 8.7 - TIME * 2.6 + sin(along * 1.9)) * 0.5 + 0.5;
	float broken_edge = smoothstep(0.19, 0.82, coarse * 0.58 + fine * 0.42);
	float inward_fade = pow(clamp(1.0 - UV.x, 0.0, 1.0), 1.7);
	ALBEDO = mix(COLOR.rgb * 0.78, COLOR.rgb, fine);
	ALPHA = COLOR.a * inward_fade * mix(0.22, 0.76, broken_edge);
}
