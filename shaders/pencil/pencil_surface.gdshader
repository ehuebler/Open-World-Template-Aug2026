// Colored-pencil surface shader.
//
// Three layers stacked in one material:
//   1. flat banded colour fill (posterized lighting, tinted shadow)
//   2. procedural pencil hatching that gets denser as the surface darkens
//   3. a parallax offset applied only to the hatching, so the strokes read as
//      a separate sheet of paper floating just above the form
//
// Ambient light is taken over by the Fill uniforms below so the shadow side
// stays hatched instead of being flooded by the environment.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled, ambient_light_disabled;

#include "res://shaders/pencil/pencil_lib.gdshaderinc"

group_uniforms Fill;
uniform vec3 base_color : source_color = vec3(0.78, 0.73, 0.61);
uniform sampler2D base_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// Tiling for base_texture only. Primitive meshes hand out one UV span across the
// whole surface, so a floor needs this to keep its texture at a sane size.
uniform vec2 base_uv_scale = vec2(1.0, 1.0);
// Multiplies the fill by the mesh's vertex colours. Generated meshes that vary in
// colour across one surface — terrain, which is water, sand, grass and rock in a
// single chunk — carry it there rather than in a texture nobody authored.
uniform bool use_vertex_color = false;
// 0 keeps the smooth colour, higher values posterize it like flat marker fill.
uniform int color_steps : hint_range(0, 12) = 0;
group_uniforms;

group_uniforms Shading;
uniform int light_bands : hint_range(1, 6) = 2;
uniform float band_softness : hint_range(0.0, 0.5) = 0.05;
uniform float light_wrap : hint_range(0.0, 1.0) = 0.3;
uniform float shadow_leak : hint_range(0.0, 1.0) = 0.12;
// Breaks up the light/shadow boundary so the terminator looks drawn.
uniform float terminator_wobble : hint_range(0.0, 0.5) = 0.07;
group_uniforms;

group_uniforms Fill_Light;
uniform vec3 fill_color : source_color = vec3(0.63, 0.67, 0.83);
uniform float fill_energy : hint_range(0.0, 2.0) = 0.55;
// Hatch density used for the ambient term, i.e. how heavily shadow is scribbled.
uniform float fill_tone : hint_range(0.0, 1.0) = 0.35;
group_uniforms;

group_uniforms Pencil;
uniform vec3 ink_color : source_color = vec3(0.17, 0.14, 0.21);
// 0 draws strokes in a darker shade of the fill, 1 draws them in ink_color.
uniform float ink_tint : hint_range(0.0, 1.0) = 0.5;
uniform float ink_strength : hint_range(0.0, 1.0) = 0.85;
uniform int hatch_space : hint_enum("Model UV", "Model Triplanar", "World Triplanar", "Screen") = 1;
uniform float hatch_scale = 14.0;
uniform vec4 hatch_angles_degrees = vec4(28.0, -37.0, 74.0, 6.0);
uniform vec4 hatch_layer_scales = vec4(1.0, 1.33, 0.82, 1.71);
uniform float stroke_thickness : hint_range(0.05, 1.0) = 0.4;
uniform float stroke_wobble : hint_range(0.0, 2.0) = 0.55;
uniform float stroke_breakup : hint_range(0.0, 0.9) = 0.26;
uniform float tone_gamma : hint_range(0.2, 3.0) = 1.0;
uniform sampler2D hatch_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float hatch_texture_blend : hint_range(0.0, 1.0) = 0.0;
uniform float hatch_texture_scale = 0.12;
group_uniforms;

group_uniforms Redraw;
uniform float redraw_jitter : hint_range(0.0, 4.0) = 0.5;
uniform float redraw_fps : hint_range(0.0, 24.0) = 8.0;
group_uniforms;

group_uniforms Parallax;
uniform float parallax_strength : hint_range(0.0, 0.5) = 0.03;
// Per stroke layer depth, so the four layers separate slightly as you move.
uniform vec4 parallax_layer_depths = vec4(0.2, 0.5, 0.8, 1.0);
uniform sampler2D height_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float height_texture_blend : hint_range(0.0, 1.0) = 0.0;
uniform float height_scale = 2.5;
group_uniforms;

group_uniforms Paper;
uniform float paper_grain : hint_range(0.0, 1.0) = 0.22;
uniform float paper_grain_scale = 320.0;
uniform bool paper_grain_screen_space = true;
group_uniforms;

group_uniforms Edges;
// Extra hatching where the surface turns away, the way you'd press harder
// around a form's edge.
uniform float edge_ink : hint_range(0.0, 1.0) = 0.3;
uniform float edge_width : hint_range(0.05, 1.0) = 0.45;
group_uniforms;

varying vec3 v_model_position;
varying vec3 v_model_normal;
varying vec3 v_world_position;
varying vec3 v_world_normal;

// Assigned in fragment(), read in light().
varying vec4 v_layers;
varying vec3 v_fill;
varying vec3 v_ink;
varying float v_edge;
varying float v_wobble;

float hatch_layer(vec2 uv, float angle_degrees, float layer_scale, float seed) {
	float ink = pencil_strokes(uv, angle_degrees, layer_scale, stroke_thickness, stroke_wobble, stroke_breakup, seed);
	if (hatch_texture_blend > 0.0) {
		vec2 tex_uv = pencil_rotate(uv * layer_scale, radians(angle_degrees)) * hatch_texture_scale;
		ink = mix(ink, 1.0 - texture(hatch_texture, tex_uv).r, hatch_texture_blend);
	}
	return ink;
}

void vertex() {
	v_model_position = VERTEX;
	v_model_normal = NORMAL;
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	vec3 fill = base_color * texture(base_texture, UV * base_uv_scale).rgb;
	if (use_vertex_color) {
		fill *= COLOR.rgb;
	}
	if (color_steps > 0) {
		fill = floor(fill * float(color_steps) + 0.5) / float(color_steps);
	}

	vec3 camera_position = INV_VIEW_MATRIX[3].xyz;
	vec3 world_view = normalize(camera_position - v_world_position);
	vec3 world_normal = normalize(v_world_normal);

	// Pick the 2D space the strokes live in, and the direction the strokes
	// should slide when the camera moves (both must use the same projection).
	vec2 coord;
	vec2 slide;
	if (hatch_space == 0) {
		coord = UV;
		vec3 view_tangent_space = vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), dot(VIEW, NORMAL));
		slide = -view_tangent_space.xy / max(abs(view_tangent_space.z), 0.2);
	} else if (hatch_space == 3) {
		// One unit is 100 pixels here, so hatch_scale reads as strokes per
		// 100 pixels of screen instead of strokes per world unit.
		coord = SCREEN_UV * VIEWPORT_SIZE * 0.01;
		float facing = max(dot(VIEW, NORMAL), 0.2);
		slide = -(VIEW - NORMAL * dot(VIEW, NORMAL)).xy / facing;
	} else {
		bool model_space = hatch_space == 1;
		vec3 point = model_space ? v_model_position : v_world_position;
		vec3 normal = normalize(model_space ? v_model_normal : v_world_normal);
		// Transposing MODEL_MATRIX inverts it for rotation plus uniform scale,
		// which is all a direction needs since it gets normalized anyway.
		vec3 view_dir = model_space
			? normalize((vec4(world_view, 0.0) * MODEL_MATRIX).xyz)
			: world_view;
		int axis = pencil_dominant_axis(normal);
		coord = pencil_project(point, axis);
		slide = pencil_project(view_dir - normal * dot(view_dir, normal), axis) / max(dot(view_dir, normal), 0.2);
	}

	float boil = pencil_boil(TIME, redraw_fps);
	vec2 jitter = (vec2(pencil_hash11(boil * 1.7 + 0.3), pencil_hash11(boil * 3.1 + 11.0)) - 0.5) * redraw_jitter;

	// Parallax mapping math, but the offset is spent on the stroke layers only.
	float height = pencil_fbm(coord * height_scale);
	height = mix(height, texture(height_texture, coord * height_scale).r, height_texture_blend);
	vec2 parallax = slide * (height - 0.5) * parallax_strength * hatch_scale;

	vec2 hatch_uv = coord * hatch_scale + jitter;
	vec4 layers;
	layers.x = hatch_layer(hatch_uv + parallax * parallax_layer_depths.x, hatch_angles_degrees.x, hatch_layer_scales.x, 1.0);
	layers.y = hatch_layer(hatch_uv + parallax * parallax_layer_depths.y, hatch_angles_degrees.y, hatch_layer_scales.y, 2.0);
	layers.z = hatch_layer(hatch_uv + parallax * parallax_layer_depths.z, hatch_angles_degrees.z, hatch_layer_scales.z, 3.0);
	layers.w = hatch_layer(hatch_uv + parallax * parallax_layer_depths.w, hatch_angles_degrees.w, hatch_layer_scales.w, 4.0);

	if (paper_grain > 0.0) {
		vec2 grain_uv = paper_grain_screen_space ? SCREEN_UV * VIEWPORT_SIZE / VIEWPORT_SIZE.y : coord;
		float grain = pencil_noise(grain_uv * paper_grain_scale + boil);
		fill *= mix(1.0 - paper_grain * 0.5, 1.0 + paper_grain * 0.25, grain);
	}

	float facing = 1.0 - abs(dot(world_normal, world_view));
	float edge = smoothstep(1.0 - edge_width, 1.0, facing) * edge_ink;
	vec3 ink = mix(fill * 0.3, ink_color, ink_tint);

	v_layers = layers;
	v_fill = fill;
	v_ink = ink;
	v_edge = edge;
	v_wobble = (pencil_fbm(coord * 2.5 + boil * 0.13) - 0.5) * terminator_wobble;

	ALBEDO = fill;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;

	// Stand-in for ambient light: the unlit look, scribbled at fill_tone density.
	float fill_hatch = pencil_hatch(layers, clamp(pow(fill_tone, tone_gamma) - edge, 0.0, 1.0)) * ink_strength;
	EMISSION = mix(fill, ink, fill_hatch) * fill_color * fill_energy;
}

void light() {
	float ndotl = dot(normalize(NORMAL), normalize(LIGHT));
	float wrapped = clamp((ndotl + light_wrap) / (1.0 + light_wrap), 0.0, 1.0);
	float lit = clamp(wrapped * ATTENUATION + v_wobble, 0.0, 1.0);
	float level = mix(shadow_leak, 1.0, pencil_bands(lit, light_bands, band_softness));

	float tone = clamp(pow(level, tone_gamma) - v_edge, 0.0, 1.0);
	float coverage = pencil_hatch(v_layers, tone) * ink_strength;
	DIFFUSE_LIGHT += mix(v_fill, v_ink, coverage) * LIGHT_COLOR * level / PI;
}
