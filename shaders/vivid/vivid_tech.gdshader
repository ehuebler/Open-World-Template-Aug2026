// Faceted alien technology: real PBR reflections over a fixed magenta/turquoise
// thin-film palette. The authored mesh owns every silhouette and large panel;
// this adds only a view-dependent colour shift and fine highlight breakup.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Film;
uniform vec3 deep_color : source_color = vec3(0.055, 0.018, 0.11);
uniform vec3 magenta : source_color = vec3(1.0, 0.035, 0.72);
uniform vec3 turquoise : source_color = vec3(0.015, 0.95, 0.9);
uniform float film_albedo : hint_range(0.0, 1.0) = 0.72;
uniform float film_bands : hint_range(0.5, 12.0) = 4.6;
uniform float film_noise_scale = 0.18;
uniform float film_emission : hint_range(0.0, 3.0) = 0.82;
group_uniforms;

group_uniforms Reflection;
uniform float roughness : hint_range(0.0, 1.0) = 0.14;
uniform float roughness_variation : hint_range(0.0, 0.5) = 0.16;
uniform float specular : hint_range(0.0, 1.0) = 0.92;
uniform float rim : hint_range(0.0, 1.0) = 0.48;
group_uniforms;

group_uniforms Surface_Detail;
uniform float variation_scale = 0.22;
uniform float variation_amount : hint_range(0.0, 0.5) = 0.16;
uniform float detail_near = 18.0;
uniform float detail_far = 170.0;
uniform float bump_scale = 20.0;
uniform float bump_strength : hint_range(0.0, 0.4) = 0.07;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;
varying float v_phase;
varying float v_bias;


void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_phase = INSTANCE_CUSTOM.x;
	v_bias = INSTANCE_CUSTOM.y;
}


void fragment() {
	vec3 position = v_world_position;
	vec3 world_normal = normalize(v_world_normal);
	vec3 view = normalize(CAMERA_POSITION_WORLD - position);
	float distance_to_eye = length(CAMERA_POSITION_WORLD - position);
	float detail_fade = 1.0 - smoothstep(detail_near, detail_far, distance_to_eye);

	vec3 shaped = vivid_bump_normal(position, world_normal, bump_scale,
		bump_strength * detail_fade, 0.0);
	float incidence = clamp(dot(shaped, view), 0.0, 1.0);
	float film_noise = vivid_fbm3(position * film_noise_scale
		+ vec3(v_phase * 19.0), 2);
	float phase = incidence * film_bands + film_noise * 0.72
		+ dot(shaped, vec3(0.31, 0.73, 0.19)) * 0.34 + v_phase;
	float wave = 0.5 + 0.5 * cos(TAU * phase);
	vec3 iris = mix(turquoise, magenta, smoothstep(0.18, 0.82, wave));

	// Continuous noise breaks up the reflection without drawing a second square
	// pattern over the hundreds of square panels already present in the mesh.
	float variation = vivid_fbm3(position * variation_scale
		+ vec3(v_phase * 31.0), 2);
	vec3 albedo = mix(deep_color, iris, film_albedo);
	albedo *= mix(1.0 - variation_amount, 1.0 + variation_amount, variation);

	float fresnel = pow(1.0 - incidence, 3.2);
	float varied_roughness = roughness
		+ (variation - 0.5) * roughness_variation * detail_fade;

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	NORMAL = vivid_to_view(VIEW_MATRIX, shaped);
	ROUGHNESS = clamp(varied_roughness, 0.035, 0.72);
	// The sky is strongly coloured; dielectric specular keeps the film legible
	// in shadow where metallic would reduce the whole object to that sky colour.
	METALLIC = 0.0;
	SPECULAR = specular;
	RIM = rim;
	RIM_TINT = 0.62;
	EMISSION = iris * film_emission * fresnel * mix(0.82, 1.18, v_bias);
}
