// Puts the shafts god_rays.glsl gathered onto the colour buffer.
//
// A raster pass and not a second compute dispatch, and that is not a preference.
// The Mobile renderer's colour buffer carries no TEXTURE_USAGE_STORAGE_BIT, so
// nothing can write to it through an image2D; a fullscreen triangle drawn into it
// as a colour attachment with additive blending can. It runs at
// POST_TRANSPARENT, which is before Godot's glow and tonemapping, so the shafts
// bloom and roll off with the rest of the frame rather than being pasted flat
// over a finished image.
#[vertex]
#version 450

layout(location = 0) out vec2 uv;

void main() {
	// One triangle covering the screen, out of the vertex index alone. Two
	// corners of it are off screen and are clipped, which costs nothing and
	// saves binding a vertex buffer, a vertex format and an index buffer for
	// three known positions.
	vec2 corner = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
	uv = corner;
	gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;

// Linear filtering, which is the whole reason the shafts could be gathered at a
// quarter of the resolution: the upsample is what smooths the march's steps out.
layout(set = 0, binding = 0) uniform sampler2D rays_texture;

layout(push_constant, std430) uniform Params {
	// The sun's own colour in rgb, and how bright the shafts are in a.
	vec4 tint;
} params;

void main() {
	// One channel out of the ray pass and the colour applied here, rather than
	// three channels gathered. Shafts are the sun's light and are all the same
	// colour as each other, so carrying that colour through twenty-four taps per
	// pixel would be paying for it three times over.
	float rays = texture(rays_texture, uv).r;
	frag_color = vec4(params.tint.rgb * (rays * params.tint.a), 1.0);
}
