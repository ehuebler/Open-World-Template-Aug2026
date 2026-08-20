extends Node

## Headless checks for the Meep colony: the site's projection, the navigation grid
## read off the height field, the boundary the flood fill derives from it, the cost
## field every walk uses, the settlers themselves, and the colony taking damage on
## their behalf.
##
##     godot --headless --path . dev/_meep_test.tscn
##
## Run with a renderer it also captures the boundary wall and the Meeps close up and
## at the distance they are actually played at, which is the half of this that a
## number cannot answer:
##
##     godot --path . dev/_meep_test.tscn

const WORLD := preload("res://game/world.tscn")
const PLAYER_SCENE := preload("res://game/player/player.tscn")
const SHOT_DIR := "res://dev/captures/"
## The ColonyShip's own placement from `game/world.tscn`. The point of the checks
## below is what the terrain there does to a town, so they are run against the
## terrain the game actually founds one on.
const COLONY_DIRECTION := Vector3(-0.2881049, -0.1121179, 0.9510127)
const COLONY_FACING := 91.9
const SITE := &"landing"
const FOUNDING_RNG_SEED := 0x6D33A
## Simulated seconds of colony life the movement checks are run over. Long enough
## for every settler to have picked several wander targets and walked to them.
const WALK_SECONDS := 60.0
const WALK_STEP := 0.1
## Bearings the claim's reach is measured along.
const BEARINGS := 32
## Frames to give the terrain to stream in before a capture.
const TERRAIN_FRAMES := 200
## How long the town in the real world is given to fill Tier 0, and how many ticks of it
## are run per frame. Together they allow about forty-two minutes of colony life: long
## enough to exhaust placement across the irregular claim, connect every final house,
## and clone into all housing that was built first.
const LIVE_FRAMES := 5000
const LIVE_SLICES := 5
## Stand-in colonists this fixture parks in towns it is inspecting. See
## [method _watcher_at].
const TEST_WATCHERS := &"meep_test_watchers"
var _failures := 0
var _failure_messages := PackedStringArray()
var _town_harvestables_at_start := 0


class TestWorld extends GameWorld:
	func _ready() -> void:
		pass


class TestCycle extends CelestialCycle:
	func _ready() -> void:
		set_process(false)


class ClientColony extends MeepColony:
	func _is_host() -> bool:
		return false


class FlatProjectionShape extends PlanetShape:
	func elevation(_direction: Vector3, _spacing := 0.0) -> float:
		return 8.0


class TestPlanet extends Planet:
	var test_viewer := Vector3.ZERO

	## The height field `game/world.tscn` ships, which means unsettled: the town pads
	## are off there, and leaving them on here would flatten the exact chasm and
	## shoreline these checks exist to meet. Everything else about the shape is its
	## default, because that is what the world's own sub-resource is.
	static func world_shape() -> PlanetShape:
		var shape := PlanetShape.new()
		shape.settled = false
		return shape

	func _ready() -> void:
		if shape == null:
			shape = world_shape()
		shape.prepare()
		set_process(false)
		set_physics_process(false)

	func viewer_position() -> Vector3:
		return test_viewer

	func finest_spacing() -> float:
		return 1.5

	## Pinned, where the real one follows whichever chunk is under the camera. A
	## colony's grid is baked at the finest spacing on every peer precisely so it
	## does not depend on this, and a test that let it drift would be measuring the
	## quadtree rather than the town.
	func spacing_underfoot() -> float:
		return 1.5


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if OS.get_cmdline_user_args().has("--town-only"):
		await _town()
		_finish()
		return
	var world := TestWorld.new()
	world.name = "TestWorld"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	world.add_child(spawn_points)
	var cycle := TestCycle.new()
	cycle.name = "CelestialCycle"
	world.add_child(cycle)
	add_child(world)
	var planet := TestPlanet.new()
	planet.name = "Planet"
	planet.shape = TestPlanet.world_shape()
	world.add_child(planet)
	await get_tree().process_frame

	var direction := COLONY_DIRECTION.normalized()
	var ship := ColonyShip.new()
	ship.name = "ColonyShip"
	ship.direction = direction
	ship.facing = COLONY_FACING
	ship.colony_site = SITE
	planet.add_child(ship)
	# Everything is HOT for the checks: the sharpest ground reads and the local
	# obstacle ray are the code paths worth testing, and the cheaper ones are the
	# same arithmetic against a cached height.
	planet.test_viewer = planet.to_local(ship.global_position)
	await get_tree().process_frame

	_check_site(planet, direction)
	_check_ship(ship)

	var colonies := MeepColonies.new()
	colonies.name = "MeepColonies"
	planet.add_child(colonies)
	await get_tree().process_frame
	_expect(colonies.ship(SITE) == ship,
		"the registry finds the colony ship by its site name")
	_expect(world.meep_colonies() == colonies,
		"the world finds the registry under the planet")

	# The production API deliberately chooses a random city style. Pin that choice
	# here so long economic and blueprint assertions exercise one repeatable city.
	seed(FOUNDING_RNG_SEED)
	var released := colonies.release_settlers(SITE)
	var colony := colonies.colony(SITE)
	_expect(colony != null, "releasing settlers founds the colony")
	if colony == null:
		_finish()
		return
	_expect(released == MeepColony.FIRST_WAVE and colony.alive_count()
		== MeepColony.FIRST_WAVE,
		"the first wave is the whole population")
	_expect(colonies.release_settlers(SITE) == 0,
		"the ship cannot be asked for a second wave")
	_check_animated_render(colony)

	# The bake is a worker task picked up by the colony's own physics step.
	var bake_from := Time.get_ticks_msec()
	for _frame in 900:
		if colony.ground_ready():
			break
		await get_tree().physics_frame
	_expect(colony.ground_ready(), "the ground bake finishes")
	if not colony.ground_ready():
		_finish()
		return
	# Rendering waits for the first 10 Hz detail grade; the ground can finish on
	# an earlier physics frame while every freshly added row is still COLD.
	for _frame in 12:
		await get_tree().physics_frame
		await get_tree().process_frame
		var render := colony.get_node_or_null("Meeps") as MultiMeshInstance3D
		if render != null and render.multimesh != null \
				and render.multimesh.visible_instance_count > 0:
			break
	_check_animated_instances(colony)
	if OS.get_cmdline_user_args().has("--megacity-only"):
		_check_megacity_projection(colony)
		_finish()
		return
	if OS.get_cmdline_user_args().has("--projection-only"):
		_check_city_projection(colony)
		_finish()
		return
	var phase := _took("ground bake", bake_from)

	_check_grid(colony)
	phase = _took("grid", phase)
	_check_ship_plaza(colony)
	_check_claim(colony)
	phase = _took("claim", phase)
	_check_routes(colony)
	phase = _took("routes", phase)
	_check_wall(colony)
	phase = _took("wall", phase)
	_check_collision_proxies(colony)
	_check_crowd_avoidance(colony)
	phase = _took("crowd collision", phase)
	_check_walking(colony)
	phase = _took("%.0f s of walking" % WALK_SECONDS, phase)
	_check_damage(planet, colony)
	_took("damage", phase)
	_check_report(world, colony)
	_check_funded_mining(colony)
	_check_city_purchases(colony)
	_check_urban_density_model(colony)
	_check_meep_lifecycle_model(colony)
	_check_region_plan_model(colony)
	_check_city_blueprint_model(colony)
	if OS.get_cmdline_user_args().has("--plan-only"):
		_finish()
		return
	_check_city_projection(colony)
	if OS.get_cmdline_user_args().has("--blueprint-only"):
		_finish()
		return
	_check_surface_model(colony)
	await _check_continuous_expansion(colony)
	_check_commission_construction(colony)
	_check_second_cloner(colony)
	await _check_menu(colony)
	_check_biomass_harvester(colony)
	if OS.get_cmdline_user_args().has("--commission-only"):
		world.queue_free()
		await get_tree().process_frame
		_finish()
		return
	await _check_snapshot(colonies, colony)

	world.queue_free()
	await get_tree().process_frame
	await _town()
	_finish()


## Prints how long a phase took and returns the clock for the next one. These are
## the numbers to watch if a later pass makes the town bigger: the grid, the flood
## fill and the cost field are all O(cells), and the walk is the tick itself.
func _took(phase: String, from: int) -> int:
	var now := Time.get_ticks_msec()
	print("meep_test: %s took %.2f s" % [phase, float(now - from) / 1000.0])
	return now


func _finish() -> void:
	for message in _failure_messages:
		print("meep_test: FAILED  ", message)
	print("meep_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


# --- Site --------------------------------------------------------------------

func _check_site(planet: TestPlanet, direction: Vector3) -> void:
	var site := MeepSite.new(direction, planet.shape.radius, COLONY_FACING, 128.0)
	_expect(site.to_local(direction).length() < 0.001,
		"the colony centre is the origin of its own map")
	_expect(absf(site.up.dot(site.east)) < 0.0001
		and absf(site.up.dot(site.north)) < 0.0001
		and absf(site.east.dot(site.north)) < 0.0001,
		"the site frame is orthonormal")
	var worst := 0.0
	for point: Vector2 in [Vector2(40.0, 0.0), Vector2(0.0, -95.0),
			Vector2(70.0, 70.0), Vector2(-120.0, 30.0)]:
		var round_trip := site.to_local(site.direction_at(point))
		worst = maxf(worst, round_trip.distance_to(point))
	_expect(worst < 0.01,
		"the projection round-trips to within a centimetre over the map")
	# The reason the projection is equidistant rather than a plain tangent plane:
	# a hundred metres on the map has to be a hundred metres of ground.
	var measured := planet.shape.radius \
		* site.up.angle_to(site.direction_at(Vector2(100.0, 0.0)))
	_expect(absf(measured - 100.0) < 0.05,
		"a hundred metres on the map is a hundred metres of ground")
	_expect(site.near(direction) and not site.near(-direction),
		"the cheap nearness test accepts the site and rejects the far side")


func _check_ship(ship: ColonyShip) -> void:
	_expect(ship.has_method("interact") and ship.has_method("interact_prompt"),
		"the colony ship satisfies the interaction contract")
	_expect(not ship.interact_prompt().is_empty(),
		"the ship offers a prompt to open city control")


func _check_animated_render(colony: MeepColony) -> void:
	var render := colony.get_node_or_null("Meeps") as MultiMeshInstance3D
	_expect(render != null, "the colony owns one batched Meep renderer")
	if render == null:
		return
	var meep_batches := 0
	for child in colony.get_children():
		if child is MultiMeshInstance3D and child.name == &"Meeps":
			meep_batches += 1
	_expect(meep_batches == 1,
		"four animation clips share one MultiMeshInstance3D")
	var batch := render.multimesh
	_expect(batch != null and batch.mesh != null,
		"valid VAT assets produce a render mesh without fallback geometry")
	if batch == null or batch.mesh == null:
		return
	_expect(batch.use_custom_data and batch.use_colors \
		and batch.instance_count == colony.count(),
		"the Meep batch allocates animation data and a white COLOR_0 multiplier")
	_expect(not (batch.mesh is SphereMesh) and batch.mesh.get_surface_count() == 1,
		"the grounded Idle VAT mesh is the batch's single draw surface")
	var bounds := batch.mesh.get_aabb()
	_expect(absf(bounds.position.y) < 0.003
		and absf(bounds.size.y - 1.2) < 0.004,
		"the runtime mesh remains grounded and 1.2 metres tall")
	_expect(render.physics_interpolation_mode
			== Node.PHYSICS_INTERPOLATION_MODE_OFF
		and render.cast_shadow
			== GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		and render.gi_mode == GeometryInstance3D.GI_MODE_DISABLED,
		"the animated batch keeps shadows without interpolation or baked GI")
	_expect(render.find_children("*", "Skeleton3D", true, false).is_empty()
		and render.find_children("*", "AnimationPlayer", true, false).is_empty(),
		"the batch has no per-Meep skeleton or animation player")

	var material := render.material_override as ShaderMaterial
	var shader_ok := material != null and material.shader != null \
		and material.shader.resource_path == MeepColony.MEEP_SHADER_PATH
	_expect(shader_ok, "the renderer uses the dedicated vivid Meep shader")
	if not shader_ok:
		return
	var locomotion_direction := float(material.get_shader_parameter(
		&"locomotion_time_direction"))
	var planted_foot_motion := _walk_vat_planted_foot_motion(batch.mesh)
	_expect(is_equal_approx(locomotion_direction, 1.0)
		and planted_foot_motion > 0.08,
		"walk and run preserve the baked forward gait instead of reversing it")
	var metadata_ok := true
	var expected_frames := [90.0, 30.0, 20.0, 30.0]
	for index in MeepColony.MEEP_VAT_PREFIXES.size():
		var prefix := MeepColony.MEEP_VAT_PREFIXES[index]
		metadata_ok = metadata_ok \
			and material.get_shader_parameter(
				StringName("%s_vat_positions" % prefix)) is Texture2D \
			and is_equal_approx(float(material.get_shader_parameter(
				StringName("%s_vat_frame_count" % prefix))),
				expected_frames[index]) \
			and is_equal_approx(float(material.get_shader_parameter(
				StringName("%s_vat_fps" % prefix))), 30.0) \
			and material.get_shader_parameter(
				StringName("%s_vat_delta_min" % prefix)) is Vector3 \
			and material.get_shader_parameter(
				StringName("%s_vat_delta_max" % prefix)) is Vector3
	_expect(metadata_ok,
		"all four VAT textures and clip metadata reach the runtime shader")

	var clips_ok := MeepColony.meep_animation_clip(MeepColony.State.IDLE) \
			== MeepColony.AnimationClip.IDLE \
		and MeepColony.meep_animation_clip(MeepColony.State.WALK) \
			== MeepColony.AnimationClip.WALK \
		and MeepColony.meep_animation_clip(MeepColony.State.GO_HOME) \
			== MeepColony.AnimationClip.WALK \
		and MeepColony.meep_animation_clip(MeepColony.State.STROLL) \
			== MeepColony.AnimationClip.WALK \
		and MeepColony.meep_animation_clip(MeepColony.State.FLEE) \
			== MeepColony.AnimationClip.RUN \
		and MeepColony.meep_animation_clip(MeepColony.State.WORK) \
			== MeepColony.AnimationClip.BUILD \
		and MeepColony.meep_animation_clip(MeepColony.State.WORK, true) \
			== MeepColony.AnimationClip.IDLE
	_expect(clips_ok,
		"simulation states select Idle, Walk, Run, Build, and clone-wait Idle")


## The model faces local -Z, so a planted foot must move toward +Z while the body
## advances. This reads the actual baked rows rather than trusting a playback-sign
## constant that can encode the same mistake as the shader.
func _walk_vat_planted_foot_motion(mesh: Mesh) -> float:
	if mesh == null or mesh.get_surface_count() < 1:
		return 0.0
	var clip := load(MeepColony.MEEP_VAT_PATHS[
		MeepColony.AnimationClip.WALK]) as VatClip
	if clip == null or not clip.prepare() or clip.frame_count <= 6.0:
		return 0.0
	var arrays := mesh.surface_get_arrays(0)
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var vertex_ids := arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array
	if vertices.is_empty() or vertex_ids.size() != vertices.size():
		return 0.0
	var base_by_id: Array[Vector3] = []
	base_by_id.resize(clip.vertex_count)
	var seen := PackedByteArray()
	seen.resize(clip.vertex_count)
	for index in vertices.size():
		var vertex_id := floori(
			vertex_ids[index].x * float(clip.texture_width))
		if vertex_id >= 0 and vertex_id < clip.vertex_count \
				and seen[vertex_id] == 0:
			seen[vertex_id] = 1
			base_by_id[vertex_id] = vertices[index]
	var right_foot := PackedInt32Array()
	for vertex_id in clip.vertex_count:
		var point := base_by_id[vertex_id]
		if seen[vertex_id] != 0 and point.x > 0.025 and point.x < 0.18 \
				and point.y < 0.145:
			right_foot.push_back(vertex_id)
	if right_foot.size() < 8:
		return 0.0
	var image := clip.positions.get_image()
	var start := _vat_region_centre(image, clip, base_by_id, right_foot, 0)
	var planted := _vat_region_centre(image, clip, base_by_id, right_foot, 6)
	if absf(planted.y - start.y) > 0.02:
		return 0.0
	return planted.z - start.z


func _vat_region_centre(image: Image, clip: VatClip,
		base_by_id: Array[Vector3], vertex_ids: PackedInt32Array,
		frame: int) -> Vector3:
	var centre := Vector3.ZERO
	for vertex_id in vertex_ids:
		var encoded := image.get_pixel(vertex_id, frame)
		var delta := Vector3(encoded.r, encoded.g, encoded.b) \
			* (clip.delta_maximum - clip.delta_minimum) \
			+ clip.delta_minimum
		centre += base_by_id[vertex_id] + delta
	return centre / float(vertex_ids.size())


func _check_animated_instances(colony: MeepColony) -> void:
	var render := colony.get_node_or_null("Meeps") as MultiMeshInstance3D
	if render == null or render.multimesh == null:
		_expect(false, "the animated batch survives the first colony draw")
		return
	var batch := render.multimesh
	_expect(batch.visible_instance_count > 0,
		"nearby visible Meeps are compacted into the animated batch")
	if batch.visible_instance_count <= 0:
		return
	# The dummy headless renderer does not retain MultiMesh readback data.
	if DisplayServer.get_name() != "headless":
		_expect(batch.get_instance_color(0).is_equal_approx(Color.WHITE),
			"the first drawn row preserves mesh COLOR_0 with a white instance multiplier")
	var custom := colony.meep_render_instance_data(0)
	_expect(custom.r >= float(MeepColony.AnimationClip.IDLE)
		and custom.r <= float(MeepColony.AnimationClip.BUILD)
		and custom.g >= 0.0 and custom.g <= 1.0
		and custom.b > 0.0
		and custom.a >= 0.0 and custom.a <= 1.0,
		"each shown slot stores clip, deterministic phase, rate, and appearance seed")
	var stood := colony.meep_render_transform(0)
	var at := colony.meep_render_local(0)
	var direction := colony.site.direction_at(at)
	var expected := direction * (colony.site.planet_radius
		+ colony._render_height[0] + MeepColony.FLOOR_CLEARANCE)
	_expect(stood.origin.distance_to(expected) < 0.002,
		"the grounded visual starts at floor clearance, not body-centre height")

	var saved_local := colony._local[0]
	var saved_heading := colony._heading[0]
	var saved_state := colony._state[0]
	var saved_detail := colony._detail[0]
	colony._heading[0] = Vector2.RIGHT
	colony.call("_snap_render_pose", 0)
	var faced := colony.meep_render_transform(0)
	var forward := -faced.basis.z.normalized()
	var expected_forward := colony.site.east \
		- direction * colony.site.east.dot(direction)
	_expect(forward.dot(expected_forward.normalized()) > 0.98,
		"the imported Meep's visible front faces its direction of travel")

	var shown_before := colony.meep_render_local(0)
	colony._local[0] = saved_local + Vector2.RIGHT
	colony._state[0] = MeepColony.State.WALK
	colony._detail[0] = MeepColony.Detail.HOT
	colony.call("_smooth_render", 1.0 / 60.0)
	var shown_after := colony.meep_render_local(0)
	_expect(shown_after.distance_to(shown_before) > 0.001
		and shown_after.distance_to(colony._local[0]) > 0.001,
		"host presentation advances between simulation ticks instead of snapping")
	_expect(is_equal_approx(MeepColony.WARM_INTERVAL, MeepColony.HOT_INTERVAL)
		and is_equal_approx(MeepColony.COLD_INTERVAL, MeepColony.HOT_INTERVAL)
		and MeepColony.STEPS_PER_TICK >= 512,
		"every resident keeps full simulation cadence, even with no player nearby")
	colony._local[0] = saved_local
	colony._heading[0] = saved_heading
	colony._state[0] = saved_state
	colony._detail[0] = saved_detail
	colony.call("_snap_render_pose", 0)


# --- Ground ------------------------------------------------------------------

func _check_grid(colony: MeepColony) -> void:
	var grid := colony.grid
	_expect(grid.built and grid.terrain.size() == grid.cells * grid.cells,
		"the grid classifies every cell it holds")
	var tally := {}
	for at in grid.terrain.size():
		var kind := grid.terrain[at]
		tally[kind] = int(tally.get(kind, 0)) + 1
	var passable := int(tally.get(MeepGrid.Terrain.PASSABLE, 0))
	var water := int(tally.get(MeepGrid.Terrain.WATER, 0))
	var void_cells := int(tally.get(MeepGrid.Terrain.VOID, 0))
	var steep := int(tally.get(MeepGrid.Terrain.STEEP, 0))
	print("meep_test: grid passable=%d water=%d void=%d steep=%d" % [
		passable, water, void_cells, steep])
	_expect(passable > grid.terrain.size() / 8,
		"most of the landing site is walkable ground")
	_expect(water > 0,
		"the sea inside the grid is classified as water")
	_expect(void_cells + steep > 0,
		"the chasm beside the ship is classified as unwalkable")
	# The classification is only as good as its agreement with the field it came
	# from, which is also what every peer rebuilding this depends on.
	var slipped := 0
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			var kind := grid.terrain_at(cell)
			var height := grid.height_at(cell)
			if kind == MeepGrid.Terrain.WATER \
					and height >= MeepGrid.SHORE_MARGIN:
				slipped += 1
			elif kind == MeepGrid.Terrain.PASSABLE \
					and height < MeepGrid.SHORE_MARGIN:
				slipped += 1
	_expect(slipped == 0,
		"no cell is walkable below the waterline or wet above it")


func _check_ship_plaza(colony: MeepColony) -> void:
	var grid := colony.grid
	var ring := colony.ship_ring_cells()
	var ring_lookup: Dictionary = {}
	for cell_index in ring:
		ring_lookup[cell_index] = true
	var bad_ring_cell := 0
	var open_ends := 0
	for cell_index in ring:
		var cell := Vector2i(cell_index % grid.cells, cell_index / grid.cells)
		if not grid.passable(cell) \
				or absf(grid.centre_of(cell).length()
					- MeepColony.SHIP_ROAD_RADIUS) > grid.cell_size * 0.9:
			bad_ring_cell += 1
		var neighbours := 0
		for offset in MeepRoads.NEIGHBOURS:
			var around := cell + offset
			if grid.inside(around) and ring_lookup.has(grid.index(around)):
				neighbours += 1
		if neighbours < 2:
			open_ends += 1
	var blocked := 0
	var leaked := 0
	var paved_under_ship := 0
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			if grid.centre_of(cell).length() \
					>= MeepColony.SHIP_NAVIGATION_RADIUS:
				continue
			blocked += 1
			if grid.passable(cell) \
					or not grid.has_flag(cell, MeepGrid.FLAG_SHIP):
				leaked += 1
			if grid.has_flag(cell, MeepGrid.FLAG_ROAD):
				paved_under_ship += 1
	var gate := colony.road_origin_cell()
	_expect(ring.size() >= 40 and bad_ring_cell == 0 and open_ends == 0
		and ring_lookup.has(grid.index(gate)) and grid.passable(gate),
		"the ship plaza is a closed walkable circle with an exterior route gate")
	_expect(blocked > 0 and leaked == 0 and paved_under_ship == 0,
		"the ship interior is navigation-blocked and contains no paving")

	# A legacy snapshot may contain a centreline paved before the plaza existed.
	# Applying it must keep the exterior cell and discard the under-hull cell.
	var centre_index := grid.index(grid.cell_of(Vector2.ZERO))
	var ring_index := ring[0] if not ring.is_empty() else -1
	colony.roads.apply_snapshot(PackedInt32Array([centre_index, ring_index]))
	var ring_clears_flora := false
	if ring_index >= 0:
		var ring_cell := Vector2i(
			ring_index % grid.cells, ring_index / grid.cells)
		ring_clears_flora = colony.roads.clears_flora_direction(
			colony.site.direction_at(grid.centre_of(ring_cell)), colony._planet)
	_expect(not colony.roads.has_cell(centre_index)
		and (ring_index < 0 or colony.roads.has_cell(ring_index)),
		"legacy road snapshots migrate out from beneath the ship")
	_expect(ring_clears_flora,
		"completed paving advertises its flora-free footprint before plants stream")
	colony.roads.apply_snapshot(PackedInt32Array())


func _check_claim(colony: MeepColony) -> void:
	var grid := colony.grid
	var claim := colony.claim
	_expect(claim.count > 0, "the claim is not empty")
	var wrong := 0
	var outside := 0
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			if not claim.contains_cell(cell):
				continue
			if not grid.passable(cell) \
					and not grid.has_flag(cell, MeepGrid.FLAG_SHIP):
				wrong += 1
			if grid.centre_of(cell).length() > claim.radius + 0.001:
				outside += 1
	_expect(wrong == 0,
		"every claimed cell is walkable ground or the reserved ship interior")
	_expect(outside == 0, "no claimed cell is beyond the claim's radius")

	# How far the town got on each bearing, and what stopped it. This is the whole
	# argument for deriving the boundary: on the open flats it should reach its cap,
	# and on the chasm and the shore it should stop well short of it without
	# anything in the code naming either.
	var shortest := INF
	var longest := 0.0
	var stopped_by := {}
	for bearing in BEARINGS:
		var angle := TAU * float(bearing) / float(BEARINGS)
		var found := claim.reach_along(Vector2(cos(angle), sin(angle)))
		var reach := float(found[0])
		var blocker := int(found[1])
		shortest = minf(shortest, reach)
		longest = maxf(longest, reach)
		stopped_by[blocker] = int(stopped_by.get(blocker, 0)) + 1
	print("meep_test: claim reach %.0f m to %.0f m of a %.0f m cap, stopped by %s"
		% [shortest, longest, claim.radius, stopped_by])
	_expect(longest >= claim.radius * 0.9,
		"the claim reaches its radius across the open ground")
	_expect(shortest <= claim.radius * 0.75,
		"the claim stops well short of its radius on at least one bearing")
	_expect(int(stopped_by.get(MeepGrid.Terrain.WATER, 0))
		+ int(stopped_by.get(MeepGrid.Terrain.SHALLOW, 0)) > 0,
		"the waterline is one of the things that stops the claim")
	_expect(int(stopped_by.get(MeepGrid.Terrain.VOID, 0))
		+ int(stopped_by.get(MeepGrid.Terrain.STEEP, 0)) > 0,
		"the chasm is one of the things that stops the claim")
	_check_non_overlapping_claims(colony)


func _check_non_overlapping_claims(colony: MeepColony) -> void:
	var radius := colony.site.planet_radius
	var centre_a := colony.site.centre
	var site_a := MeepSite.new(centre_a, radius, 0.0, 160.0)
	var centre_b := site_a.direction_at(Vector2(120.0, 0.0))
	var site_b := MeepSite.new(centre_b, radius, 0.0, 160.0)
	var grid_a := MeepGrid.new(site_a, 160, MeepGrid.CELL)
	var grid_b := MeepGrid.new(site_b, 160, MeepGrid.CELL)
	var flat_grids: Array[MeepGrid] = [grid_a, grid_b]
	for flat_grid: MeepGrid in flat_grids:
		flat_grid.terrain.fill(MeepGrid.Terrain.PASSABLE)
		flat_grid.heights.fill(0.0)
		flat_grid.flags.fill(MeepGrid.FLAG_NONE)
		flat_grid.surface_heights.fill(NAN)
		flat_grid.built = true
		flat_grid.revision += 1
	var claim_a := MeepClaim.new()
	var claim_b := MeepClaim.new()
	claim_a.build(grid_a, Vector2.ZERO, 150.0, false,
		PackedVector3Array([centre_b]), PackedByteArray([0]))
	claim_b.build(grid_b, Vector2.ZERO, 150.0, false,
		PackedVector3Array([centre_a]), PackedByteArray([1]))
	var overlap := 0
	var owned := 0
	for x in range(30, 91):
		for y in range(-50, 51, 2):
			var direction := site_a.direction_at(Vector2(float(x), float(y)))
			var in_a := claim_a.contains(site_a.to_local(direction))
			var in_b := claim_b.contains(site_b.to_local(direction))
			if in_a or in_b:
				owned += 1
			if in_a and in_b:
				overlap += 1
	_expect(owned > 0 and overlap == 0,
		"continuously growing neighbouring claims meet without overlapping")
	var compact_rival := MeepCityLedger.new()
	compact_rival.site_id = &"compact_b"
	compact_rival.direction = centre_b
	compact_rival.alive = 6
	var registry := MeepColonies.new()
	registry._ledgers[compact_rival.site_id] = compact_rival
	var rival_state := registry.claim_rivals(&"resident_a")
	var compact_centres: PackedVector3Array = rival_state["centres"]
	_expect(compact_centres.size() == 1
		and compact_centres[0].is_equal_approx(centre_b),
		"an offscreen ledger city keeps its centre in every resident border frontier")
	registry.free()


func _check_wall(colony: MeepColony) -> void:
	var claim := colony.claim
	var edges := claim.border_edges()
	_expect(edges.size() >= 8 and edges.size() % 2 == 0,
		"the boundary traces as whole segments")
	var report := colony.report()
	_expect(int(report.get("wall_segments", 0)) == edges.size() / 2,
		"the wall stands one post per boundary segment")
	var loops := claim.border_loops()
	_expect(not loops.is_empty(),
		"the boundary stitches into at least one ring for the roads pass")
	var stitched := 0
	for loop in loops:
		stitched += loop.size()
	_expect(stitched == edges.size() / 2,
		"every boundary segment lands in exactly one ring")
	var hidden := MeepBoundaryWall.new()
	var middle := (edges[0] + edges[1]) * 0.5
	var direction := colony.site.direction_at(middle)
	var height := colony._shape.elevation(direction, colony._spacing_drawn())
	var completed_span := PackedVector3Array([
		colony.site.point_at(edges[0], height),
		colony.site.point_at(edges[1], height),
	])
	hidden.raise(colony.site, claim, colony._shape,
		colony._spacing_drawn(), completed_span)
	_expect(hidden.segment_count() < edges.size() / 2,
		"a completed shared wall suppresses the provisional purple edge beneath it")
	hidden.free()


# --- Routes ------------------------------------------------------------------

## Every walk in the town, checked against the two things a walk must never do:
## cross water, or step into a hole.
func _check_routes(colony: MeepColony) -> void:
	var grid := colony.grid
	var field := MeepFlowField.new()
	# The exterior plaza gate is where every shared route leads; the claim's actual
	# centre is intentionally blocked by the ship.
	var home := colony.road_origin_cell()
	field.build(grid, home)
	_expect(field.reached > 0 and not field.stale(),
		"the cost field fills from the exterior ship plaza")
	var planned_lot_costed := false
	for cell_index in grid.cells * grid.cells:
		if (int(grid.flags[cell_index]) & MeepGrid.FLAG_PLANNED_LOT) == 0:
			continue
		var planned_cell := Vector2i(
			cell_index % grid.cells, cell_index / grid.cells)
		var planned_step := field.step_at(planned_cell)
		if planned_step == Vector2i.ZERO:
			continue
		var expected_cost := MeepGrid.STEP_COST + MeepGrid.PLANNED_LOT_COST \
			+ int(grid.hazard[cell_index]) * MeepGrid.HAZARD_COST
		if planned_step.x != 0 and planned_step.y != 0:
			expected_cost = expected_cost * MeepGrid.DIAGONAL_COST \
				/ MeepGrid.STEP_COST
		if field.distance_at(planned_cell) \
				- field.distance_at(planned_cell + planned_step) == expected_cost:
			planned_lot_costed = true
			break
	_expect(planned_lot_costed,
		"cost fields steer roads around reserved future building lots")
	var unreachable := 0
	var wet := 0
	var stranded := 0
	var checked := 0
	var ceiling := grid.cells * 4
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			# Sampled rather than exhaustive: one in seven claimed cells is
			# thousands of routes and a second of wall time.
			if not colony.claim.contains_cell(cell) or not grid.passable(cell) \
					or (y * grid.cells + x) % 7 != 0:
				continue
			checked += 1
			if not field.reachable(cell):
				unreachable += 1
				continue
			var walk := cell
			var steps := 0
			while walk != home and steps < ceiling:
				var kind := grid.terrain_at(walk)
				if kind == MeepGrid.Terrain.WATER \
						or kind == MeepGrid.Terrain.VOID:
					wet += 1
					break
				var step := field.step_at(walk)
				if step == Vector2i.ZERO:
					break
				walk = walk + step
				steps += 1
			if walk != home:
				stranded += 1
	print("meep_test: routed %d claimed cells home" % checked)
	_expect(checked > 32, "there is a town's worth of routes to check")
	_expect(unreachable == 0,
		"every walkable claimed cell has a route to the ship plaza")
	_expect(wet == 0,
		"no route crosses water or a crevasse")
	_expect(stranded == 0,
		"every route arrives rather than giving up part way")


# --- Crowd collision ---------------------------------------------------------

func _check_collision_proxies(colony: MeepColony) -> void:
	var blockers: Array[MeepBlockProxy] = []
	var pickers: Array[MeepPickProxy] = []
	for child in colony.get_children():
		if child is MeepBlockProxy:
			blockers.push_back(child as MeepBlockProxy)
		elif child is MeepPickProxy:
			pickers.push_back(child as MeepPickProxy)
	colony.call("_lend_block_proxies")
	var lent := 0
	var parked := 0
	var wrong_layer := 0
	var first_lent: MeepBlockProxy = null
	for proxy in blockers:
		if proxy.collision_layer == MeepBlockProxy.LAYER:
			lent += 1
			if first_lent == null:
				first_lent = proxy
		elif proxy.collision_layer == 0:
			parked += 1
		else:
			wrong_layer += 1
	_expect(blockers.size() == MeepColony.BLOCK_PROXY_POOL
		and lent > 0 and parked == blockers.size() - lent and wrong_layer == 0,
		"the fixed 32-body crowd pool lends nearby rows and parks every spare")
	_expect(pickers.size() == MeepColony.PROXY_POOL,
		"the independent interaction pool remains fixed instead of following population")
	_expect(colony.find_children("*", "CharacterBody3D", true, false).is_empty()
		and colony.find_children("*", "Skeleton3D", true, false).is_empty()
		and colony.find_children("*", "AnimationPlayer", true, false).is_empty(),
		"no resident gains a CharacterBody, Skeleton, or AnimationPlayer node")

	var shape_ok := true
	var interpolation_ok := true
	for proxy in blockers:
		var capsule := proxy.capsule_shape()
		shape_ok = shape_ok and capsule != null \
			and is_equal_approx(capsule.radius, colony.stats.collision_radius) \
			and is_equal_approx(capsule.height, colony.stats.body_height)
		interpolation_ok = interpolation_ok and proxy.physics_interpolation_mode \
			== Node.PHYSICS_INTERPOLATION_MODE_OFF
	for proxy in pickers:
		var capsule := proxy.capsule_shape()
		shape_ok = shape_ok and capsule != null \
			and is_equal_approx(capsule.radius, colony.stats.collision_radius) \
			and is_equal_approx(capsule.height, colony.stats.body_height) \
			and (proxy.collision_layer == 0
				or proxy.collision_layer == MeepPickProxy.LAYER)
		interpolation_ok = interpolation_ok and proxy.physics_interpolation_mode \
			== Node.PHYSICS_INTERPOLATION_MODE_OFF
	_expect(shape_ok,
		"pick and block pools use the same grounded 1.2 m capsule dimensions")
	_expect(interpolation_ok,
		"moving pooled collision bodies have physics interpolation disabled")
	if first_lent != null:
		var row := first_lent.meep
		var stood := first_lent.transform
		var expected_up := colony.site.direction_at(colony.meep_local(row))
		var expected_radius := colony.site.planet_radius + colony.meep_height(row) \
			+ colony.stats.body_height * 0.5 + MeepColony.FLOOR_CLEARANCE
		_expect(stood.basis.y.normalized().dot(expected_up) > 0.9999
			and absf(stood.origin.length() - expected_radius) < 0.002,
			"lent capsules align +Y to site up and centre at half body height")

	# Put this peer's eye directly on row zero so both pools lend the same shape.
	# Whichever overlapping body wins a broad interaction ray must name that row.
	var old_eye := colony._view_eye
	colony._view_eye = colony.meep_local(0)
	colony.call("_lend_proxies")
	colony.call("_lend_block_proxies")
	var overlapping_pick: MeepPickProxy = null
	var overlapping_block: MeepBlockProxy = null
	for proxy in pickers:
		if proxy.meep == 0:
			overlapping_pick = proxy
			break
	for proxy in blockers:
		if proxy.meep == 0:
			overlapping_block = proxy
			break
	_expect(overlapping_pick != null and overlapping_block != null
		and overlapping_pick.collision_layer == MeepPickProxy.LAYER
		and overlapping_block.collision_layer == MeepBlockProxy.LAYER
		and overlapping_pick.transform.origin.distance_to(
			overlapping_block.transform.origin) < 0.001
		and overlapping_block.interact_prompt() == colony.meep_summary(0),
		"an overlapping physical proxy forwards the same deterministic Meep interaction")
	colony._view_eye = old_eye
	colony.call("_lend_proxies")
	colony.call("_lend_block_proxies")

	var player := PLAYER_SCENE.instantiate() as CharacterBody3D
	var ceiling := player.get_node("CeilingCheck") as RayCast3D
	var aim := player.get_node("Head/CameraArm/Camera3D/AimRay") as RayCast3D
	_expect(player.collision_mask == (1 | MeepBlockProxy.LAYER)
		and ceiling.collision_mask == 1 and aim.collision_mask == 1,
		"the player body sees crowd layer 7 while explicit ground and aim rays stay world-only")
	player.free()


func _open_crowd_origin(colony: MeepColony, minimum_radius := 0) -> Vector2:
	var grid := colony.grid
	for radius in range(maxi(minimum_radius, 0), 40):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				var cell := colony.claim.origin + Vector2i(x, y)
				var open := true
				for around_y in range(-4, 5):
					for around_x in range(-4, 9):
						if not grid.passable(cell + Vector2i(around_x, around_y)):
							open = false
							break
					if not open:
						break
				if open:
					return grid.centre_of(cell)
	return grid.centre_of(colony.claim.origin)


func _synthetic_crowd(template: MeepColony, rows: int,
		origin: Vector2, spacing := 0.0) -> MeepColony:
	var crowd := MeepColony.new()
	crowd.site = template.site
	crowd.grid = template.grid
	crowd.stats = template.stats
	crowd.founded_seed = 0x51de
	for index in rows:
		var at := origin
		if spacing > 0.0:
			at += Vector2(
				(float(index % 32) - 15.5) * spacing,
				(float(index / 32) - 7.5) * spacing)
		crowd._local.push_back(at)
		crowd._heading.push_back(Vector2.ZERO)
		crowd._goal.push_back(origin + Vector2(40.0, 0.0))
		var cell := crowd.grid.cell_of(at)
		crowd._height.push_back(crowd.grid.walk_height_at(cell)
			if crowd.grid.has_walk_surface(cell) else crowd.grid.height_at(cell))
		crowd._health.push_back(crowd.stats.maximum_health)
		crowd._state.push_back(MeepColony.State.WALK)
		# HOT, WARM, and COLD rows share the same occupancy and steering path.
		crowd._detail.push_back(index % 3)
		crowd._job.push_back(0)
		crowd._seed.push_back(1009 + index * 37)
	# Rows assembled by hand rather than released, so the iteration lists the
	# occupancy and presentation passes walk have to be built by hand too.
	crowd.call("_refresh_rows")
	return crowd


func _minimum_crowd_spacing(crowd: MeepColony) -> float:
	var nearest := INF
	for index in crowd.count():
		for other in range(index + 1, crowd.count()):
			nearest = minf(nearest,
				crowd.meep_local(index).distance_to(crowd.meep_local(other)))
	return nearest


func _check_crowd_avoidance(colony: MeepColony) -> void:
	var before_rebuild := int(colony.crowd_spatial_stats().get("rebuilds", 0))
	colony.step_simulation(MeepColony.SIM_STEP)
	var after_rebuild := int(colony.crowd_spatial_stats().get("rebuilds", 0))
	_expect(after_rebuild == before_rebuild + 1,
		"the host rebuilds crowd occupancy exactly once per simulation tick")

	var origin := _open_crowd_origin(colony)
	var crowd := _synthetic_crowd(colony, 24, origin)
	crowd.call("_rebuild_crowd_index")
	var direction_a := crowd.crowd_steering_for_test(0, Vector2.RIGHT)
	var direction_b := crowd.crowd_steering_for_test(0, Vector2.RIGHT)
	var axis_a: Vector2 = crowd.call("_overlap_axis", 0, 1)
	var axis_b: Vector2 = crowd.call("_overlap_axis", 1, 0)
	_expect(direction_a.is_equal_approx(direction_b)
		and direction_a.distance_to(Vector2.RIGHT) > 0.01
		and axis_a.is_equal_approx(-axis_b),
		"exact overlaps resolve into repeatable opposite pair steering")
	crowd._detail[0] = MeepColony.Detail.HOT
	var hot := crowd.crowd_steering_for_test(0, Vector2.RIGHT)
	crowd._detail[0] = MeepColony.Detail.WARM
	var warm := crowd.crowd_steering_for_test(0, Vector2.RIGHT)
	crowd._detail[0] = MeepColony.Detail.COLD
	var cold := crowd.crowd_steering_for_test(0, Vector2.RIGHT)
	_expect(hot.is_equal_approx(warm) and warm.is_equal_approx(cold),
		"crowd steering is identical for HOT, WARM, and COLD movement detail")
	var index_stats := crowd.crowd_spatial_stats()
	_expect(int(index_stats.get("indexed_rows", 0)) == crowd.count()
		and int(index_stats.get("last_cells_checked", 0)) <= 9
		and int(index_stats.get("last_neighbor_checks", 0))
			<= int(index_stats.get("neighbor_check_cap", 0)),
		"all visible rows are indexed while each advance reads only bounded 3x3 buckets")

	var right_pass := _synthetic_crowd(colony, 2, origin)
	right_pass._local[1] = origin + Vector2(0.5, 0.0)
	right_pass.call("_rebuild_crowd_index")
	var shoulder := right_pass.crowd_steering_for_test(0, Vector2.RIGHT)
	_expect(shoulder.y < -0.001 and shoulder.dot(Vector2.RIGHT) > 0.0,
		"a head-on neighbor produces a consistent right-hand pass without reversing route")
	right_pass.free()

	var initial_spacing := _minimum_crowd_spacing(crowd)
	var trespassing := 0
	var overstep := 0
	for _tick in 24:
		crowd.call("_rebuild_crowd_index")
		for index in crowd.count():
			var before := crowd.meep_local(index)
			crowd.call("_advance", index, 0.1, 2.0)
			var after := crowd.meep_local(index)
			if before.distance_to(after) > 0.201:
				overstep += 1
			if not crowd.grid.passable(crowd.grid.cell_of(after)):
				trespassing += 1
	var final_spacing := _minimum_crowd_spacing(crowd)
	print("meep_test: synthetic crowd minimum spacing %.3f -> %.3f m"
		% [initial_spacing, final_spacing])
	_expect(trespassing == 0 and overstep == 0,
		"crowd steering preserves passability and speed-bounded movement")
	_expect(final_spacing > colony.stats.collision_radius * 0.45,
		"local avoidance materially improves the minimum spacing of a stacked crowd")
	crowd.free()

	var performance := _synthetic_crowd(colony, 512, origin, 0.42)
	var started := Time.get_ticks_usec()
	performance.call("_rebuild_crowd_index")
	for index in performance.count():
		performance.crowd_steering_for_test(index, Vector2.RIGHT)
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var performance_stats := performance.crowd_spatial_stats()
	print("meep_test: 512-row crowd index and steering took %.2f ms" % elapsed_ms)
	_expect(int(performance_stats.get("indexed_rows", 0)) == 512
		and int(performance_stats.get("max_neighbor_checks", 0))
			<= int(performance_stats.get("neighbor_check_cap", 0)),
		"the 512-row occupancy pass has a fixed per-row neighbor ceiling")
	_expect(elapsed_ms < 250.0,
		"the 512-row crowd pass stays inside a modest 250 ms debug budget")
	performance.free()


# --- Settlers ----------------------------------------------------------------

## A minute of colony life, run at the tick rate rather than in real time, checking
## after every step that nobody is anywhere they should not be.
func _check_walking(colony: MeepColony) -> void:
	var grid := colony.grid
	var off_ground := 0.0
	var trespassing := 0
	var strayed := 0
	var moved := 0.0
	var start := PackedVector2Array()
	for index in colony.count():
		start.push_back(colony.meep_local(index))
	var steps := int(WALK_SECONDS / WALK_STEP)
	for _tick in steps:
		colony.step_simulation(WALK_STEP)
		for index in colony.count():
			if colony.meep_state(index) == MeepColony.State.DEAD:
				continue
			var at := colony.meep_local(index)
			if not grid.passable(grid.cell_of(at)):
				trespassing += 1
			if at.length() > colony.claim_radius + grid.cell_size * 2.0:
				strayed += 1
			# The one failure a data-oriented crowd hides best: a Meep whose height
			# drifts from the ground under it shows up as a sphere buried in a
			# hillside, not as an error.
			off_ground = maxf(off_ground, absf(
				colony.meep_height(index) - colony.ground_height_at(at)))
	for index in colony.count():
		moved = maxf(moved,
			colony.meep_local(index).distance_to(start[index]))
	print("meep_test: after %.0f s the furthest Meep had walked %.1f m, worst"
		% [WALK_SECONDS, moved] + " ground error %.3f m" % off_ground)
	_expect(trespassing == 0,
		"no Meep ever stands on water, a crevasse or a slope")
	_expect(strayed == 0,
		"no Meep wanders out of its own colony's reach")
	_expect(moved > colony.stats.arrive_within,
		"the settlers actually walk")
	_expect(colony.stats.walk_speed >= 5.0,
		"their working pace crosses the town without spending minutes in transit")
	_expect(off_ground < 0.25,
		"every Meep stays on the ground rather than sinking or floating")


func _check_damage(planet: Planet, colony: MeepColony) -> void:
	var before := colony.alive_count()
	colony._state[0] = MeepColony.State.IDLE
	var at := colony.meep_combat_position(0)
	var expected_radius := colony.site.planet_radius + colony.meep_height(0) \
		+ colony.stats.body_height * 0.5 + MeepColony.FLOOR_CLEARANCE
	_expect(colony.meep_position(0).is_equal_approx(at)
		and absf(planet.to_local(at).length() - expected_radius) < 0.002,
		"Meep position is the shared centre of its upright 1.2 m combat body")
	_expect(colony.is_in_group(DamageHit.COMBATANT_GROUP),
		"the colony stands in the combatants group for its Meeps")
	_expect(colony.combat_faction() == DamageHit.Faction.PLAYER,
		"Meeps are on the player's side")
	_expect(colony.combat_radius() >= colony.claim_radius,
		"the colony reports the whole town, so falloff is not applied twice")
	# The site map's zero is sea level, and this town is not at sea level. A centre
	# reported down there is inside the hill: out of range of hits that landed in the
	# town, and behind cover for anything that checks line of sight.
	var stands := planet.to_local(colony.combat_position()).length() \
		- planet.shape.radius - colony.ground_height_at(Vector2.ZERO)
	_expect(stands > 0.0 and stands < 4.0,
		"the colony's combat point stands on the ground at its centre")
	_expect(colony.combat_position().distance_to(at) < colony.combat_radius(),
		"and every Meep is inside the bounds it reports with it")
	_expect(is_equal_approx(colony.stats.maximum_health, 24.0)
		and colony.meep_summary(0).contains("24/24"),
		"the hover summary shows current and maximum health on the 24 HP tune")

	var damage_numbers: Array[DamageNumberEvent] = []
	colony.meep_damage_number.connect(
		func(_index: int, event: DamageNumberEvent) -> void:
			damage_numbers.push_back(event))
	var player_hit_before := colony.meep_health(0)
	var friendly := DamageHit.impact(at, 0.05, 2.0)
	friendly.faction = DamageHit.Faction.PLAYER
	friendly.source_peer = 17
	_expect(is_equal_approx(
			DamageHit.apply_to_combatants(colony, friendly), 2.0)
		and is_equal_approx(
			player_hit_before - colony.meep_health(0), 2.0),
		"an ordinary player combat hit can hurt the exact Meep it reaches")
	var player_number: DamageNumberEvent = damage_numbers[0] \
		if damage_numbers.size() == 1 else null
	var expected_number_at := at \
		+ planet.up_at(at) * colony.stats.body_height * 0.62
	_expect(player_number != null and not player_number.incoming
		and player_number.source_peer == 17
		and player_number.target_key == "%s:0" % String(SITE)
		and player_number.world_position.distance_to(expected_number_at) < 0.01,
		"player damage publishes one number directly above the struck Meep")
	if player_number != null:
		var wire_number := DamageNumberEvent.from_wire(player_number.to_wire())
		var other_number := DamageNumberEvent.from_wire(player_number.to_wire())
		other_number.target_key = "%s:1" % String(SITE)
		var number_layer := DamageNumberLayer.new()
		_expect(wire_number.target_key == player_number.target_key
			and number_layer._key(wire_number) != number_layer._key(other_number),
			"Meep number identity survives the wire and keeps residents separate")

	var inside_state := colony.meep_state(1)
	var home_state := colony.meep_state(2)
	var inside_health := colony.meep_health(1)
	var home_health := colony.meep_health(2)
	colony._state[1] = MeepColony.State.INSIDE
	colony._state[2] = MeepColony.State.AT_HOME
	var inside_hit := DamageHit.impact(
		colony.meep_combat_position(1), 0.05, 8.0)
	inside_hit.faction = DamageHit.Faction.ENEMY
	var home_hit := DamageHit.impact(
		colony.meep_combat_position(2), 0.05, 8.0)
	home_hit.faction = DamageHit.Faction.ENEMY
	_expect(colony.apply_damage_to_row(1, inside_hit) == 0.0
		and colony.apply_damage_to_row(2, home_hit) == 0.0
		and is_equal_approx(colony.meep_health(1), inside_health)
		and is_equal_approx(colony.meep_health(2), home_health),
		"cloner and home-hidden rows remain invulnerable")
	colony._state[1] = inside_state
	colony._state[2] = home_state

	var body_before := colony.meep_health(0)
	var up := planet.up_at(at)
	var first_flee_goal := Vector2.ZERO
	var same_flee_goal := true
	for offset in [-colony.stats.body_height * 0.5 + 0.02, 0.0,
			colony.stats.body_height * 0.5 - 0.02]:
		var narrow := DamageHit.impact(at + up * float(offset), 0.03, 1.0)
		narrow.faction = DamageHit.Faction.ENEMY
		_expect(is_equal_approx(colony.apply_damage_to_row(0, narrow), 1.0),
			"a narrow hostile strike reaches feet, torso, or head")
		if first_flee_goal == Vector2.ZERO:
			first_flee_goal = colony._goal[0]
		else:
			same_flee_goal = same_flee_goal \
				and colony._goal[0].is_equal_approx(first_flee_goal)
	_expect(is_equal_approx(body_before - colony.meep_health(0), 3.0),
		"upright capsule samples do not inflate one strike's damage")
	_expect(damage_numbers.size() == 4
		and damage_numbers[-1].incoming
		and damage_numbers[-1].target_key == "%s:0" % String(SITE),
		"mob hits publish red incoming numbers from that same Meep")
	_expect(colony.meep_state(0) == MeepColony.State.FLEE
		and MeepColony.meep_animation_clip(colony.meep_state(0))
			== MeepColony.AnimationClip.RUN,
		"a nonlethal hit selects FLEE simulation and the Run VAT clip")
	_expect(first_flee_goal.distance_to(colony.meep_local(0)) > 1.0
		and same_flee_goal,
		"a body-centred impact chooses one deterministic nonzero flee direction")

	var opt_in_before := colony.meep_health(0)
	var opt_in := DamageHit.impact(at, 0.05, 1.0)
	opt_in.faction = DamageHit.Faction.ENEMY
	opt_in.ability_id = "nuke"
	_expect(is_equal_approx(colony.apply_damage_to_row(0, opt_in), 1.0)
		and is_equal_approx(
			opt_in_before - colony.meep_health(0), 1.0),
		"the existing ENEMY-faction affects-players path also reaches allied Meeps")

	var graze := DamageHit.area(at, 4.0, 6.0)
	graze.faction = DamageHit.Faction.ENEMY
	var dealt := DamageHit.apply_to_combatants(colony, graze)
	_expect(dealt > 0.0, "an enemy blast lands on the Meeps inside it")
	_expect(colony.alive_count() == before,
		"a graze hurts without killing")
	_expect(colony.meep_health(0) < colony.stats.maximum_health,
		"the Meep at the centre of the blast takes the damage")
	var health_text := "%d/%d" % [roundi(colony.meep_health(0)),
		roundi(colony.stats.maximum_health)]
	_expect(colony.meep_summary(0).contains(health_text),
		"the live hover summary follows hurt current/max health")

	var far := DamageHit.area(at + Vector3(0.0, 400.0, 0.0), 4.0, 60.0)
	far.faction = DamageHit.Faction.ENEMY
	_expect(colony.apply_damage(far) == 0.0,
		"a blast nowhere near the town reaches nobody")

	var previous_job := colony._job[0]
	if previous_job != 0:
		colony.tasks.release(previous_job)
	var death_job := colony.tasks.post(MeepTasks.Kind.ROAD,
		colony.grid.cell_of(colony.meep_local(0)), -100.0)
	_expect(death_job != 0 and colony.tasks.claim(death_job),
		"the lethal fixture owns one real job-board claim")
	colony._job[0] = death_job
	colony._deeds[0] = 12345
	colony._detail[0] = MeepColony.Detail.HOT
	colony._view_eye = colony.meep_local(0)
	colony.call("_lend_proxies")
	colony.call("_lend_block_proxies")
	var lent_before := false
	for child in colony.get_children():
		if (child is MeepPickProxy and (child as MeepPickProxy).meep == 0) \
				or (child is MeepBlockProxy
					and (child as MeepBlockProxy).meep == 0):
			lent_before = true
			break
	_expect(lent_before, "a living nearby row can borrow collision proxies")

	var age_at_death := colony.meep_age(0)
	var lethal := DamageHit.impact(colony.meep_combat_position(0), 0.05, 999.0)
	lethal.faction = DamageHit.Faction.ENEMY
	lethal.ability_id = "nuke"
	_expect(DamageHit.apply_to_combatants(colony, lethal) > 0.0,
		"a lethal hostile hit connects through combatant dispatch")
	_expect(colony.alive_count() == before - 1, "exactly its targeted Meep dies")
	_expect(colony.meep_state(0) == MeepColony.State.DEAD,
		"a killed Meep leaves the simulation")
	var released_job := colony.tasks.job(death_job)
	_expect(is_zero_approx(colony.meep_health(0))
		and not bool(colony.call("_visible", 0))
		and colony._job[0] == 0 and colony._deeds[0] == -1
		and released_job != null and released_job.workers == 0,
		"lethal damage hides the row and releases its job and deed")
	colony.call("_lend_proxies")
	colony.call("_lend_block_proxies")
	var lent_after := false
	for child in colony.get_children():
		if (child is MeepPickProxy and (child as MeepPickProxy).meep == 0) \
				or (child is MeepBlockProxy
					and (child as MeepBlockProxy).meep == 0):
			lent_after = true
			break
	_expect(not lent_after,
		"a dead row lends neither interaction nor body collision")
	colony.tasks.finish(death_job)
	colony.call("_advance_life_clocks", 12.0)
	var mortality: Dictionary = {}
	for row_variant: Variant in colony.meep_roster():
		var row := row_variant as Dictionary
		if int(row.get("index", -1)) == 0:
			mortality = row
			break
	_expect(not mortality.is_empty()
		and is_equal_approx(float(mortality.get("age_seconds", -1.0)),
			age_at_death)
		and float(mortality.get("death_seconds_ago", -1.0)) >= 12.0
		and String(mortality.get("death_cause", "")).contains("Nuke"),
		"the permanent memorial freezes age and records when and how a Meep died")

	var client := ClientColony.new()
	client.stats = MeepStats.new()
	client.call("_add", Vector2.ZERO, 71)
	client._apply_state(
		PackedInt32Array([0]), PackedVector2Array([Vector2(2.0, 3.0)]),
		PackedByteArray([128]), PackedByteArray([MeepColony.State.FLEE]),
		1, 0.0, 0.0, PackedFloat32Array())
	var replicated_health := client.stats.maximum_health * 128.0 / 255.0
	_expect(absf(client.meep_health(0) - replicated_health) < 0.01
		and client.meep_state(0) == MeepColony.State.FLEE,
		"client state packets carry per-row health and hurt state")
	client._apply_deaths(PackedInt32Array([0]),
		PackedFloat64Array([37.5]), PackedStringArray(["Killed by Quills"]))
	client.call("_advance_life_clocks", 3.0)
	var client_mortality := (client.meep_roster()[0] as Dictionary) \
		if not client.meep_roster().is_empty() else {}
	_expect(client.meep_state(0) == MeepColony.State.DEAD
		and is_zero_approx(client.meep_health(0))
		and client.alive_count() == 0
		and is_equal_approx(float(client_mortality.get("age_seconds", 0.0)), 37.5)
		and float(client_mortality.get("death_seconds_ago", 0.0)) >= 3.0
		and String(client_mortality.get("death_cause", "")) == "Killed by Quills",
		"reliable death packets carry the same row, age, recency, and cause to clients")
	client.free()


func _check_report(world: GameWorld, colony: MeepColony) -> void:
	_expect(world.has_method("request_release_settlers")
		and world.has_method("request_deposit_biomass")
		and world.has_method("request_add_city_biomass")
		and world.has_method("request_city_purchase")
		and world.has_method("colony_report"),
		"the world exposes release, deposits, purchases, and the panel's report")
	var report := world.colony_report(SITE)
	_expect(bool(report.get("founded", false)),
		"the report says the site is settled")
	_expect(int(report.get("settlers", -1)) == colony.alive_count(),
		"the report's settler count is the live population")
	var roster: Array = report.get("meeps", [])
	var living_records := 0
	var death_records := 0
	for row_variant: Variant in roster:
		var row := row_variant as Dictionary
		if String(row.get("status", "")) == "dead":
			death_records += 1
		else:
			living_records += 1
	_expect(roster.size() == colony.count() and living_records == colony.alive_count()
		and death_records == 1,
		"the report separates all current residents from the permanent memorial")
	var repeated_report := world.colony_report(SITE)
	_expect(int(report.get("meep_roster_revision", -1)) > 0
		and int(repeated_report.get("meep_roster_revision", -2))
			== int(report.get("meep_roster_revision", -1)),
		"frequent city-menu polls reuse one bounded roster snapshot")
	_expect(float(report.get("resources", -1.0)) == 0.0,
		"the resource bank ships at zero, ready for the mining pass")
	_expect(int(report.get("build_speed_level", -1)) == 0
		and int(report.get("move_speed_level", -1)) == 0
		and report.get("purchase_offers", {}) is Dictionary,
		"the report includes per-city speed levels and authoritative offers")
	var offers := report.get("purchase_offers", {}) as Dictionary
	_expect(offers.size() == 12 and not offers.has("expand_area")
		and offers.has("biomass_harvester")
		and offers.has("abilities_house_tower")
		and offers.has("second_cloner")
		and offers.has("third_cloner")
		and offers.has("fourth_cloner")
		and offers.has("send_settlement"),
		"the report exposes every city control without a border-speed purchase")
	_expect(world.colony_report(&"nowhere").is_empty(),
		"an unsettled site reports nothing rather than failing")


func _check_funded_mining(colony: MeepColony) -> void:
	var resources_before := colony.resources
	var committed_before := colony.committed
	colony.resources = 0.0
	colony.committed = 0.0
	var unfunded := colony.mining_job_target()
	var runway := colony.mining_resource_runway()
	colony.resources = runway * 2.0
	var funded := colony.mining_job_target()
	_expect(funded < unfunded and funded >= MeepColony.MINE_JOBS_FUNDED_MIN,
		"a funded growth runway releases harvesters but keeps a mining floor")
	colony.resources = resources_before
	colony.committed = committed_before


func _check_city_purchases(colony: MeepColony) -> void:
	var before := colony.city_progression_snapshot().duplicate(true)
	var base_work := colony.stats.work_rate
	var base_walk := colony.stats.walk_speed
	var catalog_valid := true
	for purchase_id in MeepColony.CITY_PURCHASE_COUNT:
		catalog_valid = catalog_valid \
			and MeepColony.city_purchase_valid(purchase_id) \
			and is_finite(MeepColony.city_purchase_cost(purchase_id)) \
			and MeepColony.city_purchase_cost(purchase_id) > 0.0
	_expect(catalog_valid,
		"every city purchase ID has a canonical positive price")
	_expect(MeepColony.CityPurchase.SECOND_CLONER
			== MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER + 1
		and MeepColony.CityPurchase.THIRD_CLONER
			== MeepColony.CityPurchase.SECOND_CLONER + 1
		and MeepColony.CityPurchase.FOURTH_CLONER
			== MeepColony.CityPurchase.THIRD_CLONER + 1
		and MeepColony.city_purchase_cost(
			MeepColony.CityPurchase.SECOND_CLONER)
				== MeepColony.SECOND_CLONER_COST
		and MeepColony.city_purchase_cost(
			MeepColony.CityPurchase.THIRD_CLONER)
				== MeepColony.THIRD_CLONER_COST
		and MeepColony.city_purchase_cost(
			MeepColony.CityPurchase.FOURTH_CLONER)
				== MeepColony.FOURTH_CLONER_COST,
		"all extra-cloner purchases append without moving existing wire IDs")
	_expect(not MeepColony.commissioned_work_unlocked(31)
		and MeepColony.commissioned_work_unlocked(32),
		"commission priority begins at exactly thirty-two living settlers")
	var priority_board := MeepTasks.new()
	priority_board.post(MeepTasks.Kind.BUILD, Vector2i.ZERO,
		MeepColony.BUILD_PRIORITY)
	var commissioned_job := priority_board.post(MeepTasks.Kind.BUILD,
		Vector2i(80, 0), MeepColony.COMMISSION_PRIORITY)
	_expect(priority_board.best_for(Vector2i.ZERO, MeepGrid.CELL)
		== commissioned_job,
		"commission priority outweighs a routine job across a future large city")
	var hat_plan := MeepStructures.plan_of(MeepStructures.Kind.HAT_HOUSE)
	var ability_plan := MeepStructures.plan_of(
		MeepStructures.Kind.ABILITIES_HOUSE)
	var harvester_plan := MeepStructures.plan_of(
		MeepStructures.Kind.BIOMASS_HARVESTER)
	_expect(hat_plan.span == Vector2i(6, 6)
		and ability_plan.span == Vector2i(6, 6)
		and harvester_plan.span == Vector2i(9, 9),
		"commissioned placeholders use their large civic footprints")

	colony.resources = 79.0
	colony.committed = 0.0
	_expect(not colony.try_city_purchase(
		MeepColony.CityPurchase.BUILD_SPEED_1)
		and is_equal_approx(colony.resources, 79.0),
		"an underfunded city upgrade is rejected without taking biomass")

	colony.resources = 200.0
	colony.committed = 150.0
	_expect(not colony.try_city_purchase(
		MeepColony.CityPurchase.BUILD_SPEED_1)
		and is_equal_approx(colony.resources, 200.0),
		"city purchases cannot spend biomass held by active construction")

	colony.committed = 0.0
	_expect(colony.try_city_purchase(
		MeepColony.CityPurchase.BUILD_SPEED_1)
		and colony.build_speed_level == 1
		and is_equal_approx(colony.resources, 120.0),
		"the host atomically buys the exact first build-speed level")
	var after_first := colony.resources
	_expect(not colony.try_city_purchase(
		MeepColony.CityPurchase.BUILD_SPEED_1)
		and is_equal_approx(colony.resources, after_first)
		and colony.build_speed_level == 1,
		"repeating an exact purchase ID cannot double-charge or skip a level")
	_expect(is_equal_approx(colony.effective_work_rate(), base_work * 1.10)
		and is_equal_approx(colony.stats.work_rate, base_work),
		"build speed is a per-city multiplier, not a shared-stats mutation")

	colony.resources = 1000.0
	_expect(colony.try_city_purchase(
		MeepColony.CityPurchase.MOVE_SPEED_1)
		and colony.move_speed_level == 1
		and is_equal_approx(colony.effective_walk_speed(), base_walk * 1.08)
		and is_equal_approx(colony.stats.walk_speed, base_walk),
		"move speed raises this city's walks without changing every colony")
	_expect(not colony.city_purchase_offers().has("expand_area")
		and is_equal_approx(colony.expansion_rate(),
			MeepColony.EXPANSION_BASE_RATE
			+ MeepColony.population_expansion_bonus(colony.alive_count())),
		"border speed is automatic and absent from the city upgrade catalogue")

	colony.resources = 1000.0
	colony.committed = 0.0
	_expect(colony.try_city_purchase(MeepColony.CityPurchase.HAT_HOUSE)
		and colony.city_upgrade_requested(
			MeepColony.CityPurchase.HAT_HOUSE)
		and not colony.city_upgrade_built(
			MeepColony.CityPurchase.HAT_HOUSE)
		and is_equal_approx(colony.resources, 1000.0)
		and is_equal_approx(colony.committed, 240.0),
		"a specialty commission holds its cost while it awaits Meep work")
	var queued_hat := colony.city_purchase_offers().get(
		"hat_house", {}) as Dictionary
	_expect(String(queued_hat.get("value", "")).contains("32 SETTLERS"),
		"an early commission reports that starter growth comes first")
	var paid := colony.city_progression_snapshot()
	_expect(int(paid.get("build_speed_level", 0)) == 1
		and int(paid.get("move_speed_level", 0)) == 1
		and not paid.has("expansion_rate_level")
		and int(paid.get("requested_flags", 0)) != 0,
		"the whole paid/requested progression state has a snapshot form")
	_expect(colony.cancel_city_purchase(MeepColony.CityPurchase.HAT_HOUSE)
		and not colony.city_upgrade_requested(
			MeepColony.CityPurchase.HAT_HOUSE)
		and is_equal_approx(colony.committed, 0.0)
		and is_equal_approx(colony.resources, 1000.0),
		"a failed specialty placement releases its reservation for retry")
	_expect(colony.try_city_purchase(MeepColony.CityPurchase.HAT_HOUSE)
		and colony.complete_city_purchase(
			MeepColony.CityPurchase.HAT_HOUSE)
		and colony.city_upgrade_built(MeepColony.CityPurchase.HAT_HOUSE)
		and is_equal_approx(colony.committed, 0.0)
		and is_equal_approx(colony.resources, 760.0),
		"completed commissioned work converts its exact reservation into spending")

	colony.apply_city_progression(before)
	_expect(colony.build_speed_level == int(before.get(
		"build_speed_level", 0))
		and colony.move_speed_level == int(before.get("move_speed_level", 0))
		and is_equal_approx(colony.resources,
			float(before.get("resources", 0.0))),
		"applying a progression snapshot restores levels, flags, and bank")


func _check_urban_density_model(colony: MeepColony) -> void:
	var hut := MeepStructures.plan_of(MeepStructures.Kind.HUT)
	var townhouse := MeepStructures.plan_of(MeepStructures.Kind.TOWNHOUSE)
	var mid_rise := MeepStructures.plan_of(MeepStructures.Kind.MID_RISE)
	var tower := MeepStructures.plan_of(MeepStructures.Kind.SKYSCRAPER)
	var mega_tower := MeepStructures.plan_of(
		MeepStructures.Kind.MEGA_SKYSCRAPER)
	var super_tower := MeepStructures.plan_of(
		MeepStructures.Kind.SUPER_SKYSCRAPER)
	var arcology := MeepStructures.plan_of(MeepStructures.Kind.ARCLOGY)
	_expect(MeepStructures.Kind.TOWNHOUSE
			== MeepStructures.Kind.BIOMASS_HARVESTER + 1
		and MeepStructures.Kind.MID_RISE == MeepStructures.Kind.TOWNHOUSE + 1
		and MeepStructures.Kind.SKYSCRAPER == MeepStructures.Kind.MID_RISE + 1
		and MeepStructures.Kind.MEGA_SKYSCRAPER
			== MeepStructures.Kind.DOCK_HUT + 1
		and MeepStructures.Kind.SUPER_SKYSCRAPER
			== MeepStructures.Kind.MEGA_SKYSCRAPER + 1
		and MeepStructures.Kind.ARCLOGY
			== MeepStructures.Kind.SUPER_SKYSCRAPER + 1,
		"residential form wire kinds append after every existing structure kind")
	_expect(hut.span == Vector2i(3, 3) and hut.resident_slots == 2
		and hut.floors == 1
		and townhouse.span == Vector2i(6, 3)
		and townhouse.resident_slots == 6 and townhouse.floors == 2
		and mid_rise.span == Vector2i(6, 6)
		and mid_rise.resident_slots == 16
		and tower.span == Vector2i(9, 9)
		and tower.resident_slots == 360
		and tower.floors >= 12 and tower.floors <= 16
		and mega_tower.span == Vector2i(12, 12)
		and mega_tower.resident_slots == 640
		and mega_tower.size.y > tower.size.y
		and super_tower.span == Vector2i(15, 15)
		and super_tower.resident_slots == 100
		and super_tower.size.y > mega_tower.size.y
		and arcology.span == Vector2i(9, 9)
		and arcology.resident_slots == 3584
		and arcology.size.y > super_tower.size.y,
		"forms scale from huts through towers to compact 3,584-resident arcologies")
	_expect(colony.population_ceiling(0) == 94
		and colony.population_ceiling(1) == 160
		and colony.population_ceiling(2) == 320
		and colony.population_ceiling(3) == 2800
		and colony.population_ceiling(4)
			== MeepColony.MAX_CITY_POPULATION
		and MeepColony.MAX_CITY_POPULATION >= 10000,
		"tier population ceilings extend city growth beyond ten thousand residents")
	var tier_one_capacity := 94 + MeepColony.MAX_VERTICAL_HUT_UPGRADES * 2
	while tier_one_capacity < colony.population_ceiling(1):
		tier_one_capacity += townhouse.resident_slots
	var tier_two_capacity := tier_one_capacity
	while tier_two_capacity < colony.population_ceiling(2):
		tier_two_capacity += mid_rise.resident_slots
	var tier_three_capacity := tier_two_capacity
	while tier_three_capacity < colony.population_ceiling(3):
		tier_three_capacity += tower.resident_slots
	var tier_four_capacity := tier_three_capacity
	while tier_four_capacity < colony.population_ceiling(4):
		var dense_kind := MeepStructures.residential_kind_for_growth(
			4, tier_four_capacity)
		tier_four_capacity += MeepStructures.plan_of(dense_kind).resident_slots
	_expect(tier_one_capacity >= 160 and tier_one_capacity <= 165
		and tier_two_capacity >= 320 and tier_two_capacity <= 335
		and tier_three_capacity >= 2800 and tier_three_capacity <= 3159
		and tier_four_capacity >= MeepColony.MAX_CITY_POPULATION
		and tier_four_capacity < MeepColony.MAX_CITY_POPULATION
			+ arcology.resident_slots,
		"finite form counts can physically fill every tier near its population ceiling")
	_expect(MeepColony.TIER_BLOCK_SIZES[1] == 24.0
		and MeepColony.TIER_BLOCK_SIZES[2] == 32.0
		and MeepColony.TIER_BLOCK_SIZES[3] == 44.0
		and MeepColony.TIER_BLOCK_SIZES[4] == 56.0
		and tower.spacing > mid_rise.spacing
		and super_tower.spacing > mega_tower.spacing,
		"district rules scale to 56-metre megacity blocks and wider tower gaps")
	_expect(MeepRoads.width_class_for_tier(1) == MeepRoads.WidthClass.STREET
		and MeepRoads.width_class_for_tier(2) == MeepRoads.WidthClass.AVENUE
		and MeepRoads.width_class_for_tier(3) == MeepRoads.WidthClass.BOULEVARD
		and MeepRoads.width_class_for_tier(4)
			== MeepRoads.WidthClass.GRAND_BOULEVARD
		and MeepRoads.ROAD_WIDTHS[0] < MeepRoads.ROAD_WIDTHS[1]
		and MeepRoads.ROAD_WIDTHS[1] < MeepRoads.ROAD_WIDTHS[2]
		and MeepRoads.ROAD_WIDTHS[2] < MeepRoads.ROAD_WIDTHS[3],
		"district roads append a grand boulevard for the megacity tier")
	_expect(MeepColony.site_limit_for(2, 200) == 3
		and MeepColony.site_limit_for(3, 400) == 4
		and MeepColony.site_limit_for(4, 600) == 5
		and MeepColony.population_expansion_bonus(500) > 0.0,
		"population scales simultaneous building sites and continuous border growth")

	# Exercise the additive form sidecar and an in-place floor independently from the
	# live town so this model check cannot consume its biomass or plots.
	var model := MeepStructures.new()
	model.configure(colony.site, colony.grid, colony.claim, null, null)
	var hut_index := model.place_at(MeepStructures.Kind.HUT, Vector2i(8, 8))
	var town_index := model.place_at(
		MeepStructures.Kind.TOWNHOUSE, Vector2i(20, 8), 1)
	var mid_index := model.place_at(
		MeepStructures.Kind.MID_RISE, Vector2i(36, 8), 2)
	var tower_index := model.place_at(
		MeepStructures.Kind.SKYSCRAPER, Vector2i(54, 8), 3)
	var mega_index := model.place_at(
		MeepStructures.Kind.MEGA_SKYSCRAPER, Vector2i(74, 8), 4)
	var super_index := model.place_at(
		MeepStructures.Kind.SUPER_SKYSCRAPER, Vector2i(94, 8), 4)
	var arcology_index := model.place_at(
		MeepStructures.Kind.ARCLOGY, Vector2i(126, 8), 4)
	var abilities_index := model.place_at(
		MeepStructures.Kind.ABILITIES_HOUSE, Vector2i(8, 30))
	for index in model.count():
		model.at(index).progress = 1.0
	_expect(model.residential_capacity() == 4708
		and model.development_units() == 4708,
		"variable completed residences expose their exact functional capacity")
	var upgraded := model.begin_vertical_upgrade(hut_index)
	if upgraded:
		model.advance_upgrade(hut_index, model.upgrade_work(hut_index) + 1.0)
		upgraded = model.complete_upgrade(hut_index)
	_expect(upgraded and model.at(hut_index).completed_floors == 2
		and model.at(hut_index).resident_slots == 4
		and model.at(town_index).resident_slots == 6
		and model.at(mid_index).resident_slots == 16
		and model.at(tower_index).resident_slots == 360
		and model.at(mega_index).resident_slots == 640
		and model.at(super_index).resident_slots == 100
		and model.at(arcology_index).resident_slots == 3584,
		"a safe vertical upgrade preserves the footprint and adds slots on completion")
	var abilities_base_height := model.display_height(abilities_index)
	var abilities_upgraded := model.begin_vertical_upgrade(abilities_index)
	if abilities_upgraded:
		model.advance_upgrade(
			abilities_index, model.upgrade_work(abilities_index) + 1.0)
		abilities_upgraded = model.complete_upgrade(abilities_index)
	_expect(abilities_upgraded
		and model.at(abilities_index).completed_floors == 2
		and is_equal_approx(
			model.display_height(abilities_index), abilities_base_height * 2.0),
		"the Abilities House form sidecar doubles its civic height in place")
	var placement_state := model.snapshot()
	var form_state := model.form_snapshot()
	var upgrade_state := model.upgrade_progress_snapshot()
	var copy := MeepStructures.new()
	copy.configure(colony.site, colony.grid, colony.claim, null, null)
	copy.apply_snapshot(placement_state)
	copy.apply_form_snapshot(form_state, upgrade_state)
	_expect(copy.form_snapshot() == form_state
		and copy.residential_capacity(false) == model.residential_capacity(false),
		"late join form sidecars round-trip floors, district tier, and capacity")
	copy.free()
	var legacy_forms := form_state.duplicate()
	legacy_forms[tower_index * MeepStructures.FORM_STRIDE
		+ MeepStructures.FORM_SLOTS] = 48
	legacy_forms[mega_index * MeepStructures.FORM_STRIDE
		+ MeepStructures.FORM_SLOTS] = 72
	legacy_forms[super_index * MeepStructures.FORM_STRIDE
		+ MeepStructures.FORM_SLOTS] = 100
	var migrated := MeepStructures.new()
	migrated.configure(colony.site, colony.grid, colony.claim, null, null)
	migrated.apply_snapshot(placement_state)
	migrated.apply_form_snapshot(legacy_forms, upgrade_state)
	_expect(migrated.at(tower_index).resident_slots == 360
		and migrated.at(mega_index).resident_slots == 640
		and migrated.at(super_index).resident_slots == 100
		and migrated.at(arcology_index).resident_slots == 3584,
		"legacy dense-city saves migrate to the new ten-thousand-resident capacities")
	migrated.free()
	model.free()


func _check_meep_lifecycle_model(colony: MeepColony) -> void:
	var prior_last := colony.count() - 1
	var prior_sibling := colony.meep_sibling(prior_last) \
		if prior_last >= 0 else -1
	var child := colony._add(Vector2.ZERO, 987654, true)
	_expect(colony.meep_role(child) == MeepColony.Role.CHILD
		and is_equal_approx(colony.meep_scale(child),
			MeepColony.CHILD_START_SCALE),
		"cloner births append a small persistent Child role")
	colony._ages[child] = MeepColony.CHILDHOOD_SECONDS * 0.5
	_expect(is_equal_approx(colony.meep_scale(child),
			lerpf(MeepColony.CHILD_START_SCALE, 1.0, 0.5)),
		"child render, combat, and proxy scale grows smoothly from the same value")
	colony._child_play(child)
	var play_path: PackedInt32Array = colony._stroll_paths.get(
		child, PackedInt32Array())
	var plaza := colony.ship_ring_cells()
	var current_play_cell := colony.grid.index(
		colony.grid.cell_of(colony._goal[child]))
	var road_only := colony.roads.has_cell(current_play_cell) \
		or plaza.has(current_play_cell)
	for cell_index in play_path:
		road_only = road_only and (
			colony.roads.has_cell(cell_index) or plaza.has(cell_index))
	_expect(colony.meep_state(child) == MeepColony.State.STROLL and road_only,
		"children play only along completed roads or the paved ship plaza")
	colony._ages[child] = MeepColony.CHILDHOOD_SECONDS
	colony._mature_children()
	var adult_role := colony.meep_role(child)
	colony._mature_children()
	_expect(adult_role != MeepColony.Role.CHILD
		and colony.meep_role(child) == adult_role
		and is_equal_approx(colony.meep_scale(child), 1.0),
		"maturation assigns one deterministic adult role and never rerolls it")
	# Retire only the synthetic row. Append-only identity remains exercised without
	# changing the live city population or an established sibling relationship.
	colony._state[child] = MeepColony.State.DEPARTED
	colony._alive -= 1
	colony._siblings[child] = -1
	if prior_last >= 0:
		colony._siblings[prior_last] = prior_sibling
	colony._refresh_rows()

	var street_states := colony._state.duplicate()
	var street_timers := colony._timer.duplicate()
	for index in colony._state.size():
		if colony._active_resident(index):
			colony._state[index] = MeepColony.State.AT_HOME
			colony._timer[index] = 999.0
	colony._refresh_rows()
	var street_rows := 0
	var street_rows_waking := true
	for index in colony._street_life_mask.size():
		if colony._street_life_mask[index] == 0:
			continue
		street_rows += 1
		street_rows_waking = street_rows_waking \
			and colony._timer[index] <= MeepColony.STREET_LIFE_WAKE_SECONDS \
				+ float(street_rows) * 0.1 + 0.001
	_expect(street_rows == colony._street_life_target()
		and street_rows >= MeepColony.MIN_STREET_LIFE
		and street_rows_waking,
		"a quiet colony wakes a bounded road cohort instead of drawing zero Meeps")
	colony._state = street_states
	colony._timer = street_timers
	colony._refresh_rows()

	var board := MeepTasks.new()
	var mine := board.post(MeepTasks.Kind.MINE, Vector2i(1, 0), 1.0)
	var build := board.post(MeepTasks.Kind.BUILD, Vector2i(2, 0), 1.0)
	var clone := board.post(MeepTasks.Kind.CLONE, Vector2i(3, 0), 1.0)
	_expect(board.best_for_kinds(Vector2i.ZERO, 2.0, 7,
			MeepColony.BUILDER_JOB_KINDS) == build
		and board.best_for_kinds(Vector2i.ZERO, 2.0, 7,
			MeepColony.HARVESTER_JOB_KINDS) == mine
		and board.best_for_kinds(Vector2i.ZERO, 2.0, 7,
			MeepColony.HOMEBODY_JOB_KINDS) == clone,
		"role-indexed queues keep Builders, Harvesters, and Homebodies on fixed work")

	var compact := MeepCityLedger.new()
	compact.site_id = &"role_fixture"
	compact.founded_seed = 31415
	compact.alive = 8
	compact.housing_capacity = 20
	compact.residential_slots = 20
	compact.resources = 200.0
	compact.harvester_rate = 2.0
	compact._cloners = 1
	compact.structures = PackedInt32Array([
		MeepStructures.Kind.BIOMASS_HARVESTER, 90, 90,
		MeepStructures.Kind.CLONER, 96, 96,
	])
	compact.identities = {
		"states": PackedByteArray([
			MeepColony.State.IDLE, MeepColony.State.IDLE,
			MeepColony.State.IDLE, MeepColony.State.IDLE,
			MeepColony.State.IDLE, MeepColony.State.IDLE,
			MeepColony.State.IDLE, MeepColony.State.IDLE,
		]),
		"roles": PackedByteArray([
			MeepColony.Role.HARVESTER, MeepColony.Role.HARVESTER,
			MeepColony.Role.HARVESTER, MeepColony.Role.HARVESTER,
			MeepColony.Role.HOMEBODY, MeepColony.Role.HOMEBODY,
			MeepColony.Role.HOMEBODY, MeepColony.Role.HOMEBODY,
		]),
		"ages": PackedFloat64Array([
			200.0, 200.0, 200.0, 200.0,
			200.0, 200.0, 200.0, 200.0,
		]),
		"maximum_health": 24.0,
	}
	compact._advance_identity_lifecycle(1.0)
	_expect(compact.staffed_harvesters()
			== MeepColony.HARVESTER_STAFF_SLOTS
		and is_equal_approx(compact.effective_harvester_rate(),
			compact.harvester_rate * (1.0
				+ MeepColony.HARVESTER_STAFF_SLOTS
					* MeepColony.HARVESTER_STAFF_BONUS)),
		"Harvesters remain indoors and persistently boost biomass-harvester output")
	compact._clone(1.0)
	var compact_roles := compact.role_counts()
	_expect(compact.alive > 8
		and compact_roles[MeepColony.Role.CHILD] == compact.alive - 8,
		"only Homebodies visit cloners and every compact birth starts as a Child")
	compact._advance_identity_lifecycle(MeepColony.CHILDHOOD_SECONDS)
	_expect(compact.role_counts()[MeepColony.Role.CHILD] == 0,
		"offscreen child cohorts mature through the same persistent role quotas")
	var compact_copy := MeepCityLedger.from_dictionary(
		compact.to_dictionary())
	var roster := compact_copy.meep_roster()
	_expect(compact_copy.role_counts() == compact.role_counts()
		and not roster.is_empty()
		and (roster[0] as Dictionary).has("type")
		and (roster[0] as Dictionary).has("health")
		and (roster[0] as Dictionary).get("tile_stats", {}) is Dictionary,
		"ledger snapshots preserve roles, workplaces, health, and extensible tile stats")
	var cohort := MeepCityLedger.new()
	cohort.site_id = &"cohort_fixture"
	cohort.founded_seed = 27182
	cohort.alive = 200
	cohort.tier = 1
	cohort.housing_capacity = 240
	cohort.residential_slots = 240
	cohort._advance_identity_lifecycle(60.0)
	cohort._append_compact_child()
	cohort.alive += 1
	cohort._advance_identity_lifecycle(59.0)
	var cohort_state := cohort.to_dictionary()
	var cohort_copy := MeepCityLedger.from_dictionary(cohort_state)
	cohort_copy._advance_identity_lifecycle(62.0)
	var cohort_counts := cohort_copy.role_counts()
	var cohort_total := 0
	for count in cohort_counts:
		cohort_total += count
	var cohort_bytes := var_to_bytes(cohort_copy.to_dictionary()).size()
	var materialized_cohort := cohort_copy.identity_snapshot()
	_expect(cohort.identities.is_empty()
		and cohort_copy.compact_child_ages.is_empty()
		and cohort_counts[MeepColony.Role.CHILD] == 0
		and cohort_total == cohort_copy.alive
		and cohort_bytes < 4096
		and (materialized_cohort.get("states",
			PackedByteArray()) as PackedByteArray).size() == cohort_copy.alive,
		"legacy 200-Meep ledgers mature persisted cohorts without per-row simulation")

	var build_gate := MeepCityLedger.new()
	build_gate.alive = 1
	build_gate.housing_capacity = MeepColony.FIRST_WAVE
	build_gate.residential_slots = MeepColony.FIRST_WAVE
	build_gate.build_kind = MeepStructures.Kind.HUT
	build_gate.build_work_remaining = 10.0
	build_gate.identities = {
		"states": PackedByteArray([MeepColony.State.IDLE]),
		"roles": PackedByteArray([MeepColony.Role.HOMEBODY]),
	}
	build_gate._build(1.0)
	var without_builder := build_gate.build_work_remaining
	build_gate.identities["roles"] = PackedByteArray([
		MeepColony.Role.BUILDER])
	build_gate._role_cache_valid = false
	build_gate._build(1.0)
	_expect(is_equal_approx(without_builder, 10.0)
		and build_gate.build_work_remaining < without_builder,
		"resident and compact construction consume only the reserved Builder pool")


func _check_region_plan_model(colony: MeepColony) -> void:
	var origin := Vector2(-100.0, -60.0)
	var dimensions := Vector2i(100, 60)
	var terrain := PackedByteArray()
	terrain.resize(dimensions.x * dimensions.y)
	terrain.fill(1)
	# One slower western town and one faster eastern town on symmetric ground.
	# The protected points deliberately sit on the opposite side of the geometric
	# bisector, proving developed land wins over a new forecast.
	var cities: Array[Dictionary] = [{
		"site": "alpha",
		"local_centre": Vector2(-42.0, 0.0),
		"forecast_rate": 1.0,
		"seed": 11,
		"protected_local": PackedVector2Array([
			Vector2(-42.0, 0.0), Vector2(18.0, 0.0)]),
	}, {
		"site": "beta",
		"local_centre": Vector2(42.0, 0.0),
		"forecast_rate": 2.0,
		"seed": 22,
		"protected_local": PackedVector2Array([Vector2(42.0, 0.0)]),
	}]
	var plan := MeepRegionPlan.new()
	var solved := plan.solve(origin, dimensions, terrain, cities)
	_expect(solved and plan.owner_at(Vector2(18.0, 0.0)) == &"alpha",
		"regional arrival ownership preserves developed land as an immutable anchor")
	var alpha_cells := 0
	var beta_cells := 0
	for owner in plan.owner_map():
		alpha_cells += 1 if owner == plan.site_index(&"alpha") else 0
		beta_cells += 1 if owner == plan.site_index(&"beta") else 0
	_expect(beta_cells > alpha_cells,
		"the faster predicted city receives more undeveloped regional territory")
	var reverse := cities.duplicate(true)
	reverse.reverse()
	var replay := MeepRegionPlan.new()
	replay.solve(origin, dimensions, terrain, reverse)
	_expect(plan.owner_map() == replay.owner_map()
		and plan.seam_records() == replay.seam_records(),
		"sorted regional site indices make ownership and gates byte-deterministic")
	var alpha_setback := plan.setback_mask(&"alpha")
	var beta_setback := plan.setback_mask(&"beta")
	_expect(alpha_setback.count(1) > 0 and beta_setback.count(1) > 0,
		"both cities receive the shared eight-metre no-building setback")
	var region_frame := MeepSite.new(
		colony.site.centre, colony.site.planet_radius, 0.0, 400.0)
	var alpha_site := MeepSite.new(
		region_frame.direction_at(Vector2(-42.0, 0.0)),
		colony.site.planet_radius, 0.0, MeepColony.MAX_CLAIM_RADIUS)
	var projected_alpha := MeepColonies._worker_region_projection(
		region_frame, alpha_site, plan, plan.site_index(&"alpha"),
		plan.owner_map(), alpha_setback)
	var projected_owner: PackedByteArray = projected_alpha.get(
		"owner", PackedByteArray())
	var projected_setback: PackedByteArray = projected_alpha.get(
		"setback", PackedByteArray())
	var projected_centre := (MeepGrid.CELLS / 2) * MeepGrid.CELLS \
		+ MeepGrid.CELLS / 2
	_expect(projected_owner.size() == MeepGrid.CELLS * MeepGrid.CELLS
		and projected_setback.size() == projected_owner.size()
		and projected_owner[projected_centre] != 0,
		"worker-preprojected local masks retain each city's owned centre")
	var has_gate := false
	for seam in plan.seam_records():
		if not (seam as Dictionary).get(
				"gate_gaps", PackedVector2Array()).is_empty():
			has_gate = true
			break
	_expect(has_gate,
		"shared seams carry deterministic player-crossing gates")
	var restored := MeepRegionPlan.new()
	_expect(restored.apply_snapshot(plan.snapshot())
		and restored.owner_map() == plan.owner_map()
		and restored.seam_records() == plan.seam_records(),
		"the RLE region snapshot round-trips owners, forecasts, seams, and gates")
	var inserted_cities := cities.duplicate(true)
	inserted_cities.push_back({
		"site": "gamma",
		"local_centre": Vector2(0.0, 34.0),
		"forecast_rate": 1.5,
		"seed": 33,
		"protected_local": PackedVector2Array([Vector2(0.0, 34.0)]),
	})
	var inserted := MeepRegionPlan.new()
	inserted.solve(origin, dimensions, terrain, inserted_cities)
	var inserted_sites: Dictionary = {}
	for owner in inserted.owner_map():
		if owner >= 0:
			inserted_sites[owner] = true
	_expect(inserted_sites.size() == 3
		and inserted.owner_at(Vector2(18.0, 0.0)) == &"alpha"
		and inserted.owner_at(Vector2(42.0, 0.0)) == &"beta"
		and inserted.owner_at(Vector2(0.0, 34.0)) == &"gamma",
		"a later third settlement recomputes one unified grid without confiscating anchors")

	var four_cities: Array[Dictionary] = []
	for row in [
			["alpha", Vector2(-42.0, -24.0), 1.0],
			["beta", Vector2(42.0, -24.0), 1.4],
			["gamma", Vector2(-42.0, 24.0), 0.8],
			["delta", Vector2(42.0, 24.0), 1.8],
	]:
		four_cities.push_back({
			"site": row[0],
			"local_centre": row[1],
			"forecast_rate": row[2],
			"seed": String(row[0]).hash(),
			"protected_local": PackedVector2Array([row[1]]),
		})
	var began := Time.get_ticks_msec()
	var four_plan := MeepRegionPlan.new()
	var four_solved := four_plan.solve(
		origin, dimensions, terrain, four_cities)
	var elapsed := Time.get_ticks_msec() - began
	var seen := {}
	for owner in four_plan.owner_map():
		if owner >= 0:
			seen[owner] = true
	_expect(four_solved and seen.size() == 4,
		"a four-city unified grid gives every member one disjoint owner partition")
	_expect(elapsed < 1000,
		"a four-city weighted regional solve remains a bounded event cost")

	var walls := MeepBorderWalls.new()
	walls.presentation_enabled = false
	walls.collision_enabled = false
	var definition := walls.define_segment(
		&"alpha", &"beta", Vector3(-10.0, 100.0, 0.0),
		Vector3(10.0, 100.0, 0.0),
		PackedVector2Array([Vector2(0.4, 0.6)]), 40.0, 10.0, 3)
	var segment_id := String(definition.get("segment_id", ""))
	walls.set_city_reached(segment_id, &"beta")
	var reservation := walls.reserve_segment(
		segment_id, &"alpha", &"alpha_builder", 40.0)
	var duplicate := walls.reserve_segment(
		segment_id, &"beta", &"beta_builder", 100.0)
	var reservation_id := int(reservation.get("reservation_id", 0))
	var progress := walls.report_progress(
		segment_id, &"alpha", reservation_id, &"alpha_builder", 10.0)
	var completion := walls.complete_segment(
		segment_id, &"alpha", reservation_id, &"alpha_builder")
	_expect(bool(reservation.get("ok", false))
		and is_equal_approx(float(reservation.get("charge_amount", 0.0)), 40.0)
		and not bool(duplicate.get("ok", false))
		and is_zero_approx(float(duplicate.get("charge_amount", 0.0))),
		"either city can reserve a shared wall but the global contract charges once")
	_expect(bool(progress.get("ready_to_complete", false))
		and bool(completion.get("newly_completed", false))
		and walls.collision_spans_for_segment(segment_id).size() == 4,
		"completed shared walls collide on both sides of their deterministic gate")
	var resettled := walls.resettle_segment(
		segment_id, Vector3(-10.0, 101.0, 0.0),
		Vector3(10.0, 101.0, 0.0),
		PackedVector2Array([Vector2(0.4, 0.6)]), 4)
	_expect(bool(resettled.get("ok", false))
		and int(walls.segment_record(segment_id).get("state", -1))
			== MeepBorderWalls.SegmentState.COMPLETE
		and is_equal_approx(
			walls.collision_spans_for_segment(segment_id)[0].y, 101.0),
		"completed shared walls resettle after terrain rebakes without reopening payment")
	var restored_walls := MeepBorderWalls.new()
	restored_walls.presentation_enabled = false
	restored_walls.collision_enabled = false
	var wall_restore := restored_walls.apply_snapshot(walls.snapshot())
	_expect(bool(wall_restore.get("ok", false))
		and restored_walls.segment_record(segment_id)
			== walls.segment_record(segment_id),
		"shared wall payment and completion persist once at registry scope")
	var live_registry := colony.get_parent() as MeepColonies
	var registry := MeepColonies.new()
	registry.planet = live_registry.planet
	add_child(registry)
	registry._border_walls.presentation_enabled = false
	registry._border_walls.collision_enabled = false
	registry._border_walls.apply_snapshot(walls.snapshot())
	var region_id := &"region_fixture"
	registry._region_plans[region_id] = plan
	registry._region_frames[region_id] = MeepSite.new(
		colony.site.centre, colony.site.planet_radius, 0.0, 400.0)
	registry._site_regions[&"alpha"] = region_id
	registry._site_regions[&"beta"] = region_id
	registry._forecast_rows[&"alpha"] = {
		"last_population": 30,
		"last_time": 90.0,
		"growth_ema": 0.2,
		"forecast_growth": 0.18,
		"error_seconds": 30.0,
	}
	registry._wall_seam_links["fixture|seam"] = segment_id
	var compact_link := MeepCityLedger.new()
	compact_link.site_id = &"alpha"
	compact_link.direction = colony.site.direction_at(Vector2(-42.0, 0.0))
	compact_link.alive = 30
	registry._ledgers[&"alpha"] = compact_link
	registry._region_clock = 120.0
	registry._next_region_replan_at = 300.0
	registry._forecast_rows[&"alpha"] = {
		"last_population": 0,
		"last_time": 90.0,
		"growth_ema": 0.0,
		"forecast_growth": 0.05,
		"error_seconds": 90.0,
	}
	registry._regions_dirty = false
	registry._regions_urgent = false
	registry._audit_region_forecasts()
	var drift_coalesced := registry.region_replan_pending() \
		and not registry.region_replan_due()
	registry.city_growth_contract_changed(&"alpha")
	var upgrade_immediate := registry.region_replan_due()
	registry._regions_dirty = false
	registry._regions_urgent = false
	registry.terrain_deformed(-compact_link.direction, 8.0, 1.0)
	var outside_ignored := not registry.region_replan_pending()
	registry.terrain_deformed(compact_link.direction, 3.0, 0.25)
	var small_ignored := not registry.region_replan_pending()
	registry.terrain_deformed(compact_link.direction, 8.0, 1.0)
	registry.terrain_deformed(compact_link.direction, 9.0, 1.5)
	var scar_coalesced := registry.region_replan_pending() \
		and not registry.region_replan_due()
	_expect(drift_coalesced and upgrade_immediate
		and outside_ignored and small_ignored and scar_coalesced,
		"forecast, upgrade, cooldown, and significant-scar triggers stay bounded and coalesced")
	registry._regions_dirty = false
	registry._regions_urgent = false
	var packet := registry.snapshot()
	var late := MeepColonies.new()
	late.planet = live_registry.planet
	add_child(late)
	late._border_walls.presentation_enabled = false
	late._border_walls.collision_enabled = false
	var late_ledger := MeepCityLedger.new()
	late_ledger.site_id = &"alpha"
	late_ledger.direction = compact_link.direction
	late._ledgers[&"alpha"] = late_ledger
	late.apply_snapshot(packet)
	var late_plan := late._region_plans.get(region_id) as MeepRegionPlan
	_expect(packet.size() >= 2
		and String((packet[0] as Dictionary).get(
			"snapshot_kind", "")) == "meep_region_registry"
		and late_plan != null
		and late_plan.owner_map() == plan.owner_map()
		and late._border_walls.segment_record(segment_id)
			== walls.segment_record(segment_id)
		and late._forecast_rows.has(&"alpha")
		and late._wall_seam_links.get("fixture|seam", "") == segment_id
		and late.ledger(&"alpha").region_id == region_id,
		"late joins restore one registry-authored region, wall, forecast, and ledger link")
	remove_child(registry)
	remove_child(late)
	registry.free()
	late.free()
	walls.free()
	restored_walls.free()


func _check_city_blueprint_model(colony: MeepColony) -> void:
	var generation_started := Time.get_ticks_msec()
	var founded_summary := colony.city_plan.lot_summary()
	var founded_kinds: PackedInt32Array = founded_summary.get(
		"by_kind", PackedInt32Array())
	var founded_civic: Dictionary = founded_summary.get("civic_by_span", {})
	_expect(founded_kinds.size() == MeepStructures.Kind.size()
		and founded_kinds[MeepStructures.Kind.MEGA_SKYSCRAPER] >= 3
		and founded_kinds[MeepStructures.Kind.ARCLOGY] >= 3
		and int(founded_civic.get(9, 0)) >= 4
		and int(founded_civic.get(12, 0)) >= 1
		and int(founded_civic.get(15, 0)) >= 1,
		"the real landing terrain retains tower campuses and every civic pad")
	var seed := 7320
	var first := MeepCityPlan.new()
	first.configure(colony.grid, colony.claim, seed)
	var baseline := first.snapshot()
	var twin := MeepCityPlan.new()
	twin.configure(colony.grid, colony.claim, seed)
	var twin_state := twin.snapshot()
	_expect(first.generated()
		and baseline["districts"] == twin_state["districts"]
		and baseline["lots"] == twin_state["lots"]
		and baseline["lot_states"] == twin_state["lot_states"],
		"the founding seed and terrain produce a byte-exact city blueprint")

	var styles: Dictionary = {}
	var layouts: Dictionary = {}
	for offset in MeepCityPlan.Style.size():
		var candidate := MeepCityPlan.new()
		candidate.configure(colony.grid, colony.claim, seed + offset)
		styles[candidate.style] = true
		layouts[hash(candidate.districts)] = true
	_expect(styles.size() == MeepCityPlan.Style.size()
		and layouts.size() >= 4,
		"founding seeds cover all city styles and produce distinct district geometry")

	var summary := first.lot_summary()
	var by_kind: PackedInt32Array = summary.get(
		"by_kind", PackedInt32Array())
	var planned_capacity := 0
	var planned_lots: PackedInt32Array = baseline.get(
		"lots", PackedInt32Array())
	for index in planned_lots.size() / MeepCityPlan.LOT_STRIDE:
		var kind := planned_lots[
			index * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_KIND]
		if kind >= 0 and MeepStructures.is_residential_kind(kind):
			planned_capacity += MeepStructures.plan_of(kind).resident_slots
	_expect(first.district_count() >= 13
		and first.road_project_count() >= 24
		and first.lot_count() >= 80
		and by_kind.size() == MeepStructures.Kind.size()
		and by_kind[MeepStructures.Kind.TOWNHOUSE] >= 14
		and by_kind[MeepStructures.Kind.MID_RISE] >= 10
		and by_kind[MeepStructures.Kind.SKYSCRAPER] >= 8
		and by_kind[MeepStructures.Kind.MEGA_SKYSCRAPER] >= 5
		and by_kind[MeepStructures.Kind.ARCLOGY] >= 3
		and planned_capacity >= colony.population_ceiling(4),
		"one compact plan carries streets and staged housing for a 10k+ city")
	var civic_by_span: Dictionary = summary.get("civic_by_span", {})
	var civic_districts: Dictionary = {}
	var ordinary_districts: Dictionary = {}
	var all_lots_inside_reach := true
	for lot in planned_lots.size() / MeepCityPlan.LOT_STRIDE:
		var lot_kind := planned_lots[
			lot * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_KIND]
		var lot_district := planned_lots[
			lot * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_DISTRICT]
		var lot_span := Vector2i(
			planned_lots[lot * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_MAX_SPAN],
			planned_lots[lot * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_MAX_SPAN]) \
			if lot_kind == MeepCityPlan.CIVIC_LOT \
			else MeepStructures.plan_of(lot_kind).span
		var lot_corner := Vector2i(
			planned_lots[lot * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_X],
			planned_lots[lot * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_Y]) \
			- Vector2i(lot_span.x / 2, lot_span.y / 2)
		var district_reach := float(first.districts[
			lot_district * MeepCityPlan.DISTRICT_STRIDE
				+ MeepCityPlan.DISTRICT_REACH_DM]) * 0.1
		for y in lot_span.y:
			for x in lot_span.x:
				all_lots_inside_reach = all_lots_inside_reach \
					and colony.grid.centre_of(
						lot_corner + Vector2i(x, y)).length() \
						<= district_reach + 0.001
		if lot_kind == MeepCityPlan.CIVIC_LOT:
			civic_districts[lot_district] = true
		else:
			ordinary_districts[lot_district] = true
	_expect(int(civic_by_span.get(9, 0)) >= 4
		and int(civic_by_span.get(12, 0)) > 0
		and int(civic_by_span.get(15, 0)) > 0
		and int(civic_by_span.get(9, 0))
			+ int(civic_by_span.get(12, 0))
			+ int(civic_by_span.get(15, 0)) >= 6
		and all_lots_inside_reach
		and civic_districts.size() >= 3
		and ordinary_districts.size() >= 3,
		"future 9x9, 12x12, and 15x15 upgrade pads mix through ordinary districts")

	var park_cells := 0
	for value in first.park_mask():
		park_cells += 1 if value != 0 else 0
	var founding_permit := first.permit_mask()
	var permitted_before := 0
	for value in founding_permit:
		permitted_before += 1 if value != 0 else 0
	var radial_core_cells := 0
	var radial_missing := 0
	var shaped_outside := 0
	for index in colony.grid.cells * colony.grid.cells:
		var cell := Vector2i(
			index % colony.grid.cells, index / colony.grid.cells)
		var radial := colony.grid.centre_of(cell).length() \
			<= MeepClaim.DEFAULT_RADIUS \
			and colony.grid.regionally_owned_index(index)
		var permitted := index < founding_permit.size() \
			and founding_permit[index] != 0
		if radial:
			radial_core_cells += 1
			radial_missing += 1 if not permitted else 0
		elif permitted:
			shaped_outside += 1
	_expect(radial_missing + shaped_outside
			>= roundi(float(radial_core_cells) * 0.07)
		and radial_missing > 0 and shaped_outside > 0,
		"the founding permit is a visibly shaped core instead of a near-circle")
	var old_permit_revision := first.permit_revision()
	var next_townhouse_district := -1
	for index in planned_lots.size() / MeepCityPlan.LOT_STRIDE:
		if planned_lots[index * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_KIND] == MeepStructures.Kind.TOWNHOUSE:
			next_townhouse_district = planned_lots[
				index * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_DISTRICT]
			break
	var pending_townhouse := first.prepared_lot(MeepStructures.Kind.TOWNHOUSE)
	var demanded_reach := 0.0
	for district in first.active_districts:
		demanded_reach = maxf(demanded_reach, float(first.districts[
			district * MeepCityPlan.DISTRICT_STRIDE
				+ MeepCityPlan.DISTRICT_REACH_DM]) * 0.1)
	_expect(pending_townhouse.is_empty()
		and next_townhouse_district >= 1
		and first.active_districts == next_townhouse_district + 1
		and is_equal_approx(first.target_radius(), demanded_reach),
		"housing demand activates only its next dormant residential district")
	var permitted_after := 0
	for value in first.permit_mask():
		permitted_after += 1 if value != 0 else 0
	_expect(park_cells > 0
		and first.active_districts > 1
		and first.target_radius() > MeepClaim.DEFAULT_RADIUS
		and first.permit_revision() > old_permit_revision
		and permitted_after > permitted_before,
		"demand activates a shaped district with parks instead of another radial ring")

	var committed_lot := -1
	for index in first.lot_count():
		if first.lots[index * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_KIND] == MeepStructures.Kind.HUT:
			committed_lot = index
			break
	var lot_mask_revision := first.mask_revision()
	var lot_permit_revision := first.permit_revision()
	var commit_started := Time.get_ticks_usec()
	first.commit_lot(committed_lot)
	var commit_ms := float(Time.get_ticks_usec() - commit_started) / 1000.0
	var committed_mask_cleared := true
	var planned_mask := first.planned_lot_mask()
	for cell_index in first.lot_cell_indices(committed_lot):
		committed_mask_cleared = committed_mask_cleared \
			and planned_mask[cell_index] == 0
	_expect(committed_mask_cleared
		and first.mask_revision() > lot_mask_revision
		and first.permit_revision() == lot_permit_revision
		and commit_ms < 10.0,
		"consuming a lot patches only its footprint without rebuilding the district")
	var saved := first.snapshot()
	var restored := MeepCityPlan.new()
	restored.apply_snapshot(saved)
	restored.configure(colony.grid, colony.claim, seed)
	var restored_state := restored.snapshot()
	_expect(committed_lot >= 0
		and restored_state["districts"] == saved["districts"]
		and restored_state["lots"] == saved["lots"]
		and restored_state["lot_states"] == saved["lot_states"]
		and int(restored_state["active_districts"])
			== int(saved["active_districts"])
		and int(restored_state["requested_district"])
			== int(saved["requested_district"]),
		"save and late-join snapshots round-trip opened districts and consumed lots")
	var before_rebake := restored.snapshot()
	restored.configure(colony.grid, colony.claim, seed)
	var after_rebake := restored.snapshot()
	_expect(after_rebake == before_rebake,
		"a terrain rebake rebinds the founding plan without regenerating city progress")

	var migrated := MeepCityPlan.new()
	migrated.apply_snapshot({
		"version": 0,
		"style": MeepCityPlan.Style.TERRACES,
		"active_districts": 9,
	})
	migrated.configure(colony.grid, colony.claim, seed + 2)
	_expect(migrated.generated()
		and int(migrated.snapshot().get("version", 0)) == MeepCityPlan.VERSION
		and migrated.active_districts == 1
		and migrated.lot_count() >= 80,
		"a pre-blueprint city migrates to one complete founding plan")

	var ledger_result := MeepCityPlan.ledger_prepare_lot(
		baseline.duplicate(true), MeepStructures.Kind.TOWNHOUSE,
		MeepClaim.DEFAULT_RADIUS)
	var ledger_state: Dictionary = ledger_result.get("state", {})
	var ledger_target := float(ledger_result.get("target_radius", 0.0))
	var ledger_finished := MeepCityPlan.ledger_finish_expansion(
		ledger_state, ledger_target)
	_expect(bool(ledger_result.get("managed", false))
		and not bool(ledger_result.get("ready", true))
		and ledger_target > MeepClaim.DEFAULT_RADIUS
		and int(ledger_state.get("active_districts", 1)) > 1
		and int(ledger_finished.get("requested_district", 0)) == -1,
		"offscreen demand opens and completes the same planned district")
	var clip_plan := MeepCityPlan.new()
	clip_plan.configure(colony.grid, colony.claim, seed + 19)
	var fixed_lot := -1
	var moving_lot := -1
	for lot in clip_plan.lot_count():
		if fixed_lot < 0:
			fixed_lot = lot
		elif moving_lot < 0:
			moving_lot = lot
			break
	clip_plan.commit_lot(fixed_lot)
	var fixed_before := Vector2i(
		clip_plan.lots[fixed_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_X],
		clip_plan.lots[fixed_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_Y])
	var moving_before := Vector2i(
		clip_plan.lots[moving_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_X],
		clip_plan.lots[moving_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_Y])
	var owner_clip := PackedByteArray()
	var setback_clip := PackedByteArray()
	owner_clip.resize(colony.grid.cells * colony.grid.cells)
	owner_clip.fill(1)
	setback_clip.resize(owner_clip.size())
	owner_clip[colony.grid.index(moving_before)] = 0
	setback_clip[colony.grid.index(moving_before)] = 1
	colony.grid.bind_region_masks(owner_clip, setback_clip, 91)
	var foreign_index := colony.grid.index(moving_before)
	var foreign_corner := moving_before \
		- MeepStructures.plan_of(MeepStructures.Kind.HUT).span / 2
	_expect(not colony.claim._permitted(foreign_index)
		and not colony.roads._cell_allowed(foreign_index)
		and colony.structures._placement_score(
			MeepStructures.plan_of(MeepStructures.Kind.HUT),
			foreign_corner) == -INF,
		"claims, roads, structures, and jobs all reject another city's regional cells")
	clip_plan.reflow_region_clip()
	var fixed_after := Vector2i(
		clip_plan.lots[fixed_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_X],
		clip_plan.lots[fixed_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_Y])
	var moving_after := Vector2i(
		clip_plan.lots[moving_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_X],
		clip_plan.lots[moving_lot * MeepCityPlan.LOT_STRIDE
			+ MeepCityPlan.LOT_Y])
	_expect(fixed_after == fixed_before
		and (moving_after != moving_before
			or clip_plan.lot_states[moving_lot]
				== MeepCityPlan.LOT_REGION_BLOCKED),
		"regional revisions preserve built lots and deterministically reflow only free work")
	colony.grid.bind_region_masks(
		PackedByteArray(), PackedByteArray(), -1)
	var generation_ms := Time.get_ticks_msec() - generation_started
	print("meep_test: eight complete city plans took %d ms" % generation_ms)
	_expect(generation_ms < 4000,
		"founding plans remain one bounded setup cost rather than runtime scanning")


func _check_city_projection(colony: MeepColony) -> void:
	var real_structures := colony.structures.snapshot()
	var real_roads := colony.roads.snapshot()
	var real_plan := colony.city_plan.snapshot()
	var site := MeepSite.new(
		colony.site.centre, colony.site.planet_radius,
		colony.site.facing, MeepColony.MAX_CLAIM_RADIUS)
	var ground := MeepCityProjection.ground_snapshot(colony.grid)
	var config := {
		"site": site,
		"shape": colony._shape,
		"ground": ground,
		"seed": 0x51A7,
		"population": 32,
	}
	var starter := MeepCityProjection.project(config)
	var starter_twin := MeepCityProjection.project(config)
	var starter_structures: PackedInt32Array = starter.get(
		"structures", PackedInt32Array())
	var starter_roads: PackedInt32Array = starter.get(
		"roads", PackedInt32Array())
	_expect(not starter.is_empty()
		and int(starter.get("projected_population", 0)) == 32
		and int(starter.get("housing_capacity", 0)) >= 32
		and starter_structures.size() / 3 >= MeepColony.STARTER_STRUCTURES
		and not starter_roads.is_empty()
		and starter == starter_twin,
		"population projection deterministically builds the production starter city")

	var mature_config := config.duplicate(true)
	mature_config["population"] = 160
	var mature := MeepCityProjection.project(mature_config)
	var mature_structures: PackedInt32Array = mature.get(
		"structures", PackedInt32Array())
	var mature_roads: PackedInt32Array = mature.get(
		"roads", PackedInt32Array())
	_expect(int(mature.get("projected_population", 0)) == 160
		and int(mature.get("tier", 0)) >= 2
		and mature_structures.size() > starter_structures.size()
		and mature_roads.size() >= starter_roads.size()
		and (mature.get("structure_forms", PackedInt32Array())
			as PackedInt32Array).size() > 0,
		"larger dummy populations project denser tier forms, roads, and upgrades")

	var flat_shape := FlatProjectionShape.new()
	flat_shape.radius = site.planet_radius
	var flat_site := MeepSite.new(
		site.centre, flat_shape.radius, site.facing,
		MeepColony.MAX_CLAIM_RADIUS)
	var tier_config := {
		"site": flat_site,
		"shape": flat_shape,
		"ground": MeepCityProjection.bake_ground(
			flat_site, flat_shape),
		"seed": 0x51A7,
	}
	var tier_projection_ok := true
	var previous_structure_count := 0
	var previous_projected_population := 0
	var maximum_projection: Dictionary = {}
	for tier_index: int in [0, 2, 3, 4]:
		var tier_population: int = \
			MeepColony.TIER_POPULATION_CEILINGS[tier_index]
		var tier_projection := MeepCityProjection.project(
			tier_config.merged(
				{"population": tier_population}, true))
		var tier_structures: PackedInt32Array = tier_projection.get(
			"structures", PackedInt32Array())
		var structure_count := tier_structures.size() / 3
		var projected_population := int(tier_projection.get(
			"projected_population", 0))
		var housing_capacity := int(tier_projection.get(
			"housing_capacity", 0))
		var stalled := bool(tier_projection.get("stalled", true))
		tier_projection_ok = tier_projection_ok \
			and int(tier_projection.get(
				"population", 0)) == tier_population \
			and projected_population <= tier_population \
			and projected_population >= previous_projected_population \
			and housing_capacity >= projected_population \
			and stalled == (projected_population < tier_population) \
			and structure_count >= previous_structure_count
		previous_projected_population = projected_population
		previous_structure_count = structure_count
		if tier_index == MeepColony.MAX_CITY_TIER:
			maximum_projection = tier_projection
	_expect(tier_projection_ok,
		"every tier request projects monotonically or reports its physical site limit")
	_expect(MeepBlueprintPreviewRegistry.MAX_POPULATION
			== MeepColony.MAX_CITY_POPULATION
		and int(maximum_projection.get(
			"projected_population", 0)) >= 10000
		and not bool(maximum_projection.get("stalled", true)),
		"Blueprint projection physically reaches more than ten thousand residents")

	var visual := MeepBlueprintCityVisual.new()
	visual.configure(colony._planet, &"projection_test",
		site.centre, site.facing, 0x51A7)
	colony.get_parent().add_child(visual)
	visual.apply_projection(mature)
	var lamp_stand := visual.find_child(
		"StreetLightPoles", true, false) as MultiMeshInstance3D
	_expect(visual.roads != null and visual.structures != null
		and lamp_stand != null
		and not visual.has_gameplay_collision()
		and visual.roads.snapshot() == mature_roads
		and visual.structures.snapshot() == mature_structures,
		"blueprint visuals reuse production roads, lamps, and structures without collision")
	visual.queue_free()

	_expect(colony.structures.snapshot() == real_structures
		and colony.roads.snapshot() == real_roads
		and colony.city_plan.snapshot() == real_plan,
		"hypothetical projection leaves the real colony and plan byte-for-byte unchanged")


func _check_megacity_projection(colony: MeepColony) -> void:
	var flat_shape := FlatProjectionShape.new()
	flat_shape.radius = colony.site.planet_radius
	var flat_site := MeepSite.new(
		colony.site.centre, flat_shape.radius, colony.site.facing,
		MeepColony.MAX_CLAIM_RADIUS)
	var projection := MeepCityProjection.project({
		"site": flat_site,
		"shape": flat_shape,
		"ground": MeepCityProjection.bake_ground(flat_site, flat_shape),
		"seed": 0x51A7,
		"population": MeepColony.MAX_CITY_POPULATION,
	})
	var kind_counts: Dictionary = {}
	var structures: PackedInt32Array = projection.get(
		"structures", PackedInt32Array())
	for offset in range(0, structures.size(), 3):
		kind_counts[structures[offset]] = int(
			kind_counts.get(structures[offset], 0)) + 1
	print("meep_test: megacity population=%d housing=%d skyline=%s stalled=%s" % [
		int(projection.get("projected_population", 0)),
		int(projection.get("housing_capacity", 0)),
		str(kind_counts),
		str(projection.get("stalled", true)),
	])
	_expect(int(projection.get("projected_population", 0))
			== MeepColony.MAX_CITY_POPULATION
		and int(projection.get("housing_capacity", 0))
			>= MeepColony.MAX_CITY_POPULATION
		and int(kind_counts.get(MeepStructures.Kind.SKYSCRAPER, 0)) >= 7
		and int(kind_counts.get(MeepStructures.Kind.MEGA_SKYSCRAPER, 0)) >= 5
		and int(kind_counts.get(MeepStructures.Kind.ARCLOGY, 0)) >= 2
		and not bool(projection.get("stalled", true)),
		"a maximum Blueprint projects a dense skyline for the complete 10k+ city")


func _surface_test_grid(site: MeepSite) -> MeepGrid:
	var grid := MeepGrid.new(site, 48, 2.0)
	grid.terrain.fill(MeepGrid.Terrain.PASSABLE)
	grid.heights.fill(0.0)
	grid.flags.fill(MeepGrid.FLAG_NONE)
	grid.surface_heights.fill(NAN)
	grid.built = true
	grid.revision += 1
	return grid


func _check_surface_model(colony: MeepColony) -> void:
	_expect(MeepRoads.SurfaceKind.LAND == 0
		and MeepRoads.SurfaceKind.BRIDGE == 1
		and MeepRoads.SurfaceKind.RAMP == 2
		and MeepRoads.SurfaceKind.DOCK == 3
		and MeepStructures.Kind.DOCK_HUT
			== MeepStructures.Kind.SKYSCRAPER + 1,
		"surface and dock-hut wire enums append without moving legacy values")
	_expect(MeepColony.city_purchase_cost(
			MeepColony.CityPurchase.BRIDGES) == 150.0
		and MeepColony.city_purchase_cost(
			MeepColony.CityPurchase.COASTS) == 175.0,
		"bridge and coast unlocks retain their exact permanent prices")
	var unlock_city := MeepColony.new()
	add_child(unlock_city)
	unlock_city.resources = 325.0
	_expect(unlock_city.try_city_purchase(MeepColony.CityPurchase.BRIDGES)
		and not unlock_city.try_city_purchase(MeepColony.CityPurchase.BRIDGES)
		and unlock_city.try_city_purchase(MeepColony.CityPurchase.COASTS)
		and unlock_city.city_upgrade_built(MeepColony.CityPurchase.BRIDGES)
		and unlock_city.city_upgrade_built(MeepColony.CityPurchase.COASTS)
		and is_zero_approx(unlock_city.resources),
		"surface unlocks are permanent, exact-cost, and idempotent")
	unlock_city.free()

	# A full-height synthetic crevasse makes the before/after connectivity exact:
	# there is no route around its ends inside this grid.
	var bridge_grid := _surface_test_grid(colony.site)
	for y in bridge_grid.cells:
		for x in range(32, 35):
			var cell := Vector2i(x, y)
			bridge_grid.terrain[bridge_grid.index(cell)] = MeepGrid.Terrain.VOID
			bridge_grid.heights[bridge_grid.index(cell)] = -8.0
	var bridge_claim := MeepClaim.new()
	bridge_claim.build(bridge_grid, Vector2.ZERO, 45.0)
	var far := Vector2i(36, bridge_claim.origin.y)
	_expect(not bridge_claim.contains_cell(far)
		and not bridge_grid.passable(Vector2i(33, bridge_claim.origin.y))
		and not bridge_grid.raw_claimable(
			Vector2i(33, bridge_claim.origin.y), false),
		"bridge unlock alone cannot claim or walk unsupported void")
	var bridge_roads := MeepRoads.new()
	bridge_roads.configure(colony.site, bridge_grid, bridge_claim, null, null, 71)
	var scan_started := Time.get_ticks_msec()
	var bridge_candidate := bridge_roads.next_surface_candidate(true, false)
	var bridge_start: Vector2i = bridge_candidate.get(
		"start", bridge_claim.origin)
	var approach_field := MeepFlowField.new()
	approach_field.build(bridge_grid, bridge_claim.origin)
	var approach := bridge_roads.path_home_from(bridge_start, approach_field)
	var approach_segment := bridge_roads.plan(-10, approach)
	bridge_roads.complete(approach_segment)
	bridge_candidate = bridge_roads.next_surface_candidate(true, false)
	var bridge_cells: PackedInt32Array = bridge_candidate.get(
		"cells", PackedInt32Array())
	var bridge_heights: PackedFloat32Array = bridge_candidate.get(
		"heights", PackedFloat32Array())
	var bridge_kind := int(bridge_candidate.get(
		"surface_kind", MeepRoads.SurfaceKind.LAND))
	# Routine streets are deliberately kept unfinished here. They must not starve
	# the higher-priority frontier bridge planner.
	var routine_segment := bridge_roads.plan(
		-11, PackedInt32Array([0]))
	var bridge_city := MeepColony.new()
	add_child(bridge_city)
	bridge_city.site = colony.site
	bridge_city.grid = bridge_grid
	bridge_city.claim = bridge_claim
	bridge_city.roads = bridge_roads
	bridge_city.claim_radius = 45.0
	bridge_city.resources = 10000.0
	bridge_city._alive = 6
	bridge_city._ground_ready = true
	bridge_city._fields[bridge_claim.origin] = approach_field
	var bridge_unlocked := bridge_city.try_city_purchase(
		MeepColony.CityPurchase.BRIDGES)
	bridge_city._plan_surfaces()
	var bridge_segment := bridge_roads.count() - 1
	var automatic_bridge := bridge_roads.at(bridge_segment)
	_expect(bridge_unlocked and not bridge_roads.at(routine_segment).built()
		and automatic_bridge != null
		and automatic_bridge.frontier_surface_project
		and automatic_bridge.surface_kind == bridge_kind
		and automatic_bridge.cells == bridge_cells
		and bridge_roads.has_unfinished_surface_project(),
		"routine street work does not starve an unlocked frontier bridge")
	bridge_roads.complete(bridge_segment)
	bridge_city.tasks.finish(automatic_bridge.job)
	bridge_claim.build(bridge_grid, Vector2.ZERO, 45.0)
	var bridge_field := MeepFlowField.new()
	bridge_field.build(bridge_grid, bridge_claim.origin)
	_expect(bridge_kind == MeepRoads.SurfaceKind.BRIDGE
		and bridge_grid.has_flag(bridge_start, MeepGrid.FLAG_ROAD)
		and bridge_claim.contains_cell(far) and bridge_field.reachable(far)
		and not bridge_roads.has_unfinished_surface_project(),
		"a road-connected completed bridge makes the far level claimable and routable")
	# Terrain rebakes erase constructed surfaces before roads are resettled. The
	# post-resettle claim refresh must see the restored deck even when growth has
	# already reached its cap and no future radius tick can repair the boundary.
	for cell_index in bridge_cells:
		var bridge_cell := Vector2i(
			cell_index % bridge_grid.cells, cell_index / bridge_grid.cells)
		bridge_grid.set_surface(bridge_cell, 0.0, false)
		bridge_grid.set_flag(bridge_cell, MeepGrid.FLAG_ROAD, false)
	bridge_claim.build(bridge_grid, Vector2.ZERO, 45.0)
	var rebake_lost_far_bank := not bridge_claim.contains_cell(far)
	bridge_roads.resettle()
	bridge_city._repair_claim_over_surfaces()
	var repaired_far_bank := bridge_claim.contains_cell(far)
	var repaired_count := bridge_claim.count
	# The seeded repair replaced a full flood at the end of every ground bake, so
	# it has to reach exactly the claim that full flood would have found.
	var reference_deck_claim := MeepClaim.new()
	reference_deck_claim.build(bridge_grid, Vector2.ZERO, 45.0, false,
		PackedVector3Array(), PackedByteArray(), false)
	_expect(rebake_lost_far_bank and repaired_far_bank
			and repaired_count == reference_deck_claim.count,
		"restored bridge decks are re-flooded before the rebuilt border is drawn")
	_expect(Time.get_ticks_msec() - scan_started < 1000,
		"deterministic frontier surface planning stays within its performance budget")
	_expect(bridge_roads.visible_surface_faces()
			== bridge_roads.collision_faces()
		and not bridge_roads.collision_faces().is_empty(),
		"road and bridge collision uses the exact visible final surface triangles")
	var bridge_state := bridge_roads.snapshot()
	var bridge_widths := bridge_roads.width_snapshot()
	var bridge_surfaces := bridge_roads.surface_snapshot()
	var bridge_copy := MeepRoads.new()
	bridge_copy.configure(
		colony.site, bridge_grid, bridge_claim, null, null, 71)
	bridge_copy.apply_snapshot(bridge_state)
	bridge_copy.apply_width_snapshot(bridge_widths)
	bridge_copy.apply_surface_snapshot(bridge_surfaces)
	bridge_copy.draw()
	_expect(bridge_copy.surface_snapshot() == bridge_surfaces
		and bridge_copy.collision_faces() == bridge_roads.collision_faces(),
		"late joiners restore bridge kind, cell, height, width, and collision")
	bridge_copy.free()
	bridge_city.free()
	bridge_roads.free()

	# A completed broad commission blocks its original west-side work cell at a
	# synthetic choke. The south/east perimeter remains connected to the home field;
	# road planning must use it rather than leaving tier completion impossible.
	var access_city := MeepColony.new()
	add_child(access_city)
	var access_grid := _surface_test_grid(colony.site)
	var access_claim := MeepClaim.new()
	access_claim.build(access_grid, Vector2.ZERO, 40.0)
	var access_roads := MeepRoads.new()
	access_roads.configure(
		colony.site, access_grid, access_claim, null, null, 75)
	var access_structures := MeepStructures.new()
	access_structures.configure(colony.site, access_grid, access_claim,
		null, null, access_city, access_roads)
	var access_corner := access_claim.origin + Vector2i(7, -3)
	var access_structure := access_structures.place_at(
		MeepStructures.Kind.HAT_HOUSE, access_corner)
	access_city.site = colony.site
	access_city.grid = access_grid
	access_city.claim = access_claim
	access_city.roads = access_roads
	access_city.structures = access_structures
	access_city.stats = MeepStats.new()
	access_city._ground_ready = true

	var surround_job_id := access_city.tasks.post(MeepTasks.Kind.BUILD,
		access_structures.work_cell(access_structure),
		MeepColony.BUILD_PRIORITY, 6, 100.0)
	var surround_job := access_city.tasks.job(surround_job_id)
	surround_job.subject = access_structure
	var surround_cells: Array[Vector2i] = []
	var surround_claimed := true
	for slot in 6:
		var row := access_city._add(
			access_grid.centre_of(access_claim.origin), 700 + slot)
		access_city._roles[row] = MeepColony.Role.BUILDER
		access_city._decide(row)
		surround_claimed = surround_claimed \
			and access_city._job[row] == surround_job_id \
			and access_city._state[row] == MeepColony.State.WALK
		var destination := access_grid.cell_of(access_city._goal[row])
		surround_cells.push_back(destination)
	var distinct_surround_cells: Dictionary = {}
	var occupied_sides: Dictionary = {}
	var surround_plan := MeepStructures.plan_of(
		MeepStructures.Kind.HAT_HOUSE)
	for cell in surround_cells:
		distinct_surround_cells[access_grid.index(cell)] = true
		if cell.x < access_corner.x:
			occupied_sides[0] = true
		elif cell.x >= access_corner.x + surround_plan.span.x:
			occupied_sides[1] = true
		elif cell.y < access_corner.y:
			occupied_sides[2] = true
		elif cell.y >= access_corner.y + surround_plan.span.y:
			occupied_sides[3] = true
	_expect(surround_claimed and distinct_surround_cells.size() == 6
		and occupied_sides.size() == 4,
		"a six-Meep building crew takes distinct slots around all four sides")

	var facing_row := 0
	access_city._local[facing_row] = access_grid.centre_of(
		surround_cells[facing_row])
	access_city._goal[facing_row] = access_city._local[facing_row]
	access_city._state[facing_row] = MeepColony.State.WALK
	access_city._arrive(facing_row)
	var toward_building := (
		access_structures.at(access_structure).local
			- access_city._local[facing_row]).normalized()
	_expect(access_city._state[facing_row] == MeepColony.State.WORK
		and access_city._heading[facing_row].dot(toward_building) > 0.99,
		"builders face inward from their perimeter slot while working")
	for row in access_city.count():
		access_city._detail[row] = MeepColony.Detail.COLD
		access_city._since[row] = 0.0
	var cold_progress_before := access_structures.at(access_structure).progress
	var cold_walk_before := access_city._local[1]
	access_city._advance_residents(MeepColony.SIM_STEP)
	_expect(access_structures.at(access_structure).progress
			> cold_progress_before
		and access_city._local[1].distance_to(cold_walk_before) > 0.01,
		"unwatched Meeps keep building and traveling while the player is away")
	access_city.tasks.finish(surround_job_id)
	for row in access_city.count():
		access_city._job[row] = 0
		access_city._state[row] = MeepColony.State.IDLE

	access_structures.at(access_structure).progress = 1.0
	var blocked_door := access_structures.work_cell(access_structure)
	access_structures.block(access_structure)
	access_grid.set_flag(blocked_door, MeepGrid.FLAG_BUILDING)
	var access_field := MeepFlowField.new()
	access_field.build(access_grid, access_claim.origin)
	access_city.resources = 10000.0
	access_city._alive = 32
	access_city._ground_ready = true
	access_city.tier_allocated_flags = 1
	access_city._fields[access_claim.origin] = access_field
	access_city._plan_roads()
	var access_segment := access_roads.at(0)
	var used_alternate := access_segment != null \
		and not access_segment.cells.is_empty() \
		and access_roads._cell(access_segment.cells[0]) != blocked_door
	if access_segment != null:
		access_roads.complete(0)
	_expect(access_roads.has_subject(access_structure) and used_alternate,
		"a blocked nominal doorway deterministically plans from a reachable perimeter")
	_expect(access_segment != null and access_segment.built() \
		and access_city._current_tier_ready(),
		"alternate access physically completes its road subject and resolves tier readiness")
	access_city.queue_free()
	await get_tree().process_frame

	var ramp_grid := _surface_test_grid(colony.site)
	for y in ramp_grid.cells:
		for x in range(28, 37):
			ramp_grid.terrain[ramp_grid.index(
				Vector2i(x, y))] = MeepGrid.Terrain.STEEP
			ramp_grid.heights[ramp_grid.index(
				Vector2i(x, y))] = float(x - 27) * 1.5
		for x in range(37, ramp_grid.cells):
			ramp_grid.heights[ramp_grid.index(Vector2i(x, y))] = 15.0
	var ramp_claim := MeepClaim.new()
	ramp_claim.build(ramp_grid, Vector2.ZERO, 45.0)
	var upper_hill := Vector2i(43, ramp_claim.origin.y)
	var hill_was_cut_off := not ramp_claim.contains_cell(upper_hill)
	var ramp_roads := MeepRoads.new()
	ramp_roads.configure(colony.site, ramp_grid, ramp_claim, null, null, 73)
	var ramp_candidate := ramp_roads.next_surface_candidate(true, false)
	var ramp_kind := int(ramp_candidate.get(
		"surface_kind", MeepRoads.SurfaceKind.LAND))
	var ramp_start: Vector2i = ramp_candidate.get(
		"start", ramp_claim.origin)
	var ramp_endpoint: Vector2i = ramp_candidate.get(
		"endpoint", ramp_claim.origin)
	var ramp_cells: PackedInt32Array = ramp_candidate.get(
		"cells", PackedInt32Array())
	var ramp_heights: PackedFloat32Array = ramp_candidate.get(
		"heights", PackedFloat32Array())
	var ramp_run := float(ramp_cells.size() + 1) * ramp_grid.cell_size
	var ramp_grade := absf(
		ramp_grid.height_at(ramp_endpoint)
			- ramp_grid.height_at(ramp_start)) / maxf(ramp_run, 0.001)
	var ramp_segment := ramp_roads.plan(-73, ramp_cells,
		MeepRoads.WidthClass.STREET, ramp_kind, ramp_heights)
	ramp_roads.complete(ramp_segment)
	ramp_claim.build(ramp_grid, Vector2.ZERO, 45.0)
	var hill_field := MeepFlowField.new()
	hill_field.build(ramp_grid, ramp_claim.origin)
	_expect(hill_was_cut_off
		and ramp_kind == MeepRoads.SurfaceKind.RAMP
		and ramp_cells.size() > 9
		and ramp_grade <= MeepRoads.MAX_RAMP_GRADE + 0.0001
		and ramp_claim.contains_cell(upper_hill)
		and hill_field.reachable(upper_hill),
		"a broad natural-grade hill gets a safe extended ramp and no longer traps the border or Meeps")
	ramp_roads.free()

	var dock_grid := _surface_test_grid(colony.site)
	for y in dock_grid.cells:
		for x in range(32, 41):
			var shallow := Vector2i(x, y)
			dock_grid.terrain[dock_grid.index(
				shallow)] = MeepGrid.Terrain.SHALLOW
			dock_grid.heights[dock_grid.index(shallow)] = -2.0
		for x in range(41, dock_grid.cells):
			var deep := Vector2i(x, y)
			dock_grid.terrain[dock_grid.index(deep)] = MeepGrid.Terrain.WATER
			dock_grid.heights[dock_grid.index(deep)] = -6.0
	var dock_claim := MeepClaim.new()
	dock_claim.build(dock_grid, Vector2.ZERO, 45.0, true)
	var undecked_shallow := Vector2i(34, dock_claim.origin.y)
	var deep_cell := Vector2i(42, dock_claim.origin.y)
	_expect(dock_claim.contains_cell(undecked_shallow)
		and not dock_grid.passable(undecked_shallow)
		and not dock_claim.contains_cell(deep_cell)
		and dock_grid.raw_claimable(undecked_shallow, true)
		and not dock_grid.raw_claimable(deep_cell, true),
		"coasts claim connected <=5 m shallows before decks without making them walkable")
	var dock_roads := MeepRoads.new()
	dock_roads.configure(colony.site, dock_grid, dock_claim, null, null, 79)
	var dock_candidate := dock_roads.next_surface_candidate(false, true)
	var dock_cells: PackedInt32Array = dock_candidate.get(
		"cells", PackedInt32Array())
	var dock_heights: PackedFloat32Array = dock_candidate.get(
		"heights", PackedFloat32Array())
	var dock_kind := int(dock_candidate.get(
		"surface_kind", MeepRoads.SurfaceKind.LAND))
	var dock_segment := dock_roads.plan(-2, dock_cells,
		MeepRoads.WidthClass.STREET, dock_kind, dock_heights)
	dock_roads.complete(dock_segment)
	dock_claim.build(dock_grid, Vector2.ZERO, 45.0, true)
	var deck_cell := dock_roads._cell(dock_cells[dock_cells.size() - 1])
	_expect(dock_kind == MeepRoads.SurfaceKind.DOCK
		and dock_claim.contains_cell(deck_cell) and dock_grid.passable(deck_cell)
		and not dock_claim.contains_cell(deep_cell)
		and dock_roads.dock_pile_count() == dock_cells.size()
		and not dock_roads.dock_pile_faces().is_empty(),
		"dock planning grows through claimed shallows and adds seabed pile supports")
	var dock_structures := MeepStructures.new()
	dock_structures.configure(colony.site, dock_grid, dock_claim,
		null, null, null, dock_roads)
	var dock_hut := dock_structures.place_dock_hut(1)
	if dock_hut >= 0:
		dock_structures.at(dock_hut).progress = 1.0
	_expect(dock_hut >= 0
		and dock_structures.at(dock_hut).kind == MeepStructures.Kind.DOCK_HUT
		and dock_structures.residential_capacity() == 4,
		"append-only dock huts place only on dock platforms and provide housing")
	dock_structures.free()
	dock_roads.free()


func _check_continuous_expansion(colony: MeepColony) -> void:
	var before := colony.city_progression_snapshot().duplicate(true)
	var was_space_full := colony.tier_zero_space_exhausted()
	var was_complete := colony.tier_zero_full()
	var old_plan_left := colony._plan_left
	var old_structures := colony.structures.snapshot()
	var old_forms := colony.structures.form_snapshot()
	var old_upgrades := colony.structures.upgrade_progress_snapshot()
	var old_roads := colony.roads.snapshot()
	var old_widths := colony.roads.width_snapshot()
	var old_surfaces := colony.roads.surface_snapshot()
	var old_deeds := colony.deed_snapshot()
	colony._plan_left = INF
	colony.resources = 5000.0
	colony.committed = 0.0
	var starting_tier := colony.tier
	var starting_radius := colony.claim_radius
	var starting_cells := colony.claim.count
	var automatic_rate := colony.expansion_rate()
	colony.call("_simulate_border_growth", 10.0)
	_expect(is_equal_approx(colony.claim_radius, starting_radius),
		"a prepared city border waits until construction needs another district")
	var plan_revision := colony.city_plan.permit_revision()
	_expect(colony.city_plan.request_kind(MeepStructures.Kind.TOWNHOUSE),
		"housing demand activates a prepared dormant district")
	colony.call("_apply_city_plan_masks")
	var district_target := colony.city_plan.target_radius()
	var growth_seconds := maxf(
		colony.grid.cell_size / maxf(automatic_rate, 0.0001), 10.0)
	var grown_radius := minf(
		starting_radius + automatic_rate * growth_seconds, district_target)
	colony.set_performance_profiling(true)
	var growth_started := Time.get_ticks_usec()
	colony.call("_simulate_border_growth", growth_seconds)
	var growth_ms := float(Time.get_ticks_usec() - growth_started) / 1000.0
	var growth_profile := colony.performance_profile()
	colony.set_performance_profiling(false)
	var reference_claim := MeepClaim.new()
	var rivals := colony._claim_rival_state()
	reference_claim.bind_permit_mask(colony.city_plan.permit_mask(),
		colony.city_plan.permit_revision())
	reference_claim.build(colony.grid, Vector2.ZERO, grown_radius,
		colony.city_upgrade_built(MeepColony.CityPurchase.COASTS),
		rivals["centres"], rivals["rival_wins_ties"], false)
	var growth_report := colony.report()
	_expect(is_equal_approx(colony.claim_radius, grown_radius)
		and is_equal_approx(colony.claim.radius, grown_radius)
		and colony.claim.count >= starting_cells
		and colony.tier == starting_tier
		and int(growth_report.get("claimed_cells", 0)) == colony.claim.count
		and is_equal_approx(float(growth_report.get(
			"expansion_rate", 0.0)), automatic_rate),
		"the automatic border grows continuously toward its demanded district")
	_expect(colony.claim._claimed == reference_claim._claimed,
		"district-shaped incremental growth is cell-exact with a complete flood")
	print("meep_test: incremental border band took %.2f ms — %s"
		% [growth_ms, growth_profile])
	_expect(growth_ms < 75.0,
		"one district activation stays below the 75 ms spike threshold")
	colony.call("_simulate_border_growth", 10000.0)
	_expect(is_equal_approx(
			colony.claim_radius, district_target)
		and is_equal_approx(
			colony.claim.radius, district_target)
		and colony.tier == starting_tier
		and colony.city_plan.requested_district < 0,
		"demand stops border growth at the prepared district instead of filling a circle")
	var radial_claim := MeepClaim.new()
	radial_claim.build(colony.grid, Vector2.ZERO, district_target,
		colony.city_upgrade_built(MeepColony.CityPurchase.COASTS),
		rivals["centres"], rivals["rival_wins_ties"], false)
	_expect(colony.claim.count < radial_claim.count
		and colony.city_plan.active_districts > 1
		and colony.city_plan.permit_revision() > plan_revision,
		"the activated district adds a shaped lobe rather than another radial ring")

	_expect(colony.city_upgrade_built(MeepColony.CityPurchase.BRIDGES)
		or colony.try_city_purchase(MeepColony.CityPurchase.BRIDGES),
		"the landing city owns Bridges before testing its continuous frontier")
	# Isolate the physical-surface contract from the district-direction test above.
	colony.claim.bind_permit_mask(PackedByteArray(),
		colony.city_plan.permit_revision() + 1000)
	colony.claim.build(colony.grid, Vector2.ZERO,
		MeepColony.MAX_CLAIM_RADIUS)
	var crossing := _outer_landing_bridge_candidate(colony)
	var crossed := false
	if not crossing.is_empty():
		var bridge_cells: PackedInt32Array = crossing["cells"]
		var bridge_heights: PackedFloat32Array = crossing["heights"]
		var surface_kind := int(crossing["surface_kind"])
		var bridge := colony.roads.plan(-151, bridge_cells,
			MeepRoads.WidthClass.STREET, surface_kind, bridge_heights)
		colony.roads.complete(bridge)
		var decked := bridge >= 0
		for cell_index in bridge_cells:
			decked = decked and colony.grid.has_walk_surface(
				colony.roads._cell(cell_index))
		colony.claim.build(colony.grid, Vector2.ZERO,
			MeepColony.MAX_CLAIM_RADIUS)
		var endpoint: Vector2i = crossing["endpoint"]
		var beyond: Vector2i = crossing["beyond"]
		crossed = decked \
			and colony.claim.contains_cell(endpoint) \
			and colony.claim.contains_cell(beyond) \
			and float(crossing.get("beyond_radius", 0.0)) > 125.0
	_expect(crossed,
		"Bridges lets a growing border cross the ship-side crevasse and continue beyond")
	colony.claim.bind_permit_mask(colony.city_plan.permit_mask(),
		colony.city_plan.permit_revision())
	colony.claim.build(colony.grid, Vector2.ZERO, colony.claim_radius,
		colony.city_upgrade_built(MeepColony.CityPurchase.COASTS),
		rivals["centres"], rivals["rival_wins_ties"], false)

	_expect(colony.development_inner_radius_for_tier(1) == 100.0
		and colony.development_inner_radius_for_tier(2) == 125.0
		and colony.development_inner_radius_for_tier(3) == 150.0
		and colony.development_inner_radius_for_tier(4) == 130.0,
		"megacity infill reuses outer civic gaps without controlling the boundary")
	var compact_city := MeepCityLedger.new()
	compact_city.site_id = &"growth_ledger"
	compact_city.alive = 6
	compact_city.claim_radius = 70.0
	compact_city.resources = 100.0
	compact_city.committed = 90.0
	compact_city.physical = {"progression": {
		"claim_radius": compact_city.claim_radius,
		"resources": compact_city.resources,
		"committed": compact_city.committed,
	}}
	compact_city.advance(10.0)
	var compact_state := compact_city.to_dictionary()
	var restored_compact := MeepCityLedger.from_dictionary(compact_state)
	_expect(is_equal_approx(compact_city.claim_radius, 70.0)
		and is_equal_approx(float((compact_city.physical["progression"]
			as Dictionary).get("claim_radius", 0.0)), 70.0)
		and is_equal_approx(restored_compact.claim_radius, 70.0)
		and is_equal_approx(compact_city.committed, 90.0)
		and compact_city.resources >= compact_city.committed
		and is_equal_approx(restored_compact.committed, 90.0),
		"pre-blueprint ledgers freeze reach without spending commissions until migration")

	var plan_state := colony.city_plan.snapshot()
	var planned_lots: PackedInt32Array = plan_state.get(
		"lots", PackedInt32Array())
	var planned_kinds: Dictionary = {}
	for lot in planned_lots.size() / MeepCityPlan.LOT_STRIDE:
		planned_kinds[planned_lots[
			lot * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_KIND]] = true
	_expect(planned_kinds.has(MeepStructures.Kind.TOWNHOUSE)
		and planned_kinds.has(MeepStructures.Kind.MID_RISE)
		and planned_kinds.has(MeepStructures.Kind.SKYSCRAPER)
		and planned_kinds.has(MeepStructures.Kind.MEGA_SKYSCRAPER)
		and planned_kinds.has(MeepStructures.Kind.ARCLOGY),
		"the founding blueprint reserves every dense and megacity form")

	var growth_state := colony.city_progression_snapshot()
	_expect(not growth_state.has("expansion_rate_level")
		and is_equal_approx(float(growth_state.get(
			"claim_radius", 0.0)), district_target)
		and growth_state.get("city_plan", {}) is Dictionary,
		"live and late-join progression carries shaped reach and its city plan")

	colony.apply_city_progression(before)
	colony.structures.apply_snapshot(old_structures)
	colony.structures.apply_form_snapshot(old_forms, old_upgrades)
	colony.roads.apply_snapshot(old_roads)
	colony.roads.apply_width_snapshot(old_widths)
	colony.roads.apply_surface_snapshot(old_surfaces)
	colony.apply_deed_snapshot(old_deeds)
	colony.apply_tier_zero_space_exhausted(was_space_full)
	colony.apply_tier_zero_complete(was_complete)
	colony._plan_left = old_plan_left
	colony.reground()
	for _frame in 1200:
		if colony.ground_ready() \
				and is_equal_approx(colony.claim.radius,
					float(before.get("claim_radius", 100.0))):
			break
		await get_tree().physics_frame


func _outer_landing_bridge_candidate(colony: MeepColony) -> Dictionary:
	var tier_one_cap := MeepColony.MAX_CLAIM_RADIUS
	var candidate: Dictionary = colony.roads.call(
		"_frontier_bridge_candidate")
	if candidate.is_empty():
		return {}
	var endpoint: Vector2i = candidate["endpoint"]
	var beyond := _far_side_buffer_cell(colony, endpoint, tier_one_cap)
	candidate["beyond"] = beyond
	candidate["beyond_radius"] = colony.grid.centre_of(beyond).length()
	return candidate


func _far_side_buffer_cell(colony: MeepColony, from: Vector2i,
		tier_one_cap: float) -> Vector2i:
	var visited := PackedByteArray()
	visited.resize(colony.grid.cells * colony.grid.cells)
	var queue := PackedInt32Array([colony.grid.index(from)])
	visited[queue[0]] = 1
	var head := 0
	var furthest := from
	var furthest_distance := colony.grid.centre_of(from).length()
	while head < queue.size():
		var index := queue[head]
		head += 1
		var cell := Vector2i(
			index % colony.grid.cells, index / colony.grid.cells)
		var distance := colony.grid.centre_of(cell).length()
		if distance > furthest_distance and distance <= tier_one_cap:
			furthest = cell
			furthest_distance = distance
		for step: Vector2i in [
				Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP,
			]:
			var neighbour := cell + step
			if not colony.grid.inside(neighbour):
				continue
			var neighbour_index := colony.grid.index(neighbour)
			if visited[neighbour_index] != 0 \
					or colony.grid.terrain_at(neighbour) \
						!= MeepGrid.Terrain.PASSABLE \
					or colony.grid.centre_of(neighbour).length() \
						> tier_one_cap:
				continue
			visited[neighbour_index] = 1
			queue.push_back(neighbour_index)
	return furthest


func _check_commission_construction(colony: MeepColony) -> void:
	var missing := maxi(
		MeepColony.COMMISSION_POPULATION - colony.alive_count(), 0)
	if missing > 0:
		colony.release_settlers(missing, 31337)
	var compact := MeepCityLedger.new()
	compact.absorb(colony)
	var compact_copy := MeepCityLedger.from_dictionary(compact.to_dictionary())
	var tracked := 0
	while tracked < colony._state.size() \
			and not colony._active_resident(tracked):
		tracked += 1
	_expect(tracked < colony._local.size()
		and compact_copy.resident_places.size() > tracked
		and MeepColony.unpack_resident_place(
			compact_copy.resident_places[tracked]).distance_to(
				colony._local[tracked]) <= 0.11,
		"ledger round trips preserve each Meep's last local position")

	var damaged := MeepCityLedger.new()
	damaged.structures = PackedInt32Array([
		MeepStructures.Kind.CLONER, 0, 0,
	])
	damaged.physical = {
		"progression": {
			"built_flags":
				(1 << MeepColony.CityPurchase.HAT_HOUSE)
				| (1 << MeepColony.CityPurchase.FOURTH_CLONER),
		},
	}
	damaged.repair_commissioned_owed()
	_expect(damaged.structures_owed[MeepStructures.Kind.HAT_HOUSE] == 1
		and damaged.structures_owed[MeepStructures.Kind.CLONER] == 3,
		"completed purchase flags repair missing commissioned buildings on return")
	var registry := colony.get_parent() as MeepColonies
	var owed := PackedInt32Array()
	owed.resize(MeepStructures.Kind.size())
	owed[MeepStructures.Kind.TOWNHOUSE] = 1
	colony.structures._exhausted[MeepStructures.Kind.TOWNHOUSE] = true
	registry._replaying[colony.site_id] = owed
	registry.call("_advance_replays", 0.0)
	var retained: PackedInt32Array = registry._replaying[colony.site_id]
	_expect(retained[MeepStructures.Kind.TOWNHOUSE] == 1,
		"offscreen completed work waits while its planned district is still dormant")
	registry._replaying.erase(colony.site_id)
	registry._replay_wait.erase(colony.site_id)
	colony.structures.clear_exhaustion()
	colony.resources = MeepColony.SPECIALTY_HOUSE_COST
	colony.committed = 0.0
	_expect(colony.try_city_purchase(MeepColony.CityPurchase.HAT_HOUSE),
		"a thirty-two-settler city accepts a physical Hat House commission")
	colony.structures._exhausted[MeepStructures.Kind.HAT_HOUSE] = true
	colony.call("_plan_commissioned")
	_expect(colony.city_upgrade_requested(
			MeepColony.CityPurchase.HAT_HOUSE)
		and is_equal_approx(
			colony.committed, MeepColony.SPECIALTY_HOUSE_COST)
		and not colony._commission_waiting_for_space
		and colony.commissioned_work_blocks_routine()
		and not colony.ready_for_distillation(),
		"a reserved civic lot bypasses a stale whole-claim exhaustion result")
	colony.structures.clear_exhaustion()
	colony.call("_plan_commissioned")
	var pending_hat := colony.structures.nearest(
		MeepStructures.Kind.HAT_HOUSE, Vector2.ZERO, false)
	var restored_hat_job := colony.structures.at(pending_hat).job \
		if pending_hat >= 0 else 0
	if pending_hat >= 0:
		colony.structures.at(pending_hat).job = 0
	colony.reconnect_restored_tasks()
	_expect(pending_hat >= 0 and restored_hat_job > 0
		and colony.structures.at(pending_hat).job == restored_hat_job,
		"restoring separate structure and task sidecars reconnects a commission crew")
	for _step in 180:
		colony.step_simulation(0.5)
		if colony.city_upgrade_built(MeepColony.CityPurchase.HAT_HOUSE):
			break
	var structure := colony.structures.nearest(
		MeepStructures.Kind.HAT_HOUSE, Vector2.ZERO, true)
	_expect(structure >= 0
		and colony.city_upgrade_built(MeepColony.CityPurchase.HAT_HOUSE)
		and not colony.city_upgrade_requested(
			MeepColony.CityPurchase.HAT_HOUSE)
		and is_equal_approx(colony.committed, 0.0),
		"commissioned work is pegged out, prioritized, built, and paid by Meeps")
	if structure >= 0:
		var proxy := MeepStructureProxy.new()
		proxy.configure(colony)
		proxy.set_lent(structure)
		_expect(proxy.interact_prompt() == "Open Hat House"
			and colony.specialty_interaction_valid(
				structure, MeepStructures.Kind.HAT_HOUSE,
				colony.structures.world_centre(structure), 0.1),
			"a completed specialty proxy advertises its local overlay and validates")
		proxy.free()

	colony.resources = MeepColony.SPECIALTY_HOUSE_COST + 5000.0
	_expect(colony.try_city_purchase(
		MeepColony.CityPurchase.ABILITIES_HOUSE),
		"a mature city accepts a physical Abilities House commission")
	for _step in 300:
		colony.step_simulation(0.5)
		if colony.city_upgrade_built(
				MeepColony.CityPurchase.ABILITIES_HOUSE):
			break
	var abilities := colony.abilities_house_index()
	var base_height := colony.structures.display_height(abilities) \
		if abilities >= 0 else 0.0
	_expect(abilities >= 0
		and colony.city_upgrade_built(
			MeepColony.CityPurchase.ABILITIES_HOUSE)
		and not colony.abilities_house_stats_unlocked()
		and is_equal_approx(base_height,
			MeepStructures.plan_of(
				MeepStructures.Kind.ABILITIES_HOUSE).size.y),
		"the completed base Abilities House begins at its original height")

	colony.resources = MeepColony.ABILITIES_HOUSE_TOWER_COST + 5000.0
	_expect(colony.try_city_purchase(
		MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER),
		"the completed house unlocks its commissioned tower upgrade")
	colony.call("_plan_commissioned")
	var restored_tower_job := colony.structures.at(abilities).job
	colony.structures.at(abilities).job = 0
	colony.reconnect_restored_tasks()
	_expect(restored_tower_job > 0
		and colony.structures.at(abilities).job == restored_tower_job,
		"restoring a commissioned tower reconnects its upgrade job without duplication")
	for _step in 300:
		colony.step_simulation(0.5)
		if colony.abilities_house_stats_unlocked():
			break
	var tower_report := colony.report()
	_expect(colony.abilities_house_stats_unlocked()
		and colony.structures.at(abilities).completed_floors == 2
		and is_equal_approx(
			colony.structures.display_height(abilities), base_height * 2.0)
		and bool(tower_report.get("abilities_house_upgraded", false))
		and not colony.try_city_purchase(
			MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER),
		"Meeps double the existing house in height and permanently unlock stat training")
	print("meep_test: commission debug %s" % [{
		"abilities": abilities,
		"unlocked": colony.abilities_house_stats_unlocked(),
		"flags": colony.built_flags,
		"requested": colony.requested_flags,
	}])


func _check_second_cloner(colony: MeepColony) -> void:
	var clone_city := MeepColony.new()
	clone_city.stats = MeepStats.new()
	add_child(clone_city)
	var clone_grid := _surface_test_grid(colony.site)
	var clone_claim := MeepClaim.new()
	clone_claim.build(clone_grid, Vector2.ZERO, 40.0)
	clone_city.site = colony.site
	clone_city.grid = clone_grid
	clone_city.claim = clone_claim
	clone_city.claim_radius = 40.0
	clone_city._ground_ready = true
	var clone_roads := MeepRoads.new()
	clone_city.add_child(clone_roads)
	clone_roads.configure(
		colony.site, clone_grid, clone_claim, null, null, 83)
	clone_city.roads = clone_roads
	var clone_structures := MeepStructures.new()
	clone_city.add_child(clone_structures)
	clone_structures.configure(
		colony.site, clone_grid, clone_claim, null, null,
		clone_city, clone_roads)
	clone_city.structures = clone_structures

	var first_cloner := clone_structures.place_at(
		MeepStructures.Kind.CLONER,
		clone_claim.origin + Vector2i(-10, -1))
	var housing := clone_structures.place_at(
		MeepStructures.Kind.SKYSCRAPER,
		clone_claim.origin + Vector2i(4, -4))
	for structure in [first_cloner, housing]:
		if structure >= 0:
			clone_structures.set_progress(structure, 1.0)
			clone_structures.block(structure)
	for row in MeepColony.COMMISSION_POPULATION:
		clone_city._add(Vector2.ZERO, 8100 + row)

	clone_city.resources = MeepColony.SECOND_CLONER_COST
	var available_offer := clone_city.city_purchase_offers().get(
		"second_cloner", {}) as Dictionary
	var bought := clone_city.try_city_purchase(
		MeepColony.CityPurchase.SECOND_CLONER)
	clone_city._plan_commissioned()
	var second_cloner := clone_city.second_cloner_index(false)
	var second_entry := clone_structures.at(second_cloner)
	var build_job := clone_city.tasks.job(
		second_entry.job if second_entry != null else 0)
	_expect(first_cloner >= 0 and housing >= 0
		and String(available_offer.get("status", "")) == "available"
		and bought and second_cloner >= 0 and second_cloner != first_cloner
		and build_job != null
		and is_equal_approx(
			build_job.reserved, MeepColony.SECOND_CLONER_COST),
		"the city upgrade commissions a distinct second physical Meep Cloner")
	if build_job != null:
		clone_city.tasks.claim(build_job.id)
		clone_city._job[0] = build_job.id
		clone_city._state[0] = MeepColony.State.WORK
		clone_city._build(0, build_job,
			MeepStructures.plan_of(MeepStructures.Kind.CLONER).work + 1.0)
	_expect(clone_city.second_cloner_index() == second_cloner
		and clone_city.city_upgrade_built(
			MeepColony.CityPurchase.SECOND_CLONER)
		and clone_structures.count_of(
			MeepStructures.Kind.CLONER, true) == 2
		and is_zero_approx(clone_city.resources)
		and is_zero_approx(clone_city.committed),
		"the second cloner is built, paid once, and retained as permanent city progress")

	var extra_cloners: Array[int] = [first_cloner, second_cloner]
	var later_purchases: Array[int] = [
		MeepColony.CityPurchase.THIRD_CLONER,
		MeepColony.CityPurchase.FOURTH_CLONER,
	]
	var later_costs: Array[float] = [
		MeepColony.THIRD_CLONER_COST,
		MeepColony.FOURTH_CLONER_COST,
	]
	var later_built := true
	for slot in later_purchases.size():
		var purchase_id := later_purchases[slot]
		var ordinal := slot + 2
		var offer_key := "third_cloner" if ordinal == 2 else "fourth_cloner"
		var offer := clone_city.city_purchase_offers().get(
			offer_key, {}) as Dictionary
		clone_city.resources = later_costs[slot]
		clone_city.committed = 0.0
		var accepted := String(offer.get("status", "")) == "available" \
			and clone_city.try_city_purchase(purchase_id)
		clone_city._plan_commissioned()
		var structure := clone_city.cloner_index(ordinal, false)
		var structure_entry := clone_structures.at(structure)
		var job := clone_city.tasks.job(
			structure_entry.job if structure_entry != null else 0)
		later_built = later_built and accepted and structure >= 0 \
			and job != null and is_equal_approx(
				job.reserved if job != null else 0.0, later_costs[slot])
		if job != null:
			clone_city.tasks.claim(job.id)
			clone_city._job[0] = job.id
			clone_city._state[0] = MeepColony.State.WORK
			clone_city._build(0, job,
				MeepStructures.plan_of(MeepStructures.Kind.CLONER).work + 1.0)
		later_built = later_built \
			and clone_city.cloner_index(ordinal) == structure \
			and clone_city.city_upgrade_built(purchase_id) \
			and is_zero_approx(clone_city.resources) \
			and is_zero_approx(clone_city.committed)
		extra_cloners.push_back(structure)
	_expect(later_built and extra_cloners.size() == 4
		and clone_structures.count_of(
			MeepStructures.Kind.CLONER, true) == 4,
		"third and fourth purchases build distinct permanent cloners in sequence")

	clone_city.resources = MeepColony.CLONE_COST * 40.0
	clone_city._plan_cloning()
	var clone_jobs := clone_city.tasks.all_of(MeepTasks.Kind.CLONE)
	var first_job: MeepTasks.Job = null
	var second_job: MeepTasks.Job = null
	for job in clone_jobs:
		if job.subject == first_cloner:
			first_job = job
		elif job.subject == second_cloner:
			second_job = job
	if first_job != null and second_job != null:
		clone_city.tasks.claim(first_job.id)
		clone_city._job[0] = first_job.id
		clone_city._state[0] = MeepColony.State.WORK
		clone_city._timer[0] = MeepColony.QUEUE_PATIENCE
		clone_city._queue_at_cloner(0, first_job, 0.0)
		clone_city.tasks.claim(second_job.id)
		clone_city._job[1] = second_job.id
		clone_city._state[1] = MeepColony.State.WORK
		clone_city._timer[1] = MeepColony.QUEUE_PATIENCE
		clone_city._queue_at_cloner(1, second_job, 0.0)
	var entered_both := first_job != null and second_job != null \
		and clone_city._state[0] == MeepColony.State.INSIDE \
		and clone_city._state[1] == MeepColony.State.INSIDE \
		and clone_structures.at(first_cloner).inside == 1 \
		and clone_structures.at(second_cloner).inside == 1
	var before_clones := clone_city.alive_count()
	if entered_both:
		clone_city._incubate(0, MeepColony.CLONE_SECONDS + 0.01)
		clone_city._incubate(1, MeepColony.CLONE_SECONDS + 0.01)
	_expect(clone_jobs.size() == 4 and entered_both
		and clone_city.alive_count() == before_clones + 2,
		"all four completed cloners own queues and can produce Meeps in parallel")

	var clone_limit := mini(
		clone_city.housing_capacity(), clone_city.population_ceiling())
	while clone_city.alive_count() < clone_limit - 1:
		clone_city._add(Vector2.ZERO, 9100 + clone_city.count())
	clone_city._plan_cloning()
	if first_job != null and second_job != null:
		clone_city.tasks.claim(first_job.id)
		clone_city._job[2] = first_job.id
		clone_city._state[2] = MeepColony.State.WORK
		clone_city._timer[2] = MeepColony.QUEUE_PATIENCE
		clone_city._queue_at_cloner(2, first_job, 0.0)
		clone_city.tasks.claim(second_job.id)
		clone_city._job[3] = second_job.id
		clone_city._state[3] = MeepColony.State.WORK
		clone_city._timer[3] = MeepColony.QUEUE_PATIENCE
		clone_city._queue_at_cloner(3, second_job, 0.0)
	_expect(clone_city._cloners_inside() == 1
		and clone_city._state[3] != MeepColony.State.INSIDE,
		"parallel cloners share one projected-population guard and cannot exceed housing")

	var one_machine := MeepCityLedger.new()
	one_machine.alive = 20
	one_machine.housing_capacity = 30
	one_machine.resources = 120.0
	one_machine.compact_roles = PackedInt32Array([
		0, 0, 20, 0])
	one_machine._cloners = 1
	one_machine._clone(0.2)
	var two_machines := MeepCityLedger.new()
	two_machines.alive = 20
	two_machines.housing_capacity = 30
	two_machines.resources = 120.0
	two_machines.compact_roles = PackedInt32Array([
		0, 0, 20, 0])
	two_machines._cloners = 2
	two_machines._clone(0.2)
	var four_machines := MeepCityLedger.new()
	four_machines.alive = 20
	four_machines.housing_capacity = 30
	four_machines.resources = 120.0
	four_machines.compact_roles = PackedInt32Array([
		0, 0, 20, 0])
	four_machines._cloners = 4
	four_machines._clone(0.2)
	_expect(one_machine.alive == 21 and two_machines.alive == 22
		and four_machines.alive == 24,
		"unwatched cities preserve the throughput of all four physical cloners")
	clone_city.queue_free()


func _check_biomass_harvester(colony: MeepColony) -> void:
	colony.resources = MeepColony.BIOMASS_HARVESTER_COST
	colony.committed = 0.0
	_expect(colony.try_city_purchase(
		MeepColony.CityPurchase.BIOMASS_HARVESTER),
		"a mature city accepts one physical Biomass Harvester commission")
	for _step in 2000:
		colony.step_simulation(0.5)
		if colony.biomass_harvester_index() >= 0:
			break
	var structure := colony.biomass_harvester_index()
	if structure < 0:
		print("meep_test: harvester debug ", {
			"next_commission": colony._next_commission_purchase(),
			"waiting_for_space": colony._commission_waiting_for_space,
			"claim_radius": colony.claim_radius,
			"target_radius": colony.city_plan.target_radius(),
			"active_districts": colony.city_plan.active_districts,
			"lots": colony.city_plan.lot_summary(),
			"availability": colony.city_plan.availability_summary(
				MeepStructures.Kind.BIOMASS_HARVESTER),
			"structures": colony.structures.count(),
			"build_jobs": colony.tasks.all_of(MeepTasks.Kind.BUILD).size(),
		})
	_expect(structure >= 0
		and colony.city_upgrade_built(
			MeepColony.CityPurchase.BIOMASS_HARVESTER)
		and colony.structures.count_of(
			MeepStructures.Kind.BIOMASS_HARVESTER, true) == 1,
		"the commissioned pink 9x9 project activates only after physical completion")
	if structure < 0:
		return
	var proxy := MeepStructureProxy.new()
	proxy.configure(colony)
	proxy.set_lent(structure)
	var centre := colony.structures.world_centre(structure)
	_expect(proxy.interact_prompt() == "Open Biomass Harvester"
		and colony.specialty_interaction_valid(structure,
			MeepStructures.Kind.BIOMASS_HARVESTER, centre, 0.1)
		and not colony.specialty_interaction_valid(structure,
			MeepStructures.Kind.BIOMASS_HARVESTER,
			centre + Vector3.UP * 50.0, GameWorld.SPECIALTY_HOUSE_MAX_DISTANCE),
		"the completed proxy opens its overlay and rejects distant requests")
	proxy.free()

	var timber_before := colony.standing_timber()
	var population_before := colony.alive_count()
	colony.resources = 0.0
	colony.committed = 0.0
	colony.harvester_lifetime = 0.0
	var exact := float(colony.call("_simulate_harvester", 4.0))
	_expect(is_equal_approx(exact, 4.0)
		and is_equal_approx(colony.resources, 4.0)
		and is_equal_approx(colony.harvester_lifetime, 4.0)
		and colony.standing_timber() == timber_before
		and colony.alive_count() == population_before,
		"base passive output is exactly one per second without flora or workers")
	colony.resources = 0.0
	colony.harvester_lifetime = 0.0
	var bounded := float(colony.call("_simulate_harvester", 1000.0))
	_expect(is_equal_approx(bounded,
		MeepColony.MAX_HARVEST_ELAPSED * MeepColony.HARVEST_BASE_RATE),
		"one stalled elapsed interval is bounded instead of minting offline output")

	colony.resources = MeepColony.HARVEST_RATE_COSTS[0]
	colony.committed = 1.0
	_expect(not colony.try_city_purchase(
		MeepColony.CityPurchase.HARVEST_RATE_1),
		"harvester upgrades cannot spend city biomass committed to other work")
	colony.committed = 0.0
	_expect(not colony.try_city_purchase(
		MeepColony.CityPurchase.HARVEST_RATE_2),
		"harvester levels cannot be bought out of order")
	for level in MeepColony.MAX_HARVEST_RATE_LEVEL:
		var purchase_id := MeepColony.CityPurchase.HARVEST_RATE_1 + level
		var cost := float(MeepColony.HARVEST_RATE_COSTS[level])
		colony.resources = cost
		colony.committed = 0.0
		var bought := colony.try_city_purchase(purchase_id)
		var after := colony.resources
		var replayed := colony.try_city_purchase(purchase_id)
		_expect(bought and not replayed and is_equal_approx(after, 0.0)
			and is_equal_approx(colony.resources, after)
			and colony.harvester_rate_level == level + 1,
			"harvester rate level %d costs exactly %d and replays idempotently" % [
				level + 1, roundi(cost)])
	_expect(is_equal_approx(colony.harvester_rate(), 3.5)
		and String(colony.harvester_upgrade_offer().get(
			"status", "")) == "maxed",
		"five permanent levels cap the city's passive rate at 3.5 per second")

	colony.resources = 123.25
	colony.harvester_lifetime = 456.5
	var live_state := colony.city_progression_snapshot().duplicate(true)
	colony.resources = 0.0
	colony.harvester_rate_level = 0
	colony.harvester_lifetime = 0.0
	colony.apply_city_progression(live_state)
	var report := colony.report()
	_expect(is_equal_approx(colony.resources, 123.25)
		and colony.harvester_rate_level == 5
		and is_equal_approx(colony.harvester_lifetime, 456.5)
		and is_equal_approx(float(report.get("harvester_rate", 0.0)), 3.5)
		and report.get("harvester_upgrade", {}) is Dictionary,
		"live progression round-trips exact bank, level, rate, lifetime, and offer")
	var child := MeepColony.new()
	_expect(child.harvester_rate_level == 0
		and is_zero_approx(child.harvester_lifetime)
		and is_zero_approx(child.resources),
		"a separate child colony starts with an independent harvester bank and state")
	child.free()


func _check_menu(colony: MeepColony) -> void:
	var menu := CityMenu.new()
	var carried := [0.0]
	var displayed_bank := [0.0]
	var speed_status := ["available"]
	menu.configure(func() -> Dictionary:
		var report := colony.report()
		report["carried_biomass"] = carried[0]
		report["resources"] = displayed_bank[0]
		var offers := report.get("purchase_offers", {}) as Dictionary
		offers["build_speed"] = {
			"purchase_id": MeepColony.CityPurchase.BUILD_SPEED_1,
			"cost": 80.0,
			"status": speed_status[0],
			"enabled": speed_status[0] == "available",
			"shortfall": 0.0,
			"value": "BUILT" if speed_status[0] == "built" \
				else "LEVEL 0/5  (+0%)",
		}
		report["purchase_offers"] = offers
		return report)
	add_child(menu)
	await get_tree().process_frame
	_expect(menu.row_text("tier") == "TIER 0",
		"the city panel identifies growing settlement space as Tier 0")
	_expect(menu.row_text("settlers") == str(colony.alive_count()),
		"the city panel shows the live settler count")
	_expect(menu.row_text("resources") == "0",
		"the city panel shows the resource bank")
	_expect((menu.row_text("claim_radius").contains("ON DEMAND")
			or menu.row_text("claim_radius").contains("M/S"))
		and menu.row_text("city_style").contains("DISTRICTS")
		and menu.purchase_button("expand_area") == null
		and menu.purchase_button("second_cloner") != null
		and menu.purchase_button("third_cloner") != null
		and menu.purchase_button("fourth_cloner") != null,
		"the city panel shows automatic demand growth and all extra-cloner upgrades")
	_expect(menu.row_text("carried_biomass") == "0",
		"the city panel shows the player's carried biomass")
	_expect(menu.row_text("roads") == "0 m",
		"the city panel shows how much road has been laid")
	var tabs := menu.tab_container()
	_expect(tabs != null and tabs.get_tab_count() == 2
		and tabs.get_tab_title(0) == "CONTROL"
		and tabs.get_tab_title(1) == "MEEPS"
		and menu.find_child("MeepRosterScroll", true, false) is ScrollContainer,
		"city control has a dedicated second scrolling Meeps tab")
	var roster_grid := menu.find_child(
		"MeepRosterGrid", true, false) as MeepRosterGrid
	var alive_toggle := menu.find_child(
		"AliveMeepsToggle", true, false) as Button
	var dead_toggle := menu.find_child(
		"DeadMeepsToggle", true, false) as Button
	_expect(roster_grid != null and MeepRosterGrid.COLUMNS == 3
		and roster_grid.get_child_count() == 0
		and roster_grid.row_count() == colony.alive_count()
		and alive_toggle != null and alive_toggle.text.contains(
			str(colony.alive_count()))
		and dead_toggle != null,
		"the Meep tab uses one childless custom canvas with exactly three tiles per row")
	if roster_grid != null:
		var stable_revision := roster_grid.render_revision()
		roster_grid.set_rows(colony.meep_roster().filter(
			func(row: Dictionary) -> bool:
				return String(row.get("status", "")) == "alive"))
		_expect(roster_grid.render_revision() == stable_revision,
			"unchanged roster polling reuses cached card signatures")
	if dead_toggle != null:
		dead_toggle.pressed.emit()
	_expect(roster_grid != null and roster_grid.row_count()
			== colony.count() - colony.alive_count() - 1
		and dead_toggle != null and dead_toggle.button_pressed,
		"the segmented DEAD toggle isolates permanent memorial tiles and their count")
	if alive_toggle != null:
		alive_toggle.pressed.emit()
	var scale_grid := MeepRosterGrid.new()
	var fixture: Array[Dictionary] = []
	for index in MeepColony.MAX_CITY_POPULATION:
		fixture.push_back({
			"name": "Scale Meep %d" % index,
			"status": "alive",
			"type": "Builder",
			"health": 24.0,
			"maximum_health": 24.0,
			"tile_stats": {
				"TYPE": "Builder",
				"HEALTH": "24 / 24",
				"MOOD": "Ready",
			},
		})
	scale_grid.set_rows(fixture)
	_expect(scale_grid.row_count() == MeepColony.MAX_CITY_POPULATION
		and scale_grid.visual_row_count() == ceili(
			float(MeepColony.MAX_CITY_POPULATION)
			/ float(MeepRosterGrid.COLUMNS))
		and scale_grid.get_child_count() == 0,
		"a 12,000-Meep roster remains one virtualized canvas with extensible stat rows")
	scale_grid.free()
	_expect(menu.meep_row_text(1).contains(colony.meep_name(1))
		and menu.meep_row_text(1).contains("AGE")
		and menu.meep_row_text(1).contains("HP")
		and menu.meep_row_text(1).contains("SIBLING"),
		"the living roster shows each Meep's name, age, health, activity, and family")
	_expect(menu.meep_row_text(0).contains("DIED")
		and menu.meep_row_text(0).contains("ago")
		and menu.meep_row_text(0).contains("Nuke"),
		"the memorial shows how recently and how each dead Meep died")
	var button := menu.release_button()
	_expect(button != null and button.disabled,
		"the release button reports the settled state rather than asking again")
	var deposited := [0.0]
	menu.deposit_biomass_requested.connect(
		func(amount: float) -> void: deposited[0] = amount)
	var granted := [false]
	menu.add_100_biomass_requested.connect(
		func() -> void:
			granted[0] = true
			displayed_bank[0] = 100.0)
	var quick_deposit := menu.deposit_100_button()
	_expect(quick_deposit != null and not quick_deposit.disabled,
		"the fixed +100 city button stays enabled with no carried biomass")
	quick_deposit.pressed.emit()
	_expect(bool(granted[0]) and is_equal_approx(float(deposited[0]), 0.0),
		"the +100 action requests a city grant instead of a player transfer")
	_expect(menu.row_text("resources") == "100",
		"the city panel refreshes its report immediately after a button action")
	carried[0] = 237.0
	menu.call("_refresh")
	var deposit := menu.deposit_button()
	_expect(deposit != null and not deposit.disabled,
		"a founded city accepts carried biomass")
	deposit.pressed.emit()
	_expect(is_equal_approx(float(deposited[0]), 237.0),
		"the add-all city deposit asks for the whole displayed amount")
	var purchased := [-1]
	menu.city_purchase_requested.connect(
		func(purchase_id: int) -> void:
			purchased[0] = purchase_id
			speed_status[0] = "built")
	var speed_button := menu.purchase_button("build_speed")
	_expect(speed_button != null and not speed_button.disabled,
		"the scrollable city controls enable an affordable host offer")
	var tower_button := menu.purchase_button("abilities_house_tower")
	_expect(tower_button != null and tower_button.disabled
		and tower_button.text == "PURCHASED",
		"the city controls report the completed Abilities House tower")
	speed_button.pressed.emit()
	_expect(int(purchased[0]) == MeepColony.CityPurchase.BUILD_SPEED_1,
		"the panel sends the exact purchase ID, never its price")
	_expect(speed_button.disabled and speed_button.text == "PURCHASED",
		"purchase controls redraw their authoritative result on the same press")
	_expect(menu.find_child("CityControlsScroll", true, false) \
		is ScrollContainer,
		"city controls scroll without pushing the close action off-screen")
	var closed := [false]
	menu.closed.connect(func() -> void: closed[0] = true)
	menu.close()
	_expect(bool(closed[0]), "the panel raises its own close")
	await get_tree().process_frame


func _check_full_menu(colony: MeepColony) -> void:
	var menu := CityMenu.new()
	menu.configure(func() -> Dictionary: return colony.report())
	add_child(menu)
	await get_tree().process_frame
	_expect(colony.tier_zero_full() and colony.tier == 1
		and menu.row_text("tier") == "TIER 1",
		"completed Tier 0 advances architectural development without moving the border")
	menu.close()
	await get_tree().process_frame


func _check_snapshot(colonies: MeepColonies, colony: MeepColony) -> void:
	var snapshot := colonies.snapshot()
	_expect(snapshot.size() == 1, "the settled site is in the joiner snapshot")
	if snapshot.is_empty():
		return
	var entry := snapshot[0] as Dictionary
	_expect(String(entry.get("site", "")) == String(SITE)
		and int(entry.get("seed", -1)) == colony.founded_seed,
		"the snapshot carries the founding facts and nothing else")
	_expect(not entry.has("meeps"),
		"the Meeps themselves are left to the state packets")
	var identities: Dictionary = entry.get("identities", {})
	_expect(identities.get("ages", PackedFloat64Array()) is PackedFloat64Array
		and (identities.get("ages", PackedFloat64Array())
			as PackedFloat64Array).size() == colony.count()
		and (identities.get("death_causes", PackedStringArray())
			as PackedStringArray).size() == colony.count(),
		"saves and late joins retain every Meep's age and mortality record")
	var progression: Variant = entry.get("progression", {})
	print("meep_test: progression debug %s" % [{
		"build": (progression as Dictionary).get("build_speed_level", -1)
			if progression is Dictionary else -2,
		"expected_build": colony.build_speed_level,
		"committed": (progression as Dictionary).get("committed", -1.0)
			if progression is Dictionary else -2.0,
		"expected_committed": colony.committed,
		"harvest": (progression as Dictionary).get(
			"harvester_rate_level", -1) if progression is Dictionary else -2,
		"expected_harvest": colony.harvester_rate_level,
		"radius": (progression as Dictionary).get("claim_radius", -1.0)
			if progression is Dictionary else -2.0,
		"expected_radius": colony.claim_radius,
		"harvester_lifetime": (progression as Dictionary).get(
			"harvester_lifetime", -1.0) if progression is Dictionary else -2.0,
		"expected_lifetime": colony.harvester_lifetime,
		"flags": (progression as Dictionary).get("built_flags", 0)
			if progression is Dictionary else -2,
	}])
	_expect(progression is Dictionary
		and int((progression as Dictionary).get("build_speed_level", -1))
			== colony.build_speed_level
		and is_equal_approx(float((progression as Dictionary).get(
			"committed", -1.0)), colony.committed)
		and int((progression as Dictionary).get(
			"harvester_rate_level", -1)) == colony.harvester_rate_level
		and not (progression as Dictionary).has("expansion_rate_level")
		and is_equal_approx(float((progression as Dictionary).get(
			"claim_radius", -1.0)), colony.claim_radius)
		and is_equal_approx(float((progression as Dictionary).get(
			"harvester_lifetime", -1.0)), colony.harvester_lifetime)
		and (int((progression as Dictionary).get("built_flags", 0))
			& (1 << MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER)) != 0,
		"late joiners receive purchases, held biomass, and exact harvester state")
	var joiners := MeepColonies.new()
	joiners.name = "LateJoinRoundTrip"
	var planet := colony.get_parent().get_parent() as Planet
	joiners.planet = planet
	planet.add_child(joiners)
	joiners.apply_snapshot(snapshot)
	var joined := joiners.colony(SITE)
	# Freeze only passive production while the joiner's derived ground bake catches
	# up. Otherwise both authoritative fixture colonies accrue on different physics
	# frames and an exact snapshot assertion races by one simulation interval.
	var harvester_flag := 1 << MeepColony.CityPurchase.BIOMASS_HARVESTER
	var source_built_flags := colony.built_flags
	var joined_built_flags := joined.built_flags if joined != null else 0
	colony.built_flags &= ~harvester_flag
	if joined != null:
		joined.built_flags &= ~harvester_flag
	for _frame in 1800:
		if joined != null and joined.ground_ready() \
				and joined._build_task < 0 \
				and not joined._rebuild_after_ground:
			break
		await get_tree().physics_frame
	colony.built_flags = source_built_flags
	if joined != null:
		joined.built_flags = joined_built_flags
	print("meep_test: joined city debug %s" % [{
		"joined": joined != null,
		"harvest_level": joined.harvester_rate_level if joined != null else -1,
		"expected_level": colony.harvester_rate_level,
		"lifetime": joined.harvester_lifetime if joined != null else -1.0,
		"expected_lifetime": colony.harvester_lifetime,
		"resources": joined.resources if joined != null else -1.0,
		"expected_resources": colony.resources,
		"harvesters": joined.structures.count_of(
			MeepStructures.Kind.BIOMASS_HARVESTER, true)
				if joined != null else -1,
		"ability": joined.abilities_house_stats_unlocked()
			if joined != null else false,
	}])
	_expect(joined != null
		and joined.harvester_rate_level == colony.harvester_rate_level
		and is_equal_approx(joined.harvester_lifetime,
			colony.harvester_lifetime)
		and is_equal_approx(joined.resources, colony.resources)
		and joined.structures.count_of(
			MeepStructures.Kind.BIOMASS_HARVESTER, true) == 1
		and joined.abilities_house_stats_unlocked()
		and is_equal_approx(
			joined.structures.display_height(joined.abilities_house_index()),
			colony.structures.display_height(colony.abilities_house_index())),
		"late join restores the physical harvester and doubled Abilities House")
	var source_memorial: Dictionary = {}
	var joined_memorial: Dictionary = {}
	for row_variant: Variant in colony.meep_roster():
		var row := row_variant as Dictionary
		if int(row.get("index", -1)) == 0:
			source_memorial = row
			break
	if joined != null:
		for row_variant: Variant in joined.meep_roster():
			var row := row_variant as Dictionary
			if int(row.get("index", -1)) == 0:
				joined_memorial = row
				break
	_expect(not source_memorial.is_empty() and not joined_memorial.is_empty()
		and is_equal_approx(float(joined_memorial.get("age_seconds", -1.0)),
			float(source_memorial.get("age_seconds", -2.0)))
		and String(joined_memorial.get("death_cause", ""))
			== String(source_memorial.get("death_cause", "")),
		"late join restores the dead Meep's final age and cause of death")
	_expect(joined != null and joined.ground_ready()
		and joined.claim.count > 0
		and int(joined.report().get("wall_segments", 0)) > 0
		and absf(joined.claim.radius - joined.claim_radius)
			< joined.grid.cell_size + 0.001
		and absf(joined.claim_radius - colony.claim_radius)
			< joined.grid.cell_size + 0.001,
		"late join rebuilds the derived land claim and boundary after all sidecars")
	joiners.free()


# --- The town, in the real world ---------------------------------------------

## The half of this that needs the world the game ships.
##
## Everything above runs against a bare planet, which is the right place to check a
## projection and a flood fill. The economy cannot be checked there: what a colony earns
## comes out of the flower trees standing around the landing site, and what it spends it
## on has to fit between them. So this loads `game/world.tscn`, presses the button
## through the same request a player's press goes through, and then runs the town until
## it has cut something down, built a cloner, made a Meep out of it and put up a house —
## or until it is clear that it will not.
##
## Runs headless as well as with a renderer. The captures are the part that needs a
## screen; the milestones are not.
func _town() -> void:
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	var world := WORLD.instantiate() as GameWorld
	add_child(world)
	for _frame in 10:
		await get_tree().process_frame
	var planet := world.find_child("Planet", true, false) as Planet
	var ship := world.find_child("ColonyShip", true, false) as ColonyShip
	var timber := world.find_child("LandingFlowerTrees", true, false)
	var flowers := world.find_child(
		"LandingFlowers", true, false) as GroundCover
	var player := get_tree().get_first_node_in_group("network_players") \
		as OnlinePlayer
	if planet == null or ship == null or player == null or timber == null \
			or flowers == null:
		push_error("meep_test: no world to run a town in")
		return
	# The repeat-purchase assertion deliberately leaves launchers owned. Preserve
	# the real local stack so this fixture cannot erase a developer's purchases.
	var saved_launchers := player.one_time_ability_records("settlement_launcher")
	var saved_ability_items := player.abilities.items()
	var saved_ability_stats := player.ability_stat_progress.duplicate(true)
	player.one_time_abilities.erase("settlement_launcher")
	for slot in player.abilities.size():
		if player.abilities.get_item(slot) == "settlement_launcher":
			player.abilities.set_item(slot, "")
	# This long accelerated fixture measures housing, jobs, and biomass. Incidental
	# fauna combat now has its own real-row integration coverage in _fauna_test;
	# pause it here so one valid quill death cannot weaken the existing exact
	# sibling/home and filled-housing assertions.
	for spawner_variant in world.find_children("*", "FaunaSpawner", true, false):
		var fauna_spawner := spawner_variant as FaunaSpawner
		if fauna_spawner != null:
			fauna_spawner.set_process(false)
	for mob_variant: Variant in get_tree().get_nodes_in_group(&"fauna_mobs"):
		var mob := mob_variant as FaunaMob
		if mob != null and world.is_ancestor_of(mob):
			mob.set_physics_process(false)
	# Stood at the ship rather than at the spawn marker, because the host checks
	# that whoever pressed the button is actually there.
	_stand_facing(planet, player, ship.global_position, 14.0)
	for _frame in TERRAIN_FRAMES:
		await get_tree().process_frame
	seed(FOUNDING_RNG_SEED)
	world.request_release_settlers(1, SITE)
	var colony := world.meep_colonies().colony(SITE)
	if colony == null:
		push_error("meep_test: the world would not found a colony")
		return
	for _frame in 600:
		if colony.ground_ready():
			break
		await get_tree().process_frame
	if not colony.ground_ready():
		push_error("meep_test: the town's ground never finished baking")
		return
	# Adopting the ground starts the timber reading rather than finishing it: one
	# flora field per frame, so that a settled city does not spend a whole frame
	# surveying the planet's plants. The job board is published when the last field
	# is in, which is what the harvest checks below are about.
	for _frame in 600:
		if not colony._reading_timber():
			break
		await get_tree().process_frame

	var baseline_progression := colony.city_progression_snapshot().duplicate(true)
	world.request_add_city_biomass(1, SITE)
	_expect(is_equal_approx(player.biomass(), 0.0)
		and is_equal_approx(colony.resources, 100.0),
		"the host grants exactly 100 city biomass without a carried balance")
	world.request_city_purchase(
		1, SITE, MeepColony.CityPurchase.BUILD_SPEED_1)
	_expect(colony.build_speed_level == 1
		and is_equal_approx(colony.resources, 20.0),
		"a ship-side city purchase is validated and spent by the host")
	world.request_city_purchase(
		1, SITE, MeepColony.CityPurchase.BUILD_SPEED_1)
	_expect(colony.build_speed_level == 1
		and is_equal_approx(colony.resources, 20.0),
		"repeating the same world purchase remains idempotent")
	var donated := player.credit_biomass(25.0, ship.global_position)
	world.request_deposit_biomass(1, SITE, donated)
	_expect(is_equal_approx(player.biomass(), 0.0)
		and is_equal_approx(colony.resources, 45.0),
		"add-all still atomically transfers the player's actual carried biomass")
	player.take_biomass(player.biomass())
	colony.apply_city_progression(baseline_progression)
	# Keep the long economy audit calibrated to an empty-bank colony.
	colony.resources = 0.0
	_check_timber(colony, timber)
	await _live(colony, timber)
	_check_economy(colony, timber)
	_check_identity_and_homes(colony)
	_check_town_ground(colony)
	_check_town_snapshot(world, colony)
	await _check_full_menu(colony)
	# Last, because it works by cutting flora down and everything above it wants the
	# town photographed as the Meeps left it.
	_check_exact_harvest(colony, timber)
	_check_cleared(colony, _built_in(colony))
	_check_exact_meadow_harvest(colony, flowers)
	_check_harvester_request_authority(world, colony, player)
	await _check_settlement_expeditions(world, colony, player)
	await _capture(planet, player, colony)
	await _capture_city_upgrade_showcase(planet, player, colony)
	_check_ability_stat_request_authority(world, colony, player)
	_release_watchers()
	player.one_time_abilities.erase("settlement_launcher")
	player.ability_stat_progress = saved_ability_stats
	player.apply_abilities(saved_ability_items)
	if not saved_launchers.is_empty():
		player.one_time_abilities["settlement_launcher"] = \
			saved_launchers.duplicate(true)
	player.publish_authoritative_progression()
	# Let the queued local save observe the restored record before this world exits.
	await get_tree().process_frame
	await get_tree().process_frame


func _check_harvester_request_authority(world: GameWorld,
		colony: MeepColony, player: OnlinePlayer) -> void:
	colony.resources = MeepColony.BIOMASS_HARVESTER_COST
	colony.committed = 0.0
	if not colony.try_city_purchase(
			MeepColony.CityPurchase.BIOMASS_HARVESTER):
		_expect(false, "the request fixture commissions its physical harvester")
		return
	var structure := colony.structures.place_at(
		MeepStructures.Kind.BIOMASS_HARVESTER,
		colony.claim.origin + Vector2i(24, 24))
	colony.structures.set_progress(structure, 1.0)
	colony.complete_city_purchase(
		MeepColony.CityPurchase.BIOMASS_HARVESTER)
	var centre := colony.structures.world_centre(structure)
	colony.resources = MeepColony.HARVEST_RATE_COSTS[0]
	var before := colony.resources
	player.global_position = centre + centre.normalized() * 50.0
	var distant: Variant = world.call("_server_harvester_upgrade",
		1, SITE, structure, MeepColony.CityPurchase.HARVEST_RATE_1)
	_expect(not bool(distant) and is_equal_approx(colony.resources, before)
		and colony.harvester_rate_level == 0,
		"the host rejects a rate request away from the actual completed machine")
	player.global_position = centre
	var accepted: Variant = world.call("_server_harvester_upgrade",
		1, SITE, structure, MeepColony.CityPurchase.HARVEST_RATE_1)
	var after := colony.resources
	var replayed: Variant = world.call("_server_harvester_upgrade",
		1, SITE, structure, MeepColony.CityPurchase.HARVEST_RATE_1)
	_expect(bool(accepted) and not bool(replayed)
		and colony.harvester_rate_level == 1
		and is_equal_approx(after, 0.0)
		and is_equal_approx(colony.resources, after),
		"the nearby host route validates, spends uncommitted funds, and is idempotent")


func _check_ability_stat_request_authority(world: GameWorld,
		colony: MeepColony, player: OnlinePlayer) -> void:
	var structure := colony.structures.nearest(
		MeepStructures.Kind.ABILITIES_HOUSE, Vector2.ZERO, true)
	if structure < 0:
		structure = colony.structures.place_at(
			MeepStructures.Kind.ABILITIES_HOUSE,
			colony.claim.origin + Vector2i(-36, 30))
		colony.structures.set_progress(structure, 1.0)
	colony.call("_mark_purchase_built",
		MeepColony.CityPurchase.ABILITIES_HOUSE)
	var entry := colony.structures.at(structure)
	entry.completed_floors = 1
	entry.target_floors = 1
	entry.upgrade_progress = 0.0
	colony.built_flags &= ~(
		1 << MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER)
	var centre := colony.structures.world_centre(structure)
	var stood := player.global_position
	player.global_position = centre
	player.ability_stat_progress.erase("starfire")
	var locked: Variant = world.call("_server_ability_stat_upgrade",
		1, SITE, structure, "starfire", "speed")
	var upgraded := colony.structures.begin_vertical_upgrade(structure)
	if upgraded:
		colony.structures.advance_upgrade(
			structure, colony.structures.upgrade_work(structure) + 1.0)
		upgraded = colony.structures.complete_upgrade(structure)
	colony.call("_mark_purchase_built",
		MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER)
	player.global_position = centre + centre.normalized() * 50.0
	var distant: Variant = world.call("_server_ability_stat_upgrade",
		1, SITE, structure, "starfire", "speed")
	player.global_position = centre
	var accepted: Variant = world.call("_server_ability_stat_upgrade",
		1, SITE, structure, "starfire", "speed")
	var level := player.ability_stat_level("starfire", "speed")
	var passed := not bool(locked) and upgraded and not bool(distant) \
		and bool(accepted) and level == 1
	_expect(passed,
		"host stat training requires the tower and the player at its real structure")
	player.global_position = stood


func _check_settlement_expeditions(world: GameWorld,
		parent: MeepColony, player: OnlinePlayer) -> void:
	var colonies := world.meep_colonies()
	var planet := world.planet()
	var parent_ship := colonies.ship(parent.site_id) if colonies != null else null
	if colonies == null or planet == null or parent_ship == null:
		_expect(false, "the settlement harness has a parent city and ship")
		return
	var prerequisite := MeepColony.new()
	prerequisite.name = "SettlementPrerequisiteFixture"
	planet.add_child(prerequisite)
	prerequisite.stats = parent.stats
	prerequisite.founded_seed = 81726
	prerequisite.release_settlers(5, 71)
	prerequisite.resources = MeepColony.SETTLEMENT_EXPEDITION_COST * 2.0
	var rejected_five := not prerequisite.try_city_purchase(
		MeepColony.CityPurchase.SEND_SETTLEMENT, 77)
	prerequisite.release_settlers(1, 73)
	var accepted_six := prerequisite.try_city_purchase(
		MeepColony.CityPurchase.SEND_SETTLEMENT, 77)
	var accepted_repeat := prerequisite.try_city_purchase(
		MeepColony.CityPurchase.SEND_SETTLEMENT, 88)
	_expect(rejected_five and accepted_six and accepted_repeat
		and prerequisite.settlement_tokens == 2
		and prerequisite.settlement_armed_owner == 88,
		"three sibling pairs unlock repeatable paid launch-authorizations")
	prerequisite.queue_free()
	await get_tree().process_frame
	_stand_facing(planet, player, parent_ship.global_position, 14.0)
	parent.resources = parent.committed \
		+ MeepColony.SETTLEMENT_EXPEDITION_COST * 2.0
	var before_bank := parent.resources
	world.request_city_purchase(
		1, parent.site_id, MeepColony.CityPurchase.SEND_SETTLEMENT)
	world.request_city_purchase(
		1, parent.site_id, MeepColony.CityPurchase.SEND_SETTLEMENT)
	_expect(parent.settlement_tokens == 2
		and parent.settlement_armed_owner == 1
		and is_equal_approx(parent.resources,
			before_bank - MeepColony.SETTLEMENT_EXPEDITION_COST * 2.0)
		and player.owns_one_time_ability("settlement_launcher")
		and player.one_time_ability_count("settlement_launcher") == 2
		and player.abilities.find("settlement_launcher") < 0
		and not player.settlement_targeting(),
		"each city purchase adds one launcher without auto-equipping it")
	_expect(player.one_time_ability_title("settlement_launcher")
		== "First Settlement of Colony Ship"
		and String(player.one_time_ability_records(
			"settlement_launcher")[1].get("title", ""))
			== "Second Settlement of Colony Ship",
		"queued launchers retain unique launch numbers and their source colony")
	var direct_assignment_refused := not player.equip_ability(
		"settlement_launcher", 0)
	player.abilities.set_item(0, "building")
	player.apply_held("sword")
	var overrides_weapon := player._ability_overrides_weapon_input(0)
	player.activate_primary()
	await get_tree().process_frame
	var city_wheel := player.building_wheel()
	var nearest_city_enabled := city_wheel != null \
		and city_wheel.option_enabled(BuildingWheel.Option.CITY)
	if city_wheel != null:
		city_wheel.update_selection_from_point(
			city_wheel.point_for_option(BuildingWheel.Option.CITY))
	player.release_ability(0)
	await get_tree().process_frame
	_expect(nearest_city_enabled and is_instance_valid(player._city_menu),
		"Building's city segment opens the nearest founded city's menu")
	if is_instance_valid(player._city_menu):
		player._city_menu.close()
	await get_tree().process_frame
	player.activate_primary()
	await get_tree().process_frame
	var build_wheel := player.building_wheel()
	if build_wheel != null:
		build_wheel.update_selection_from_point(
			build_wheel.point_for_option(BuildingWheel.Option.SETTLEMENT))
	player.release_ability(0)
	await get_tree().process_frame
	build_wheel = player.building_wheel()
	var launcher_labels := "\n".join(build_wheel.picker_labels()) \
		if build_wheel != null else ""
	var launcher_picker_count := build_wheel.picker_count() \
		if build_wheel != null else 0
	var launcher_list := build_wheel.find_child(
		"SettlementLauncherList", true, false) as VBoxContainer \
		if build_wheel != null else null
	var first_launcher := launcher_list.get_child(0) as Button \
		if launcher_list != null and launcher_list.get_child_count() > 0 \
		else null
	if first_launcher != null:
		first_launcher.pressed.emit()
	await get_tree().process_frame
	_expect(direct_assignment_refused and overrides_weapon
		and launcher_picker_count == 2
		and launcher_labels.contains(parent.display_name)
		and player.settlement_targeting()
		and player.held_item().is_empty(),
		"Building takes LMB, lists both parent-city launchers, and enters targeting")
	player.cancel_settlement_targeting()
	_expect(not player.settlement_targeting()
		and parent.settlement_tokens == 2
		and player.owns_one_time_ability("settlement_launcher"),
		"Escape-style aim cancellation keeps the paid one-time ability")
	var bank_before_reactivation := parent.resources
	var reactivated := player.activate_ability(0)
	await get_tree().process_frame
	build_wheel = player.building_wheel()
	if build_wheel != null:
		build_wheel.update_selection_from_point(
			build_wheel.point_for_option(BuildingWheel.Option.SETTLEMENT))
	player.release_ability(0)
	await get_tree().process_frame
	build_wheel = player.building_wheel()
	launcher_list = build_wheel.find_child(
		"SettlementLauncherList", true, false) as VBoxContainer \
		if build_wheel != null else null
	first_launcher = launcher_list.get_child(0) as Button \
		if launcher_list != null and launcher_list.get_child_count() > 0 \
		else null
	if first_launcher != null:
		first_launcher.pressed.emit()
	await get_tree().process_frame
	_expect(reactivated and player.settlement_targeting()
		and parent.settlement_tokens == 2
		and parent.resources >= bank_before_reactivation,
		"reactivating Building resumes targeting without another charge")
	_expect(player.settlement_blocks_action(&"aim")
		and player.settlement_blocks_action(&"weapon_1")
		and player.settlement_blocks_action(&"parry")
		and not player.settlement_blocks_action(&"move_forward"),
		"settlement targeting reserves mouse combat and weapon inputs while retaining movement")
	world.request_settlement_launch(1, parent.site_id, parent.site.centre)
	_expect(parent.settlement_tokens == 2
		and player.settlement_targeting(),
		"an invalid too-close target retains both token and landing mode")
	var wet_target := Vector3.ZERO
	for sample in 512:
		var direction := Vector3(
			cos(float(sample) * 2.399963) * 0.8,
			-0.6 + float(sample % 17) * 0.07,
			sin(float(sample) * 2.399963) * 0.8).normalized()
		if planet.shape.elevation(direction) < MeepGrid.SHORE_MARGIN:
			wet_target = direction
			break
	if wet_target != Vector3.ZERO:
		world.request_settlement_launch(1, parent.site_id, wet_target)
	_expect(wet_target != Vector3.ZERO and parent.settlement_tokens == 2,
		"wet or unsupported landing terrain is rejected without consuming the token")

	var target := Vector3.ZERO
	var samples := 1600
	var golden := PI * (3.0 - sqrt(5.0))
	for sample in samples:
		var y := 1.0 - 2.0 * (float(sample) + 0.5) / float(samples)
		var radius := sqrt(maxf(1.0 - y * y, 0.0))
		var direction := Vector3(
			cos(golden * sample) * radius, y,
			sin(golden * sample) * radius)
		if colonies.valid_settlement_landing(parent.site_id, direction):
			target = direction
			break
	_expect(target != Vector3.ZERO,
		"the deterministic terrain scan finds a dry level clear landing footprint")
	if target == Vector3.ZERO:
		return
	var far_direction := -parent.site.centre
	var far_height := planet.shape.elevation(far_direction)
	player.global_position = planet.to_global(far_direction
		* (planet.shape.radius + far_height + 2.0))
	world.call("_server_settlement_launch", 2, 1, parent.site_id, target)
	_expect(parent.settlement_tokens == 2
		and colonies.expedition(&"settlement_1") == null,
		"host authority rejects a sender without the owned launch authorization")
	# Two more colonists stay put, one in each town, for the rest of this fixture.
	# Everything below inspects the parent's rows and the child's grid, and the
	# registry only keeps a city's full simulation while somebody is near it; a
	# settlement landed on the far side of the planet is a MeepCityLedger within
	# half a second of touching down otherwise, which is right for the game and
	# useless here.
	_watcher_at(planet, parent.site.centre)
	_watcher_at(planet, target)
	var founder_rows := parent.settlement_founder_rows()
	for slot in founder_rows.size():
		parent._ages[founder_rows[slot]] += 100.0 + slot
	var founder_manifest := parent.settlement_founder_manifest(founder_rows)
	var founder_names := PackedStringArray()
	var founder_ages := PackedFloat64Array()
	var former_homes := PackedInt32Array()
	var manifest_deeds_exact := true
	for entry_variant: Variant in founder_manifest:
		var entry := entry_variant as Dictionary
		founder_names.push_back(String(entry.get("name", "")))
		founder_ages.push_back(float(entry.get("age", 0.0)))
		var former_home := parent.meep_home(
			int(entry.get("parent_row", -1)))
		former_homes.push_back(former_home)
		manifest_deeds_exact = manifest_deeds_exact \
			and int(entry.get("former_deed", -1)) == former_home
	_expect(manifest_deeds_exact,
		"the authoritative founder manifest captures every deed before departure")
	var alive_before := parent.alive_count()
	player._settlement_preview_direction = target
	var placement_click := InputEventAction.new()
	placement_click.action = &"attack"
	placement_click.pressed = true
	player._unhandled_input(placement_click)
	var child_site := StringName("settlement_1")
	var lander := colonies.expedition(child_site)
	_expect(lander != null and parent.settlement_tokens == 1
		and parent.alive_count() == alive_before - 6
		and not player.settlement_targeting()
		and player.one_time_ability_count("settlement_launcher") == 1
		and player.one_time_ability_title("settlement_launcher")
			== "Second Settlement of Colony Ship"
		and player.abilities.get_item(0) == "building",
		"the second LMB click on green launches and keeps Building assigned")
	var departed_exact := true
	for row in founder_rows:
		departed_exact = departed_exact \
			and parent.meep_state(row) == MeepColony.State.DEPARTED \
			and parent.meep_home(row) < 0
	_expect(departed_exact,
		"founder rows remain departed history while all former deeds become vacant")
	var remembered_home := former_homes[0] if not former_homes.is_empty() else -1
	var vacancy_report := parent.resident_report(remembered_home)
	_expect(remembered_home >= 0
		and not (vacancy_report.get("former_owners", []) as Array).is_empty()
		and parent.structure_summary(remembered_home).contains("Formerly"),
		"vacant homes name departed former owners without counting them as occupants")
	if lander == null:
		return
	var in_flight_snapshot := colonies.snapshot()
	var late := MeepColonies.new()
	late.name = "SettlementLateJoin"
	late.planet = planet
	planet.add_child(late)
	late.apply_snapshot(in_flight_snapshot)
	var late_ship := late.expedition(child_site)
	if late_ship != null:
		lander.set_flight_state(3.25, false)
		late_ship.set_flight_state(3.25, false)
	_expect(late_ship != null and not late_ship.collision_enabled()
		and late_ship.position.distance_to(lander.position) < 0.001,
		"late join reconstructs the deterministic in-flight arc without collision")
	var visual_only := SettlementShip.new()
	add_child(visual_only)
	visual_only.configure(planet, &"visual_only", parent.site_id,
		lander.origin_direction, lander.target_direction, 17, [])
	visual_only.advance(SettlementShip.FLIGHT_DURATION, false)
	_expect(not visual_only.landed and not visual_only.collision_enabled()
		and visual_only.interact_prompt() == "Settlement Ship in flight",
		"a client reaching the visual endpoint waits for the reliable landed RPC")
	visual_only.queue_free()
	lander.set_flight_state(SettlementShip.FLIGHT_DURATION - 0.01, false)
	for _frame in 4:
		await get_tree().process_frame
	var child := colonies.colony(child_site)
	for _frame in 900:
		if child != null and child.ground_ready():
			break
		await get_tree().process_frame
		child = colonies.colony(child_site)
	_expect(child != null and child.alive_count() == 6
		and child.claim_radius >= 70.0
		and child.claim_radius < 70.0 + MeepGrid.CELL
		and is_zero_approx(child.resources)
		and child.parent_site_id == parent.site_id
		and child.site_id == &"settlement_1"
		and child.display_name == "Settlement 1",
		"landing founds an independent growing Tier 0 child with exactly six founders")
	if child == null:
		late.queue_free()
		await get_tree().process_frame
		return
	var ship_cloner := child.settlement_ship_cloner_index()
	var ship_machine := child.structures.at(ship_cloner) \
		if child.structures != null else null
	var ship_door := child._cloner_work_cell(ship_cloner)
	var hull_radius := Vector2(
		SettlementShip.FOOTPRINT.x, SettlementShip.FOOTPRINT.z).length() * 0.5
	var child_gate := child.road_origin_cell()
	var child_centre := child.grid.cell_of(Vector2.ZERO)
	var ship_report := child.report()
	_expect(ship_cloner >= 0 and ship_machine != null and ship_machine.built()
		and child.structures.count_of(MeepStructures.Kind.CLONER, true) == 1
		and child.grid.passable(ship_door)
		and child.grid.centre_of(ship_door).length() > hull_radius
		and bool(ship_report.get("settlement_ship_cloner", false)),
		"the landed settlement ship is its child's built cloner with an exterior queue")
	_expect(child.ship_ring_cells().size() >= 40
		and child.grid.passable(child_gate)
		and child.grid.centre_of(child_gate).length()
			>= MeepColony.SHIP_NAVIGATION_RADIUS
		and not child.grid.passable(child_centre)
		and child.grid.has_flag(child_centre, MeepGrid.FLAG_SHIP),
		"the child settlement also reserves a circular exterior road around its hull")
	_expect(child._wanted_kind() != MeepStructures.Kind.CLONER,
		"the child plans housing instead of constructing a duplicate cloner")
	var child_names := PackedStringArray()
	var sibling_exact := true
	var ages_carried := true
	for index in 6:
		child_names.push_back(child.meep_name(index))
		var sibling := child.meep_sibling(index)
		sibling_exact = sibling_exact and sibling >= 0 \
			and child.meep_sibling(sibling) == index
		ages_carried = ages_carried \
			and child.meep_age(index) >= founder_ages[index]
	child_names.sort()
	founder_names.sort()
	_expect(child_names == founder_names and sibling_exact and ages_carried,
		"all six names, ages, and three exact sibling relationships survive transfer")
	_expect(lander.landed and lander.collision_enabled()
		and lander.collision_matches_hull()
		and lander.interact_prompt() == "Open City Control",
		"the landed ship has exact hull-aligned collision and exposes child interaction")
	lander.interact(player)
	await get_tree().process_frame
	_expect(is_instance_valid(player._city_menu),
		"using the landed ship opens that child city's local control overlay")
	if is_instance_valid(player._city_menu):
		player._city_menu.close()
		await get_tree().process_frame
	var rows_before_refill := parent.count()
	parent.release_settlers(6, 0x51E771E)
	var reused := false
	var parent_deeds := parent.deed_snapshot()
	for row in range(rows_before_refill, parent.count()):
		reused = reused or parent_deeds[row] in former_homes
	_expect(reused,
		"parent cloning refills a founder vacancy before requiring new housing")
	_stand_facing(planet, player, parent_ship.global_position, 14.0)
	parent.resources = parent.committed \
		+ MeepColony.SETTLEMENT_EXPEDITION_COST
	world.request_city_purchase(
		1, parent.site_id, MeepColony.CityPurchase.SEND_SETTLEMENT)
	_expect(parent.settlement_tokens == 2
		and parent.settlement_armed_owner == 1
		and player.owns_one_time_ability("settlement_launcher")
		and player.one_time_ability_count("settlement_launcher") == 2
		and player.one_time_ability_title("settlement_launcher")
			== "Second Settlement of Colony Ship"
		and String(player.one_time_ability_records(
			"settlement_launcher")[1].get("title", ""))
			== "Third Settlement of Colony Ship"
		and player.abilities.get_item(0) == "building",
		"another city purchase stacks a third uniquely named launcher")
	_stand_facing(planet, player, lander.global_position, 14.0)
	world.request_settlement_rename(1, child_site, "  New   Dawn!!  ")
	var child_report := colonies.report(child_site)
	var parent_report := colonies.report(parent.site_id)
	var children: Array = parent_report.get("children", [])
	_expect(child.display_name == "New Dawn"
		and String(child_report.get("parent_name", "")) == parent.display_name
		and children.size() == 1
		and String((children[0] as Dictionary).get("name", "")) == "New Dawn",
		"moderated host renaming and direct parent/child lineage reports round-trip")
	var child_menu := CityMenu.new()
	child_menu.configure(func() -> Dictionary:
		return colonies.report(child_site))
	add_child(child_menu)
	await get_tree().process_frame
	var rename_requested := [""]
	child_menu.settlement_rename_requested.connect(
		func(wanted: String) -> void: rename_requested[0] = wanted)
	var rename_field := child_menu.settlement_name_field()
	var rename_button := child_menu.settlement_rename_button()
	if rename_field != null and rename_button != null:
		rename_field.text = "Harbour Light"
		rename_button.pressed.emit()
	_expect(rename_field != null and rename_button != null
		and rename_field.get_parent().visible
		and rename_requested[0] == "Harbour Light",
		"child city menus expose a dedicated rename field and action")
	child_menu.queue_free()
	late.apply_snapshot(colonies.snapshot())
	var late_child := late.colony(child_site)
	var late_lander := late.expedition(child_site)
	var late_parent := late.colony(parent.site_id)
	_expect(late_child != null and late_child.display_name == "New Dawn"
		and late_child.alive_count() == 6
		and late_lander != null and late_lander.landed
		and late_lander.collision_enabled() and late_parent != null
		and late_parent.settlement_armed_owner == 1
		and late.colonies().size() == 2,
		"late join restores lineage, identities, ship, collision, armed owner, and no duplicate city")
	var remembered_on_join := false
	if late_parent != null:
		for row in founder_rows:
			remembered_on_join = remembered_on_join \
				or (row < late_parent._former_deeds.size()
					and late_parent._former_deeds[row] in former_homes)
	_expect(remembered_on_join,
		"late join replicates departed founders' former deed references")
	if DisplayServer.get_name() != "headless":
		# Renderer waits happen only after the network/state assertions. Reuse the
		# authoritative path in a production SettlementShip clone so the registry's
		# live process cannot move it out of frame during terrain streaming.
		_hide_showcase_particles(planet)
		var launch_visual := SettlementShip.new()
		launch_visual.name = "SettlementLaunchCapture"
		planet.add_child(launch_visual)
		launch_visual.configure(planet, child_site, parent.site_id,
			lander.origin_direction, lander.target_direction,
			lander.expedition_seed, founder_manifest,
			SettlementShip.FLIGHT_DURATION * 0.55, false)
		await get_tree().process_frame
		await _showcase_shot(planet, player, launch_visual.global_position,
			36.0, 13.0, "settlement_launch")
		launch_visual.queue_free()
		await _showcase_shot(planet, player, lander.global_position,
			48.0, 19.0, "settlement_child_city")
	var completed_huts := 0
	var hut_plan := MeepStructures.plan_of(MeepStructures.Kind.HUT)
	for fixture_offset in [
			Vector2(30.0, 0.0), Vector2(-30.0, 0.0),
			Vector2(0.0, 30.0), Vector2(0.0, -30.0),
		]:
		var hut_centre := child.grid.cell_of(fixture_offset)
		var hut_corner := hut_centre - Vector2i(
			hut_plan.span.x / 2, hut_plan.span.y / 2)
		var hut := child.structures.place_at(
			MeepStructures.Kind.HUT, hut_corner)
		if hut >= 0:
			child.structures.set_progress(hut, 1.0)
			completed_huts += 1
	child.resources = MeepColony.CLONE_COST * 4.0
	child._plan_cloning()
	var clone_jobs := child.tasks.all_of(MeepTasks.Kind.CLONE)
	var clone_job: MeepTasks.Job = clone_jobs[0] \
		if not clone_jobs.is_empty() else null
	var entered_ship_cloner := false
	if clone_job != null and child.tasks.claim(clone_job.id):
		child._job[0] = clone_job.id
		child._state[0] = MeepColony.State.WORK
		child._timer[0] = MeepColony.QUEUE_PATIENCE
		child._queue_at_cloner(0, clone_job, WALK_STEP)
		entered_ship_cloner = child._state[0] == MeepColony.State.INSIDE \
			and ship_machine.inside == 1
		child._incubate(0, MeepColony.CLONE_SECONDS)
	_expect(completed_huts == 4
		and child.housing_capacity() > MeepColony.FIRST_WAVE,
		"completed child housing opens room for settlement-ship cloning")
	_expect(clone_job != null and clone_job.subject == ship_cloner
		and clone_job.at == ship_door,
		"the child's clone job queues outside its landed settlement ship")
	_expect(child.alive_count() > MeepColony.FIRST_WAVE
		and entered_ship_cloner
		and child.structures.count_of(MeepStructures.Kind.CLONER, true) == 1,
		"the settlement ship clones a founder after the child builds housing")
	late.queue_free()
	await get_tree().process_frame


## Renderer-only visual contract for the city phases. It runs after every gameplay
## assertion, on isolated deterministic grids projected through real MeepSite and
## Planet transforms. Every mesh, collider, completion flag and colour below is raised
## by MeepStructures, MeepRoads or SettlementShip rather than by screenshot-only art.
func _capture_city_upgrade_showcase(planet: Planet, player: OnlinePlayer,
		parent: MeepColony) -> void:
	if DisplayServer.get_name() == "headless":
		return
	print("meep_test: building deterministic city-upgrade visual fixtures")
	_hide_showcase_clutter(planet)
	var structure_site := MeepSite.new(_showcase_dry_direction(planet, 0),
		planet.shape.radius, parent.site.facing, 180.0)
	var structure_grid := _showcase_grid(planet, structure_site, 96)
	var structure_claim := MeepClaim.new()
	structure_claim.build(structure_grid, Vector2.ZERO, 88.0)
	var context_roads := MeepRoads.new()
	context_roads.name = "CityUpgradeContextRoads"
	planet.add_child(context_roads)
	context_roads.configure(structure_site, structure_grid,
		structure_claim, planet.shape, planet, 289)
	var centre := structure_claim.origin
	_complete_showcase_line(context_roads, structure_grid,
		Vector2i(8, centre.y - 19), Vector2i(83, centre.y - 19),
		MeepRoads.WidthClass.AVENUE)
	_complete_showcase_line(context_roads, structure_grid,
		Vector2i(8, centre.y + 15), Vector2i(83, centre.y + 15),
		MeepRoads.WidthClass.AVENUE)
	_complete_showcase_line(context_roads, structure_grid,
		Vector2i(centre.x + 24, centre.y + 4),
		Vector2i(centre.x + 24, 92), MeepRoads.WidthClass.BOULEVARD)
	_complete_showcase_line(context_roads, structure_grid,
		Vector2i(centre.x + 4, centre.y + 24),
		Vector2i(92, centre.y + 24), MeepRoads.WidthClass.BOULEVARD)
	var showcase_structures := MeepStructures.new()
	showcase_structures.name = "CityUpgradeShowcaseStructures"
	planet.add_child(showcase_structures)
	showcase_structures.configure(structure_site, structure_grid,
		structure_claim, planet.shape, planet, null, context_roads)
	var structure_specs: Array[Dictionary] = [
		{"kind": MeepStructures.Kind.HAT_HOUSE,
			"corner": centre + Vector2i(-34, -18), "shot": "city_hat_house",
			"away": 21.0, "up": 8.0},
		{"kind": MeepStructures.Kind.ABILITIES_HOUSE,
			"corner": centre + Vector2i(-13, -18),
			"shot": "city_abilities_house", "away": 21.0, "up": 8.0},
		{"kind": MeepStructures.Kind.BIOMASS_HARVESTER,
			"corner": centre + Vector2i(10, -19),
			"shot": "city_biomass_harvester", "away": 27.0, "up": 10.0},
		{"kind": MeepStructures.Kind.TOWNHOUSE,
			"corner": centre + Vector2i(-33, 17),
			"shot": "city_tier1_townhouse", "away": 20.0, "up": 8.0},
		{"kind": MeepStructures.Kind.MID_RISE,
			"corner": centre + Vector2i(-8, 16),
			"shot": "city_tier2_midrise", "away": 28.0, "up": 12.0},
	]
	for spec in structure_specs:
		var structure := showcase_structures.place_at(
			int(spec["kind"]), spec["corner"])
		showcase_structures.set_progress(structure, 1.0)
		_expect(structure >= 0 and showcase_structures.at(structure).built(),
			"renderer fixture completes %s through MeepStructures" % spec["shot"])
		showcase_structures.draw()
		showcase_structures.lend_colliders(
			showcase_structures.at(structure).local)
		var target := _structure_visual_centre(
			planet, showcase_structures, structure)
		await _showcase_shot(planet, player, target,
			float(spec["away"]) + (6.0
				if int(spec["kind"]) == MeepStructures.Kind.MID_RISE else 0.0),
			float(spec["up"]), String(spec["shot"]))

	# Three actual skyscraper instances make the 3x3 footprint and deliberate
	# 48-metre block spacing readable around a broad boulevard cross.
	var tower_corners: Array[Vector2i] = [
		centre + Vector2i(8, 8),
		centre + Vector2i(32, 8),
		centre + Vector2i(8, 32),
	]
	var tower_centres := PackedVector3Array()
	for corner in tower_corners:
		var tower := showcase_structures.place_at(
			MeepStructures.Kind.SKYSCRAPER, corner, 3)
		showcase_structures.set_progress(tower, 1.0)
		if tower >= 0:
			tower_centres.push_back(_structure_visual_centre(
				planet, showcase_structures, tower))
	showcase_structures.draw()
	_expect(tower_centres.size() == 3,
		"renderer fixture completes three production skyscrapers with block gaps")
	if not tower_centres.is_empty():
		var tower_target := Vector3.ZERO
		for point in tower_centres:
			tower_target += point
		tower_target /= float(tower_centres.size())
		showcase_structures.lend_colliders(
			structure_site.to_local(planet.to_local(tower_target).normalized()))
		await _showcase_shot(planet, player, tower_target,
			104.0, 72.0, "city_tier3_skyscraper_blocks")

	await _capture_surface_showcase(planet, player, parent)
	await _ensure_settlement_captures(planet, player, parent)
	showcase_structures.queue_free()
	context_roads.queue_free()
	await get_tree().process_frame
	var expected := PackedStringArray([
		"city_hat_house", "city_abilities_house", "city_biomass_harvester",
		"city_tier1_townhouse", "city_tier2_midrise",
		"city_tier3_skyscraper_blocks", "city_bridge", "city_ramp",
		"city_dock_boardwalk", "settlement_launch", "settlement_child_city",
	])
	for shot_name in expected:
		var image := Image.load_from_file(SHOT_DIR + shot_name + ".png")
		_expect(not image.is_empty() and image.get_width() >= 800
			and image.get_height() >= 450,
			"renderer saved a nontrivial %s PNG" % shot_name)


func _capture_surface_showcase(planet: Planet, player: OnlinePlayer,
		parent: MeepColony) -> void:
	var names := PackedStringArray(["bridge", "ramp", "dock"])
	for fixture_index in names.size():
		var wanted_kind := MeepRoads.SurfaceKind.BRIDGE \
			if names[fixture_index] == "bridge" \
			else MeepRoads.SurfaceKind.RAMP
		if names[fixture_index] != "dock":
			var natural := _natural_surface_fixture(
				planet, parent, wanted_kind)
			if not natural.is_empty():
				var natural_roads := natural["roads"] as MeepRoads
				var natural_grid := natural["grid"] as MeepGrid
				var natural_site := natural["site"] as MeepSite
				var natural_focus: Vector2i = natural["focus"]
				var natural_height := natural_roads.deck_height_at(
					natural_grid.index(natural_focus))
				var natural_target := planet.to_global(natural_site.point_at(
					natural_grid.centre_of(natural_focus), natural_height))
				print("meep_test: natural %s showcase candidate found at %s (%s)"
					% [names[fixture_index], natural_focus,
						String(natural.get("source", "terrain scan"))])
				var natural_view: Vector3 = natural.get(
					"view_side", Vector3.ZERO)
				await _showcase_shot(planet, player, natural_target,
					26.0, 8.0, "city_%s" % names[fixture_index],
					natural_view)
				natural_roads.queue_free()
				await get_tree().process_frame
				continue
			print("meep_test: no natural %s candidate; using marked synthetic fallback"
				% names[fixture_index])
		var site := MeepSite.new(_showcase_shallow_direction(planet)
			if names[fixture_index] == "dock"
			else _showcase_dry_direction(planet, fixture_index + 1),
			planet.shape.radius, parent.site.facing, 150.0)
		var grid := _showcase_grid(planet, site, 72)
		var claim := MeepClaim.new()
		var roads := MeepRoads.new()
		roads.name = "CityUpgrade%sRoads" % names[fixture_index].capitalize()
		planet.add_child(roads)
		var row := grid.cells / 2
		var base := grid.height_at(Vector2i(grid.cells / 2, row))
		var focus := Vector2i(grid.cells / 2, row)
		match names[fixture_index]:
			"bridge":
				for x in range(30, 42):
					var cell := Vector2i(x, row)
					grid.terrain[grid.index(cell)] = MeepGrid.Terrain.VOID
					grid.heights[grid.index(cell)] = base - 7.0
				claim.build(grid, Vector2.ZERO, 68.0)
				roads.configure(site, grid, claim, planet.shape, planet, 301)
				_complete_land_strip(roads, grid, row, 23, 29)
				_complete_land_strip(roads, grid, row, 42, 48)
				var bridge_cells := PackedInt32Array()
				var bridge_heights := PackedFloat32Array()
				for x in range(30, 42):
					bridge_cells.push_back(grid.index(Vector2i(x, row)))
					bridge_heights.push_back(base + 3.5)
				var bridge := roads.plan(-301, bridge_cells,
					MeepRoads.WidthClass.AVENUE,
					MeepRoads.SurfaceKind.BRIDGE, bridge_heights)
				roads.complete(bridge)
				_expect(roads.at(bridge).built()
					and roads.collision_faces() == roads.visible_surface_faces(),
					"renderer fixture completes a collidable production bridge")
				focus = Vector2i(35, row)
			"ramp":
				for x in range(30, 42):
					var cell := Vector2i(x, row)
					grid.terrain[grid.index(cell)] = MeepGrid.Terrain.STEEP
				claim.build(grid, Vector2.ZERO, 68.0)
				roads.configure(site, grid, claim, planet.shape, planet, 303)
				_complete_land_strip(roads, grid, row, 23, 29)
				_complete_land_strip(roads, grid, row, 42, 48)
				var ramp_cells := PackedInt32Array()
				var ramp_heights := PackedFloat32Array()
				for x in range(30, 42):
					ramp_cells.push_back(grid.index(Vector2i(x, row)))
					ramp_heights.push_back(base + float(x - 30) * 0.55)
				var ramp := roads.plan(-303, ramp_cells,
					MeepRoads.WidthClass.AVENUE,
					MeepRoads.SurfaceKind.RAMP, ramp_heights)
				roads.complete(ramp)
				_expect(roads.at(ramp).built()
					and roads.collision_faces() == roads.visible_surface_faces(),
					"renderer fixture completes a collidable production slope ramp")
				focus = Vector2i(35, row)
			"dock":
				for y in range(30, 43):
					for x in range(24, 50):
						var cell := Vector2i(x, y)
						grid.terrain[grid.index(cell)] = MeepGrid.Terrain.SHALLOW
						grid.heights[grid.index(cell)] = base - 4.5
				claim.build(grid, Vector2.ZERO, 68.0, true)
				roads.configure(site, grid, claim, planet.shape, planet, 307)
				var dock_cells := PackedInt32Array()
				var dock_heights := PackedFloat32Array()
				for x in range(24, 43):
					dock_cells.push_back(grid.index(Vector2i(x, row)))
					dock_heights.push_back(base + 1.25)
				for y_offset in 7:
					var y := row - 3 + y_offset
					if y_offset % 2 == 0:
						for x in range(43, 50):
							dock_cells.push_back(grid.index(Vector2i(x, y)))
							dock_heights.push_back(base + 1.25)
					else:
						for x in range(49, 42, -1):
							dock_cells.push_back(grid.index(Vector2i(x, y)))
							dock_heights.push_back(base + 1.25)
				var dock := roads.plan(-307, dock_cells,
					MeepRoads.WidthClass.STREET,
					MeepRoads.SurfaceKind.DOCK, dock_heights)
				roads.complete(dock)
				claim.build(grid, Vector2.ZERO, 68.0, true)
				var dock_structures := MeepStructures.new()
				dock_structures.name = "CityUpgradeDockHut"
				planet.add_child(dock_structures)
				dock_structures.configure(site, grid, claim,
					planet.shape, planet, null, roads)
				var hut := dock_structures.place_dock_hut(1)
				if hut >= 0:
					dock_structures.set_progress(hut, 1.0)
					dock_structures.draw()
					dock_structures.lend_colliders(
						dock_structures.at(hut).local)
				_expect(hut >= 0 and roads.dock_pile_count() > 0
					and not roads.dock_pile_faces().is_empty()
					and roads.collision_faces().size()
						== roads.visible_surface_faces().size()
							+ roads.dock_pile_faces().size(),
					"renderer fixture completes a dock hut, boardwalk, piles, and collision")
				focus = Vector2i(46, row)
		roads.draw()
		var focus_height := roads.deck_height_at(grid.index(focus))
		var target := planet.to_global(site.point_at(
			grid.centre_of(focus), focus_height))
		var shot_name := "city_%s" % (
			"dock_boardwalk" if names[fixture_index] == "dock"
			else names[fixture_index])
		await _showcase_shot(planet, player, target,
			30.0 if names[fixture_index] != "dock" else 27.0,
			5.0 if names[fixture_index] != "dock" else 4.0, shot_name)
		roads.queue_free()
		for child in planet.get_children():
			if child is MeepStructures \
					and child.name == "CityUpgradeDockHut":
				child.queue_free()
		await get_tree().process_frame


func _natural_surface_fixture(planet: Planet, parent: MeepColony,
		wanted_kind: int) -> Dictionary:
	# Try the known landing chasm first, then deterministic globally distributed
	# production grid bakes. The latter still classify the real PlanetShape; they
	# are not cached-height substitutions.
	for probe_index in 97:
		var site := parent.site
		var grid := _copy_showcase_grid(parent.grid)
		var radius := parent.claim_radius
		var source := "landing chasm"
		if probe_index > 0:
			var direction := _showcase_probe_direction(probe_index - 1)
			site = MeepSite.new(direction, planet.shape.radius,
				float(probe_index * 17 % 360), 80.0)
			grid = MeepGrid.new(site, 80, 2.0)
			grid.build(planet.shape, planet.finest_spacing())
			radius = 72.0
			source = "global natural probe %d" % (probe_index - 1)
			if planet.sun != null and direction.dot(
					planet.sun.global_basis.z.normalized()) < 0.12:
				continue
		if not grid.passable(grid.cell_of(Vector2.ZERO)):
			continue
		var claim := MeepClaim.new()
		claim.build(grid, Vector2.ZERO, radius)
		var roads := MeepRoads.new()
		roads.name = "Natural%sShowcase" % (
			"Bridge" if wanted_kind == MeepRoads.SurfaceKind.BRIDGE else "Ramp")
		roads.configure(site, grid, claim, planet.shape, planet,
			313 + wanted_kind + probe_index)
		var candidate := _find_natural_surface_candidate(
			roads, grid, claim, wanted_kind)
		if candidate.is_empty():
			roads.free()
			continue
		planet.add_child(roads)
		var start: Vector2i = candidate["start"]
		var field := MeepFlowField.new()
		field.build(grid, claim.origin)
		var approach := roads.path_home_from(start, field)
		if not approach.is_empty():
			var approach_segment := roads.plan(-401, approach,
				MeepRoads.WidthClass.AVENUE)
			roads.complete(approach_segment)
		var cells: PackedInt32Array = candidate["cells"]
		var heights: PackedFloat32Array = candidate["heights"]
		var segment := roads.plan(-402, cells, MeepRoads.WidthClass.AVENUE,
			wanted_kind, heights)
		roads.complete(segment)
		var endpoint: Vector2i = candidate["endpoint"]
		var endpoint_segment := roads.plan(-403,
			PackedInt32Array([grid.index(endpoint)]),
			MeepRoads.WidthClass.AVENUE)
		roads.complete(endpoint_segment)
		_expect(roads.at(segment).built()
			and roads.collision_faces() == roads.visible_surface_faces(),
			"renderer fixture completes a natural collidable %s"
				% ("bridge" if wanted_kind == MeepRoads.SurfaceKind.BRIDGE
					else "slope ramp"))
		return {
			"roads": roads,
			"grid": grid,
			"site": site,
			"focus": roads._cell(cells[cells.size() / 2]),
			"source": source,
			"view_side": _surface_view_side(
				planet, site, start, endpoint, grid),
		}
	return {}


func _find_natural_surface_candidate(roads: MeepRoads, grid: MeepGrid,
		claim: MeepClaim, wanted_kind: int) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	var directions: Array[Vector2i] = [
		Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]
	for y in grid.cells:
		for x in grid.cells:
			var start := Vector2i(x, y)
			if not claim.contains_cell(start) or not grid.passable(start):
				continue
			for direction in directions:
				var first := start + direction
				if not grid.inside(first) or claim.contains_cell(first):
					continue
				var terrain := grid.terrain_at(first)
				if terrain != MeepGrid.Terrain.VOID \
						and terrain != MeepGrid.Terrain.STEEP:
					continue
				var candidate := roads._bridge_candidate(start, direction)
				if candidate.is_empty() \
						or int(candidate["surface_kind"]) != wanted_kind:
					continue
				var cells: PackedInt32Array = candidate["cells"]
				if not _surface_candidate_reads_clearly(
						grid, candidate, wanted_kind):
					continue
				var score := float(cells.size()) \
					+ float(grid.index(start)) * 0.000001
				if score < best_score:
					best_score = score
					best = candidate
	return best


func _surface_candidate_reads_clearly(grid: MeepGrid,
		candidate: Dictionary, wanted_kind: int) -> bool:
	var cells: PackedInt32Array = candidate["cells"]
	var heights: PackedFloat32Array = candidate["heights"]
	if cells.is_empty() or heights.is_empty():
		return false
	var deck_low := INF
	var deck_high := -INF
	var raw_low := INF
	for slot in cells.size():
		deck_low = minf(deck_low, heights[slot])
		deck_high = maxf(deck_high, heights[slot])
		raw_low = minf(raw_low, grid.height_at(
			Vector2i(cells[slot] % grid.cells, cells[slot] / grid.cells)))
	var start: Vector2i = candidate["start"]
	var endpoint: Vector2i = candidate["endpoint"]
	var min_x := mini(start.x, endpoint.x) - 5
	var max_x := maxi(start.x, endpoint.x) + 5
	var min_y := mini(start.y, endpoint.y) - 5
	var max_y := maxi(start.y, endpoint.y) + 5
	var surrounding_high := -INF
	for y in range(maxi(min_y, 0), mini(max_y + 1, grid.cells)):
		for x in range(maxi(min_x, 0), mini(max_x + 1, grid.cells)):
			surrounding_high = maxf(
				surrounding_high, grid.height_at(Vector2i(x, y)))
	if surrounding_high > deck_high + 4.0:
		return false
	if wanted_kind == MeepRoads.SurfaceKind.BRIDGE:
		return deck_low - raw_low >= 2.0
	return absf(grid.height_at(endpoint) - grid.height_at(start)) >= 1.5


func _surface_view_side(planet: Planet, site: MeepSite,
		start: Vector2i, endpoint: Vector2i, grid: MeepGrid) -> Vector3:
	var start_world := planet.to_global(site.point_at(
		grid.centre_of(start), grid.height_at(start)))
	var end_world := planet.to_global(site.point_at(
		grid.centre_of(endpoint), grid.height_at(endpoint)))
	var middle := (start_world + end_world) * 0.5
	var up := (middle - planet.global_position).normalized()
	var along := end_world - start_world
	along -= up * along.dot(up)
	return up.cross(along).normalized() if along.length_squared() > 0.001 \
		else Vector3.ZERO


func _copy_showcase_grid(source: MeepGrid) -> MeepGrid:
	var grid := MeepGrid.new(source.site, source.cells, source.cell_size)
	grid.terrain = source.terrain.duplicate()
	grid.heights = source.heights.duplicate()
	grid.hazard = source.hazard.duplicate()
	grid.flags.fill(MeepGrid.FLAG_NONE)
	grid.surface_heights.fill(NAN)
	grid.built = true
	grid.revision += 1
	return grid


func _showcase_probe_direction(sample: int) -> Vector3:
	const PROBES := 96
	var golden := PI * (3.0 - sqrt(5.0))
	var y := 1.0 - 2.0 * (float(sample) + 0.5) / float(PROBES)
	var radius := sqrt(maxf(1.0 - y * y, 0.0))
	return Vector3(
		cos(golden * sample) * radius, y,
		sin(golden * sample) * radius)


func _complete_land_strip(roads: MeepRoads, grid: MeepGrid,
		row: int, from_x: int, to_x: int) -> void:
	var cells := PackedInt32Array()
	for x in range(from_x, to_x + 1):
		cells.push_back(grid.index(Vector2i(x, row)))
	var segment := roads.plan(-900 - from_x, cells,
		MeepRoads.WidthClass.AVENUE)
	roads.complete(segment)


func _complete_showcase_line(roads: MeepRoads, grid: MeepGrid,
		from: Vector2i, to: Vector2i, width_class: int) -> void:
	var cells := PackedInt32Array()
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	for step in steps + 1:
		var ratio := float(step) / float(maxi(steps, 1))
		var cell := Vector2i(
			roundi(lerpf(from.x, to.x, ratio)),
			roundi(lerpf(from.y, to.y, ratio)))
		if grid.inside(cell) and not cells.has(grid.index(cell)):
			cells.push_back(grid.index(cell))
	var segment := roads.plan(-950 - roads.count(), cells, width_class)
	roads.complete(segment)


func _showcase_site(planet: Planet, parent: MeepColony,
		offset: Vector2, reach: float) -> MeepSite:
	return MeepSite.new(parent.site.direction_at(offset),
		planet.shape.radius, parent.site.facing, reach)


func _showcase_dry_direction(planet: Planet, selector: int) -> Vector3:
	var golden := PI * (3.0 - sqrt(5.0))
	var samples := 4096
	var start := posmod(selector * 1301, samples)
	for turn in samples:
		var sample := posmod(start + turn, samples)
		var y := 1.0 - 2.0 * (float(sample) + 0.5) / float(samples)
		var radius := sqrt(maxf(1.0 - y * y, 0.0))
		var direction := Vector3(
			cos(golden * sample) * radius, y,
			sin(golden * sample) * radius)
		var low := INF
		var high := -INF
		var probe := MeepSite.new(
			direction, planet.shape.radius, 0.0, 40.0)
		for offset: Vector2 in [
				Vector2.ZERO, Vector2(18.0, 0.0), Vector2(-18.0, 0.0),
				Vector2(0.0, 18.0), Vector2(0.0, -18.0)]:
			var height := planet.shape.elevation(probe.direction_at(offset))
			low = minf(low, height)
			high = maxf(high, height)
		if low >= 1.0 and high - low <= 2.5:
			return direction
	print("meep_test: no broad dry showcase site; using deterministic fallback")
	return Vector3(0.0, 1.0, 0.0)


func _showcase_shallow_direction(planet: Planet) -> Vector3:
	var golden := PI * (3.0 - sqrt(5.0))
	var first_shallow := Vector3.ZERO
	var to_sun := planet.sun.global_basis.z.normalized() \
		if planet.sun != null else Vector3.ZERO
	for sample in 4096:
		var y := 1.0 - 2.0 * (float(sample) + 0.5) / 4096.0
		var radius := sqrt(maxf(1.0 - y * y, 0.0))
		var direction := Vector3(
			cos(golden * sample) * radius, y,
			sin(golden * sample) * radius)
		var height := planet.shape.elevation(direction)
		if height >= -4.5 and height <= -1.0:
			if first_shallow == Vector3.ZERO:
				first_shallow = direction
			if to_sun == Vector3.ZERO or direction.dot(to_sun) >= 0.18:
				print("meep_test: sunlit natural shallow showcase site found")
				return direction
	if first_shallow != Vector3.ZERO:
		print("meep_test: no sunlit shallow site; using natural shaded fallback")
		return first_shallow
	print("meep_test: no natural shallow showcase site; using deterministic coast fallback")
	return Vector3(0.742, 0.231, -0.629).normalized()


func _showcase_grid(planet: Planet, site: MeepSite, across: int) -> MeepGrid:
	var grid := MeepGrid.new(site, across, 2.0)
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			var index := grid.index(cell)
			grid.terrain[index] = MeepGrid.Terrain.PASSABLE
			grid.flags[index] = MeepGrid.FLAG_NONE
			grid.heights[index] = planet.shape.elevation(
				site.direction_at(grid.centre_of(cell)),
				planet.finest_spacing())
	grid.surface_heights.fill(NAN)
	grid.built = true
	grid.revision += 1
	return grid


func _hide_showcase_clutter(planet: Planet) -> void:
	for node in planet.find_children("*", "", true, false):
		if node is GroundCover or node is FlowerTreeField \
				or node is GPUParticles3D or node is CPUParticles3D:
			(node as Node3D).visible = false


func _hide_showcase_particles(planet: Planet) -> void:
	for node in planet.find_children("*", "", true, false):
		if node is GPUParticles3D or node is CPUParticles3D:
			(node as Node3D).visible = false


func _structure_visual_centre(planet: Planet,
		structures: MeepStructures, structure: int) -> Vector3:
	var floor := structures.world_centre(structure)
	var entry := structures.at(structure)
	if entry == null:
		return floor
	var up := (floor - planet.global_position).normalized()
	return floor + up * structures.display_height(structure) * 0.5


func _showcase_shot(planet: Planet, player: OnlinePlayer, target: Vector3,
		away: float, lift: float, shot_name: String,
		view_side: Vector3 = Vector3.ZERO, light_scale := 1.0) -> void:
	_stand_facing(planet, player, target, maxf(away * 0.8, 12.0))
	var up := (target - planet.global_position).normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	var forward_tangent := up.cross(side).normalized()
	side = view_side.normalized() if view_side.length_squared() > 0.001 \
		else (side + forward_tangent * 0.55).normalized()
	var eye := target + side * away + up * lift
	var camera := Camera3D.new()
	camera.name = "CityUpgradeCamera"
	camera.fov = 58.0
	camera.far = 6000.0
	add_child(camera)
	camera.global_transform = Transform3D(
		Basis.looking_at(target - eye, up), eye)
	var light := OmniLight3D.new()
	light.name = "CityUpgradeFillLight"
	light.light_energy = 3.0 * light_scale
	light.omni_range = maxf(away * 2.5, 80.0)
	light.shadow_enabled = false
	camera.add_child(light)
	var key := DirectionalLight3D.new()
	key.name = "CityUpgradeKeyLight"
	key.light_energy = 1.2 * light_scale
	key.shadow_enabled = true
	camera.add_child(key)
	var low_fill := OmniLight3D.new()
	low_fill.name = "CityUpgradeLowFill"
	low_fill.light_energy = 3.5 * light_scale
	low_fill.light_color = Color(0.92, 0.96, 1.0)
	low_fill.omni_range = maxf(away * 2.0, 64.0)
	low_fill.shadow_enabled = false
	add_child(low_fill)
	low_fill.global_position = target - up * 1.5 - side * minf(away * 0.3, 8.0)
	var hidden_layers: Array[CanvasLayer] = []
	for node in get_tree().root.find_children("*", "CanvasLayer", true, false):
		var layer := node as CanvasLayer
		if layer != null and layer.visible:
			layer.visible = false
			hidden_layers.push_back(layer)
	var previous := get_viewport().get_camera_3d()
	camera.make_current()
	for _frame in 75:
		await get_tree().process_frame
	await _shot(shot_name)
	camera.queue_free()
	low_fill.queue_free()
	for layer in hidden_layers:
		if is_instance_valid(layer):
			layer.visible = true
	if is_instance_valid(previous):
		previous.make_current()


func _ensure_settlement_captures(planet: Planet, player: OnlinePlayer,
		parent: MeepColony) -> void:
	var launch_path := SHOT_DIR + "settlement_launch.png"
	var child_path := SHOT_DIR + "settlement_child_city.png"
	if FileAccess.file_exists(launch_path) and FileAccess.file_exists(child_path):
		print("meep_test: existing settlement launch and child captures verified")
		return
	print("meep_test: settlement visual absent; using production SettlementShip fallback")
	var fallback := SettlementShip.new()
	fallback.name = "SettlementCaptureFallback"
	planet.add_child(fallback)
	var target_direction := parent.site.direction_at(Vector2(0.0, 620.0))
	fallback.configure(planet, &"settlement_visual_fallback", parent.site_id,
		parent.site.centre, target_direction, 0x5E771E, [])
	if not FileAccess.file_exists(launch_path):
		fallback.set_flight_state(SettlementShip.FLIGHT_DURATION * 0.55, false)
		await _showcase_shot(planet, player, fallback.global_position,
			42.0, 15.0, "settlement_launch")
	if not FileAccess.file_exists(child_path):
		fallback.set_flight_state(SettlementShip.FLIGHT_DURATION, true)
		await _showcase_shot(planet, player, fallback.global_position,
			46.0, 18.0, "settlement_child_city")
	fallback.queue_free()
	await get_tree().process_frame


## What the colony found to cut, before anyone has cut any of it.
func _check_timber(colony: MeepColony, timber: Node) -> void:
	var standing: PackedVector4Array = timber.call("standing_near",
		colony.combat_position(), colony.grid.half_span())
	_town_harvestables_at_start = colony.standing_timber()
	print("meep_test: %d trees within the town's grid, %d in-boundary plants"
		% [standing.size(), _town_harvestables_at_start]
		+ " worth harvesting")
	_expect(colony.standing_timber() > 0,
		"the colony finds standing flora to harvest within its claim")
	_expect(colony.standing_timber() > standing.size(),
		"the local non-grass flower field joins the biomass supply")
	_expect(colony.resources == 0.0 and colony.committed == 0.0,
		"a colony starts with an empty bank and nothing promised")


## The target contract behind mining: completing work on one selected flower-tree must
## remove that exact flower-tree, rather than accepting damage absorbed by unrelated
## ground cover nearby. Restore it immediately so this probe does not alter the world.
func _check_exact_harvest(colony: MeepColony, timber: Node) -> void:
	var standing: PackedVector4Array = timber.call(&"standing_near",
		colony.combat_position(), 1200.0)
	_expect(not standing.is_empty(),
		"at least one flower-tree remains for the exact-harvest probe")
	if standing.is_empty():
		return
	var picked := standing[0]
	var root := Vector3(picked.x, picked.y, picked.z)
	var harvested := bool(timber.call(&"harvest_at", root, 1.0, 100000.0))
	var remains: PackedVector4Array = timber.call(&"standing_near", root, 1.0)
	_expect(harvested and remains.is_empty(),
		"mining hides the exact flower-tree the Meep selected")
	_expect(int(timber.call(&"restore_within", root, 1.0)) == 1,
		"the exact-harvest probe restores its flower-tree afterwards")


## GroundCover is streamed, but a selected root retains a stable tile/species/instance
## identity. This proves the flower disappears through that identity rather than merely
## paying biomass for an unrelated plant in the same damage volume.
func _check_exact_meadow_harvest(colony: MeepColony,
		flowers: GroundCover) -> void:
	var standing: PackedVector4Array = flowers.standing_near(
		colony.combat_position(), colony.claim_radius)
	_expect(not standing.is_empty(),
		"at least one meadow flower remains for the exact-harvest probe")
	if standing.is_empty():
		return
	var picked := standing[0]
	var root := Vector3(picked.x, picked.y, picked.z)
	var token: PackedInt32Array = flowers._harvest_targets.get(
		flowers._harvest_key(root), PackedInt32Array())
	var picked_glow_anchor := false
	# Prefer the exact source of a pooled flower light. The disappearing mesh and its
	# cast light are separate failure modes, and both used to leave a pulse on the dirt.
	for tile_variant: Variant in flowers._tiles.values():
		if picked_glow_anchor:
			break
		var tile = tile_variant
		for slot in tile.glow_points.size():
			var candidate := flowers.to_global(tile.glow_points[slot])
			var candidate_token: PackedInt32Array = flowers._harvest_targets.get(
				flowers._harvest_key(candidate), PackedInt32Array())
			if candidate_token.size() < 5:
				continue
			root = candidate
			token = candidate_token
			picked_glow_anchor = true
			break
	_expect(token.size() == 5,
		"the streamed flower keeps its stable visual identity until harvest")
	if token.size() < 5:
		return

	var harvested := flowers.harvest_at(root, 0.25, 100000.0)
	var remains := flowers.standing_near(root, 0.05)
	_expect(harvested and remains.is_empty(),
		"mining hides the exact streamed flower the Meep selected")
	var cell := Vector3i(token[0], token[1], token[2])
	var species_index := token[3]
	var instance_index := token[4]
	var tile = flowers._tiles.get(cell)
	if tile != null and species_index < tile.rows.size():
		var buffer: PackedFloat32Array = tile.rows[species_index]
		var hidden := flowers._instance_transform(buffer, instance_index)
		var shortest := minf(hidden.basis.x.length(),
			minf(hidden.basis.y.length(), hidden.basis.z.length()))
		var longest := maxf(hidden.basis.x.length(),
			maxf(hidden.basis.y.length(), hidden.basis.z.length()))
		var row := instance_index * GroundCover.STRIDE
		_expect(shortest > 0.0 and longest < 0.001,
			"a harvested flower is micro-scaled instead of leaving a singular point")
		_expect(is_zero_approx(buffer[row + GroundCover.COLOR + 3])
			and is_zero_approx(buffer[row + GroundCover.RANK + 2]),
			"a harvested flower cannot keep pulsing through its emission channels")
	if picked_glow_anchor:
		flowers._place_glow_lights(root)
		var up := (root - flowers.planet_host().global_position).normalized()
		var old_light := root + up * flowers.glow_light_height
		var stale := false
		for target in flowers._glow_targets:
			if target.is_finite() and target.distance_squared_to(old_light) < 0.0001:
				stale = true
				break
		_expect(not stale,
			"a harvested flower stops lending its pooled light to the bare ground")


## Runs the town until it has done everything it is meant to do, or until it is clear it
## will not, and prints when each of those things first happened.
##
## Stepped faster than the clock, several tenths of a second per frame, because a mining
## trip is a hundred-metre walk each way and a test that waited for one in real time
## would take minutes. The step itself stays small: a Meep moves a couple of metres in a
## tenth of a second and the cells are two metres wide, so a coarser one would let
## somebody stride over the lip of the chasm the rest of these checks are about.
func _live(colony: MeepColony, timber: Node) -> void:
	var reached := {}
	var lived := 0.0
	var housing_violation := false
	var starter_harvestables := -1
	for frame in LIVE_FRAMES:
		for _slice in LIVE_SLICES:
			colony.step_simulation(WALK_STEP)
			lived += WALK_STEP
		await get_tree().physics_frame
		if colony.resources > 0.0 and not reached.has("earned"):
			reached["earned"] = lived
			print("meep_test: first biomass banked after %.0f s" % lived)
		if not reached.has("cloner") and colony.structures.count_of(
				MeepStructures.Kind.CLONER, true) > 0:
			reached["cloner"] = lived
			print("meep_test: the cloner was finished after %.0f s" % lived)
		if not reached.has("cloned") \
				and colony.alive_count() > MeepColony.FIRST_WAVE:
			reached["cloned"] = lived
			print("meep_test: the first cloned Meep walked out after %.0f s"
				% lived)
		var huts := colony.structures.count_of(MeepStructures.Kind.HUT, true)
		if not reached.has("hut") and huts > 0:
			reached["hut"] = lived
			print("meep_test: the first hut was finished after %.0f s" % lived)
		if not reached.has("road") and colony.roads.cell_count() > 0:
			reached["road"] = lived
			print("meep_test: the first road was finished after %.0f s" % lived)
		if not reached.has("starter") \
				and colony.alive_count() >= MeepColony.STARTER_POPULATION \
				and colony.structures.built_count() \
					>= MeepColony.STARTER_STRUCTURES:
			reached["starter"] = lived
			starter_harvestables = colony.standing_timber()
			print("meep_test: starter population milestone reached"
				+ " after %.0f s" % lived)
		if colony.alive_count() > MeepColony.FIRST_WAVE \
				and colony.alive_count() > huts \
					* MeepColony.TIER_ZERO_SETTLERS_PER_HUT:
			housing_violation = true
		if colony.alive_count() > MeepColony.STARTER_POPULATION:
			if not reached.has("expanded"):
				reached["expanded"] = lived
				print("meep_test: house-first expansion cloned settler 33"
					+ " after %.0f s" % lived)
		if colony.tier_zero_full() \
				and colony.alive_count() == colony.housing_capacity():
			print("meep_test: Tier 0 filled with %d houses and %d settlers"
				% [huts, colony.alive_count()]
				+ " after %.0f s" % lived)
			break
	_expect(reached.has("starter"),
		"the starter milestone houses all 32 settlers in sixteen huts")
	_expect(reached.has("expanded"),
		"growth continues beyond the former 32-settler stopping point")
	_expect(not housing_violation,
		"every settler after the landed wave has completed sibling housing first")
	_expect(starter_harvestables >= 0
		and colony.standing_timber() < starter_harvestables,
		"settlers keep harvesting biomass after the starter milestone")
	_expect(colony.tier_zero_full(),
		"Tier 0 keeps building until its spaced settlement plan is filled")
	print("meep_test: %.0f s of town life in %d frames: %d settlers, %.0f"
		% [lived, LIVE_FRAMES, colony.alive_count(), colony.resources]
		+ " biomass, %d structures, %d road cells, %d trees felled"
		% [colony.structures.built_count(),
		colony.roads.cell_count(),
		int(timber.call("broken_keys").size())])
	print("meep_test: road branches %d/%d built, %d unfinished; space exhausted=%s"
		% [colony.roads.built_count(), colony.structures.built_count(),
		colony.roads.unfinished_count(),
		str(colony.tier_zero_space_exhausted())])
	print("meep_test: city blueprint %s" % [colony.report().get(
		"city_lots", {})])
	print("meep_test: next hut lots %s" % [colony.report().get(
		"next_hut_lots", {})])


## The economy end to end: trees came down, biomass was earned for them, buildings were
## paid for out of it, and the population grew because they were.
func _check_economy(colony: MeepColony, timber: Node) -> void:
	var felled := int((timber.call("broken_keys") as PackedInt32Array).size())
	_expect(felled > 0
		or colony.standing_timber() < _town_harvestables_at_start,
		"the Meeps harvest real non-grass flora from the world")
	_expect(colony.resources > 0.0 or colony.structures.built_count() > 0,
		"and were paid biomass for them")
	_expect(colony.standing_timber() < _town_harvestables_at_start,
		"the flora they cut stops being offered as work")
	_expect(colony.structures.count_of(MeepStructures.Kind.CLONER, true) > 0,
		"the first thing the town finishes is a cloner")
	_expect(colony.alive_count() > MeepColony.FIRST_WAVE,
		"the cloner turns one Meep into two, so the colony grows past its wave")
	_expect(colony.structures.count_of(MeepStructures.Kind.HUT, true) > 0,
		"housing follows the cloner")
	_expect(colony.structures.built_count() > MeepColony.STARTER_STRUCTURES,
		"the town keeps building beyond its housed starter core")
	_expect(colony.structures.built_count()
		== colony.tier_zero_structure_target(),
		"Tier 0 stops at its terrain-scaled civic density")
	_expect(colony.alive_count() == colony.housing_capacity(),
		"cloning fills completed housing without overshooting it")
	_expect(colony.roads.cell_count() > 0,
		"the builders connect their structures with real road cells")
	# Every unit promised to a site is a unit that cannot be promised to another, and
	# the promise is released when the building is finished or never.
	_expect(colony.committed <= colony.resources + 0.001,
		"the bank never promises biomass it does not have")
	var spent := 0.0
	for index in colony.structures.count():
		spent += MeepStructures.plan_of(colony.structures.at(index).kind).cost
	print("meep_test: %.0f biomass banked, %.0f promised, %.0f of building"
		% [colony.resources, colony.committed, spent] + " paid for")
	_expect(spent > 0.0, "the town spent its biomass on what it put up")


## Stable individual identity, one sibling deed per hut, live occupancy, and connected
## leisure routes are all derived data: none of them may require one node per resident
## or an extra town snapshot.
func _check_identity_and_homes(colony: MeepColony) -> void:
	var names: Dictionary = {}
	var bad_pairs := 0
	var bad_prompts := 0
	for index in colony.count():
		var title := colony.meep_name(index)
		names[title] = true
		if not colony.meep_summary(index).begins_with(title):
			bad_prompts += 1
		var sibling := colony.meep_sibling(index)
		if sibling >= 0:
			var same_family := title.get_slice(" ", 1) \
				== colony.meep_name(sibling).get_slice(" ", 1)
			if not same_family \
					or colony.meep_home(index) != colony.meep_home(sibling):
				bad_pairs += 1
	_expect(names.size() == colony.count() and bad_prompts == 0,
		"every Meep has a unique stable name in its look prompt")
	_expect(bad_pairs == 0,
		"siblings share a family name and one specific completed home")
	var actual_alive := colony._alive
	colony._alive = MeepColony.MAX_CITY_POPULATION
	_expect(colony._consecutive_home_visits()
			== MeepColony.MAX_CONSECUTIVE_HOME_VISITS
		and colony._home_wait_multiplier() > 1.5
		and MeepColony.STEPS_PER_TICK == 1024
		and colony.population_ceiling(4) >= 10000,
		"giant cities keep idle Meeps indoors and advance active rows in bounded chunks")
	colony._alive = actual_alive

	var first_hut := colony.structures.hut_at_ordinal(0, true)
	_expect(first_hut >= 0, "the finished town has an inspectable sibling home")
	if first_hut < 0:
		return
	var first_prompt := colony.structure_summary(first_hut)
	_expect(first_prompt.contains(colony.meep_name(0))
		and first_prompt.contains(colony.meep_name(1))
		and first_prompt.contains("Occupied")
		and first_prompt.contains("/2"),
		"a house look prompt names both owners and reports live occupancy")
	var proxy := MeepStructureProxy.new()
	proxy.configure(colony)
	proxy.set_lent(first_hut)
	_expect(proxy.interact_prompt() == first_prompt,
		"the pooled building collider exposes the live house report")
	proxy.free()

	# Put one owner at its own doorway, enter, then let its wait expire. Restore the
	# mature town immediately so this probe cannot alter the captures or economy audit.
	var resident := 0
	var old_local := colony._local[resident]
	var old_goal := colony._goal[resident]
	var old_heading := colony._heading[resident]
	var old_state := colony._state[resident]
	var old_job := colony._job[resident]
	var old_timer := colony._timer[resident]
	var old_turn := colony._idle_turn[resident]
	var door := colony.structures.work_cell(first_hut)
	colony._job[resident] = 0
	colony._local[resident] = colony.grid.centre_of(door)
	colony._go_home(resident, first_hut)
	colony._step(resident, MeepColony.SIM_STEP)
	_expect(colony.meep_state(resident) == MeepColony.State.AT_HOME
		and colony.structure_summary(first_hut).contains(
			"Occupied %d/2" % colony.home_occupancy(first_hut)),
		"an idle owner walks through its own door and counts as home")
	colony._timer[resident] = 0.0
	colony._step(resident, MeepColony.SIM_STEP)
	_expect(colony.meep_state(resident) == MeepColony.State.IDLE,
		"a resident leaves its house after waiting inside")
	colony._local[resident] = old_local
	colony._goal[resident] = old_goal
	colony._heading[resident] = old_heading
	colony._state[resident] = old_state
	colony._job[resident] = old_job
	colony._timer[resident] = old_timer
	colony._idle_turn[resident] = old_turn

	var stroll := colony.roads.stroll_path(
		colony.meep_local(resident), MeepColony.STROLL_CELLS_MAX, 947)
	var bad_step := 0
	for slot in stroll.size():
		var cell_index := stroll[slot]
		if not colony.roads.snapshot().has(cell_index):
			bad_step += 1
		if slot == 0:
			continue
		var before := Vector2i(stroll[slot - 1] % colony.grid.cells,
			stroll[slot - 1] / colony.grid.cells)
		var after := Vector2i(cell_index % colony.grid.cells,
			cell_index / colony.grid.cells)
		var apart := (after - before).abs()
		if apart.x > 1 or apart.y > 1:
			bad_step += 1
	_expect(stroll.size() > 1 and bad_step == 0,
		"idle walks are connected road-cell routes instead of cross-town shortcuts")


## The ground a finished building stands on stops being ground.
func _check_town_ground(colony: MeepColony) -> void:
	var built := _built_in(colony)
	if built < 0:
		_expect(false, "something in the town is finished")
		return
	var entry := colony.structures.at(built)
	var plan := MeepStructures.plan_of(entry.kind)
	var blocked := 0
	for x in plan.span.x:
		for y in plan.span.y:
			if not colony.grid.passable(entry.corner + Vector2i(x, y)):
				blocked += 1
	_expect(blocked == plan.span.x * plan.span.y,
		"a finished building takes its whole footprint out of the grid")
	var inside_ship_circle := 0
	for index in colony.structures.count():
		if colony.structures.clearance_from_ship(index) \
				< MeepStructures.SHIP_CLEAR_RADIUS:
			inside_ship_circle += 1
	_expect(inside_ship_circle == 0,
		"every building footprint stays outside the ship's landing plaza")
	var inside := 0
	for index in colony.count():
		if colony.meep_state(index) == MeepColony.State.DEAD:
			continue
		if not colony.grid.passable(
				colony.grid.cell_of(colony.meep_local(index))):
			inside += 1
	_expect(inside == 0,
		"nobody is left standing inside the walls of what they built")
	# Two structures cannot be pegged out on top of each other, whatever else is
	# true about the ground they were offered.
	var overlapping := 0
	for first in colony.structures.count():
		for second in range(first + 1, colony.structures.count()):
			var one := colony.structures.at(first)
			var two := colony.structures.at(second)
			if one.local.distance_to(two.local) < MeepStructures.SPACING:
				overlapping += 1
	_expect(overlapping == 0, "no two buildings were put in the same place")
	var furthest_structure := 0.0
	for index in colony.structures.count():
		furthest_structure = maxf(
			furthest_structure, colony.structures.at(index).local.length())
	_expect(furthest_structure >= colony.claim_radius * 0.72,
		"post-starter houses spread into the outer settlement instead of crowding its centre")
	var footprint_cells := 0
	for index in colony.structures.count():
		var footprint := MeepStructures.plan_of(
			colony.structures.at(index).kind).span
		footprint_cells += footprint.x * footprint.y
	_expect(footprint_cells < colony.claim.count / 2,
		"Tier 0 retains most claimed ground for streets, parks and civic sites")
	var bad_road := 0
	var under_ship := 0
	for cell_index in colony.roads.snapshot():
		var cell := Vector2i(cell_index % colony.grid.cells,
			cell_index / colony.grid.cells)
		if not colony.claim.contains_cell(cell) \
				or not colony.grid.has_flag(cell, MeepGrid.FLAG_ROAD) \
				or colony.grid.has_flag(cell, MeepGrid.FLAG_BUILDING) \
				or colony.grid.has_flag(cell, MeepGrid.FLAG_SHIP):
			bad_road += 1
		if colony.grid.centre_of(cell).length() \
				< MeepColony.SHIP_NAVIGATION_RADIUS:
			under_ship += 1
	var missing_ring := 0
	for cell_index in colony.ship_ring_cells():
		if not colony.roads.has_cell(cell_index):
			missing_ring += 1
	_expect(bad_road == 0,
		"every road stays inside the dynamic claim and outside solid footprints")
	_expect(under_ship == 0 and missing_ring == 0,
		"the completed plaza circles the ship and every later road grows outward")
	var expected_lamps := 0
	var lamp_phase := posmod(colony.founded_seed, MeepRoads.LAMP_STRIDE)
	for cell_index in colony.roads.snapshot():
		if posmod(cell_index + lamp_phase, MeepRoads.LAMP_STRIDE) == 0:
			expected_lamps += 1
	var bad_lamp := 0
	for slot in colony.roads.lamp_count():
		var lamp_cell := colony.roads.lamp_cell_at(slot)
		var cell := Vector2i(lamp_cell % colony.grid.cells,
			lamp_cell / colony.grid.cells)
		var from_centre := colony.roads.lamp_local_at(slot).distance_to(
			colony.grid.centre_of(cell))
		if not colony.roads.snapshot().has(lamp_cell) \
				or absf(from_centre - MeepRoads.LAMP_KERB) > 0.001:
			bad_lamp += 1
	_expect(colony.roads.lamp_count() == expected_lamps
		and colony.roads.lamp_count() > 0 and bad_lamp == 0,
		"paving crews erect deterministic lamps on completed road kerbs")
	_expect(colony.roads.light_pool_size() == MeepRoads.LIGHT_POOL,
		"street lamps share a bounded physical-light pool")
	var road_cell := colony.roads.cell_index_at(0)
	if road_cell >= 0:
		var cell := Vector2i(road_cell % colony.grid.cells,
			road_cell / colony.grid.cells)
		_expect(colony.grid.cost_at(cell) == MeepGrid.ROAD_COST,
			"completed roads strongly attract the routes town errands follow")


## The first thing the town finished, or -1 if it finished nothing.
func _built_in(colony: MeepColony) -> int:
	for index in colony.structures.count():
		if colony.structures.at(index).built():
			return index
	return -1


## Whether a finished building is standing on bare ground, asked by trying to clear it
## a second time: if the first attempt worked there is nothing left there to cut.
##
## Which is the one form of this question that answers itself. Counting what stands
## inside the footprint cannot answer it — the far-distance grass field ignores damage
## the way it ignores craters, so a cleared building still has a dozen of its blades
## standing in it and always will. Offering the same volume again asks only about the
## plants that were ever removable.
##
## Only asked with a renderer, and that is the difficulty rather than a detail: the cover
## fields sow the tiles a viewer is near, so a headless run has no grass anywhere near
## the town and would pass this by having nothing to find. The control below is what
## stops a graphical run from passing the same empty way.
func _check_cleared(colony: MeepColony, built: int) -> void:
	if DisplayServer.get_name() == "headless" or built < 0:
		return
	var middle := colony.structures.world_centre(built)
	var reach := colony.structures.footprint_radius(built)
	var span := reach + MeepColony.CLEAR_MARGIN
	var road_absorbed := 0.0
	if colony.roads.cell_count() > 0:
		var road_hit := DamageHit.area(
			colony.roads.world_point(colony.roads.cell_index_at(0)),
			MeepColony.ROAD_CLEAR_RADIUS, MeepColony.FELL_DAMAGE, 0.0)
		road_hit.affects_combatants = false
		road_absorbed = DamageHit.apply_to_fields(colony, road_hit)
	# Pick something that is observably still standing rather than a fixed point which
	# may now be part of the road from the ship.
	var control_at := Vector3.ZERO
	for field_variant: Variant in get_tree().get_nodes_in_group(
			DamageHit.FIELD_GROUP):
		var field := field_variant as Node
		if field == null or not field.has_method(&"standing") \
				or String(field.name).contains("Distant"):
			continue
		for stood: Transform3D in field.call(&"standing"):
			if stood.origin.distance_to(colony.combat_position()) < colony.claim_radius:
				control_at = stood.origin
				break
		if control_at != Vector3.ZERO:
			break
	var growing := 0.0
	if control_at != Vector3.ZERO:
		var control := DamageHit.area(control_at, span,
			MeepColony.FELL_DAMAGE, 0.0)
		control.affects_combatants = false
		growing = DamageHit.apply_to_fields(colony, control)
	var again := DamageHit.area(middle, span, MeepColony.FELL_DAMAGE, 0.0)
	again.affects_combatants = false
	var absorbed := DamageHit.apply_to_fields(colony, again)
	print("meep_test: clearing the building again cut %.0f of flora, the same"
		% absorbed + " volume by the ship cut %.0f" % growing)
	if growing <= 0.0:
		return # Nothing was sown near the town at all; the question is unanswerable.
	_expect(absorbed == 0.0,
		"a finished building has already cleared everything it stands on")
	_expect(road_absorbed == 0.0,
		"a completed road has already cleared everything growing through it")


func _check_town_snapshot(world: GameWorld, colony: MeepColony) -> void:
	var snapshot := world.meep_colonies().snapshot()
	if snapshot.is_empty():
		_expect(false, "the grown town is in the joiner snapshot")
		return
	var entry := snapshot[0] as Dictionary
	var built: PackedInt32Array = entry.get("structures", PackedInt32Array())
	var raised: PackedFloat32Array = entry.get("raised", PackedFloat32Array())
	var forms: PackedInt32Array = entry.get(
		"structure_forms", PackedInt32Array())
	var upgrades: PackedFloat32Array = entry.get(
		"structure_upgrades", PackedFloat32Array())
	var deeds: PackedInt32Array = entry.get("deeds", PackedInt32Array())
	var street_state: PackedInt32Array = entry.get("roads", PackedInt32Array())
	var road_widths: PackedInt32Array = entry.get(
		"road_widths", PackedInt32Array())
	var road_surfaces: PackedInt32Array = entry.get(
		"road_surfaces", PackedInt32Array())
	_expect(bool(entry.get("tier_space_full", false))
		== colony.tier_zero_space_exhausted(),
		"the joiner snapshot carries Tier 0's exhausted placement state")
	_expect(bool(entry.get("tier_complete", false)) == colony.tier_zero_full(),
		"the joiner snapshot carries Tier 0's completed state")
	_expect(built.size() == colony.structures.count() * 3,
		"the snapshot carries a kind and a corner for every structure")
	_expect(raised.size() == colony.structures.count(),
		"and how far along each of them is")
	_expect(forms.size() == colony.structures.count() * 4
		and upgrades.size() == colony.structures.count()
		and deeds == colony.deed_snapshot(),
		"additive snapshots carry floors, capacities, upgrades, and explicit deeds")
	# What a joiner does with it: a fresh set of structures rebuilt from the wire has
	# to stand in the same places as the ones it was told about.
	var copy := MeepStructures.new()
	copy.configure(colony.site, colony.grid, colony.claim, null, null)
	copy.apply_snapshot(built)
	copy.apply_progress(raised)
	copy.apply_form_snapshot(forms, upgrades)
	var moved := 0.0
	for index in copy.count():
		moved = maxf(moved,
			copy.at(index).local.distance_to(colony.structures.at(index).local))
	_expect(copy.count() == colony.structures.count() and moved < 0.001
		and copy.form_snapshot() == colony.structures.form_snapshot(),
		"a client rebuilds the same town and residential function from it")
	copy.free()
	_expect(street_state == colony.roads.snapshot(),
		"the joiner snapshot carries every completed road cell")
	var road_copy := MeepRoads.new()
	road_copy.configure(colony.site, colony.grid, colony.claim,
		null, null, colony.founded_seed)
	road_copy.apply_snapshot(street_state)
	road_copy.apply_width_snapshot(road_widths)
	road_copy.apply_surface_snapshot(road_surfaces)
	_expect(road_copy.snapshot() == street_state
		and road_copy.width_snapshot() == colony.roads.width_snapshot()
		and road_copy.surface_snapshot() == colony.roads.surface_snapshot()
		and road_copy.lamp_cells() == colony.roads.lamp_cells(),
		"a client rebuilds the same road surfaces, widths, network, and lights")
	road_copy.free()


# --- Captures ----------------------------------------------------------------

## Stages real resident rows on one clear patch for the two views that validate the
## creature itself. Expedition tests intentionally leave the first founders marked
## DEPARTED, so selecting "not dead" can point the camera at an invisible historical
## row. The simulation is paused only while these captures borrow live rows.
func _capture_meep_creatures(planet: Planet, player: OnlinePlayer,
		colony: MeepColony) -> void:
	var rows := PackedInt32Array()
	for index in colony.count():
		if bool(colony.call("_visible", index)):
			rows.push_back(index)
			if rows.size() == 12:
				break
	_expect(rows.size() >= 4,
		"renderer capture finds four live visible residents after founder departure")
	if rows.size() < 4:
		return

	var old_local := colony._local.duplicate()
	var old_heading := colony._heading.duplicate()
	var old_height := colony._height.duplicate()
	var old_state := colony._state.duplicate()
	var old_detail := colony._detail.duplicate()
	var old_job := colony._job.duplicate()
	var old_near := colony._near_squared.duplicate()
	var was_processing := colony.is_processing()
	var was_physics_processing := colony.is_physics_processing()
	colony.set_process(false)
	colony.set_physics_process(false)

	# Keep the lineup outside the colony ship's broad shadow at the town origin.
	var origin := _open_crowd_origin(colony, 24)
	var capture_states := PackedByteArray([
		MeepColony.State.IDLE,
		MeepColony.State.WALK,
		MeepColony.State.FLEE,
		MeepColony.State.WORK,
	])
	for index in colony.count():
		colony._detail[index] = MeepColony.Detail.COLD
	for slot in rows.size():
		var index := rows[slot]
		# Four residents across the camera and up to three rows deep.
		var at := origin + Vector2(
			(float(slot / 4) - 1.0) * 1.65,
			(float(slot % 4) - 1.5) * 1.35)
		var cell := colony.grid.cell_of(at)
		colony._local[index] = at
		colony._height[index] = colony.grid.walk_height_at(cell) \
			if colony.grid.has_walk_surface(cell) else colony.grid.height_at(cell)
		colony._heading[index] = Vector2.RIGHT
		colony._state[index] = capture_states[slot % capture_states.size()]
		colony._detail[index] = MeepColony.Detail.HOT if slot < 4 \
			else MeepColony.Detail.COLD
		colony._job[index] = 0
		if index < colony._near_squared.size():
			colony._near_squared[index] = 0.0

	var hidden_flora: Array[Node3D] = []
	for node in planet.find_children("*", "", true, false):
		if (node is GroundCover or node is FlowerTreeField) \
				and (node as Node3D).visible:
			var visual := node as Node3D
			visual.visible = false
			hidden_flora.push_back(visual)

	colony.call("_snap_render_poses")
	colony.call("_draw")
	var close_target := Vector3.ZERO
	for slot in 4:
		close_target += colony.meep_position(rows[slot])
	close_target /= 4.0
	await _showcase_shot(planet, player, close_target,
		5.2, 1.55, "meep_settlers_close", colony.site.east, 0.12)

	for row in rows:
		colony._detail[row] = MeepColony.Detail.HOT
	colony.call("_draw")
	var gameplay_target := Vector3.ZERO
	for row in rows:
		gameplay_target += colony.meep_position(row)
	gameplay_target /= float(rows.size())
	await _showcase_shot(planet, player, gameplay_target,
		17.0, 6.5, "meep_colony_gameplay", colony.site.east, 0.12)

	for visual in hidden_flora:
		if is_instance_valid(visual):
			visual.visible = true
	colony._local = old_local
	colony._heading = old_heading
	colony._height = old_height
	colony._state = old_state
	colony._detail = old_detail
	colony._job = old_job
	colony._near_squared = old_near
	colony.call("_snap_render_poses")
	colony.call("_draw")
	colony.set_process(was_processing)
	colony.set_physics_process(was_physics_processing)


## The views a number cannot answer: the settlers up close, the boundary they claimed,
## the cloner they built and the town from the distance it is played at.
func _capture(planet: Planet, player: OnlinePlayer,
		colony: MeepColony) -> void:
	if DisplayServer.get_name() == "headless":
		return

	# One resident per clip up close, then the same batched rows at play distance.
	await _capture_meep_creatures(planet, player, colony)

	var edges := colony.claim.border_edges()
	if not edges.is_empty():
		var post := (edges[0] + edges[1]) * 0.5
		_stand_facing(planet, player,
			planet.to_global(colony.site.point_at(post,
				colony.grid.height_at(colony.grid.cell_of(post)))), 4.0)
		player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
		for _frame in 30:
			await get_tree().process_frame
		await _shot("meep_boundary_close")

	# What they built, from the distance you would stand at to watch them build it.
	var cloner := colony.structures.nearest(
		MeepStructures.Kind.CLONER, Vector2.ZERO)
	if cloner >= 0:
		_stand_facing(planet, player, colony.structures.world_centre(cloner), 9.0)
		player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
		for _frame in 30:
			await get_tree().process_frame
		await _shot("meep_cloner")

	# Concrete in the middle, a dark edge on both sides, no grass growing through and
	# the simple pole-and-head lamps the paving crew leaves behind.
	var road_cell := -1
	if colony.roads.cell_count() > 0:
		road_cell = colony.roads.cell_index_at(
			colony.roads.cell_count() / 2)
		_stand_facing(planet, player, colony.roads.world_point(road_cell), 7.0)
		player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
		for _frame in 60:
			await get_tree().process_frame
		await _shot("meep_road_close")
	if road_cell >= 0:
		var cycle := planet.get_parent().find_child(
			"CelestialCycle", true, false) as CelestialCycle
		if cycle != null:
			cycle.period_seconds = 0.0
			cycle.set_phase(0.5)
			for _frame in 60:
				await get_tree().process_frame
			_expect(colony.roads.active_light_count() > 0
				and colony.roads.light_energy() > MeepRoads.LIGHT_ENERGY * 0.5,
				"street lights cast bright local light at night")
			await _shot("meep_street_lights")
			cycle.set_phase(0.0)
			for _frame in 45:
				await get_tree().process_frame
			_expect(colony.roads.light_energy() < 0.05,
				"street lights switch their physical light off in daylight")

	# The whole town, from above. The only view that shows how it grew — the cloner
	# nearest the lander, the houses filling in around it, the boundary out at the
	# chasm — and it needs its own camera: at head height in a metre of grass, a town
	# eighty metres away is grass.
	await _overhead(planet, colony, 96.0, 52.0, "meep_town")


## Looks down on the colony from [param up] metres up and [param away] metres out, with
## a camera of its own rather than the player's.
##
## The player's camera is on a spring arm behind their shoulders and pitched by the
## mouse, so an aerial framing cannot be asked of it without driving the input. This is a
## screenshot, so it borrows the viewport for one instead and gives it straight back.
func _overhead(planet: Planet, colony: MeepColony, away: float, up: float,
		shot_name: String) -> void:
	var centre := planet.to_global(colony.site.point_at(Vector2.ZERO,
		colony.ground_height_at(Vector2.ZERO)))
	var overhead := planet.to_local(centre).normalized()
	var side := colony.site.east
	var eye := planet.to_global(planet.to_local(centre)
		+ overhead * up + side * away)
	var camera := Camera3D.new()
	camera.name = "TownCamera"
	camera.far = 6000.0
	add_child(camera)
	camera.global_transform = Transform3D(
		Basis.looking_at(centre - eye, planet.global_basis * overhead), eye)
	var was := get_viewport().get_camera_3d()
	camera.make_current()
	# Long enough for the flora to have streamed to the new eye, which is what the
	# ground under a town looks like from up here.
	for _frame in 90:
		await get_tree().process_frame
	await _shot(shot_name)
	camera.queue_free()
	if is_instance_valid(was):
		was.make_current()


## Puts the player on the ground [param away] metres to one side of a target and
## turns them to look at it. Lifted from dev/_ability_shot.gd, which needs the same
## thing for the same reason: a shot of something on a sphere cannot be framed by
## typing a transform.
## A stand-in colonist who does not move, so [MeepColonies] keeps the town it is
## standing in fully simulated while a fixture inspects that town's rows, grid and
## roads. Freed together through [constant TEST_WATCHERS].
func _watcher_at(planet: Planet, direction: Vector3) -> Node3D:
	var stand_in := Node3D.new()
	stand_in.name = "MeepTestWatcher"
	planet.add_child(stand_in)
	stand_in.add_to_group(&"network_players")
	stand_in.add_to_group(TEST_WATCHERS)
	stand_in.global_position = planet.standing_position(
		direction.normalized(), 0.4)
	return stand_in


func _release_watchers() -> void:
	for stand_in in get_tree().get_nodes_in_group(TEST_WATCHERS):
		stand_in.queue_free()


func _stand_facing(planet: Planet, player: OnlinePlayer, target: Vector3,
		away: float) -> void:
	var direction := planet.to_local(target).normalized()
	var up := planet.global_basis * direction
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	var stand_at := (direction + planet.to_local(
		planet.global_position + side).normalized()
		* (away / planet.shape.radius)).normalized()
	player.global_transform = Transform3D(
		Basis.looking_at(-side, planet.global_basis * stand_at),
		planet.standing_position(stand_at, 0.4))
	player.velocity = Vector3.ZERO


func _shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	print("meep_test: %s %s" % [
		shot_name, "saved" if error == OK else error_string(error)])
	_expect(error == OK and image.get_width() >= 800 and image.get_height() >= 450,
		"capture %s saves at a useful rendered resolution" % shot_name)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("meep_test: PASS  ", message)
		return
	_failures += 1
	_failure_messages.push_back(message)
	push_error("meep_test: FAIL  %s" % message)
