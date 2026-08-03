// Colored-pencil surface for UI, the 2D counterpart of pencil_surface.gdshader.
//
// Draws a rounded rectangle of paper, shades it with the same procedural
// hatching the 3D material uses, and traces its border with a few sketchy
// strokes. Meant to sit behind a Control's own drawing (see PencilSurface in
// ui/themes/pencil_surface.gd), so text and icons stay crisp on top.
//
// `fill_tone` replaces the lighting: 1.0 is bare paper, and lower values switch
// on more stroke layers, which is how button hover and press states are drawn.
shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/pencil/pencil_lib.gdshaderinc"

group_uniforms Paper;
// Defaults are the project's paper and pencil, i.e. Dust Grey and Jet Black from
// ui/themes/ui_palette.tres; PencilSurface overrides them per style.
uniform vec3 paper_color : source_color = vec3(0.855, 0.824, 0.847);
uniform float paper_alpha : hint_range(0.0, 1.0) = 1.0;
uniform float paper_grain : hint_range(0.0, 1.0) = 0.22;
// Grain cells per 100 px, in screen space, so every panel and button shares one
// continuous sheet of paper instead of each carrying its own tooth.
uniform float paper_grain_scale = 45.0;
group_uniforms;

group_uniforms Shape;
// Every pixel measurement below is in viewport units, i.e. the size the project
// designs against, so line weight and stroke spacing survive both the
// canvas_items stretch and a hiDPI window.
uniform float reference_height = 720.0;
uniform float corner_radius = 16.0;
// Pixels of the rect kept clear on every side. The backing rect is grown past
// the Control it belongs to so wandering border strokes are not clipped, and
// this pulls the drawn shape back onto the Control's real bounds.
uniform float inset_pixels = 0.0;
group_uniforms;

group_uniforms Pencil;
uniform vec3 ink_color : source_color = vec3(0.078, 0.212, 0.259);
// 0 draws strokes in a darker shade of the paper, 1 draws them in ink_color.
uniform float ink_tint : hint_range(0.0, 1.0) = 0.5;
// Lower than the 3D material's: menu text sits directly on these strokes, so
// they read as shading rather than as ink.
uniform float ink_strength : hint_range(0.0, 1.0) = 0.5;
uniform float fill_tone : hint_range(0.0, 1.0) = 1.0;
uniform float tone_gamma : hint_range(0.2, 3.0) = 1.0;
// Strokes per 100 px, matching the Screen setting of pencil_surface.gdshader.
uniform float hatch_scale = 12.0;
uniform vec4 hatch_angles_degrees = vec4(28.0, -37.0, 74.0, 6.0);
uniform vec4 hatch_layer_scales = vec4(1.0, 1.33, 0.82, 1.71);
uniform float stroke_thickness : hint_range(0.05, 1.0) = 0.2;
uniform float stroke_wobble : hint_range(0.0, 2.0) = 0.55;
uniform float stroke_breakup : hint_range(0.0, 0.9) = 0.26;
group_uniforms;

group_uniforms Edges;
// Extra hatching pressed in along the border, the way a hand shades a rim.
uniform float edge_ink : hint_range(0.0, 1.0) = 0.25;
uniform float edge_width_pixels = 26.0;
group_uniforms;

group_uniforms Border;
uniform vec3 border_color : source_color = vec3(0.078, 0.212, 0.259);
uniform int border_passes : hint_range(0, 3) = 2;
uniform float border_pixels : hint_range(0.0, 8.0) = 2.0;
uniform float border_jitter : hint_range(0.0, 1.0) = 0.45;
// Sideways drift per pass, so stacked strokes never trace the same path.
uniform float border_wander_pixels : hint_range(0.0, 8.0) = 2.4;
uniform float border_gaps : hint_range(0.0, 0.9) = 0.16;
uniform float border_noise_scale = 0.035;
uniform float border_seed = 0.0;
group_uniforms;

group_uniforms Redraw;
uniform float redraw_jitter : hint_range(0.0, 4.0) = 0.4;
uniform float redraw_fps : hint_range(0.0, 24.0) = 8.0;
group_uniforms;

float hatch_layer(vec2 uv, float angle_degrees, float layer_scale, float seed) {
	return pencil_strokes(uv, angle_degrees, layer_scale, stroke_thickness, stroke_wobble, stroke_breakup, seed);
}

// Signed distance to the rounded rect, negative inside.
float rounded_rect_distance(vec2 point, vec2 half_size, float radius) {
	float limit = min(radius, min(half_size.x, half_size.y));
	vec2 q = abs(point) - half_size + limit;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - limit;
}

void fragment() {
	// Screen pixels per viewport unit: 2.0 for a 1440p window on a 720p project.
	float pixel_scale = max((1.0 / SCREEN_PIXEL_SIZE.y) / max(reference_height, 1.0), 0.001);
	// UV runs 0..1 across the rect, so one screen pixel's worth of it is
	// fwidth(UV); inverting that recovers the rect size without a script feeding
	// in sizes on every resize.
	vec2 rect_pixels = 1.0 / max(fwidth(UV), vec2(0.000001)) / pixel_scale;
	// One screen pixel, which is what the antialiasing below is allowed to spend.
	float aa = 1.0 / pixel_scale;
	vec2 point = (UV - 0.5) * rect_pixels;
	vec2 half_size = max(rect_pixels * 0.5 - inset_pixels, vec2(0.5));
	float border_distance = rounded_rect_distance(point, half_size, corner_radius);

	float boil = pencil_boil(TIME, redraw_fps);
	vec2 jitter = (vec2(pencil_hash11(boil * 1.7 + 0.3), pencil_hash11(boil * 3.1 + 11.0)) - 0.5) * redraw_jitter;

	// One hatch unit is 100 px, measured from the middle of the rect, so a widget
	// that grows covers more of the same stroke field instead of stretching it.
	vec2 hatch_uv = point * 0.01 * hatch_scale + jitter;
	vec4 layers;
	layers.x = hatch_layer(hatch_uv, hatch_angles_degrees.x, hatch_layer_scales.x, 1.0);
	layers.y = hatch_layer(hatch_uv, hatch_angles_degrees.y, hatch_layer_scales.y, 2.0);
	layers.z = hatch_layer(hatch_uv, hatch_angles_degrees.z, hatch_layer_scales.z, 3.0);
	layers.w = hatch_layer(hatch_uv, hatch_angles_degrees.w, hatch_layer_scales.w, 4.0);

	vec3 paper = paper_color;
	if (paper_grain > 0.0) {
		float grain = pencil_noise(FRAGCOORD.xy / pixel_scale * 0.01 * paper_grain_scale + boil);
		paper *= mix(1.0 - paper_grain * 0.5, 1.0 + paper_grain * 0.25, grain);
	}

	// Densest against the border and gone by edge_width_pixels inside it.
	float edge = edge_ink * smoothstep(-max(edge_width_pixels, 0.001), 0.0, border_distance);
	float tone = clamp(pow(clamp(fill_tone, 0.0, 1.0), tone_gamma) - edge, 0.0, 1.0);
	float coverage = pencil_hatch(layers, tone) * ink_strength;
	vec3 ink = mix(paper * 0.35, ink_color, ink_tint);
	vec3 color = mix(paper, ink, coverage);
	float alpha = (1.0 - smoothstep(-aa, aa, border_distance)) * paper_alpha;

	float line = 0.0;
	for (int i = 0; i < border_passes; i++) {
		float seed = border_seed + float(i) * 7.31;
		vec2 noise_uv = point * border_noise_scale + vec2(seed, boil * 0.37);
		float wander = (pencil_fbm(noise_uv) - 0.5) * 2.0 * border_wander_pixels;
		float pressure = pencil_noise(noise_uv * 2.3 + seed);
		float width = border_pixels * mix(1.0 - border_jitter, 1.0 + border_jitter, pressure);
		float stroke = 1.0 - smoothstep(0.0, aa, abs(border_distance + wander) - width * 0.5);
		float gap = pencil_noise(point * border_noise_scale * 8.0 + boil + seed);
		line = max(line, stroke * smoothstep(border_gaps, border_gaps + 0.25, gap));
	}
	color = mix(color, border_color, line);
	alpha = max(alpha, line);

	COLOR *= vec4(color, alpha);
}
