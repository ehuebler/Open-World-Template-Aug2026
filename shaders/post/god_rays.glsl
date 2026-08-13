// Sunbeams, from the depth buffer and nothing else.
//
// The whole effect is one observation: a pixel of sky is a pixel the sun's light
// reached, and a pixel of geometry is one it did not. So marching from a pixel
// toward the sun's place on screen and counting how much of that walk was sky
// gives how much light arrives along it — which is a shaft. No volume, no
// scattering integral, no shadow map: a radial blur of the depth buffer's own
// silhouette.
//
// Written to its own quarter-resolution single-channel image rather than into the
// colour buffer. The Mobile renderer does not set TEXTURE_USAGE_STORAGE_BIT on
// its render targets, so a compute shader cannot write to them at all; depth is
// read here through a sampler, which is allowed, and the raster pass in
// god_rays_composite.glsl is what puts the result on screen.
#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Full resolution, and read by sampler because that is the only legal way in.
// Nearest filtering on purpose: the test below is "is this sky", and a linearly
// filtered depth of a sky texel averaged with a wall texel is not half sky, it
// is a wall. Interpolating a binary occlusion test biases every silhouette one
// way. The quarter-resolution target and the bilinear upsample in the composite
// are where the softness comes from instead.
layout(set = 0, binding = 0) uniform sampler2D depth_texture;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D rays_image;

layout(push_constant, std430) uniform Params {
	// Size of the target in pixels, which is a quarter of the internal render
	// size on each axis.
	vec2 ray_size;
	// Where the sun is, in the same 0..1 screen UVs the depth texture is read
	// through. May be outside that range: a sun just off the edge of the screen
	// still throws shafts across it, and clamping it to the border would drag
	// them round to point at the corner instead.
	vec2 sun_uv;
	// Share of the distance to the sun that the march covers. Close to one,
	// because the light being gathered all lives within `halo` of the sun and a
	// march that stops short of it never reaches any: at 0.75 a pixel across the
	// screen finished a quarter of the way out and came back with nothing.
	float density;
	// What each step of the march is worth relative to the one before. This is
	// what makes a shaft fade along its length rather than being a hard-edged
	// wedge, and it is the only reason the count below can be as low as it is.
	float decay;
	float strength;
	// Distance from the sun, in UV, past which no shafts are drawn. Bounds the
	// effect to the part of the screen the sun is actually in.
	float reach;
	// Radius of the light itself, in screen heights.
	//
	// This is the one number that decides whether the pass draws shafts or fog,
	// and getting it wrong is not a matter of degree. What is being gathered has
	// to be *the sun*, not "sky": a march that treats every unoccluded sky pixel
	// as a light source finds a whole hemisphere of them, every pixel's walk
	// comes back nearly full, and the result is a flat wash over the entire frame
	// with a faint dent behind each obstacle. Weighting each step by how near the
	// sun it landed is what turns the same march into light arriving *from* one
	// place, so the effect brightens toward the sun, dies away from it, and is
	// cut wherever something stands on the line between.
	float halo;
	// Width over height of the render, so `halo` is a circle on screen rather
	// than an ellipse. UV distance is not isotropic and on a 16:9 frame the error
	// is nearly a factor of two, which reads as the shafts being squashed
	// vertically.
	float aspect;
	// Raw depths at which the pixel's own share of the shaft begins and finishes
	// coming in. `veil_near` is the nearer of the two and therefore the *larger*
	// number, depth being reversed here.
	//
	// What is being drawn is light scattered by air along the view ray, so how
	// much of it a pixel gets depends on how much air is in front of that pixel —
	// which is its distance. Without this the pass has no idea of distance and
	// brightens everything its march found sky beyond, including a wall an arm's
	// length away: the first run of this lit five test bars standing fourteen
	// metres from the camera as brightly as the sky behind them, which reads as
	// the geometry glowing rather than as light in the air.
	//
	// Both arrive already in raw depth, converted on the CPU through the camera's
	// own projection. Doing it here would mean either an inverse projection matrix
	// per pixel or hand-writing Godot's reverse-Z mapping from its near and far
	// planes, and that mapping has changed between Godot versions.
	float veil_near;
	float veil_far;
} params;

// Fixed, and low. The cost of this pass is exactly this number times the pixel
// count, so it is the one figure that decides whether the effect is affordable;
// at quarter resolution twenty-four taps come to a little over one full-screen
// texture read. Loop-bounded rather than distance-bounded so a pixel next to the
// sun and one across the screen from it cost the same, which keeps the frame
// time flat as the camera turns.
const int GOD_RAY_STEPS = 24;

void main() {
	ivec2 at = ivec2(gl_GlobalInvocationID.xy);
	ivec2 bounds = ivec2(params.ray_size);
	if (at.x >= bounds.x || at.y >= bounds.y) {
		return;
	}
	vec2 uv = (vec2(at) + 0.5) / params.ray_size;

	vec2 shape = vec2(params.aspect, 1.0);
	// How much air stands in front of this pixel, from its own depth. Sky reads
	// zero, which is past `veil_far`, so the sky keeps the whole shaft.
	float own = texture(depth_texture, uv).x;
	float veil = 1.0 - smoothstep(params.veil_far, params.veil_near, own);
	if (veil <= 0.0) {
		imageStore(rays_image, at, vec4(0.0));
		return;
	}
	// Nothing outside the sun's reach is drawn at all, and the march is skipped
	// for it rather than being computed and multiplied by zero. A hard bound
	// rather than a fade: the falloff is `halo`'s job, and two tapers stacked
	// would pull the shafts in twice.
	if (length((uv - params.sun_uv) * shape) > params.reach) {
		imageStore(rays_image, at, vec4(0.0));
		return;
	}

	vec2 stride = (params.sun_uv - uv) * (params.density / float(GOD_RAY_STEPS));
	float weight = 1.0;
	float gathered = 0.0;
	float total = 0.0;
	vec2 walk = uv;
	for (int i = 0; i < GOD_RAY_STEPS; i++) {
		walk += stride;
		// How much light there is to be had where this step landed. Squared, so
		// the light falls off from the sun faster than linearly and the shafts
		// have a bright root rather than reading as an even sheet.
		float lamp = 1.0 - smoothstep(0.0, params.halo,
			length((walk - params.sun_uv) * shape));
		lamp *= lamp;
		// Reverse Z: the far plane is zero, so a raw depth of exactly zero is a
		// pixel nothing was drawn into — sky. Everything else is geometry
		// standing in the way. The same convention vivid_water.gdshader reads
		// the depth buffer under, and getting it backwards draws shafts out of
		// the terrain and shadows across the sky.
		//
		// The clamp is on the read and not on the walk: a march that leaves the
		// screen should find the border texel rather than being folded back
		// inside, where it would sample geometry that is not on that ray.
		float raw = texture(depth_texture, clamp(walk, vec2(0.0), vec2(1.0))).x;
		gathered += (raw > 0.0 ? 0.0 : 1.0) * lamp * weight;
		total += weight;
		weight *= params.decay;
	}

	// Normalised by the weights actually used, so `decay` changes the shape of a
	// shaft without also changing how bright the effect is overall. Note that the
	// `lamp` term is deliberately left out of the divisor: what comes back is then
	// how much light this pixel receives rather than what share of the light on
	// its own path reached it, and the second of those is one everywhere the sky
	// is clear — which is the wash again.
	float rays = (gathered / max(total, 0.0001)) * params.strength * veil;
	imageStore(rays_image, at, vec4(rays, 0.0, 0.0, 1.0));
}
