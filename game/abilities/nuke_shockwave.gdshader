shader_type spatial;

// The delayed pressure shell behind the ground-skimming rings. Fresnel keeps
// only the edge of the sphere, so it reads as a front moving through the air
// rather than as another translucent fireball.
render_mode blend_add, depth_draw_never, cull_back, unshaded;

uniform vec4 tint : source_color = vec4(1.0, 0.48, 0.18, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.0;


void fragment() {
	float edge = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	float shell = smoothstep(0.48, 0.96, edge);
	if (shell < 0.01) {
		discard;
	}
	ALBEDO = mix(tint.rgb, vec3(1.0), 0.48);
	EMISSION = ALBEDO * (0.8 + strength * 2.2);
	ALPHA = shell * strength * 0.52;
}
