class_name MeepRoads
extends Node3D

## The streets a colony has planned and finished.
##
## A road is a chain of the same two-metre cells Meeps already navigate. That makes
## routing, placement and replication bytes rather than geometry: completed cells set
## [constant MeepGrid.FLAG_ROAD], every flow field immediately values them at half the
## price of dirt, and a late joiner only needs their integer indices.
##
## The paving is two small meshes rebuilt only when a branch finishes. Their vertices
## sample the terrain itself, so the street lies on the ground rather than bridging its
## two-metre cells as a row of slabs. A dark, slightly wider ribbon sits under a warm
## concrete ribbon, leaving a black edge on both sides. Two more MultiMeshes hold every
## pole and emissive head, with a bounded real-light pool lent to the nearest ones at
## night. The chains are still free to bend diagonally around water, cliffs and
## buildings; the grid is a measuring tool, not a street layout.


class Segment extends RefCounted:
	## Structure this branch reaches. Host-side planning fact; clients only need cells.
	var subject := -1
	## Grid indices newly laid by this branch.
	var cells := PackedInt32Array()
	var progress := 0.0
	var job := 0
	var width_class := 0
	var surface_kind := 0
	var deck_heights := PackedFloat32Array()
	## Both the land approach and the elevated crossing count as one frontier project.
	## Routine structure roads may coexist; another surface planner must wait.
	var frontier_surface_project := false

	func built() -> bool:
		return progress >= 1.0


## Widths in metres. The lower ribbon showing around the upper one is the black edge.
const EDGE_WIDTH := 2.72
const ROAD_WIDTH := 2.16
## Ground cover asks completed road networks directly whether a deterministic plant
## root intersects paving. This keeps streamed and distant flora off roads before it is
## ever shown, instead of waiting for a player collision to remove it.
const FLORA_CLEARANCE_GROUP := &"flora_road_clearance_sources"
const FLORA_CLEAR_MARGIN := 0.24
const FLORA_CORNER_SCALE := 0.70710678
## Append-only replicated width classes. Existing Tier 0 streets retain class zero;
## later branches never rewrite their cells merely because a wider road meets them.
enum WidthClass {
	STREET,
	AVENUE,
	BOULEVARD,
	GRAND_BOULEVARD,
}
## Append-only surface values replicated beside the legacy land-cell snapshot.
enum SurfaceKind {
	LAND,
	BRIDGE,
	RAMP,
	DOCK,
}
const ROAD_WIDTHS := [ROAD_WIDTH, 3.6, 5.2, 7.2]
const EDGE_WIDTHS := [EDGE_WIDTH, 4.2, 5.8, 7.8]
const MAX_FLORA_CLEAR_RADIUS := 7.8 * FLORA_CORNER_SCALE + FLORA_CLEAR_MARGIN
## How many changed cells a scoped flora refresh will describe before it gives up
## and covers the whole town. A finished segment is a handful of cells; a restored
## snapshot is the entire network, and drawing a tight bound around that is both
## slower and no narrower than the town itself.
const CLEARANCE_SCOPE_CELLS := 96
## How many road cells the presentation step will measure ribbon geometry for in one
## frame. A grown town remeasuring its whole network after a ground rebake cost
## 40 ms in a single frame; four quiet frames are not noticeable and this is not.
const RIBBON_PATCHES_PER_FRAME := 72
## Measuring also stops here, whichever comes first. The count above is what makes a
## rebuild deterministic; this is what keeps one expensive cell — a bridge deck over
## a scarred slope — from carrying the whole budget past a frame.
const RIBBON_MEASURE_BUDGET_USEC := 1800
## And this is the ceiling for every town on the planet put together.
##
## The budget above describes one network measuring one of its two ribbon layers.
## Six towns are resident at once and they all remeasure after their ground is
## rebaked, so twelve individually reasonable budgets became twenty milliseconds of a
## single frame — the worst frames left once arriving in a city stopped stalling. A
## town refused here loses nothing: its network stays dirty and it measures on the
## next frame instead.
const RIBBON_MEASURE_FRAME_USEC := 2400
## How long every town on the planet together will spend hiding plants under its
## paving in one frame. A returning city restores its whole network at once, and
## covering every tile of every field for that took 170 ms held on the main thread.
## Shared rather than per town for the same reason as [constant
## RIBBON_MEASURE_FRAME_USEC]: six towns arriving at once each had one.
const CLEARANCE_FRAME_USEC := 1200
const SURFACE_COST_MULTIPLIERS := [1.0, 3.2, 2.7, 2.2]
const SURFACE_WORK_MULTIPLIERS := [1.0, 3.6, 3.0, 2.4]
const SURFACE_COLOURS := [
	Color(0.42, 0.415, 0.40),
	Color(0.32, 0.36, 0.41),
	Color(0.37, 0.38, 0.39),
	Color(0.34, 0.20, 0.09),
]
const MAX_RAMP_GRADE := 0.38
## Unsupported terrain searched from one bank. Broad hills need more than the old
## twenty-four cells: unlike a chasm, a steep region can cover most of a hillside.
const MAX_BRIDGE_CROSSING_CELLS := 48
## A ramp may begin on the lower flat and finish on the upper flat so its deck is
## actually walkable. This is deliberately larger than the unsupported search span.
const MAX_RAMP_SURFACE_CELLS := 96
const MIN_INTERNAL_CROSSING_CELLS := 3
const MIN_INTERNAL_BANK_SEPARATION_CELLS := 2
## A crossing that opens new territory always wins over one that merely closes an
## internal notch. The latter is still valuable once a border has grown around a
## hill, but must not starve the route that gets Meeps to its far side.
const INTERNAL_CROSSING_SCORE_PENALTY := 256.0
const CARDINAL_DIRECTIONS: Array[Vector2i] = [
	Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP,
]
const EDGE_LIFT := 0.028
const ROAD_LIFT := 0.058
## Work and biomass per newly paved two-metre cell. Roads should be real work without
## consuming the forest faster than the buildings they exist to connect.
const WORK_PER_CELL := 0.48
const COST_PER_CELL := 0.45
const CREW := 2

const EDGE_COLOUR := Color(0.018, 0.021, 0.025)
## The same warm paving albedo as RoadProfile. Neutral RGB turns blue under the landing
## site's sky; this is the grey that reads as concrete after its lighting.
const ROAD_COLOUR := Color(0.42, 0.415, 0.40)

## A paving crew finishes its branch with one lamp every five cells. Eligibility is a
## stable phase of the absolute cell index, so extending the road never removes a lamp
## already erected and a late joiner derives the same fixtures from the road snapshot.
const LAMP_STRIDE := 5
## Just outside the concrete and on the black kerb.
const LAMP_KERB := 1.22
const LAMP_POLE_RADIUS := 0.075
const LAMP_POLE_HEIGHT := 3.6
const LAMP_HEAD_RADIUS := 0.24
const LAMP_HEAD_HEIGHT := 0.24
const LAMP_POLE_COLOUR := Color(0.075, 0.082, 0.095)
const LAMP_HEAD_COLOUR := Color(1.0, 0.90, 0.64)
const LAMP_HEAD_DAY_EMISSION := 0.12
const LAMP_HEAD_NIGHT_EMISSION := 3.6

## Only the nearest fixtures own real lights. Forward Mobile drops excess omnis per
## rendered object, which made broad terrain patches exchange lights and flicker as
## their chunks changed while the player moved. Four leaves room for the planet's
## bounded flora/night pools; every other fixture remains visibly emissive.
const LIGHT_POOL := 4
const LIGHT_RANGE := 20.0
const LIGHT_ENERGY := 6.5
const LIGHTS_WITHIN := 105.0
## A retained pole may trail the exact nearest-set boundary by this many metres.
## Without hysteresis, equally distant fixtures exchanged pooled lights repeatedly.
const LIGHT_TARGET_HYSTERESIS := 8.0
const LIGHT_RETARGET_INTERVAL := 0.75
const COLLISION_WITHIN := 120.0
const DOCK_PILE_HALF_WIDTH := 0.13
const DOCK_PILE_SEABED_CLEARANCE := 0.05
const DOCK_PILE_TOP_INSET := 0.06
const DOCK_PILE_COLOUR := Color(0.18, 0.095, 0.035)

## Forward neighbour half of the eight-connected grid. Looking only at these avoids
## drawing every link twice.
const LINKS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(1, 1),
	Vector2i(1, -1),
]

const NEIGHBOURS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
	Vector2i(1, 1),
	Vector2i(-1, -1),
	Vector2i(1, -1),
	Vector2i(-1, 1),
]

## The two ribbons: the wider kerb underneath and the driving surface over it. The
## surface is also the collision source.
const RIBBON_EDGE := 0
const RIBBON_SURFACE := 1

var site: MeepSite
var grid: MeepGrid
var claim: MeepClaim

var _shape: PlanetShape
var _planet: Planet
var _seed := 0
var _segments: Array[Segment] = []
## Grid index to true. A dictionary gives constant membership while tracing and drawing.
var _built: Dictionary = {}
## Completed cell index to WidthClass. Missing means legacy STREET.
var _width_by_cell: Dictionary = {}
## Non-land cell metadata. Missing entries are legacy LAND at raw terrain height.
var _surface_by_cell: Dictionary = {}
var _deck_height_by_cell: Dictionary = {}
## Radius around the settlement centre that can never hold road cells. Set before
## snapshots are applied so old saves and late-join packets cannot restore paving
## beneath either kind of ship.
var _centre_exclusion_radius := 0.0
## Stable order for snapshots, rendering and the rolling flora-clear pass.
var _built_order := PackedInt32Array()
## Grid cell to the few completed road cells whose outer edge reaches it. GroundCover
## may ask about thousands of deterministic roots while raising one tile; indexing the
## footprint once keeps each answer a short lookup rather than a scan of the network.
var _flora_roads_by_cell: Dictionary = {}
## Ribbon geometry per built cell, one dictionary per layer, keyed by cell index.
##
## Every vertex of a road patch is a point on the height field, and reading the
## height field is what costs: four elevation samples per square, five squares per
## cell, two layers. Recomputing all of it because one segment finished cost 65 ms
## with the physics step held open, fifteen times over a thirty-second walk through
## a growing town. A cell's share cannot change unless it or a neighbour changed,
## so that ring is what [method _forget_ribbon_patches] drops.
var _ribbon_cache: Array[Dictionary] = [{}, {}]
## Cells whose geometry the draw in progress had to measure, and the microseconds it
## spent doing it. Diagnostic only, and the reason the draw reports two rows.
var _ribbon_measured := 0
var _ribbon_measure_usec := 0
## Terrain heights sampled for the layer being measured, keyed by local position, and
## whether one is being measured at all. See [method _corner_height].
var _corner_heights := {}
var _corner_memo := false
## Cells the crossing search reached, and frontier cells the shore walk stepped
## off. Diagnostic only; see [method next_surface_candidate].
var _flood_expanded := 0
var _shore_walked := 0
## Unsupported cell and bank cell in pairs, as [method _walk_surface_frontier]
## found them, for the crossing flood to start from. Kept rather than returned so
## that one scan of a large claim does not allocate a second array for them.
var _bridge_seeds := PackedInt32Array()
## Triangle numbering for an assembled ribbon, per layer. Depends on nothing but
## how many four-vertex squares the layer ended up with.
var _ribbon_indices: Array[PackedInt32Array] = [
	PackedInt32Array(), PackedInt32Array(),
]
var _edge: MeshInstance3D
var _surface: MeshInstance3D
var _deck_stands: Array[MeshInstance3D] = []
## One batched mesh for every deterministic dock pile, included in road collision.
var _dock_piles: MeshInstance3D
var _collision_body: StaticBody3D
var _collision_shape: CollisionShape3D
## Lamp geometry is two MultiMeshes no matter how large the town becomes.
var _poles: MultiMeshInstance3D
var _heads: MultiMeshInstance3D
var _head_material: StandardMaterial3D
var _lamp_cells := PackedInt32Array()
var _lamp_locals := PackedVector2Array()
var _lamp_slot_by_cell: Dictionary = {}
var _lights: Array[OmniLight3D] = []
## Stable road-cell indices rather than lamp slots: inserting a newly completed cell
## into the sorted lamp list must not make a live pooled light jump to another fixture.
var _light_targets: Array[int] = []
var _since_light_targets := INF
var _dirty := true
var _flora_refresh_queued := false
## Cells whose paving changed since the last flora refresh, and the flag that gives
## up on tracking them and re-tests the whole town instead.
var _clear_scope_cells: Dictionary = {}
var _clear_scope_everywhere := false
var _flora_index_stale := false
## Flora fields with clearance still to walk, and the tile the current one resumes
## at. See [method advance_flora_clearance].
var _clear_fields: Array[Node] = []
var _clear_cursor := 0
var _clear_restart := false
## False for local city blueprints: their paving is presentation only and must not
## hide live flora or join the planet-wide clearance work queue.
var _world_effects_enabled := true
## Ribbon measurement the planet's towns have spent this frame, and the frame that
## count belongs to. See [constant RIBBON_MEASURE_FRAME_USEC].
static var _measure_frame := -1
static var _measure_spent := 0
## The same, for hiding plants under paving. See [constant CLEARANCE_FRAME_USEC].
static var _clearance_frame := -1
static var _clearance_spent := 0


func _init() -> void:
	name = "Roads"


func _enter_tree() -> void:
	if _world_effects_enabled:
		add_to_group(FLORA_CLEARANCE_GROUP)


func configure(for_site: MeepSite, for_grid: MeepGrid, for_claim: MeepClaim,
		shape: PlanetShape, planet: Planet, colony_seed: int = 0,
		presentation := true, collisions := true,
		world_effects := true) -> void:
	site = for_site
	grid = for_grid
	claim = for_claim
	_shape = shape
	_planet = planet
	_seed = colony_seed
	_world_effects_enabled = world_effects
	if not _world_effects_enabled and is_in_group(FLORA_CLEARANCE_GROUP):
		remove_from_group(FLORA_CLEARANCE_GROUP)
	if presentation:
		_edge = _stand("RoadEdges", EDGE_COLOUR)
		_surface = _stand("RoadSurface", ROAD_COLOUR)
		for kind in range(SurfaceKind.BRIDGE, SurfaceKind.size()):
			_deck_stands.push_back(_stand(
				"Surface%d" % kind, SURFACE_COLOURS[kind]))
		_dock_piles = _stand("DockPiles", DOCK_PILE_COLOUR)
		_raise_lamp_stands()
		if _planet != null:
			_raise_light_pool()
	if collisions:
		_raise_collision()


## Establishes the ship footprint and migrates any already-loaded road state out of
## it. Segment indices stay stable because live road jobs address them directly; only
## their forbidden inner cells are removed.
func set_centre_exclusion_radius(radius: float) -> void:
	_centre_exclusion_radius = maxf(radius, 0.0)
	if grid == null:
		return
	for segment in _segments:
		var kept_cells := PackedInt32Array()
		var kept_heights := PackedFloat32Array()
		for slot in segment.cells.size():
			var cell_index := segment.cells[slot]
			if _cell_allowed(cell_index):
				kept_cells.push_back(cell_index)
				if segment.surface_kind != SurfaceKind.LAND:
					kept_heights.push_back(segment.deck_heights[slot] \
						if slot < segment.deck_heights.size() else 0.0)
				continue
			grid.set_flag(_cell(cell_index), MeepGrid.FLAG_RESERVED, false)
		segment.cells = kept_cells
		if segment.surface_kind != SurfaceKind.LAND:
			segment.deck_heights = kept_heights
	var dropped := PackedInt32Array()
	for index_variant: Variant in _built.keys():
		var cell_index := int(index_variant)
		if _cell_allowed(cell_index):
			continue
		grid.set_flag(_cell(cell_index), MeepGrid.FLAG_ROAD, false)
		grid.set_surface(_cell(cell_index), 0.0, false)
		_built.erase(cell_index)
		_width_by_cell.erase(cell_index)
		_surface_by_cell.erase(cell_index)
		_deck_height_by_cell.erase(cell_index)
		dropped.push_back(cell_index)
	_forget_ribbon_patches(dropped)
	_reorder_after_dropping(dropped)
	_dirty = true


func centre_exclusion_radius() -> float:
	return _centre_exclusion_radius


func has_cell(cell_index: int) -> bool:
	return _built.has(cell_index)


func _cell_allowed(cell_index: int) -> bool:
	if grid == null or cell_index < 0 \
			or cell_index >= grid.cells * grid.cells:
		return false
	var cell := _cell(cell_index)
	if not grid.region_buildable(cell) and not _built.has(cell_index):
		return false
	if grid.has_flag(cell, MeepGrid.FLAG_PARK) and not _built.has(cell_index):
		return false
	if grid.has_flag(cell, MeepGrid.FLAG_PLANNED_LOT) \
			and not _built.has(cell_index):
		return false
	if _centre_exclusion_radius <= 0.0:
		return true
	return grid.centre_of(cell).length_squared() \
		>= _centre_exclusion_radius * _centre_exclusion_radius


func _raise_collision() -> void:
	_collision_body = StaticBody3D.new()
	_collision_body.name = "RoadCollision"
	_collision_body.collision_layer = 1
	_collision_body.collision_mask = 0
	_collision_shape = CollisionShape3D.new()
	_collision_shape.shape = ConcavePolygonShape3D.new()
	_collision_body.add_child(_collision_shape)
	add_child(_collision_body)


func _stand(title: String, colour: Color) -> MeshInstance3D:
	var stand := MeshInstance3D.new()
	stand.name = title
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.92
	stand.material_override = material
	add_child(stand)
	return stand


func _raise_lamp_stands() -> void:
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = LAMP_POLE_RADIUS
	pole_mesh.bottom_radius = LAMP_POLE_RADIUS * 1.18
	pole_mesh.height = LAMP_POLE_HEIGHT
	pole_mesh.radial_segments = 8
	pole_mesh.rings = 0
	var pole_material := StandardMaterial3D.new()
	pole_material.albedo_color = LAMP_POLE_COLOUR
	pole_material.metallic = 0.55
	pole_material.roughness = 0.72
	pole_mesh.material = pole_material
	_poles = _lamp_stand("StreetLightPoles", pole_mesh)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = LAMP_HEAD_RADIUS
	head_mesh.bottom_radius = LAMP_HEAD_RADIUS
	head_mesh.height = LAMP_HEAD_HEIGHT
	head_mesh.radial_segments = 10
	head_mesh.rings = 0
	_head_material = StandardMaterial3D.new()
	_head_material.albedo_color = LAMP_HEAD_COLOUR * 0.72
	_head_material.roughness = 0.34
	_head_material.emission_enabled = true
	_head_material.emission = LAMP_HEAD_COLOUR
	_head_material.emission_energy_multiplier = LAMP_HEAD_DAY_EMISSION
	head_mesh.material = _head_material
	_heads = _lamp_stand("StreetLightHeads", head_mesh)
	_heads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _lamp_stand(title: String, mesh: Mesh) -> MultiMeshInstance3D:
	var stand := MultiMeshInstance3D.new()
	stand.name = title
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = mesh
	stand.multimesh = batch
	add_child(stand)
	return stand


func _raise_light_pool() -> void:
	for slot in LIGHT_POOL:
		var light := OmniLight3D.new()
		light.name = "StreetLight%d" % slot
		light.light_color = LAMP_HEAD_COLOUR
		light.light_energy = 0.0
		light.light_specular = 0.65
		light.omni_range = LIGHT_RANGE
		light.omni_attenuation = 1.0
		light.shadow_enabled = false
		light.visible = false
		add_child(light, false, Node.INTERNAL_MODE_BACK)
		_lights.append(light)
		_light_targets.append(-1)


# --- Planning ----------------------------------------------------------------

func count() -> int:
	return _segments.size()


func built_count() -> int:
	var found := 0
	for segment in _segments:
		if segment.built():
			found += 1
	return found


func segment_count_of(surface_kind: int, only_built := false) -> int:
	var found := 0
	for segment in _segments:
		if segment.surface_kind == surface_kind \
				and (segment.built() or not only_built):
			found += 1
	return found


func unfinished_count() -> int:
	return count() - built_count()


func has_unfinished_surface_project() -> bool:
	for segment in _segments:
		if segment.frontier_surface_project and not segment.built():
			return true
	return false


func cell_count() -> int:
	return _built_order.size()


func cell_index_at(slot: int) -> int:
	return _built_order[slot] if slot >= 0 and slot < _built_order.size() else -1


## The paved cells nearest a viewer on the site's flat map. Used to keep streamed grass
## from appearing through whichever piece of road somebody can actually inspect.
func nearest_cells(local: Vector2, limit: int) -> PackedInt32Array:
	var wanted := mini(maxi(limit, 0), _built_order.size())
	var out := PackedInt32Array()
	if wanted == 0:
		return out
	var ordered: Array[Vector2i] = []
	for index in _built_order:
		var away := grid.centre_of(_cell(index)).distance_squared_to(local)
		var entry := Vector2i(roundi(away * 100.0), index)
		var slot := 0
		while slot < ordered.size() and (
				ordered[slot].x < entry.x
				or (ordered[slot].x == entry.x
					and ordered[slot].y <= entry.y)):
			slot += 1
		if slot >= wanted and ordered.size() >= wanted:
			continue
		ordered.insert(slot, entry)
		if ordered.size() > wanted:
			ordered.pop_back()
	for slot in ordered.size():
		out.push_back(ordered[slot].y)
	return out


## A short connected route for an idle walk. Built once when the stroll starts rather
## than as a full cost field per Meep: each next cell is an existing street neighbour,
## so following the returned waypoints cannot cut across the blocks between them.
func stroll_path(from: Vector2, length: int, selector: int) -> PackedInt32Array:
	var path := PackedInt32Array()
	if grid == null or _built_order.is_empty() or length <= 0:
		return path
	var current := -1
	var nearest := INF
	for index in _built_order:
		var away := grid.centre_of(_cell(index)).distance_squared_to(from)
		if away < nearest:
			nearest = away
			current = index
	if current < 0:
		return path
	var previous := -1
	var seen: Dictionary = {}
	for turn in length:
		path.push_back(current)
		seen[current] = true
		var cell := _cell(current)
		var fresh: Array[int] = []
		var fallback: Array[int] = []
		for offset in NEIGHBOURS:
			var neighbour := cell + offset
			if not grid.inside(neighbour):
				continue
			var candidate := grid.index(neighbour)
			if not _built.has(candidate) or candidate == previous:
				continue
			fallback.push_back(candidate)
			if not seen.has(candidate):
				fresh.push_back(candidate)
		var choices := fresh if not fresh.is_empty() else fallback
		if choices.is_empty():
			if previous < 0:
				break
			var swap := current
			current = previous
			previous = swap
			continue
		choices.sort()
		var pick := posmod(selector + turn * 17, choices.size())
		previous = current
		current = choices[pick]
	return path


func at(index: int) -> Segment:
	return _segments[index] if index >= 0 and index < _segments.size() else null


func has_subject(subject: int) -> bool:
	for segment in _segments:
		if segment.subject == subject:
			return true
	return false


## Traces a structure doorway down the colony's shared asynchronous home field until
## it reaches the existing street network (or the ship for the first branch).
##
## One home field serves every structure. Baking a destination field per outer house
## worked for a twelve-building starter town, but road and building completions kept
## invalidating those fields faster than a mature town could bake them, leaving its last
## districts permanently disconnected.
func path_home_from(target: Vector2i, field: MeepFlowField) -> PackedInt32Array:
	var path := PackedInt32Array()
	if grid == null or claim == null or field == null \
			or not grid.passable(target) or not claim.contains_cell(target) \
			or not field.reachable(target):
		return path
	var seen: Dictionary = {}
	var current := target
	for _step in grid.cells * grid.cells:
		if not grid.inside(current) or not claim.contains_cell(current) \
				or not grid.passable(current):
			return PackedInt32Array()
		var index := grid.index(current)
		if seen.has(index):
			return PackedInt32Array()
		seen[index] = true
		if _built.has(index):
			return path
		if grid.has_flag(current, MeepGrid.FLAG_PARK):
			return PackedInt32Array()
		if grid.has_flag(current, MeepGrid.FLAG_PLANNED_LOT):
			return PackedInt32Array()
		if grid.has_flag(current, MeepGrid.FLAG_RESERVED):
			return PackedInt32Array()
		path.push_back(index)
		if current == field.target:
			return path
		var step := field.step_at(current)
		if step == Vector2i.ZERO:
			return PackedInt32Array()
		current += step
	return PackedInt32Array()


## Reserves a branch. An empty path still records that a structure already touches a
## street, preventing it from being reconsidered every planning pass.
func plan(subject: int, cells: PackedInt32Array,
		width_class := WidthClass.STREET,
		surface_kind := SurfaceKind.LAND,
		deck_heights: PackedFloat32Array = PackedFloat32Array(),
		frontier_surface_project := false) -> int:
	var segment := Segment.new()
	segment.subject = subject
	segment.width_class = clampi(width_class, 0, WidthClass.size() - 1)
	segment.surface_kind = clampi(
		surface_kind, SurfaceKind.LAND, SurfaceKind.DOCK)
	segment.frontier_surface_project = frontier_surface_project
	for slot in cells.size():
		var cell_index := cells[slot]
		if not _cell_allowed(cell_index):
			continue
		segment.cells.push_back(cell_index)
		if segment.surface_kind != SurfaceKind.LAND:
			segment.deck_heights.push_back(deck_heights[slot] \
				if slot < deck_heights.size() else 0.0)
	if segment.surface_kind != SurfaceKind.LAND \
			and segment.deck_heights.size() != segment.cells.size():
		segment.deck_heights.resize(segment.cells.size())
		for slot in segment.cells.size():
			segment.deck_heights[slot] = grid.height_at(
				_cell(segment.cells[slot]))
	segment.progress = 1.0 if segment.cells.is_empty() else 0.0
	_segments.push_back(segment)
	for index in segment.cells:
		grid.set_flag(_cell(index), MeepGrid.FLAG_RESERVED)
	return _segments.size() - 1


func cost_for(cells: PackedInt32Array,
		width_class := WidthClass.STREET,
		surface_kind := SurfaceKind.LAND) -> float:
	return cells.size() * COST_PER_CELL * width_multiplier(width_class) \
		* SURFACE_COST_MULTIPLIERS[clampi(
			surface_kind, SurfaceKind.LAND, SurfaceKind.DOCK)]


func work_for(cells: PackedInt32Array,
		width_class := WidthClass.STREET,
		surface_kind := SurfaceKind.LAND) -> float:
	return maxf(cells.size() * WORK_PER_CELL * width_multiplier(width_class)
		* SURFACE_WORK_MULTIPLIERS[clampi(
			surface_kind, SurfaceKind.LAND, SurfaceKind.DOCK)],
		WORK_PER_CELL)


static func width_class_for_tier(tier: int) -> int:
	return clampi(tier - 1, WidthClass.STREET, WidthClass.GRAND_BOULEVARD)


static func width_multiplier(width_class: int) -> float:
	return ROAD_WIDTHS[clampi(width_class, 0, ROAD_WIDTHS.size() - 1)] \
		/ ROAD_WIDTH


func road_width_at(cell_index: int) -> float:
	var width_class := int(_width_by_cell.get(
		cell_index, WidthClass.STREET))
	return ROAD_WIDTHS[clampi(width_class, 0, ROAD_WIDTHS.size() - 1)]


func width_class_at(cell_index: int) -> int:
	return clampi(int(_width_by_cell.get(
		cell_index, WidthClass.STREET)), 0, WidthClass.size() - 1)


func surface_kind_at(cell_index: int) -> int:
	return clampi(int(_surface_by_cell.get(
		cell_index, SurfaceKind.LAND)), SurfaceKind.LAND, SurfaceKind.DOCK)


func deck_height_at(cell_index: int) -> float:
	return float(_deck_height_by_cell.get(
		cell_index, grid.height_at(_cell(cell_index))))


## Built cells carrying an overlay rather than plain ground: the decks, ramps, and
## docks that make a cell walkable which the terrain alone would refuse. These are
## the only road cells that can change a claim, so [method MeepClaim.repair] takes
## them as its seeds instead of the boundary being flooded again from scratch.
func constructed_surface_cells() -> PackedInt32Array:
	var found := PackedInt32Array()
	for index in _built_order:
		if surface_kind_at(index) != SurfaceKind.LAND:
			found.push_back(index)
	return found


func surface_cell_count(kind: int) -> int:
	var found := 0
	for index in _built_order:
		if surface_kind_at(index) == kind:
			found += 1
	return found


## Deterministic shortest unsupported crossing from the connected claim frontier.
## The caller may first pave `start` back to the existing network, then submit the
## returned non-land cells as one ordinary Meep road job.
func next_surface_candidate(allow_bridges: bool,
		allow_coasts: bool) -> Dictionary:
	if grid == null or claim == null:
		return {}
	# Both halves of the scan, with how much ground each one covered. They fail
	# differently: the flood is a search over the land inside the claim and grows with
	# the crevasses in it, and the shore walk is one step off every frontier cell.
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	var shore := _walk_surface_frontier(allow_bridges, allow_coasts)
	if began > 0:
		RuntimeTelemetry.record_activity(&"roads", &"surface_shore",
			Time.get_ticks_usec() - began, float(_shore_walked))
	began = Time.get_ticks_usec() if began > 0 else 0
	_flood_expanded = 0
	var best: Dictionary = _bridge_candidate_from_seeds(_bridge_seeds) \
		if allow_bridges else {}
	if began > 0:
		RuntimeTelemetry.record_activity(&"roads", &"surface_flood",
			Time.get_ticks_usec() - began, float(_flood_expanded))
	# The crossing the flood found is preferred where the two tie, which is what
	# the separate passes did when the shore walk started from its score.
	if not shore.is_empty() and _surface_candidate_score(shore) \
			< _surface_candidate_score(best):
		return shore
	return best


## One pass over the claim's frontier for both kinds of surface project.
##
## Bridges want the unclaimed void or steep ground a frontier cell backs onto;
## docks want the claimed shallow water it backs onto. Those are two answers to
## the same question about the same four neighbours of the same eleven hundred
## cells, and asking it twice — through the grid's and the claim's bounds-checked
## accessors both times — was the sixteen milliseconds a growing coastal town
## dropped on the frame that widened its boundary. Returns the best dock and
## leaves the bridge seeds in [member _bridge_seeds].
##
## The reads are inlined against the terrain, flag and claim bytes rather than
## made through [method MeepGrid.passable] and friends, because at four thousand
## neighbours the bounds check and the call are the whole cost.
func _walk_surface_frontier(allow_bridges: bool,
		allow_coasts: bool) -> Dictionary:
	_bridge_seeds.clear()
	_shore_walked = 0
	var span := grid.cells
	var terrain := grid.terrain
	var flags := grid.flags
	var claimed := claim.claimed_mask()
	var blocked := MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_SHIP
	var best: Dictionary = {}
	var best_score := INF
	for start_index: int in claim.surface_frontier_cells():
		_shore_walked += 1
		var start_flags := flags[start_index]
		if (start_flags & blocked) != 0:
			continue
		if terrain[start_index] != MeepGrid.Terrain.PASSABLE \
				and (start_flags & MeepGrid.FLAG_SURFACE) == 0:
			continue
		var x := start_index % span
		var y := start_index / span
		for direction: Vector2i in CARDINAL_DIRECTIONS:
			var at_x := x + direction.x
			var at_y := y + direction.y
			if at_x < 0 or at_y < 0 or at_x >= span or at_y >= span:
				continue
			var at := at_y * span + at_x
			var kind := terrain[at]
			var at_flags := flags[at]
			if claimed[at] == 0:
				if not allow_bridges:
					continue
				if kind != MeepGrid.Terrain.VOID \
						and kind != MeepGrid.Terrain.STEEP:
					continue
				_bridge_seeds.push_back(at)
				_bridge_seeds.push_back(start_index)
				continue
			if not allow_coasts or kind != MeepGrid.Terrain.SHALLOW:
				continue
			# Shallow water is only walkable once something has been built on it,
			# and a deck a ship or a building is sitting on is not a candidate.
			if (at_flags & MeepGrid.FLAG_SURFACE) != 0 \
					and (at_flags & blocked) == 0:
				continue
			var candidate := _dock_candidate(Vector2i(x, y), direction)
			if candidate.is_empty():
				continue
			var score := _surface_candidate_score(candidate)
			if score < best_score:
				best_score = score
				best = candidate
	return best


func _surface_candidate_score(candidate: Dictionary) -> float:
	if candidate.is_empty():
		return INF
	var cells: PackedInt32Array = candidate["cells"]
	var start: Vector2i = candidate["start"]
	return float(cells.size()) \
		+ (0.0 if bool(candidate.get("opens_frontier", true))
			else INTERNAL_CROSSING_SCORE_PENALTY) \
		+ (0.0 if grid.has_flag(
			start, MeepGrid.FLAG_ROAD) else 64.0) \
		+ float(grid.index(start)) * 0.000001


## The crossing search on its own, for a caller that wants a bridge without the
## dock half of the scan.
func _frontier_bridge_candidate() -> Dictionary:
	if grid == null or claim == null:
		return {}
	_walk_surface_frontier(true, false)
	return _bridge_candidate_from_seeds(_bridge_seeds)


## Finds a shortest connected deck through an irregular crevasse. A four-way
## multi-source flood starts at every claimed rim cell, so the result can bend
## around a sampled rock tooth instead of requiring two perfectly aligned banks.
##
## `seeds` is unsupported-cell and bank-cell indices in pairs, as
## [method _walk_surface_frontier] gathered them. A cell reachable from two banks
## keeps the first. New land is preferred; once growth has gone around a hill,
## sufficiently separated sources may still close the internal notch with a deck.
func _bridge_candidate_from_seeds(seeds: PackedInt32Array) -> Dictionary:
	var total := grid.cells * grid.cells
	var parent := PackedInt32Array()
	var source := PackedInt32Array()
	var depth := PackedByteArray()
	parent.resize(total)
	source.resize(total)
	depth.resize(total)
	parent.fill(-2)
	source.fill(-1)
	var queue := PackedInt32Array()
	var seed_at := 0
	while seed_at + 1 < seeds.size():
		var first_index := seeds[seed_at]
		var bank_index := seeds[seed_at + 1]
		seed_at += 2
		if parent[first_index] != -2:
			continue
		parent[first_index] = -1
		source[first_index] = bank_index
		depth[first_index] = 1
		queue.push_back(first_index)
	var best: Dictionary = {}
	var best_score := INF
	var head := 0
	while head < queue.size():
		var current := queue[head]
		head += 1
		# Nothing reachable from here can beat what is already held.
		#
		# A crossing scores by how many cells it spans, and the shortest path to any
		# cell of this flood is the depth it was reached at, so the depth of the cell
		# being expanded is a floor under every crossing that could still be found
		# through it. The queue comes out in depth order, which makes this the end of
		# the search rather than the end of one branch. Without it the flood ran to
		# its full twenty-four-cell reach across the whole claim and built a candidate
		# — a path walk, an array, and a height per cell — at every bank it touched on
		# the way, which is how one scan of a coastal town reached thirty milliseconds.
		if float(int(depth[current])) >= best_score:
			break
		var cell := _cell(current)
		for direction in CARDINAL_DIRECTIONS:
			var neighbour := cell + direction
			if not grid.inside(neighbour) \
					or grid.centre_of(neighbour).length() > claim.radius:
				continue
			var terrain := grid.terrain_at(neighbour)
			if terrain == MeepGrid.Terrain.PASSABLE:
				var endpoint_index := grid.index(neighbour)
				var returns_to_source := endpoint_index == source[current]
				var endpoint_claimed := claim.contains_cell(neighbour)
				if returns_to_source or (endpoint_claimed \
						and (int(depth[current]) < MIN_INTERNAL_CROSSING_CELLS
							or _bank_separation(
								_cell(source[current]), neighbour)
								< MIN_INTERNAL_BANK_SEPARATION_CELLS)):
					continue
				var candidate := _bridge_candidate_from_flood(
					current, neighbour, parent, source)
				if not candidate.is_empty():
					candidate["opens_frontier"] = not endpoint_claimed
				var score := _surface_candidate_score(candidate)
				if score < best_score:
					best = candidate
					best_score = score
				continue
			if terrain != MeepGrid.Terrain.VOID \
					and terrain != MeepGrid.Terrain.STEEP:
				continue
			var neighbour_index := grid.index(neighbour)
			if parent[neighbour_index] != -2:
				var other_source := source[neighbour_index]
				if other_source != source[current] \
						and _bank_separation(
							_cell(source[current]), _cell(other_source)) \
							>= MIN_INTERNAL_BANK_SEPARATION_CELLS \
						and int(depth[current]) + int(depth[neighbour_index]) \
							<= MAX_BRIDGE_CROSSING_CELLS:
					var joined := _bridge_candidate_from_flood_join(
						current, neighbour_index, parent, source)
					var joined_score := _surface_candidate_score(joined)
					if joined_score < best_score:
						best = joined
						best_score = joined_score
				continue
			if int(depth[current]) >= MAX_BRIDGE_CROSSING_CELLS:
				continue
			parent[neighbour_index] = current
			source[neighbour_index] = source[current]
			depth[neighbour_index] = depth[current] + 1
			queue.push_back(neighbour_index)
			_flood_expanded += 1
	return best


func _bridge_candidate_from_flood(last: int, endpoint: Vector2i,
		parent: PackedInt32Array, source: PackedInt32Array) -> Dictionary:
	var reversed := PackedInt32Array()
	var cursor := last
	while cursor >= 0:
		reversed.push_back(cursor)
		cursor = parent[cursor]
	var cells := PackedInt32Array()
	for slot in range(reversed.size() - 1, -1, -1):
		cells.push_back(reversed[slot])
	return _bridge_candidate_for_cells(
		_cell(source[last]), endpoint, cells)


func _bridge_candidate_from_flood_join(left: int, right: int,
		parent: PackedInt32Array, source: PackedInt32Array) -> Dictionary:
	var left_reversed := PackedInt32Array()
	var cursor := left
	while cursor >= 0:
		left_reversed.push_back(cursor)
		cursor = parent[cursor]
	var cells := PackedInt32Array()
	for slot in range(left_reversed.size() - 1, -1, -1):
		cells.push_back(left_reversed[slot])
	cursor = right
	while cursor >= 0:
		cells.push_back(cursor)
		cursor = parent[cursor]
	if cells.size() < MIN_INTERNAL_CROSSING_CELLS \
			or cells.size() > MAX_BRIDGE_CROSSING_CELLS:
		return {}
	var candidate := _bridge_candidate_for_cells(
		_cell(source[left]), _cell(source[right]), cells)
	if not candidate.is_empty():
		candidate["opens_frontier"] = false
	return candidate


func _bank_separation(first: Vector2i, second: Vector2i) -> int:
	return absi(first.x - second.x) + absi(first.y - second.y)


func _bridge_candidate_for_cells(start: Vector2i, endpoint: Vector2i,
		cells: PackedInt32Array) -> Dictionary:
	if start == endpoint or cells.is_empty():
		return {}
	var saw_steep := false
	var heights := PackedFloat32Array()
	for slot in cells.size():
		saw_steep = saw_steep \
			or grid.terrain_at(_cell(cells[slot])) == MeepGrid.Terrain.STEEP
	if _surface_grade(start, endpoint, cells.size()) > MAX_RAMP_GRADE:
		var extended := _extend_surface_for_grade(start, endpoint, cells)
		if extended.is_empty():
			return {}
		start = extended["start"]
		endpoint = extended["endpoint"]
		cells = extended["cells"]
	var start_height := _bank_height(start)
	var end_height := _bank_height(endpoint)
	for slot in cells.size():
		heights.push_back(lerpf(start_height, end_height,
			float(slot + 1) / float(cells.size() + 1)))
	return {
		"start": start,
		"endpoint": endpoint,
		"cells": cells,
		"heights": heights,
		"surface_kind": SurfaceKind.RAMP if saw_steep else SurfaceKind.BRIDGE,
	}


## Extends a crossing onto ordinary ground until its deck is no steeper than a
## Meep-safe ramp. A real hill classified STEEP is, by definition, steeper than
## the old direct deck limit; requiring the deck to begin and end exactly at the
## steep cells therefore rejected every sustained natural slope. Flat approaches
## provide the missing run without changing which obstacle is crossed.
func _extend_surface_for_grade(start: Vector2i, endpoint: Vector2i,
		cells: PackedInt32Array) -> Dictionary:
	if cells.is_empty():
		return {}
	var first := _cell(cells[0])
	var last := _cell(cells[cells.size() - 1])
	var into := first - start
	var out := endpoint - last
	if absi(into.x) + absi(into.y) != 1 \
			or absi(out.x) + absi(out.y) != 1:
		return {}
	var extended := cells.duplicate()
	var new_start := start
	var new_endpoint := endpoint
	var occupied: Dictionary = {
		grid.index(start): true,
		grid.index(endpoint): true,
	}
	for cell_index in cells:
		occupied[cell_index] = true
	var prefer_start := true
	while _surface_grade(
			new_start, new_endpoint, extended.size()) > MAX_RAMP_GRADE:
		if extended.size() >= MAX_RAMP_SURFACE_CELLS:
			return {}
		var before := new_start - into
		var after := new_endpoint + out
		var before_ok := _ramp_anchor_available(before, true, occupied)
		var after_ok := _ramp_anchor_available(after, false, occupied)
		if not before_ok and not after_ok:
			return {}
		var use_before := before_ok and not after_ok
		if before_ok and after_ok:
			var before_grade := _surface_grade(
				before, new_endpoint, extended.size() + 1)
			var after_grade := _surface_grade(
				new_start, after, extended.size() + 1)
			if is_equal_approx(before_grade, after_grade):
				use_before = prefer_start
			else:
				use_before = before_grade < after_grade
		if use_before:
			extended.insert(0, grid.index(new_start))
			occupied[grid.index(new_start)] = true
			new_start = before
		else:
			extended.push_back(grid.index(new_endpoint))
			occupied[grid.index(new_endpoint)] = true
			new_endpoint = after
		prefer_start = not prefer_start
	return {
		"start": new_start,
		"endpoint": new_endpoint,
		"cells": extended,
	}


func _ramp_anchor_available(cell: Vector2i, must_be_claimed: bool,
		occupied: Dictionary) -> bool:
	if not grid.inside(cell) \
			or grid.centre_of(cell).length() > claim.radius \
			or grid.terrain_at(cell) != MeepGrid.Terrain.PASSABLE:
		return false
	var cell_index := grid.index(cell)
	if occupied.has(cell_index) or not _cell_allowed(cell_index):
		return false
	var blocked := MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_SHIP \
		| MeepGrid.FLAG_RESERVED
	if (grid.flags[cell_index] & blocked) != 0:
		return false
	return not must_be_claimed or claim.contains_cell(cell)


func _surface_grade(start: Vector2i, endpoint: Vector2i,
		surface_cells: int) -> float:
	var run := float(surface_cells + 1) * grid.cell_size
	return absf(_bank_height(endpoint) - _bank_height(start)) \
		/ maxf(run, 0.001)


func _bank_height(cell: Vector2i) -> float:
	var height := grid.walk_height_at(cell)
	return height - ROAD_LIFT if grid.has_walk_surface(cell) else height


func _bridge_candidate(start: Vector2i, direction: Vector2i) -> Dictionary:
	# Forty-eight two-metre cells cover broad authored hills while keeping crossing
	# work and the frontier search strictly bounded.
	var cells := PackedInt32Array()
	var endpoint := start
	for step in range(1, MAX_BRIDGE_CROSSING_CELLS + 2):
		var cell := start + direction * step
		if not grid.inside(cell) \
				or grid.centre_of(cell).length() > claim.radius:
			return {}
		var terrain := grid.terrain_at(cell)
		if terrain == MeepGrid.Terrain.VOID \
				or terrain == MeepGrid.Terrain.STEEP:
			if step > MAX_BRIDGE_CROSSING_CELLS:
				return {}
			cells.push_back(grid.index(cell))
			continue
		if terrain != MeepGrid.Terrain.PASSABLE or cells.is_empty() \
				or claim.contains_cell(cell):
			return {}
		endpoint = cell
		break
	if endpoint == start:
		return {}
	return _bridge_candidate_for_cells(start, endpoint, cells)


func _dock_candidate(start: Vector2i, direction: Vector2i) -> Dictionary:
	const DOCK_RUN := 6
	var cells := PackedInt32Array()
	var heights := PackedFloat32Array()
	for step in range(1, DOCK_RUN + 1):
		var cell := start + direction * step
		if not grid.inside(cell) \
				or grid.centre_of(cell).length() > claim.radius \
						or grid.terrain_at(cell) != MeepGrid.Terrain.SHALLOW \
						or not claim.contains_cell(cell):
			break
		cells.push_back(grid.index(cell))
		# Water level is zero in PlanetShape coordinates. A small lift keeps the
		# visible/collidable deck above wave z-fighting.
		heights.push_back(0.12)
	if cells.size() < 3:
		return {}
	var platform := PackedInt32Array()
	var endpoint := Vector2i(-1, -1)
	for end_slot in range(cells.size() - 1, 1, -1):
		var centre := _cell(cells[end_slot])
		var fits := true
		var wanted := PackedInt32Array()
		for x in range(-1, 2):
			for y in range(-1, 2):
				var cell := centre + Vector2i(x, y)
				if not grid.inside(cell) \
						or grid.terrain_at(cell) != MeepGrid.Terrain.SHALLOW \
						or not claim.contains_cell(cell) \
						or grid.centre_of(cell).length() > claim.radius:
					fits = false
					break
				wanted.push_back(grid.index(cell))
			if not fits:
				break
		if fits:
			endpoint = centre
			platform = wanted
			cells.resize(end_slot + 1)
			heights.resize(end_slot + 1)
			break
	if endpoint.x < 0:
		return {}
	for index in platform:
		if not cells.has(index):
			cells.push_back(index)
			heights.push_back(0.12)
	return {
		"start": start,
		"endpoint": endpoint,
		"cells": cells,
		"heights": heights,
		"surface_kind": SurfaceKind.DOCK,
	}


func advance(index: int, seconds: float) -> bool:
	var segment := at(index)
	if segment == null or segment.built():
		return false
	segment.progress = clampf(segment.progress
		+ seconds / work_for(segment.cells, segment.width_class,
			segment.surface_kind), 0.0, 1.0)
	return segment.built()


## Commits the reserved cells to the street map.
func complete(index: int) -> PackedInt32Array:
	var segment := at(index)
	if segment == null:
		return PackedInt32Array()
	segment.progress = 1.0
	# Separate lists because the two indices are invalidated by different things:
	# the ribbon by any change to a cell, the clearance footprint only by a cell
	# that was not road before. Restamping a footprint this segment already owns
	# would leave the same road in the list twice.
	var touched := PackedInt32Array()
	var laid := PackedInt32Array()
	for slot in segment.cells.size():
		var at_index := segment.cells[slot]
		var cell := _cell(at_index)
		grid.set_flag(cell, MeepGrid.FLAG_RESERVED, false)
		if not _cell_allowed(at_index):
			continue
		if not _built.has(at_index):
			laid.push_back(at_index)
		touched.push_back(at_index)
		_built[at_index] = true
		if not _width_by_cell.has(at_index):
			_width_by_cell[at_index] = segment.width_class
		if segment.surface_kind != SurfaceKind.LAND:
			var height := segment.deck_heights[slot]
			_surface_by_cell[at_index] = segment.surface_kind
			_deck_height_by_cell[at_index] = height
			grid.set_surface(cell, height + ROAD_LIFT)
		grid.set_flag(cell, MeepGrid.FLAG_ROAD)
	_forget_ribbon_patches(touched)
	_reorder_after_adding(laid)
	# Left for the presentation step, which draws this network every frame anyway.
	# Redrawing here put the whole ribbon, its collision mesh and its lamps inside
	# the settler's simulation tick — ten milliseconds of the physics step, for
	# geometry that would have been rebuilt a few milliseconds later regardless.
	# What a Meep needs to walk the new cell is the grid flag set above.
	_dirty = true
	_queue_flora_clearance_refresh(touched)
	return segment.cells.duplicate()


func _cell(index: int) -> Vector2i:
	return Vector2i(index % grid.cells, index / grid.cells)


func _reorder() -> void:
	_sort_built()
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_rebuild_flora_clearance_index()
	_trace(&"reorder_clearance", began)
	_replan_lamps()


## Reorders after [param added] cells became road and nothing else changed.
##
## The clearance index is additive: a new road cell can only put itself into the
## list of the few cells its edge reaches. Restamping the whole network for that
## cost 30 ms on the physics thread in a mature town, once per finished segment.
func _reorder_after_adding(added: PackedInt32Array) -> void:
	_sort_built()
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_index_flora_clearance(added)
	_trace(&"reorder_clearance", began)
	_replan_lamps()


## Reorders after [param dropped] cells stopped being road and nothing else changed.
##
## Withdrawing a cell's footprint is the exact inverse of stamping it, and reaches
## the same short list of cells. Restamping the network instead cost 18 ms every
## time a rebaked town re-established its ship plaza.
func _reorder_after_dropping(dropped: PackedInt32Array) -> void:
	_sort_built()
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_unindex_flora_clearance(dropped)
	_trace(&"reorder_clearance", began)
	_replan_lamps()


func _sort_built() -> void:
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	var ordered: Array[int] = []
	for index_variant: Variant in _built:
		ordered.push_back(int(index_variant))
	ordered.sort()
	_built_order = PackedInt32Array(ordered)
	_trace(&"reorder_sort", began)


func _replan_lamps() -> void:
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_rebuild_lamp_plan()
	_trace(&"reorder_lamps", began)


## [param amount] is how much work the step found to do — cells measured, patches
## assembled — because a row that only carries milliseconds cannot say whether a slow
## draw measured too much ground or simply had too much of it to put together.
func _trace(label: StringName, began: int, amount := 0.0) -> void:
	if began > 0:
		RuntimeTelemetry.record_activity(
			&"roads", label, Time.get_ticks_usec() - began, amount)


## Marks the whole clearance footprint stale without paying for it yet.
##
## A city returning from its ledger applies its streets, then their widths, then
## their surfaces, and each of the three invalidates the same index. Restamping the
## network once per sidecar cost three walks of a grown town in a single tick.
func _rebuild_flora_clearance_index() -> void:
	_flora_index_stale = true


## Restamps the footprint if a snapshot invalidated it, before anything reads it.
func _ensure_flora_clearance_index() -> void:
	if not _flora_index_stale:
		return
	_flora_index_stale = false
	_flora_roads_by_cell.clear()
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_index_flora_clearance(_built_order)
	_trace(&"restamp_clearance", began)


## Records that each of [param road_cells] clears flora out to its own edge, for
## every grid cell that edge reaches.
func _index_flora_clearance(road_cells: PackedInt32Array) -> void:
	# A pending restamp will cover these cells along with every other, so adding
	# them now would only be undone.
	if grid == null or _flora_index_stale:
		return
	# Grid arithmetic is inlined and the bounds are clamped up front rather than
	# tested per square. Restamping a grown town visits a hundred thousand candidate
	# squares, and three script calls apiece was most of the 58 ms this took on the
	# main thread. Only the separation between two centres matters, and the grid's
	# own origin cancels out of that, so the cell size is all this needs.
	var across := grid.cells
	var metres := grid.cell_size
	var half_cell := metres * 0.5
	for road_index in road_cells:
		var surface_kind := surface_kind_at(road_index)
		if surface_kind == SurfaceKind.BRIDGE or surface_kind == SurfaceKind.DOCK:
			continue
		var road_x := road_index % across
		var road_y := road_index / across
		var clear_radius: float = EDGE_WIDTHS[width_class_at(road_index)] \
			* FLORA_CORNER_SCALE + FLORA_CLEAR_MARGIN
		var reach_squared := clear_radius * clear_radius
		var span := ceili(clear_radius / metres) + 1
		var last_x := mini(road_x + span, across - 1)
		var last_y := mini(road_y + span, across - 1)
		for y in range(maxi(road_y - span, 0), last_y + 1):
			var away_y := maxf(absf(float(y - road_y) * metres) - half_cell, 0.0)
			var row := y * across
			for x in range(maxi(road_x - span, 0), last_x + 1):
				var away_x := maxf(
					absf(float(x - road_x) * metres) - half_cell, 0.0)
				if away_x * away_x + away_y * away_y > reach_squared:
					continue
				var candidate_index := row + x
				var roads: PackedInt32Array = _flora_roads_by_cell.get(
					candidate_index, PackedInt32Array())
				roads.push_back(road_index)
				_flora_roads_by_cell[candidate_index] = roads


## Withdraws each of [param road_cells] from every cell its edge could have reached.
##
## The widest edge in the game decides how far to look rather than the cell's own,
## because a cell that has just stopped being road no longer remembers what width it
## was stamped at. Erasing an entry that was never there costs nothing, and the
## alternative is restamping the whole network to remove a handful of squares.
func _unindex_flora_clearance(road_cells: PackedInt32Array) -> void:
	if grid == null or _flora_index_stale or road_cells.is_empty():
		return
	var span := ceili(MAX_FLORA_CLEAR_RADIUS / grid.cell_size) + 1
	for road_index in road_cells:
		var road_cell := _cell(road_index)
		for x in range(road_cell.x - span, road_cell.x + span + 1):
			for y in range(road_cell.y - span, road_cell.y + span + 1):
				var candidate := Vector2i(x, y)
				if not grid.inside(candidate):
					continue
				var candidate_index := grid.index(candidate)
				var listed: Variant = _flora_roads_by_cell.get(candidate_index)
				if not listed is PackedInt32Array:
					continue
				var roads := listed as PackedInt32Array
				var slot := roads.find(road_index)
				if slot < 0:
					continue
				roads.remove_at(slot)
				if roads.is_empty():
					_flora_roads_by_cell.erase(candidate_index)
				else:
					_flora_roads_by_cell[candidate_index] = roads


## Derives every fixture from completed cells alone. The seed only chooses which one of
## each five-cell run receives it; no lamp positions need their own network payload.
func _rebuild_lamp_plan() -> void:
	_lamp_cells.clear()
	_lamp_locals.clear()
	_lamp_slot_by_cell.clear()
	if grid == null or site == null:
		return
	var phase := posmod(_seed, LAMP_STRIDE)
	for index in _built_order:
		if posmod(index + phase, LAMP_STRIDE) != 0:
			continue
		_lamp_slot_by_cell[index] = _lamp_cells.size()
		_lamp_cells.push_back(index)
		_lamp_locals.push_back(_lamp_local(index))


func _lamp_local(index: int) -> Vector2:
	var cell := _cell(index)
	var along := _road_axis(cell)
	var side := Vector2(-along.y, along.x)
	var positive := _side_cost(cell, side)
	var negative := _side_cost(cell, -side)
	if negative < positive or (negative == positive
			and posmod(floori(float(index) / float(LAMP_STRIDE)) + _seed, 2) != 0):
		side = -side
	return grid.centre_of(cell) + side * (
		road_width_at(index) * 0.5 + (LAMP_KERB - ROAD_WIDTH * 0.5))


## An undirected road axis. Preferring complete opposite pairs keeps an existing lamp
## from rotating when the next branch merely extends the straight it already stands on.
func _road_axis(cell: Vector2i) -> Vector2:
	for along: Vector2i in [
			Vector2i(1, 0), Vector2i(0, 1),
			Vector2i(1, 1), Vector2i(1, -1)]:
		if _road_neighbour(cell, along) and _road_neighbour(cell, -along):
			return Vector2(along).normalized()
	for offset in NEIGHBOURS:
		if _road_neighbour(cell, offset):
			return Vector2(offset).normalized()
	return Vector2.RIGHT


func _road_neighbour(cell: Vector2i, offset: Vector2i) -> bool:
	var neighbour := cell + offset
	return grid.inside(neighbour) and _built.has(grid.index(neighbour))


## Buildings, the boundary and another strip of road are successively worse kerbs. A
## deterministic tie alternates sides so a straight does not become a row of fenceposts.
func _side_cost(cell: Vector2i, side: Vector2) -> int:
	var neighbour := cell + Vector2i(roundi(side.x), roundi(side.y))
	if not grid.inside(neighbour):
		return 1000
	var cost := 0
	if claim != null and not claim.contains_cell(neighbour):
		cost += 500
	if grid.has_flag(neighbour, MeepGrid.FLAG_BUILDING) \
			or grid.has_flag(neighbour, MeepGrid.FLAG_SHIP):
		cost += 200
	if grid.has_flag(neighbour, MeepGrid.FLAG_RESERVED):
		cost += 40
	if grid.has_flag(neighbour, MeepGrid.FLAG_ROAD):
		cost += 12
	return cost


# --- Ground and presentation -------------------------------------------------

## World point at the centre of one paved cell, used by the flora clear pass.
func world_point(index: int) -> Vector3:
	if index < 0 or grid == null or site == null or _planet == null:
		return Vector3.ZERO
	var local := grid.centre_of(_cell(index))
	return _planet.to_global(_point(local, 0.0,
		deck_height_at(index) if surface_kind_at(index) != SurfaceKind.LAND \
		else NAN))


## Whether a deterministic plant root belongs under a completed road patch.
##
## The road renderer joins square patches, including diagonals. A circle around each
## cell's outer-edge corners is a conservative version of that footprint: neighbouring
## circles overlap across every connector, and wider architectural tiers clear their
## full paving rather than retaining the Tier 0 radius.
func clears_flora_direction(direction: Vector3, for_planet: Planet) -> bool:
	if for_planet == null or for_planet != _planet or site == null or grid == null \
			or _built.is_empty() or not direction.is_finite() \
			or direction.length_squared() < 0.5:
		return false
	var at := direction.normalized()
	var broad_reach := site.reach + MAX_FLORA_CLEAR_RADIUS
	if at.dot(site.centre) < cos(broad_reach / site.planet_radius):
		return false
	_ensure_flora_clearance_index()
	var local := site.to_local(at)
	var containing := grid.cell_of(local)
	if not grid.inside(containing):
		return false
	var candidates: PackedInt32Array = _flora_roads_by_cell.get(
		grid.index(containing), PackedInt32Array())
	for cell_index in candidates:
		var clear_radius: float = EDGE_WIDTHS[width_class_at(cell_index)] \
			* FLORA_CORNER_SCALE + FLORA_CLEAR_MARGIN
		if local.distance_squared_to(grid.centre_of(_cell(cell_index))) \
				<= clear_radius * clear_radius:
			return true
	return false


## Answers [method clears_flora_direction] for a whole tile of plants at once.
##
## Returns one byte per entry of [param directions] — planet-local unit directions —
## set where this road already paves that spot. [param known] is the answer so far, so
## a field standing between two towns can ask each of them in turn and neither looks
## at a plant the other has already covered.
##
## The single-plant form needs the site projection, the containing cell, the width
## class and a cell centre, and every one of those is a call into another script. A
## field raising a tile of grass inside a paved town asks about thousands of plants in
## one frame and spent seventeen milliseconds of it there. Nothing in that per-plant
## work depends on the plant except the arithmetic, so all of it is hoisted here and
## the loop is arithmetic.
func clear_flora_directions(directions: PackedVector3Array,
		known: PackedByteArray, for_planet: Planet) -> PackedByteArray:
	var cleared := known
	var count := directions.size()
	if cleared.size() != count:
		cleared.resize(count)
	if for_planet == null or for_planet != _planet or site == null \
			or grid == null or _built.is_empty() or count == 0:
		return cleared
	_ensure_flora_clearance_index()
	if _flora_roads_by_cell.is_empty():
		return cleared
	var up := site.up
	var east := site.east
	var north := site.north
	var planet_radius := site.planet_radius
	var town_centre := site.centre
	var cos_broad := cos(minf(
		(site.reach + MAX_FLORA_CLEAR_RADIUS) / planet_radius, PI))
	var across := grid.cells
	var cell_size := grid.cell_size
	var half := grid.half_span()
	# Three numbers rather than a class lookup per plant. A road cell's width cannot
	# change while this loop runs.
	var squared_radii := PackedFloat32Array()
	for width_class in WidthClass.size():
		var clear_radius: float = EDGE_WIDTHS[width_class] * FLORA_CORNER_SCALE \
			+ FLORA_CLEAR_MARGIN
		squared_radii.push_back(clear_radius * clear_radius)
	for slot in count:
		if cleared[slot] != 0:
			continue
		var at := directions[slot]
		var along := at.dot(up)
		if at.dot(town_centre) < cos_broad:
			continue
		# [method MeepSite.to_local], inlined.
		var tangent := at - up * along
		var out := tangent.length()
		if out < 1e-9:
			continue
		var arc := atan2(out, along) * planet_radius / out
		var local_x := tangent.dot(east) * arc
		var local_y := tangent.dot(north) * arc
		var cell_x := floori((local_x + half) / cell_size)
		var cell_y := floori((local_y + half) / cell_size)
		if cell_x < 0 or cell_y < 0 or cell_x >= across or cell_y >= across:
			continue
		var listed: Variant = _flora_roads_by_cell.get(cell_y * across + cell_x)
		if listed == null:
			continue
		for road_index: int in listed as PackedInt32Array:
			var away_x := local_x \
				- ((road_index % across + 0.5) * cell_size - half)
			var away_y := local_y \
				- ((road_index / across + 0.5) * cell_size - half)
			if away_x * away_x + away_y * away_y > squared_radii[clampi(
					int(_width_by_cell.get(road_index, WidthClass.STREET)),
					0, WidthClass.size() - 1)]:
				continue
			cleared[slot] = 1
			break
	return cleared


## Cheap tile-level rejection used before a GroundCover field inspects its instances.
func flora_clearance_reaches(world_point: Vector3, extra_radius: float,
		for_planet: Planet) -> bool:
	if for_planet == null or for_planet != _planet or site == null \
			or _built.is_empty() or not world_point.is_finite():
		return false
	var relative := _planet.to_local(world_point)
	if relative.length_squared() < 0.5:
		return false
	var reach := site.reach + MAX_FLORA_CLEAR_RADIUS + maxf(extra_radius, 0.0)
	return relative.normalized().dot(site.centre) \
		>= cos(reach / site.planet_radius)


## Coalesces complete snapshots and their width sidecar into one main-thread flora
## refresh. New tiles also query this road node while being raised, so this notification
## is only for plants that were already visible when the paving changed.
##
## [param changed] are the cells whose paving moved. A refresh only has to reach the
## plants those cells can newly clear: everything else standing in the town was
## already cleared when its own pavement was laid. Asking every field about every
## plant the whole town reaches, once per finished segment, cost 215 ms of deferred
## main-thread time in a mature city to hide a hundred and seventy plants.
func _queue_flora_clearance_refresh(
		changed := PackedInt32Array(), everywhere := false) -> void:
	if not _world_effects_enabled:
		return
	if everywhere or changed.is_empty():
		_clear_scope_everywhere = true
	else:
		for index in changed:
			_clear_scope_cells[index] = true
		if _clear_scope_cells.size() > CLEARANCE_SCOPE_CELLS:
			_clear_scope_everywhere = true
	if _clear_scope_everywhere:
		_clear_scope_cells.clear()
	if _flora_refresh_queued or not is_inside_tree():
		return
	_flora_refresh_queued = true
	call_deferred(&"_refresh_flora_clearance")


## Lines up the fields the pending refresh has to walk. The walking itself is done
## by [method advance_flora_clearance], because a whole-town scope reaches every tile
## of every field and doing that here cost 170 ms in one deferred call.
func _refresh_flora_clearance() -> void:
	_flora_refresh_queued = false
	if not is_inside_tree():
		return
	# A segment that finishes mid-walk widens the scope, so the tiles already passed
	# have to be looked at again. Owed rather than restarted now: a busy town finishes
	# a segment every few seconds, and restarting each time would mean a walk of a
	# grown town never reaching its last field.
	if not _clear_fields.is_empty():
		_clear_restart = true
		return
	_line_up_flora_clearance()


func _line_up_flora_clearance() -> void:
	_clear_fields.clear()
	_clear_cursor = 0
	_clear_restart = false
	for field_variant: Variant in get_tree().get_nodes_in_group(
			DamageHit.FIELD_GROUP):
		var field := field_variant as Node
		if field != null and field.has_method(&"refresh_road_clearance_slice"):
			_clear_fields.push_back(field)


## Hides plants under the town's paving, out of what the planet has left of the frame.
##
## The scope the fields are tested against is only cleared once every field has been
## covered, so a segment finishing midway through simply widens what the remaining
## slices look for rather than restarting them.
func advance_flora_clearance() -> void:
	if _clear_fields.is_empty():
		return
	var budget_usec := _clearance_allowance()
	if budget_usec <= 0:
		return
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_ensure_flora_clearance_index()
	var opened := Time.get_ticks_usec()
	while not _clear_fields.is_empty():
		var left := budget_usec - (Time.get_ticks_usec() - opened)
		# Checked before the next field rather than inside it: a field always walks at
		# least one tile, and a planet carries seventeen of them, so handing each a
		# spent budget in turn was seventeen tiles and eleven milliseconds.
		if left <= 0:
			break
		var field := _clear_fields[0]
		if field == null or not is_instance_valid(field) \
				or not field.is_inside_tree():
			_clear_fields.remove_at(0)
			_clear_cursor = 0
			continue
		var slice: Dictionary = field.call(&"refresh_road_clearance_slice",
			self, _clear_cursor, left)
		_clear_cursor = int(slice.get("next", -1))
		if _clear_cursor >= 0:
			break
		_clear_fields.remove_at(0)
		_clear_cursor = 0
	_spend_clearance_allowance(Time.get_ticks_usec() - opened)
	if _clear_fields.is_empty():
		if _clear_restart:
			_line_up_flora_clearance()
		else:
			_clear_scope_cells.clear()
			_clear_scope_everywhere = false
	_trace(&"flora_clearance", began)


static func _clearance_allowance() -> int:
	var frame := Engine.get_process_frames()
	if frame != _clearance_frame:
		_clearance_frame = frame
		_clearance_spent = 0
	return maxi(CLEARANCE_FRAME_USEC - _clearance_spent, 0)


static func _spend_clearance_allowance(used: int) -> void:
	_clearance_spent += maxi(used, 0)


## The patch of planet the pending refresh has to cover: a unit direction, the
## cosine of the angle around it that the new pavement can clear, and the radius
## the two were measured on.
##
## Handed to the field whole so that it can reject a tile, and then a plant, with
## one dot product instead of a call back into this node.
func flora_clearance_scope() -> Dictionary:
	if site == null or grid == null:
		return {}
	var whole := {
		"centre": site.centre,
		"cos_reach": cos(minf(
			(site.reach + MAX_FLORA_CLEAR_RADIUS) / site.planet_radius, PI)),
		"radius": site.planet_radius,
	}
	if _clear_scope_everywhere or _clear_scope_cells.is_empty():
		return whole
	var centre := Vector3.ZERO
	for index: Variant in _clear_scope_cells:
		centre += site.direction_at(grid.centre_of(_cell(int(index))))
	if centre.length_squared() < 0.000001:
		return whole
	centre = centre.normalized()
	var narrowest := 1.0
	for index: Variant in _clear_scope_cells:
		narrowest = minf(narrowest, centre.dot(
			site.direction_at(grid.centre_of(_cell(int(index))))))
	return {
		"centre": centre,
		"cos_reach": cos(minf(acos(clampf(narrowest, -1.0, 1.0))
			+ MAX_FLORA_CLEAR_RADIUS / site.planet_radius, PI)),
		"radius": site.planet_radius,
	}


func _point(local: Vector2, lift: float, height_override := NAN) -> Vector3:
	var direction := site.direction_at(local)
	return direction * (site.planet_radius
		+ _corner_height(local, direction, height_override) + lift)


## Ground height under one ribbon corner.
##
## [param height_override] wins when it is finite: a bridge or dock corner sits on its
## deck, not on the seabed. Otherwise this is an analytical terrain sample, which is
## several octaves of noise plus every scar overlapping the point, and is the whole
## reason measuring a network is expensive.
##
## While [member _corner_memo] is on, samples are remembered by position for the rest
## of the layer. A cell's own square and the connectors its neighbours draw back to it
## meet at exactly the same points, so a straight run asked for every corner twice.
func _corner_height(local: Vector2, direction: Vector3,
		height_override := NAN) -> float:
	if is_finite(height_override):
		return height_override
	if _corner_memo:
		var kept: Variant = _corner_heights.get(local)
		if kept != null:
			return float(kept)
	var height := _shape.elevation(direction,
		_planet.finest_spacing() if _planet != null else 0.0) \
		if _shape != null else grid.height_at(grid.cell_of(local))
	if _corner_memo:
		_corner_heights[local] = height
	return height


## Rebuilds whatever geometry is out of date, measuring at most [param patch_budget]
## previously uncached cells per layer. Zero means no limit, which is what a
## finished segment and a restoring late joiner both want: they are either small or
## they are expected to be complete the moment they return.
func draw(patch_budget := 0) -> void:
	if not _dirty or _edge == null or _surface == null \
			or _poles == null or _heads == null:
		return
	_dirty = false
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_ribbon_measured = 0
	_ribbon_measure_usec = 0
	_edge.mesh = _ribbon(RIBBON_EDGE, EDGE_LIFT, patch_budget,
		_measure_allowance())
	# One continuous upper mesh is also the collision source. Surface kind remains
	# explicit metadata; keeping transitions in one ribbon makes ramps genuinely
	# sloped instead of a stack of separately coloured collision steps.
	_surface.mesh = _ribbon(RIBBON_SURFACE, ROAD_LIFT, patch_budget,
		_measure_allowance())
	# Two rows, because the two halves are turned down by different things: measuring
	# is a height-field sample per corner of every cell that changed, and assembling
	# is putting the whole network's cached patches into one mesh however little of it
	# moved. A slow draw with nothing measured is a network too large to reassemble.
	if began > 0:
		var spent := Time.get_ticks_usec() - began
		RuntimeTelemetry.record_activity(&"roads", &"draw_measure",
			_ribbon_measure_usec, float(_ribbon_measured))
		RuntimeTelemetry.record_activity(&"roads", &"draw_assemble",
			maxi(spent - _ribbon_measure_usec, 0),
			float(_built_order.size()))
		RuntimeTelemetry.record_activity(
			&"roads", &"draw_ribbons", spent, float(_ribbon_measured))
	# The ribbon above is shown as far as it got, because a street appearing over a
	# few frames is the point of the budget. What follows is derived from the whole
	# of it and costs the same however little was measured, so a network still being
	# remeasured would otherwise rebuild its collision, piles and lamps from a
	# partial mesh every frame until it finished — several milliseconds a frame to
	# publish geometry that is about to be replaced. The one already standing is
	# both complete and a fraction of a second old.
	if _dirty:
		return
	began = Time.get_ticks_usec() if began > 0 else 0
	for stand in _deck_stands:
		stand.mesh = null
	_dock_piles.mesh = _dock_pile_mesh()
	_trace(&"draw_piles", began)
	began = Time.get_ticks_usec() if began > 0 else 0
	_rebuild_collision()
	_trace(&"draw_collision", began)
	began = Time.get_ticks_usec() if began > 0 else 0
	_draw_lamps()
	_trace(&"draw_lamps", began)


## What this network may spend measuring one ribbon layer, out of its own cap and out
## of what the planet's other towns have left of the frame.
static func _measure_allowance() -> int:
	var frame := Engine.get_process_frames()
	if frame != _measure_frame:
		_measure_frame = frame
		_measure_spent = 0
	return clampi(RIBBON_MEASURE_FRAME_USEC - _measure_spent,
		0, RIBBON_MEASURE_BUDGET_USEC)


static func _spend_measure_allowance(used: int) -> void:
	_measure_spent += maxi(used, 0)


func _rebuild_collision() -> void:
	if _collision_shape == null:
		return
	var faces := PackedVector3Array()
	var collision_stands: Array[MeshInstance3D] = [_surface]
	collision_stands.append_array(_deck_stands)
	collision_stands.push_back(_dock_piles)
	for stand in collision_stands:
		if stand != null and stand.mesh != null:
			faces.append_array(stand.mesh.get_faces())
	(_collision_shape.shape as ConcavePolygonShape3D).set_faces(faces)


func _dock_pile_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var offsets: Array[Vector2] = [
		Vector2(-DOCK_PILE_HALF_WIDTH, -DOCK_PILE_HALF_WIDTH),
		Vector2(DOCK_PILE_HALF_WIDTH, -DOCK_PILE_HALF_WIDTH),
		Vector2(DOCK_PILE_HALF_WIDTH, DOCK_PILE_HALF_WIDTH),
		Vector2(-DOCK_PILE_HALF_WIDTH, DOCK_PILE_HALF_WIDTH),
	]
	for index in _built_order:
		if surface_kind_at(index) != SurfaceKind.DOCK:
			continue
		var cell := _cell(index)
		var centre := grid.centre_of(cell)
		var bottom := grid.height_at(cell) + DOCK_PILE_SEABED_CLEARANCE
		var top := deck_height_at(index) - DOCK_PILE_TOP_INSET
		if top <= bottom:
			continue
		for side in 4:
			var a := centre + offsets[side]
			var b := centre + offsets[(side + 1) % 4]
			var first := vertices.size()
			var points := PackedVector3Array([
				_point(a, 0.0, bottom),
				_point(b, 0.0, bottom),
				_point(b, 0.0, top),
				_point(a, 0.0, top),
			])
			var normal := (points[1] - points[0]).cross(
				points[3] - points[0]).normalized()
			vertices.append_array(points)
			for _slot in 4:
				normals.push_back(normal)
			indices.append_array(PackedInt32Array([
				first, first + 2, first + 1,
				first, first + 3, first + 2,
			]))
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func dock_pile_count() -> int:
	return surface_cell_count(SurfaceKind.DOCK)


func dock_pile_faces() -> PackedVector3Array:
	_flush_pending_draw()
	return _dock_piles.mesh.get_faces() \
		if _dock_piles != null and _dock_piles.mesh != null \
		else PackedVector3Array()


func _draw_lamps() -> void:
	var count := _lamp_cells.size()
	for stand: MultiMeshInstance3D in [_poles, _heads]:
		if stand.multimesh.instance_count < count:
			stand.multimesh.instance_count = count
	for slot in count:
		var local := _lamp_locals[slot]
		var cell_index := _lamp_cells[slot]
		var deck_height := deck_height_at(cell_index) \
			if surface_kind_at(cell_index) != SurfaceKind.LAND else NAN
		var up := site.direction_at(local)
		var east := site.east - up * site.east.dot(up)
		if east.length_squared() < 0.000001:
			east = site.north - up * site.north.dot(up)
		east = east.normalized()
		var facing := Basis(east, up, east.cross(up))
		_poles.multimesh.set_instance_transform(slot, Transform3D(
			facing, _point(local,
				ROAD_LIFT + LAMP_POLE_HEIGHT * 0.5, deck_height)))
		_heads.multimesh.set_instance_transform(slot, Transform3D(
			facing, _point(local, ROAD_LIFT + LAMP_POLE_HEIGHT
				+ LAMP_HEAD_HEIGHT * 0.5, deck_height)))
	_poles.multimesh.visible_instance_count = count
	_heads.multimesh.visible_instance_count = count


## One terrain-conforming patch per cell and per link. The patches deliberately
## overlap; the upper concrete hides interior black while the wider lower layer remains
## visible only at the outside edge.
func _ribbon(layer: int, lift: float, patch_budget := 0,
		measure_usec := RIBBON_MEASURE_BUDGET_USEC) -> ArrayMesh:
	var cache := _ribbon_cache[layer]
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var left := patch_budget
	var spent := 0
	_corner_heights.clear()
	_corner_memo = true
	for index in _built_order:
		var cached: Variant = cache.get(index)
		var patch: Array
		if cached is Array:
			patch = cached as Array
		else:
			if patch_budget > 0 and (left <= 0 or spent >= measure_usec):
				# Every vertex of a patch is a height-field sample, so a town whose
				# ground was just rebaked has to remeasure its whole network. Leaving
				# the rest for the coming frames reads as the streets finishing
				# rather than as the game stopping.
				_dirty = true
				continue
			left -= 1
			var measure_began := Time.get_ticks_usec()
			patch = _cell_ribbon(index, layer, lift)
			spent += Time.get_ticks_usec() - measure_began
			_ribbon_measured += 1
			cache[index] = patch
		vertices.append_array(patch[0] as PackedVector3Array)
		normals.append_array(patch[1] as PackedVector3Array)
	_corner_memo = false
	_corner_heights.clear()
	_ribbon_measure_usec += spent
	# Only a presentation draw is billed. An accessor flushing a pending draw measures
	# the whole network on purpose, and charging the frame for that would starve every
	# town that was waiting its turn.
	if patch_budget > 0:
		_spend_measure_allowance(spent)
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = _ribbon_triangles(layer, vertices.size() / 4)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## One cell's share of a ribbon: its own square, then a tapered connector to each
## forward neighbour it links to. Returns the vertices and the normals; the
## triangles are the same two per square wherever it lands, so they are numbered
## once for the whole layer in [method _ribbon_triangles].
func _cell_ribbon(index: int, layer: int, lift: float) -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var edge_layer := layer == RIBBON_EDGE
	var width_class := width_class_at(index)
	var width: float = EDGE_WIDTHS[width_class] if edge_layer \
		else ROAD_WIDTHS[width_class]
	var cell := _cell(index)
	var centre := grid.centre_of(cell)
	var centre_height := deck_height_at(index) \
		if surface_kind_at(index) != SurfaceKind.LAND else NAN
	var patch_heights := PackedFloat32Array([
		centre_height, centre_height, centre_height, centre_height])
	_append_patch(vertices, normals,
		centre + Vector2(-width, -width) * 0.5,
		centre + Vector2(width, -width) * 0.5,
		centre + Vector2(width, width) * 0.5,
		centre + Vector2(-width, width) * 0.5, lift, patch_heights)
	for offset in LINKS:
		var neighbour := cell + offset
		if not grid.inside(neighbour):
			continue
		var other := grid.index(neighbour)
		if not _built.has(other):
			continue
		# A diagonal whose orthogonal corner is already road is an accidental
		# adjacency between nearby branches, not part of either branch.
		if offset.x != 0 and offset.y != 0:
			if _built.has(grid.index(cell + Vector2i(offset.x, 0))) \
					or _built.has(grid.index(cell + Vector2i(0, offset.y))):
				continue
		var other_centre := grid.centre_of(neighbour)
		var other_width_class := width_class_at(other)
		var other_width: float = EDGE_WIDTHS[other_width_class] if edge_layer \
			else ROAD_WIDTHS[other_width_class]
		var along := (other_centre - centre).normalized()
		# Taper only the connector. Existing cell patches retain their original
		# class, so meeting a boulevard never widens an old Tier 0 street.
		var side_here: Vector2 = Vector2(-along.y, along.x) * width * 0.5
		var side_there: Vector2 = Vector2(
			-along.y, along.x) * other_width * 0.5
		var other_height := deck_height_at(other) \
			if surface_kind_at(other) != SurfaceKind.LAND else NAN
		_append_patch(vertices, normals,
			centre - side_here, other_centre - side_there,
			other_centre + side_there, centre + side_here, lift,
			PackedFloat32Array([
				centre_height, other_height,
				other_height, centre_height]))
	return [vertices, normals]


## Triangles for [param quads] four-vertex patches, grown in place. The numbering
## depends on nothing but the count, so a town that gained a few cells extends the
## list it already had instead of renumbering every square in it.
func _ribbon_triangles(layer: int, quads: int) -> PackedInt32Array:
	var indices := _ribbon_indices[layer]
	var have := indices.size() / 6
	if have == quads:
		return indices
	if have > quads:
		indices.resize(quads * 6)
		_ribbon_indices[layer] = indices
		return indices
	indices.resize(quads * 6)
	for quad in range(have, quads):
		var first := quad * 4
		var slot := quad * 6
		# Clockwise from outside, which is Godot's front face.
		indices[slot] = first
		indices[slot + 1] = first + 2
		indices[slot + 2] = first + 1
		indices[slot + 3] = first
		indices[slot + 4] = first + 3
		indices[slot + 5] = first + 2
	_ribbon_indices[layer] = indices
	return indices


## Drops cached geometry for [param cells] and for everything touching them.
##
## What a cell contributes is decided inside one ring: its own square, the
## connectors it draws to neighbours, and the orthogonal cells that suppress its
## diagonals. One ring is therefore all that a completed segment can invalidate.
func _forget_ribbon_patches(cells: PackedInt32Array) -> void:
	if grid == null:
		return
	for cell_index in cells:
		var cell := _cell(cell_index)
		for layer in _ribbon_cache.size():
			(_ribbon_cache[layer] as Dictionary).erase(cell_index)
		for offset in NEIGHBOURS:
			var neighbour := cell + offset
			if not grid.inside(neighbour):
				continue
			var neighbour_index := grid.index(neighbour)
			for layer in _ribbon_cache.size():
				(_ribbon_cache[layer] as Dictionary).erase(neighbour_index)


func _forget_all_ribbon_patches() -> void:
	for layer in _ribbon_cache.size():
		(_ribbon_cache[layer] as Dictionary).clear()


func _append_patch(vertices: PackedVector3Array, normals: PackedVector3Array,
		a: Vector2, b: Vector2, c: Vector2, d: Vector2, lift: float,
		heights: PackedFloat32Array = PackedFloat32Array()) -> void:
	var points: Array[Vector2] = [a, b, c, d]
	for slot in points.size():
		var local := points[slot]
		# One direction serves as both the normal and the ray the vertex is placed
		# along, which is what it was before being asked for twice per corner.
		var direction := site.direction_at(local)
		vertices.push_back(direction * (site.planet_radius + _corner_height(
			local, direction, heights[slot] if slot < heights.size() else NAN)
			+ lift))
		normals.push_back(direction)


# --- Bounded night lighting --------------------------------------------------

## Keeps physical light around the local viewer, not around every road on the planet.
## The visible cylinders are all batched above; these twelve nodes only provide cast
## light and fade before being lent to a different fixture.
func update_lights(delta: float, eye: Vector2) -> void:
	if _collision_body != null:
		_collision_body.collision_layer = 1 \
			if claim == null or eye.length() <= claim.radius + COLLISION_WITHIN \
			else 0
	if _lights.is_empty():
		return
	_since_light_targets += delta
	if _since_light_targets >= LIGHT_RETARGET_INTERVAL:
		_since_light_targets = 0.0
		_choose_light_targets(eye)
	_update_lights(delta)
	_update_head_emission()


func _choose_light_targets(eye: Vector2) -> void:
	var candidates: Array[Vector2] = []
	var near_town := claim == null \
		or eye.length() <= claim.radius + LIGHTS_WITHIN
	if near_town:
		var reach := LIGHTS_WITHIN * LIGHTS_WITHIN
		for slot in _lamp_cells.size():
			var away := eye.distance_squared_to(_lamp_locals[slot])
			if away <= reach:
				candidates.push_back(Vector2(away, float(_lamp_cells[slot])))
		candidates.sort_custom(func(a: Vector2, b: Vector2) -> bool:
			return a.y < b.y if is_equal_approx(a.x, b.x) else a.x < b.x)

	# Preserve targets just beyond the exact nearest set. A walker crossing the
	# bisector between two poles should not make either patch of ground pulse.
	var retain_squared := -1.0
	if not candidates.is_empty():
		var cutoff_slot := mini(_lights.size() - 1, candidates.size() - 1)
		var retain_distance := minf(
			sqrt(candidates[cutoff_slot].x) + LIGHT_TARGET_HYSTERESIS,
			LIGHTS_WITHIN)
		retain_squared = retain_distance * retain_distance
	var assigned := {}
	for slot in _light_targets.size():
		var current := _light_targets[slot]
		var lamp_slot := int(_lamp_slot_by_cell.get(current, -1))
		if current >= 0 and lamp_slot >= 0 and retain_squared >= 0.0 \
				and eye.distance_squared_to(
					_lamp_locals[lamp_slot]) <= retain_squared:
			assigned[current] = true
		else:
			_light_targets[slot] = -1
	for candidate in candidates:
		var target := int(candidate.y)
		if assigned.has(target):
			continue
		var free_slot := _light_targets.find(-1)
		if free_slot < 0:
			break
		_light_targets[free_slot] = target
		assigned[target] = true


func _update_lights(delta: float) -> void:
	var step := delta * LIGHT_ENERGY * 3.0
	for slot in _lights.size():
		var light := _lights[slot]
		var target := _lamp_world_point(_light_targets[slot])
		var arrived := target.is_finite() \
			and light.global_position.distance_squared_to(target) < 0.01
		var toward := LIGHT_ENERGY * _night_at(target) if arrived else 0.0
		light.light_energy = move_toward(light.light_energy, toward, step)
		light.visible = light.light_energy > 0.001
		if not arrived and light.light_energy <= 0.001 and target.is_finite():
			light.global_position = target
			light.light_color = LAMP_HEAD_COLOUR


func _lamp_world_point(cell_index: int) -> Vector3:
	if _planet == null or not _lamp_slot_by_cell.has(cell_index):
		return Vector3.INF
	var slot := int(_lamp_slot_by_cell[cell_index])
	if slot < 0 or slot >= _lamp_locals.size():
		return Vector3.INF
	return _planet.to_global(_point(_lamp_locals[slot],
		ROAD_LIFT + LAMP_POLE_HEIGHT,
		deck_height_at(cell_index) \
			if surface_kind_at(cell_index) != SurfaceKind.LAND else NAN))


func _night_at(at: Vector3) -> float:
	if not at.is_finite() or _planet == null or _planet.sun == null:
		return 0.0
	var up := (at - _planet.global_position).normalized()
	var to_sun := _planet.sun.global_basis.z.normalized()
	return 1.0 - smoothstep(-0.16, 0.12, up.dot(to_sun))


func _update_head_emission() -> void:
	if _head_material == null or _planet == null:
		return
	var at := _planet.to_global(_point(Vector2.ZERO,
		ROAD_LIFT + LAMP_POLE_HEIGHT))
	_head_material.emission_energy_multiplier = lerpf(
		LAMP_HEAD_DAY_EMISSION, LAMP_HEAD_NIGHT_EMISSION, _night_at(at))


func lamp_count() -> int:
	return _lamp_cells.size()


func lamp_cells() -> PackedInt32Array:
	return _lamp_cells.duplicate()


func lamp_cell_at(slot: int) -> int:
	return _lamp_cells[slot] if slot >= 0 and slot < _lamp_cells.size() else -1


func lamp_local_at(slot: int) -> Vector2:
	return _lamp_locals[slot] \
		if slot >= 0 and slot < _lamp_locals.size() else Vector2.INF


func light_pool_size() -> int:
	return _lights.size()


func active_light_count() -> int:
	var found := 0
	for light in _lights:
		if light.visible and light.light_energy > 0.001:
			found += 1
	return found


func light_energy() -> float:
	var total := 0.0
	for light in _lights:
		total += light.light_energy
	return total


# --- Replication -------------------------------------------------------------

## A whole road network is just the sorted indices of completed cells.
func snapshot() -> PackedInt32Array:
	return _built_order.duplicate()


func width_snapshot() -> PackedInt32Array:
	var out := PackedInt32Array()
	for index in _built_order:
		out.push_back(index)
		out.push_back(width_class_at(index))
	return out


## Compact additive sidecar: cell, SurfaceKind, deck height in millimetres.
## LAND remains implicit so every old road snapshot is still valid unchanged.
func surface_snapshot() -> PackedInt32Array:
	var out := PackedInt32Array()
	for index in _built_order:
		var kind := surface_kind_at(index)
		if kind == SurfaceKind.LAND:
			continue
		out.append_array(PackedInt32Array([
			index, kind, roundi(deck_height_at(index) * 1000.0)]))
	return out


func apply_snapshot(state: PackedInt32Array) -> void:
	if grid != null:
		for index_variant: Variant in _built:
			var old_index := int(index_variant)
			grid.set_flag(_cell(old_index), MeepGrid.FLAG_ROAD, false)
			grid.set_surface(_cell(old_index), 0.0, false)
	_built.clear()
	_width_by_cell.clear()
	_surface_by_cell.clear()
	_deck_height_by_cell.clear()
	for index in state:
		if grid == null or index < 0 or index >= grid.cells * grid.cells:
			continue
		if not _cell_allowed(index):
			continue
		_built[index] = true
		_width_by_cell[index] = WidthClass.STREET
		grid.set_flag(_cell(index), MeepGrid.FLAG_ROAD)
	_forget_all_ribbon_patches()
	_reorder()
	_dirty = true
	_queue_flora_clearance_refresh(PackedInt32Array(), true)


func apply_width_snapshot(state: PackedInt32Array) -> void:
	for slot in state.size() / 2:
		var index := state[slot * 2]
		if _built.has(index):
			_width_by_cell[index] = clampi(
				state[slot * 2 + 1], 0, WidthClass.size() - 1)
	_forget_all_ribbon_patches()
	_rebuild_flora_clearance_index()
	_dirty = true
	_queue_flora_clearance_refresh(PackedInt32Array(), true)


func apply_surface_snapshot(state: PackedInt32Array) -> void:
	for slot in state.size() / 3:
		var index := state[slot * 3]
		if not _built.has(index):
			continue
		var kind := clampi(state[slot * 3 + 1],
			SurfaceKind.BRIDGE, SurfaceKind.DOCK)
		var height := float(state[slot * 3 + 2]) / 1000.0
		_surface_by_cell[index] = kind
		_deck_height_by_cell[index] = height
		grid.set_surface(_cell(index), height + ROAD_LIFT)
	_forget_all_ribbon_patches()
	_rebuild_flora_clearance_index()
	_dirty = true
	_queue_flora_clearance_refresh(PackedInt32Array(), true)


## A completed segment leaves its geometry for the presentation step rather than
## rebuilding it inside the settler tick, so anyone reading that geometry has to be the
## one who waits. Nothing here is on a hot path: these are asked by tests, by a late
## joiner comparing its restored network, and by the pile count.
func _flush_pending_draw() -> void:
	if _dirty:
		draw()


func collision_faces() -> PackedVector3Array:
	_flush_pending_draw()
	if _collision_shape == null or _collision_shape.shape == null:
		return PackedVector3Array()
	return (_collision_shape.shape as ConcavePolygonShape3D).get_faces()


func visible_surface_faces() -> PackedVector3Array:
	_flush_pending_draw()
	var faces := PackedVector3Array()
	var stands: Array[MeshInstance3D] = [_surface]
	stands.append_array(_deck_stands)
	for stand in stands:
		if stand != null and stand.mesh != null:
			faces.append_array(stand.mesh.get_faces())
	return faces


## Reapplies intent after the terrain grid underneath the town was rebuilt.
func resettle() -> void:
	if grid == null:
		return
	for index in _built_order:
		grid.set_flag(_cell(index), MeepGrid.FLAG_ROAD)
		if surface_kind_at(index) != SurfaceKind.LAND:
			grid.set_surface(_cell(index), deck_height_at(index) + ROAD_LIFT)
	# The ground the ribbon was measured against is the thing that just moved, so
	# no cached patch survives a rebake.
	_forget_all_ribbon_patches()
	_dirty = true
