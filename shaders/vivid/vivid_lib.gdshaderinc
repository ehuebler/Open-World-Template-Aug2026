// Shared helpers for the vivid shader family: the planet frame every material
// reads, the colour wheel painted around that planet, and the procedural detail
// that keeps an untextured surface from reading as plastic.
//
// The planet frame arrives as global shader parameters rather than per-material
// uniforms, because the terrain, the props standing on it, the sky and the
// atmosphere shell all have to agree on where the planet is and how its colour
// wheel is turned. They are declared in project.godot's [shader_globals] and
// written by Planet; nothing else should write them.

// Planet centre in world space, and the sea-level radius in metres.
global uniform vec3 planet_center;
global uniform float planet_radius;
// Direction the sun's light travels, matching a DirectionalLight3D's -Z. So the
// direction *to* the sun is `-sun_direction`, and every shader here that wants a
// day/night term writes exactly that.
//
// A sky shader is the exception and must not use this: it gets LIGHT0_DIRECTION
// instead, which is the opposite sign — the engine hands sky shaders the vector
// pointing at the light so that `dot(EYEDIR, LIGHT0_DIRECTION)` peaks on the sun.
// Negating that one to "match" this one flips day and night across the planet.
global uniform vec3 sun_direction;

// Pole of the colour wheel: hue runs around this axis the way longitude does.
global uniform vec3 region_axis;
// Turns of the wheel per trip around the planet. Whole numbers only — half a
// turn meets itself on the far side as a hard seam instead of a gradient.
global uniform float region_turns;
// Rotates the whole wheel. Drifting it slowly moves the regions over the ground.
global uniform float region_phase;
// How far region boundaries wander off the meridians they would otherwise be.
global uniform float region_warp;
// Chroma of the wheel: 0 leaves the world its own colour, 1 is full spectrum.
global uniform float region_chroma;

// The polar cap. `frost_axis` is north in world space; the two cosines are the
// cap's outer and inner edges, written by Planet out of PlanetShape so the CPU
// and the GPU cannot disagree about where the arctic starts. Do not set these by
// hand: the values in project.godot are only what an editor preview sees before
// a Planet has published its own.
global uniform vec3 frost_axis;
global uniform float frost_edge;
global uniform float frost_full;

// The sea, as the four numbers everything looking through it needs. Global for the
// same reason the planet frame is: the bed, the underside of the surface, the sky
// and the weather all meet at a swimmer's horizon, and any two of them disagreeing
// about how clear the water is draws that horizon at two different distances. They
// were a uniform on two materials with a comment on each begging the other to be
// kept equal; this is that comment made structural. Written by PlanetWater.
//
// `murk_color` is the light the water scatters back — the colour a diver's whole
// view goes once there is more water in front of them than they can see through.
//
// `murk_visibility` is how far can be seen along the water, in metres, and it is
// sight and nothing else. It used to stand in for the light going *down* the
// column as well, and one number cannot do both: a bed is lit by a sky it can see
// all of and looked at along one line of it, so a column stays lit several times
// deeper than it stays clear. Splitting the two is what let this go from the 14 m
// they shared to a figure a swimmer can actually see by, without touching the
// ocean seen from the air — a bed there is still charged for both journeys, the
// way down through `murk_daylight` and the way back out through this.
//
// `murk_channels` is what each channel of the light survives, as a multiple of
// that visibility. Water is not a grey filter: red is gone within a few metres and
// blue outlasts it several times over, which is most of why anything photographed
// under water is blue — and, more to the point, it is what keeps a shape readable
// past the visibility. One rate for all three takes a whole picture to a flat
// panel of colour at one distance; three take the red out first and leave the
// slopes and the rock in the two that are left. Green is 1, so the middle channel
// is the visibility as written and every scalar reading of the murk is taken from
// green.
//
// `murk_daylight` is the depth the daylight in the water falls off by, in metres.
// A plain vec3 and not a colour, so that what the shader gets is linear and known
// to be: a `color` global is one more place a value can quietly pass through a
// gamma conversion or not. PlanetWater converts once, on the way in.
global uniform vec3 murk_color;
global uniform float murk_visibility;
global uniform vec3 murk_channels;
global uniform float murk_daylight;


// --- Hashes and noise -------------------------------------------------------
//
// Hoskins-style hashes rather than the usual sin(dot(...)) * 43758.0: terrain is
// sampled at world coordinates thousands of metres from the origin, and a large
// argument to sin loses its low bits on some drivers, which shows up as the
// noise going flat in patches far from the planet's centre.

float vivid_hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

vec3 vivid_hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

// Quintic interpolation, not the usual cubic. Cubic smoothstep has a kink in its
// second derivative at every cell boundary, and vivid_bump_normal takes the
// gradient of this field — which turns that kink into a visible lattice of
// metre-wide tiles across any surface it is used to bump.
float vivid_noise3(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n000 = vivid_hash13(cell);
	float n100 = vivid_hash13(cell + vec3(1.0, 0.0, 0.0));
	float n010 = vivid_hash13(cell + vec3(0.0, 1.0, 0.0));
	float n110 = vivid_hash13(cell + vec3(1.0, 1.0, 0.0));
	float n001 = vivid_hash13(cell + vec3(0.0, 0.0, 1.0));
	float n101 = vivid_hash13(cell + vec3(1.0, 0.0, 1.0));
	float n011 = vivid_hash13(cell + vec3(0.0, 1.0, 1.0));
	float n111 = vivid_hash13(cell + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

// Octave count is a compile-time constant everywhere it is called, so the loop
// unrolls; passing it in only keeps the callers honest about what they pay for.
float vivid_fbm3(vec3 p, int octaves) {
	float sum = 0.0;
	float amplitude = 0.5;
	float total = 0.0;
	for (int i = 0; i < octaves; i++) {
		sum += vivid_noise3(p) * amplitude;
		total += amplitude;
		// Swizzled as well as scaled: without turning the lattice between
		// octaves they all line up on the same axes and the sum keeps the grid
		// each one was built on.
		p = p.yzx * 2.02 + vec3(17.3, 5.7, 31.1);
		amplitude *= 0.5;
	}
	return sum / max(total, 0.0001);
}

// Sharp crests instead of soft lumps. Cliffs and cloud edges want this; ground
// tone does not.
float vivid_ridge3(vec3 p, int octaves) {
	float sum = 0.0;
	float amplitude = 0.5;
	float total = 0.0;
	for (int i = 0; i < octaves; i++) {
		float value = 1.0 - abs(vivid_noise3(p) * 2.0 - 1.0);
		sum += value * value * amplitude;
		total += amplitude;
		p = p * 2.11 + vec3(9.2, 23.7, 3.5);
		amplitude *= 0.5;
	}
	return sum / max(total, 0.0001);
}


// --- Colour -----------------------------------------------------------------

// A full turn of hue with no flat spots, from a cosine palette. Smoother than a
// hue-to-rgb conversion, which has corners where the channels clip and reads as
// six wedges rather than as a wheel.
vec3 vivid_spectrum(float t) {
	return 0.5 + 0.5 * cos(TAU * (t + vec3(0.0, 0.33, 0.67)));
}

// Pushes chroma without pushing brightness, so a saturated colour stays as
// bright as the grey it was mixed from and nothing clips on its way up.
vec3 vivid_saturate(vec3 color, float amount) {
	float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
	return max(mix(vec3(luma), color, amount), vec3(0.0));
}


// --- The planet frame -------------------------------------------------------

// Unit direction from the planet's centre, which is "up" anywhere on the ground.
vec3 vivid_up(vec3 world_position) {
	vec3 offset = world_position - planet_center;
	float distance_squared = dot(offset, offset);
	return distance_squared > 0.0001 ? offset * inversesqrt(distance_squared) : vec3(0.0, 1.0, 0.0);
}

// Metres above sea level. Negative under water, and negative inside the planet.
float vivid_altitude(vec3 world_position) {
	return length(world_position - planet_center) - planet_radius;
}

// Metres of the segment `from`..`to` that lie under the sea.
//
// This is the number a view of water is actually made of, and asking for it
// rather than for "is the eye submerged" is what lets the sea look like a body of
// water from outside it. A bed two metres down and the same bed sixty metres down
// are not the same sight, and a boolean cannot tell them apart: what hides the
// ground is the column of water in front of it, and that column is there whether
// the eye is in it or not.
//
// Altitude is taken to run linearly along the segment, which is exact enough over
// any distance a sea is deep and errs toward too little water rather than too
// much. A ray that leaves the water and comes back — over a sandbar, say — is
// counted as though it stayed out, for the same reason.
float vivid_sea_path(vec3 from, vec3 to) {
	float a = vivid_altitude(from);
	float b = vivid_altitude(to);
	float span = distance(from, to);
	if (a > 0.0) {
		return b >= 0.0 ? 0.0 : span * (-b / (a - b));
	}
	return b > 0.0 ? span * (a / (a - b)) : span;
}

// What is left of the surface's daylight this far under the sea, as a share of
// it. [param reach] is the depth it falls off by.
//
// Everything the deep looks like comes out of this one number, read from three
// places: the light landing on the bed, the light in the water standing between
// the bed and the eye, and the light in the wash that water becomes once it is
// thicker than can be seen through. All three reading the same falloff is the
// point — a bed lit like the shallows cannot then sit in water shaded like a
// trench, which is the shape of what made deep water one flat panel of colour.
//
// It is also, on its own, what gives a swimmer an up: the water overhead is lit
// by daylight from half their own depth away and the water below by daylight from
// the bed, so a view under the sea has a gradient in it before anything in the
// frame has a shape.
//
// The floor is not physics. It is the difference between a deep dive being dark
// and being a black screen with a HUD on it.
float vivid_daylight(float depth, float reach) {
	return mix(0.04, 1.0, exp(-max(depth, 0.0) / max(reach, 0.01)));
}

// Metres of sea a ray leaving [param from] along [param toward] crosses before it
// comes out the other side, and 0 if it started in the air.
//
// This is the number for everything *outside* the water seen from inside it, which
// is the sky and the weather. They need it and cannot get it from
// [method vivid_sea_path] because there is nothing at the far end of the ray to
// measure to — a sky fragment is a direction, not a place. Solved against the
// sea-level sphere instead, exactly, because unlike a bed a few metres off, the
// chord out of the water at a grazing angle is hundreds of metres long and the
// linear-altitude shortcut is nowhere near it.
//
// What it fixes is a band of unfogged sky along a swimmer's horizon. Rays a little
// under the horizontal leave the sea hundreds of metres out and never meet a bed —
// the sea floor is below the surface everywhere, so a ray that keeps rising
// relative to it never lands — and the sea's own disc is a cap around the viewer
// that cannot be made wide enough to cover them all. So the sky has to be drawn
// through its own water rather than hidden behind something.
float vivid_sea_chord(vec3 from, vec3 toward) {
	vec3 offset = from - planet_center;
	float outward = dot(offset, toward);
	float over = dot(offset, offset) - planet_radius * planet_radius;
	if (over >= 0.0) {
		return 0.0;
	}
	return -outward + sqrt(max(outward * outward - over, 0.0));
}

// What a length of sea does to whatever is behind it: how much of the light gets
// through, per channel, and the lit water that fills in the rest.
//
// [param depth] is how far under the surface the water doing the scattering is,
// and [param day] is how much daylight the surface over it is getting. Every
// surface that has water in front of it reads this, so the sea bed, the underside
// of the surface, the sky and the clouds all fade into the same wash at the same
// distance — which is the whole reason the numbers behind it are global.
void vivid_sea_veil(float path, float depth, float day, out vec3 kept, out vec3 wash) {
	kept = exp(-vec3(max(path, 0.0)) / (murk_visibility * murk_channels));
	wash = murk_color * vivid_daylight(depth, murk_daylight) * day;
}

// Where a point sits on the planet's colour wheel.
//   x  hue coordinate, 0..1 and wrapping, so any two neighbouring regions meet
//      in a gradient rather than at a seam
//   y  how strongly this ground answers the light, 0..1
//
// The wander is added to the angle and not to the finished hue on purpose: the
// hue stays a continuous function of a coordinate that meets itself all the way
// around, which is what keeps region_turns whole numbers seamless.
vec2 vivid_region(vec3 unit) {
	vec3 axis = normalize(region_axis);
	vec3 side = normalize(cross(axis, abs(axis.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 front = cross(axis, side);
	float longitude = atan(dot(unit, side), dot(unit, front)) / TAU;
	float latitude = asin(clamp(dot(unit, axis), -1.0, 1.0)) / PI;
	// Two octaves, not three. Regions are hundreds of kilometres across and this
	// runs per pixel on every surface in the game; the third octave moves the
	// boundary by metres and nobody has ever seen it.
	float wander = vivid_fbm3(unit * 2.6, 2) - 0.5;
	float hue = fract((longitude + wander * region_warp) * region_turns
		+ latitude * 0.5 + region_phase);
	// A second field decides which regions gleam, so brightness does not simply
	// track hue and the wheel reads as weather rather than as a paint chart.
	float intensity = smoothstep(0.18, 0.82, vivid_fbm3(unit * 1.7 + 31.4, 2));
	return vec2(hue, intensity);
}

// The light a region reflects, ready to multiply into a specular or rim term.
vec3 vivid_region_light(vec3 unit) {
	vec2 region = vivid_region(unit);
	vec3 hue = mix(vec3(1.0), vivid_spectrum(region.x), region_chroma);
	return hue * mix(0.45, 1.0, region.y);
}

// How arctic a direction on the sphere is: 0 outside the polar cap, 1 inside it,
// and a ramp across the edge. The twin of PlanetShape.frost(), reading the same
// two cosines out of the globals it publishes, so the ground the mesh is built
// from and the ground the shaders paint agree on where the ice stops.
//
// Takes a unit radial, as vivid_region does — pass it vivid_up(position).
float vivid_frost(vec3 unit) {
	return smoothstep(frost_edge, frost_full, dot(unit, normalize(frost_axis)));
}


// --- Water ------------------------------------------------------------------

// The net of light a rippling surface throws: bright filaments enclosing dark
// cells, the thing on the bottom of every swimming pool.
//
// Sampled at the point's own sea-level projection and not at the point, which is
// the whole reason this lives here rather than in one of the three shaders that
// use it. The web on the bed is then the *same* web as the one glittering on the
// surface five metres above it and the same one the shafts between them are lit
// by, without any of the three knowing the others exist.
//
// The filaments come free: the half-contour of a noise field is already a closed
// net of cells, so all that is left is to sharpen it. Time is the third axis
// rather than a drift, because a caustic net does not travel across the bed — it
// boils in place as the surface above it bends — and walking through the noise
// instead of across it is exactly that, for the same eight lookups.
float vivid_caustic(vec3 world_position, float scale, float speed) {
	vec3 up = vivid_up(world_position);
	vec3 at = (planet_center + up * planet_radius) * scale;
	float coarse = 1.0 - abs(vivid_noise3(at + up * (TIME * speed)) * 2.0 - 1.0);
	float fine = 1.0 - abs(vivid_noise3(at * 1.71 + up * (TIME * speed * 1.37)
		+ 23.1) * 2.0 - 1.0);
	// Overlaid, not multiplied. Two nets crossed leave bright dots where their
	// filaments happen to meet and nothing at all in between; laid over each
	// other they read as one net with more going on inside it.
	float web = max(coarse, fine * 0.82);
	// Sixth power. The filaments are the top few per cent of the field and
	// everything under them has to go properly dark, or the bed lifts evenly
	// instead of being netted and the effect reads as a brighter seabed.
	web *= web;
	return web * web * web;
}

// One planar wave: the gradient of its height in xyz and the height itself in w.
//
// Planar in three dimensions and then cut by the sphere, which on a ball this
// size gives crests that are near enough great circles — and costs no tangent
// frame, which is the one thing that cannot be built over a whole sphere without
// a seam somewhere.
vec4 vivid_wave(vec3 offset, vec3 heading, float number, float gain, float speed) {
	// Deep-water dispersion: a wave's speed goes as the root of its wavelength.
	// Worth the one sqrt, because it is what stops three summed sines from
	// travelling as a single rigid pattern sliding past.
	float phase = dot(offset, heading) * number - TIME * speed * sqrt(number) * 5.0;
	return vec4(heading * (cos(phase) * gain * number), sin(phase) * gain);
}

// Open-water swell: three waves crossing, as a height above sea level and the
// slope that goes with it. [param offset] is measured from the planet's centre.
void vivid_swell(vec3 offset, float wavelength, float speed,
		out float height, out vec3 slope) {
	float number = TAU / max(wavelength, 1.0);
	vec4 sum = vivid_wave(offset, normalize(vec3(1.0, 0.0, 0.36)), number, 1.0, speed)
		+ vivid_wave(offset, normalize(vec3(-0.44, 0.12, 1.0)), number * 1.63, 0.55, speed)
		+ vivid_wave(offset, normalize(vec3(0.66, -0.3, -0.69)), number * 2.41, 0.30, speed);
	height = sum.w / 1.85;
	slope = sum.xyz / 1.85;
}

// Shafts of sunlight in the water between the eye and whatever is behind it.
//
// Not a scattering integral. It samples the same net [method vivid_caustic]
// paints the bed with, at the place each step's own sun ray crossed the surface,
// and adds the samples up. That is the actual reason shafts exist — the column
// of water under a bright filament is lit the whole way down — and it costs a
// handful of lookups rather than a phase function.
//
// [param reach] bounds the march in metres, so a bed a kilometre off costs the
// same as one at arm's length; [param fade] is the depth the shafts give out at.
const int VIVID_SHAFT_STEPS = 6;

float vivid_sea_shafts(vec3 from, vec3 to, float scale, float speed,
		float reach, float fade) {
	vec3 ray = to - from;
	float span = length(ray);
	if (span < 0.5) {
		return 0.0;
	}
	vec3 heading = ray / span;
	vec3 sun = normalize(-sun_direction);
	// A stride measured in metres, rather than the span cut into a fixed number of
	// pieces. The samples then stand at the same distances along every ray in the
	// frame, and what they add up to is a set of sheets hanging in the water —
	// which is what a shaft is. Cutting the span instead keys the sample positions
	// to the depth of whatever is behind each pixel, so a bed seen at a grazing
	// angle got the net stamped onto it as flat translucent slabs with straight
	// edges wherever a sample crossed from one step to the next.
	//
	// It also means the shafts grow with the water in front of them rather than
	// being renormalised to it, so a swimmer looking along a kilometre of sea gets
	// more of them than one looking at a rock an arm away.
	float stride = reach / float(VIVID_SHAFT_STEPS);
	float along = stride * 0.5;
	float gathered = 0.0;
	for (int i = 0; i < VIVID_SHAFT_STEPS; i++) {
		// The step the water runs out inside is worth the part of it that fits.
		// Whole steps only would put the last one in at full strength the moment
		// the span reached it, which draws a contour line across the bed every
		// stride. Jittering the march start from the fragment instead — the other
		// obvious answer — makes the value differ between neighbouring pixels and
		// lays the whole sea over with white speckle.
		float weight = clamp((span - along) / stride + 0.5, 0.0, 1.0);
		if (weight <= 0.0) {
			break;
		}
		vec3 at = from + heading * along;
		float under = -vivid_altitude(at);
		if (under > 0.0) {
			// Back up the sun's own path to where this water was lit from. The
			// slant is what leans the shafts over as the sun drops; without it
			// they stand vertically whatever the time of day.
			float slant = max(dot(vivid_up(at), sun), 0.25);
			gathered += vivid_caustic(at + sun * (under / slant), scale, speed)
				* (1.0 - smoothstep(0.0, fade, under)) * weight;
		}
		along += stride;
	}
	return gathered / float(VIVID_SHAFT_STEPS);
}


// --- Surface detail ---------------------------------------------------------

// Blend weights for triplanar sampling. Sharpness above about 4 keeps the three
// projections from smearing across each other on a slope.
vec3 vivid_triplanar_weights(vec3 normal, float sharpness) {
	vec3 weights = pow(abs(normal), vec3(sharpness));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}

vec3 vivid_triplanar(sampler2D source, vec3 position, vec3 weights, float scale) {
	return texture(source, position.zy * scale).rgb * weights.x
		+ texture(source, position.xz * scale).rgb * weights.y
		+ texture(source, position.xy * scale).rgb * weights.z;
}

// Bends the normal along the slope of a noise field, which is what turns a flat
// wall into a surface that catches light unevenly. Sampled in world space and
// with no tangents, because procedural terrain chunks carry neither.
//
// [param scale] is cycles per metre; [param strength] is roughly the height of
// the bumps as a share of their spacing.
//
// Steepest tilt any bump is allowed to ask for, as a tangent — about twenty
// degrees. See where it is applied for what happens without it.
const float VIVID_BUMP_TILT = 0.38;

vec3 vivid_bump_normal(vec3 world_position, vec3 normal, float scale, float strength) {
	if (strength <= 0.0) {
		return normal;
	}
	vec3 tangent = normalize(cross(normal,
		abs(normal.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 bitangent = cross(normal, tangent);
	// Central differences over a quarter of a noise cell each way, which is the same
	// span as the half-cell forward difference this was and so needs no change to the
	// gain below.
	//
	// Forward differencing is what put a lattice of flat metre-wide tiles across
	// every surface this bumps. A half-cell step is not a derivative of the field,
	// it is the difference between this cell of it and the next one — near enough
	// constant inside a cell and stepping at every boundary — so the normal came out
	// piecewise constant on the noise lattice and the ground read as a plaid of
	// translucent slabs. It is the same failure the quintic in `vivid_noise3` was
	// chosen to avoid, reintroduced one function later by the way the field was
	// sampled. Centred and shorter, the estimate is a real gradient of a C2 field
	// and is continuous everywhere.
	float step_size = 0.25 / max(scale, 0.0001);
	vec3 along = tangent * step_size;
	vec3 across = bitangent * step_size;
	vec3 slope = tangent * (vivid_fbm3((world_position + along) * scale, 3)
			- vivid_fbm3((world_position - along) * scale, 3))
		+ bitangent * (vivid_fbm3((world_position + across) * scale, 3)
			- vivid_fbm3((world_position - across) * scale, 3));
	// The offset is the tangent of the tilt it asks for, and an unbounded one is
	// what turned a sea bed into a plaid. A field this sharp has patches where the
	// difference is several times its own average, and past a tilt of about one the
	// `normalize` stops leaning the surface normal and starts *replacing* it with
	// the field's own gradient direction — which barely turns inside a noise cell,
	// so those patches come out as flat facets a cell wide with hard creases
	// between them. Clamping the length rather than lowering the gain keeps the
	// texture everywhere the field is ordinary and only gives up the spikes, which
	// were never bumps so much as folds.
	float tilt = length(slope) * strength * 8.0;
	if (tilt <= 0.0) {
		return normal;
	}
	return normalize(normal - slope * (min(tilt, VIVID_BUMP_TILT) / length(slope)));
}

// Godot's fragment normals are view space, and everything here works in world
// space, so this is the only way back.
vec3 vivid_to_view(mat4 view_matrix, vec3 world_normal) {
	return normalize((view_matrix * vec4(world_normal, 0.0)).xyz);
}
