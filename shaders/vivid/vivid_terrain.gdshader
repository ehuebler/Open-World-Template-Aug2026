// The planet's ground.
//
// Terrain arrives as bare vertex colour: PlanetShape decides the biome on the
// CPU and writes it per vertex, with the water depth in alpha. That is a few
// hundred metres between colour samples on a coarse chunk, so everything that
// makes the ground read as ground at walking distance has to be added here —
// grain, macro variation, slope, wetness and the bumps that catch light.
//
// Colour comes from three places that are deliberately kept apart:
//   the biome     what kind of ground this is, from the vertex colour
//   the region    where it sits on the planet's colour wheel, from vivid_lib
//   the light     which is Godot's own PBR, not a custom light() function
//
// Keeping the light real is what stops the vivid palette from reading as a
// cartoon: the hues are exaggerated, the shading underneath them is not.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"

group_uniforms Ground;
// Pushed past 1 on purpose. The biome colours are chosen to stay legible as a
// map; this is what makes them a place rather than a legend.
uniform float saturation : hint_range(0.0, 3.0) = 1.5;
// Held well below 1 because the sky is also the ambient light: sun plus sky
// bounce puts far more light on the ground here than the single directional
// light the old look was tuned against, and an albedo near 1 washes out before
// the tonemapper gets a say.
uniform float brightness : hint_range(0.0, 2.0) = 0.6;
uniform float ground_roughness : hint_range(0.0, 1.0) = 0.9;
// Ground reflects the sky as well as being lit by it, and at this roughness that
// reflection is a broad white sheen over the whole landscape rather than a
// highlight. Dirt is not shiny; the water below has its own value for this.
uniform float ground_specular : hint_range(0.0, 1.0) = 0.16;
group_uniforms;

group_uniforms Detail;
// Cycles per metre. 0.35 puts one patch of variation every ~3 m, which is the
// scale a walking player reads as texture rather than as stains.
uniform float detail_scale = 0.35;
uniform float detail_amount : hint_range(0.0, 1.0) = 0.3;
// Tens of metres, so a hillside is not one flat wash of the same green.
uniform float macro_scale = 0.014;
uniform float macro_amount : hint_range(0.0, 1.0) = 0.4;
uniform float bump_scale = 0.9;
uniform float bump_strength : hint_range(0.0, 1.0) = 0.35;
// Detail costs three noise fields per pixel and aliases into shimmer once one
// bump is smaller than a pixel, so it is faded out with distance instead.
// Procedural noise has no mip chain to fall back on, which is why the fade has
// to be explicit and why the macro field needs one of its own: from orbit its
// 70 m blotches are smaller than a pixel and boil into speckle.
uniform float detail_near = 40.0;
uniform float detail_far = 260.0;
uniform float macro_near = 1500.0;
uniform float macro_far = 9000.0;
group_uniforms;

group_uniforms Ground_Texture;
uniform sampler2D ground_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float ground_texture_scale = 0.25;
uniform float ground_texture_blend : hint_range(0.0, 1.0) = 0.0;
group_uniforms;

group_uniforms Cliffs;
uniform vec3 cliff_color : source_color = vec3(0.42, 0.35, 0.34);
uniform float cliff_start : hint_range(0.0, 1.0) = 0.22;
uniform float cliff_end : hint_range(0.0, 1.0) = 0.55;
uniform float cliff_roughness : hint_range(0.0, 1.0) = 0.95;
group_uniforms;

group_uniforms Water;
// Water is the one surface here that is smooth, and a smooth surface is where
// the sun and the region's colour actually get to reflect off something.
uniform float water_roughness : hint_range(0.0, 1.0) = 0.06;
uniform float water_specular : hint_range(0.0, 1.0) = 0.9;
uniform vec3 water_deep_tint : source_color = vec3(0.05, 0.32, 0.62);
// The sea bed as a diver sees it, which is not what the vertex colour under the
// waterline says — see where these are used. Sand to silt over [code]bed_reach[/code]
// metres of depth.
// Held near neutral. Everything downstream of it pushes chroma — `saturation` at
// 1.5, then the region's own hue at nearly half strength — and a sand written as
// sand comes out of the pair of them as lime.
uniform vec3 bed_shallow : source_color = vec3(0.70, 0.68, 0.59);
uniform vec3 bed_deep : source_color = vec3(0.30, 0.33, 0.32);
uniform float bed_reach : hint_range(10.0, 500.0) = 170.0;
// Share of the ground's metre-scale bump the bed keeps. Silt and sand are the
// smoothest ground on the planet, and shading them like scree is what the sea bed
// used to be: a flat plain lit at a grazing angle, where a bump that size does not
// read as texture but as broad plates with the light terminator running along their
// edges. Its albedo grain and the slope under it carry the shape instead.
uniform float bed_bump : hint_range(0.0, 1.0) = 0.3;
uniform float wave_scale = 1.6;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.16;
uniform float wave_speed = 0.09;
group_uniforms;

group_uniforms Caustics;
// The net of light on the sea bed, and the shafts of it hanging in the water
// above. Both come out of `vivid_caustic`, which is also what the sea's own
// surface twinkles with — one field, read from three places, so the web on the
// sand is the web glittering on the water over it. Do not retune the scale here
// alone: it has a twin in `planet_water.tres` and they have to agree.
uniform vec3 caustic_color : source_color = vec3(0.62, 0.95, 1.0);
uniform float caustic_scale = 0.25;
uniform float caustic_speed : hint_range(0.0, 4.0) = 0.6;
uniform float caustic_strength : hint_range(0.0, 4.0) = 0.7;
// Depth the net gives out at, in metres. Focused light is what makes it, and a
// surface only stays a lens for as long as its bends have not spread past each
// other — which on real water is about a dozen metres.
uniform float caustic_depth : hint_range(1.0, 80.0) = 14.0;
uniform float caustic_near = 60.0;
uniform float caustic_far = 700.0;
// Shafts, and they are only paid for when the camera is under the water: above
// it there is nothing between the eye and the bed to light up. Metres of the
// view ray marched, and the depth the shafts fade out at.
uniform float shaft_strength : hint_range(0.0, 4.0) = 0.8;
uniform float shaft_reach = 90.0;
uniform float shaft_depth : hint_range(1.0, 200.0) = 40.0;
// The water itself, seen from inside it, comes from the murk globals in
// `vivid_lib` — one set for every surface the sea stands in front of. Without it
// the sea has no body: the bed is as crisp at six hundred metres as at six, and
// shafts drawn through nothing are just a second net laid over the first. It is
// also what a shaft is *made* of, which is why the shafts below are weighted by
// it.
//
// Applied as an emissive fog rather than as a tint on the albedo, because a tint
// would be shaded: ground in shadow would look through clear water and ground in
// the sun through murk.
//
// What the fog takes from the bed is contrast, and contrast is the only thing a
// shape is made of: a bed with a hundred metres of sea in front of it keeps under
// half of its own colour and the wash supplies the rest as one flat sheet, so its
// grain and its slopes arrive at under half strength. This is how much of that
// the ground's own variation is stretched back up by, as a share, and how far the
// stretch is allowed to go.
//
// An eye and not a photon, and worth being honest about. A diver is adapted to
// the wash they are looking through and read what varies against it; a camera at
// a fixed exposure records the wash and loses the rest, and this shader is a
// camera. Only the variation is stretched and never the level, so the bed still
// fades into the water at the distance it did and a trench is still a trench.
uniform float murk_relief : hint_range(0.0, 1.0) = 0.85;
uniform float murk_relief_limit : hint_range(1.0, 4.0) = 3.0;
group_uniforms;

group_uniforms Region;
// How much of the region's hue is mixed into the ground's own colour. This is
// the honest half of the effect and carries most of it: ground really is a
// different colour there.
//
// Set against the sky, which takes its hue from the same wheel at close to full
// strength. The ground cannot go that far — the biome colours are what say sea
// from shore from grass from snow, and past about half they stop saying it — so
// the two do not match, and are not meant to. The sky states the region and the
// ground agrees with it.
uniform float region_albedo : hint_range(0.0, 1.0) = 0.45;
// A grazing-angle sheen in the region's hue. The showy half, and the one that
// has to be kept small: a landscape running to the horizon is nearly all
// grazing angle, so anything generous here is a wash over the whole frame
// rather than a highlight on the edge of a hill.
uniform float region_sheen : hint_range(0.0, 2.0) = 0.18;
// Concentrates that sheen onto true silhouettes. Below about 6 it starts
// reaching the middle distance and reads as fog.
uniform float sheen_falloff : hint_range(1.0, 12.0) = 8.0;
// Off by default, and worth understanding before turning up. Godot's rim is a
// grazing-angle term, and on a landscape running to the horizon almost every
// pixel is a grazing angle — it is a white wash over the whole frame here, not
// the highlight along an edge that it is on a prop.
uniform float region_rim : hint_range(0.0, 1.0) = 0.0;
// What is left of the wheel inside the polar cap. Snow is white, and white is
// the one biome colour that has nothing to spare: the wheel at full strength
// turns a whole ice sheet into a pastel one and the arctic stops reading as
// arctic. A little is kept so the pole still belongs to the same planet.
uniform float region_polar : hint_range(0.0, 1.0) = 0.22;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;

void vertex() {
	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 position = v_world_position;
	vec3 normal = normalize(v_world_normal);
	vec3 up = vivid_up(position);
	vec3 view = normalize(CAMERA_POSITION_WORLD - position);
	// Alpha is how wet the ground is, and all this asks of it is whether it is wet
	// at all — the ripples and the sheen that belong on a wet surface. How deep the
	// water runs is measured from the geometry below rather than read off here,
	// because a vertex knows the depth under itself and not the depth a pixel is
	// looking through.
	float wetness = COLOR.a;
	float water = smoothstep(0.0, 0.16, wetness);
	float range = length(CAMERA_POSITION_WORLD - position);
	float detail_fade = 1.0 - smoothstep(detail_near, detail_far, range);
	float macro_fade = 1.0 - smoothstep(macro_near, macro_far, range);

	// Metres of sea between the eye and this point, and how much of the view that
	// column costs, per channel. Everything the water does to this fragment is
	// worked out from this and from the depth of water over the point itself; both
	// are used further down, and why they are lengths rather than a submerged flag
	// is written there.
	float wet_path = vivid_sea_path(CAMERA_POSITION_WORLD, position);
	vec3 haze = vec3(1.0) - exp(-vec3(wet_path) / (murk_visibility * murk_channels));
	bool submerged = vivid_altitude(CAMERA_POSITION_WORLD) < 0.0;
	// How far under the sea this ground is. Used three times below — for the colour
	// of the bed, the daylight reaching it, and the net drawn on it — and read off
	// the geometry rather than off the vertex alpha for the reason given there.
	float under = -vivid_altitude(position);

	// Wet ground is drawn as the sea's own surface — smooth, and with no grain,
	// rock or slope shading of its own — because from outside the water that is
	// what it stands in for. From inside the water it is the sea bed, and the sea
	// bed is ground: it has sand, it has rock where it is steep, and it catches
	// light on its bumps like everything else does. Masking all of that with the
	// wetness alone is what left a diver looking at a floor of flat blue with no
	// shape anywhere in it.
	//
	// So the mirror reading and the ground reading are one switch, and it turns on
	// the eye rather than on the paint. Above the water `sheen` is `water` to the
	// last decimal, which is what it was.
	float sheen = water * (submerged ? 0.0 : 1.0);
	float dry = 1.0 - sheen;
	// The other half of that switch: wet ground with the eye in the water is a sea
	// bed, and it is the one thing here that needs a colour of its own.
	float bed = water - sheen;
	// How much the ground's own variation is stretched to stand against the wash in
	// front of it — see where the two uniforms are declared for why it is stretched
	// at all. Zero above the water, where the fog is a tint on the sea rather than
	// the air the eye is in, and where `dry` has the detail switched off anyway.
	float relief = submerged
		? min(mix(1.0, 1.0 / max(1.0 - haze.g, 0.05), murk_relief), murk_relief_limit)
		: 1.0;

	vec3 albedo = vivid_saturate(COLOR.rgb, saturation) * brightness;

	// The sea bed's own colour, for the eye that is down there with it.
	//
	// Under the waterline the vertex colour is the sea as a *map* draws it: two
	// blues, chosen by depth and chosen to be told apart from orbit. That is the
	// right answer from outside the water and the wrong one from a metre away — it
	// puts a diver on a floor whose only variation is the noise laid over it, and
	// noise over flat blue reads as flat blue with noise on it, which is precisely
	// the missing topography this is here for. Sand where the light still reaches,
	// silt where it does not, and the slope test below still finds rock on anything
	// steep.
	//
	// Swapped here and not in PlanetShape.color_at, because that colour is what the
	// sea is drawn as from every vantage outside it, up to and including orbit, and
	// a sandy shelf seen from the air is a beach.
	vec3 floor_color = mix(bed_shallow, bed_deep, smoothstep(0.0, bed_reach, under));
	albedo = mix(albedo, vivid_saturate(floor_color, saturation) * brightness, bed);

	// Slope against the planet's own up, not against world up: on a sphere those
	// are the same thing only at one point.
	float slope = 1.0 - clamp(dot(normal, up), 0.0, 1.0);
	float cliff = smoothstep(cliff_start, cliff_end, slope) * dry;
	albedo = mix(albedo, vivid_saturate(cliff_color, saturation), cliff);

	// Two scales of breakup. The macro field is the one that matters at range —
	// without it a hillside is a single flat wash whatever the detail does.
	// Floored, because `relief` can push either amount past 1 and a mix past 1 is
	// an extrapolation: at a strong enough stretch the dark half of a field would
	// otherwise cross zero and start brightening the ground again.
	float macro = vivid_fbm3(position * macro_scale, 4);
	albedo *= max(mix(1.0, 0.6 + 0.8 * macro,
		macro_amount * dry * macro_fade * relief), 0.0);
	float grain = vivid_fbm3(position * detail_scale, 3);
	albedo *= max(mix(1.0, 0.65 + 0.7 * grain,
		detail_amount * dry * detail_fade * relief), 0.0);

	if (ground_texture_blend > 0.0) {
		vec3 weights = vivid_triplanar_weights(normal, 4.0);
		vec3 sampled = vivid_triplanar(ground_texture, position, weights, ground_texture_scale);
		albedo = mix(albedo, albedo * sampled * 2.0, ground_texture_blend * dry);
	}

	// What daylight is left this far down. Light going down a column is spent at
	// much the same sort of rate as sight along one, so a bed four hundred metres
	// under is not sunlit sand a long way off: it is unlit. Applied here, before the
	// water in front of it — that order is the whole of it, because the tint below
	// stands for the sea itself, and the sea is as bright as its own surface however
	// dark the bed under it is. The other way round turns deep ocean seen from the
	// air black.
	float sunk = vivid_daylight(under, murk_daylight);
	albedo *= sunk;

	// Water looked into from outside it. The more of it stands in front of the bed,
	// the less of the bed's own colour survives and the more of the sea's is left,
	// so a lagoon reads as sand under glass and a trench reads as sea.
	//
	// Measured off the column rather than lerped from the painted depth in the
	// vertex alpha, which is what this was. Same intent, but the alpha is a map of
	// how deep the water is under a *vertex* while the column is how much of it a
	// *pixel* is looking through — so the painted version tinted a bay by the same
	// amount from directly overhead as from a kilometre away along the surface, and
	// looking down into shallow water got no water in the way at all. The result
	// was ground in a slightly odd colour, which is exactly what it looked like.
	vec3 shoal = submerged ? vec3(0.0) : haze;
	albedo = mix(albedo, vivid_saturate(water_deep_tint, saturation), shoal);

	vec2 region = vivid_region(up);
	vec3 region_color = vivid_spectrum(region.x);
	// The spectrum averages 0.5 a channel, so doubling it swings the hue while
	// leaving the ground about as bright as it was. Saturating the result again
	// on top of that is what turned the first pass of this into fluorescent
	// paint; the hue shift is enough on its own.
	float region_strength = region_albedo * mix(0.35, 1.0, region.y)
		* mix(1.0, region_polar, vivid_frost(up));
	albedo = mix(albedo, albedo * region_color * 2.0, region_strength);

	// Normals: waves on the water, ground grain on the land. Both are worth more
	// than any amount of albedo detail, because they are what makes light move
	// across the surface as the camera does.
	vec3 shaped = normal;
	if (bump_strength > 0.0 && detail_fade > 0.0) {
		// Not stretched by `relief`. That number is a contrast, and a bump is not:
		// tilting the normal harder does not scale the ground's variation about its
		// own mean, it drives `normalize` toward the noise gradient's own direction,
		// which is near enough constant across a cell. At three times the strength
		// the bed came out as a plaid of flat facets one noise cell wide — more
		// shape in the numbers and less of it in the picture.
		shaped = vivid_bump_normal(position, shaped, bump_scale,
			bump_strength * dry * detail_fade * mix(1.0, bed_bump, bed));
	}
	if (wave_strength > 0.0 && sheen > 0.0 && detail_fade > 0.0) {
		vec3 drift = vec3(TIME * wave_speed, TIME * wave_speed * 0.63, 0.0);
		shaped = vivid_bump_normal(position + drift, shaped, wave_scale,
			wave_strength * sheen * detail_fade);
	}

	// The water column, read the other way. Inside the sea it is fog around the eye:
	// it takes the ground away and puts a lit wash in its place. From outside it is
	// the sea's own colour over the bed, which is the `shoal` mix further up. One
	// length, two readings, never both at once.
	//
	// That length is the whole reason looking down into a bay reads as water rather
	// than as oddly blue grass. It used to be a test of whether the *camera* was
	// under the surface, which is cheap and wrong in the common case: from a beach
	// or from the air every metre of sea between the eye and the bed counted for
	// nothing, so a lagoon and a trench were drawn with the same clarity and the
	// only thing marking either as wet was a sheen on it.
	//
	// Neither reading is masked by `water`: where the ground sits relative to sea
	// level is a fact, and what colour it was painted is not part of it.
	//
	// Caustics and the shafts feeding them are light rather than paint, so they go
	// into emission and are scaled by how high the sun is — a net on the bed at
	// midnight is a glowing sea floor, which is the one thing worse than no net at
	// all — and the net fades out as the column thickens, because a bed nobody can
	// see cannot have a pattern on it.
	vec3 caustic_light = vec3(0.0);
	vec3 murk = submerged ? haze : vec3(0.0);
	// The scalar reading of it, for the three things that are one number rather
	// than three: how rough the fog is, how much specular is left behind it, and
	// how much water a shaft has to be scattered out of. Green, because green is
	// the channel the single-rate version was written as.
	float murk_dim = murk.g;
	// The wash is lit by the water standing between the eye and here — but not by
	// all of it evenly. What is seen of a column is almost entirely its near end,
	// because the far end is behind the rest of it, so the depth it is lit at is
	// the depth about a visibility along the ray and not the depth halfway to a bed
	// four hundred metres off. The midpoint of the whole run was the first go at
	// this and it read every downward view in deep water as unlit black.
	//
	// It is still what puts a gradient in a view under the sea: the water toward
	// the surface is lit from shallower than the eye and the water toward the bed
	// from deeper, so a diver has an up before anything in the frame has a shape.
	float toward = 0.5 * min(murk_visibility, wet_path) / max(wet_path, 0.001);
	float column = vivid_daylight(
		mix(-vivid_altitude(CAMERA_POSITION_WORLD), under, toward), murk_daylight);
	float noon = smoothstep(-0.05, 0.35, dot(up, normalize(-sun_direction)));
	// Shafts stay a thing seen from *inside* the water, unlike everything else here.
	// You see a shaft because you are in the medium doing the scattering and are
	// looking along it; from above there is nothing to look along, and the honest
	// version of the view — sunlight going in, and coming back only where it has a
	// bed to bounce off — is the blue column and the net, which are already here.
	// Marching them from above put a bright net over a five-hundred-metre trench,
	// which read as a reef in water a few feet deep, and charged six noise samples
	// for every ocean pixel on the planet to do it.
	if (murk_dim > 0.0 && shaft_strength > 0.0 && noon > 0.0) {
		// Weighted by the murk, because a shaft is the light scattered out of the
		// water in its path and there is exactly as much of that as there is water.
		// It also puts the shafts where they read: over the far bed, which the fog
		// has taken down to a flat wash.
		//
		// And by the daylight in that water, for the same reason the wash is: a
		// shaft is one part of the light in the column and cannot be brighter than
		// the column it is in. Without it the shafts held full strength at any
		// depth and became the whole of the picture down there — bright swirls
		// painted across a flat panel, which is the one thing a deep dive is not.
		caustic_light += caustic_color * shaft_strength * noon * murk_dim * column
			* vivid_sea_shafts(CAMERA_POSITION_WORLD, position,
				caustic_scale, caustic_speed, shaft_reach, shaft_depth);
	}
	if (under > 0.0 && noon > 0.0 && caustic_strength > 0.0) {
		float web_fade = (1.0 - smoothstep(caustic_near, caustic_far, range))
			* (1.0 - smoothstep(0.0, caustic_depth, under)) * (1.0 - haze.g);
		if (web_fade > 0.0) {
			caustic_light += caustic_color * caustic_strength * noon * web_fade
				* vivid_caustic(position, caustic_scale, caustic_speed);
		}
	}

	float fresnel = pow(1.0 - clamp(dot(shaped, view), 0.0, 1.0), sheen_falloff);

	// Fogging in two halves: the ground is taken away and the water is put in its
	// place. Killing the albedo is what stops the fog being lit — the shading
	// still runs, but there is nothing left for it to shade.
	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0)) * (1.0 - murk);
	NORMAL = vivid_to_view(VIEW_MATRIX, shaped);
	// Under water, the sea bed is sand and not a mirror.
	//
	// Wet ground is written as smooth and specular so that an ocean seen from
	// above has a sheen on it at the ranges the sea's own ripples have faded out
	// at. From inside the water that reading is simply wrong — the mirror is the
	// surface overhead, which is drawn separately — and it costs the whole view:
	// a bed at 0.9 specular and 0.06 roughness returns the sky whatever is put in
	// front of it, so the murk took the albedo down to nothing and the bottom
	// stayed as bright as an unfogged one, with the sun burnt into it.
	//
	// This one really is about the eye and not about the column: the mirror is a
	// reading of the surface, and from below there is no surface here to read. It
	// is the same switch the ground detail above is gated on.
	ROUGHNESS = mix(mix(mix(ground_roughness, cliff_roughness, cliff),
		water_roughness, sheen), 1.0, murk_dim);
	SPECULAR = mix(ground_specular, water_specular, sheen) * (1.0 - murk_dim);
	METALLIC = 0.0;
	// Godot's rim is lit by the real lights, so it reads as the sun catching the
	// edge of a hill. The emission beside it is not, which is what keeps a
	// gleaming region visible on the night side as a faint aurora.
	RIM = region_rim * mix(0.4, 1.0, region.y) * (1.0 - murk_dim);
	RIM_TINT = 0.35;
	EMISSION = region_color * fresnel * region_sheen * region.y * mix(0.35, 1.0, water + 0.35)
		* (1.0 - murk_dim)
		+ murk_color * murk * mix(0.06, 1.0, noon) * column
		+ caustic_light;
}
