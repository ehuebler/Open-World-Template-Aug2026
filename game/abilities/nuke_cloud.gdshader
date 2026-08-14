shader_type spatial;

// A noisy, depth-writing smoke skin for the Nuke cloud.
//
// The cloud is assembled from overlapping low-poly billows. Plain alpha turns
// every billow into a visible dark circle; the alpha pre-pass and broad
// procedural breakup make those billows read as one torn mass instead.
render_mode blend_mix, depth_prepass_alpha, cull_back, diffuse_burley,
	specular_disabled;

uniform vec4 smoke_color : source_color = vec4(0.50, 0.42, 0.36, 1.0);
uniform vec4 hot_color : source_color = vec4(1.0, 0.34, 0.06, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 0.0;
uniform float heat : hint_range(0.0, 1.0) = 0.0;
uniform float phase = 0.0;

varying vec3 world_position;


float hash3(vec3 point) {
	point = fract(point * 0.1031);
	point += dot(point, point.yzx + 33.33);
	return fract((point.x + point.y) * point.z);
}


float value_noise(vec3 point) {
	vec3 cell = floor(point);
	vec3 share = fract(point);
	share = share * share * (3.0 - 2.0 * share);
	float n000 = hash3(cell);
	float n100 = hash3(cell + vec3(1.0, 0.0, 0.0));
	float n010 = hash3(cell + vec3(0.0, 1.0, 0.0));
	float n110 = hash3(cell + vec3(1.0, 1.0, 0.0));
	float n001 = hash3(cell + vec3(0.0, 0.0, 1.0));
	float n101 = hash3(cell + vec3(1.0, 0.0, 1.0));
	float n011 = hash3(cell + vec3(0.0, 1.0, 1.0));
	float n111 = hash3(cell + vec3(1.0, 1.0, 1.0));
	float low = mix(mix(n000, n100, share.x),
		mix(n010, n110, share.x), share.y);
	float high = mix(mix(n001, n101, share.x),
		mix(n011, n111, share.x), share.y);
	return mix(low, high, share.z);
}


float billow_noise(vec3 point) {
	float broad = value_noise(point);
	float middle = value_noise(point * 2.07 + vec3(7.1, 2.9, 5.3));
	float fine = value_noise(point * 4.13 + vec3(1.7, 9.2, 3.4));
	return broad * 0.58 + middle * 0.29 + fine * 0.13;
}


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	vec3 sample_at = world_position * 0.045
		+ vec3(phase, phase * 1.71, phase * 2.37);
	float noise = billow_noise(sample_at);
	float facing = max(dot(normalize(NORMAL), normalize(VIEW)), 0.0);
	float torn_edge = pow(1.0 - facing, 1.5);
	float density = smoothstep(0.30, 0.73, noise + torn_edge * 0.17);

	// Heat lives in the denser folds and drains upward into sooty brown. A small
	// amount of emission remains after it cools so the far side of the cloud is
	// not a featureless black disc against a bright sky.
	float live_heat = heat * smoothstep(0.25, 0.85, density);
	ALBEDO = mix(smoke_color.rgb, hot_color.rgb, live_heat * 0.72);
	EMISSION = smoke_color.rgb * 0.32
		+ hot_color.rgb * live_heat * 2.8;
	ROUGHNESS = 1.0;
	ALPHA = opacity * density;
	ALPHA_SCISSOR_THRESHOLD = 0.08;
}
