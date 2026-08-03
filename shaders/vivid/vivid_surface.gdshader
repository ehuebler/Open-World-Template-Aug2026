// Everything that is not the ground or the sky: props, garments, weapons, and
// whatever a .glb arrives carrying.
//
// The problem this shader exists to solve is that the project's art is flat
// albedo — hand-painted ~500 px textures and single-colour Blender materials,
// with no normal maps, no roughness maps and no intention of ever authoring
// them. Lit plainly, that reads as coloured plastic. So relief is manufactured
// from what is already there:
//
//   the texture     its own brightness is read as height, so painted brick
//                   catches light along its mortar lines
//   3D noise        two scales of it, one for grain and one for the blotchy
//                   variation that stops a large flat panel being one wash
//   the region      the planet's colour wheel reaches objects too, so a player
//                   walking between regions changes colour with the ground
//
// None of it touches the lighting model. Diffuse and specular are Godot's own,
// which is what keeps the result reading as a real surface rather than as a
// filter over one.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Fill;
uniform vec3 base_color : source_color = vec3(0.82, 0.80, 0.78);
uniform sampler2D base_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// Tiling for base_texture only. Primitive meshes hand out one UV span across the
// whole surface, so a floor needs this to keep its texture at a sane size.
uniform vec2 base_uv_scale = vec2(1.0, 1.0);
uniform bool use_vertex_color = false;
uniform float saturation : hint_range(0.0, 3.0) = 1.35;
uniform float brightness : hint_range(0.0, 2.0) = 1.0;
group_uniforms;

group_uniforms Surface;
uniform float roughness : hint_range(0.0, 1.0) = 0.65;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
// Varies roughness with the detail noise, so highlights break up across a panel
// instead of sliding over it as one clean shape.
uniform float roughness_variation : hint_range(0.0, 1.0) = 0.25;
group_uniforms;

group_uniforms Texture_Relief;
// Height read from the texture's own brightness. This is the single biggest win
// on flat art and costs two extra taps.
uniform float texture_relief : hint_range(0.0, 4.0) = 1.0;
// Widens the sampling stride past one texel, for textures painted softer than
// their resolution.
uniform float relief_width : hint_range(1.0, 8.0) = 1.5;
group_uniforms;

group_uniforms Detail;
// Cycles per metre.
uniform float detail_scale = 6.0;
uniform float detail_amount : hint_range(0.0, 1.0) = 0.18;
uniform float bump_scale = 9.0;
uniform float bump_strength : hint_range(0.0, 1.0) = 0.18;
uniform float macro_scale = 0.45;
uniform float macro_amount : hint_range(0.0, 1.0) = 0.22;
// Detail is three noise fields per pixel and aliases once a bump is smaller than
// a pixel, so it fades out with distance rather than shimmering at range.
uniform float detail_near = 12.0;
uniform float detail_far = 60.0;
group_uniforms;

group_uniforms Region;
// Kept a little under the terrain's, so a prop standing on the ground shifts
// with it rather than reading as painted a different colour from it.
uniform float region_albedo : hint_range(0.0, 1.0) = 0.34;
uniform float region_sheen : hint_range(0.0, 2.0) = 0.35;
uniform float region_rim : hint_range(0.0, 1.0) = 0.4;
group_uniforms;

group_uniforms Emission;
uniform vec3 emission_color : source_color = vec3(0.0, 0.0, 0.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;

void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv = UV * base_uv_scale;
	vec3 position = v_world_position;
	vec3 world_normal = normalize(v_world_normal);
	vec3 view = normalize(CAMERA_POSITION_WORLD - position);
	float detail_fade = 1.0 - smoothstep(detail_near, detail_far,
		length(CAMERA_POSITION_WORLD - position));

	vec4 sampled = texture(base_texture, uv);
	vec3 albedo = base_color * sampled.rgb;
	if (use_vertex_color) {
		albedo *= COLOR.rgb;
	}

	// Both fields are skipped rather than multiplied by nothing when they are
	// turned off. A character carries this material, is on screen every frame,
	// and wants none of it — see player_suit.tres — so leaving two fbm fields
	// running to be discarded is the whole cost of the shader for no picture.
	// 0.5 is the neutral grain: it leaves ROUGHNESS exactly where it started.
	if (macro_amount > 0.0) {
		float macro = vivid_fbm3(position * macro_scale, 3);
		albedo *= mix(1.0, 0.72 + 0.56 * macro, macro_amount);
	}
	float grain = 0.5;
	if (detail_amount * detail_fade > 0.0 || roughness_variation > 0.0) {
		grain = vivid_fbm3(position * detail_scale, 3);
		albedo *= mix(1.0, 0.75 + 0.5 * grain, detail_amount * detail_fade);
	}
	albedo = vivid_saturate(albedo, saturation) * brightness;

	vec2 region = vivid_region(vivid_up(position));
	vec3 region_color = vivid_spectrum(region.x);
	albedo = mix(albedo, vivid_saturate(albedo * region_color * 2.0, saturation * 0.8),
		region_albedo * mix(0.35, 1.0, region.y));

	// Bend the normal in world space, where the noise lives and no tangents are
	// needed, then hand it to view space for the texture's own relief to be
	// added along the UV axes.
	vec3 shaped = vivid_bump_normal(position, world_normal, bump_scale,
		bump_strength * detail_fade);
	vec3 view_normal = vivid_to_view(VIEW_MATRIX, shaped);

	if (texture_relief > 0.0) {
		vec2 texel = relief_width / vec2(textureSize(base_texture, 0));
		float here = dot(sampled.rgb, vec3(0.2126, 0.7152, 0.0722));
		float along = dot(texture(base_texture, uv + vec2(texel.x, 0.0)).rgb,
			vec3(0.2126, 0.7152, 0.0722));
		float across = dot(texture(base_texture, uv + vec2(0.0, texel.y)).rgb,
			vec3(0.2126, 0.7152, 0.0722));
		view_normal = normalize(view_normal
			- (TANGENT * (along - here) + BINORMAL * (across - here))
			* texture_relief * 6.0 * detail_fade);
	}

	float fresnel = pow(1.0 - clamp(dot(shaped, view), 0.0, 1.0), 4.0);

	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	NORMAL = view_normal;
	ROUGHNESS = clamp(roughness * mix(1.0, 0.6 + 0.8 * grain, roughness_variation), 0.02, 1.0);
	METALLIC = metallic;
	SPECULAR = specular;
	RIM = region_rim * mix(0.4, 1.0, region.y);
	RIM_TINT = 0.4;
	EMISSION = emission_color * emission_energy
		+ region_color * fresnel * region_sheen * region.y * 0.5;
}
