shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

void fragment() {
	float distance_from_center = length(UV - vec2(0.5)) * 2.0;
	float outer = smoothstep(0.72, 0.86, distance_from_center);
	float inner = 1.0 - smoothstep(0.86, 0.99, distance_from_center);
	float broken = 0.72 + 0.28 * sin(atan(UV.y - 0.5, UV.x - 0.5) * 9.0 + TIME * 2.0);
	ALBEDO = COLOR.rgb;
	ALPHA = outer * inner * broken * COLOR.a;
}
