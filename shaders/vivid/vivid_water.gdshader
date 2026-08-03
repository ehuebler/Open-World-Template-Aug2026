// The sea: one surface at sea level, drawn from both sides.
//
// The mesh handed to this is a flat disc lying in the tangent plane under the
// viewer, and the vertex stage bends it onto the sphere. That is the whole trick
// — the ocean is never a mesh of the planet, it is a patch that follows whoever
// is looking at it and lands on the exact radius the height field calls zero. So
// there is no seam, no LOD, and no chunk to keep in step with the terrain's.
//
// Where it stops and where it breaks are the two things it has to know about the
// land, and it finds both out by reading the depth the opaque pass already wrote
// rather than by being told: a fragment's water column is the sea-level radius
// less the radius of whatever is behind it. The waterline and every scrap of foam
// are then functions of that one number, so both follow the coast exactly without
// anything, on the CPU or the GPU, ever working out where the coast is — and the
// sea's edge is cut from the same surface the land is drawn from, which is what
// stops the two disagreeing. See "the chord gap" below for what happens when they
// do.
//
// [code]cull_disabled[/code] because a swimmer looks up at it.
// [code]depth_draw_always[/code] because the surface has to hide itself: a
// transparent sea that writes no depth is drawn all the way to the disc's rim,
// including the parts of it that are round the curve, and they pile up past the
// true horizon as a flat band with the rim's own polygons notched along the top.
// It costs nothing against the terrain, which is opaque and already drawn.
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_always, shadows_disabled,
	world_vertex_coords;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

uniform vec3 deep_color : source_color = vec3(0.03, 0.16, 0.38);
uniform vec3 shallow_color : source_color = vec3(0.10, 0.48, 0.60);
// How much of the sea bed shows through when looking straight down into it.
uniform float water_alpha : hint_range(0.0, 1.0) = 0.72;
// A grazing view of water is nearly a mirror, so both the colour and the opacity
// climb toward the horizon. This is the only thing giving the flat sea a shape.
uniform float fresnel_power : hint_range(1.0, 16.0) = 4.0;
uniform float glint_sharpness : hint_range(8.0, 512.0) = 180.0;
uniform float glint_strength : hint_range(0.0, 8.0) = 2.4;
// Ripples, in cycles per metre and metres per second of drift. Fine detail on
// top of the swell below, and normal only: at this scale a displacement would be
// smaller than the disc's own triangles anywhere but under the viewer's nose.
uniform float ripple_scale : hint_range(0.0, 4.0) = 0.35;
uniform float ripple_speed : hint_range(0.0, 8.0) = 0.7;
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.4;
// Where the ripples fade out, in metres. Past a few hundred they are finer than
// a pixel and turn into a field of noise that crawls as the camera moves; this
// is also most of what the sea costs to draw, and the fade takes the noise field
// out of the shader entirely for everything beyond it.
uniform float ripple_near = 80.0;
uniform float ripple_far = 500.0;
// How much of the planet's colour wheel the sea takes. The ripples fade out at a
// few hundred metres and this does not, so from orbit it is the only thing
// varying across the ocean — and what it varies in is bands, because that is the
// shape of the wheel. At anything above zero the sea is banded from space.
uniform float region_tint : hint_range(0.0, 1.0) = 0.0;
// What the night side keeps, so an unlit ocean is dark water and not a hole.
uniform float night_light : hint_range(0.0, 1.0) = 0.14;

// --- Swell --------------------------------------------------------------------
//
// Real displacement, and the height is an error budget before it is a taste
// setting: PlanetWater.depth_at measures the sea as an exact radius, so a crest
// stands this far above where swimming, buoyancy and the splash check all
// believe the surface is. Half a metre disappears inside the bob buoyancy
// already has on a 1.45 m body. A couple of metres would let you swim through
// air, and anything that wants that has to move the physics first.
uniform float swell_height : hint_range(0.0, 3.0) = 0.55;
// Crest to crest, in metres, for the longest of the three waves in the mix.
uniform float swell_length : hint_range(4.0, 200.0) = 24.0;
uniform float swell_speed : hint_range(0.0, 4.0) = 0.85;
// Where the swell flattens out, in metres. Past this a wavelength is a handful
// of pixels across and the sea reads as boiling rather than as moving; it is
// also where the disc's own rings grow longer than a wave and the displacement
// starts sampling itself.
uniform float swell_near = 500.0;
uniform float swell_far = 3000.0;

// --- The web ------------------------------------------------------------------
//
// The caustic net, which this shader draws twice: once as the flicker in the
// sun's glitter path on top, and once as the light on the underside of the
// surface for anyone swimming below it. The bed's own copy of the same net is
// drawn by `vivid_terrain`, and the shafts joining the two are drawn there too —
// all three read `vivid_caustic` at the same scale, so they are one net seen
// from three places rather than three effects that happen to look alike.
uniform float caustic_scale = 0.25;
uniform float caustic_speed : hint_range(0.0, 4.0) = 0.6;
// Twinkle: how hard the net breaks up the sun's glitter. At zero the glitter is
// the smooth specular a flat plane gives, which is the one thing a sea never
// looks like; the net is what turns it into points of light going on and off.
uniform float twinkle : hint_range(0.0, 8.0) = 3.2;
// Light on the underside, for a swimmer looking up. Snell's window is bright,
// and the net is what is written across it.
uniform float underlight : hint_range(0.0, 2.0) = 0.55;
// The water seen through, for a swimmer looking along it, comes from the murk
// globals in `vivid_lib`. They used to be a copy of the bed's own pair with a
// comment asking for the two to be kept equal — the sea bed and the underside of
// the sea meet at every shoreline, and two visibilities draw the horizon under
// water at two different distances.
// Where the net gives out, in metres. It is the finest thing here — filaments a
// few metres apart — so it goes before the ripples do.
uniform float caustic_near = 60.0;
uniform float caustic_far = 700.0;

// --- Under the floe ---------------------------------------------------------
//
// Where the polar cap is solid there is no sea to draw: PlanetShape lifts the
// arctic sea bed to PlanetShape.ICE_TOP and the terrain mesh takes the ice over
// as ordinary ground. The disc is still there underneath, and underneath is
// where it should stay — but a chunk's triangles are chords, and from orbit,
// where a chunk spans a kilometre or two, the mesh dips tens of metres inside
// the sphere it describes. The sea then shows through the ice in rings, which
// are the disc's own radial tessellation seen through the gaps.
//
// So the water gives way rather than being hidden. It fades out across the
// frost band, which is where the floe thins back into open sea anyway, and by
// the time the cap is solid there is nothing left to poke through.
uniform float floe_edge : hint_range(0.0, 1.0) = 0.9;
uniform float floe_solid : hint_range(0.0, 1.0) = 0.99;

// --- Surf -------------------------------------------------------------------
//
// White water where the sea shoals, driven entirely by the depth of the column
// under each fragment. Nothing here knows where the coastline is and nothing
// needs to: a band of constant depth *is* a line parallel to the shore, so the
// surf follows every bay, headland and river mouth exactly, and it keeps doing
// so when the terrain seed changes.
uniform vec3 foam_color : source_color = vec3(0.93, 0.97, 1.0);
uniform float surf_strength : hint_range(0.0, 1.0) = 1.0;
// Depth at which the wash off the sand gives out, in metres. This is the band
// that stays white whatever the waves are doing.
uniform float wash_depth : hint_range(0.0, 20.0) = 0.6;
// Depth at which a wave starts to feel the bottom. The surf zone is everything
// shallower than this, and it wants to be a small fraction of the 22 m shelf:
// these coasts shelve very gently, so a depth generous in metres is enormous on
// the ground, and at 9 m the whole shallows went over rather than the shore.
uniform float break_depth : hint_range(0.0, 60.0) = 3.5;
// Crest spacing, in metres of depth rather than of ground. That is not a
// shortcut: it crowds the breakers together on a steep shore and draws them out
// across a flat one, which is what a real coast does.
uniform float wave_spacing : hint_range(0.2, 20.0) = 0.9;
// Share of a wave that is white water. The rest is the trough, and it has to
// stay clear: foam that merely ramps between crests averages a third, and a
// third of white over dark water is not surf, it is grey.
uniform float crest_width : hint_range(0.05, 0.95) = 0.35;
// Crests arriving per second at any fixed depth. Negative rolls them back out.
uniform float surf_speed : hint_range(-2.0, 2.0) = 0.22;
// Break-up along the shore, so the bands read as stretches of surf and not as
// contour lines. It does not drift: what makes one stretch foamier than the next
// is the shape of the bed, which stays where it is.
uniform float surf_mottle : hint_range(0.0, 1.0) = 0.45;
uniform float surf_mottle_scale = 0.02;
// Where the surf fades out, in two stages, because it is two things at two
// scales and one fade cannot serve both.
//
// The crests go first and they have to go early. They are spaced by
// `wave_spacing` — under a metre of depth, and on a shelf this gentle only a few
// metres of ground — so they are the finest pattern anywhere in this project,
// and they are laid across the shore, which is the direction most foreshortened
// when a coast is looked down on from above. Past a few hundred metres there is
// less than a pixel per wave and what is drawn is not surf but the aliasing of
// surf: a row of white dashes hugging every coastline, which from a few
// kilometres up is the most visible thing on the planet. One fade at 1200 to
// 5000 m was what put them there.
//
// The wash outlasts them, because it is not a pattern at all — it is the band of
// white at the waterline, and a coast seen from a kilometre up does have a white
// line on it. It still ends well short of orbit: the band is under a metre of
// depth, the bed behind it comes from a depth buffer sampled `filter_nearest`
// off a chunk whose triangles are hundreds of metres wide out there, and past
// that finding a depth at all means differencing two numbers either side of 8 km.
uniform float crest_near = 120.0;
uniform float crest_far = 700.0;
uniform float surf_near = 600.0;
uniform float surf_far = 2500.0;
// How much of the caustic net goes into the white water. Foam is not a flat
// paint job — it is bubbles, and bubbles are lit by the same focused light that
// nets the sand under them, which is why surf sparkles and a white band does
// not. This puts the net into the crests and leaves the wash off the sand
// alone, so the shoreline itself stays solid white.
uniform float surf_caustic : hint_range(0.0, 2.0) = 0.7;
// Extra lift the swell gives a crest. A wave already breaking gets the last of
// its white from being the steepest thing on the shore.
uniform float surf_swell : hint_range(0.0, 2.0) = 0.6;
// What the opaque pass already put down, which is the sea bed. Nearest, because
// a depth interpolated across a silhouette is the distance to somewhere with
// nothing at it, and filtering would ring every rock and headland with foam.
uniform sampler2D depth_buffer : hint_depth_texture, filter_nearest;

// --- The chord gap ------------------------------------------------------------
//
// The disc is flat triangles bent onto a sphere at their corners, so between the
// corners the surface is a chord and it cuts *inside* the sphere — by
// (edge^2)/(8R) at the middle of a cell, which is millimetres under a swimmer
// and about four metres out at the rings the disc covers the horizon with.
//
// That gap is small in metres and enormous on a coast, because these shelves
// shelve very gently: four metres of depth is hundreds of metres of ground. So
// wherever the bed passes within the gap of sea level — which is every shore on
// the planet — the sea and the ground swapped places from cell to cell, and what
// that drew was a saw of whole disc cells along every coastline, alternating
// with the spokes. Seen from orbit it was the most visible thing on the planet.
//
// It cannot be tessellated away: halving the gap costs four times the mesh, and
// the gap grows with the disc's reach, so there is no size that settles it. It is
// fixed in two halves instead, and both are needed:
//
//  - the vertex stage lifts every vertex by its own cell's gap, so the surface
//    never falls *below* the sphere and the ground can no longer win a cell it
//    should have lost. On its own this floods the shore instead of notching it.
//  - the fragment stage cuts the sea back to the waterline using the bed's own
//    depth, read out of the buffer the opaque pass already wrote. The shoreline
//    is then decided by the one surface the land is also drawn from, at pixel
//    resolution, and the two cannot disagree.
//
// The lift is what a swimmer feels: it is at most a couple of centimetres at
// wading depth, where the disc is at its smallest, against a swell of half a
// metre and a buoyancy bob larger than either. `PlanetWater.depth_at` is still
// the exact radius and nothing here moves it.
//
// [code]SHORE_MARGIN[/code] covers the lift being interpolated across a cell
// while the dip it answers is not: at the middle of a cell the lift has fallen
// to the average of the corners just as the chord is at its deepest.
const float SHORE_MARGIN = 2.0;
// How far above sea level the bed is still cut from, as a multiple of the gap.
// It has to clear the lift and the terrain's own chords; past that it must stop,
// because a bed sampled *above* sea level is also what anything standing out of
// the water looks like from behind, and cutting the sea away from those would
// punch a hole in it around every pier and swimmer's head.
const float SHORE_WINDOW = 4.0;

varying vec3 v_world_position;
// How deep this vertex's own cell cuts inside the sphere, in metres. Read in the
// fragment stage as the width of the band the shoreline is cut from.
varying float v_shore_gap;
varying float v_reach;
varying float v_slope;
varying float v_span;
// Where this fragment's water sits before the swell lifts it, which is the one
// coordinate every field here is sampled at. Using the lifted position instead
// would let the waves modulate their own phase, and a wave that steepens itself
// keeps steepening.
varying vec3 v_sea_level;

void vertex() {
	// Straight onto the sphere, whatever the mesh was. A vertex 16 km out across
	// the tangent plane lands two thirds of the way to the horizon; one at the
	// centre barely moves.
	vec3 up = vivid_up(VERTEX);
	// Taken before the projection, off the flat disc: the tangent plane touches
	// the sphere under the viewer, so a vertex `r` out across it sits at
	// sqrt(R^2 + r^2) from the centre and this ratio is the cosine of the angle
	// it lands at. Which is all that is needed to turn the mesh's own spacing,
	// measured across the plane, into arc along the sphere: a radial step
	// foreshortens by that cosine twice and a step round the ring once.
	float slope = planet_radius / length(VERTEX - planet_center);
	vec2 arc = UV2 * length(MODEL_MATRIX[0].xyz) * vec2(slope * slope, slope);
	v_shore_gap = dot(arc, arc) / (8.0 * planet_radius) * SHORE_MARGIN;
	v_reach = length(MODEL_MATRIX[0].xyz);
	v_slope = slope;
	v_span = UV2.y;

	vec3 at = planet_center + up * planet_radius;
	v_sea_level = at;
	float lift = 0.0;
	if (swell_height > 0.0) {
		vec3 unused_slope;
		vivid_swell(at - planet_center, swell_length, swell_speed, lift, unused_slope);
		lift *= swell_height * (1.0 - smoothstep(swell_near, swell_far,
			distance(at, CAMERA_POSITION_WORLD)));
	}
	// The swell rides on top of the lift, not instead of it: one is a wave and the
	// other is the mesh apologising for being flat.
	VERTEX = at + up * (lift + v_shore_gap);
	NORMAL = up;
	v_world_position = VERTEX;
}

void fragment() {
	vec3 up = vivid_up(v_world_position);
	// Discarded rather than faded to nothing, so the frozen half of the disc
	// costs a dot product instead of a ripple field, a depth read and a surf.
	float floe = smoothstep(floe_edge, floe_solid, vivid_frost(up));
	if (floe >= 1.0) {
		discard;
	}
	vec3 to_eye = CAMERA_POSITION_WORLD - v_world_position;
	float range = length(to_eye);

	// The bed behind this pixel, as a depth of water rather than as a distance:
	// the sea-level radius less the radius of whatever the opaque pass left here.
	// Taken as a difference of radii, not as a length along the view ray, because
	// a slant path through shallow water is long and the ray version reads every
	// grazing pixel as shallow.
	//
	// This one number does both jobs the sea needs the land for — where it ends,
	// and where it breaks — and neither of them ever works out where the coastline
	// is. Depth clears to zero under reverse-Z, so a zero is open sky past the
	// limb: no bed behind the water at all.
	float under = 0.0;
	bool bedded = false;
	vec3 bed = vec3(0.0);
	float raw = texture(depth_buffer, SCREEN_UV).x;
	if (raw > 0.0) {
		vec4 probe = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
		bed = (INV_VIEW_MATRIX * vec4(probe.xyz / probe.w, 1.0)).xyz;
		under = planet_radius - length(bed - planet_center);
		bedded = true;
	}
	// The waterline, and the second half of what the chord gap above is about: the
	// lift put the whole surface above the sphere, and this takes back the ground
	// it flooded on the way. Only within the window, for the reason written there.
	if (false && bedded && under < 0.0 && -under < v_shore_gap * SHORE_WINDOW) {
		discard;
	}

	// The swell's own tilt, taken per pixel from the same field the vertex stage
	// displaced by. Interpolating the vertex normal instead would give the outer
	// rings — where one triangle is longer than a wavelength — the average slope
	// of a whole wave, which is nothing.
	vec3 surface = up;
	float heave = 0.0;
	if (swell_height > 0.0) {
		float swell_fade = 1.0 - smoothstep(swell_near, swell_far, range);
		if (swell_fade > 0.0) {
			vec3 slope;
			vivid_swell(v_sea_level - planet_center, swell_length, swell_speed,
				heave, slope);
			slope *= swell_height * swell_fade;
			// Tangential part only: the radial component of the gradient is the
			// wave field's own variation with altitude, which is not a slope.
			surface = normalize(up - (slope - up * dot(up, slope)));
			heave *= swell_fade;
		}
	}
	float close = 1.0 - smoothstep(ripple_near, ripple_far, range);
	surface = vivid_bump_normal(v_world_position + vec3(TIME * ripple_speed),
		surface, ripple_scale, ripple_strength * close);
	vec3 view = normalize(to_eye);
	// Against the shaped normal and not against the radial up, which is what
	// makes the swell visible at all. A wave lit only through its specular shows
	// up when the sun happens to be behind it and is a flat plane the rest of the
	// day; taking the fresnel off the same tilt turns every face toward the eye
	// dark and every face away from it pale, and the sea has a shape from any
	// angle in any light.
	//
	// Absolute, because from underneath the same surface is seen from the other
	// side and a signed dot would turn the whole sea inside out.
	float facing = abs(dot(surface, view));
	float grazing = pow(1.0 - facing, fresnel_power);
	vec3 sun = normalize(-sun_direction);
	float day = mix(night_light, 1.0, smoothstep(-0.2, 0.45, dot(up, sun)));

	// One caustic sample, spent three ways: it breaks up the glitter, it lights
	// the underside for a swimmer, and it goes into the surf below. Reading it
	// once and sharing it is the difference between a sea that costs one noise
	// pair per pixel and one that costs three.
	float web = 0.0;
	float near_web = 1.0 - smoothstep(caustic_near, caustic_far, range);
	if (near_web > 0.0 && (twinkle > 0.0 || underlight > 0.0 || surf_caustic > 0.0)) {
		web = vivid_caustic(v_sea_level, caustic_scale, caustic_speed) * near_web;
	}

	float glint = pow(max(dot(surface, normalize(view + sun)), 0.0), glint_sharpness);
	// Twinkling: the glitter path punched through by the net. The same bending
	// that throws filaments onto the bed tilts the facets up here, so the
	// sparkle belongs exactly where the net is and goes on and off with it.
	glint *= 1.0 + web * twinkle;

	vec3 color = mix(deep_color, mix(shallow_color, vec3(1.0), 0.35 * grazing), grazing);
	color = mix(color, color * vivid_region_light(up), region_tint);
	// Under the surface, looking up. Snell's window is the brightest thing a
	// swimmer can see and the net is written across it; above the water this is
	// nothing, because from up there the net is on the bed and the bed draws it.
	bool submerged = vivid_altitude(CAMERA_POSITION_WORLD) < 0.0;
	if (underlight > 0.0 && submerged) {
		color += vec3(0.55, 0.85, 1.0) * web * underlight * day;
	}

	float foam = 0.0;
	float reach = 1.0 - smoothstep(surf_near, surf_far, range);
	if (surf_strength > 0.0 && reach > 0.0 && bedded) {
		float shoal = 1.0 - smoothstep(0.0, break_depth, under);
		if (shoal > 0.0) {
			float wash = 1.0 - smoothstep(0.0, wash_depth, under);
			// Everything with a wavelength, faded as one: the crests, the swell
			// riding them, and the mottle that breaks them up along the shore.
			// What is left past this is the waterline.
			float rolling = 1.0 - smoothstep(crest_near, crest_far, range);
			float crest = 0.0;
			if (rolling > 0.0) {
				// One pulse of white water per wave, marching shoreward as TIME
				// advances. Overdriven so the middle of a crest saturates and
				// only its edges are a blend — a crest that merely peaks at
				// white is never actually white anywhere. It reaches zero at
				// both ends of the cycle, so the wrap needs no special care.
				float phase = fract(under / max(wave_spacing, 0.01)
					+ TIME * surf_speed);
				crest = clamp(1.7 * smoothstep(0.0, crest_width, phase)
					* (1.0 - smoothstep(crest_width, 1.0, phase)), 0.0, 1.0);
				// A crest riding the face of the swell breaks harder than one in
				// the trough, which is what ties the two together: without it
				// the surf marches up the beach on its own schedule while the
				// water it is made of moves to another.
				crest = clamp(crest * (1.0 + max(heave, 0.0) * surf_swell),
					0.0, 1.0) * rolling;
			}
			foam = max(wash, crest * shoal);
			float mottle = vivid_fbm3(v_world_position * surf_mottle_scale, 3);
			foam *= mix(1.0, clamp(2.1 * mottle - 0.2, 0.0, 1.4),
				surf_mottle * rolling);
			// The net into the crests and not into the wash. Bubbles are lit by
			// the same focused light that draws the net on the sand under them,
			// which is why real surf glitters; the wash along the waterline has
			// to stay solid white or the shoreline dissolves.
			foam *= 1.0 + web * surf_caustic * (1.0 - wash);
			foam = clamp(foam * surf_strength * reach, 0.0, 1.0);
		}
	}

	// Foam is lit by the whole sky and not by the sun alone, so it holds its
	// brightness far later into the evening than the water under it: the same
	// terminator, opened up at both ends. Tying it to `day` instead caps the
	// foam at whatever a low sun gives — measured at 0.53 on the test coast,
	// which is grey, and grey is the one thing white water cannot be. It still
	// falls to night_light on the dark side, so an unlit shore is not a beacon.
	float sky = mix(night_light, 1.0, smoothstep(-0.55, 0.15, dot(up, sun)));
	ALBEDO = mix(color * day + glint * glint_strength * day, foam_color * sky, foam);
	ALPHA = mix(mix(water_alpha, 1.0, grazing), 1.0, foam) * (1.0 - floe);
	// The same water the bed is fogged by, applied to the surface a swimmer sees
	// it through. Alpha goes with it: past the visibility there is no surface
	// left to see, only the water in front of it.
	//
	// The wash is dimmed by the daylight left in the water it is made of, which is
	// what a swimmer's up is made of in turn: this surface is at depth nothing and
	// the eye is at whatever depth it is, so the water in between is lit from half
	// of it — always brighter than the water down toward the bed, however dark
	// either gets. Without it the sea a hundred metres down was drawn in the same
	// wash as the sea at the beach, and a dive had no bottom and no top.
	// R: the lift this fragment's water was given, over 40 m. G: how far the bed
	// behind it stands above sea level, same scale. B is pinned at one so a sample
	// can be told from the ground and the weather, which are also in the frame.
	// R: the sine of the angle between the view ray to this fragment and the view
	// ray to the point the depth sample was reconstructed at, times a hundred. A
	// reconstruction that landed on the right ray reads zero. G: whether that
	// sample is nearer than the fragment, half being equal and above half meaning
	// the sample is in front of water that was drawn anyway.
	ALBEDO = vec3(clamp(length(cross(normalize(bed - CAMERA_POSITION_WORLD),
		normalize(-to_eye))) * 100.0, 0.0, 1.0),
		clamp((raw - FRAGCOORD.z) * 25000000.0 + 0.5, 0.0, 1.0), 1.0);
	ALPHA = 1.0;
	if (submerged) {
		vec3 murk = vec3(1.0) - exp(-vec3(range) / (murk_visibility * murk_channels));
		// Weighted toward the near end of the run, for the reason written where the
		// bed does the same. This end of it is the surface, at depth nothing, so the
		// water in front of a swimmer looking up is always lit from shallower than
		// they are — and the water in front of one looking down, from deeper.
		float toward = 0.5 * min(murk_visibility, range) / max(range, 0.001);
		float column = vivid_daylight(
			-vivid_altitude(CAMERA_POSITION_WORLD) * (1.0 - toward), murk_daylight);
		ALBEDO = mix(ALBEDO, murk_color * column * mix(night_light, 1.0,
			smoothstep(-0.05, 0.35, dot(up, sun))), murk);
		ALPHA = mix(ALPHA, 1.0, murk.g) * (1.0 - floe);
	}
}
