// Anything that grows out of the ground and bends: flowers, grass, ferns, the
// scrub on a hillside. Drawn by [GroundCover] as MultiMesh tiles, thousands of
// instances to a draw call, so every per-plant decision this shader can make is
// a decision the CPU does not have to make for each of them.
//
// It makes three:
//
//   the bend      wind, and anyone walking through. A plant is a rod hinged at
//                 the ground, so both are one rotation about the base with the
//                 vertex's own height as the lever arm. No bones, no per-plant
//                 state, no script running on ten thousand nodes.
//   the thinning  a plant carries a rank, and past a distance only the low
//                 ranks are drawn. This is the whole of the LOD: the far half
//                 of a field is not drawn dimmer or simpler, it is not there.
//                 GroundCover computes the same curve per tile and stops
//                 submitting the instances that would fail it, so the vertex
//                 stage is not being paid to discard them either.
//   the variation two plants from the same mesh at the same size are a tiling
//                 pattern. Phase, tint and stiffness come off the instance's
//                 custom data, which costs one vec4 per plant and nothing per
//                 frame.
//
// The look is vivid_surface's, minus every field of it: a plant is centimetres
// across and vivid_surface's relief is authored in cycles per metre, so all of
// it would land as one wash of noise across a whole bloom. What is left is the
// authored color-paint PNG, semantic vertex colour, the region wheel and the
// light. The paint carries deliberate broad markings rather than relief noise,
// so it survives minification without making a field shimmer.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/vivid/vivid_lib.gdshaderinc"
#include "res://shaders/vivid/vivid_vat.gdshaderinc"

// The weather, in world space, written by GroundCover. Global rather than
// per-material because a gust crossing a hillside has to cross every species on
// it together; two materials with their own wind is two fields of plants
// blowing different ways in the same breeze.
global uniform vec3 wind_direction;
global uniform float wind_strength;
// Where the picture is being drawn from. Not CAMERA_POSITION_WORLD, which in the
// shadow pass is the light: thinning against that draws shadows for plants that
// were never drawn, scattered across ground that has none.
global uniform vec3 viewer_point;
// Whoever is walking through, as xyz position and w reach in metres. w at zero
// is an empty slot. Four, because the fifth nearest person to any one plant is
// not going to be inside its reach.
global uniform vec4 walker_0;
global uniform vec4 walker_1;
global uniform vec4 walker_2;
global uniform vec4 walker_3;

group_uniforms Fill;
uniform vec3 base_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float saturation : hint_range(0.0, 3.0) = 1.35;
uniform float brightness : hint_range(0.0, 2.0) = 1.0;
// Spread of brightness across the field, as a fraction either way. A stand of
// identical plants reads as one object repeated; a stand where some are a
// quarter darker reads as a stand.
uniform float tone_variation : hint_range(0.0, 0.8) = 0.22;
group_uniforms;

group_uniforms Surface;
uniform float roughness : hint_range(0.0, 1.0) = 0.55;
uniform float specular : hint_range(0.0, 1.0) = 0.4;
// Light coming through a petal from behind, which is most of what tells a thin
// growing thing from a painted one at this distance.
uniform float translucency : hint_range(0.0, 2.0) = 0.45;
group_uniforms;

group_uniforms ColorPaint;
// Every generated biome model keeps COLOR_0 as its semantic mask and receives
// a separate PNG on TEXCOORD_0 for the visible paint. The external texture is
// bound per PlantSpecies rather than imported from the GLB, because
// GroundCover's material override is what makes thousands of instances batch.
uniform bool color_paint_enabled = false;
uniform sampler2D color_paint : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float color_paint_strength : hint_range(0.0, 1.0) = 1.0;
group_uniforms;

group_uniforms PaintEmission;
// Generated luminous geology stores a broad, mip-safe tattoo/crystal mask in
// the color-paint PNG's alpha channel. RGB remains ordinary visible paint.
// Keeping the mask in that already-bound texture preserves one draw call and
// means a regenerated rock cannot accidentally lose the pattern it emits by.
uniform bool emission_from_paint_alpha = false;
// Day emission is independent of local night. Crystals can therefore remain
// green or cyan under the sun, while rune stones leave this at zero and wake
// only through NightEmission below.
uniform vec3 day_emission_color : source_color = vec3(0.0);
uniform float day_emission_energy : hint_range(0.0, 8.0) = 0.0;
uniform float day_emission_albedo : hint_range(0.0, 1.0) = 0.2;
group_uniforms;

group_uniforms Region;
uniform float region_albedo : hint_range(0.0, 1.0) = 0.3;
uniform float region_sheen : hint_range(0.0, 2.0) = 0.35;
uniform float region_rim : hint_range(0.0, 1.0) = 0.4;
group_uniforms;

group_uniforms Camera_Rim;
uniform vec3 camera_rim_color : source_color = vec3(0.20, 1.0, 0.58);
// Thin grass and leaves can be edge-on across their whole visible area. Keep
// their emission below a character's so a field gains outlines, not a white
// emissive carpet.
uniform float camera_rim_energy : hint_range(0.0, 8.0) = 0.35;
uniform float camera_rim_dark : hint_range(0.0, 1.0) = 0.68;
uniform float camera_rim_light : hint_range(0.0, 1.0) = 0.84;
// Optional specular-style filtering for sub-pixel growth. Ordinary flora keeps
// the rim at every range; dense grass overrides this so its edge energy is
// folded away before individual blades turn into one-pixel sparkles.
uniform float camera_rim_fade_from = 10000.0;
uniform float camera_rim_fade_to = 10001.0;
group_uniforms;

group_uniforms Shape;
// Height of the mesh as it was authored, in metres, base at the origin and
// growing up +Y. GroundCover writes it from the mesh's own bounds, so a new
// plant needs nothing set here.
uniform float stem_height = 1.3;
// How the bend is shared up the stem. 1 is a rod hinged at the ground and
// perfectly straight; higher leaves the bottom of the plant standing and puts
// the curve in the top, which is what a stem with a thick base does.
uniform float rigidity : hint_range(1.0, 4.0) = 1.9;
group_uniforms;

group_uniforms VertexAnimation;
uniform bool vat_enabled = false;
uniform sampler2D vat_positions : filter_nearest, repeat_disable;
uniform float vat_frame_count = 1.0;
uniform float vat_fps = 24.0;
uniform float vat_playback_speed = 1.0;
uniform vec3 vat_delta_min = vec3(0.0);
uniform vec3 vat_delta_max = vec3(0.0);
// How much of the baked clip's phase is drawn per plant rather than taken from
// where the plant stands.
//
// At 1 every plant starts its loop at an unrelated point, which is the obvious
// thing to do and is wrong at this density. Two blades of grass a pixel apart
// are then swinging opposite ways at rather better than one cycle a second, and
// what the pixel between them shows is neither blade but the two of them
// beating against each other. Nothing legible travels across the field, so it
// does not read as wind — it reads as the ground boiling, which is very close to
// how it was reported. Measured with the camera pinned at the colony ship, the
// baked sway alone was 96 percent of everything that changed between frames;
// the wind bend on top of it was not measurable at all.
//
// Most of the phase therefore comes from `gust_length`, the same travelling
// crests the wind bend uses, so the clip ripples across a field in step with the
// bend instead of against it. What is left is per plant, because a wave with no
// scatter at all in it is a sheet of identical grass and reads as machinery.
uniform float sway_scatter : hint_range(0.0, 1.0) = 0.25;
group_uniforms;

group_uniforms Wind;
// Where the motion is given up, in metres from `viewer_point`. Both the wind
// bend and the baked clip fade to nothing across this band, and past it the
// field stands in its rest pose.
//
// A blade is a few millimetres across, which is under one pixel from about
// eight metres out. Sub-pixel geometry that moves does not read as movement: it
// reads as the pixel changing its mind, because what is moving is not the blade
// across the screen but which fragments the blade happens to win. Far grass
// therefore costs the whole flicker of an animated field and returns none of
// the life, and the further off it is the worse that trade gets.
//
// What this does *not* do is remove anything that can be seen. Every blade is
// still drawn, still where it was and still as dark, so a field reads exactly
// as it did standing still — which is the point, because the pattern the far
// grass makes on the ground is wanted and only its boiling is not.
uniform float calm_from = 18.0;
uniform float calm_to = 55.0;
// Degrees at the tip in a full gust.
uniform float wind_sway : hint_range(0.0, 60.0) = 9.0;
uniform float wind_speed = 1.15;
// Metres between gust crests. This is what makes wind read as weather rather
// than as an animation: the wave travels across the ground, so a field ripples
// away from you instead of every plant leaning on the same beat.
uniform float gust_length = 17.0;
group_uniforms;

group_uniforms Walkers;
// Degrees at the tip for someone standing on top of the plant.
uniform float push_sway : hint_range(0.0, 90.0) = 52.0;
// Ceiling on everything above added together, so a plant with two people in it
// leans hard rather than folding through the ground.
uniform float max_bend : hint_range(0.0, 90.0) = 62.0;
group_uniforms;

group_uniforms GroundCoverLook;
// Dense grass uses MultiMesh instance colour for the exact terrain tint. This
// shifts that green gently toward violet without replacing its light/dark value.
uniform float purple_shift : hint_range(0.0, 1.0) = 0.0;
uniform bool custom_z_is_glow = false;
// Coral grows out of the sea bed and is planted by the same GroundCover as
// everything else, but it is looked at through water. Water in this project is
// a transparent surface rather than a post-process volume, so anything under it
// applies the shared visibility law itself — see `vivid_sea_veil`. Off for
// anything growing in air, which is why it is a flag and not a distance test:
// a flower on a clifftop is above water and below the line of sight to it.
uniform bool underwater = false;
uniform float glow_strength : hint_range(0.0, 8.0) = 0.0;
// Like specular filtering in foliage shaders: once a blade is too small to
// resolve, stop asking its individual emissive pixels to carry the patch. The
// pooled low-frequency ground light remains. Defaults leave ordinary species
// unchanged; dense glowing grass opts in.
uniform float glow_fade_from = 10000.0;
uniform float glow_fade_to = 10001.0;
group_uniforms;

group_uniforms NightEmission;
// Local-night emission for colony flowers. This is separate from glow_strength:
// grass patches may glow in daylight, while these flowers should wake at their
// own sunset and go dark again at dawn.
uniform vec3 night_emission_color : source_color = vec3(0.0);
uniform float night_emission_energy : hint_range(0.0, 8.0) = 0.0;
// A small pulse, independently phased and slightly speed-varied per plant from
// its rooted world position. Zero leaves every existing material unchanged.
uniform float night_pulse_amount : hint_range(0.0, 0.5) = 0.0;
uniform float night_pulse_speed : hint_range(0.0, 2.0) = 0.3;
// A sharper, less regular companion to breathing. Intended for occasional
// mushrooms, shrubs and ice rather than dense grass: two narrow hashed peaks
// make neighbouring specimens wink independently instead of the whole biome
// rising and falling as one.
uniform float night_twinkle_amount : hint_range(0.0, 1.0) = 0.0;
uniform float night_twinkle_speed : hint_range(0.0, 4.0) = 0.8;
// How much authored albedo is allowed to tint the emitted colour. Low values
// produce a dense, opaque-looking darklight instead of a washed-out petal.
uniform float night_emission_albedo : hint_range(0.0, 1.0) = 0.38;
// Confines the glow to the bloom. MeshMaker paints the petals violet and the
// leaves and stem green, so the gap between the blue and green channels
// separates them without a second UV set or a mask texture: on
// purple_flower_near_vat.glb every vertex above +0.02 is petal and sits in the
// top half of the plant, while no leaf or stem vertex reaches 0 at all.
// Off for anything painted in one family of hues, such as the pink tree crown,
// where the whole mesh is the flower already.
uniform bool night_emission_petals_only = false;
group_uniforms;

group_uniforms Thinning;
// Where thinning starts, where it reaches the sparse distant density, and where
// the field stops being drawn at all, in metres from viewer_point. Keeping
// thin_to separate from draw_within lets a field gain a long sparse horizon
// without stretching near-field density across the whole larger radius.
uniform float thin_from = 26.0;
uniform float thin_to = 130.0;
uniform float draw_within = 130.0;
// Share of the plants still standing from thin_to through draw_within.
uniform float far_density : hint_range(0.02, 1.0) = 0.13;
// How much of the rank range a plant spends shrinking as its turn to go comes
// up. Without it the far edge of the field is a line plants pop across.
uniform float fade_band : hint_range(0.01, 0.5) = 0.14;
group_uniforms;

varying vec3 v_world_position;
varying vec3 v_world_normal;
varying float v_tone;
varying float v_glow;
varying float v_night_phase;
varying float v_night_rate;
// How badly this instance has been burned, 0 untouched and 1 charred through.
//
// Carried in the alpha of the instance colour, which is the one per-instance
// channel that was written and never read: the three colour channels are the
// semantic mask the petal, paint and emission rules all key off, and all four
// INSTANCE_CUSTOM floats are already spent on rank, phase, stiffness and tone.
// Undamaged cover is written with alpha 1, so this is zero for every plant that
// has not been hit and the whole term costs nothing to leave switched on.
varying float v_char;
// What a fully burned plant is left as. Warm rather than neutral, because ash
// over the biome tint at zero saturation comes out blue-grey under this sky.
const vec3 CHAR_COLOR = vec3(0.17, 0.135, 0.115);

// Share of the field still standing at this distance, as a rank threshold. Kept
// above 1 at close range so that even the highest-ranked plant is at full size
// rather than permanently part-way through its own fade.
//
// GroundCover.tile_keep is this same curve in GDScript. They have to agree: the
// CPU submits the instances below the threshold and this draws them, so a CPU
// curve that sat lower would cut plants off mid-fade.
float plant_keep(float away) {
	float thinned = mix(1.0 + fade_band, far_density,
		smoothstep(thin_from, thin_to, away));
	return thinned * (1.0 - smoothstep(draw_within, draw_within * 1.12, away));
}

// How hard one walker leans this plant, as a direction in the ground plane
// times a strength of 0..1.
vec3 plant_shove(vec4 walker, vec3 base, vec3 up) {
	if (walker.w <= 0.0) {
		return vec3(0.0);
	}
	vec3 away = base - walker.xyz;
	away -= up * dot(away, up);
	float span = length(away);
	if (span >= walker.w || span < 0.001) {
		return vec3(0.0);
	}
	// Squared, so the lean is nearly nothing at the edge of the reach and piles
	// up under the feet. Linear reads as a disc of bent plants sliding across
	// the ground with the player inside it.
	float force = 1.0 - span / walker.w;
	return (away / span) * force * force;
}

vec3 plant_turn(vec3 point, vec3 axis, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return point * c + cross(axis, point) * s + axis * (dot(axis, point) * (1.0 - c));
}

void vertex() {
	// Solved in model space, where the plant's own up is +Y and its base is the
	// origin, because that is what the mesh was authored as and it saves
	// carrying a tangent frame per instance. Only the two world directions —
	// the wind and the way out of the ground — have to be brought across.
	vec3 base = MODEL_MATRIX[3].xyz;
	vec3 up = vivid_up(base);
	mat3 frame = mat3(MODEL_MATRIX);

	// Read once and spent three times: on the calming here, on the thinning at
	// the bottom of this function, and on nothing else. It is the same distance
	// both curves are written against.
	float away = distance(base, viewer_point);
	// See `calm_from`. Applied to the bend and to the baked clip both, because
	// either one left running on its own is still an animated field.
	float animate = 1.0 - smoothstep(calm_from, calm_to, away);

	vec3 bind_vertex = VERTEX;
	vec3 posed = VERTEX;
	vec3 lean = vec3(0.0);
	// Past calm_to every deformation term is exactly at rest. Avoiding the
	// trigonometry, four walker distance tests and two VAT fetches there is a
	// large saving for a field whose overwhelming majority is sub-pixel. The
	// 0.001 tail is below a tenth of one percent of the authored motion, so the
	// branch happens only after the existing smooth fade has visually ended.
	bool deform = animate > 0.001
		&& (vat_enabled || wind_sway > 0.001 || push_sway > 0.001);
	if (deform) {
		if (wind_sway > 0.001) {
			float phase = dot(base, wind_direction) / max(gust_length, 0.1)
				+ TIME * wind_speed + INSTANCE_CUSTOM.y * TAU;
			// Two frequencies, so a gust has a shape instead of a beat, and a
			// slow cross-wind wobble so the plant traces a figure rather than a
			// line.
			float gust = sin(phase) * 0.62
				+ sin(phase * 2.17 + 1.3) * 0.38;
			vec3 breeze = wind_direction - up * dot(wind_direction, up);
			breeze = length(breeze) > 0.001
				? normalize(breeze) : vec3(0.0);
			lean += (breeze * (radians(wind_sway) * wind_strength
					* (0.34 + 0.66 * gust))
				+ cross(up, breeze) * (radians(wind_sway)
					* wind_strength * 0.3
					* sin(phase * 0.77 + 2.1))) * animate;
		}
		if (push_sway > 0.001) {
			vec3 shove = plant_shove(walker_0, base, up)
				+ plant_shove(walker_1, base, up)
				+ plant_shove(walker_2, base, up)
				+ plant_shove(walker_3, base, up);
			lean += shove * radians(push_sway);
		}
		if (vat_enabled) {
			// In loops rather than in radians, matching the baker's phase.
			float sway = dot(base, wind_direction)
					/ max(gust_length * TAU, 0.1)
				+ INSTANCE_CUSTOM.y * sway_scatter;
			posed += vivid_vat_delta(vat_positions, UV2.x, TIME, sway,
				vat_playback_speed, vat_frame_count, vat_fps,
				vat_delta_min, vat_delta_max) * animate;
		}
	}

	float angle = 0.0;
	if (deform) {
		angle = min(length(lean), radians(max_bend));
		// Stiffness off the instance, so a stand of plants in one gust does not
		// move as one sheet. The hash is irrelevant at rest and is intentionally
		// kept inside this branch for the hundreds of thousands of distant
		// blades that never bend.
		float character = custom_z_is_glow
			? vivid_hash13(base * 1.73) : INSTANCE_CUSTOM.z;
		angle /= mix(0.78, 1.3, character);
	}
	vec3 grown = posed;
	if (angle > 0.0008) {
		// Grass may be widened without being made taller, so use the full
		// inverse rather than assuming the instance basis has uniform scale.
		vec3 heading = normalize(inverse(frame) * normalize(lean));
		vec3 axis = cross(vec3(0.0, 1.0, 0.0), heading);
		axis = length(axis) > 0.001 ? normalize(axis) : vec3(1.0, 0.0, 0.0);
		// Height is the lever arm, so the base stays rooted and the tip
		// travels the whole angle. Only the vertical part of the vertex is
		// turned: sweeping the horizontal part with it swings a petal around
		// the stem as well as over, which reads as the flower spinning.
		float lever = pow(clamp(bind_vertex.y / max(stem_height, 0.01), 0.0, 1.0),
			rigidity);
		float turn = angle * lever;
		grown = vec3(posed.x, 0.0, posed.z)
			+ plant_turn(vec3(0.0, posed.y, 0.0), axis, turn);
		NORMAL = plant_turn(NORMAL, axis, turn);
	}

	// Its turn to go. Scaling into the ground rather than vanishing, because
	// the alternative at this instance count is a horizon that crawls.
	float keep = plant_keep(away);
	VERTEX = grown * (1.0 - smoothstep(keep - fade_band, keep, INSTANCE_CUSTOM.x));

	v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	v_tone = mix(1.0 - tone_variation, 1.0 + tone_variation, INSTANCE_CUSTOM.w);
	v_glow = custom_z_is_glow ? INSTANCE_CUSTOM.z : 0.0;
	v_char = clamp(1.0 - COLOR.a, 0.0, 1.0);
	// Rooted position makes the pulse deterministic across streaming rebuilds:
	// the same flower comes back with the same beat, while neighbours get
	// unrelated phases and rates.
	v_night_phase = 0.0;
	v_night_rate = 1.0;
	if (night_pulse_amount > 0.0 || night_twinkle_amount > 0.0) {
		v_night_phase = vivid_hash13(base * 0.071 + vec3(3.1, 7.7, 1.9));
		v_night_rate = mix(0.82, 1.18,
			vivid_hash13(base * 0.113 + vec3(9.2, 2.6, 5.4)));
	}
}

void fragment() {
	// The paint PNG carries the readable bark bands, leaf veins, cap spots and
	// other species motifs. COLOR remains the fallback and semantic mask, so old
	// hand-authored plants and petal-only emission keep their existing contract.
	vec4 paint_sample = vec4(COLOR.rgb, 1.0);
	vec3 authored_color = COLOR.rgb;
	if (color_paint_enabled) {
		paint_sample = texture(color_paint, UV);
		authored_color = mix(
			authored_color, paint_sample.rgb, color_paint_strength);
	}
	float paint_emission = emission_from_paint_alpha && color_paint_enabled
		? clamp(paint_sample.a, 0.0, 1.0) : 1.0;
	vec3 albedo = base_color * authored_color * v_tone;
	float value = max(max(albedo.r, albedo.g), albedo.b);
	vec3 violet = vec3(albedo.r * 1.08, albedo.g * 0.82, albedo.b * 1.34);
	violet *= value / max(max(max(violet.r, violet.g), violet.b), 0.001);
	albedo = mix(albedo, violet, purple_shift);
	albedo = vivid_saturate(albedo, saturation) * brightness;
	// Burned wood keeps a little of its own hue at the edges of the scorch and
	// loses all of it at the centre, so a half-cut trunk reads as charred bark
	// rather than as a grey plant. Applied before the region wheel, which would
	// otherwise paint the char back up to the biome's colour.
	if (v_char > 0.001) {
		albedo = mix(albedo, vivid_saturate(albedo, 0.15) * CHAR_COLOR, v_char);
	}

	vec2 region = vivid_region(vivid_up(v_world_position));
	vec3 region_color = vivid_spectrum(region.x);
	albedo = mix(albedo, vivid_saturate(albedo * region_color * 2.0, saturation * 0.8),
		region_albedo * mix(0.35, 1.0, region.y));

	vec3 view = normalize(CAMERA_POSITION_WORLD - v_world_position);
	float fresnel = pow(1.0 - clamp(dot(normalize(v_world_normal), view), 0.0, 1.0), 4.0);
	float camera_rim = vivid_camera_rim(
		v_world_normal, view, camera_rim_dark, camera_rim_light);
	if (camera_rim_fade_from < 9999.0) {
		camera_rim *= 1.0 - smoothstep(camera_rim_fade_from,
			max(camera_rim_fade_to, camera_rim_fade_from + 0.01),
			distance(CAMERA_POSITION_WORLD, v_world_position));
	}

	// The plant's own colour, taken before the water gets at it. What a coral
	// glows by is what a coral is, and the veil below pulls albedo towards the
	// sea with distance — reading the night colour off it afterwards would make
	// a far reef glow sea-green rather than glow pink faintly. EMISSION is
	// scaled by `lit` at the end regardless, so the distance is already paid for
	// once and does not want paying for twice.
	//
	// Above water this is albedo unchanged, so the flowers and the trees are
	// unaffected.
	vec3 own_color = albedo;

	float lit = 1.0;
	if (underwater) {
		// The same two journeys the sea bed under it is charged for: the light
		// down the column to the coral, and the sight back along the water to
		// the eye. Reading them from the same globals PlanetWater writes is
		// what keeps a reef and the bed it sits on fading out together.
		vec3 kept;
		vec3 wash;
		vivid_sea_veil(distance(CAMERA_POSITION_WORLD, v_world_position),
			max(planet_radius - distance(v_world_position, planet_center), 0.0),
			1.0, kept, wash);
		lit = clamp((kept.r + kept.g + kept.b) / 3.0, 0.0, 1.0);
		albedo = mix(wash, albedo, kept);
	}

	// Grass is drawn solid and thin rather than screen-doored. A dither keyed on
	// the world position is a different mask every time the pixel lands
	// somewhere new, so the whole field boils while you walk; BACKLIGHT below is
	// what carries "you can see the light through it" instead.
	ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
	ROUGHNESS = roughness;
	SPECULAR = specular;
	METALLIC = 0.0;
	RIM = region_rim * mix(0.4, 1.0, region.y);
	RIM_TINT = 0.4;
	// Petals are thin and the sun is usually behind some of them.
	BACKLIGHT = albedo * translucency;
	// Scaled by what the water leaves of the view, so a reef fading into the
	// murk does not keep its sheen and its glow burning through it.
	vec3 night_emission = vec3(0.0);
	if (night_emission_energy > 0.0) {
		// Measured off the painted mesh, not guessed: the petals clear +0.02
		// and the leaves and stem never reach zero, so the band between them
		// is where the bloom starts without clipping its own darker edges.
		float petal = 1.0;
		if (night_emission_petals_only) {
			petal = smoothstep(0.0, 0.045, COLOR.b - COLOR.g);
		}
		float night = petal * paint_emission * (1.0 - smoothstep(-0.16, 0.12,
			dot(vivid_up(v_world_position), normalize(-sun_direction))));
		float pulse = 1.0;
		if (night_pulse_amount > 0.0) {
			pulse += night_pulse_amount * sin(
				TIME * TAU * night_pulse_speed * v_night_rate
					+ v_night_phase * TAU);
		}
		if (night_twinkle_amount > 0.0) {
			float twinkle_phase = TIME * TAU * night_twinkle_speed
				* v_night_rate + v_night_phase * TAU;
			float first = pow(0.5 + 0.5 * sin(twinkle_phase), 12.0);
			float second = pow(0.5 + 0.5 * sin(
				twinkle_phase * 0.63 + v_night_phase * 17.0), 18.0);
			pulse *= 1.0 + night_twinkle_amount
				* (first * 1.35 + second * 0.85);
		}
		night_emission = night_emission_color * night_emission_energy
			* night * pulse * mix(vec3(1.0), own_color, night_emission_albedo);
	}
	vec3 day_emission = day_emission_color * day_emission_energy
		* paint_emission * mix(vec3(1.0), own_color, day_emission_albedo);
	float glow_visibility = 1.0;
	if (glow_fade_from < 9999.0) {
		glow_visibility = 1.0 - smoothstep(glow_fade_from,
			max(glow_fade_to, glow_fade_from + 0.01),
			distance(CAMERA_POSITION_WORLD, v_world_position));
	}
	// A burned lantern mushroom stops glowing. Emission is what makes a
	// scorched instance still read as healthy at night, so it goes out with the
	// albedo rather than after it.
	EMISSION = (region_color * fresnel * region_sheen * region.y * 0.5
		+ vivid_camera_rim_colour(camera_rim_color)
			* camera_rim_energy * camera_rim
		+ albedo * v_glow * glow_strength * glow_visibility
		+ day_emission + night_emission) * lit * (1.0 - v_char);
}
