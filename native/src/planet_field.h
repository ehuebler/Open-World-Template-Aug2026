#ifndef PLANET_FIELD_H
#define PLANET_FIELD_H

// The planet's height field, natively. This is `PlanetShape`'s arithmetic and
// nothing else: no towns, no exported tuning of its own, no state that outlives
// a call. `PlanetShape` stays the owner — it holds the numbers, the towns and
// the shoreline solve, and hands them here through `configure`.
//
// It exists because a chunk build is this function a few thousand times and
// essentially nothing else, so its cost *is* how long a new place takes to
// sharpen. In GDScript a sample was 4.7 us, of which only about half was noise
// and the rest was call overhead and interpreted arithmetic.
//
// Every method is const and reads only what `configure` wrote, which is what
// makes it safe on the mesh worker threads the way the GDScript it replaces was.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include "thirdparty/FastNoiseLite.h"

namespace godot {

class PlanetField : public RefCounted {
	GDCLASS(PlanetField, RefCounted)

protected:
	static void _bind_methods();

public:
	PlanetField();

	// Takes every number `PlanetShape` exports, by the same names. A dictionary
	// rather than a method per field because the alternative is fifty setters
	// that all have to be kept in step with the resource by hand, and a name
	// missing from here is a number silently left at its default.
	void configure(const Dictionary &p_settings);

	// The natural ground, before any town is laid over it. Metres from sea level.
	double elevation(const Vector3 &p_direction, double p_spacing) const;

	// The biome colour, with wetness in alpha. Takes the normal rather than
	// working it out, because the caller already has one from its own grid.
	Color color_at(const Vector3 &p_direction, double p_height,
			const Vector3 &p_normal) const;

	double frost(const Vector3 &p_direction) const;
	Dictionary sample(const Vector3 &p_direction) const;

	// Solved here rather than in GDScript so the quantile is taken over the same
	// noise the rest of the field reads. Everything on the planet is measured
	// from it, so a value a hair out moves every coastline in the world.
	double solve_sea_bias(int p_samples, double p_fraction);

	double get_sea_bias() const { return sea_bias; }
	void set_sea_bias(double p_bias) { sea_bias = p_bias; }
	double get_arid_edge() const { return arid_edge; }
	double noise_at(const String &p_field, const Vector3 &p_direction) const;
	Dictionary build_patch(const Vector3 &p_face_origin, const Vector3 &p_face_u,
			const Vector3 &p_face_v, const Vector2 &p_offset, double p_size,
			int p_resolution, double p_spacing, double p_skirt,
			const Vector3 &p_chunk_origin, bool p_want_collision) const;

	static Vector3 even_direction(int p_index, int p_count);

private:
	// One field per feature, configured exactly as `PlanetShape._make_noise`
	// does: OpenSimplex2S, FBm, the wavelength's reciprocal as frequency, and a
	// per-field offset on the shared seed.
	FastNoiseLite continent_noise;
	FastNoiseLite mountain_noise;
	// The second, coarser ridge field the mountains are shaped against. See
	// `mountains()`; it is what gathers peaks into ranges instead of scattering
	// them, and it is the only field here that exists to modify another.
	FastNoiseLite massif_noise;
	FastNoiseLite hills_noise;
	FastNoiseLite detail_noise;
	FastNoiseLite rivers_noise;
	FastNoiseLite roughness_noise;
	FastNoiseLite lakes_noise;
	FastNoiseLite arid_noise;
	FastNoiseLite hoodoo_noise;
	// Which escarpments are hoodoo country and which are bare rock. See
	// `hoodoos()`; without it every bench on the planet grows them.
	FastNoiseLite badland_noise;

	void setup_noise(FastNoiseLite &r_noise, double p_wavelength, int p_octaves,
			int p_seed_offset) const;
	Vector3 grid_normal(const Vector3 *p_field, const float *p_heights,
			int p_side, int p_row, int p_col) const;

	double sea_floor(const Vector3 &p_point, double p_continent, double p_spacing) const;
	double arid_at(const Vector3 &p_point, double p_inland) const;
	// The mountain field's shape, 0..1, before it is given a height. Split out
	// of `relief` because it is now six lines of graph rather than one term.
	double mountains(const Vector3 &p_point, double p_rough) const;
	double relief(const Vector3 &p_point, double p_inland, double p_rough,
			double p_arid, double p_spacing) const;
	double river_cut(const Vector3 &p_point, double p_height, double p_arid,
			double p_spacing) const;
	double lake_cut(const Vector3 &p_point, double p_height, double p_rough,
			double p_spacing) const;
	double mesa(const Vector3 &p_point, double p_height, double p_arid,
			double p_spacing) const;
	double hoodoos(const Vector3 &p_point, double p_into, double p_arid,
			double p_spacing) const;
	double roughness_at(const Vector3 &p_point) const;
	double freeze(const Vector3 &p_direction, double p_height) const;
	double volcano_influence(const Vector3 &p_direction) const;
	Vector3 volcano_coordinates(const Vector3 &p_direction) const;
	double volcano_height(const Vector3 &p_direction, double p_height,
			double p_spacing) const;
	double volcano_channel(double p_distance, double p_angle) const;
	double volcano_pool_radius(double p_base, double p_angle, int p_seed) const;
	double volcano_one_pool_basin(const Vector2 &p_coordinates,
			const Vector2 &p_centre, double p_radius, double p_surface,
			int p_seed, double p_height) const;
	double volcano_pool_basin(const Vector3 &p_coordinates,
			double p_height) const;
	Color strata(const Vector3 &p_point, double p_height, double p_slope) const;
	Color whiten(const Vector3 &p_direction, double p_height, const Color &p_ground) const;

	// Written by `configure` from `PlanetShape`, which owns them. The values here
	// are only what an unconfigured field would answer; nothing in the game ever
	// sees them, and they are not a second opinion about the planet's palette.
	double CONTINENT_SPAN = 0.55;
	double RESOLVE_FLOOR = 0.33;
	double SHORE_WETNESS = 0.2;
	double ICE_TOP = 3.0;
	double SEA_ICE_WETNESS = 0.3;
	Color DEEP_WATER, SHALLOW_WATER, SHORE, GRASS, UPLAND, ROCK, SNOW, ICE;
	Color MESA_MAROON, MESA_RED, MESA_ORANGE, MESA_CREAM, DESERT_FLOOR;
	Color VOLCANIC_BASALT, VOLCANIC_ASH, VOLCANIC_OXIDE;

	double radius = 8000.0;
	int noise_seed = 20260801;

	double continent_wavelength = 8200.0;
	double mountain_wavelength = 1500.0;
	double massif_wavelength = 3800.0;
	double hill_wavelength = 300.0;
	double detail_wavelength = 52.0;
	double river_wavelength = 2400.0;
	double roughness_wavelength = 3600.0;
	double lake_wavelength = 950.0;

	double ocean_depth = 480.0;
	double shelf_depth = 22.0;
	double shelf_break = 0.16;
	double abyss_span = 0.32;
	double seabed_relief = 34.0;
	double land_height = 260.0;
	double mountain_height = 400.0;
	double mountain_mix = 0.45;
	double mountain_plain = 0.72;
	double mountain_peak = 1.0;
	double mountain_sharpness = 2.6;
	double mountain_crag = 1.8;
	double hill_height = 24.0;
	double detail_height = 2.4;
	double river_depth = 45.0;
	double lake_depth = 38.0;

	double sea_fraction = 0.44;
	double river_width = 0.012;
	double river_channel = 45.0;
	double lake_threshold = 0.60;

	double aridity = 0.66;
	double arid_wavelength = 4600.0;
	double terrace_height = 32.0;
	double terrace_riser = 0.2;
	double terrace_span = 120.0;
	double canyon_depth = 120.0;
	double canyon_width = 0.0035;
	double stratum_height = 11.5;
	double hoodoo_height = 17.0;
	double hoodoo_wavelength = 21.0;
	double hoodoo_stand = 0.94;
	double badland_wavelength = 700.0;
	double badland_reach = 0.62;

	double frost_area = 0.18;
	double frost_blend = 0.06;
	Vector3 frost_axis = Vector3(0, 1, 0);

	bool volcano_enabled = true;
	double volcano_radius = 1450.0;
	double volcano_island_height = 55.0;
	double volcano_cone_radius = 980.0;
	double volcano_cone_height = 500.0;
	double volcano_crater_radius = 190.0;
	double volcano_crater_depth = 145.0;
	Vector3 volcano_flow_angles = Vector3(0.65, -1.55, 2.55);
	double volcano_channel_width = 34.0;
	double volcano_channel_depth = 135.0;
	Vector3 volcano_pool_one = Vector3(760.0, 130.0, 126.0);
	Vector3 volcano_pool_two = Vector3(870.0, 105.0, 76.0);
	Vector3 volcano_pool_three = Vector3(810.0, 120.0, 100.0);
	double volcano_pool_depth = 10.0;
	double volcano_pool_shore_width = 18.0;
	double volcano_pool_shore_overlap = 0.25;
	double volcano_crater_lava_height = 420.0;

	// Solved or derived at configure time, exactly as `PlanetShape.prepare` does.
	double sea_bias = 0.0;
	double arid_edge = 0.0;
	double frost_edge = 0.0;
	double frost_full = 0.0;
	Vector3 pole = Vector3(0, 1, 0);
	Vector3 volcano_pole = Vector3(0, -1, 0);
	Vector3 volcano_east = Vector3(0, 0, 1);
	Vector3 volcano_north = Vector3(-1, 0, 0);
};

} // namespace godot

#endif // PLANET_FIELD_H
