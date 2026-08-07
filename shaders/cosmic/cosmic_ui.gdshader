// The menus: a rounded pane of deep space with a nebula drifting inside it and a
// lit rim around it. Sits behind a Control's own drawing (see AuroraSurface in
// ui/themes/aurora_surface.gd), so text and icons stay crisp on top.
//
// It replaced a coloured-pencil shader, and the two are opposites in the one way
// that matters here: the pencil drew everything with *strokes*, so every panel had
// a hard traced border, a hatched fill and a paper grain, and the whole UI read as
// something laid on top of the game. This draws nothing with an edge to it. The
// fill fades out into its own rim, the light comes from inside the pane, and the
// only hard boundary anywhere is the rounded rect's alpha — which is itself
// feathered over a pixel.
//
// `fill_tone` is what the states are drawn with, and it now *raises* light rather
// than pressing strokes in: 1.0 is at rest and a hover or a press lifts it, which
// is the same dial reading the opposite way round.
shader_type canvas_item;
render_mode blend_mix, unshaded;

group_uniforms Pane;
uniform vec3 fill_color : source_color = vec3(0.090, 0.075, 0.204);
// Panes are translucent so the starfield behind the menus is still faintly there,
// which is most of what stops a card reading as a lid over the game.
uniform float fill_alpha : hint_range(0.0, 1.0) = 1.0;
// Deepens the fill towards the bottom of the pane. The gradient is what gives a
// flat colour somewhere for the light to come from.
uniform float depth_shade : hint_range(0.0, 1.0) = 0.35;
uniform float fill_tone : hint_range(0.0, 2.0) = 1.0;
group_uniforms;

group_uniforms Shape;
// Every pixel measurement below is in viewport units, i.e. the size the project
// designs against, so a rim keeps its weight through both the canvas_items
// stretch and a hiDPI window.
uniform float reference_height = 720.0;
uniform float corner_radius = 18.0;
// Pixels of the rect kept clear on every side, so a rim that blooms outward is
// not clipped by the Control's own bounds.
uniform float inset_pixels = 0.0;
group_uniforms;

group_uniforms Nebula;
uniform vec3 nebula_color : source_color = vec3(0.435, 0.325, 0.839);
uniform vec3 nebula_deep : source_color = vec3(0.157, 0.360, 0.600);
uniform float nebula_strength : hint_range(0.0, 1.0) = 0.30;
// Cells per 100 px, in the pane's own space, so a wide card holds more cloud
// rather than a stretched copy of a small one's.
uniform float nebula_scale = 1.6;
uniform float nebula_drift = 0.012;
group_uniforms;

group_uniforms Stars;
uniform vec3 star_color : source_color = vec3(0.902, 0.933, 1.0);
uniform float star_density : hint_range(0.0, 1.0) = 0.35;
// Cells per 100 px. One star lives in each cell that wins the density roll.
uniform float star_scale = 3.4;
uniform float star_twinkle : hint_range(0.0, 1.0) = 0.5;
group_uniforms;

group_uniforms Rim;
uniform vec3 rim_color : source_color = vec3(0.545, 0.541, 0.898);
uniform float rim_strength : hint_range(0.0, 3.0) = 0.9;
// How far in from the edge the rim light reaches. Wide and soft is the whole
// look; anything under about 4 px reads as a drawn border again.
uniform float rim_width_pixels = 26.0;
// A thin bright line right on the edge, kept separate from the glow above so a
// pane can have one, the other, or both.
uniform float edge_line_pixels : hint_range(0.0, 6.0) = 1.4;
uniform float edge_line_strength : hint_range(0.0, 2.0) = 0.5;
group_uniforms;

// Value noise. Cheap, and smooth enough at these scales that nothing here needs
// gradient noise: a UI pane is a few hundred pixels and the cloud is a wash.
float cosmic_hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
}

float cosmic_noise(vec2 point) {
	vec2 cell = floor(point);
	vec2 within = fract(point);
	within = within * within * (3.0 - 2.0 * within);
	float a = cosmic_hash(cell);
	float b = cosmic_hash(cell + vec2(1.0, 0.0));
	float c = cosmic_hash(cell + vec2(0.0, 1.0));
	float d = cosmic_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, within.x), mix(c, d, within.x), within.y);
}

float cosmic_fbm(vec2 point) {
	float sum = 0.0;
	float weight = 0.5;
	for (int i = 0; i < 4; i++) {
		sum += cosmic_noise(point) * weight;
		point *= 2.03;
		weight *= 0.5;
	}
	return sum;
}

// Signed distance to the rounded rect, negative inside.
float rounded_rect_distance(vec2 point, vec2 half_size, float radius) {
	float limit = min(radius, min(half_size.x, half_size.y));
	vec2 q = abs(point) - half_size + limit;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - limit;
}

// Points of light on a jittered grid, one per cell that passes the density roll.
// Sized in cells rather than pixels so a star stays a star at any pane size.
float cosmic_stars(vec2 point, float time) {
	vec2 grid = point * 0.01 * star_scale;
	vec2 cell = floor(grid);
	vec2 within = fract(grid) - 0.5;
	float roll = cosmic_hash(cell + 3.7);
	if (roll > star_density) {
		return 0.0;
	}
	vec2 offset = vec2(cosmic_hash(cell + 11.3), cosmic_hash(cell + 27.1)) - 0.5;
	float distance_to_star = length(within - offset * 0.7);
	float star = smoothstep(0.16, 0.0, distance_to_star);
	// Each star keeps its own phase, so the field breathes instead of pulsing as
	// one. Slow on purpose: a UI that flickers is a UI nobody can read over.
	float phase = cosmic_hash(cell + 5.9) * 6.283;
	float pulse = mix(1.0, 0.45 + 0.55 * sin(time * 0.9 + phase), star_twinkle);
	return star * pulse;
}

void fragment() {
	// Screen pixels per viewport unit: 2.0 for a 1440p window on a 720p project.
	float pixel_scale = max((1.0 / SCREEN_PIXEL_SIZE.y) / max(reference_height, 1.0), 0.001);
	// UV runs 0..1 across the rect, so one screen pixel's worth of it is
	// fwidth(UV); inverting that recovers the rect size without a script feeding
	// sizes in on every resize.
	vec2 rect_pixels = 1.0 / max(fwidth(UV), vec2(0.000001)) / pixel_scale;
	float aa = 1.0 / pixel_scale;
	vec2 point = (UV - 0.5) * rect_pixels;
	vec2 half_size = max(rect_pixels * 0.5 - inset_pixels, vec2(0.5));
	float distance_to_edge = rounded_rect_distance(point, half_size, corner_radius);

	float tone = clamp(fill_tone, 0.0, 2.0);
	// Down the pane rather than out from its middle: a card is read top to
	// bottom, and a radial gradient puts its darkest part in the corners where
	// the rim light already is.
	vec3 pane = mix(fill_color * (1.0 - depth_shade), fill_color, 1.0 - UV.y * 0.85);

	if (nebula_strength > 0.0) {
		vec2 cloud_uv = point * 0.01 * nebula_scale;
		float drift = TIME * nebula_drift;
		// Two layers pulled in opposite directions, which is what keeps the cloud
		// from reading as one texture sliding behind a window.
		float low = cosmic_fbm(cloud_uv + vec2(drift, drift * 0.6));
		float high = cosmic_fbm(cloud_uv * 2.7 - vec2(drift * 1.4, drift));
		float cloud = clamp(low * 0.75 + high * 0.45 - 0.28, 0.0, 1.0);
		vec3 hue = mix(nebula_deep, nebula_color, clamp(high * 1.4, 0.0, 1.0));
		pane += hue * cloud * nebula_strength;
	}

	if (star_density > 0.0) {
		pane += star_color * cosmic_stars(point, TIME) * 0.9;
	}

	// Inward from the edge and gone by rim_width_pixels, squared so the falloff
	// reads as light rather than as a wide band of colour.
	float rim = smoothstep(-max(rim_width_pixels, 0.001), 0.0, distance_to_edge);
	pane += rim_color * rim * rim * rim_strength;

	// The bright hairline sitting on the boundary itself.
	float line = 1.0 - smoothstep(0.0, max(edge_line_pixels, aa),
		abs(distance_to_edge) - edge_line_pixels * 0.5);
	pane += rim_color * line * edge_line_strength;

	pane *= tone;

	float inside = 1.0 - smoothstep(-aa, aa, distance_to_edge);
	float alpha = max(inside * fill_alpha, line * edge_line_strength);
	COLOR *= vec4(pane, alpha);
}
