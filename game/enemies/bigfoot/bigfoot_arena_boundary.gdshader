shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

uniform vec4 line_color : source_color = vec4(1.0, 0.015, 0.01, 0.86);
uniform float pulse_rate : hint_range(0.0, 6.0) = 1.8;

void fragment() {
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float soft_edge = smoothstep(0.0, 0.35, across);
	float core = smoothstep(0.58, 1.0, across);
	float pulse = 0.82 + sin(TIME * pulse_rate + UV.x * 18.8495559) * 0.18;
	float strength = soft_edge * pulse;

	ALBEDO = line_color.rgb * (0.9 + core * 0.5);
	EMISSION = line_color.rgb * (2.2 + core * 2.8) * strength;
	ALPHA = line_color.a * strength;
}
