// The band of air seen from outside it.
//
// A shell a few per cent wider than the planet, drawn additively. Where the line
// of sight only grazes the shell it passes through kilometres of air and the
// glow piles up; where it looks straight down through it there is barely any, so
// a plain fresnel is most of the effect.
//
// It is faded out below [member shell_height] because from inside the air the sky
// shader is already drawing it, and adding both would double the haze.
shader_type spatial;
render_mode blend_add, unshaded, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

uniform vec3 glow_color : source_color = vec3(0.32, 0.62, 1.0);
uniform float glow_strength : hint_range(0.0, 4.0) = 1.15;
// How tightly the glow hugs the limb. Lower values wash the whole disc.
uniform float glow_falloff : hint_range(1.0, 16.0) = 4.0;
// How much of the region's own hue the air over it takes.
uniform float region_tint : hint_range(0.0, 1.0) = 0.55;
// Extra brightness on the day side, where the air is actually being lit.
uniform float sun_side : hint_range(0.0, 1.0) = 0.8;
// Camera altitude at which the shell reaches full strength, in metres.
uniform float shell_height = 2400.0;

varying vec3 v_world_position;

void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 up = vivid_up(v_world_position);
	vec3 view = normalize(CAMERA_POSITION_WORLD - v_world_position);
	float limb = pow(1.0 - abs(dot(up, view)), glow_falloff);
	float lit = mix(1.0 - sun_side, 1.0,
		smoothstep(-0.25, 0.55, dot(up, normalize(-sun_direction))));
	float outside = smoothstep(shell_height * 0.35, shell_height,
		vivid_altitude(CAMERA_POSITION_WORLD));
	vec3 tint = mix(glow_color, vivid_region_light(up) * glow_color * 2.0, region_tint);
	ALBEDO = vec3(0.0);
	EMISSION = tint * limb * lit * outside * glow_strength;
}
