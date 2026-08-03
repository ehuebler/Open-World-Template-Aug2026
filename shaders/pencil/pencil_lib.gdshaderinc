// Shared helpers for the pencil/sketch shader family.
// Everything is procedural so the style works before any hatch textures exist.

float pencil_hash11(float x) {
	return fract(sin(x * 78.233 + 12.9898) * 43758.5453123);
}

float pencil_hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float pencil_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = pencil_hash21(cell);
	float b = pencil_hash21(cell + vec2(1.0, 0.0));
	float c = pencil_hash21(cell + vec2(0.0, 1.0));
	float d = pencil_hash21(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float pencil_fbm(vec2 p) {
	float sum = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 3; i++) {
		sum += pencil_noise(p) * amplitude;
		p *= 2.03;
		amplitude *= 0.5;
	}
	return sum / 0.875;
}

vec2 pencil_rotate(vec2 p, float angle) {
	float s = sin(angle);
	float c = cos(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Time quantized to a low frame rate. Jitter driven by this reads as a hand
// redrawing the frame rather than as per-pixel noise.
float pencil_boil(float time, float fps) {
	return fps <= 0.0 ? 0.0 : floor(time * fps);
}

// Triplanar-style projection without the three-way blend: hatching can change
// direction abruptly across an edge, which is what a hand would do anyway.
int pencil_dominant_axis(vec3 n) {
	vec3 a = abs(n);
	if (a.x >= a.y && a.x >= a.z) {
		return 0;
	}
	if (a.y >= a.z) {
		return 1;
	}
	return 2;
}

vec2 pencil_project(vec3 v, int axis) {
	if (axis == 0) {
		return v.zy;
	}
	if (axis == 1) {
		return v.xz;
	}
	return v.xy;
}

// One layer of pencil strokes. `uv` is measured in stroke spacings, so a
// distance of 1.0 is one stroke to the next. Returns ink coverage in 0..1.
float pencil_strokes(vec2 uv, float angle_degrees, float frequency, float thickness, float wobble, float breakup, float seed) {
	vec2 r = pencil_rotate(uv, radians(angle_degrees)) * frequency;
	// Warp across the stroke direction, at two scales: long bows plus small kinks.
	float warp = pencil_noise(vec2(r.y * 0.31, r.x * 0.07) + seed * 17.0) - 0.5;
	warp += (pencil_noise(vec2(r.y * 1.7, seed * 5.0)) - 0.5) * 0.4;
	float x = r.x + warp * wobble;
	float cell = floor(x);
	float across = abs(fract(x) - 0.5) * 2.0; // 0 on the stroke core, 1 between strokes
	float width = thickness * mix(0.6, 1.25, pencil_hash11(cell * 1.13 + seed * 31.0));
	// Widening the falloff by the pixel footprint lets distant strokes dissolve
	// into flat tone instead of aliasing into moire.
	float aa = clamp(fwidth(x) * 1.5, 0.002, 1.0);
	float ink = 1.0 - smoothstep(width - aa, width + aa, across);
	// Dash the stroke along its length and vary pressure from stroke to stroke.
	float along = pencil_noise(vec2(r.y * 0.45, cell * 3.7 + seed * 7.0));
	ink *= smoothstep(breakup, breakup + 0.3, along);
	ink *= mix(0.72, 1.0, pencil_hash11(cell * 2.7 + seed));
	return clamp(ink, 0.0, 1.0);
}

// Tonal art map compositing: each darker step switches on one more stroke layer.
// `tone` is 1.0 for full light (bare paper) and 0.0 for the deepest shadow.
float pencil_hatch(vec4 layers, float tone) {
	float t = clamp(tone, 0.0, 1.0) * 4.0;
	float ink = layers.x * (1.0 - smoothstep(3.0, 4.0, t));
	ink = max(ink, layers.y * (1.0 - smoothstep(2.0, 3.0, t)));
	ink = max(ink, layers.z * (1.0 - smoothstep(1.0, 2.0, t)));
	ink = max(ink, layers.w * (1.0 - smoothstep(0.0, 1.0, t)));
	return clamp(ink, 0.0, 1.0);
}

// Quantize 0..1 into flat bands with a soft edge, for posterized lighting.
float pencil_bands(float value, int band_count, float softness) {
	float bands = float(max(band_count, 1));
	float scaled = clamp(value, 0.0, 1.0) * bands;
	float index = floor(scaled);
	float edge = max(softness * bands, 0.0005);
	return clamp((index + smoothstep(0.5 - edge, 0.5 + edge, scaled - index)) / bands, 0.0, 1.0);
}
