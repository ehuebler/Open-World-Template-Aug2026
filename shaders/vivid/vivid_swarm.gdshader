// Solid, instanced insects for AerialSwarm.
//
// MultiMesh COLOR supplies per-insect tint. INSTANCE_CUSTOM is packed as:
//   x  stable distance-fade stagger
//   y  twinkle phase
//   z  slower pulse phase
//   w  glow-strength variation
//
// Bodies remain opaque. Distance and optional daytime visibility are softened by
// shrinking each insect around its own instance origin, so there is no blended
// swarm edge to sort and no screen-door pattern that boils as the camera moves.
// Alpha textures may still cut out card wings through a fixed discard threshold.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley,
	specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Surface;
uniform vec3 base_color : source_color = vec3(0.16, 0.13, 0.08);
uniform sampler2D base_texture : source_color, hint_default_white,
	filter_linear_mipmap, repeat_enable;
uniform float saturation : hint_range(0.0, 3.0) = 1.1;
uniform float brightness : hint_range(0.0, 3.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.58;
uniform float specular : hint_range(0.0, 1.0) = 0.32;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float translucency : hint_range(0.0, 1.0) = 0.22;
// Zero keeps every texel. A positive value is an opaque alpha cutout, useful
// for wing cards without putting the whole swarm in the transparent pipeline.
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.0;
group_uniforms;

group_uniforms Camera_Rim;
uniform vec3 camera_rim_color : source_color = vec3(0.20, 1.0, 0.58);
uniform float camera_rim_energy : hint_range(0.0, 8.0) = 0.75;
uniform float camera_rim_dark : hint_range(0.0, 1.0) = 0.68;
uniform float camera_rim_light : hint_range(0.0, 1.0) = 0.84;
group_uniforms;

group_uniforms Cards;
// Off for an authored 3D insect. Turn on only for a flat/card model.
uniform bool billboard_enabled = false;
// Axis-locked keeps the CPU-authored local +Y aligned with the planet surface.
// Full billboarding is available for a camera-facing sprite with no vertical
// world orientation of its own.
uniform bool billboard_axis_locked = true;
group_uniforms;

group_uniforms Firefly;
uniform vec3 glow_color : source_color = vec3(0.72, 1.0, 0.30);
uniform float glow_energy : hint_range(0.0, 16.0) = 3.2;
uniform sampler2D glow_mask : hint_default_white, filter_linear_mipmap,
	repeat_enable;
uniform float glow_tint_share : hint_range(0.0, 1.0) = 0.28;
uniform bool glow_night_only = true;
// Fast, peaked flashes and a separate slow breathing pulse. Their phases come
// from different custom channels, so neither can synchronise the other.
uniform float twinkle_amount : hint_range(0.0, 1.0) = 0.74;
uniform float twinkle_speed : hint_range(0.0, 12.0) = 3.1;
uniform float twinkle_sharpness : hint_range(1.0, 16.0) = 6.0;
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.20;
uniform float pulse_speed : hint_range(0.0, 4.0) = 0.46;
group_uniforms;

group_uniforms Visibility;
uniform float distance_fade_from = 205.0;
uniform float distance_fade_to = 250.0;
// Moves each insect's fade band a little without making any frame stochastic.
uniform float distance_fade_stagger = 10.0;
uniform bool night_only = false;
// Dot(direction-to-sun, local-up) across which local night fades in.
uniform float twilight_dark : hint_range(-1.0, 1.0) = -0.16;
uniform float twilight_light : hint_range(-1.0, 1.0) = 0.12;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;
varying float v_twinkle_phase;
varying float v_pulse_phase;
varying float v_glow_variation;
varying float v_visibility;


float swarm_night(vec3 world_position) {
	float sun_length = length(sun_direction);
	if (sun_length < 0.0001) {
		return 1.0;
	}
	float light = dot(vivid_up(world_position), normalize(-sun_direction));
	return 1.0 - smoothstep(twilight_dark, twilight_light, light);
}


void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	// Stagger only toward the camera. Every insect is therefore fully gone by
	// distance_fade_to, before the CPU removes its cluster draw submission.
	float stagger = INSTANCE_CUSTOM.x * min(max(distance_fade_stagger, 0.0),
		max(distance_fade_to - 0.01, 0.0));
	float fade_from = max(distance_fade_from - stagger, 0.0);
	float fade_to = max(distance_fade_to - stagger, fade_from + 0.01);
	float visibility = 1.0 - smoothstep(fade_from, fade_to,
		distance(CAMERA_POSITION_WORLD, origin));
	if (night_only) {
		visibility *= swarm_night(origin);
	}

	// Solid geometry scales down continuously instead of changing alpha.
	VERTEX *= visibility;
	v_visibility = visibility;

	mat4 swarm_model = MODEL_MATRIX;
	if (billboard_enabled) {
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
				? normalize(to_eye)
				: normalize(MODEL_MATRIX[2].xyz);
			right = normalize(cross(up, back));
			back = normalize(cross(right, up));
		} else {
			right = normalize(INV_VIEW_MATRIX[0].xyz);
			up = normalize(INV_VIEW_MATRIX[1].xyz);
			back = normalize(INV_VIEW_MATRIX[2].xyz);
		}
		swarm_model = mat4(
			vec4(right * scale_x, 0.0),
			vec4(up * scale_y, 0.0),
			vec4(back * scale_z, 0.0),
			vec4(origin, 1.0));
		MODELVIEW_MATRIX = VIEW_MATRIX * swarm_model;
		MODELVIEW_NORMAL_MATRIX = transpose(inverse(mat3(MODELVIEW_MATRIX)));
	}

	v_world_position = (swarm_model * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(transpose(inverse(mat3(swarm_model))) * NORMAL);
	v_twinkle_phase = INSTANCE_CUSTOM.y;
	v_pulse_phase = INSTANCE_CUSTOM.z;
	v_glow_variation = INSTANCE_CUSTOM.w;
}


void fragment() {
	vec4 sampled = texture(base_texture, UV);
	if (alpha_cutoff > 0.0 && sampled.a * COLOR.a < alpha_cutoff) {
		discard;
	}
	vec3 albedo = vivid_saturate(base_color * sampled.rgb * COLOR.rgb,
		saturation) * brightness;
	vec3 normal = normalize(v_world_normal);
	vec3 view = normalize(CAMERA_POSITION_WORLD - v_world_position);
	float fresnel = pow(1.0 - clamp(dot(normal, view), 0.0, 1.0), 3.0);
	float camera_rim = vivid_camera_rim(
		normal, view, camera_rim_dark, camera_rim_light);

	float twinkle_wave = pow(0.5 + 0.5 * sin(
		TIME * TAU * twinkle_speed + v_twinkle_phase * TAU),
		twinkle_sharpness);
	float twinkle = mix(1.0, twinkle_wave, twinkle_amount);
	// Rate is decorrelated from both phases without spending another custom
	// channel. It is stable arithmetic, not frame noise.
	float pulse_rate = mix(0.82, 1.18,
		fract(v_twinkle_phase * 13.37 + v_pulse_phase * 7.91));
	float pulse = 1.0 + pulse_amount * sin(
		TIME * TAU * pulse_speed * pulse_rate + v_pulse_phase * TAU);
	float night = glow_night_only ? swarm_night(v_world_position) : 1.0;
	float mask = texture(glow_mask, UV).r;
	vec3 glow_tint = mix(vec3(1.0), COLOR.rgb, glow_tint_share);
	vec3 emission = glow_color * glow_tint * glow_energy * mask * night
		* twinkle * pulse * v_glow_variation * v_visibility;

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	ROUGHNESS = roughness;
	SPECULAR = specular;
	METALLIC = metallic;
	RIM = 0.22 + fresnel * 0.18;
	RIM_TINT = 0.5;
	// Thin wings catch light from either side without requiring transparency.
	BACKLIGHT = albedo * translucency;
	EMISSION = emission
		+ vivid_camera_rim_colour(camera_rim_color)
			* camera_rim_energy * camera_rim * v_visibility;
}
