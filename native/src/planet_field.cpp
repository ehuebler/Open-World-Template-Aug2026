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

	frost_area = setting(p_settings, "frost_area", frost_area);
	frost_blend = setting(p_settings, "frost_blend", frost_blend);
	if (p_settings.has("frost_axis")) {
		frost_axis = p_settings["frost_axis"];
	}

	setup_noise(continent_noise, continent_wavelength, 5, 0);
	setup_noise(mountain_noise, mountain_wavelength, 5, 101);
	setup_noise(hills_noise, hill_wavelength, 3, 202);
	setup_noise(detail_noise, detail_wavelength, 2, 303);
	setup_noise(rivers_noise, river_wavelength, 3, 404);
	setup_noise(roughness_noise, roughness_wavelength, 2, 505);
	setup_noise(lakes_noise, lake_wavelength, 3, 606);
	setup_noise(arid_noise, arid_wavelength, 3, 707);
	setup_noise(hoodoo_noise, hoodoo_wavelength, 2, 808);

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
	}

	arid_edge = lerpd(-0.5, 0.5, 1.0 - aridity);
	pole = frost_axis.length_squared() > 0.0 ? frost_axis.normalized() : Vector3(0, 1, 0);
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
		return out;
	}
	double inland = clampd(continent / CONTINENT_SPAN, 0.0, 1.0);
	double rough = roughness_at(point);
	double arid = arid_at(point, inland);
	double dry = relief(point, inland, rough, arid, 0.0);
	double lake = lake_cut(point, dry, rough, 0.0);
	double river = river_cut(point, dry - lake, arid, 0.0);
	out["elevation"] = freeze(p_direction, mesa(point, dry - lake - river, arid, 0.0));
	out["dry"] = dry;
	out["river"] = river;
	out["lake"] = lake;
	out["rough"] = rough;
	out["arid"] = arid;
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

double PlanetField::relief(const Vector3 &p_point, double p_inland, double p_rough,
		double p_arid, double p_spacing) const {
	double height = std::pow(p_inland, 1.4) * land_height;
	double ashore = smoothstep(0.0, 0.1, p_inland);
	double mountain = mountain_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	double ridge = 1.0 - std::abs(mountain);
	height += std::pow(ridge, 3.0) * mountain_height * p_rough * (1.0 - 0.66 * p_arid) *
			smoothstep(0.05, 0.45, p_inland) *
			smoothstep(mountain_wavelength, mountain_wavelength * RESOLVE_FLOOR, p_spacing);
	double hills = hills_noise.GetNoise((float)p_point.x, (float)p_point.y, (float)p_point.z);
	height += (hills * 0.5 + 0.5) * hill_height * (0.2 + 0.8 * p_rough) *
			(1.0 - 0.55 * p_arid) * ashore *
			smoothstep(hill_wavelength, hill_wavelength * RESOLVE_FLOOR, p_spacing);
	double detail = detail_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	return height + detail * detail_height * ashore *
			smoothstep(detail_wavelength, detail_wavelength * RESOLVE_FLOOR, p_spacing);
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
	double field = hoodoo_noise.GetNoise(
			(float)p_point.x, (float)p_point.y, (float)p_point.z);
	double spire = 1.0 - std::abs(field);
	spire = smoothstep(0.80, 0.99, spire);
	return hoodoo_height * spire * spire * lip * p_arid * resolves;
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
	return freeze(p_direction, height);
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
	ground.a = 0.0f;
	return whiten(p_direction, p_height, ground);
}
