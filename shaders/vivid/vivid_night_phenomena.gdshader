// Soft, camera-facing night phenomena driven by AerialSwarm MultiMeshes.
//
// INSTANCE_CUSTOM supplies four stable random values per mote. They stagger
// distance fading, appearance cycles, colour, motion, and brightness without
// creating any per-frame CPU state. The particles therefore fade in and out
// independently while their host swarm only updates broad formation movement.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded,
	shadows_disabled, fog_disabled;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Appearance;
uniform vec3 primary_color : source_color = vec3(0.48, 0.82, 1.0);
uniform vec3 secondary_color : source_color = vec3(0.92, 0.42, 1.0);
uniform float emission_energy : hint_range(0.0, 16.0) = 5.0;
uniform float opacity : hint_range(0.0, 1.0) = 0.7;
uniform bool wisp_shape = false;
uniform bool billboard_axis_locked = false;
uniform float wisp_curl : hint_range(0.0, 1.0) = 0.2;
uniform float wisp_curl_speed : hint_range(0.0, 4.0) = 0.42;
group_uniforms;

group_uniforms Camera_Rim;
uniform vec3 camera_rim_color : source_color = vec3(0.20, 1.0, 0.58);
uniform float camera_rim_energy : hint_range(0.0, 8.0) = 0.6;
uniform float camera_rim_dark : hint_range(0.0, 1.0) = 0.68;
uniform float camera_rim_light : hint_range(0.0, 1.0) = 0.84;
group_uniforms;

group_uniforms Lifetime;
// A complete visible-plus-hidden cycle. Custom data varies this per instance.
uniform float cycle_seconds : hint_range(0.5, 60.0) = 8.0;
uniform float visible_share : hint_range(0.02, 0.9) = 0.3;
uniform float fade_share : hint_range(0.01, 0.4) = 0.08;
uniform float shimmer_speed : hint_range(0.0, 12.0) = 2.4;
group_uniforms;

group_uniforms Visibility;
uniform float distance_fade_from = 210.0;
uniform float distance_fade_to = 270.0;
uniform float distance_fade_stagger = 12.0;
uniform bool night_only = true;
// Kept for AerialSwarm's shared material configuration contract.
uniform bool glow_night_only = true;
uniform float twilight_dark : hint_range(-1.0, 1.0) = -0.16;
uniform float twilight_light : hint_range(-1.0, 1.0) = 0.12;
group_uniforms;

varying vec3 v_colour;
varying float v_visibility;
varying float v_phase;
varying float v_seed;


float phenomenon_night(vec3 world_position) {
	float sun_length = length(sun_direction);
	if (sun_length < 0.0001) {
		return 1.0;
	}
	float light = dot(vivid_up(world_position), normalize(-sun_direction));
	return 1.0 - smoothstep(twilight_dark, twilight_light, light);
}


void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	float stagger = INSTANCE_CUSTOM.x * min(max(distance_fade_stagger, 0.0),
		max(distance_fade_to - 0.01, 0.0));
	float fade_from = max(distance_fade_from - stagger, 0.0);
	float fade_to = max(distance_fade_to - stagger, fade_from + 0.01);
	float distance_visibility = 1.0 - smoothstep(fade_from, fade_to,
		distance(CAMERA_POSITION_WORLD, origin));

	float rate = mix(0.72, 1.34,
		fract(INSTANCE_CUSTOM.z * 17.17 + INSTANCE_CUSTOM.x * 5.31));
	float phase = fract(TIME * rate / max(cycle_seconds, 0.01)
		+ INSTANCE_CUSTOM.y);
	float fade = min(max(fade_share, 0.001), visible_share * 0.48);
	float appear = smoothstep(0.0, fade, phase);
	float disappear = 1.0 - smoothstep(
		max(visible_share - fade, fade), visible_share, phase);
	float life = appear * disappear;
	float night = (night_only || glow_night_only)
		? phenomenon_night(origin) : 1.0;
	float visibility = life * distance_visibility * night;

	// Subdivided wisp quads curl as ribbons. Sparkles instead bloom slightly as
	// they appear, which keeps their arrival from looking like an alpha switch.
	if (wisp_shape) {
		float ribbon = sin(UV.y * 7.0 + TIME * TAU * wisp_curl_speed
			+ INSTANCE_CUSTOM.z * TAU);
		VERTEX.x += ribbon * wisp_curl * sin(UV.y * PI);
		VERTEX *= mix(0.68, 1.0, sqrt(max(life, 0.0)));
	} else {
		VERTEX *= mix(0.22, 1.0, sqrt(max(life, 0.0)));
	}

	mat4 phenomenon_model = MODEL_MATRIX;
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	float scale_z = length(MODEL_MATRIX[2].xyz);
	vec3 right;
	vec3 up;
	vec3 back;
	if (billboard_axis_locked) {
		up = normalize(MODEL_MATRIX[1].xyz);
		vec3 to_eye = CAMERA_POSITION_WORLD - origin;
		to_eye -= up * dot(to_eye, up);
		back = length(to_eye) > 0.0001
			? normalize(to_eye) : normalize(MODEL_MATRIX[2].xyz);
		right = normalize(cross(up, back));
		back = normalize(cross(right, up));
	} else {
		right = normalize(INV_VIEW_MATRIX[0].xyz);
		up = normalize(INV_VIEW_MATRIX[1].xyz);
		back = normalize(INV_VIEW_MATRIX[2].xyz);
	}
	phenomenon_model = mat4(
		vec4(right * scale_x, 0.0),
		vec4(up * scale_y, 0.0),
		vec4(back * scale_z, 0.0),
		vec4(origin, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * phenomenon_model;
	MODELVIEW_NORMAL_MATRIX = transpose(inverse(mat3(MODELVIEW_MATRIX)));

	float colour_mix = fract(INSTANCE_CUSTOM.x * 11.73
		+ INSTANCE_CUSTOM.z * 23.19);
	v_colour = mix(primary_color, secondary_color, colour_mix) * COLOR.rgb;
	v_visibility = visibility;
	v_phase = phase;
	v_seed = INSTANCE_CUSTOM.z;
}


void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float mask;
	if (wisp_shape) {
		float centre = sin(UV.y * 8.0 + v_seed * TAU) * 0.1
			* sin(UV.y * PI);
		float width = mix(0.18, 0.72,
			0.5 + 0.5 * sin(UV.y * 5.0 + v_seed * 9.0));
		float ribbon = 1.0 - smoothstep(width, width + 0.28,
			abs(p.x - centre));
		float ends = smoothstep(0.0, 0.16, UV.y)
			* (1.0 - smoothstep(0.72, 1.0, UV.y));
		float filaments = 0.68 + 0.32 * sin(
			UV.y * 19.0 + p.x * 4.0 + v_seed * 17.0);
		mask = ribbon * ends * filaments;
	} else {
		float radius = length(p);
		float core = 1.0 - smoothstep(0.0, 0.24, radius);
		float horizontal = (1.0 - smoothstep(0.025, 0.12, abs(p.y)))
			* (1.0 - smoothstep(0.12, 1.0, abs(p.x)));
		float vertical = (1.0 - smoothstep(0.025, 0.12, abs(p.x)))
			* (1.0 - smoothstep(0.12, 1.0, abs(p.y)));
		float diamond = 1.0 - smoothstep(0.18, 0.74,
			abs(p.x) + abs(p.y));
		mask = max(core, max(horizontal, vertical) * 0.82);
		mask = max(mask, diamond * 0.34);
		float shimmer = 0.72 + 0.28 * pow(0.5 + 0.5 * sin(
			TIME * TAU * shimmer_speed + v_seed * TAU), 4.0);
		mask *= shimmer;
	}

	// These meshes are camera-facing cards, so Layer Weight is identically
	// front-facing. The authored mask supplies the equivalent silhouette ramp:
	// a soft outer gate and the same narrow dark/light edge used by 3D fauna.
	float camera_rim = smoothstep(0.04, 0.18, mask)
		* (1.0 - smoothstep(camera_rim_dark, camera_rim_light, mask));
	float alpha = clamp(max(mask * opacity, camera_rim * 0.65)
		* v_visibility, 0.0, 1.0);
	ALBEDO = v_colour * 0.08;
	EMISSION = (v_colour * emission_energy * mask
		+ camera_rim_color * camera_rim_energy * camera_rim) * v_visibility;
	ALPHA = alpha;
}
