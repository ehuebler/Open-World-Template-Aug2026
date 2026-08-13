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

group_uniforms Scattering;
// How far the wavelength model in `vivid_air_scatter` takes the limb's hue over
// from `glow_color`. Multiplied by the `air_chroma` global so the player's
// setting scales this rather than replacing it.
//
// This is the higher of the two settings — the sky's is 0.75 — because from
// outside, the limb *is* the scattering. A ray across it crosses the whole
// atmosphere twice and the sun's angle at each point along it varies from
// overhead to below the horizon within a few pixels, which is the one place the
// model has more to say than an authored blue does.
uniform float scatter_strength : hint_range(0.0, 1.0) = 0.9;
// Thickness of the air along a limb ray, as a multiple of the model's vertical
// atmosphere. Well under one on purpose. The honest figure for a grazing ray is
// several, and the haze lobe swamps the Rayleigh term long before that — which
// pales the sunlit rim to white and loses the blue that a limb is recognisable
// by. Around a half is where the rim reads blue and the terminator still burns.
uniform float scatter_density : hint_range(0.1, 2.0) = 0.5;
group_uniforms;

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
	// `vivid_region_light` inlined, because the scattering below wants the hue
	// coordinate as well and that function only returns the colour built from
	// it. Calling both would read the region twice — four two-octave fBm fields
	// per pixel across a shell that covers the whole screen from orbit.
	vec2 region = vivid_region(up);
	vec3 region_light = mix(vec3(1.0), vivid_spectrum(region.x), region_chroma)
		* mix(0.45, 1.0, region.y);
	vec3 tint = mix(glow_color, region_light * glow_color * 2.0, region_tint);
	// The same model the sky runs, read from the other side. `-view` is the way
	// the ray travels — from the camera into the shell — which is the sense the
	// sky shader's EYEDIR has, so a forward lobe means the same thing to both.
	//
	// The limb is where this earns its place: `up` swings through ninety degrees
	// across the rim, so the sunlight term goes from overhead white at the
	// sub-solar point to seven atmospheres of amber at the terminator on its own,
	// and the warm band around the night side stops being something `sun_side`
	// has to fake.
	tint = vivid_air_scatter(tint, -view, up, normalize(-sun_direction),
		region.x, scatter_density,
		clamp(scatter_strength * air_chroma, 0.0, 1.0));
	ALBEDO = vec3(0.0);
	EMISSION = tint * limb * lit * outside * glow_strength;
}
