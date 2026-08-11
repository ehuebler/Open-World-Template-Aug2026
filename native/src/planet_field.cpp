#include "planet_field.h"

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

// GDScript's `smoothstep`, including the descending case every resolution fade
// here relies on. Written out rather than taken from Math:: so that the one
// operation this file is made of cannot pick up a different edge convention.
inline double smoothstep(double p_from, double p_to, double p_weight) {
	if (p_from == p_to) {
		return p_from <= p_weight ? 1.0 : 0.0;
	}
	double x = (p_weight - p_from) / (p_to - p_from);
	x = std::clamp(x, 0.0, 1.0);
	return x * x * (3.0 - 2.0 * x);
}

inline double lerpd(double p_from, double p_to, double p_weight) {
	return p_from + (p_to - p_from) * p_weight;
}

inline double clampd(double p_value, double p_low, double p_high) {
	return std::clamp(p_value, p_low, p_high);
}

// A shader graph's Colour Ramp, with its two stops where a terrain artist puts
// them: at or below `p_black` everything comes out at the floor, at or above
// `p_white` at the ceiling, straight line between.
//
// Linear and not a smoothstep, and that is the entire point of it. The corners
// at the two stops are the feature rather than a defect to be rounded off: the
// lower one is where a plain stops being a plain, and the upper one is where a
// summit flattens into a cap. Smoothstep would ease both of those away and give
// back the rolling ground this is meant to replace. Sliding the two stops
// together is the strongest single control over how dramatic the ground is —
// far apart is downland, a hand's width apart is Utah.
inline double ramp(double p_value, double p_black, double p_white) {
	if (p_white <= p_black) {
		return p_value >= p_white ? 1.0 : 0.0;
	}
	return std::clamp((p_value - p_black) / (p_white - p_black), 0.0, 1.0);
}

inline double setting(const Dictionary &p_settings, const char *p_key, double p_fallback) {
	return p_settings.has(p_key) ? (double)p_settings[p_key] : p_fallback;
}

} // namespace

PlanetField::PlanetField() {}

void PlanetField::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "settings"), &PlanetField::configure);
	ClassDB::bind_method(D_METHOD("elevation", "direction", "spacing"),
			&PlanetField::elevation, DEFVAL(0.0));
	ClassDB::bind_method(D_METHOD("color_at", "direction", "height", "normal"),
			&PlanetField::color_at);
	ClassDB::bind_method(D_METHOD("frost", "direction"), &PlanetField::frost);
	ClassDB::bind_method(D_METHOD("solve_sea_bias", "samples", "fraction"),
			&PlanetField::solve_sea_bias);
	ClassDB::bind_method(D_METHOD("get_sea_bias"), &PlanetField::get_sea_bias);
	ClassDB::bind_method(D_METHOD("set_sea_bias", "bias"), &PlanetField::set_sea_bias);
	ClassDB::bind_method(D_METHOD("get_arid_edge"), &PlanetField::get_arid_edge);
	ClassDB::bind_method(D_METHOD("noise_at", "field", "direction"),
			&PlanetField::noise_at);
	ClassDB::bind_method(D_METHOD("sample", "direction"), &PlanetField::sample);
	ClassDB::bind_method(D_METHOD("build_patch", "face_origin", "face_u", "face_v",
								  "offset", "size", "resolution", "spacing", "skirt",
								  "chunk_origin", "want_collision"),
			&PlanetField::build_patch);
}

Dictionary PlanetField::build_patch(const Vector3 &p_face_origin, const Vector3 &p_face_u,
		const Vector3 &p_face_v, const Vector2 &p_offset, double p_size,
		int p_resolution, double p_spacing, double p_skirt,
		const Vector3 &p_chunk_origin, bool p_want_collision) const {
	// `Planet._build`, whole. It was split across the two languages for one
	// version — the samples here, the grid there — and that was the worst of
	// both: 361 vertices took 9.4 ms, of which under 3 was the field. The loop
	// itself, the array writes and the index arithmetic were the other 90%, and
	// none of it is work that reads any better in GDScript.
	const int side = p_resolution + 3;
	const int count = side * side;
	const int last = side - 1;
	const double span = (double)p_resolution;
	const double quarter_pi = 0.78539816339744830961;

	PackedVector3Array field;
	PackedFloat32Array heights;
	field.resize(count);
	heights.resize(count);
	Vector3 *field_write = field.ptrw();
	float *heights_write = heights.ptrw();

	for (int row = 0; row < side; row++) {
		double v = (double)(row - 1) / span;
		double face_v = std::tan((p_offset.y + v * p_size) * quarter_pi);
		for (int col = 0; col < side; col++) {
			double u = (double)(col - 1) / span;
			double face_u = std::tan((p_offset.x + u * p_size) * quarter_pi);
			Vector3 direction = (p_face_origin + p_face_u * face_u + p_face_v * face_v)
										.normalized();
			int index = row * side + col;
			field_write[index] = direction;
			heights_write[index] = (float)elevation(direction, p_spacing);
		}
	}

	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedColorArray colors;
	PackedVector2Array uvs;
	vertices.resize(count);
	normals.resize(count);
	colors.resize(count);
	uvs.resize(count);
	Vector3 *vertices_write = vertices.ptrw();
	Vector3 *normals_write = normals.ptrw();
	Color *colors_write = colors.ptrw();
	Vector2 *uvs_write = uvs.ptrw();

	for (int row = 0; row < side; row++) {
		int v_index = std::clamp(row - 1, 0, p_resolution);
		int patch_row = std::clamp(row, 1, last - 1);
		for (int col = 0; col < side; col++) {
			int u_index = std::clamp(col - 1, 0, p_resolution);
			int patch_col = std::clamp(col, 1, last - 1);
			int index = row * side + col;
			int source = patch_row * side + patch_col;
			Vector3 direction = field_write[source];
			double height = (double)heights_write[source];
			Vector3 normal = grid_normal(field_write, heights_write, side,
					patch_row, patch_col);
			double vertex_radius = radius + height;
			if (row == 0 || col == 0 || row == last || col == last) {
				vertex_radius -= p_skirt;
			}
			vertices_write[index] = direction * vertex_radius - p_chunk_origin;
			normals_write[index] = normal;
			colors_write[index] = color_at(direction, height, normal);
			uvs_write[index] = Vector2((float)(u_index / span), (float)(v_index / span));
		}
	}

	PackedInt32Array indices;
	indices.resize(last * last * 6);
	int32_t *indices_write = indices.ptrw();
	int write = 0;
	for (int row = 0; row < last; row++) {
		for (int col = 0; col < last; col++) {
			int corner = row * side + col;
			// Clockwise seen from outside, which is Godot's front face.
			indices_write[write] = corner;
			indices_write[write + 1] = corner + side;
			indices_write[write + 2] = corner + 1;
			indices_write[write + 3] = corner + 1;
			indices_write[write + 4] = corner + side;
			indices_write[write + 5] = corner + side + 1;
			write += 6;
		}
	}

	Dictionary out;
	out["vertices"] = vertices;
	out["normals"] = normals;
	out["colors"] = colors;
	out["uvs"] = uvs;
	out["indices"] = indices;
	// The centre sample the chunk's children inherit instead of sampling for
	// themselves. Taken here rather than by a second call for the same reason
	// everything else moved: the call is a third of what the sample costs.
	double centre_v = std::tan((p_offset.y + 0.5 * p_size) * quarter_pi);
	double centre_u = std::tan((p_offset.x + 0.5 * p_size) * quarter_pi);
	Vector3 centre = (p_face_origin + p_face_u * centre_u + p_face_v * centre_v)
							 .normalized();
	out["height"] = elevation(centre, p_spacing);

	if (p_want_collision) {
		PackedVector3Array faces;
		faces.resize(p_resolution * p_resolution * 6);
		Vector3 *faces_write = faces.ptrw();
		int at = 0;
		for (int row = 0; row < p_resolution; row++) {
			for (int col = 0; col < p_resolution; col++) {
				int corner = (row + 1) * side + col + 1;
				faces_write[at] = vertices_write[corner];
				faces_write[at + 1] = vertices_write[corner + side];
				faces_write[at + 2] = vertices_write[corner + 1];
				faces_write[at + 3] = vertices_write[corner + 1];
				faces_write[at + 4] = vertices_write[corner + side];
				faces_write[at + 5] = vertices_write[corner + side + 1];
				at += 6;
			}
		}
		out["collision"] = faces;
	}
	return out;
}

Vector3 PlanetField::grid_normal(const Vector3 *p_field, const float *p_heights,
		int p_side, int p_row, int p_col) const {
	int index = p_row * p_side + p_col;
	int west = index - 1;
	int east = index + 1;
	int south = index - p_side;
	int north = index + p_side;
	Vector3 along_u = p_field[east] * (radius + (double)p_heights[east]) -
			p_field[west] * (radius + (double)p_heights[west]);
	Vector3 along_v = p_field[north] * (radius + (double)p_heights[north]) -
			p_field[south] * (radius + (double)p_heights[south]);
	Vector3 normal = along_u.cross(along_v);
	Vector3 up = p_field[index];
	if (normal.length_squared() < 1e-12) {
		return up;
	}
	normal = normal.normalized();
	return normal.dot(up) > 0.0 ? normal : -normal;
}

double PlanetField::noise_at(const String &p_field, const Vector3 &p_direction) const {
	// Only `dev/_field_check.gd` calls this. Every later disagreement is
	// downstream of these nine fields, so a port has to be able to be asked
	// about them one at a time or a mismatch in one of them presents as a
	// confusing argument about the shape of a mountain.
	Vector3 point = p_direction * radius;
	const FastNoiseLite *noise = nullptr;
	if (p_field == "_continent") {
		noise = &continent_noise;
	} else if (p_field == "_mountain") {
		noise = &mountain_noise;
	} else if (p_field == "_hills") {
		noise = &hills_noise;
	} else if (p_field == "_detail") {
		noise = &detail_noise;
	} else if (p_field == "_rivers") {
		noise = &rivers_noise;
	} else if (p_field == "_roughness") {
		noise = &roughness_noise;
	} else if (p_field == "_lakes") {
		noise = &lakes_noise;
	} else if (p_field == "_arid") {
		noise = &arid_noise;
	} else if (p_field == "_hoodoo") {
		noise = &hoodoo_noise;
	}
	if (noise == nullptr) {
		return 0.0;
	}
	return noise->GetNoise((float)point.x, (float)point.y, (float)point.z);
}

void PlanetField::setup_noise(FastNoiseLite &r_noise, double p_wavelength,
		int p_octaves, int p_seed_offset) const {
	// Godot's FastNoiseLite resource with TYPE_SIMPLEX_SMOOTH and FRACTAL_FBM,
	// setting for setting. The defaults it does not expose in `_make_noise` are
	// spelled out rather than left to this library's, because the two libraries
	// only agree by construction and a differing default here would move every
	// coastline on the planet while still looking like plausible terrain.
	r_noise.SetNoiseType(FastNoiseLite::NoiseType_OpenSimplex2S);
	r_noise.SetSeed(noise_seed + p_seed_offset);
	r_noise.SetFrequency((float)(1.0 / std::max(p_wavelength, 1.0)));
	r_noise.SetFractalType(FastNoiseLite::FractalType_FBm);
	r_noise.SetFractalOctaves(p_octaves);
	r_noise.SetFractalLacunarity(2.0f);
	r_noise.SetFractalGain(0.5f);
	r_noise.SetFractalWeightedStrength(0.0f);
}

void PlanetField::configure(const Dictionary &p_settings) {
	radius = setting(p_settings, "radius", radius);
	noise_seed = (int)setting(p_settings, "noise_seed", noise_seed);

	continent_wavelength = setting(p_settings, "continent_wavelength", continent_wavelength);
	mountain_wavelength = setting(p_settings, "mountain_wavelength", mountain_wavelength);
	massif_wavelength = setting(p_settings, "massif_wavelength", massif_wavelength);
	hill_wavelength = setting(p_settings, "hill_wavelength", hill_wavelength);
	detail_wavelength = setting(p_settings, "detail_wavelength", detail_wavelength);
	river_wavelength = setting(p_settings, "river_wavelength", river_wavelength);
	roughness_wavelength = setting(p_settings, "roughness_wavelength", roughness_wavelength);
	lake_wavelength = setting(p_settings, "lake_wavelength", lake_wavelength);

	ocean_depth = setting(p_settings, "ocean_depth", ocean_depth);
	shelf_depth = setting(p_settings, "shelf_depth", shelf_depth);
	shelf_break = setting(p_settings, "shelf_break", shelf_break);
	abyss_span = setting(p_settings, "abyss_span", abyss_span);
	seabed_relief = setting(p_settings, "seabed_relief", seabed_relief);
	land_height = setting(p_settings, "land_height", land_height);
	mountain_height = setting(p_settings, "mountain_height", mountain_height);
	mountain_mix = setting(p_settings, "mountain_mix", mountain_mix);
	mountain_plain = setting(p_settings, "mountain_plain", mountain_plain);
	mountain_peak = setting(p_settings, "mountain_peak", mountain_peak);
	mountain_sharpness = setting(p_settings, "mountain_sharpness", mountain_sharpness);
	mountain_crag = setting(p_settings, "mountain_crag", mountain_crag);
	hill_height = setting(p_settings, "hill_height", hill_height);
	detail_height = setting(p_settings, "detail_height", detail_height);
	river_depth = setting(p_settings, "river_depth", river_depth);
	lake_depth = setting(p_settings, "lake_depth", lake_depth);

	sea_fraction = setting(p_settings, "sea_fraction", sea_fraction);
	river_width = setting(p_settings, "river_width", river_width);
	river_channel = setting(p_settings, "river_channel", river_channel);
	lake_threshold = setting(p_settings, "lake_threshold", lake_threshold);

	aridity = setting(p_settings, "aridity", aridity);
	arid_wavelength = setting(p_settings, "arid_wavelength", arid_wavelength);
	terrace_height = setting(p_settings, "terrace_height", terrace_height);
	terrace_riser = setting(p_settings, "terrace_riser", terrace_riser);
	terrace_span = setting(p_settings, "terrace_span", terrace_span);
	canyon_depth = setting(p_settings, "canyon_depth", canyon_depth);
	canyon_width = setting(p_settings, "canyon_width", canyon_width);
	stratum_height = setting(p_settings, "stratum_height", stratum_height);
	hoodoo_height = setting(p_settings, "hoodoo_height", hoodoo_height);
	hoodoo_wavelength = setting(p_settings, "hoodoo_wavelength", hoodoo_wavelength);
	hoodoo_stand = setting(p_settings, "hoodoo_stand", hoodoo_stand);
	badland_wavelength = setting(p_settings, "badland_wavelength", badland_wavelength);
	badland_reach = setting(p_settings, "badland_reach", badland_reach);

	frost_area = setting(p_settings, "frost_area", frost_area);
	frost_blend = setting(p_settings, "frost_blend", frost_blend);
	if (p_settings.has("frost_axis")) {
		frost_axis = p_settings["frost_axis"];
	}
	volcano_enabled = setting(p_settings, "volcano_enabled",
			volcano_enabled ? 1.0 : 0.0) > 0.5;
	volcano_radius = setting(p_settings, "volcano_radius", volcano_radius);
	volcano_island_height = setting(
			p_settings, "volcano_island_height", volcano_island_height);
	volcano_cone_radius = setting(
			p_settings, "volcano_cone_radius", volcano_cone_radius);
	volcano_cone_height = setting(
			p_settings, "volcano_cone_height", volcano_cone_height);
	volcano_crater_radius = setting(
			p_settings, "volcano_crater_radius", volcano_crater_radius);
	volcano_crater_depth = setting(
			p_settings, "volcano_crater_depth", volcano_crater_depth);
	if (p_settings.has("volcano_flow_angles")) {
		volcano_flow_angles = p_settings["volcano_flow_angles"];
	}
	volcano_channel_width = setting(
			p_settings, "volcano_channel_width", volcano_channel_width);
	volcano_channel_depth = setting(
			p_settings, "volcano_channel_depth", volcano_channel_depth);
	if (p_settings.has("volcano_pool_one")) {
		volcano_pool_one = p_settings["volcano_pool_one"];
	}
	if (p_settings.has("volcano_pool_two")) {
		volcano_pool_two = p_settings["volcano_pool_two"];
	}
	if (p_settings.has("volcano_pool_three")) {
		volcano_pool_three = p_settings["volcano_pool_three"];
	}
	volcano_pool_depth = setting(
			p_settings, "volcano_pool_depth", volcano_pool_depth);
	volcano_pool_shore_width = setting(
			p_settings, "volcano_pool_shore_width", volcano_pool_shore_width);
	volcano_pool_shore_overlap = setting(
			p_settings, "volcano_pool_shore_overlap", volcano_pool_shore_overlap);
	volcano_crater_lava_height = setting(
			p_settings, "volcano_crater_lava_height", volcano_crater_lava_height);

	setup_noise(continent_noise, continent_wavelength, 5, 0);
	setup_noise(mountain_noise, mountain_wavelength, 5, 101);
	// Three octaves against the mountain field's five, because this one is only
	// ever asked where the ranges are and not what the ground does inside them.
	// Its fine octaves would be answering the first question with detail that
	// the other field already provides, at the price of the extra noise reads
	// the whole term is being kept cheap to afford.
	setup_noise(massif_noise, massif_wavelength, 3, 909);
	setup_noise(hills_noise, hill_wavelength, 3, 202);
	setup_noise(detail_noise, detail_wavelength, 2, 303);
	setup_noise(rivers_noise, river_wavelength, 3, 404);
	setup_noise(roughness_noise, roughness_wavelength, 2, 505);
	setup_noise(lakes_noise, lake_wavelength, 3, 606);
	setup_noise(arid_noise, arid_wavelength, 3, 707);
	setup_noise(hoodoo_noise, hoodoo_wavelength, 2, 808);
	setup_noise(badland_noise, badland_wavelength, 2, 1010);

	// Named constants and the palette, which `PlanetShape` owns. Fallbacks are
	// deliberately absent for the colours: a missing key there would paint a
	// plausible planet in the wrong colours and nothing would report it, so an
	// unset entry comes through as black and is impossible to miss.
	CONTINENT_SPAN = setting(p_settings, "CONTINENT_SPAN", CONTINENT_SPAN);
	RESOLVE_FLOOR = setting(p_settings, "RESOLVE_FLOOR", RESOLVE_FLOOR);
	SHORE_WETNESS = setting(p_settings, "SHORE_WETNESS", SHORE_WETNESS);
	ICE_TOP = setting(p_settings, "ICE_TOP", ICE_TOP);
	SEA_ICE_WETNESS = setting(p_settings, "SEA_ICE_WETNESS", SEA_ICE_WETNESS);
	if (p_settings.has("palette")) {
		Dictionary palette = p_settings["palette"];
		DEEP_WATER = palette["DEEP_WATER"];
		SHALLOW_WATER = palette["SHALLOW_WATER"];
		SHORE = palette["SHORE"];
		GRASS = palette["GRASS"];
		UPLAND = palette["UPLAND"];
		ROCK = palette["ROCK"];
		SNOW = palette["SNOW"];
		ICE = palette["ICE"];
		MESA_MAROON = palette["MESA_MAROON"];
		MESA_RED = palette["MESA_RED"];
		MESA_ORANGE = palette["MESA_ORANGE"];
		MESA_CREAM = palette["MESA_CREAM"];
		DESERT_FLOOR = palette["DESERT_FLOOR"];
		VOLCANIC_BASALT = palette["VOLCANIC_BASALT"];
		VOLCANIC_ASH = palette["VOLCANIC_ASH"];
		VOLCANIC_OXIDE = palette["VOLCANIC_OXIDE"];
	}

	arid_edge = lerpd(-0.5, 0.5, 1.0 - aridity);
	pole = frost_axis.length_squared() > 0.0 ? frost_axis.normalized() : Vector3(0, 1, 0);
	volcano_pole = -pole;
	Vector3 reference = std::abs(volcano_pole.y) < 0.9
			? Vector3(0, 1, 0) : Vector3(1, 0, 0);
	volcano_east = volcano_pole.cross(reference).normalized();
	volcano_north = volcano_pole.cross(volcano_east).normalized();
	frost_edge = 1.0 - 2.0 * clampd(frost_area + frost_blend * 0.5, 0.0, 1.0);
	frost_full = 1.0 - 2.0 * clampd(frost_area - frost_blend * 0.5, 0.0, 1.0);
}

Vector3 PlanetField::even_direction(int p_index, int p_count) {
	const double pi = 3.14159265358979323846;
	double y = 1.0 - 2.0 * ((double)p_index + 0.5) / (double)p_count;
	double ring = std::sqrt(std::max(0.0, 1.0 - y * y));
	double angle = pi * (3.0 - std::sqrt(5.0)) * (double)p_index;
	return Vector3(std::cos(angle) * ring, y, std::sin(angle) * ring);
}

double PlanetField::solve_sea_bias(int p_samples, double p_fraction) {
	PackedFloat32Array values;
	values.resize(p_samples);
	for (int index = 0; index < p_samples; index++) {
		Vector3 direction = even_direction(index, p_samples) * radius;
		values[index] = continent_noise.GetNoise(
				(float)direction.x, (float)direction.y, (float)direction.z);
	}
	values.sort();
	int at = (int)clampd((double)p_samples * p_fraction, 0.0, (double)(p_samples - 1));
	sea_bias = -(double)values[at];
	return sea_bias;
}

double PlanetField::frost(const Vector3 &p_direction) const {
	return smoothstep(frost_edge, frost_full, p_direction.dot(pole));
}

double PlanetField::volcano_influence(const Vector3 &p_direction) const {
	if (!volcano_enabled || volcano_radius <= 0.0 || radius <= 0.0) {
		return 0.0;
	}
	double outer = std::cos(volcano_radius / radius);
	double inner = std::cos(volcano_radius * 0.82 / radius);
	return smoothstep(outer, inner, p_direction.normalized().dot(volcano_pole));
}

Vector3 PlanetField::volcano_coordinates(const Vector3 &p_direction) const {
	Vector3 out = p_direction.normalized();
	double cosine = clampd(out.dot(volcano_pole), -1.0, 1.0);
	double distance = std::acos(cosine) * radius;
	Vector3 tangent = out - volcano_pole * cosine;
	if (tangent.length_squared() < 0.0000001) {
		return Vector3(0.0, 0.0, 0.0);
	}
	tangent.normalize();
	return Vector3(tangent.dot(volcano_east) * distance,
			tangent.dot(volcano_north) * distance, distance);
}

double PlanetField::volcano_channel(double p_distance, double p_angle) const {
	if (volcano_channel_depth <= 0.0 || volcano_channel_width <= 0.0 ||
			p_distance <= volcano_crater_radius * 0.55 ||
			p_distance >= volcano_cone_radius * 1.02) {
		return 0.0;
	}
	double angles[3] = {
		volcano_flow_angles.x, volcano_flow_angles.y, volcano_flow_angles.z,
	};
	double channel = 0.0;
	for (double angle : angles) {
		double delta = p_angle - angle;
		// A sine is the distance to an infinite line. A lava channel is a ray:
		// accepting the opposite half made three breaches appear as six.
		if (std::cos(delta) <= 0.0) {
			continue;
		}
		double lateral = std::abs(std::sin(delta)) * p_distance;
		double band = 1.0 - smoothstep(
				volcano_channel_width, volcano_channel_width * 2.2, lateral);
		channel = std::max(channel, band);
	}
	double from_crater = smoothstep(
			volcano_crater_radius * 0.55, volcano_crater_radius, p_distance);
	double toward_foot = 1.0 - smoothstep(
			volcano_cone_radius * 0.82, volcano_cone_radius * 1.02, p_distance);
	double cone = smoothstep(volcano_cone_radius, volcano_crater_radius, p_distance);
	return volcano_channel_depth * channel * from_crater * toward_foot * cone;
}

double PlanetField::volcano_pool_radius(
		double p_base, double p_angle, int p_seed) const {
	double phase = (double)p_seed * 0.731;
	return p_base * (0.91 +
			std::sin(p_angle * 3.0 + phase) * 0.045 +
			std::sin(p_angle * 7.0 - phase * 1.7) * 0.028 +
			std::sin(p_angle * 11.0 + phase * 0.43) * 0.018);
}

double PlanetField::volcano_one_pool_basin(const Vector2 &p_coordinates,
		const Vector2 &p_centre, double p_radius, double p_surface,
		int p_seed, double p_height) const {
	Vector2 relative = p_coordinates - p_centre;
	double away = relative.length();
	// Almost every volcano sample is nowhere near any one pool. Reject it
	// before evaluating the three sines that make that pool's irregular edge.
	double widest_edge = p_radius * 1.001;
	double widest_shore = clampd(
			volcano_pool_shore_width, 0.1, widest_edge * 0.45);
	if (away >= widest_edge + widest_shore) {
		return p_height;
	}
	double angle = std::atan2(relative.y, relative.x);
	double edge = volcano_pool_radius(p_radius, angle, p_seed);
	double shore = clampd(volcano_pool_shore_width, 0.1, edge * 0.45);
	double floor_edge = edge - shore;
	double outer_edge = edge + shore;
	if (away >= outer_edge) {
		return p_height;
	}
	double floor = p_surface - volcano_pool_depth;
	double lip = p_surface - volcano_pool_shore_overlap;
	if (away <= floor_edge) {
		return floor;
	}
	if (away < edge) {
		return lerpd(floor, lip, smoothstep(floor_edge, edge, away));
	}
	return lerpd(lip, p_height, smoothstep(edge, outer_edge, away));
}

double PlanetField::volcano_pool_basin(const Vector3 &p_coordinates,
		double p_height) const {
	Vector2 here(p_coordinates.x, p_coordinates.y);
	// The crater lake is a pool too. Without this shelf its thin visible disc
	// floats ten metres above the crater floor just like the three lower pools.
	double height = volcano_one_pool_basin(
			here, Vector2(), volcano_crater_radius * 0.62,
			volcano_crater_lava_height, 3, p_height);
	Vector3 pools[3] = { volcano_pool_one, volcano_pool_two, volcano_pool_three };
	double angles[3] = {
		volcano_flow_angles.x, volcano_flow_angles.y, volcano_flow_angles.z,
	};
	for (int index = 0; index < 3; index++) {
		Vector2 centre(std::cos(angles[index]) * pools[index].x,
				std::sin(angles[index]) * pools[index].x);
		height = volcano_one_pool_basin(
				here, centre, pools[index].y, pools[index].z,
				11 + index * 7, height);
	}
	return height;
}

double PlanetField::volcano_height(const Vector3 &p_direction, double p_height,
		double p_spacing) const {
	double influence = volcano_influence(p_direction);
	if (influence <= 0.0) {
		return p_height;
	}
	Vector3 coordinates = volcano_coordinates(p_direction);
	double distance = coordinates.z;
	double cone = smoothstep(
			volcano_cone_radius, volcano_crater_radius, distance);
	double crater = 1.0 - smoothstep(
			volcano_crater_radius * 0.62, volcano_crater_radius, distance);
	double target = volcano_island_height + volcano_cone_height * cone -
			volcano_crater_depth * crater;

	// Broad radial ribs keep the cone from being a mathematically smooth funnel.
	// They are faded before a chunk can undersample them, like every other
	// sub-hundred-metre terrain term in this field.
	double detail_fade = smoothstep(180.0, 55.0, p_spacing);
	if (detail_fade > 0.0 && cone > 0.0 && crater < 1.0) {
		Vector3 point = p_direction * radius;
		double ribs = hills_noise.GetNoise(
				(float)point.x, (float)point.y, (float)point.z);
		target += ribs * 18.0 * cone * (1.0 - crater) * detail_fade;
	}

	double angle = std::atan2(coordinates.y, coordinates.x);
	target -= volcano_channel(distance, angle);
	double shaped = lerpd(p_height, target, influence);
	return volcano_pool_basin(coordinates, shaped);
}

Dictionary PlanetField::sample(const Vector3 &p_direction) const {
	// The parts an elevation was made of. Surveys need them to tell a river from
	// a lake, which the finished height cannot say. Built from the same helpers
	// as `elevation` so the two cannot drift, which is also why it is here rather
	// than left behind in GDScript: a second copy of this arithmetic in another
	// language is a copy that will disagree eventually, and the disagreement
	// would show up as a survey naming the wrong terrain rather than as anything
	// obviously broken.
	Dictionary out;
	Vector3 point = p_direction * radius;
	double continent = continent_noise.GetNoise(
							   (float)point.x, (float)point.y, (float)point.z) +
			sea_bias;
	out["continent"] = continent;
	if (continent <= 0.0) {
		out["elevation"] = freeze(p_direction, sea_floor(point, continent, 0.0));
		out["dry"] = 0.0;
		out["river"] = 0.0;
		out["lake"] = 0.0;
		out["rough"] = 0.0;
		out["arid"] = 0.0;
	} else {
		double inland = clampd(continent / CONTINENT_SPAN, 0.0, 1.0);
		double rough = roughness_at(point);
		double arid = arid_at(point, inland);
		double dry = relief(point, inland, rough, arid, 0.0);
		double lake = lake_cut(point, dry, rough, 0.0);
		double river = river_cut(point, dry - lake, arid, 0.0);
		out["elevation"] = freeze(
				p_direction, mesa(point, dry - lake - river, arid, 0.0));
		out["dry"] = dry;
		out["river"] = river;
		out["lake"] = lake;
		out["rough"] = rough;
		out["arid"] = arid;
	}

	double volcanic = volcano_influence(p_direction);
	if (volcanic > 0.0) {
		out["elevation"] = volcano_height(
				p_direction, (double)out["elevation"], 0.0);
		out["dry"] = std::max((double)out["dry"], volcanic);
		out["river"] = 0.0;
		out["lake"] = 0.0;
		out["rough"] = std::max((double)out["rough"], volcanic);
		out["arid"] = std::max((double)out["arid"], volcanic);
	}
	out["volcano"] = volcanic;
	return out;
}

double PlanetField::freeze(const Vector3 &p_direction, double p_height) const {
	if (p_height >= ICE_TOP) {
		return p_height;
	}
	double chill = frost(p_direction);
	if (chill <= 0.0) {
		return p_height;
	}
	return lerpd(p_height, ICE_TOP, chill);
}

double PlanetField::roughness_at(const Vector3 &p_point) const {
	double value = roughness_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	return smoothstep(0.42, 0.86, value * 0.5 + 0.5);
}

double PlanetField::arid_at(const Vector3 &p_point, double p_inland) const {
	if (aridity <= 0.0) {
		return 0.0;
	}
	double field = arid_noise.GetNoise((float)p_point.x, (float)p_point.y, (float)p_point.z);
	return smoothstep(arid_edge - 0.14, arid_edge + 0.14, field) *
			smoothstep(0.03, 0.22, p_inland);
}

double PlanetField::sea_floor(const Vector3 &p_point, double p_continent,
		double p_spacing) const {
	double out = clampd(-p_continent / abyss_span, 0.0, 1.0);
	double depth = shelf_depth * smoothstep(0.0, shelf_break, out) +
			(ocean_depth - shelf_depth) * smoothstep(shelf_break, 1.0, out);
	double hills = hills_noise.GetNoise((float)p_point.x, (float)p_point.y, (float)p_point.z);
	double relief_value = hills * seabed_relief *
			smoothstep(hill_wavelength, hill_wavelength * RESOLVE_FLOOR, p_spacing) *
			smoothstep(0.0, seabed_relief * 2.0, depth);
	return relief_value - depth;
}

double PlanetField::mountains(const Vector3 &p_point, double p_rough) const {
	// Both fields folded about zero. `1 - |fbm|` turns the contour where the
	// noise changed sign into a crest, which is why ranges out of this run in
	// lines instead of sitting about as lumps: a zero set is a line, a peak is
	// not.
	double crest = 1.0 - std::abs(mountain_noise.GetNoise(
									(float)p_point.x, (float)p_point.y, (float)p_point.z));
	double massif = 1.0 - std::abs(massif_noise.GetNoise(
									 (float)p_point.x, (float)p_point.y, (float)p_point.z));
	// Mixed rather than multiplied, and the ramp below is what makes that the
	// right way round. Multiplying would thin every ridge it kept, because a
	// crest at full height still gets scaled down by whatever the broad field
	// happens to be under it. Mixing leaves the crests alone and lets the ramp
	// do the gating instead: with the black stop up where it is, a fine crest
	// only clears the floor in country where the broad field is already high, so
	// the two fields select each other without either being diluted.
	double shaped = ramp(lerpd(crest, massif, mountain_mix), mountain_plain, mountain_peak);
	if (shaped <= 0.0) {
		return 0.0;
	}
	// The exponent acts on the ramp's 0..1 and not on the raw field, which is
	// the whole difference between this and the cubed ridge it replaces. Cubing
	// raw noise pulls the entire range down at once, so it flattens the plains
	// and the summits together and the only thing left standing is a thin crease
	// along every zero contour at every octave — which is the speckle of sharp
	// little spikes this planet was covered in. Here the plains are already flat
	// before the exponent is reached, and all it decides is the profile of the
	// climb between plain and summit: above 1 concave, so a spire; below 1
	// convex, so a dome.
	//
	// Sharpened further in rough country, because that is where the request for
	// sharp points actually belongs. The same field already decides how tall the
	// mountains are, so crags now come with the terrain that ought to have them
	// and the quiet country keeps rounded hills instead of getting a share of
	// everything.
	return std::pow(shaped,
			lerpd(mountain_sharpness, mountain_sharpness * mountain_crag, p_rough));
}

double PlanetField::relief(const Vector3 &p_point, double p_inland, double p_rough,
		double p_arid, double p_spacing) const {
	double height = std::pow(p_inland, 1.4) * land_height;
	double ashore = smoothstep(0.0, 0.1, p_inland);

	// All three terms below are gated before their noise is read rather than
	// after. Each was already multiplied by exactly these factors, so no height
	// anywhere changes by a millimetre — but the mountain term is two fields and
	// eight octaves now, and a chunk seen from orbit was reading every one of
	// them in order to multiply the result by a zero that was known in advance.
	// Between the spacing fade and the roughness field this skips the whole
	// mountain read over most of the planet, which is what pays for the second
	// field being there at all.
	double mountain_fade = smoothstep(mountain_wavelength,
			mountain_wavelength * RESOLVE_FLOOR, p_spacing);
	double mountain_reach = smoothstep(0.05, 0.45, p_inland);
	double mountain_room = mountain_height * p_rough * (1.0 - 0.66 * p_arid);
	if (mountain_fade > 0.0 && mountain_reach > 0.0 && mountain_room > 0.0) {
		height += mountains(p_point, p_rough) * mountain_room * mountain_reach * mountain_fade;
	}

	double hill_fade = smoothstep(hill_wavelength, hill_wavelength * RESOLVE_FLOOR, p_spacing);
	if (hill_fade > 0.0 && ashore > 0.0) {
		double hills = hills_noise.GetNoise(
				(float)p_point.x, (float)p_point.y, (float)p_point.z);
		height += (hills * 0.5 + 0.5) * hill_height * (0.2 + 0.8 * p_rough) *
				(1.0 - 0.55 * p_arid) * ashore * hill_fade;
	}

	double detail_fade = smoothstep(detail_wavelength,
			detail_wavelength * RESOLVE_FLOOR, p_spacing);
	if (detail_fade > 0.0 && ashore > 0.0) {
		double detail = detail_noise.GetNoise(
				(float)p_point.x, (float)p_point.y, (float)p_point.z);
		height += detail * detail_height * ashore * detail_fade;
	}
	return height;
}

double PlanetField::river_cut(const Vector3 &p_point, double p_height, double p_arid,
		double p_spacing) const {
	if (p_height <= 0.0) {
		return 0.0;
	}
	double reach = river_channel * 2.0;
	double resolves = smoothstep(reach, reach * RESOLVE_FLOOR, p_spacing);
	if (resolves <= 0.0) {
		return 0.0;
	}
	double rivers = rivers_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	double channel = 1.0 - std::abs(rivers);
	double across = smoothstep(1.0 - river_width, 1.0, channel);
	double cut = 0.0;
	if (across > 0.0) {
		cut = river_depth * across * resolves * (1.0 - smoothstep(90.0, 380.0, p_height));
	}
	if (p_arid > 0.0 && canyon_depth > 0.0) {
		double slot = smoothstep(1.0 - canyon_width, 1.0, channel);
		if (slot > 0.0) {
			cut += canyon_depth * slot * p_arid * resolves *
					smoothstep(0.0, canyon_depth * 1.2, p_height);
		}
	}
	return cut;
}

double PlanetField::lake_cut(const Vector3 &p_point, double p_height, double p_rough,
		double p_spacing) const {
	double basin = lake_wavelength * 0.35;
	double resolves = smoothstep(basin, basin * RESOLVE_FLOOR, p_spacing);
	if (resolves <= 0.0) {
		return 0.0;
	}
	double lakes = lakes_noise.GetNoise((float)p_point.x, (float)p_point.y, (float)p_point.z);
	double level = lakes * 0.5 + 0.5;
	double pool = smoothstep(lake_threshold, lake_threshold + 0.14, level);
	if (pool <= 0.0) {
		return 0.0;
	}
	return lake_depth * pool * resolves * (1.0 - p_rough) *
			(1.0 - smoothstep(70.0, 240.0, p_height));
}

double PlanetField::hoodoos(const Vector3 &p_point, double p_into, double p_arid,
		double p_spacing) const {
	double span = hoodoo_wavelength * 1.5;
	double resolves = smoothstep(span, span * RESOLVE_FLOOR, p_spacing);
	if (resolves <= 0.0) {
		return 0.0;
	}
	double lip = smoothstep(0.0, terrace_riser, p_into) *
			(1.0 - smoothstep(terrace_riser, terrace_riser * 2.2, p_into));
	if (lip <= 0.0) {
		return 0.0;
	}
	// Whether this escarpment is hoodoo country at all, which is the difference
	// between a landmark and a texture.
	//
	// `lip` alone is not that test, and cannot be: it is a *contour*, so it
	// traces every bench in the desert at once and puts columns along all of
	// them. That reads as a picket fence rather than as rock, and it gets worse
	// exactly where the ground gets interesting — as a slope steepens its benches
	// crowd together in plan, so the dashed lines of spires close up into one
	// serrated wall down the side of every canyon. This field is what says which
	// amphitheatres get them, and it is coarse enough that the answer holds for a
	// whole escarpment instead of flickering along it.
	double country = smoothstep(badland_reach - 0.08, badland_reach + 0.08,
			badland_noise.GetNoise((float)p_point.x, (float)p_point.y,
					(float)p_point.z) *
							0.5 +
					0.5);
	if (country <= 0.0) {
		return 0.0;
	}
	double field = hoodoo_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	// How rare a column is, inside the country that has them. The bar was 0.80,
	// and the trouble with 0.80 is that this field averages about 0.74 — so a
	// good third of every lip cleared it and the columns came out shoulder to
	// shoulder. A hoodoo is a survivor, the last of a bench that eroded away
	// around it, and survivors are thin on the ground by definition.
	double top = std::max(0.99, hoodoo_stand + 0.01);
	double spire = smoothstep(hoodoo_stand, top, 1.0 - std::abs(field));
	return hoodoo_height * spire * spire * lip * p_arid * country * resolves;
}

double PlanetField::mesa(const Vector3 &p_point, double p_height, double p_arid,
		double p_spacing) const {
	if (p_arid <= 0.0 || p_height <= 4.0) {
		return p_height;
	}
	double strength = p_arid *
			smoothstep(terrace_span, terrace_span * RESOLVE_FLOOR, p_spacing) *
			smoothstep(4.0, 40.0, p_height);
	if (strength <= 0.0) {
		return p_height;
	}
	double step = std::max(terrace_height, 1.0);
	double layer = std::floor(p_height / step);
	double into = p_height / step - layer;
	double benched = step * (layer + smoothstep(0.0, terrace_riser, into));
	return lerpd(p_height, benched, strength) + hoodoos(p_point, into, p_arid, p_spacing);
}

double PlanetField::elevation(const Vector3 &p_direction, double p_spacing) const {
	Vector3 point = p_direction * radius;
	double continent = continent_noise.GetNoise(
							   (float)point.x, (float)point.y, (float)point.z) +
			sea_bias;
	double height = 0.0;
	if (continent <= 0.0) {
		height = sea_floor(point, continent, p_spacing);
	} else {
		double inland = clampd(continent / CONTINENT_SPAN, 0.0, 1.0);
		double rough = roughness_at(point);
		double arid = arid_at(point, inland);
		height = relief(point, inland, rough, arid, p_spacing);
		height -= lake_cut(point, height, rough, p_spacing);
		height -= river_cut(point, height, arid, p_spacing);
		height = mesa(point, height, arid, p_spacing);
	}
	height = freeze(p_direction, height);
	return volcano_height(p_direction, height, p_spacing);
}

Color PlanetField::strata(const Vector3 &p_point, double p_height, double p_slope) const {
	double course = p_height / std::max(stratum_height, 0.5);
	double into = course - std::floor(course);
	Color rock = MESA_MAROON.lerp(MESA_RED, (float)smoothstep(0.0, 0.34, into));
	rock = rock.lerp(MESA_ORANGE, (float)smoothstep(0.30, 0.66, into));
	rock = rock.lerp(MESA_CREAM, (float)smoothstep(0.62, 0.94, into));
	double roughness = roughness_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	double drift = roughness * 0.5 + 0.5;
	rock = rock.lerp(MESA_RED, (float)(drift * 0.18));
	double bare = smoothstep(0.08, 0.40, p_slope);
	Color dusted = DESERT_FLOOR.lerp(rock, 0.62f);
	return dusted.lerp(rock, (float)bare);
}

Color PlanetField::whiten(const Vector3 &p_direction, double p_height,
		const Color &p_ground) const {
	double chill = frost(p_direction);
	if (chill <= 0.0) {
		return p_ground;
	}
	double ashore = smoothstep(ICE_TOP, ICE_TOP + 1.5, p_height);
	Color arctic = ICE.lerp(SNOW, (float)ashore);
	arctic.a = (float)(SEA_ICE_WETNESS * (1.0 - ashore));
	return p_ground.lerp(arctic, (float)chill);
}

Color PlanetField::color_at(const Vector3 &p_direction, double p_height,
		const Vector3 &p_normal) const {
	if (p_height <= 0.0) {
		// Returns before `whiten`, as the GDScript does. Frozen sea never
		// reaches here: `freeze` has already lifted it to ICE_TOP, which is
		// above zero, so pack ice is coloured by the land branch below.
		double depth = smoothstep(-1.0, -70.0, p_height);
		Color water = DEEP_WATER.lerp(SHALLOW_WATER, (float)(1.0 - depth));
		water.a = (float)lerpd(SHORE_WETNESS, 1.0, depth);
		return water;
	}
	Color ground = SHORE.lerp(GRASS, (float)smoothstep(0.5, 7.0, p_height));
	ground = ground.lerp(UPLAND, (float)smoothstep(25.0, 110.0, p_height));
	ground = ground.lerp(ROCK, (float)smoothstep(150.0, 300.0, p_height));
	ground = ground.lerp(SNOW, (float)smoothstep(330.0, 460.0, p_height));
	double slope = 1.0 - clampd(p_normal.dot(p_direction.normalized()), 0.0, 1.0);
	ground = ground.lerp(ROCK, (float)smoothstep(0.32, 0.62, slope));
	Vector3 point = p_direction * radius;
	double arid = arid_at(point, 1.0);
	if (arid > 0.0) {
		ground = ground.lerp(strata(point, p_height, slope), (float)arid);
	}
	double volcanic = volcano_influence(p_direction);
	if (volcanic > 0.0) {
		double soot = hills_noise.GetNoise(
				(float)point.x, (float)point.y, (float)point.z) * 0.5 + 0.5;
		Color basalt = VOLCANIC_BASALT.lerp(
				VOLCANIC_ASH, (float)(0.24 + soot * 0.52));
		double oxide = smoothstep(0.74, 0.94,
				roughness_noise.GetNoise(
					(float)point.x, (float)point.y, (float)point.z) * 0.5 + 0.5);
		basalt = basalt.lerp(VOLCANIC_OXIDE, (float)(oxide * 0.32));
		ground = ground.lerp(basalt, (float)volcanic);
	}
	ground.a = 0.0f;
	return whiten(p_direction, p_height, ground);
}
