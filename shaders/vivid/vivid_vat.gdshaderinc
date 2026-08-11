// Shared vertex-animation-texture playback for instanced props.
//
// The Blender baker writes one normalized position delta per vertex per frame:
// texture X is the stable vertex id carried by UV2.x, texture Y is the frame.
// The texture itself stays nearest-filtered; interpolation is explicit here so
// adjacent vertices can never bleed into one another.

vec3 vivid_vat_decode(vec3 packed_delta, vec3 delta_minimum, vec3 delta_maximum) {
	return mix(delta_minimum, delta_maximum, packed_delta);
}

vec3 vivid_vat_delta(
		sampler2D positions,
		float vertex_u,
		float seconds,
		float phase,
		float speed,
		float frame_count,
		float frames_per_second,
		vec3 delta_minimum,
		vec3 delta_maximum) {
	float frames = max(frame_count, 1.0);
	float cursor = mod(seconds * frames_per_second * max(speed, 0.001)
		+ phase * frames, frames);
	float first = floor(cursor);
	float second = mod(first + 1.0, frames);
	float blend = fract(cursor);
	vec3 a = texture(positions, vec2(vertex_u, (first + 0.5) / frames)).rgb;
	vec3 b = texture(positions, vec2(vertex_u, (second + 0.5) / frames)).rgb;
	return vivid_vat_decode(mix(a, b, blend), delta_minimum, delta_maximum);
}
