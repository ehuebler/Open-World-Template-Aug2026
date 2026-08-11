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
// Turn of the celestial sphere around frost_axis, in radians. CelestialCycle
// writes it with the same phase used to orbit the DirectionalLight3D; the
// planet itself remains fixed.
global uniform float celestial_angle;

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

// Detail that lands on whatever is already high, and nowhere else.
//
// Every octave of an fBm is added everywhere, which is why a field of one reads
// as evenly rough: the same texture in the troughs as on the crests. Hetero
// terrain weighs each octave by the value accumulated under it, so a place that
// is already high keeps gaining detail and a place that is low stays smooth.
//
// That asymmetry is most of what open water looks like. The trough between two
// swells is glassy and the crest is where the chop is, and no sum of
// equally-weighted octaves will produce that — turn an fBm up far enough to
// roughen the crests and it roughens the troughs with them.
//
// [param offset] lifts the field before it is used as its own weight. At zero
// the low ground multiplies every later octave by nothing and the field goes
// dead flat between crests; around three quarters the troughs keep a little
// texture and the crests still carry most of it.
//
// [param drift] is added to each octave in turn rather than to the field as a
// whole, so the fine detail travels further per unit of it than the coarse
// does. Sliding every octave together moves one rigid pattern across the
// surface, and the eye reads that as a texture being dragged rather than as
// water moving.
float vivid_hetero3(vec3 p, int octaves, float offset, vec3 drift) {
	float value = vivid_noise3(p + drift) + offset;
	float amplitude = 0.5;
	float total = 1.0;
	for (int i = 1; i < octaves; i++) {
		// Same swizzle-and-scale between octaves as `vivid_fbm3`, for the same
		// reason written there.
		p = p.yzx * 2.02 + vec3(17.3, 5.7, 31.1);
		float layer = (vivid_noise3(p + drift * float(i + 1)) + offset) * amplitude;
		// The weight, and the whole of the difference from an fBm: an octave is
		// worth what the field under it is worth. Clamped because the running
		// value can pass one, and an unclamped weight compounds into spikes
		// that the gradient below turns into creases.
		value += clamp(value, 0.0, 1.0) * layer;
		total += amplitude;
		amplitude *= 0.5;
	}
	// Back to roughly nought-to-one, so this can be swapped for `vivid_fbm3`
	// without every strength that reads it having to be retuned.
	return value / max(total * (1.0 + offset), 0.0001);
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

// A tangent-space normal out of the two channels it is stored in, leant over by
// [param strength]. Z is rebuilt rather than stored, because it is never
// negative and the other two already determine it.
vec3 vivid_unpack_normal(vec2 stored, float strength) {
	vec2 lean = (stored * 2.0 - 1.0) * strength;
	return vec3(lean, sqrt(max(1.0 - dot(lean, lean), 0.0)));
}

// One ground material, read at one point, projected from the two world axes the
// surface faces most.
//
// A sphere has no usable texture coordinates. A seamless tangent frame cannot be
// laid over one at all, which is why everything on this planet is projected from
// world space instead. Triplanar is the usual way to do that — read the texture
// once down each axis and blend by how squarely the surface faces each — and the
// third read is nearly always waste: ground faces one axis strongly, a second
// weakly and the third hardly at all, and that last one is paid for in full and
// then multiplied by a weight near nothing.
//
// Dropping it is safe because of the rescale below. The weakest component of a
// unit direction is at most 1/sqrt(3), which happens on the diagonal where all
// three are equal, so a weight that maps 1/sqrt(3) to zero has *already* fallen
// to zero by the time an axis becomes the weakest one. The projection being
// dropped is always worth nothing at the moment it is dropped, and nothing swaps
// visibly as the surface turns.
//
// Both packed maps are read together because the caller always wants both and
// they share the choice of axes: four taps and one set of comparisons, rather
// than two functions that each work out the same thing.
//
// The gradients are the caller's to supply and must be taken outside any branch.
// Which axes get picked varies from pixel to pixel, so a `dFdx` in here would be
// differencing neighbours that went the other way through it and mip selection
// would come back as noise down every diagonal. Pass `dFdx` and `dFdy` of the
// same scaled position handed in as [param position].
//
// [param leaning] is where the bumps point, in world space, unnormalised and
// with the geometry's own normal already folded in — so two materials' worth can
// be added together before anything is normalised.
//
// The weakest weight either projection can be worth, which is the diagonal.
const float VIVID_BIPLANAR_FLOOR = 0.5773502692;

// --- Breaking the repeat out of a tiled texture ------------------------------
//
// A photograph tiled every metre and a half draws a grid across a hillside
// however seamless its edges are. Healing the joins does not help: what the eye
// finds is the *features* coming back on a lattice — the same pebble every
// 1.7 m in both directions — and no amount of work on the border changes where
// the middle of the tile turns up.
//
// So the lattice is stopped from existing. The ground is cut into cells, each
// cell reads the texture from its own hashed offset, and the three cells that
// cover a point are weighed together. Two patches of ground are then never the
// same patch and there is no direction in which anything repeats.
//
// Three reads instead of one is the whole price. The gradients are untouched —
// sliding a texture coordinate does not change how fast it moves — so mip
// selection is exactly what it was, and nothing else in the function changes.
//
// The idea is Inigo Quilez's note on texture repetition, which is Heitz and
// Neyret's stochastic tiling with the histogram-preserving half left out. That
// half is not missed here: these maps are light and shade multiplied into a
// biome colour rather than colour in their own right, so slightly flatter
// contrast in the narrow bands where two cells meet is invisible.

// Shears the square lattice so one family of its edges runs off-axis. Kept to
// halves rather than the equilateral 1/sqrt(3), because the caller wraps its
// coordinate on a whole number of repeats and an irrational shear would put a
// step in the cell indices where that wrap happens.
const mat2 VIVID_SCATTER_SKEW = mat2(vec2(1.0, 0.0), vec2(-0.5, 1.0));

vec2 vivid_scatter_offset(vec2 cell) {
	return fract(sin(vec2(dot(cell, vec2(127.1, 311.7)),
		dot(cell, vec2(269.5, 183.3)))) * 43758.5453);
}

// A turn for one cell, as the matrix that takes a surface coordinate into that
// cell's copy of the texture.
//
// Sliding the texture, which is all the offset above does, hides where a repeat
// begins but not which way it faces. Everything directional in a photographed
// ground — the lie of grass, the grain of rock, the drift lines in sand — comes
// out of every cell pointing the same way, and a whole hillside combed in one
// direction is a pattern the eye finds as readily as a grid. Turning each cell
// is what removes it.
//
// [param amount] scales the angle rather than fading the matrix towards the
// identity, so a partial setting is a gentler turn and not a blend of two.
mat2 vivid_scatter_turn(vec2 cell, float amount) {
	float angle = fract(sin(dot(cell, vec2(419.2, 371.9))) * 29943.437)
		* 6.28318530718 * amount;
	float across = cos(angle);
	float along = sin(angle);
	return mat2(vec2(across, along), vec2(-along, across));
}

// Blends several readings of the same ground by which of them stands highest,
// rather than by how much of each the lattice says is there.
//
// This is the height blending of terrain splatting, and it is the answer to a
// problem the weights alone cannot solve. Averaging two photographs of ground
// is not a picture of ground: it is a picture of neither, flatter and greyer
// than both, so wherever a blend is wide it reads as a smear and wherever it is
// narrow it reads as an edge. There is no width that reads as ground.
//
// Height blending steps outside that. Each reading brings its own relief — the
// ambient occlusion channel, which is dark in the crevices and bright on the
// tops, and so is a height map already — and the blend is decided per pixel by
// which reading is standing proudest there. Where two readings meet, one's
// pebbles push up through the other's sand instead of both going half
// transparent. The handover is then shaped like the ground rather than like the
// lattice, and the lattice stops being visible however wide the band is made.
//
// [param authority] is how far a reading's own relief may move it up or down the
// order, in the same units the weights are in. It has to stay well under one:
// the weights must remain able to say that a surface is simply not present here,
// or a texture with no weight at all will still show wherever it happens to
// stand tall. Everything within half of it of the top is blended, which is what
// keeps the handover from being a hard cut.
//
// The two obvious ways of combining a weight with a height are both wrong, and
// each fails at a different end. Multiplying lets the weights dominate so
// completely that the heights never decide anything and the blend stays a
// smear. Adding them as equals — which is how the technique is usually written
// up — lets a surface with a weight of nothing win a pixel outright on the
// strength of its relief, so material appears where it was never painted.
// Adding a deliberately small share of the height is the version that does what
// it is supposed to.
vec3 vivid_height_weights(vec3 heights, vec3 weights, float authority) {
	vec3 raised = weights + heights * authority;
	float top = max(max(raised.x, raised.y), raised.z) - authority * 0.5;
	vec3 keep = max(raised - top, vec3(0.0));
	return keep / max(keep.x + keep.y + keep.z, 0.0001);
}


// The same, for two surfaces, returning how far to go towards the second.
float vivid_height_toward(float height_a, float height_b, float toward_b,
		float authority) {
	float a = (1.0 - toward_b) + height_a * authority;
	float b = toward_b + height_b * authority;
	float top = max(a, b) - authority * 0.5;
	float keep_a = max(a - top, 0.0);
	float keep_b = max(b - top, 0.0);
	return keep_b / max(keep_a + keep_b, 0.0001);
}


// The three cells covering a point, and how much of each it stands on. A
// sheared square split along its diagonal is a triangle, and a triangle needs
// three corners where a square would need four reads.
//
// [param cell] is the size of one cell in texture repeats. It wants to divide
// the caller's wrap evenly — see the wrap in vivid_ground_material — so powers
// of two are the safe settings.
//
// [param softness] raises the barycentric weights to a power: one leaves the
// blend spread right across the cell, and larger numbers pull it into a narrow
// band at the edges. This used to be a fixed cube, because a spread blend was a
// wash of two readings and only a narrow one looked like ground. With the
// heights deciding the handover that is no longer true, and the wide setting is
// now the good one: it is what stops the triangles being findable.
vec3 vivid_scatter_cells(vec2 uv, float cell, float softness, out vec2 first,
		out vec2 second, out vec2 third) {
	vec2 skewed = VIVID_SCATTER_SKEW * (uv / cell);
	vec2 base = floor(skewed);
	vec2 into = fract(skewed);
	vec3 weights;
	if (into.x + into.y < 1.0) {
		first = base;
		second = base + vec2(1.0, 0.0);
		third = base + vec2(0.0, 1.0);
		weights = vec3(1.0 - into.x - into.y, into.x, into.y);
	} else {
		first = base + vec2(1.0, 1.0);
		second = base + vec2(1.0, 0.0);
		third = base + vec2(0.0, 1.0);
		weights = vec3(into.x + into.y - 1.0, 1.0 - into.y, 1.0 - into.x);
	}
	weights = pow(max(weights, vec3(0.0)), vec3(softness));
	return weights / max(weights.x + weights.y + weights.z, 0.0001);
}

// One cell's read. The gradients are turned with the coordinate: they describe
// how fast the sample moves across the texture, so leaving them behind would
// choose the mip for a footprint the read no longer has, and an anisotropic
// footprint would be stretched along the wrong axis.
vec4 vivid_scatter_tap(sampler2DArray maps, vec2 uv, float layer,
		vec2 gradient_x, vec2 gradient_y, float strength, mat2 turn, vec2 cell) {
	return textureGrad(maps,
		vec3(turn * uv + vivid_scatter_offset(cell) * strength, layer),
		turn * gradient_x, turn * gradient_y);
}

// One projection's worth of scattered ground: colour and surface, read through
// the same three cells and blended by the same three weights.
//
// The two maps are taken together rather than in separate passes because the
// weights are no longer known before the reads. Height blending decides them
// from the occlusion the colour map comes back with, and the surface has to be
// combined the same way or the relief would belong to a different arrangement
// of cells than the colour laid over it.
//
// The surface map's red and green are a direction rather than a measurement, so
// they need turning back before they can be averaged. A normal map states which
// way the relief leans in the texture's own frame; read through a turned
// coordinate that frame is turned too, so the lean has to come back the other
// way before it means anything about this ground. Left alone, every cell lights
// as though the sun had moved for it, and the cells reappear as patches of
// shading exactly where the turning was meant to hide them. The transpose is
// the inverse for a rotation, and it is applied in the packed zero-to-one space
// the map stores so the unpack downstream is left alone.
void vivid_scatter_pair(sampler2DArray albedo_maps, sampler2DArray surface_maps,
		vec2 uv, float layer, vec2 dx, vec2 dy, vec2 bx, vec2 by,
		float strength, float spin, float cell, float softness, float depth,
		out vec4 albedo, out vec4 surface) {
	vec2 one, two, three;
	vec3 weights = vivid_scatter_cells(uv, cell, softness, one, two, three);
	mat2 turn_one = vivid_scatter_turn(one, spin);
	mat2 turn_two = vivid_scatter_turn(two, spin);
	mat2 turn_three = vivid_scatter_turn(three, spin);

	vec4 colour_one = vivid_scatter_tap(albedo_maps, uv, layer, dx, dy,
		strength, turn_one, one);
	vec4 colour_two = vivid_scatter_tap(albedo_maps, uv, layer, dx, dy,
		strength, turn_two, two);
	vec4 colour_three = vivid_scatter_tap(albedo_maps, uv, layer, dx, dy,
		strength, turn_three, three);
	if (depth > 0.0) {
		weights = vivid_height_weights(
			vec3(colour_one.a, colour_two.a, colour_three.a), weights, depth);
	}
	albedo = colour_one * weights.x + colour_two * weights.y
		+ colour_three * weights.z;

	vec4 relief_one = vivid_scatter_tap(surface_maps, uv, layer, bx, by,
		strength, turn_one, one);
	vec4 relief_two = vivid_scatter_tap(surface_maps, uv, layer, bx, by,
		strength, turn_two, two);
	vec4 relief_three = vivid_scatter_tap(surface_maps, uv, layer, bx, by,
		strength, turn_three, three);
	relief_one.rg = (transpose(turn_one) * (relief_one.rg * 2.0 - 1.0))
		* 0.5 + 0.5;
	relief_two.rg = (transpose(turn_two) * (relief_two.rg * 2.0 - 1.0))
		* 0.5 + 0.5;
	relief_three.rg = (transpose(turn_three) * (relief_three.rg * 2.0 - 1.0))
		* 0.5 + 0.5;
	surface = relief_one * weights.x + relief_two * weights.y
		+ relief_three * weights.z;
}

// Pixel footprint, as a share of the span each fade is measured against, at
// which that fade begins. Both of the fades below run from here to one.
//
// A fifth is not a guess. A detail is resolved while a pixel is smaller than
// it, half-resolved as they match, and a lottery once the pixel is bigger; the
// interesting part of that is all inside the last octave, so the fade starts
// while the pixel is still comfortably the smaller of the two and is finished
// by the time they meet.
const float VIVID_DETAIL_ONSET = 0.2;

// Pixel footprint, in cells of whatever field is being faded, past which that
// field is not resolved at all. Used by callers with their own procedural
// detail; the ground's two texture fades are passed in, because they are
// measured in texture repeats and only the caller knows how big one is.
// Tightening this to half a cell, and then to an eighth, was measured on the
// procedural relief it governs and moved nothing at any setting. What that
// relief contributes turns out to be near the eye, where a pixel is a small
// fraction of a bump and this fade is correctly leaving it alone.
const float VIVID_DETAIL_KEEP = 0.25;
const float VIVID_DETAIL_GONE = 1.0;

// [param detail_gone] is a pixel footprint in texture repeats: where the map's
// own relief stops being read at all. See the normal fade below.
//
// [param spin] is how far each scatter cell is allowed to turn its copy of the
// texture, as a share of a full circle. One is the useful setting and zero
// leaves the scatter sliding the texture without ever facing it differently.
//
// [param cell], [param softness] and [param depth] size the scatter lattice,
// spread its blend across the cell, and set how much of that blend the heights
// are allowed to decide. See vivid_scatter_cells and vivid_height_weights.
//
// [param bump_footprint] widens the filter used for the surface map alone,
// leaving the colour sharp. Colour and relief are not equally fragile and there
// is no reason to filter them together. A photographed albedo at one texel to
// the pixel is a picture of grass; the same texel count of normal map is a
// field of directions multiplied by a light, and every one of them that lands
// differently from one frame to the next is a pixel that jumps. Measured on the
// open lawn the normal map was seventy per cent of everything that moved when
// the eye shifted two millimetres, and the colour under it was almost none of
// it. So the colour is read at the pixel and the relief is read over several,
// which is the whole trade: all of the detail, none of the sparkle.
void vivid_ground_material(sampler2DArray albedo_maps, sampler2DArray surface_maps,
		float layer, vec3 position, vec3 gradient_x, vec3 gradient_y,
		vec3 normal, float sharpness, float bump, float scatter, float spin,
		float cell, float softness, float depth,
		float detail_gone, float bump_footprint,
		out vec4 albedo, out float roughness, out vec3 leaning) {
	// The coordinate is brought near the origin before it becomes a texture
	// coordinate. World positions here run out to the planet's radius, and a
	// float that large has steps of about a millimetre left in it — enough to
	// quantise a texture repeating every couple of metres into visible stairs.
	// Whole repeats are taken off, so the texel sampled is exactly the one that
	// would have been sampled anyway.
	vec3 at = position - floor(position * 0.015625 + 0.5) * 64.0;
	vec3 facing = abs(normal);

	// Where each of the two kept projections reads from, and how the two channels
	// of the normal it finds there land in world space.
	vec2 uv_a, uv_b, dx_a, dx_b, dy_a, dy_b;
	// The whiteout blend, as three directions per projection: the tangent's X
	// runs along `along`, its Y along `across`, and what is left of it stands up
	// the projection's own axis — which is `up`, and is the geometric normal's
	// component along that axis rather than a unit vector.
	vec3 along_a, across_a, up_a, along_b, across_b, up_b;
	vec2 share;
	// Spelt out as three cases rather than indexed by axis. A dynamic index into
	// a vector is not something every driver compiles well, and each case has to
	// name its own swizzles anyway.
	if (facing.x <= facing.y && facing.x <= facing.z) {
		// Facing X least, so project down Y and Z.
		uv_a = at.xz; dx_a = gradient_x.xz; dy_a = gradient_y.xz;
		along_a = vec3(1.0, 0.0, 0.0); across_a = vec3(0.0, 0.0, 1.0);
		up_a = vec3(0.0, normal.y, 0.0);
		uv_b = at.xy; dx_b = gradient_x.xy; dy_b = gradient_y.xy;
		along_b = vec3(1.0, 0.0, 0.0); across_b = vec3(0.0, 1.0, 0.0);
		up_b = vec3(0.0, 0.0, normal.z);
		share = vec2(facing.y, facing.z);
	} else if (facing.y <= facing.z) {
		uv_a = at.zy; dx_a = gradient_x.zy; dy_a = gradient_y.zy;
		along_a = vec3(0.0, 0.0, 1.0); across_a = vec3(0.0, 1.0, 0.0);
		up_a = vec3(normal.x, 0.0, 0.0);
		uv_b = at.xy; dx_b = gradient_x.xy; dy_b = gradient_y.xy;
		along_b = vec3(1.0, 0.0, 0.0); across_b = vec3(0.0, 1.0, 0.0);
		up_b = vec3(0.0, 0.0, normal.z);
		share = vec2(facing.x, facing.z);
	} else {
		uv_a = at.zy; dx_a = gradient_x.zy; dy_a = gradient_y.zy;
		along_a = vec3(0.0, 0.0, 1.0); across_a = vec3(0.0, 1.0, 0.0);
		up_a = vec3(normal.x, 0.0, 0.0);
		uv_b = at.xz; dx_b = gradient_x.xz; dy_b = gradient_y.xz;
		along_b = vec3(1.0, 0.0, 0.0); across_b = vec3(0.0, 0.0, 1.0);
		up_b = vec3(0.0, normal.y, 0.0);
		share = vec2(facing.x, facing.y);
	}

	// The floor added after the power is what keeps the diagonal from being
	// nought over nought: there both projections rescale to zero, and there they
	// are also worth exactly the same, so an even split is the right answer
	// rather than a patch over a hole.
	share = clamp((share - VIVID_BIPLANAR_FLOOR) / (1.0 - VIVID_BIPLANAR_FLOOR), 0.0, 1.0);
	share = pow(share, vec2(sharpness)) + 0.00001;
	float blend = share.y / (share.x + share.y);

	// `textureGrad` is what makes reading here legal after a branch that not
	// every pixel took the same way: with the gradients given explicitly, mip
	// selection no longer depends on what the neighbours did.
	//
	// The branch below is on a uniform, so every pixel in the draw takes the
	// same side of it and it costs nothing: turning the scatter off is a real
	// way back to one read per projection if the extra ones ever hurt.
	// One footprint per projection, in texture repeats, and the two fades that
	// are driven off it. Taken before the reads because the scatter needs its
	// one to choose how hard to weight them.
	float span_a = max(length(dx_a), length(dy_a));
	float span_b = max(length(dx_b), length(dy_b));
	// The wider read, for the surface map only.
	vec2 bx_a = dx_a * bump_footprint;
	vec2 by_a = dy_a * bump_footprint;
	vec2 bx_b = dx_b * bump_footprint;
	vec2 by_b = dy_b * bump_footprint;

	vec4 albedo_a, albedo_b, surface_a, surface_b;
	if (scatter > 0.0) {
		vivid_scatter_pair(albedo_maps, surface_maps, uv_a, layer, dx_a, dy_a,
			bx_a, by_a, scatter, spin, cell, softness, depth,
			albedo_a, surface_a);
		vivid_scatter_pair(albedo_maps, surface_maps, uv_b, layer, dx_b, dy_b,
			bx_b, by_b, scatter, spin, cell, softness, depth,
			albedo_b, surface_b);
	} else {
		albedo_a = textureGrad(albedo_maps, vec3(uv_a, layer), dx_a, dy_a);
		albedo_b = textureGrad(albedo_maps, vec3(uv_b, layer), dx_b, dy_b);
		surface_a = textureGrad(surface_maps, vec3(uv_a, layer), bx_a, by_a);
		surface_b = textureGrad(surface_maps, vec3(uv_b, layer), bx_b, by_b);
	}

	vec3 tangent_a = vivid_unpack_normal(surface_a.rg, bump);
	vec3 tangent_b = vivid_unpack_normal(surface_b.rg, bump);
	// How much of one texture repeat a single pixel covers, per projection.
	//
	// A normal map only says anything while a pixel is smaller than the grain
	// in it. Past that the mip chain hands back the average of many texels, and
	// the average of a normal map is not a flat surface: it is a short vector
	// that the unpack and the normalise below stretch straight back out to full
	// tilt, pointing wherever the averaging happened to leave it. So distant
	// ground keeps full-strength relief made of essentially random directions,
	// and a millimetre of camera movement re-rolls it — which is the sparkle.
	//
	// Colour needs none of this, which is why it is easy to miss: mipmapping an
	// albedo really does converge on its mean. Only the normals have to be
	// given up by hand, and this is where.
	//
	// The span this is measured against is the grain in the map, not the repeat
	// the grain sits in — a texel or two of a photographed surface, which is
	// millimetres. Written against the repeat instead, as it was, the fade only
	// finished a metre and a half out into a pixel's footprint and every one of
	// the tens of metres before that kept full-strength relief it could no
	// longer resolve.
	// Against the widened span, because that is the one the relief was actually
	// read at.
	float keep_a = 1.0 - smoothstep(detail_gone * VIVID_DETAIL_ONSET,
		detail_gone, span_a * bump_footprint);
	float keep_b = 1.0 - smoothstep(detail_gone * VIVID_DETAIL_ONSET,
		detail_gone, span_b * bump_footprint);
	tangent_a = mix(vec3(0.0, 0.0, 1.0), tangent_a, keep_a);
	tangent_b = mix(vec3(0.0, 0.0, 1.0), tangent_b, keep_b);
	// Written as a perturbation of the ground rather than a normal in its own
	// right, which is what lets two of them be averaged. The `- 1.0` is the part
	// worth reading twice: a flat patch of normal map stands straight up with a Z
	// of one, and has to come back out of here having left the geometry exactly
	// as it found it.
	vec3 lean_a = along_a * tangent_a.x + across_a * tangent_a.y + up_a * (tangent_a.z - 1.0);
	vec3 lean_b = along_b * tangent_b.x + across_b * tangent_b.y + up_b * (tangent_b.z - 1.0);

	albedo = mix(albedo_a, albedo_b, blend);
	roughness = mix(surface_a.b, surface_b.b, blend);
	leaning = normal + mix(lean_a, lean_b, blend);
}

// Bends the normal along the slope of a noise field, which is what turns a flat
// wall into a surface that catches light unevenly. Sampled in world space and
// with no tangents, because procedural terrain chunks carry neither.
//
// [param scale] is cycles per metre; [param strength] is roughly the height of
// the bumps as a share of their spacing.
//
// Ceiling on the tilt any bump may ask for, as a tangent — about twenty
// degrees. Approached and never reached; see where it is applied for what
// happens without it, and for why it is approached rather than clamped to.
const float VIVID_BUMP_TILT = 0.38;

// The same field as `vivid_fbm3`, with the octaves a pixel cannot resolve left
// out of it.
//
// An fBm read through a pixel wider than its finest octave is a lottery: the
// answer is whichever part of that octave the one sample landed on, and next
// frame, from a hand's breadth further along, it lands somewhere else. Fading
// each octave out as the pixel grows past it is what a mipmap does for a
// texture and the argument is the same — detail too fine to be resolved is not
// detail, it is noise with a plausible spectrum.
//
// This is a gentler instrument than fading the whole field at once, and the
// difference is the reason it exists. One fade over the sum takes the coarse
// swells away at the same distance as the fine grain, so a ground that shimmers
// at forty metres has to be made flat at forty metres to stop it. Per octave,
// the grain goes when it stops being resolvable and the swells stay until they
// do, which is much further out.
//
// Normalised by the octaves it kept rather than by all of them, so what
// survives keeps its full contrast instead of the field sinking toward flat as
// the eye backs away.
//
// [param footprint] is the width of one pixel in cells of the first octave.
float vivid_fbm3_seen(vec3 p, int octaves, float footprint) {
	float sum = 0.0;
	float amplitude = 0.5;
	float total = 0.0;
	float span = footprint;
	for (int i = 0; i < octaves; i++) {
		float keep = 1.0 - smoothstep(VIVID_DETAIL_KEEP, VIVID_DETAIL_GONE, span);
		if (keep > 0.0) {
			sum += vivid_noise3(p) * amplitude * keep;
			total += amplitude * keep;
		}
		// Same swizzle-and-scale between octaves as `vivid_fbm3`, and the span
		// doubles with the frequency because that is what it is measuring.
		p = p.yzx * 2.02 + vec3(17.3, 5.7, 31.1);
		amplitude *= 0.5;
		span *= 2.0;
	}
	return sum / max(total, 0.0001);
}

// [param footprint] is the width of one pixel in cells of the noise, which is
// the pixel's width in metres times [param scale]. Zero asks for the whole
// field and is what a surface close enough for that to be honest should pass.
vec3 vivid_bump_normal(vec3 world_position, vec3 normal, float scale,
		float strength, float footprint) {
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
	//
	// Sized against the finest octave still standing rather than the finest the
	// field has. What is taken here is a difference and not a derivative —
	// nothing divides it by the step — so once the fine octaves are filtered out
	// a step cut to their size returns a smaller and smaller number, and the
	// ground goes flat as the eye backs away for the same reason it used to
	// sparkle. Growing the step with the pixel measures the lean of what is left
	// over a baseline that suits it, and the swells keep the strength they had.
	float resolved = max(1.0, footprint / VIVID_DETAIL_KEEP);
	float step_size = 0.25 * resolved / max(scale, 0.0001);
	vec3 along = tangent * step_size;
	vec3 across = bitangent * step_size;
	vec3 slope = tangent * (
			vivid_fbm3_seen((world_position + along) * scale, 3, footprint)
			- vivid_fbm3_seen((world_position - along) * scale, 3, footprint))
		+ bitangent * (
			vivid_fbm3_seen((world_position + across) * scale, 3, footprint)
			- vivid_fbm3_seen((world_position - across) * scale, 3, footprint));
	// The offset is the tangent of the tilt it asks for, and an unbounded one is
	// what turned a sea bed into a plaid. A field this sharp has patches where the
	// difference is several times its own average, and past a tilt of about one the
	// `normalize` stops leaning the surface normal and starts *replacing* it with
	// the field's own gradient direction — which barely turns inside a noise cell,
	// so those patches come out as flat facets a cell wide with hard creases
	// between them. Clamping the length rather than lowering the gain keeps the
	// texture everywhere the field is ordinary and only gives up the spikes, which
	// were never bumps so much as folds.
	//
	// Approached rather than clamped to, and that is the last of the plaid. A
	// hard ceiling hands every pixel past it the same lean, so wherever the
	// field is steep — on open ground, most of it — the tilt stops carrying how
	// steep and the ground goes flat in patches a noise cell wide; and the line
	// where the ceiling begins is a break in the gradient, which lights as a
	// crease drawn round each patch. Photographed ground hides it and bare
	// ground does not, which is why it read as the texture being at fault.
	//
	// This curve sits on `tilt` where the field is ordinary, bends over to the
	// same ceiling where it is not, and rises everywhere in between, so no two
	// slopes are ever given the same lean and there is no line for a crease to
	// fall on. Written against the gradient direct rather than as a length and a
	// unit vector, which is the same arithmetic without the divide.
	float reach = length(slope) * strength * 8.0 / VIVID_BUMP_TILT;
	return normalize(normal
		- slope * (strength * 8.0 * inversesqrt(1.0 + reach * reach)));
}

// The same gradient-of-a-noise-field trick as `vivid_bump_normal`, over
// `vivid_hetero3` instead of an fBm, and with the field drifting.
//
// It is a separate function rather than a flag on that one because the two are
// used for different things and should be able to be tuned apart: the ground's
// bumps are a static field being read at a distance, and these are a moving
// surface being read close up. The tangent frame, the step size and the tilt
// clamp are all shared reasoning, and the comments on those live over there.
//
// [param drift] is metres of travel, handed to the field so its octaves can
// move at their own rates; see `vivid_hetero3`.
vec3 vivid_chop_normal(vec3 world_position, vec3 normal, float scale,
		float strength, float relief, vec3 drift) {
	if (strength <= 0.0) {
		return normal;
	}
	vec3 tangent = normalize(cross(normal,
		abs(normal.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 bitangent = cross(normal, tangent);
	float step_size = 0.25 / max(scale, 0.0001);
	vec3 along = tangent * step_size;
	vec3 across = bitangent * step_size;
	vec3 scaled_drift = drift * scale;
	vec3 slope = tangent * (
			vivid_hetero3((world_position + along) * scale, 3, relief, scaled_drift)
			- vivid_hetero3((world_position - along) * scale, 3, relief, scaled_drift))
		+ bitangent * (
			vivid_hetero3((world_position + across) * scale, 3, relief, scaled_drift)
			- vivid_hetero3((world_position - across) * scale, 3, relief, scaled_drift));
	float reach = length(slope) * strength * 8.0 / VIVID_BUMP_TILT;
	return normalize(normal
		- slope * (strength * 8.0 * inversesqrt(1.0 + reach * reach)));
}

// Godot's fragment normals are view space, and everything here works in world
// space, so this is the only way back.
vec3 vivid_to_view(mat4 view_matrix, vec3 world_normal) {
	return normalize((view_matrix * vec4(world_normal, 0.0)).xyz);
}
