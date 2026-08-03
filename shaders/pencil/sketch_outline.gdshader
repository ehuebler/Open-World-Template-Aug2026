// Sketchy silhouette pass: back faces pushed along their normals, with the
// push amount jittered per vertex and the line dashed in the fragment stage.
//
// Chain two or three of these as next_pass materials with different `seed`
// values to get overlapping strokes instead of one clean outline. Meant to be
// used behind pencil_surface.gdshader.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled, fog_disabled;

#include "res://shaders/pencil/pencil_lib.gdshaderinc"

uniform vec3 outline_color : source_color = vec3(0.15, 0.12, 0.19);
uniform float width_pixels : hint_range(0.0, 16.0) = 2.5;
// Stroke thickness varies along the silhouette, as with changing hand pressure.
uniform float width_jitter : hint_range(0.0, 1.0) = 0.45;
// Sideways drift, in pixels, so stacked passes never trace the same path.
uniform float wander_pixels : hint_range(0.0, 8.0) = 1.5;
uniform float jitter_scale = 3.5;
uniform float redraw_fps : hint_range(0.0, 24.0) = 8.0;
// Gaps along the line. 0 draws an unbroken outline.
uniform float stroke_gaps : hint_range(0.0, 0.9) = 0.18;
uniform float gap_scale = 40.0;
uniform float seed = 0.0;

varying vec3 v_local_position;

void vertex() {
	// Model space, so the wobble rides along with the object instead of swimming
	// through world space as the object moves.
	v_local_position = VERTEX;

	// Fattening the silhouette during the shadow pass would only bleed shadow.
	// Degenerate normals (seams and pole vertices on some primitives) are left
	// alone, since dividing by their length flings the vertex across the screen.
	if (!IN_SHADOW_PASS && length(NORMAL) > 0.5) {
		float boil = pencil_boil(TIME, redraw_fps);
		float wobble_a = pencil_noise(VERTEX.xy * jitter_scale + vec2(boil * 0.7, seed * 13.0));
		float wobble_b = pencil_noise(VERTEX.zy * jitter_scale + vec2(seed * 5.0, boil * 0.5 + 3.0));
		float wobble_c = pencil_noise(VERTEX.xz * jitter_scale + vec2(boil * 0.3, seed * 29.0));

		// World size of one screen pixel at this vertex, so thickness stays
		// constant on screen. PROJECTION_MATRIX[1][1] is 1.0 / tan(fov_y * 0.5),
		// negated under Vulkan's flipped Y, hence the abs().
		float view_depth = -(VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).z;
		float pixel = 2.0 * max(view_depth, 0.001) / max(abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y, 0.001);
		// A model-space push of 1.0 travels this far in world space, which is how
		// the pass stays honest on scaled and non-uniformly scaled objects.
		float push_scale = max(length((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz), 0.0001);

		float width = width_pixels * pixel * mix(1.0 - width_jitter, 1.0 + width_jitter, wobble_a);
		VERTEX += NORMAL * (width / push_scale);
		VERTEX += (vec3(wobble_a, wobble_b, wobble_c) - vec3(0.5)) * wander_pixels * pixel * 2.0 / push_scale;
	}
}

void fragment() {
	float boil = pencil_boil(TIME, redraw_fps);
	float gap = pencil_noise(v_local_position.xy * gap_scale + boil) * 0.5
		+ pencil_noise(v_local_position.zy * gap_scale * 1.3 + boil + seed) * 0.5;

	ALBEDO = outline_color;
	// Scissored instead of blended, which keeps the pass in the opaque queue and
	// out of transparency sorting.
	ALPHA = smoothstep(stroke_gaps, stroke_gaps + 0.25, gap);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
