// A school is one static MultiMesh. The authored swim lives in a position VAT;
// phase and speed are the only values that differ per fish, so no skeleton,
// AnimationPlayer or per-frame CPU walk is involved.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley,
	specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"
#include "res://shaders/vivid/vivid_vat.gdshaderinc"

uniform bool vat_enabled = false;
uniform sampler2D vat_positions : filter_nearest, repeat_disable;
uniform float vat_frame_count = 1.0;
uniform float vat_fps = 24.0;
uniform float vat_playback_speed = 1.0;
uniform vec3 vat_delta_min = vec3(0.0);
uniform vec3 vat_delta_max = vec3(0.0);

uniform vec3 base_color : source_color = vec3(1.0);
uniform float saturation : hint_range(0.0, 3.0) = 1.2;
uniform float roughness : hint_range(0.0, 1.0) = 0.62;
uniform float specular : hint_range(0.0, 1.0) = 0.35;
uniform float sheen : hint_range(0.0, 3.0) = 0.18;
// Optional bioluminescence for nocturnal/deep-water variants. The school
// already supplies stable random custom channels, so colour, phase and speed
// vary per fish without another buffer or material split.
uniform vec3 night_emission_color : source_color = vec3(0.0);
uniform float night_emission_energy : hint_range(0.0, 6.0) = 0.0;
uniform float night_emission_albedo : hint_range(0.0, 1.0) = 0.8;
uniform float night_pulse_amount : hint_range(0.0, 0.8) = 0.0;
uniform float night_pulse_speed : hint_range(0.0, 4.0) = 0.7;

varying vec3 v_world_position;
varying vec3 v_world_normal;
varying float v_tone;
varying float v_phase;


void vertex() {
	float speed = mix(0.85, 1.15, INSTANCE_CUSTOM.z);
	if (vat_enabled) {
		VERTEX += vivid_vat_delta(vat_positions, UV2.x, TIME, INSTANCE_CUSTOM.y,
			vat_playback_speed * speed, vat_frame_count, vat_fps,
			vat_delta_min, vat_delta_max);
	}
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_tone = mix(0.86, 1.14, INSTANCE_CUSTOM.w);
	v_phase = INSTANCE_CUSTOM.x;
}


void fragment() {
	vec3 albedo = vivid_saturate(base_color * COLOR.rgb * v_tone, saturation);
	vec3 own_color = albedo;
	// Water is a transparent surface rather than a post-process volume in this
	// project, so underwater props apply the shared visibility law themselves.
	float depth = max(planet_radius - distance(v_world_position, planet_center), 0.0);
	float sight = distance(CAMERA_POSITION_WORLD, v_world_position);
	float murk = 1.0 - exp(-sight / max(murk_visibility, 1.0));
	float daylight = exp(-depth / max(murk_daylight, 1.0));
	albedo = mix(albedo * mix(0.22, 1.0, daylight), murk_color, murk * 0.82);

	vec3 view = normalize(CAMERA_POSITION_WORLD - v_world_position);
	float rim = pow(1.0 - max(dot(normalize(v_world_normal), view), 0.0), 3.0);
	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	ROUGHNESS = roughness;
	SPECULAR = specular;
	METALLIC = 0.0;
	RIM = 0.28;
	RIM_TINT = 0.6;
	float night = 1.0 - smoothstep(-0.16, 0.12,
		dot(vivid_up(v_world_position), normalize(-sun_direction)));
	float pulse = 1.0 + night_pulse_amount * sin(
		TIME * TAU * night_pulse_speed * mix(0.78, 1.24, v_phase)
			+ v_phase * TAU);
	vec3 night_glow = night_emission_color * night_emission_energy * night
		* pulse * mix(vec3(1.0), own_color, night_emission_albedo);
	EMISSION = albedo * rim * sheen * daylight + night_glow;
}
