// Opaque, high-viscosity lava for the south-pole caldera.
//
// Motion is entirely in the material. The analytical pool surface used by the
// player remains fixed, so visual ripples can never pull the body below it.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley,
	specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Lava;
uniform vec3 crust_color : source_color = vec3(0.035, 0.018, 0.015);
uniform vec3 molten_color : source_color = vec3(0.95, 0.055, 0.004);
uniform vec3 hot_color : source_color = vec3(1.0, 0.52, 0.025);
uniform float emission_energy : hint_range(0.0, 12.0) = 5.2;
uniform float crust_share : hint_range(0.0, 1.0) = 0.48;
uniform float roughness : hint_range(0.0, 1.0) = 0.38;
uniform float specular : hint_range(0.0, 1.0) = 0.58;
group_uniforms;

group_uniforms Flow;
uniform float flow_scale = 0.032;
uniform float flow_speed : hint_range(0.0, 2.0) = 0.12;
uniform float fold_scale = 0.105;
uniform float fold_speed : hint_range(0.0, 3.0) = 0.24;
uniform float bump_strength : hint_range(0.0, 1.0) = 0.22;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;


void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(transpose(inverse(mat3(MODEL_MATRIX))) * NORMAL);
}


void fragment() {
	vec3 position = v_world_position;
	vec3 normal = normalize(v_world_normal);
	vec3 drift = vec3(TIME * flow_speed, -TIME * flow_speed * 0.37,
		TIME * flow_speed * 0.61);
	float body = vivid_hetero3(position * flow_scale, 4, 0.72, drift);
	float folds = vivid_ridge3(
		position * fold_scale + drift * fold_speed * 7.0, 3);
	float crust = smoothstep(
		0.42 - folds * 0.13, 0.72, body) * crust_share;
	float seam = smoothstep(0.64, 0.9, folds) * (1.0 - crust * 0.7);
	float heat = clamp((1.0 - crust) * (0.62 + seam * 0.72), 0.0, 1.0);

	vec3 albedo = mix(molten_color, crust_color, crust);
	albedo = mix(albedo, hot_color, seam * 0.34);
	vec3 shaped = vivid_bump_normal(
		position + drift * 2.0, normal, fold_scale,
		bump_strength * (0.35 + crust * 0.65), 0.08);

	ALBEDO = albedo;
	NORMAL = vivid_to_view(VIEW_MATRIX, shaped);
	ROUGHNESS = mix(roughness * 0.72, roughness, crust);
	SPECULAR = specular;
	METALLIC = 0.0;
	EMISSION = mix(molten_color, hot_color, seam)
		* emission_energy * heat;
}
