// Giant translucent crystal rings. Geometry owns the silhouette; this shader
// supplies a stable world-space interior, green absorption and emission that is
// present under the noon sun as well as at night.
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Crystal;
uniform vec3 deep_green : source_color = vec3(0.008, 0.18, 0.055);
uniform vec3 body_green : source_color = vec3(0.025, 0.72, 0.22);
uniform vec3 heart_green : source_color = vec3(0.28, 1.0, 0.46);
uniform float body_alpha : hint_range(0.2, 0.95) = 0.58;
uniform float edge_alpha : hint_range(0.2, 1.0) = 0.82;
uniform float internal_scale = 0.055;
uniform float internal_strength : hint_range(0.0, 1.0) = 0.42;
group_uniforms;

group_uniforms Light;
uniform float emission_energy : hint_range(0.0, 8.0) = 2.2;
uniform float edge_emission : hint_range(0.0, 8.0) = 2.8;
uniform float pulse_amount : hint_range(0.0, 0.3) = 0.055;
uniform float pulse_speed : hint_range(0.0, 2.0) = 0.18;
group_uniforms;

group_uniforms Reflection;
uniform float roughness : hint_range(0.0, 1.0) = 0.085;
uniform float specular : hint_range(0.0, 1.0) = 0.92;
uniform float rim : hint_range(0.0, 1.0) = 0.58;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;
varying float v_phase;
varying float v_variation;


void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_phase = INSTANCE_CUSTOM.x;
	v_variation = INSTANCE_CUSTOM.y;
}


void fragment() {
	vec3 position = v_world_position;
	vec3 world_normal = normalize(v_world_normal);
	if (!FRONT_FACING) {
		world_normal = -world_normal;
	}
	vec3 view = normalize(CAMERA_POSITION_WORLD - position);
	float incidence = clamp(abs(dot(world_normal, view)), 0.0, 1.0);
	float fresnel = pow(1.0 - incidence, 2.35);

	// Wide, low-frequency planes resemble inclusions inside one grown crystal.
	// They are world anchored and analytic, so flying past a ring cannot make
	// texture pixels crawl over a structure hundreds of metres tall.
	float noise = vivid_fbm3(
		position * internal_scale + vec3(v_phase * 17.0), 2);
	float strata = 0.5 + 0.5 * sin(
		dot(position, vec3(0.073, 0.041, 0.058))
		+ noise * 4.2 + v_phase * TAU);
	strata = smoothstep(0.24, 0.78, strata);
	float inclusion = mix(noise, strata, internal_strength);

	vec3 albedo = mix(deep_green, body_green, 0.64 + 0.25 * incidence);
	albedo = mix(albedo, heart_green, inclusion * 0.24);
	albedo *= mix(0.88, 1.12, v_variation);

	float pulse = 1.0 + pulse_amount * sin(
		TIME * TAU * pulse_speed + v_phase * TAU);
	vec3 emission = mix(body_green, heart_green, 0.38 + inclusion * 0.34)
		* (emission_energy + fresnel * edge_emission) * pulse;

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	NORMAL = vivid_to_view(VIEW_MATRIX, world_normal);
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = specular;
	RIM = rim;
	RIM_TINT = 0.78;
	EMISSION = emission;
	ALPHA = mix(body_alpha, edge_alpha, fresnel);
}
