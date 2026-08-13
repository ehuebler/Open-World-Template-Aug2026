shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_front, unshaded;

uniform vec4 shield_color : source_color = vec4(0.18, 0.55, 1.0, 0.22);
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform float ripple : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.2);
	float bands = 0.5 + 0.5 * sin((UV.y + UV.x * 0.18) * 36.0 - TIME * 8.0);
	float energy = clamp(rim * 0.85 + bands * 0.08 + ripple * 0.18, 0.0, 1.0);
	ALBEDO = shield_color.rgb * (1.0 + pulse * 0.8);
	EMISSION = shield_color.rgb * (rim * 1.4 + pulse * 0.9);
	ALPHA = shield_color.a * (0.55 + energy) * (1.0 + pulse * 0.35);
}
