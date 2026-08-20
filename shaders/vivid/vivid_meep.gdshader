// Every Meep in a colony is one instance of the same static mesh. Animation is
// decoded from one of four position VATs; INSTANCE_CUSTOM carries clip, phase,
// playback rate, and a stable appearance/night seed.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"
#include "res://shaders/vivid/vivid_vat.gdshaderinc"

group_uniforms VertexAnimation;
uniform float locomotion_time_direction : hint_range(-1.0, 1.0) = 1.0;
uniform sampler2D idle_vat_positions : filter_nearest, repeat_disable;
uniform float idle_vat_frame_count = 1.0;
uniform float idle_vat_fps = 24.0;
uniform vec3 idle_vat_delta_min = vec3(0.0);
uniform vec3 idle_vat_delta_max = vec3(0.0);
uniform sampler2D walk_vat_positions : filter_nearest, repeat_disable;
uniform float walk_vat_frame_count = 1.0;
uniform float walk_vat_fps = 24.0;
uniform vec3 walk_vat_delta_min = vec3(0.0);
uniform vec3 walk_vat_delta_max = vec3(0.0);
uniform sampler2D run_vat_positions : filter_nearest, repeat_disable;
uniform float run_vat_frame_count = 1.0;
uniform float run_vat_fps = 24.0;
uniform vec3 run_vat_delta_min = vec3(0.0);
uniform vec3 run_vat_delta_max = vec3(0.0);
uniform sampler2D build_vat_positions : filter_nearest, repeat_disable;
uniform float build_vat_frame_count = 1.0;
uniform float build_vat_fps = 24.0;
uniform vec3 build_vat_delta_min = vec3(0.0);
uniform vec3 build_vat_delta_max = vec3(0.0);
group_uniforms;

group_uniforms Fill;
uniform vec3 base_color : source_color = vec3(0.82, 0.80, 0.78);
uniform sampler2D base_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec2 base_uv_scale = vec2(1.0);
uniform bool use_vertex_color = false;
uniform float saturation : hint_range(0.0, 3.0) = 1.35;
uniform float brightness : hint_range(0.0, 2.0) = 1.0;
uniform float appearance_variation : hint_range(0.0, 0.3) = 0.06;
group_uniforms;

group_uniforms Surface;
uniform float roughness : hint_range(0.0, 1.0) = 0.65;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float roughness_variation : hint_range(0.0, 1.0) = 0.25;
group_uniforms;

group_uniforms Texture_Relief;
uniform float texture_relief : hint_range(0.0, 4.0) = 1.0;
uniform float relief_width : hint_range(1.0, 8.0) = 1.5;
group_uniforms;

group_uniforms Detail;
uniform float detail_scale = 6.0;
uniform float detail_amount : hint_range(0.0, 1.0) = 0.18;
uniform float bump_scale = 9.0;
uniform float bump_strength : hint_range(0.0, 1.0) = 0.18;
uniform float macro_scale = 0.45;
uniform float macro_amount : hint_range(0.0, 1.0) = 0.22;
uniform float detail_near = 12.0;
uniform float detail_far = 60.0;
group_uniforms;

group_uniforms Region;
uniform float region_albedo : hint_range(0.0, 1.0) = 0.34;
uniform float region_sheen : hint_range(0.0, 2.0) = 0.35;
uniform float region_rim : hint_range(0.0, 1.0) = 0.4;
group_uniforms;

group_uniforms Camera_Rim;
uniform vec3 camera_rim_color : source_color = vec3(0.0);
uniform float camera_rim_energy : hint_range(0.0, 8.0) = 0.0;
uniform float camera_rim_dark : hint_range(0.0, 1.0) = 0.68;
uniform float camera_rim_light : hint_range(0.0, 1.0) = 0.84;
group_uniforms;

group_uniforms Emission;
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;
uniform vec3 night_emission_color : source_color = vec3(0.0);
uniform float night_emission_energy : hint_range(0.0, 8.0) = 0.0;
uniform bool night_emission_from_texture_alpha = false;
uniform float night_pulse_amount : hint_range(0.0, 0.5) = 0.0;
uniform float night_pulse_speed : hint_range(0.0, 2.0) = 0.3;
uniform float night_emission_albedo : hint_range(0.0, 1.0) = 0.38;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;
varying float v_tone;
varying float v_night_phase;
varying float v_night_rate;


vec3 meep_vat_delta(float clip, float vertex_u, float phase, float rate) {
	// Keep sampler selection in uniform control-flow rather than indexing a
	// sampler array; this path is supported by the Mobile renderer.
	if (clip < 0.5) {
		return vivid_vat_delta(idle_vat_positions, vertex_u, TIME, phase, rate,
			idle_vat_frame_count, idle_vat_fps,
			idle_vat_delta_min, idle_vat_delta_max);
	}
	if (clip < 1.5) {
		// The baked source order already carries each planted foot backward
		// against forward world motion. Preserve that order instead of reversing
		// a correct gait into a moonwalk.
		return vivid_vat_delta(walk_vat_positions, vertex_u,
			TIME * locomotion_time_direction, phase, rate,
			walk_vat_frame_count, walk_vat_fps,
			walk_vat_delta_min, walk_vat_delta_max);
	}
	if (clip < 2.5) {
		return vivid_vat_delta(run_vat_positions, vertex_u,
			TIME * locomotion_time_direction, phase, rate,
			run_vat_frame_count, run_vat_fps,
			run_vat_delta_min, run_vat_delta_max);
	}
	return vivid_vat_delta(build_vat_positions, vertex_u, TIME, phase, rate,
		build_vat_frame_count, build_vat_fps,
		build_vat_delta_min, build_vat_delta_max);
}


void vertex() {
	// UV2.x is the baker's stable TEXCOORD_1 vertex ID. Normals deliberately
	// remain the static base-frame normals documented by the asset manifest.
	VERTEX += meep_vat_delta(INSTANCE_CUSTOM.x, UV2.x,
		INSTANCE_CUSTOM.y, INSTANCE_CUSTOM.z);
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	v_tone = mix(1.0 - appearance_variation, 1.0 + appearance_variation,
		INSTANCE_CUSTOM.w);
	v_night_phase = INSTANCE_CUSTOM.w;
	v_night_rate = mix(0.82, 1.18, fract(INSTANCE_CUSTOM.w * 7.13 + 0.37));
}


void fragment() {
	vec2 uv = UV * base_uv_scale;
	vec3 position = v_world_position;
	vec3 world_normal = normalize(v_world_normal);
	vec3 view = normalize(CAMERA_POSITION_WORLD - position);
	float detail_fade = 1.0 - smoothstep(detail_near, detail_far,
		length(CAMERA_POSITION_WORLD - position));

	// TEXCOORD_0 is visible color paint; COLOR_0 remains the semantic mask and
	// multiplicative authored colour.
	vec4 sampled = texture(base_texture, uv);
	vec3 albedo = base_color * sampled.rgb * v_tone;
	if (use_vertex_color) {
		albedo *= COLOR.rgb;
	}

	if (macro_amount > 0.0) {
		float macro = vivid_fbm3(position * macro_scale, 3);
		albedo *= mix(1.0, 0.72 + 0.56 * macro, macro_amount);
	}
	float grain = 0.5;
	if (detail_amount * detail_fade > 0.0 || roughness_variation > 0.0) {
		grain = vivid_fbm3(position * detail_scale, 3);
		albedo *= mix(1.0, 0.75 + 0.5 * grain,
			detail_amount * detail_fade);
	}
	albedo = vivid_saturate(albedo, saturation) * brightness;

	vec2 region = vivid_region(vivid_up(position));
	vec3 region_color = vivid_spectrum(region.x);
	albedo = mix(albedo,
		vivid_saturate(albedo * region_color * 2.0, saturation * 0.8),
		region_albedo * mix(0.35, 1.0, region.y));

	vec3 shaped = vivid_bump_normal(position, world_normal, bump_scale,
		bump_strength * detail_fade, 0.0);
	vec3 view_normal = vivid_to_view(VIEW_MATRIX, shaped);
	if (texture_relief > 0.0) {
		vec2 texel = relief_width / vec2(textureSize(base_texture, 0));
		float here = dot(sampled.rgb, vec3(0.2126, 0.7152, 0.0722));
		float along = dot(
			texture(base_texture, uv + vec2(texel.x, 0.0)).rgb,
			vec3(0.2126, 0.7152, 0.0722));
		float across = dot(
			texture(base_texture, uv + vec2(0.0, texel.y)).rgb,
			vec3(0.2126, 0.7152, 0.0722));
		view_normal = normalize(view_normal
			- (TANGENT * (along - here) + BINORMAL * (across - here))
			* texture_relief * 6.0 * detail_fade);
	}

	float camera_facing = 1.0 - clamp(dot(shaped, view), 0.0, 1.0);
	float fresnel = pow(camera_facing, 4.0);
	float camera_rim = vivid_camera_rim(
		shaped, view, camera_rim_dark, camera_rim_light);

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	NORMAL = view_normal;
	ROUGHNESS = clamp(roughness
		* mix(1.0, 0.6 + 0.8 * grain, roughness_variation), 0.02, 1.0);
	METALLIC = metallic;
	SPECULAR = specular;
	RIM = region_rim * mix(0.4, 1.0, region.y);
	RIM_TINT = 0.4;

	vec3 night_emission = vec3(0.0);
	if (night_emission_energy > 0.0) {
		float night = 1.0 - smoothstep(-0.16, 0.12,
			dot(vivid_up(position), normalize(-sun_direction)));
		float night_pulse = 1.0;
		if (night_pulse_amount > 0.0) {
			night_pulse += night_pulse_amount * sin(
				TIME * TAU * night_pulse_speed * v_night_rate
					+ v_night_phase * TAU);
		}
		night_emission = night_emission_color * night_emission_energy
			* night * night_pulse
			* (night_emission_from_texture_alpha ? sampled.a : 1.0)
			* mix(vec3(1.0), albedo, night_emission_albedo);
	}
	EMISSION = emission_color * emission_energy
		+ region_color * fresnel * region_sheen * region.y * 0.5
		+ vivid_camera_rim_colour(camera_rim_color)
			* camera_rim_energy * camera_rim
		+ night_emission;
}
