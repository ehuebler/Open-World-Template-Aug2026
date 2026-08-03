// The cloud deck: a slab of air around the planet, marched through rather than
// painted onto a sphere.
//
// There is no cloud mesh and no cloud object. A sphere a kilometre or so above
// sea level is the only thing submitted, and it is not the clouds — it is only
// what gets a fragment onto the screen wherever the deck could be seen. What is
// drawn is a **field of density filling the shell between two radii**, and every
// pixel walks its own view ray through that field, gathering light and losing
// transmittance as it goes.
//
// The clouds are still placed by where they are on the globe, take their colour
// from the same wheel the ground and the air do, and cost nothing to generate,
// store or replicate: two players standing in different hemispheres see
// different weather without a byte crossing the wire.
//
// Marching is the whole difference between gas and a sticker. One sample per
// pixel — which is all a shell can take — has no thickness in it anywhere, so a
// cloud looks the same seen edge-on as face-on, has no underside, and passes
// through the camera in a single frame as a wall with no inside. Walking the ray
// gives all three for free: thickness is how much field the ray crossed, the
// underside is where the ray entered from below, and flying into the deck simply
// starts the march at the eye, so cloud builds up around the camera the way fog
// does.
//
// The look on top of that is thin-film: hue runs in bands along the contours of
// the density, so every fold and every torn edge shows the spectrum somewhere.
// What makes that read as cloud instead of as an oil slick is that the bands
// follow a domain-warped fractal, so they fold back on themselves the way a
// cumulus tower does.
//
// Clouds condense and evaporate because the field holds still while the level it
// is cut at breathes: raise the cut and a cloud shrinks in from its edges until
// it is gone, lower it and it grows back out of its own core. A second, much
// slower field decides which part of the sky is doing which, so the deck never
// clears all at once.
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, depth_test_disabled,
	shadows_disabled, fog_disabled;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

// The loop has to have a constant bound to unroll, and `march_steps` only ever
// asks for fewer. Raising this costs compile time on every cloud pixel in the
// game whether or not anything asks for the steps.
const int MAX_STEPS = 24;

// Wavelength of the finest octave the density field carries, in field units.
// Three octaves at 2.02 apiece, so the third is 1 / 2.02² across. The step is
// sized against this, which is what keeps the sampling honest when cloud_scale,
// vertical_scale or the deck's depth are changed.
const float FINEST_OCTAVE = 0.245;

// Outer radius of the deck in metres from the planet's centre, written by Planet
// when it raises the shell. The mesh's own radius has to match it: the sphere is
// the volume's silhouette, and a mesh smaller than the field clips the deck at
// the limb while a larger one wastes fragments on empty sky.
uniform float shell_radius = 9450.0;
// How deep the slab is, downward from `shell_radius`. This is the number that
// decides whether the deck reads as weather or as a lid: much under a couple of
// hundred metres and a ray crosses too little of it to accumulate anything, and
// the march goes back to being one sample with extra steps.
uniform float deck_thickness = 700.0;

// The three dials that decide what the deck costs, in the order they matter.
//
//   march_steps   the hard budget of samples per pixel, and the only one that
//                 bounds the worst case. Every other number here trades quality
//                 against how far that budget reaches
//   step_detail   how much of the field's finest octave one step is allowed to
//                 cross. Half means two samples per feature, which is the least
//                 that integrates rather than point-samples; point-sampling
//                 shows as a boiling speckle, because neighbouring pixels land
//                 in different parts of the field and come back with different
//                 opacities
//   step_growth   how much longer each step is than the one before it
uniform int march_steps : hint_range(4, 24) = 20;
uniform float step_detail : hint_range(0.15, 1.5) = 0.55;
uniform float step_growth : hint_range(1.0, 1.5) = 1.14;

// Extinction per metre at unit density. This is opacity: raise it and a cloud
// goes solid in a shorter crossing, which also darkens its core, because what
// makes the inside of a cloud dark is the same number.
uniform float density_gain : hint_range(0.0, 0.4) = 0.055;

// The vertical profile, as shares of the deck's depth: how far up from the floor
// a cloud fades in, and how far down from the roof it fades out. They are
// deliberately unequal. A cumulus has a flat base — it is where the air hits the
// dew point, and it is at the same altitude for miles — and a soft billowing
// top, so the floor wants to be sharp and the roof gradual. Equal values give a
// lens, which reads as a lozenge of fog.
// The arctic deck. `polar_deepen` is extra slab depth as a multiple of
// `deck_thickness`, all of it added below the roof; `polar_coverage` is how far
// the cut is lowered, which is what actually fills the polar sky in, since the
// cut is the level the density field is sliced at; `polar_density` thickens what
// is left so a crossing goes opaque sooner and the cloud reads as weather rather
// than as haze. Each of the three is a different kind of "more cloud" and they
// are needed together: coverage alone gives a wide thin overcast, density alone
// gives the same few clouds turned to concrete.
// Bounded by the ground, and not by taste. The roof is fixed at `shell_radius`,
// so the depth added by this all comes off the floor: at the defaults the deck
// runs 850 m to 1550 m up, and anything past about 0.9 puts its floor under sea
// level. A deck whose floor is underground is one the player stands inside, and
// what that looks like is not weather but fog — the whole arctic goes flat, and
// the snow falling through it disappears behind a kilometre of overcast drawn on
// top of it.
uniform float polar_deepen : hint_range(0.0, 4.0) = 0.85;
uniform float polar_coverage : hint_range(0.0, 0.5) = 0.14;
uniform float polar_density : hint_range(0.0, 4.0) = 1.4;

// The wall: a ring of cloud standing on the ground all the way round the rim of
// the cap, dense enough that the arctic cannot be seen into or out of except by
// flying through it. Same three kinds of "more cloud" as the trio above, keyed
// to [method deck_rim] instead of to the cap.
//
// This is the one place the warning above is deliberately ignored. A floor under
// the ground is fog rather than weather and flattens whatever is standing in it
// — which is exactly the point here, and is why it is confined to a band a
// kilometre or so wide rather than let loose over the whole cap. `wall_deepen`
// has to be enough to put that floor under the deepest sea bed, or the wall ends
// in mid-air over the coast and the ring reads as a row of hanging curtains;
// past that the extra is spent below sea level, where the march never reaches.
//
// The opacity is not bought here at all, and both of the obvious ways to buy it
// end in the same picture: a wall with no surface, lit through nine turns of
// spectrum, which comes back as concentric rainbow rings centred on the eye.
// Coverage past where the field bottoms out makes every point in the slab cloud,
// so the front of the wall becomes the shell the deck is drawn on, which is a
// sphere. Density does it more quietly — it turns the wisps on the approach
// opaque too, so the ray stops in a fog ramp a few hundred metres short of
// anything, and the iso-surface of that ramp is just as smooth.
//
// What makes it opaque is the crossing. The band is over a kilometre thick and
// the ring is a wall rather than a lid, so a ray going in at eye level crosses
// all of it: at ordinary cloud density that is twenty times the extinction it
// takes to go solid. So the two dials below only have to make sure there *is*
// cloud the whole way across, and the far side stops being visible on its own.
//
// All three act on where there is cloud and how solid it is, and none of them
// on the field the cloud is made of. That is a rule and not a coincidence — see
// the note in [method deck_field], which is where breaking it shows.
uniform float wall_deepen : hint_range(0.0, 6.0) = 1.6;
uniform float wall_coverage : hint_range(0.0, 1.5) = 0.5;
uniform float wall_density : hint_range(0.0, 8.0) = 1.5;
uniform float deck_floor_soft : hint_range(0.02, 0.6) = 0.1;
uniform float deck_roof_soft : hint_range(0.02, 0.9) = 0.55;
// How much harder the field has to work to be cloud near the floor and the roof.
// This, not the profile alone, is what gives a cloud a shape in section: it
// pinches the field in from above and below so a tower narrows as it rises
// instead of being a column cut off flat at the top.
uniform float deck_taper : hint_range(0.0, 0.5) = 0.16;

// The two ends of a cloud's own tone: the shaded fold and the crest catching the
// light. Most of a cloud is the first, veined through with the second. Neither
// is where the hue comes from — the film supplies that — but the deep colour is
// saturated rather than grey, because a neutral shadow drains the film sitting
// next to it.
uniform vec3 deep_color : source_color = vec3(0.09, 0.05, 0.19);
uniform vec3 pale_color : source_color = vec3(1.0, 0.98, 0.94);

// Cycles of the cloud field around the globe. Nine puts a weather system about
// five kilometres across on an eight kilometre planet, which is the scale that
// reads as continental from orbit and as sky from the ground.
uniform float cloud_scale = 9.0;
// How far the sample slides radially between the deck's floor and its roof, in
// the same field units. This is what makes the field three-dimensional, and it
// is the difference between clouds and curtains: at zero the field depends only
// on direction, so every cloud is a column with the same cross-section all the
// way up and the deck is a cookie cutter dragged through the sky. Around two, a
// ray climbing through the slab crosses a couple of features and clouds get
// bellies, waists and tops.
uniform float vertical_scale : hint_range(0.0, 6.0) = 2.2;
// Frequency of the fine octaves and of the crests, as a multiple of the above.
// This is the dial for how torn the edges are.
uniform float detail_scale : hint_range(1.0, 16.0) = 5.0;
// How far the field is dragged through itself before it is sampled. It is the
// whole difference between round lumps and something with folds and overhangs.
uniform float warp_strength : hint_range(0.0, 2.0) = 0.6;

// How much of the deck's *volume* is cloud at the middle of the breath — not
// how much of the sky, which is what it meant while the deck was a surface and
// is a good deal more. A ray leaving the ground at a shallow angle crosses
// kilometres of slab and passes through several cloud cells on the way, so it
// finds something almost whatever this says; the share of sky ends up roughly
// double the share of volume near the zenith and total at the horizon, which is
// how a real overcast reads too. Anything much above a third closes the sky
// over completely and the deck goes back to being a lid.
uniform float coverage : hint_range(0.0, 1.0) = 0.32;
// How much the fine octaves are allowed to move the field. Bounded on purpose:
// it is what lets a step of the march decide there is nothing here after three
// octaves instead of five. See the skip in the loop.
uniform float detail_relief : hint_range(0.0, 0.6) = 0.24;

// How far the cut swings either side of `coverage`, how large the patches of sky
// that swing together are, and how fast. The speed is in cycles a second of the
// breathing field, so 0.015 is a cloud that takes a couple of minutes to build
// and clear — weather, not a strobe.
uniform float breathe : hint_range(0.0, 0.5) = 0.17;
uniform float breathe_scale : hint_range(0.5, 8.0) = 2.1;
uniform float breathe_speed = 0.015;
// Where the deck is going, in field units a second. Slow: this is the whole
// field sliding, and anything a player can see moving in the sky is a gale.
uniform vec3 wind = vec3(0.005, 0.002, -0.004);

// Metres toward the sun the shadow sample is taken, and how hard what it finds
// darkens the step. This is the one thing that makes a marched cloud read as a
// solid object rather than as coloured smoke: the near face of a tower is lit
// and its far face is not, and the two are the same field a hundred metres
// apart. One sample, not a march — a second march per step is four times the
// cost for a softer version of the same answer.
uniform float shadow_step = 180.0;
uniform float shadow_gain : hint_range(0.0, 8.0) = 3.2;
// Light reaching the deepest fold. Not zero: a cloud lit only from outside goes
// to a black core, and a real one is glowing grey all the way through.
uniform float shadow_floor : hint_range(0.0, 1.0) = 0.12;

// Turns of the spectrum across the density range, how bright the film is, and
// how fast the whole palette rolls through itself.
uniform float iris_bands : hint_range(1.0, 40.0) = 12.0;
uniform float iris_strength : hint_range(0.0, 8.0) = 1.1;
uniform float iris_drift = 0.02;
// Turns of the spectrum across the cloud body itself, which is the hue that
// survives to orbit because it is as coarse as the clouds are.
uniform float iris_swirl : hint_range(0.0, 8.0) = 2.5;
// Extra chroma on the finished colour. The film is already saturated; this is
// what keeps it that way after the day term has multiplied into it.
uniform float iris_chroma : hint_range(1.0, 3.0) = 1.55;
// How much of the film is in the cloud's own colour rather than only in the
// light coming off it. Near zero leaves a white cloud with a rainbow edge; near
// one is the whole cloud made of the film, which is what the deck is for. Short
// of one on purpose — a little white left in is what keeps it reading as cloud
// rather than as an oil slick.
uniform float iris_tint : hint_range(0.0, 1.0) = 0.95;
// How much of the glow belongs to the thin edge of the deck rather than to its
// veins.
uniform float rim_gain : hint_range(0.0, 4.0) = 1.0;
// Where the crest field becomes a vein. Narrow, and the whole cloud is dark with
// a few bright threads; wide, and it washes back out to a pale blob.
uniform float vein_low : hint_range(0.0, 1.0) = 0.14;
uniform float vein_high : hint_range(0.0, 1.0) = 0.55;
uniform float vein_glow : hint_range(0.0, 4.0) = 0.8;

// Opacity of a crossing thick enough to have no edge. Under one, so the ground
// is never quite lost under the deck and the planet still reads as a planet.
uniform float body_alpha : hint_range(0.0, 1.0) = 0.95;
// What is left of the light on the night side. Not zero — the deck is holographic
// and the terminator is the best view of it there is.
uniform float night_light : hint_range(0.0, 1.0) = 0.16;
// How strongly cloud lights up when the sun is almost straight behind it. Every
// water droplet throws most of what it catches forward, which is why the cloud
// you are looking past the sun at is the brightest thing in the sky.
uniform float forward_glow : hint_range(0.0, 3.0) = 0.9;

// Air between the eye and the cloud. Not decoration: seen from under it the deck
// compresses toward the horizon until a whole weather system is a few pixels
// tall, and with nothing in front of that band it is busier down there than
// anything overhead — which is the exact opposite of how a sky reads. Haze is
// what every real one has instead.
//
// It is scaled off as the camera leaves the air, so the view from orbit keeps
// its contrast: there is nothing between an eye in space and the cloud tops.
uniform vec3 haze_color : source_color = vec3(0.62, 0.75, 0.9);
// Metres of air that hide roughly two thirds of what is behind them.
uniform float haze_range = 5000.0;
// Camera altitude by which the air has been left behind, in metres. Wants to be
// the atmosphere's own height.
uniform float haze_ceiling = 2400.0;

// Where the fine detail starts and finishes fading out, in metres of the
// footprint below — which is not the distance to the cloud but how much deck a
// pixel is being asked to average. Straight up at a cloud a kilometre overhead
// that is a kilometre; along the deck at the horizon it is tens of them, which
// is why these numbers look far larger than anything the player can see.
uniform float detail_near = 8000.0;
uniform float detail_far = 90000.0;
// The same, for the contour bands, which need their own pair rather than a
// share of the above: they multiply the density's wobble by iris_bands and so
// give out about that many times sooner.
uniform float band_near = 1200.0;
uniform float band_far = 6000.0;

// What the opaque pass already put down, used to stop the march at the ground
// rather than to test the shell against it. Nearest, not filtered: a depth
// interpolated across a silhouette is a distance to a place with nothing at it,
// and it shows as a halo of cloud around every mountain.
uniform sampler2D depth_buffer : hint_depth_texture, filter_nearest;

varying vec3 v_world_position;


// Where a unit ray from [param origin] crosses a sphere about the planet's
// centre: the near root in x and the far one in y, and x above y for a miss.
vec2 deck_span(vec3 origin, vec3 ray, float radius) {
	vec3 offset = origin - planet_center;
	float along = dot(offset, ray);
	float outside = dot(offset, offset) - radius * radius;
	float discriminant = along * along - outside;
	if (discriminant < 0.0) {
		return vec2(1.0, -1.0);
	}
	float root = sqrt(discriminant);
	return vec2(-along - root, -along + root);
}


// Where a point sits in the field, how far up the slab it is, and how arctic it
// is. All three come out of the one radial normalise, which is why they are
// asked for together.
//
// The radius goes into the sample and not just the direction, which is the
// whole of what makes this a volume. `vertical_scale` is how much of it: the
// sample slides radially through the field as the point climbs through the
// deck, so a cloud is a different shape at its waist than at its top.
//
// Over the pole the slab is deepened rather than moved. Its roof is the shell
// the whole thing is drawn on and cannot go anywhere — a shell that had to
// change radius by latitude would stop being a sphere — so the extra depth all
// hangs below, which is both of the things the arctic deck wants: thicker, and
// low enough to fly into.
// The rim of the polar cap as a band: 0 out in the open, 0 well inside the ice,
// 1 across the ground between the two.
//
// The parabola of the cap against itself, which is the cheapest thing that is a
// band rather than a step and — the reason for taking it this way rather than
// declaring a second pair of cosines — needs nobody to say where the band is. It
// is wherever the cap is half decided, so `frost_area` and `frost_blend` carry
// the wall with them and there is still exactly one owner of where the arctic is.
float deck_rim(float frost) {
	return 4.0 * frost * (1.0 - frost);
}


vec3 deck_field(vec3 point, out float height, out float frost) {
	vec3 offset = point - planet_center;
	float here = length(offset);
	vec3 up = offset / max(here, 0.0001);
	frost = vivid_frost(up);
	float thickness = deck_thickness
		* (1.0 + frost * polar_deepen + deck_rim(frost) * wall_deepen);
	height = (here - (shell_radius - thickness)) / thickness;
	// Metres below the roof, over the slab's unswollen depth. Not `height`,
	// which is the share of the slab and is what this used to be.
	//
	// The whole field is this one number — its size sets how fine the cells are
	// across the sphere and its change with altitude sets how layered the deck
	// is — so nothing that varies with latitude may go anywhere near it. The
	// slab's depth does: through the ring it triples and comes back, so a
	// coordinate divided by it swept four turns of noise over the kilometre of
	// ground the band covers, and drew a contour of the field along every line
	// of latitude in it. From beside, at eye level, those close into ellipses
	// centred on the viewer, because the planet curves away and the far ones
	// crowd together — so the arctic came back as ripples on a pond. Two
	// attempts to break it up by *adding* latitude terms here, grain and
	// flattening, both made it finer and worse before the shared cause showed.
	//
	// Latitude belongs in the gate and in the extinction, which decide where
	// there is cloud and how solid it is. It does not belong in the coordinate,
	// which decides what the cloud looks like.
	return up * (cloud_scale + (shell_radius - here) / deck_thickness * vertical_scale);
}


// The vertical envelope: 1 through the middle of the deck, 0 at the floor and
// the roof. Also what `deck_taper` leans on to pinch a cloud's shape in.
float deck_profile(float height) {
	return smoothstep(0.0, deck_floor_soft, height)
		* (1.0 - smoothstep(1.0 - deck_roof_soft, 1.0, height));
}


void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	// The ray, taken through the fragment rather than from it. The mesh is a
	// polyhedron whose facets are hundreds of metres across at this radius, so
	// its surface is not the deck — but the line from the eye through it is
	// exactly the line the pixel is looking along, and that is all the march
	// needs.
	vec3 origin = CAMERA_POSITION_WORLD;
	vec3 ray = normalize(v_world_position - origin);

	vec2 outer = deck_span(origin, ray, shell_radius);
	if (outer.x > outer.y || outer.y <= 0.0) {
		discard;
	}
	float enter = max(outer.x, 0.0);
	float leave = outer.y;

	// The planet ends the march. Without this the ray carries on through the
	// world and out the far side, and the weather over the antipodes is drawn
	// on top of the ground under the camera.
	vec2 ground = deck_span(origin, ray, planet_radius);
	if (ground.x <= ground.y) {
		if (ground.x > 0.0) {
			leave = min(leave, ground.x);
		} else if (ground.y > 0.0) {
			// Eye below sea level, looking out: the sky starts where the ray
			// leaves the water.
			enter = max(enter, ground.y);
		}
	}

	// And so does anything already in the depth buffer — a mountain between the
	// eye and a cloud, chiefly. The deck does not depth-test as a whole, because
	// it is a volume and the shell it is drawn on is nowhere near where the
	// cloud along a given ray actually is: from inside the shell every fragment
	// carries the depth of the far side of the sphere, and a single test against
	// that would hide the entire sky behind the first hill.
	float depth = texture(depth_buffer, SCREEN_UV).x;
	vec4 seen = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	leave = min(leave, length(seen.xyz / seen.w));

	float span = leave - enter;
	if (span <= 0.0) {
		discard;
	}

	// How far along the deck one pixel reaches: its distance, stretched by
	// however obliquely the deck is being crossed. A field has no mip chain, so
	// this is the only thing standing between the fine octaves and a moire, and
	// both halves of it are needed. Distance alone misses the horizon from under
	// the deck, which is a few kilometres off but crossed at seventy-five
	// degrees; obliquity alone misses the limb from orbit.
	//
	// Obliquity is squared rather than taken straight, and that is a deliberate
	// bias rather than the geometry. A pixel at a grazing angle covers a long
	// thin strip, and a single fade can only blur it in both directions or in
	// neither; the two cases that collide here — a whole planet from 17 km, and
	// the ground four kilometres out from just above the deck — come to much the
	// same footprint measured honestly, and only the second one stripes.
	float facing = abs(dot(vivid_up(origin + ray * enter), ray));
	float footprint = (enter + span * 0.5) / pow(max(facing, 0.05), 2.0);

	// The first step's length, sized off how fast the field turns over along
	// this particular ray, and never off the span the ray has to cross.
	//
	// The field is nothing like isotropic. `cloud_scale` turns are wrapped
	// around a nine kilometre sphere and `vertical_scale` turns are packed into
	// seven hundred metres of deck, so its finest octave is a couple of hundred
	// metres across sideways and well under a hundred tall. A ray dropping
	// straight through therefore has to be sampled several times more finely
	// than one skimming along it, and the two rates simply add along whatever
	// direction the ray is actually going.
	//
	// Sizing the step off the deck's depth instead is the obvious thing to do
	// and is what this did first. It spends the same on both, which means it
	// spends the whole step budget on the skimming ray — and the skimming ray is
	// every pixel on the screen when the player is flying just above the tops.
	// That measured out at four and a half milliseconds of a sixteen millisecond
	// frame, for one effect, on a card far better than the one this has to run
	// on.
	//
	// The step is also the smooth quantity here and the count follows from it,
	// never the other way round. Dividing a span into a whole number of steps
	// looks like the same thing and is not: the count can only change by one, so
	// the step jumps by a fraction of itself wherever it does, and the screen
	// fills with hard stair-stepped bands along every line where the crossing
	// happens to be an exact multiple.
	float across = sqrt(max(1.0 - facing * facing, 0.0));
	float radial = max(deck_thickness / max(vertical_scale, 0.01) * FINEST_OCTAVE, 1.0);
	float tangential = max(shell_radius / max(cloud_scale, 0.01) * FINEST_OCTAVE, 1.0);
	float stride = step_detail / (facing / radial + across / tangential);
	int steps = min(march_steps, MAX_STEPS);

	// The march cannot resolve anything finer than its own step, so the step is
	// part of the footprint and at range it is the whole of it. Measured against
	// the crest field's own feature size rather than tuned, so it follows
	// cloud_scale and detail_scale without being told.
	float crest_metres = planet_radius / max(cloud_scale * detail_scale * 2.5, 0.001);
	float near = min(1.0 - smoothstep(detail_near, detail_far, footprint),
		1.0 - smoothstep(crest_metres * 0.6, crest_metres * 2.0, stride));

	// One warp for the whole ray, taken at the middle of the crossing. Warping
	// each sample separately is three more noise lookups per step for a fold
	// that runs a little deeper; this is the single biggest saving in the file
	// and the only one that costs anything visible, which is that overhangs do
	// not change shape along the line of sight.
	float unused_height;
	float unused_frost;
	vec3 middle = deck_field(origin + ray * (enter + span * 0.5),
		unused_height, unused_frost);
	vec3 drift = wind * TIME;
	vec3 warp = (vec3(
		vivid_noise3(middle + drift + 4.7),
		vivid_noise3((middle + drift).yzx - 9.1),
		vivid_noise3((middle + drift).zxy + 17.3)) - 0.5) * warp_strength;

	// Which way this patch of sky is going, and how far the cut has swung. Taken
	// from the direction rather than from the drifted field, so a weather system
	// stays over the place it belongs to while the cloud slides through it.
	vec3 through_up = vivid_up(origin + ray * (enter + span * 0.5));
	float tide = vivid_noise3(through_up * breathe_scale + vec3(TIME * breathe_speed));
	float cut = 1.0 - coverage + breathe * (tide * 2.0 - 1.0);

	vec3 sun = normalize(-sun_direction);

	float transmittance = 1.0;
	float lit = 0.0;
	// How far along the ray the cloud that this pixel is looking at sits,
	// weighted by how much each step contributed to it. The colour is worked out
	// once, there, rather than per step: the film, the veins and the crests are
	// six more lookups apiece and they describe the face of the cloud being
	// looked at, which is what this distance finds. Inside the loop they would
	// be four times the cost of the whole shader, for a hue gradient through the
	// inside of a solid.
	//
	// Every sample sits at the centre of its own step and nowhere else. The
	// usual trick is to jitter the first one per pixel, which dithers the
	// banding a coarse march leaves behind — but a dither wants a temporal
	// filter to resolve it and there is none here, and at the step sizes this
	// deck reaches it stops being a dither and becomes the noise itself. What
	// keeps the banding down instead is that the step starts sized to the field.
	float focus_range = 0.0;
	float focus_weight = 0.0;

	// The step lengthens as the ray goes, by `step_growth` each time. A fixed
	// budget of equal steps either reaches a few kilometres and stops — leaving
	// the far half of a grazing crossing undrawn — or is coarse enough to reach
	// and then wastes that coarseness on the near half, where it shows. Growing
	// it spends the budget the way perspective does: a step a tenth the length
	// twice as far away covers the same number of pixels, so the error stays
	// where it cannot be seen.
	float size = stride;
	float reached = enter;

	for (int i = 0; i < MAX_STEPS; i++) {
		if (i >= steps || transmittance < 0.012 || reached >= leave) {
			break;
		}
		// Shortened on the last step to whatever is left of the crossing.
		// Without it a ray that ends on the ground keeps a step's worth of cloud
		// from underneath it.
		float slice = min(size, leave - reached);
		float travelled = reached + slice * 0.5;
		reached += slice;
		size *= step_growth;
		vec3 point = origin + ray * travelled;

		float height;
		float frost;
		vec3 field = deck_field(point, height, frost) + drift + warp;
		if (height <= 0.0 || height >= 1.0) {
			continue;
		}
		float rim = deck_rim(frost);
		float gate = cut - frost * polar_coverage - rim * wall_coverage
			+ (1.0 - deck_profile(height)) * deck_taper;

		float body = vivid_fbm3(field, 3);
		// Nothing here, and no way the two fine octaves could have made it
		// something: they are centred on a half and scaled by `detail_relief`,
		// so this is a bound rather than a guess. Most steps of most rays leave
		// at this line, which is what makes the march affordable at all.
		if (body + detail_relief * 0.5 < gate) {
			continue;
		}
		float fine = mix(0.5, vivid_fbm3(field * detail_scale + 11.0, 2), near);
		float density = body + (fine - 0.5) * detail_relief - gate;
		if (density <= 0.0) {
			continue;
		}

		// One sample toward the sun, in the field the cloud is made of. Cheap
		// because it skips the fine octaves: what shadows a cloud is its mass,
		// and the filigree on its edge shadows nothing.
		float ahead_height;
		float ahead_frost;
		vec3 ahead_field = deck_field(point + sun * shadow_step, ahead_height, ahead_frost)
			+ drift + warp;
		float ahead = vivid_fbm3(ahead_field, 3) - cut + ahead_frost * polar_coverage
			+ deck_rim(ahead_frost) * wall_coverage
			- (1.0 - deck_profile(ahead_height)) * deck_taper;
		ahead *= step(0.0, ahead_height) * step(ahead_height, 1.0);
		float shadow = mix(shadow_floor, 1.0,
			exp(-max(ahead, 0.0) * shadow_gain * deck_thickness * 0.01));

		float extinction = density * density_gain
			* (1.0 + frost * polar_density + rim * wall_density) * slice;
		float absorbed = 1.0 - exp(-extinction);
		float weight = absorbed * transmittance;
		lit += shadow * weight;
		focus_range += travelled * weight;
		focus_weight += weight;
		transmittance *= exp(-extinction);
	}

	float alpha = 1.0 - transmittance;
	if (alpha < 0.004) {
		discard;
	}
	// Back from a sum weighted by contribution to the average it stands for.
	float scale = 1.0 / max(focus_weight, 0.0001);
	float shade_light = lit * scale;
	float range = focus_range * scale;

	// The one place the colour is sampled, and the only lookups in this shader
	// that are not inside the march.
	float focus_height;
	float focus_frost;
	vec3 sampled = deck_field(origin + ray * range, focus_height, focus_frost) + drift + warp;
	float body = vivid_fbm3(sampled, 3);

	// Colour detail gets a second, harder fade that the density does not: how
	// squarely the deck is being looked at.
	//
	// Everything below is sampled where the ray found its cloud, and that point
	// runs along the deck as the view tips over — so at a grazing angle a pixel
	// step slides it tens of metres and the fine fields sweep through several
	// periods between one pixel and the next. Contours of a field seen edge-on
	// compressing is not an artefact, it is what the stripes on a floor do
	// toward the far wall; but a band that was a fold of a cloud overhead and is
	// eight pixels wide at forty degrees reads as ripples on a pond, and it
	// fills the bottom half of the sky with them. Distance never catches it,
	// because the worst of it is nearest the camera.
	//
	// The density detail is deliberately left out of this. It is inside the
	// march and it decides what shape a cloud is, and a shape that fades with
	// the angle it is looked at is a cloud that changes as the player turns
	// their head.
	//
	// fwidth would measure the compression rather than infer it, and cannot be
	// used: derivatives are undefined in non-uniform control flow, and every
	// value here comes out of a loop with a data-dependent break downstream of
	// three discards. What it returns is whatever the neighbouring pixel was
	// doing, and the fade it drives is silently no fade at all.
	float square_on = near * smoothstep(0.3, 0.8, facing);
	// Ridged, not smooth. The torn filigree over a cloud is a crest field, and
	// it is the one thing that stops a fractal blob reading as fog.
	float crest = mix(0.3, vivid_ridge3(sampled * detail_scale * 2.5 + 5.0, 3), square_on);
	// Where the crossing is thin, which is the edge of every cloud and of every
	// hole torn in one. It is where nearly all of the colour goes. Taken from
	// the accumulated opacity rather than from the field, so it now follows the
	// silhouette of the volume instead of a contour of the noise.
	float rim = alpha * (1.0 - alpha) * 4.0;

	vec2 region = vivid_region(vivid_up(origin + ray * range));
	// A thin film, at three scales at once, each taking the hue over as the one
	// below it stops being resolvable. That is what keeps the deck iridescent at
	// every range rather than at one of them:
	//
	//   bands   contour lines of the density at the face being looked at, so the
	//           spectrum runs along every fold instead of being sprayed across
	//           it. Close range only — they multiply the density's own wobble by
	//           iris_bands and so alias about that many times sooner than it
	//           does, and a sub-pixel rainbow resolves as grey speckle.
	//           Deliberately not the accumulated thickness, which is the other
	//           obvious source and is what a thin film's colour really depends
	//           on: thickness grows smoothly with how obliquely the deck is
	//           crossed, so banding it draws concentric rainbow rings around the
	//           zenith and nothing along any cloud
	//   swirl   the cloud's own body, in swathes a weather system wide
	//   region  the planet's colour wheel, which is what makes one continent's
	//           weather green and the next one's magenta
	float band_fade = square_on * (1.0 - smoothstep(band_near, band_far, footprint));
	// The bands are faded out of the **colour** and not out of the phase, and
	// the difference is the single worst-looking bug this shader has had.
	//
	// Scaling a phase by a number that falls from one to zero does not remove
	// what the phase was drawing. The hue is read from the phase, so every pixel
	// on the way down passes through as many turns of the spectrum as the phase
	// was worth — and because a fade of this kind depends only on how obliquely
	// the deck is being seen, those turns land along lines of constant view
	// angle. The sky fills with concentric rainbow rings centred on the zenith,
	// strongest exactly where the fade was meant to be removing them.
	// And the swirl needs the same guard the bands have, one step further out.
	//
	// `square_on` gives up at 0.3, on the grounds that below it the bands were
	// the only thing fine enough to alias. That held while the deck was a lid:
	// nothing was looked at edge-on for more than a few hundred metres, so the
	// body under the swirl slid a little and drew a wide soft gradient. A wall
	// is looked at edge-on for kilometres — it is the one surface here that can
	// fill the screen at a facing of a twentieth — and over that the body sweeps
	// several periods and the swirl paints every one of them as a turn of
	// spectrum. What it comes out as is ripples on a pond, in rings, because
	// what the sample slides with at that point is distance and nothing else.
	//
	// So below 0.3 the swirl changes what it rides on rather than fading out.
	// `shade_light` is accumulated over the whole crossing instead of read at
	// one point, so it belongs to the cloud rather than to where the ray
	// happened to stop, and it keeps the hue moving across a wall that a flat
	// region tint would leave as one pastel sheet.
	float steady = mix(shade_light, body, smoothstep(0.05, 0.30, facing))
		* iris_swirl + region.x + TIME * iris_drift;
	vec3 iris = vivid_saturate(mix(vivid_spectrum(fract(steady)),
		vivid_spectrum(fract(steady + body * iris_bands + crest * 0.4)),
		band_fade), iris_chroma);

	float day = mix(night_light, 1.0,
		smoothstep(-0.35, 0.35, dot(vivid_up(origin + ray * range), sun)));
	// Light coming the other way through a thin edge is what lights a real
	// cloud's rim, and it is also where a film shows its colour most.
	float through = pow(max(dot(-ray, sun), 0.0), 6.0) * forward_glow;

	// Veins, not a wash. A cloud is mostly shaded fold with light drawn through
	// it along the ridges of the crest field, and it swings the whole way from
	// one to the other: the filigree only shows because of how dark the fold
	// beside it is, and a body painted pale throughout gives the film nothing to
	// sit against, which is a pastel smear.
	float vein = smoothstep(vein_low, vein_high, crest);
	vec3 tone = mix(vec3(1.0), iris, iris_tint);
	float shade = shade_light * mix(0.75, mix(0.55, 1.0, vein), near);
	float glow = vein * vein * vein_glow + rim * rim_gain + through * 0.5;
	vec3 body_color = mix(deep_color, pale_color * tone, shade) * day * (1.0 + through);

	float air = 1.0 - smoothstep(0.0, haze_ceiling, vivid_altitude(origin));
	float haze = air * (1.0 - exp(-range / haze_range));
	// Haze is sunlight scattered by the air in between, so it goes out with the
	// sun like everything else here. Left at full strength it was the one thing
	// on the night side that did not, and a deck five kilometres off came back
	// as a bank of daylight-blue cloud over an unlit horizon.
	ALBEDO = mix(body_color, haze_color * day, haze);
	EMISSION = iris * glow * iris_strength * day * mix(0.5, 1.0, region.y) * (1.0 - haze);
	// A deck seen from under the sea is seen through the sea, and the march above
	// already knows how much of it: `enter` was pushed out to where the ray leaves
	// the water, so it *is* the water in the way. Without this the weather was
	// drawn over a swimmer at full strength — the one thing visible from forty
	// metres down was clouds, which is also how the sea turned out not to be
	// covering the sky along the horizon.
	//
	// Only taken away, never washed: the wash belongs to whatever is behind the
	// cloud, and behind the cloud is the sky, which now draws its own. Adding it
	// here as well would lay it twice wherever there is weather, and a cloud gone
	// completely has to leave the sky's version showing — so the alpha goes with
	// the colour.
	float under = -vivid_altitude(origin);
	if (under > 0.0) {
		vec3 kept;
		vec3 unused_wash;
		vivid_sea_veil(enter, under, day, kept, unused_wash);
		ALBEDO *= kept;
		EMISSION *= kept;
		ALPHA *= kept.g;
	}
	// The rim is added to the opacity as well as to the colour. Alpha multiplies
	// the emission on its way into the frame, so a rim that is nearly clear puts
	// nearly none of its glow on screen — which is the one part of this that has
	// to be bright.
	ALPHA = clamp(alpha * body_alpha + rim * 0.2, 0.0, 1.0);
}
