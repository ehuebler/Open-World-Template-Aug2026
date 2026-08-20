@tool
class_name AerialSwarm
extends Node3D

## A deterministic, surface-following cloud of insects.
##
## Each cluster is one MultiMesh and each insect is only one transform, one
## colour and four custom floats. There are no insect nodes, velocities or
## integration state. Cluster orbits, individual weaving and hovering are
## closed-form functions of the clock, so a cluster can stop simulating at range
## and resume later without drifting or needing to catch up.
##
## The CPU samples PlanetShape once per cluster pose, not once per insect. That
## sample supplies a tangent plane which follows the terrain beneath the whole
## small cluster. Full MultiMesh buffers are uploaded at distance-dependent
## rates, with a hard per-frame cap. The companion shader keeps glow, twinkle,
## twilight and the final distance shrink smooth between those CPU updates.
##
## LOCALIZED scatters permanent clusters around [member anchor_direction].
## VIEWER_CENTERED streams stable cube-sphere cells around Planet's viewer; a
## given cell always receives the same placement, formation, colours and timing.

const SWARM_SHADER := preload("res://shaders/vivid/vivid_swarm.gdshader")
const NIGHT_PHENOMENA_SHADER := preload(
	"res://shaders/vivid/vivid_night_phenomena.gdshader")

const STRIDE := 20
const COLOUR_OFFSET := 12
const CUSTOM_OFFSET := 16
const INVALID_KEY := Vector3i(-99, -99, -99)
const LOCAL_FACE := -1
const PLACEMENT_ATTEMPTS := 48
const PLACEMENT_CACHE_LIMIT := 2048

enum PlacementMode {
	LOCALIZED,
	VIEWER_CENTERED,
}

enum VariantMode {
	PRIMARY_ONLY,
	ALTERNATE_CLUSTERS,
	RANDOM_PER_CLUSTER,
}

enum ForwardAxis {
	POSITIVE_X,
	NEGATIVE_X,
	POSITIVE_Z,
	NEGATIVE_Z,
}

@export_category("Appearance")
## A scene containing the insect mesh. The scene itself is never instanced into
## the world; the largest MeshInstance3D in it is extracted for the MultiMeshes.
@export var model: PackedScene
## Optional material. When empty, a ShaderMaterial using vivid_swarm is created.
## A supplied material is duplicated before runtime-controlled uniforms change.
@export var material: ShaderMaterial
## Optional second mesh/material family. Either resource may be omitted: the
## corresponding primary resource is reused.
@export var second_model: PackedScene
@export var second_material: ShaderMaterial
@export var variant_mode: VariantMode = VariantMode.RANDOM_PER_CLUSTER
@export_range(0.0, 1.0) var second_variant_chance := 0.35
## Longest authored mesh dimension is normalised to this many metres.
@export_range(0.005, 10.0, 0.005, "or_greater") var insect_size := 0.11
@export_range(0.0, 0.9) var size_variation := 0.24
## Local direction the authored body points along. Local +Y remains its up.
@export var model_forward_axis: ForwardAxis = ForwardAxis.NEGATIVE_Z

@export_group("Instance colour")
@export var random_colours := false
@export_range(0.0, 1.0) var colour_saturation := 0.62
@export_range(0.0, 4.0) var colour_brightness := 1.0

@export_category("Distribution")
@export var placement_mode: PlacementMode = PlacementMode.LOCALIZED
## Optional explicit Planet. Empty means the nearest Planet ancestor.
@export var planet_path: NodePath
## Optional GroundCover whose public terrain_claims() classifier is used for
## ground_layer. If absent, the same four-way scoring is evaluated locally.
@export var terrain_claims: NodePath
## Zero derives the anchor from this node's location, then from the viewer.
@export var anchor_direction := Vector3.ZERO
## Radius of a localized swarm field around the anchor, in surface metres.
@export_range(0.0, 100000.0, 1.0, "or_greater") var localized_spread := 110.0
## Total insects, shared exactly across the effective cluster slots.
@export_range(1, 48000) var instance_count := 420
@export_range(1, 64) var cluster_count := 14
@export var random_seed := 20260810

@export_group("Viewer-centred streaming")
## Approximate stable-cell width. Larger values make global clusters sparser.
@export_range(4.0, 1000.0, 1.0, "or_greater") var global_cluster_spacing := 48.0
## Cells are considered inside this surface radius around the viewer.
@export_range(8.0, 10000.0, 1.0, "or_greater") var global_search_radius := 300.0
@export_range(0.1, 10.0, 0.05, "or_greater") var global_survey_interval := 0.5
## Surface travel before another survey is useful.
@export_range(1.0, 1000.0, 1.0, "or_greater") var global_recenter_distance := 16.0
## Bounds terrain queries when filters make suitable cells rare.
@export_range(16, 1024) var global_candidate_limit := 256

@export_category("Ground filters")
@export var ground_layer: PlantSpecies.Ground = PlantSpecies.Ground.ANYWHERE
@export_range(0.0, 1.0) var minimum_ground_claim := 0.0
@export_range(0.0, 1.0) var minimum_arid := 0.0
@export_range(0.0, 1.0) var maximum_arid := 1.0
@export_range(0.0, 1.0) var minimum_frost := 0.0
@export_range(0.0, 1.0) var maximum_frost := 1.0
@export var minimum_elevation := 1.0
@export var maximum_elevation := 600.0
@export_range(0.0, 89.0) var minimum_slope := 0.0
@export_range(0.0, 89.0) var maximum_slope := 30.0
## Rivers and lakes can be above sea level; this keeps land swarms off them.
@export var avoid_inland_water := true

@export_category("Flight")
@export_range(0.0, 100.0, 0.05, "or_greater") var hover_minimum := 0.7
@export_range(0.0, 100.0, 0.05, "or_greater") var hover_maximum := 2.8
## Radius of an insect formation around its moving cluster centre.
@export_range(0.05, 100.0, 0.05, "or_greater") var cluster_radius := 3.2
## Radius and tangential speed of the cluster's closed surface orbit.
@export_range(0.0, 1000.0, 0.1, "or_greater") var cluster_orbit := 7.0
@export_range(0.0, 100.0, 0.05, "or_greater") var cruise_speed := 1.25
## Individual lateral weave and vertical hover bob.
@export_range(0.0, 20.0, 0.01, "or_greater") var weave_amount := 0.52
@export_range(0.0, 20.0, 0.01, "or_greater") var weave_rate := 1.8
@export_range(0.0, 20.0, 0.01, "or_greater") var hover_bob := 0.34
@export_range(0.0, 20.0, 0.01, "or_greater") var hover_rate := 1.15
@export_range(0.0, 45.0, 0.5) var roll_degrees := 9.0

@export_group("Avoiding players")
@export var avoidance_group: StringName = &"network_players"
@export_range(0.0, 100.0, 0.1, "or_greater") var avoid_reach := 3.8
@export_range(0.0, 100.0, 0.1, "or_greater") var avoid_push := 2.7
@export_range(0.0, 1.0) var avoid_turn := 0.78

@export_category("Distance budget")
@export_range(1.0, 10000.0, 1.0, "or_greater") var simulate_within := 170.0
@export_range(1.0, 10000.0, 1.0, "or_greater") var draw_within := 250.0
## The shader shrinks solid geometry over this band; it never alpha-blends the
## swarm, avoiding the crawling/boiling edge tiny transparent insects produce.
@export_range(0.0, 10000.0, 1.0, "or_greater") var distance_fade_from := 205.0
@export_range(0.0, 1000.0, 1.0, "or_greater") var distance_fade_stagger := 10.0
@export_range(1.0, 1000.0, 1.0, "or_greater") var pose_near_within := 45.0
@export_range(1.0, 120.0, 1.0) var pose_rate_near := 40.0
@export_range(1.0, 60.0, 1.0) var pose_rate_far := 12.0
## Hard cap on complete MultiMesh buffer assignments in one rendered frame.
@export_range(1, 16) var max_buffer_uploads_per_frame := 3

@export_category("Night")
## Hides bodies as well as glow during local day. The shader performs a smooth
## twilight shrink; CPU visibility only removes clusters once that reaches zero.
@export var night_only := false
## Firefly emission can remain night-gated when ordinary bugs remain visible.
@export var glow_night_only := true

@export_category("Pooled terrain lights")
## Emission itself is per insect on the GPU. These few lights only cast that glow
## onto nearby terrain and players.
@export_range(0, 12) var light_limit := 5
@export_range(0.0, 100.0, 0.1, "or_greater") var light_range := 7.0
@export_range(0.0, 32.0, 0.05, "or_greater") var light_energy := 1.25
@export var light_colour := Color(0.72, 1.0, 0.35)
@export var light_use_cluster_colour := true
@export var lights_night_only := true
@export_range(1.0, 1000.0, 1.0, "or_greater") var lights_within := 72.0
@export_range(0.5, 30.0, 0.5, "or_greater") var light_assignment_rate := 4.0
@export_range(0.1, 30.0, 0.1, "or_greater") var light_follow_speed := 7.0
@export_range(0.1, 30.0, 0.1, "or_greater") var light_fade_speed := 4.0
@export_range(0.0, 0.5) var light_pulse_amount := 0.12
@export_range(0.0, 4.0, 0.05, "or_greater") var light_pulse_speed := 0.34


var _planet: Planet
var _shape: PlanetShape
var _cover: GroundCover
var _grid: SphericalCoverGrid
var _spacing := 1.0

var _meshes: Array[Mesh] = []
var _materials: Array[ShaderMaterial] = []
var _base_scales := PackedFloat32Array()
var _has_second_variant := false

## Fixed slots. In localized mode each is permanent; global mode reassigns a
## slot to a deterministic spherical cell while preserving slots still wanted.
var _clusters: Array[Dictionary] = []
var _slot_count := 0
var _clock := 0.0
var _uploads_last_frame := 0
var _visible_clusters := 0
var _visible_insects := 0

var _placement_cache := {}
var _survey_generation := 0
var _since_survey := INF
var _surveyed_at := Vector3.INF

var _lights: Array[OmniLight3D] = []
var _light_clusters: Array[int] = []
var _desired_light_clusters: Array[int] = []
var _since_light_assignment := INF


func _ready() -> void:
	set_process(false)
	set_physics_process(false)
	if Engine.is_editor_hint():
		return
	call_deferred("_build")


func _build() -> void:
	_planet = _find_planet()
	if _planet == null or _planet.shape == null:
		push_error("AerialSwarm must be under, or point to, a Planet")
		return
	_shape = _planet.shape
	_shape.prepare()
	_spacing = _planet.finest_spacing()

	if not terrain_claims.is_empty():
		_cover = get_node_or_null(terrain_claims) as GroundCover
		if _cover == null:
			push_warning("AerialSwarm terrain_claims does not point to GroundCover")

	if model == null:
		push_error("AerialSwarm requires an exported model")
		return
	var primary_mesh := _mesh_from(model)
	if primary_mesh == null:
		push_error("AerialSwarm model contains no MeshInstance3D mesh")
		return
	var alternate_mesh := _mesh_from(second_model) if second_model != null else primary_mesh
	if alternate_mesh == null:
		push_warning("AerialSwarm second_model has no mesh; using the primary model")
		alternate_mesh = primary_mesh
	_meshes.assign([primary_mesh, alternate_mesh])
	_base_scales = PackedFloat32Array([
		_scale_for(primary_mesh),
		_scale_for(alternate_mesh),
	])

	var primary_material := _runtime_material(material)
	var alternate_material := _runtime_material(second_material) \
		if second_material != null else primary_material
	_materials.assign([primary_material, alternate_material])
	_has_second_variant = second_model != null or second_material != null
	for runtime_material in _materials:
		_configure_material(runtime_material)

	_slot_count = mini(cluster_count, instance_count)
	_make_cluster_slots()
	_make_light_pool()

	if placement_mode == PlacementMode.VIEWER_CENTERED:
		_grid = SphericalCoverGrid.new(_shape.radius, global_cluster_spacing)
		_survey_global(_planet.viewer_position(), true)
	else:
		_place_localized()
	set_process(true)


func _find_planet() -> Planet:
	if not planet_path.is_empty():
		var explicit := get_node_or_null(planet_path) as Planet
		if explicit != null:
			return explicit
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor is Planet:
			return ancestor as Planet
		ancestor = ancestor.get_parent()
	return null


func _make_cluster_slots() -> void:
	var placed := 0
	for index in _slot_count:
		var share := (instance_count * (index + 1)) / _slot_count - placed
		placed += share

		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.use_custom_data = true
		multimesh.instance_count = share
		multimesh.mesh = _meshes[0]

		var node := MultiMeshInstance3D.new()
		node.name = "AerialCluster%d" % index
		node.multimesh = multimesh
		node.material_override = _materials[0]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		# Poses are authored in _process and uploaded as complete buffers.
		# Physics interpolation would retain/interpolate another buffer between
		# physics ticks, adding work and producing an engine warning without
		# improving this deliberately low-rate closed-form motion.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		node.visible = false
		add_child(node, false, Node.INTERNAL_MODE_BACK)

		_clusters.append({
			"slot": index,
			"share": share,
			"key": INVALID_KEY,
			"active": false,
			"uploaded": false,
			"node": node,
			"multimesh": multimesh,
			"seats": [],
			"next_pose": 0.0,
			"pose_away": INF,
			"posed_centre": Vector3.INF,
			"light_colour": light_colour,
			"light_phase": 0.0,
			"light_rate": 1.0,
		})


func _make_light_pool() -> void:
	var count := mini(light_limit, _slot_count)
	for index in count:
		var light := OmniLight3D.new()
		light.name = "AerialSwarmLight%d" % index
		light.light_color = light_colour
		light.light_energy = 0.0
		light.omni_range = light_range
		light.shadow_enabled = false
		light.visible = false
		add_child(light, false, Node.INTERNAL_MODE_BACK)
		_lights.append(light)
		_light_clusters.append(-1)
		_desired_light_clusters.append(-1)


func _runtime_material(source: ShaderMaterial) -> ShaderMaterial:
	var runtime := source.duplicate(true) as ShaderMaterial if source != null \
		else ShaderMaterial.new()
	if runtime.shader == null:
		runtime.shader = SWARM_SHADER
	return runtime


func _configure_material(runtime: ShaderMaterial) -> void:
	# Both companion shaders own this visibility contract. Other custom shaders
	# remain allowed, but are not filled with parameters they may not declare.
	var shader_path := runtime.shader.resource_path
	if runtime.shader != SWARM_SHADER and shader_path != SWARM_SHADER.resource_path \
			and runtime.shader != NIGHT_PHENOMENA_SHADER \
			and shader_path != NIGHT_PHENOMENA_SHADER.resource_path:
		return
	runtime.set_shader_parameter(&"distance_fade_from",
		minf(distance_fade_from, draw_within - 0.01))
	runtime.set_shader_parameter(&"distance_fade_to", draw_within)
	runtime.set_shader_parameter(&"distance_fade_stagger", distance_fade_stagger)
	runtime.set_shader_parameter(&"night_only", night_only)
	runtime.set_shader_parameter(&"glow_night_only", glow_night_only)


# --- Placement --------------------------------------------------------------

func _place_localized() -> void:
	var anchor := _resolved_anchor()
	var axes := _tangent_axes(anchor)
	var east: Vector3 = axes[0]
	var north: Vector3 = axes[1]
	for index in _clusters.size():
		var key := Vector3i(LOCAL_FACE, index, 0)
		var rng := _rng_for(key)
		var accepted := {}
		var direction := anchor
		for attempt in PLACEMENT_ATTEMPTS:
			var reach := sqrt(rng.randf()) * localized_spread
			var angle := rng.randf() * TAU
			# Attempt zero still consumes the same deterministic values, but tests
			# the anchor itself first when there is no spread.
			if localized_spread > 0.0:
				direction = (anchor + (east * cos(angle) + north * sin(angle))
					* (reach / _shape.radius)).normalized()
			accepted = _placement(direction)
			if not accepted.is_empty():
				break
		if accepted.is_empty():
			push_warning("AerialSwarm could not place localized cluster %d" % index)
			continue
		_assign_cluster(_clusters[index], key, direction, accepted)


func _resolved_anchor() -> Vector3:
	if anchor_direction.length_squared() > 0.000001:
		return anchor_direction.normalized()
	var local_origin := _planet.to_local(global_position)
	if local_origin.length() > _shape.radius * 0.5:
		return local_origin.normalized()
	var eye := _planet.viewer_position()
	return eye.normalized() if eye.length_squared() > 0.000001 else Vector3.UP


func _survey_global(eye: Vector3, force := false) -> void:
	if _grid == null:
		return
	var eye_direction := eye.normalized() if eye.length_squared() > 0.000001 \
		else _resolved_anchor()
	if not force and _surveyed_at.is_finite():
		var travelled := eye_direction.distance_to(_surveyed_at.normalized()) * _shape.radius
		if travelled < global_recenter_distance:
			return
	_surveyed_at = eye
	_since_survey = 0.0
	_survey_generation += 1

	var candidates := _global_candidate_keys(eye_direction)
	var suitable: Array[Dictionary] = []
	for key in candidates:
		var direction := _direction_for_key(key)
		var accepted := _cached_placement(key, direction)
		if accepted.is_empty():
			continue
		var centre := direction * (_shape.radius + float(accepted["height"])
			+ _middle_hover())
		var away := eye.distance_to(centre)
		if away > maxf(global_search_radius, draw_within) + global_cluster_spacing:
			continue
		suitable.append({
			"key": key,
			"direction": direction,
			"placement": accepted,
			"away": away,
		})
	suitable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["away"]) < float(b["away"]))
	if suitable.size() > _slot_count:
		suitable.resize(_slot_count)

	var wanted := {}
	for candidate in suitable:
		wanted[candidate["key"]] = candidate

	# Keep stable cells in their current slots. This is what prevents a survey
	# from re-uploading every cluster merely because two candidates swapped rank.
	var occupied := {}
	for cluster in _clusters:
		var key: Vector3i = cluster["key"]
		if bool(cluster["active"]) and wanted.has(key):
			occupied[key] = true
		else:
			_deactivate_cluster(cluster)

	for candidate in suitable:
		var key: Vector3i = candidate["key"]
		if occupied.has(key):
			continue
		var slot := _free_cluster()
		if slot.is_empty():
			break
		_assign_cluster(slot, key, candidate["direction"], candidate["placement"])
		occupied[key] = true
	_prune_placement_cache()


func _global_candidate_keys(eye_direction: Vector3) -> Array[Vector3i]:
	var axes := _tangent_axes(eye_direction)
	var east: Vector3 = axes[0]
	var north: Vector3 = axes[1]
	var keys: Array[Vector3i] = []
	var seen := {}
	var reach := maxf(global_search_radius, draw_within)
	var rings := ceili(reach / maxf(global_cluster_spacing, 1.0)) + 2
	for ring in rings + 1:
		for row in range(-ring, ring + 1):
			for col in range(-ring, ring + 1):
				if maxi(absi(col), absi(row)) != ring:
					continue
				var offset := Vector2(col, row) * global_cluster_spacing
				if offset.length() > reach + global_cluster_spacing:
					continue
				var direction := (eye_direction
					+ (east * offset.x + north * offset.y) / _shape.radius).normalized()
				var key := _grid.key_for(direction)
				if seen.has(key):
					continue
				seen[key] = true
				keys.append(key)
				if keys.size() >= global_candidate_limit:
					return keys
	return keys


func _direction_for_key(key: Vector3i) -> Vector3:
	# Jitter stays away from cell borders so a small cube projection distortion
	# cannot put two neighbouring keys almost on top of one another.
	var rng := _rng_for(key)
	return _grid.direction_in(key,
		rng.randf_range(0.18, 0.82), rng.randf_range(0.18, 0.82))


func _cached_placement(key: Vector3i, direction: Vector3) -> Dictionary:
	if _placement_cache.has(key):
		var cached: Dictionary = _placement_cache[key]
		cached["seen"] = _survey_generation
		return cached["placement"]
	var accepted := _placement(direction)
	_placement_cache[key] = {
		"placement": accepted,
		"seen": _survey_generation,
	}
	return accepted


func _prune_placement_cache() -> void:
	if _placement_cache.size() <= PLACEMENT_CACHE_LIMIT:
		return
	var keep_after := _survey_generation - 2
	for key in _placement_cache.keys():
		var cached: Dictionary = _placement_cache[key]
		if int(cached["seen"]) < keep_after:
			_placement_cache.erase(key)
			if _placement_cache.size() <= PLACEMENT_CACHE_LIMIT:
				return


func _placement(direction: Vector3) -> Dictionary:
	var at := direction.normalized()
	var height := _shape.elevation(at, _spacing)
	var low_elevation := minf(minimum_elevation, maximum_elevation)
	var high_elevation := maxf(minimum_elevation, maximum_elevation)
	if height < low_elevation or height > high_elevation:
		return {}

	# sample() supplies climatic/hydrology fields; color_at() and frost() are
	# deliberately queried too, so placement agrees with the terrain actually
	# painted and with the one canonical polar boundary.
	var sample := _shape.sample(at)
	var arid := float(sample.get("arid", 0.0))
	if arid < minf(minimum_arid, maximum_arid) \
			or arid > maxf(minimum_arid, maximum_arid):
		return {}
	var frost := _shape.frost(at)
	if frost < minf(minimum_frost, maximum_frost) \
			or frost > maxf(minimum_frost, maximum_frost):
		return {}
	if avoid_inland_water and (float(sample.get("river", 0.0)) > 0.0
			or float(sample.get("lake", 0.0)) > 0.0):
		return {}

	var normal := _shape.normal_at(at, _spacing)
	var slope := rad_to_deg(acos(clampf(normal.dot(at), -1.0, 1.0)))
	if slope < minf(minimum_slope, maximum_slope) \
			or slope > maxf(minimum_slope, maximum_slope):
		return {}
	var biome := _shape.color_at(at, height, normal)
	if ground_layer != PlantSpecies.Ground.ANYWHERE:
		var claimed := _cover.terrain_claims(at, height, normal, biome,
			ground_layer, minimum_ground_claim) if _cover != null \
			else _fallback_terrain_claim(at, height, normal, biome)
		if not claimed:
			return {}
	return {
		"height": height,
		"normal": normal,
		"biome": biome,
		"arid": arid,
		"frost": frost,
		"slope": slope,
	}


## Fallback for integrations without a GroundCover path. Kept structurally
## identical to GroundCover's public classifier; supplying the path remains
## preferable because future terrain-layer changes then have one owner.
func _fallback_terrain_claim(at: Vector3, height: float, normal: Vector3,
		biome: Color) -> bool:
	var brightest := maxf(maxf(biome.r, biome.g), biome.b)
	var darkest := minf(minf(biome.r, biome.g), biome.b)
	var chroma := brightest - darkest
	var green := clampf((biome.g - maxf(biome.r, biome.b)) * 7.0, 0.0, 1.0)
	var red := clampf((biome.r - maxf(biome.g, biome.b)) * 7.0, 0.0, 1.0)
	var grey := 1.0 - clampf(chroma * 7.0, 0.0, 1.0)
	var cool := clampf((biome.b - biome.r) * 7.0, 0.0, 1.0)
	var pale := maxf(grey, cool) * clampf((brightest - 0.7) * 7.0, 0.0, 1.0)
	var frozen := _shape.frost(at)
	var shore := 1.0 - smoothstep(0.0, 7.0, height)
	var ice := maxf(pale, frozen * 1.3)
	var sand := (red + shore) * (1.0 - minf(ice, 1.0))
	var slope := 1.0 - clampf(normal.dot(at), 0.0, 1.0)
	var cliff := smoothstep(0.22, 0.55, slope)
	var stone := maxf(grey - pale, 0.0) + cliff * 1.1
	var grass := maxf(green, 0.3 - maxf(maxf(sand, stone), ice))
	var scores := [grass, sand, stone, ice]
	var mine: float = scores[ground_layer - 1]
	if mine < minimum_ground_claim:
		return false
	var ahead := 0
	for index in scores.size():
		if index != ground_layer - 1 and float(scores[index]) > mine:
			ahead += 1
	return ahead <= 1


func _assign_cluster(cluster: Dictionary, key: Vector3i, direction: Vector3,
		placement: Dictionary) -> void:
	var rng := _rng_for(key)
	var variant := _variant_for(key, rng)
	var multimesh := cluster["multimesh"] as MultiMesh
	var node := cluster["node"] as MultiMeshInstance3D
	multimesh.mesh = _meshes[variant]
	node.material_override = _materials[variant]

	var signed_rate := cruise_speed / maxf(cluster_orbit, 0.5)
	if rng.randf() < 0.5:
		signed_rate = -signed_rate
	var seats := _formation(int(cluster["share"]), _base_scales[variant], rng)
	var average := Vector3.ZERO
	for seat in seats:
		var tint: Color = seat["tint"]
		average += Vector3(tint.r, tint.g, tint.b)
	if not seats.is_empty():
		average /= float(seats.size())

	var axes := _tangent_axes(direction)
	cluster["key"] = key
	cluster["active"] = true
	cluster["uploaded"] = false
	cluster["direction"] = direction.normalized()
	cluster["height"] = float(placement["height"])
	cluster["centre"] = direction.normalized() * (
		_shape.radius + float(placement["height"]) + _middle_hover())
	cluster["east"] = axes[0]
	cluster["north"] = axes[1]
	cluster["phase"] = rng.randf() * TAU
	cluster["rate"] = signed_rate
	cluster["orbit"] = cluster_orbit * rng.randf_range(0.78, 1.22)
	cluster["seats"] = seats
	cluster["next_pose"] = 0.0
	cluster["posed_centre"] = Vector3.INF
	cluster["light_colour"] = Color(average.x, average.y, average.z) \
		if light_use_cluster_colour and random_colours else light_colour
	cluster["light_phase"] = rng.randf() * TAU
	cluster["light_rate"] = rng.randf_range(0.82, 1.18)
	multimesh.custom_aabb = _cluster_bounds(cluster)
	node.visible = false


func _deactivate_cluster(cluster: Dictionary) -> void:
	if not bool(cluster["active"]):
		return
	cluster["active"] = false
	cluster["uploaded"] = false
	cluster["key"] = INVALID_KEY
	cluster["seats"] = []
	cluster["posed_centre"] = Vector3.INF
	(cluster["node"] as MultiMeshInstance3D).visible = false


func _free_cluster() -> Dictionary:
	for cluster in _clusters:
		if not bool(cluster["active"]):
			return cluster
	return {}


func _variant_for(key: Vector3i, rng: RandomNumberGenerator) -> int:
	if not _has_second_variant or variant_mode == VariantMode.PRIMARY_ONLY:
		return 0
	if variant_mode == VariantMode.ALTERNATE_CLUSTERS:
		return posmod(_cluster_seed(key), 2)
	return 1 if rng.randf() < second_variant_chance else 0


func _formation(count: int, base_scale: float,
		rng: RandomNumberGenerator) -> Array:
	var seats := []
	for index in count:
		var angle := rng.randf() * TAU
		var reach := sqrt(rng.randf()) * cluster_radius
		var tint := Color.WHITE
		if random_colours:
			tint = Color.from_hsv(rng.randf(),
				colour_saturation * rng.randf_range(0.72, 1.0),
				colour_brightness * rng.randf_range(0.82, 1.0))
		seats.append({
			"offset": Vector2(cos(angle), sin(angle)) * reach,
			"hover": rng.randf(),
			"phase": rng.randf() * TAU,
			"phase_b": rng.randf() * TAU,
			"scale": base_scale * rng.randf_range(
				1.0 - size_variation, 1.0 + size_variation),
			"tint": tint,
			# X staggers solid distance shrink. Y and Z are independent
			# twinkle/pulse phases. W varies glow strength.
			"custom": Color(rng.randf(), rng.randf(), rng.randf(),
				rng.randf_range(0.72, 1.0)),
		})
	return seats


# --- Frame budget and closed-form posing -----------------------------------

func _process(delta: float) -> void:
	if not RuntimeTelemetry.deep_enabled():
		_advance(delta)
		return
	var began := Time.get_ticks_usec()
	_advance(delta)
	RuntimeTelemetry.record_process_step(
		&"aerial", &"swarm_process", Time.get_ticks_usec() - began)


func _advance(delta: float) -> void:
	_clock += delta
	_since_survey += delta
	_since_light_assignment += delta
	_uploads_last_frame = 0
	var eye := _planet.viewer_position()

	if placement_mode == PlacementMode.VIEWER_CENTERED \
			and _since_survey >= global_survey_interval:
		_survey_global(eye)

	var due: Array[Dictionary] = []
	_visible_clusters = 0
	_visible_insects = 0
	for cluster in _clusters:
		if not bool(cluster["active"]):
			continue
		var away := eye.distance_to(cluster["centre"] as Vector3) \
			- float(cluster["orbit"]) - cluster_radius - weave_amount \
			- hover_bob - avoid_push - insect_size
		away = maxf(away, 0.0)
		var night := _night_at(cluster["centre"] as Vector3)
		var node := cluster["node"] as MultiMeshInstance3D
		var shown := bool(cluster["uploaded"]) and away < draw_within \
			and (not night_only or night > 0.004)
		if node.visible != shown:
			node.visible = shown
		if shown:
			_visible_clusters += 1
			_visible_insects += int(cluster["share"])

		var first_upload := not bool(cluster["uploaded"]) and away < draw_within
		var live_update := bool(cluster["uploaded"]) and away < simulate_within \
			and _clock >= float(cluster["next_pose"])
		if night_only and night <= 0.004:
			live_update = false
			first_upload = false
		if first_upload or live_update:
			cluster["pose_away"] = away
			due.append(cluster)

	if not due.is_empty():
		due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if bool(a["uploaded"]) != bool(b["uploaded"]):
				return not bool(a["uploaded"])
			return float(a["pose_away"]) < float(b["pose_away"]))
		var players := _players()
		for index in mini(due.size(), max_buffer_uploads_per_frame):
			var cluster := due[index]
			var multimesh := cluster["multimesh"] as MultiMesh
			multimesh.buffer = _pose(cluster, _clock, players)
			cluster["uploaded"] = true
			var rate := lerpf(pose_rate_near, pose_rate_far,
				smoothstep(pose_near_within, simulate_within,
					maxf(float(cluster["pose_away"]), 0.0)))
			cluster["next_pose"] = _clock + 1.0 / maxf(rate, 1.0)
			_uploads_last_frame += 1

	if _since_light_assignment >= 1.0 / maxf(light_assignment_rate, 0.1):
		_since_light_assignment = 0.0
		_choose_light_clusters(eye)
	_update_lights(delta)


func _pose(cluster: Dictionary, seconds: float,
		players: Array[Vector3]) -> PackedFloat32Array:
	var frame := _cluster_frame(cluster, seconds)
	var centre_direction: Vector3 = frame["direction"]
	var surface: Vector3 = frame["surface"]
	var normal: Vector3 = frame["normal"]
	var heading: Vector3 = frame["heading"]
	var side: Vector3 = frame["side"]
	var seats: Array = cluster["seats"]
	var buffer := PackedFloat32Array()
	buffer.resize(seats.size() * STRIDE)
	var planet_to_swarm := global_transform.affine_inverse() * _planet.global_transform

	for index in seats.size():
		var seat: Dictionary = seats[index]
		var offset: Vector2 = seat["offset"]
		var phase: float = float(seat["phase"])
		var phase_b: float = float(seat["phase_b"])
		var beat := seconds * weave_rate + phase
		var along := offset.x + sin(beat * 0.71 + phase_b) * weave_amount * 0.55
		var across := offset.y + sin(beat) * weave_amount
		var hover := lerpf(minf(hover_minimum, hover_maximum),
			maxf(hover_minimum, hover_maximum), float(seat["hover"]))
		hover += sin(seconds * hover_rate + phase_b) * hover_bob
		hover = maxf(hover, 0.05)
		var point := surface + heading * along + side * across + normal * hover

		# The weave derivative turns the body into its own path instead of
		# sliding it sideways. It is a direction only; no velocity is integrated.
		var individual_heading := heading \
			+ side * cos(beat) * weave_amount * weave_rate * 0.32 \
			+ heading * cos(beat * 0.71 + phase_b) * weave_amount * 0.12
		individual_heading = _flat_direction(individual_heading, normal, heading)

		var shove := Vector3.ZERO
		for player in players:
			var away := point - player
			var span := away.length()
			if span >= avoid_reach or span < 0.0001:
				continue
			var force := 1.0 - span / maxf(avoid_reach, 0.001)
			shove += (away / span) * force * force * avoid_push
		if not shove.is_zero_approx():
			point += shove
			# Never let a player push an insect through the local ground plane.
			var clearance := (point - surface).dot(normal)
			if clearance < 0.05:
				point += normal * (0.05 - clearance)
			var escape := shove - normal * shove.dot(normal)
			if not escape.is_zero_approx():
				individual_heading = individual_heading.lerp(
					escape.normalized(), clampf(escape.length()
						/ maxf(avoid_push, 0.01), 0.0, 1.0) * avoid_turn)
				individual_heading = _flat_direction(
					individual_heading, normal, heading)

		var roll := deg_to_rad(roll_degrees) * sin(beat * 0.83 + phase_b)
		var body_up := (Basis(individual_heading, roll) * normal).normalized()
		var basis := _body_basis(individual_heading, body_up).scaled(
			Vector3.ONE * float(seat["scale"]))
		var placed := planet_to_swarm * Transform3D(basis, point)
		_write_instance(buffer, index, placed, seat["tint"], seat["custom"])

	cluster["posed_centre"] = surface + normal * _middle_hover()
	cluster["posed_direction"] = centre_direction
	return buffer


func _cluster_frame(cluster: Dictionary, seconds: float) -> Dictionary:
	var anchor: Vector3 = cluster["direction"]
	var east: Vector3 = cluster["east"]
	var north: Vector3 = cluster["north"]
	var orbit: float = cluster["orbit"]
	var rate: float = cluster["rate"]
	var angle := float(cluster["phase"]) + seconds * rate
	var direction := (anchor + (east * cos(angle) + north * sin(angle))
		* (orbit / _shape.radius)).normalized()
	var height := _shape.elevation(direction, _spacing)
	var surface := direction * (_shape.radius + height)
	var normal := _shape.normal_at(direction, _spacing)
	var travel := (-east * sin(angle) + north * cos(angle)) * rate
	var heading := _flat_direction(travel, normal, east)
	var side := normal.cross(heading).normalized()
	if side.is_zero_approx():
		side = north
	return {
		"direction": direction,
		"surface": surface,
		"normal": normal,
		"heading": heading,
		"side": side,
	}


func _flat_direction(direction: Vector3, normal: Vector3,
		fallback: Vector3) -> Vector3:
	var flat := direction - normal * direction.dot(normal)
	if flat.length_squared() < 0.000001:
		flat = fallback - normal * fallback.dot(normal)
	if flat.is_zero_approx():
		var axis := Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT
		flat = normal.cross(axis)
	return flat.normalized()


func _body_basis(forward: Vector3, up: Vector3) -> Basis:
	var ahead := forward.normalized()
	var above := (up - ahead * up.dot(ahead)).normalized()
	if above.is_zero_approx():
		above = ahead.cross(Vector3.RIGHT if absf(ahead.x) < 0.9
			else Vector3.FORWARD).normalized()
	match model_forward_axis:
		ForwardAxis.POSITIVE_X:
			return Basis(ahead, above, ahead.cross(above).normalized())
		ForwardAxis.NEGATIVE_X:
			return Basis(-ahead, above, -ahead.cross(above).normalized())
		ForwardAxis.POSITIVE_Z:
			return Basis(above.cross(ahead).normalized(), above, ahead)
		_:
			return Basis(ahead.cross(above).normalized(), above, -ahead)


func _players() -> Array[Vector3]:
	var found: Array[Vector3] = []
	if avoidance_group.is_empty() or avoid_reach <= 0.0 or avoid_push <= 0.0:
		return found
	for candidate in get_tree().get_nodes_in_group(avoidance_group):
		var body := candidate as Node3D
		if body != null:
			found.append(_planet.to_local(body.global_position))
	return found


func _write_instance(buffer: PackedFloat32Array, index: int,
		placed: Transform3D, tint: Color, custom: Color) -> void:
	var at := index * STRIDE
	var basis := placed.basis
	var origin := placed.origin
	buffer[at] = basis.x.x
	buffer[at + 1] = basis.y.x
	buffer[at + 2] = basis.z.x
	buffer[at + 3] = origin.x
	buffer[at + 4] = basis.x.y
	buffer[at + 5] = basis.y.y
	buffer[at + 6] = basis.z.y
	buffer[at + 7] = origin.y
	buffer[at + 8] = basis.x.z
	buffer[at + 9] = basis.y.z
	buffer[at + 10] = basis.z.z
	buffer[at + 11] = origin.z
	buffer[at + COLOUR_OFFSET] = tint.r
	buffer[at + COLOUR_OFFSET + 1] = tint.g
	buffer[at + COLOUR_OFFSET + 2] = tint.b
	buffer[at + COLOUR_OFFSET + 3] = tint.a
	buffer[at + CUSTOM_OFFSET] = custom.r
	buffer[at + CUSTOM_OFFSET + 1] = custom.g
	buffer[at + CUSTOM_OFFSET + 2] = custom.b
	buffer[at + CUSTOM_OFFSET + 3] = custom.a


# --- Bounded physical lights ------------------------------------------------

func _choose_light_clusters(eye: Vector3) -> void:
	for index in _desired_light_clusters.size():
		_desired_light_clusters[index] = -1
	if _lights.is_empty():
		return
	var candidates: Array[Dictionary] = []
	for index in _clusters.size():
		var cluster := _clusters[index]
		var node := cluster["node"] as MultiMeshInstance3D
		if not bool(cluster["active"]) or not bool(cluster["uploaded"]) \
				or not node.visible:
			continue
		var point: Vector3 = cluster["posed_centre"]
		if not point.is_finite():
			continue
		var away := eye.distance_to(point)
		if away <= lights_within:
			candidates.append({"index": index, "away": away})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["away"]) < float(b["away"]))
	if candidates.size() > _desired_light_clusters.size():
		candidates.resize(_desired_light_clusters.size())

	var wanted := {}
	for candidate in candidates:
		wanted[int(candidate["index"])] = true
	# Keep a light on the same cluster while that cluster remains among the
	# nearest set. Ordering alone must not fade and relocate two valid lights
	# merely because their distances crossed by a centimetre.
	var assigned := {}
	for light_index in _light_clusters.size():
		var cluster_index := _light_clusters[light_index]
		if cluster_index >= 0 and wanted.has(cluster_index) \
				and not assigned.has(cluster_index):
			_desired_light_clusters[light_index] = cluster_index
			assigned[cluster_index] = true
	for candidate in candidates:
		var cluster_index := int(candidate["index"])
		if assigned.has(cluster_index):
			continue
		for light_index in _desired_light_clusters.size():
			if _desired_light_clusters[light_index] < 0:
				_desired_light_clusters[light_index] = cluster_index
				assigned[cluster_index] = true
				break


func _update_lights(delta: float) -> void:
	for index in _lights.size():
		var light := _lights[index]
		var current := _light_clusters[index]
		var wanted := _desired_light_clusters[index]
		var changing := current != wanted
		var target_energy := 0.0

		if not changing and current >= 0:
			var cluster := _clusters[current]
			var point: Vector3 = cluster["posed_centre"]
			if bool(cluster["active"]) and point.is_finite():
				var target := _planet.to_global(point)
				var follow := 1.0 - exp(-delta * light_follow_speed)
				light.global_position = light.global_position.lerp(target, follow)
				var night := _night_at(point) if lights_night_only else 1.0
				var pulse := 1.0
				if light_pulse_amount > 0.0 and light_pulse_speed > 0.0:
					pulse += light_pulse_amount * sin(
						_clock * TAU * light_pulse_speed
							* float(cluster["light_rate"])
							+ float(cluster["light_phase"]))
				target_energy = light_energy * night * pulse
				light.light_color = light.light_color.lerp(
					cluster["light_colour"] as Color,
					1.0 - exp(-delta * light_follow_speed))

		light.light_energy = move_toward(light.light_energy, target_energy,
			delta * maxf(light_energy, 0.1) * light_fade_speed)
		light.visible = light.light_energy > 0.001

		# Relocate only while dark. Reassignment therefore appears as one nearby
		# glow fading out and another fading in, never as a light sweeping across
		# the ground between two unrelated clusters.
		if changing and light.light_energy <= 0.001:
			_light_clusters[index] = wanted
			if wanted >= 0:
				var cluster := _clusters[wanted]
				var point: Vector3 = cluster["posed_centre"]
				if point.is_finite():
					light.global_position = _planet.to_global(point)
					light.light_color = cluster["light_colour"]


func _night_at(point: Vector3) -> float:
	if _planet.sun == null:
		# Useful in isolated harnesses; the shader's project-global sun still
		# supplies a visual answer while CPU culling remains conservative.
		return 1.0
	var local_up := point.normalized()
	var world_up := (_planet.global_basis * local_up).normalized()
	var to_sun := _planet.sun.global_basis.z.normalized()
	return 1.0 - smoothstep(-0.16, 0.12, world_up.dot(to_sun))


# --- Geometry and deterministic utilities ---------------------------------

func _mesh_from(scene_resource: PackedScene) -> Mesh:
	if scene_resource == null:
		return null
	var scene := scene_resource.instantiate()
	var best: Mesh
	var most_vertices := -1
	for found in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		var candidate := mesh_instance.mesh
		if candidate == null:
			continue
		# get_faces() works for imported ArrayMeshes and generated PrimitiveMeshes.
		# surface_get_array_len() is only exposed by some concrete mesh classes,
		# which made an otherwise valid BoxMesh scene fail this generic loader.
		var vertices := candidate.get_faces().size()
		if vertices > most_vertices:
			most_vertices = vertices
			best = candidate
	scene.free()
	return best


func _scale_for(mesh: Mesh) -> float:
	var size := mesh.get_aabb().size
	var authored := maxf(maxf(size.x, size.y), size.z)
	return insect_size / maxf(authored, 0.0001)


func _cluster_bounds(cluster: Dictionary) -> AABB:
	var centre: Vector3 = cluster["centre"]
	var span := float(cluster["orbit"]) + cluster_radius * 1.8 \
		+ maxf(hover_minimum, hover_maximum) + hover_bob + avoid_push \
		+ insect_size * 2.0
	var planet_to_swarm := global_transform.affine_inverse() * _planet.global_transform
	var local_centre := planet_to_swarm * centre
	var local_scale := maxf(maxf(planet_to_swarm.basis.x.length(),
		planet_to_swarm.basis.y.length()), planet_to_swarm.basis.z.length())
	var half := Vector3.ONE * span * local_scale
	return AABB(local_centre - half, half * 2.0)


func _middle_hover() -> float:
	return (hover_minimum + hover_maximum) * 0.5


func _tangent_axes(direction: Vector3) -> Array[Vector3]:
	var up := direction.normalized()
	var east := up.cross(Vector3.UP if absf(up.y) < 0.9
		else Vector3.RIGHT).normalized()
	return [east, up.cross(east).normalized()]


func _rng_for(key: Vector3i) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = _cluster_seed(key)
	return rng


func _cluster_seed(key: Vector3i) -> int:
	# Explicit integer mixing rather than hash(Vector3i): this layout is part of
	# the replicated procedural result and must not depend on engine hash policy.
	var mixed := int(random_seed) ^ ((key.x + 17) * 73856093)
	mixed ^= (key.y + 104729) * 19349663
	mixed ^= (key.z + 130363) * 83492791
	mixed ^= mixed >> 13
	mixed *= 1274126177
	mixed ^= mixed >> 16
	return absi(mixed) + 1


# --- Public diagnostics -----------------------------------------------------

## Number of insects belonging to currently assigned deterministic clusters.
## Localized mode normally returns instance_count; global mode can be lower when
## terrain filters leave fewer suitable cells around the viewer.
func swarm_count() -> int:
	var total := 0
	for cluster in _clusters:
		if bool(cluster["active"]):
			total += int(cluster["share"])
	return total


## Clusters currently submitted for drawing after distance and local-night tests.
func active_cluster_count() -> int:
	return _visible_clusters


## Insects in the clusters currently submitted for drawing.
func visible_swarm_count() -> int:
	return _visible_insects


func cluster_centres() -> PackedVector3Array:
	var centres := PackedVector3Array()
	for cluster in _clusters:
		if not bool(cluster["active"]):
			continue
		var point: Vector3 = cluster["posed_centre"]
		centres.append(point if point.is_finite() else cluster["centre"])
	return centres


func statistics() -> Dictionary:
	var lit := 0
	for light in _lights:
		if light.visible:
			lit += 1
	return {
		"swarm": swarm_count(),
		"clusters": active_cluster_count(),
		"visible_insects": _visible_insects,
		"buffer_uploads": _uploads_last_frame,
		"light_pool": _lights.size(),
		"lights_active": lit,
		"placement_cache": _placement_cache.size(),
	}
