@tool
class_name Planet
extends Node3D

## A spherical world drawn as a cube-sphere quadtree that refines toward a viewer.
##
## The whole surface at walkable resolution is hundreds of millions of triangles,
## so only the ground near the viewer is ever built at full detail: each of the
## cube's six faces is a quadtree that splits while the chunk it covers is nearer
## than [member split_ratio] times its own width. Chunk meshes are built on worker
## threads and handed to the scene a few per frame, because building one on the
## main thread is a visible hitch.
##
## Cracks between neighbours at different depths are covered by skirts — a ring of
## vertices dropped below the surface — rather than by stitching, which would make
## every chunk depend on when its neighbours happened to finish.
##
## The terrain itself lives in [PlanetShape]; this file only decides how much of it
## to build and when.
##
## It is also the one writer of the planet frame — the global shader parameters
## that tell the ground, the props standing on it, the sky and the atmosphere
## shell where the planet is and which way its colour wheel is turned. They are
## declared in project.godot's [code][shader_globals][/code] and described in
## [code]shaders/vivid/README.md[/code]; nothing else should write them.

const SURFACE_MATERIAL := preload("res://game/planet/planet_surface.tres")
const ATMOSPHERE_MATERIAL := preload("res://game/planet/planet_atmosphere.tres")
const CLOUD_MATERIAL := preload("res://game/planet/planet_clouds.tres")

## Outward normal, then the u and v axes of each cube face's [-1, 1] square.
## u cross v equals the normal on every face, so one winding order serves all six.
const FACES: Array[Array] = [
	[Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
	[Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)],
	[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
	[Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)],
	[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)],
]

@export var shape: PlanetShape

@export_group("Detail")
## Quads along one edge of a chunk. Total triangles per chunk is twice its square,
## so this trades chunk count against triangles inside each one.
@export_range(4, 48, 2) var chunk_resolution := 16
## Deepest subdivision. Vertex spacing at the surface is
## (pi / 2) * radius / (2 ^ max_depth) / chunk_resolution — about 1.5 m at the
## defaults, which is finer than a footstep.
@export_range(0, 12) var max_depth := 9
## A chunk splits while the viewer is nearer than this many chunk widths. The
## scene's baseline: [member detail_level] scales it, and `statistics()["reach"]`
## reports what the two came to.
@export_range(0.5, 6.0) var split_ratio := 2.0
## Render distance, as the player's settings offer it, scaling [member
## split_ratio] — the one dial in here worth putting in a menu, because it is the
## only one that trades a visible thing for frames rather than trading one kind of
## hitch for another.
##
## What it moves is where the ground stops being sharp, not how much of the planet
## is on screen: the whole visible cap is always drawn, coarser with distance, and
## no level here removes any of it. Cost is roughly the square of the scale, since
## it is an area of ground being held at each level of detail — 155k, 301k and
## 601k triangles from the air, by `_perf_test.tscn -- --distance`.
##
## Three rather than four. A 2.4 was measured and dropped: it cost 1.1M triangles
## and twice the collision bodies, and could not be told from 1.6 in a photograph
## from either the air or the ground. A level nobody can see is a level that only
## costs.
const DETAIL_LEVELS: Array[Dictionary] = [
	{"label": "Near", "scale": 0.6},
	{"label": "Normal", "scale": 1.0},
	{"label": "Far", "scale": 1.6},
]
## Index into [constant DETAIL_LEVELS]. Written by the settings and by harnesses;
## takes effect on the next walk of the quadtree, which coarsens or refines the
## tree that is already standing rather than throwing it away.
var detail_level := 1
## How deep a chunk's skirt hangs, as a share of the chunk's width. It only has to
## cover the step between two subdivision levels, and every metre past that is a
## dark wall on show wherever the neighbour is coarser.
@export_range(0.0, 0.5) var skirt_scale := 0.12

@export_group("Budget")
## Meshes handed to the scene per frame. Each one is an ArrayMesh upload.
@export_range(1, 32) var applies_per_frame := 4
## Chunk builds allowed on the thread pool at once.
##
## Low on purpose, and the single most valuable number here. A build is a few
## thousand height-field samples in GDScript, and twelve of them at once starved
## the main thread badly enough to cost 35 ms a frame on a 24-core machine — the
## work is off the frame, but it is not off the CPU. At four, the same crossing
## at 200 m/s drops no frames at all and the terrain still keeps up: the tree
## reaches the same size and draws the same chunks either way. More parallelism
## buys throughput nobody was waiting for at the price of the frame that was.
@export_range(1, 64) var pending_limit := 4
## Chunk splits allowed per frame. Placing a chunk's four children means asking
## the height field where each of them sits, and a flight at 200 m/s crosses
## enough ground to split whole subtrees in a single frame — which was worth 48 ms
## of a 62 ms hitch before this bounded it. Refinement then lags a fast viewer by
## a few frames, which costs nothing visible: the coarse ancestor keeps its mesh
## until every child has one, so the ground is blurred rather than missing.
@export_range(1, 64) var splits_per_frame := 8
## Collision bodies built per frame. `ConcavePolygonShape3D.set_faces` builds its
## BVH on the main thread, so this is a main-thread cost like the mesh uploads and
## it has to be paid in instalments for the same reason. Ground that has not been
## given a body yet is caught by the player's own height-field check.
@export_range(1, 32) var bodies_per_frame := 2
## How often the quadtree is walked, in times a second.
##
## Every pass over it is GDScript across about a thousand nodes and costs a few
## milliseconds, and there are two of them — deciding what to split and deciding
## what to draw. Run once a frame at 300 fps that was most of the frame, and it
## bought nothing: which chunk deserves splitting does not change between frames
## three milliseconds apart. At 200 m/s, thirty a second is a fresh look every
## seven metres, against chunks that are twenty-four metres across.
##
## Finished meshes are still handed to the scene every frame — that part is a
## tenth of a millisecond and it is what puts new ground on screen.
@export_range(5, 240) var lod_updates_per_second := 30

@export_group("Collision")
## Leaf chunks nearer than this get a collision body. Everything past it is
## scenery, which is why this must comfortably exceed anything that walks.
@export var collision_range := 260.0

@export_group("Water")
## Lays a sea at sea level, which is the radius the height field measures from.
## Off leaves the ocean basins as dry holes; nothing else changes, because the
## water is not what makes them basins.
@export var has_water := true

@export_group("Clouds")
## Lays an iridescent cloud deck over the planet. It is one shell and one draw,
## and the weather in it is a function of where you are on the globe rather than
## anything stored, so it costs nothing to have and nothing to replicate.
@export var has_clouds := true
## How high the middle of the deck sits, in metres above sea level. Well inside
## [member atmosphere_height], or the clouds are drawn outside the air they are
## supposed to be in; high enough off the ground that the tallest terrain does
## not poke through, since the deck is a shell and does not part for mountains.
@export var cloud_height := 1200.0
## How deep the slab of cloudy air is, in metres. It is what the deck is marched
## through, so it is also what gives a cloud a top, a bottom and a thickness that
## depends on the angle it is seen from. Thin decks stop reading as volume: much
## under two hundred metres and a ray crosses too little field to accumulate
## anything, and the march is one sample again with the cost of fourteen.
@export var cloud_thickness := 700.0

@export_group("Atmosphere")
## Depth of the air, in metres. It sizes the shell that draws the lit rim seen
## from space, and it is also the altitude the shell fades in at.
##
## It must match [code]atmosphere_height[/code] in vivid_space.gdshader, which is
## where the sky stops being sky: below that the sky shader draws the haze, above
## it this shell does, and a mismatch shows as a band of altitude with either no
## air at all or twice as much. Set it to 0 to raise no shell.
@export var atmosphere_height := 2400.0
## The sun, so the shell knows which side of the planet is the day side. The sky
## reads its own light directly and does not need this.
@export var sun: DirectionalLight3D

@export_group("Editor")
## Builds the terrain in the editor as well as in the game, refining around the
## editor camera instead of a player. Without it the planet is an empty pivot in
## the editor and there is nothing to place a prop against.
##
## It costs what it costs in game, which is a frame budget the game already
## affords. Turn it off if the scene is only being opened to edit something else.
@export var editor_preview := true:
	set(value):
		if editor_preview == value:
			return
		editor_preview = value
		if Engine.is_editor_hint() and is_inside_tree():
			_rebuild()

## What the detail is built around. Falls back to the active camera, which is what
## the harness wants; the world will point this at the local player.
var viewer: Node3D

## The sea, or null if this planet has none. Anything asking how deep it is
## standing in water goes through this.
var water: PlanetWater

## The arctic's weather and its footprints. Where the arctic *is* belongs to
## [member shape]; this is only what happens in it.
var snowfield: Snowfield

var _roots: Array[Chunk] = []
var _pending: Dictionary = {}
var _finished: Array[Chunk] = []
var _requests: Array[Chunk] = []
var _visible: Array[Chunk] = []
var _collision_min_depth := 0
var _splits_left := 0
## [member split_ratio] with the render distance in it, taken once per walk rather
## than per chunk: the walk is a thousand nodes of GDScript and the answer is the
## same for all of them.
var _split_reach := 2.0
## Nodes visited by the last refine pass, which is the size of the whole tree and
## the thing every per-frame pass is proportional to.
var _walked := 0
var _since_lod := 0.0
var _built_meshes := 0
var _update_micros := 0.0
## This frame's cost, not an average: both are spike sources and an average is
## the one summary guaranteed to hide a spike.
var _apply_micros := 0.0
var _collision_micros := 0.0
var _frame_micros := 0.0
var _refine_micros := 0.0
var _dispatch_micros := 0.0
var _show_micros := 0.0
var _published_center := Vector3.INF
var _published_sun := Vector3.ZERO
var _published_pole := Vector3.ZERO


## One node of one face's quadtree. Alive from the moment it is split into until
## its parent collapses, which may be while its mesh is still on the thread pool.
class Chunk extends RefCounted:
	var face: int
	## Lower-left corner in the face's [-1, 1] square.
	var offset: Vector2
	var size: float
	var depth: int
	## Where the chunk sits on the surface, and how wide it is there in metres.
	var origin: Vector3
	var arc: float
	## Metres from the viewer, as of this frame's refine pass. Cached because the
	## build queue wants to order by it and recomputing it there was the most
	## expensive thing the planet did.
	var distance := 0.0
	## Best known ground level at this chunk's centre. Inherited from the parent
	## when the chunk is made and corrected by its own build, which runs on a
	## worker thread. The correction is only ever read by children, and a chunk
	## cannot have children until its build has landed, so the two never race.
	var height := 0.0
	var children: Array[Chunk] = []
	var instance: MeshInstance3D
	var body: StaticBody3D
	var arrays: Array
	var collision_faces := PackedVector3Array()
	var triangles := 0
	var queued := false
	## Set when the parent collapses while a build is still running. The result is
	## thrown away rather than cancelled, because a pool task cannot be recalled.
	var discarded := false

	func has_mesh() -> bool:
		return instance != null


func _ready() -> void:
	if shape == null:
		shape = PlanetShape.new()
	shape.prepare()
	# Two levels of slack, so a chunk does not lose its collider the instant the
	# viewer steps far enough away to coarsen it.
	_collision_min_depth = maxi(0, max_depth - 2)
	_publish_frame()
	_raise_water()
	_raise_snowfield()
	_raise_clouds()
	_raise_atmosphere()
	_follow_render_distance()
	if Engine.is_editor_hint() and not editor_preview:
		return
	for face in FACES.size():
		_roots.append(_make_chunk(face, Vector2(-1.0, -1.0), 2.0, 0))


## Takes the render distance from the player's settings and keeps taking it.
##
## Read here rather than applied by [GameSettingsManager] with the rest of the
## graphics settings, because there is nothing to apply it to until a world is
## loaded: the manager starts with the game and this node arrives with the map.
## The signal is what makes the setting land while the pause menu is still open,
## which matters more here than for most of them — a render distance is chosen by
## looking at what it did.
func _follow_render_distance() -> void:
	# Absent in the editor and in the harnesses that stand a planet up on their
	# own, both of which want the scene's own baseline.
	var settings := get_node_or_null("/root/SettingsManager") as GameSettingsManager
	if settings == null:
		return
	detail_level = int(settings.get_setting(&"graphics", &"render_distance", 1))
	settings.settings_changed.connect(
		func(section: StringName, key: StringName, value: Variant) -> void:
			if section == &"graphics" and key == &"render_distance":
				detail_level = int(value))


func _exit_tree() -> void:
	# Pool tasks reference this node's shape, so none may outlive it.
	for task in _pending:
		WorkerThreadPool.wait_for_task_completion(task)
	_pending.clear()


## Throws the quadtree away and starts it again. Only the editor needs this, to
## answer a change to [member editor_preview] without a scene reload.
func _rebuild() -> void:
	for task in _pending:
		WorkerThreadPool.wait_for_task_completion(task)
	_pending.clear()
	_finished.clear()
	for root in _roots:
		_collapse(root)
		_drop(root)
	_roots.clear()
	_visible.clear()
	if not editor_preview:
		return
	for face in FACES.size():
		_roots.append(_make_chunk(face, Vector2(-1.0, -1.0), 2.0, 0))


func _process(delta: float) -> void:
	if _roots.is_empty():
		return
	var started := Time.get_ticks_usec()
	_publish_frame()
	var applying := Time.get_ticks_usec()
	_apply_finished()
	_apply_micros = float(Time.get_ticks_usec() - applying)

	_since_lod += delta
	if _since_lod < 1.0 / float(lod_updates_per_second):
		# Zeroed rather than left alone, so an average over frames is an average
		# of what those frames actually cost and not of the last one that walked.
		_refine_micros = 0.0
		_dispatch_micros = 0.0
		_show_micros = 0.0
		_collision_micros = 0.0
		_frame_micros = float(Time.get_ticks_usec() - started)
		_update_micros = _update_micros * 0.9 + _frame_micros * 0.1
		return
	_since_lod = 0.0

	var eye := viewer_position()
	_requests.clear()
	_splits_left = splits_per_frame
	_split_reach = split_ratio * float(
		DETAIL_LEVELS[clampi(detail_level, 0, DETAIL_LEVELS.size() - 1)]["scale"])
	_walked = 0
	var refining := Time.get_ticks_usec()
	for root in _roots:
		_refine(root, eye)
	_refine_micros = float(Time.get_ticks_usec() - refining)
	var dispatching := Time.get_ticks_usec()
	_dispatch(eye)
	_dispatch_micros = float(Time.get_ticks_usec() - dispatching)
	var showing := Time.get_ticks_usec()
	_visible.clear()
	for root in _roots:
		_show(root)
	_show_micros = float(Time.get_ticks_usec() - showing)
	# No colliders in the editor: nothing there walks, and a body per chunk would
	# be built and thrown away every time the view moved.
	_collision_micros = 0.0
	if not Engine.is_editor_hint():
		var colliding := Time.get_ticks_usec()
		_update_collision(eye)
		_collision_micros = float(Time.get_ticks_usec() - colliding)
	_frame_micros = float(Time.get_ticks_usec() - started)
	# Rolling average rather than the last frame: mesh handoffs make single frames
	# swing by an order of magnitude, and the average is what costs frame rate.
	_update_micros = _update_micros * 0.9 + _frame_micros * 0.1


# --- Public surface queries -------------------------------------------------

## The global point on the ground below a direction from the planet's centre.
func surface_position(direction: Vector3) -> Vector3:
	return to_global(shape.surface_point(direction.normalized()))


## Which way is up at a global point, which on a sphere is where the player's
## gravity and camera have to take their orientation from.
func up_at(global_point: Vector3) -> Vector3:
	var local := to_local(global_point)
	return global_basis * (local.normalized() if local.length_squared() > 0.0 else Vector3.UP)


## Vertex spacing of the deepest chunks, which is the finest the ground is ever
## built at. Anything that has to agree with the mesh rather than with the true
## height field — a prop standing on it, a placement check — wants this as its
## sampling distance, because the terrain the player touches is band-limited to
## it and the true field is not.
func finest_spacing() -> float:
	return PI * 0.5 * shape.radius / pow(2.0, max_depth) / float(chunk_resolution)


## Ground level plus clearance, for putting something on the surface.
func standing_position(direction: Vector3, clearance := 0.0) -> Vector3:
	var unit := direction.normalized()
	return to_global(unit * (shape.radius + shape.elevation(unit) + clearance))


## Whether the ground stands between two global points.
##
## Asked by anything drawing a world position onto the screen, which on a globe
## is most often asking whether the thing is on the other side of it. A raycast
## cannot answer that: only the [member collision_range] around the viewer has a
## body, and everything worth naming from a distance is well past it. So the
## height field is walked directly, which needs no collision and no chunk to have
## been built.
##
## Samples are spread evenly along the line, so this catches the planet's own
## bulge exactly and a mountain range only if it is wider than the spacing. That
## is the right trade for a HUD: the bulge is the whole point and a hill in the
## way is a detail. It costs [param samples] height lookups, which is enough to
## want throttling if it is asked every frame.
func sight_blocked(from: Vector3, to: Vector3, samples := 12) -> bool:
	if shape == null:
		return false
	var start := to_local(from)
	var finish := to_local(to)
	var spacing := finest_spacing()
	for index in range(1, samples):
		var point := start.lerp(finish, float(index) / float(samples))
		var reach := point.length()
		if reach < 1.0:
			return true
		var direction := point / reach
		if reach < shape.radius + shape.elevation(direction, spacing):
			return true
	return false


## Chunks on screen, chunks mid-build, triangles drawn, and colliders standing.
## The harness prints these; they are the only honest way to see what the LOD is
## actually doing.
func statistics() -> Dictionary:
	var triangles := 0
	var bodies := 0
	for chunk in _visible:
		triangles += chunk.triangles
		if chunk.body != null:
			bodies += 1
	return {
		"visible": _visible.size(),
		"pending": _pending.size(),
		"triangles": triangles,
		"bodies": bodies,
		"built": _built_meshes,
		"update_ms": _update_micros / 1000.0,
		"apply_ms": _apply_micros / 1000.0,
		"collision_ms": _collision_micros / 1000.0,
		"frame_ms": _frame_micros / 1000.0,
		"refine_ms": _refine_micros / 1000.0,
		"dispatch_ms": _dispatch_micros / 1000.0,
		"show_ms": _show_micros / 1000.0,
		"nodes": _walked,
		"reach": _split_reach,
	}


# --- The planet frame -------------------------------------------------------

## Writes the globals the vivid shaders read. Guarded on change rather than
## written every frame: a global shader parameter counts as a uniform change, and
## the sky's radiance cubemap — which is the scene's ambient light — is rebuilt
## whenever one moves.
func _publish_frame() -> void:
	var center := global_position
	if center != _published_center:
		_published_center = center
		RenderingServer.global_shader_parameter_set(&"planet_center", center)
		RenderingServer.global_shader_parameter_set(&"planet_radius", shape.radius)
	# North, in world space, and the two cosines that bound the polar cap. The
	# shape owns all three; publishing them rather than restating them in the
	# shaders is what keeps the ice the mesh is built from and the white the
	# shaders paint on the same circle.
	var pole := (global_basis * shape.frost_axis).normalized()
	if pole != _published_pole:
		_published_pole = pole
		RenderingServer.global_shader_parameter_set(&"frost_axis", pole)
		RenderingServer.global_shader_parameter_set(&"frost_edge", shape.frost_outer())
		RenderingServer.global_shader_parameter_set(&"frost_full", shape.frost_inner())
	if sun == null:
		return
	var direction := -sun.global_basis.z
	if direction != _published_sun:
		_published_sun = direction
		RenderingServer.global_shader_parameter_set(&"sun_direction", direction)


## The sea. One node and one mesh, sized and placed by itself; all this decides is
## where the surface is, which is sea level and nowhere else.
func _raise_water() -> void:
	if not has_water:
		return
	water = PlanetWater.new()
	water.name = "Water"
	water.sea_level = shape.radius
	# It follows the same viewer the terrain refines around, and finding one in
	# the editor is knowledge this node already has.
	water.viewer_source = viewer_position
	add_child(water, false, Node.INTERNAL_MODE_BACK)


## The arctic, in as much as it is weather rather than terrain. The white ground
## and the pack ice are in the height field itself; this is the snow falling
## through the air over it and the tracks left behind in it.
func _raise_snowfield() -> void:
	snowfield = Snowfield.new()
	snowfield.name = "Snowfield"
	snowfield.shape = shape
	snowfield.viewer_source = viewer_position
	add_child(snowfield, false, Node.INTERNAL_MODE_BACK)


## The weather, drawn as one sphere a kilometre or so up.
##
## There is no cloud object and nothing is generated in GDScript: the deck is a
## field filling the slab between two radii, marched per pixel by
## `vivid_clouds.gdshader`, which is what makes the clouds located on the globe,
## endless, free to store and free to replicate. Which part of the sky is
## clouding over and which is clearing is in that shader too — see the header
## there for how condensing and evaporating are the same dial.
##
## The sphere raised here is the **top** of the slab and not the middle of it,
## because it is the volume's silhouette rather than its surface: a mesh inside
## the field would clip the deck at the limb, and the shader measures the depth
## of the slab downward from it. More segments than the air above it, because
## this one is looked at from underneath, where its silhouette is against the
## horizon rather than against space.
func _raise_clouds() -> void:
	if not has_clouds or cloud_height <= 0.0:
		return
	var radius := shape.radius + cloud_height + cloud_thickness * 0.5
	var material := CLOUD_MATERIAL.duplicate() as ShaderMaterial
	material.set_shader_parameter(&"shell_radius", radius)
	material.set_shader_parameter(&"deck_thickness", cloud_thickness)
	add_child(_shell("Clouds", radius, 128, material), false, Node.INTERNAL_MODE_BACK)


## The band of air, drawn as one sphere a few per cent wider than the planet.
##
## It is a single draw and the shader inside it fades to nothing below the
## altitude where the sky takes over, so there is no cost to leaving it up while
## someone is walking around underneath it.
func _raise_atmosphere() -> void:
	if atmosphere_height <= 0.0:
		return
	# Duplicated rather than shared, because the height is written into it and
	# the .tres would otherwise carry one planet's setting into the next scene.
	var material := ATMOSPHERE_MATERIAL.duplicate() as ShaderMaterial
	material.set_shader_parameter(&"shell_height", atmosphere_height)
	add_child(_shell("Atmosphere", shape.radius + atmosphere_height, 96, material),
		false, Node.INTERNAL_MODE_BACK)


## One of the shells the planet wears. Both are the same object — a sphere with
## no shading of its own, whose whole appearance is in the shader — so they are
## built in one place and differ only by radius, resolution and material.
func _shell(shell_name: String, radius: float, segments: int,
		material: ShaderMaterial) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	# Enough that the limb reads as a circle rather than as a polygon. The shell
	# is unshaded and untextured, so this is the only thing the count buys.
	sphere.radial_segments = segments
	sphere.rings = segments / 2
	var instance := MeshInstance3D.new()
	instance.name = shell_name
	instance.mesh = sphere
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


# --- Quadtree ---------------------------------------------------------------

func _make_chunk(face: int, offset: Vector2, size: float, depth: int, height := 0.0) -> Chunk:
	var chunk := Chunk.new()
	chunk.face = face
	chunk.offset = offset
	chunk.size = size
	chunk.depth = depth
	# A face's square spans a quarter of a great circle, so half its [-1, 1] width
	# is (pi / 2) * radius of surface.
	chunk.arc = size * PI * shape.radius * 0.25
	# The parent's ground level, not this chunk's own. Asking the height field
	# where the centre sits costs about a third of a millisecond, and a split
	# wants four of those — which at thirty splits a second was the single most
	# expensive thing in the frame. Half a chunk's worth of terrain is a good
	# enough guess for placing an origin, and the build corrects it for free.
	chunk.height = height
	chunk.origin = _direction(chunk, 0.5, 0.5) * (shape.radius + height)
	return chunk


## Distance from the viewer to the chunk's patch of ground, measured to a sphere
## around it so a chunk is not judged by its centre alone.
func _distance(chunk: Chunk, eye: Vector3) -> float:
	return maxf(0.0, eye.distance_to(chunk.origin) - chunk.arc * 0.75)


func _refine(chunk: Chunk, eye: Vector3) -> void:
	# Every level on the path gets a mesh, not just the leaves. A coarse ancestor
	# is what covers the ground while its children are still on the thread pool,
	# so without them the planet has a hole in it wherever the viewer is looking.
	if not chunk.has_mesh() and not chunk.queued:
		_requests.append(chunk)
	_walked += 1
	var distance := _distance(chunk, eye)
	chunk.distance = distance
	var split_at := chunk.arc * _split_reach
	# Nothing subdivides until it has been built. Splitting on distance alone let
	# a viewer at 200 m/s demand levels far faster than the thread pool could
	# supply them, and the tree grew to thousands of meshless nodes that every
	# pass then had to walk — which is what made refining, queueing and drawing
	# each cost tens of milliseconds. Tying growth to what has actually arrived
	# keeps the tree the size of the ground that exists.
	if chunk.depth < max_depth and distance < split_at and chunk.has_mesh():
		# Out of budget the split is simply not made this frame. Nothing records
		# that it was wanted: the same test comes round again next frame, and by
		# then the nearest chunk wanting one may be a different chunk anyway.
		if chunk.children.is_empty() and _splits_left > 0:
			_splits_left -= 1
			_split(chunk)
	elif not chunk.children.is_empty() and distance > split_at * 1.3:
		# Collapsing further out than splitting, so a viewer loitering on the
		# boundary does not rebuild the same four chunks every frame.
		_collapse(chunk)
	for child in chunk.children:
		_refine(child, eye)


func _split(chunk: Chunk) -> void:
	var half := chunk.size * 0.5
	for corner in 4:
		var offset := chunk.offset + Vector2(float(corner % 2) * half, float(corner / 2) * half)
		chunk.children.append(_make_chunk(chunk.face, offset, half, chunk.depth + 1, chunk.height))


func _collapse(chunk: Chunk) -> void:
	for child in chunk.children:
		_collapse(child)
		_drop(child)
	chunk.children.clear()


func _drop(chunk: Chunk) -> void:
	chunk.discarded = true
	if chunk.instance != null:
		chunk.instance.queue_free()
		chunk.instance = null
	if chunk.body != null:
		chunk.body.queue_free()
		chunk.body = null


## Walks the tree deciding what to draw, and returns whether this subtree is fully
## covered. A parent keeps its mesh on screen until every descendant that replaces
## it is ready, so the ground never opens up mid-build.
func _show(chunk: Chunk) -> bool:
	if not chunk.children.is_empty():
		var covered := true
		for child in chunk.children:
			covered = _show(child) and covered
		if covered:
			_set_visible(chunk, false)
			return true
		for child in chunk.children:
			_hide(child)
	if chunk.has_mesh():
		_set_visible(chunk, true)
		_visible.append(chunk)
		return true
	_set_visible(chunk, false)
	return false


func _hide(chunk: Chunk) -> void:
	_set_visible(chunk, false)
	for child in chunk.children:
		_hide(child)


func _set_visible(chunk: Chunk, shown: bool) -> void:
	# Writing visible goes through to the rendering server whether or not it
	# changed, and this runs over every node in the tree every frame.
	if chunk.instance != null and chunk.instance.visible != shown:
		chunk.instance.visible = shown
	# Ground nobody can see is ground nobody can stand on. This is also what
	# retires a parent's collider once its children have taken over.
	if not shown and chunk.body != null:
		chunk.body.queue_free()
		chunk.body = null


# --- Building ---------------------------------------------------------------

func _dispatch(_eye: Vector3) -> void:
	var slots := pending_limit - _pending.size()
	if slots <= 0 or _requests.is_empty():
		return
	# Nearest first: the chunk under the viewer's feet matters more than one on
	# the horizon, and both are in the same queue. Picked by scanning rather than
	# by sorting, because only a handful of slots are ever free and ordering the
	# whole list to take twelve off the front cost more than the builds did.
	for slot in slots:
		var nearest: Chunk = null
		var nearest_at := INF
		for chunk in _requests:
			if not chunk.queued and chunk.distance < nearest_at:
				nearest_at = chunk.distance
				nearest = chunk
		if nearest == null:
			return
		nearest.queued = true
		_pending[WorkerThreadPool.add_task(_build.bind(nearest))] = nearest


func _apply_finished() -> void:
	for task in _pending.keys():
		if WorkerThreadPool.is_task_completed(task):
			WorkerThreadPool.wait_for_task_completion(task)
			_finished.append(_pending[task])
			_pending.erase(task)
	var applied := 0
	while applied < applies_per_frame and not _finished.is_empty():
		var chunk := _finished.pop_front() as Chunk
		chunk.queued = false
		if not chunk.discarded:
			_attach(chunk)
			applied += 1
		chunk.arrays = []


func _attach(chunk: Chunk) -> void:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, chunk.arrays)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = SURFACE_MATERIAL
	# Vertices are stored around the chunk's own origin, so a chunk 8 km from the
	# planet's centre still has small coordinates and a tight bounding box.
	instance.position = chunk.origin
	instance.visible = false
	# Internal, so the hundreds of them stay out of the Scene dock and out of the
	# saved file when the quadtree is running in the editor.
	add_child(instance, false, Node.INTERNAL_MODE_BACK)
	chunk.instance = instance
	_built_meshes += 1


## Runs on a worker thread. Touches nothing but the chunk it was handed and the
## shape, which is read-only once prepared.
func _build(chunk: Chunk) -> void:
	var resolution := chunk_resolution
	# One skirt ring outside the patch on every side, so the grid is the patch
	# plus a border rather than a patch with special cases at its edges.
	var side := resolution + 3
	var count := side * side
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	uvs.resize(count)

	var spacing := chunk.arc / float(resolution)
	# On a worker thread, where a height-field sample is free as far as the frame
	# is concerned. This is what any children of this chunk will place themselves
	# against instead of sampling for themselves.
	chunk.height = shape.elevation(_direction(chunk, 0.5, 0.5), spacing)
	# Deep enough to cover the step where a coarser neighbour's smoothed terrain
	# meets this chunk's, which scales with the chunk because that is what decides
	# how much of the height field each level is allowed to see.
	var skirt := chunk.arc * skirt_scale
	var last := side - 1

	for row in side:
		var v_index := clampi(row - 1, 0, resolution)
		for col in side:
			var u_index := clampi(col - 1, 0, resolution)
			var direction := _direction(chunk,
				float(u_index) / float(resolution),
				float(v_index) / float(resolution))
			var height := shape.elevation(direction, spacing)
			var normal := shape.normal_at(direction, spacing)
			var radius := shape.radius + height
			if row == 0 or col == 0 or row == last or col == last:
				radius -= skirt
			var index := row * side + col
			vertices[index] = direction * radius - chunk.origin
			normals[index] = normal
			colors[index] = shape.color_at(direction, height, normal)
			uvs[index] = Vector2(float(u_index), float(v_index)) / float(resolution)

	var indices := PackedInt32Array()
	indices.resize(last * last * 6)
	var write := 0
	for row in last:
		for col in last:
			var corner := row * side + col
			# Clockwise seen from outside, which is Godot's front face.
			indices[write] = corner
			indices[write + 1] = corner + side
			indices[write + 2] = corner + 1
			indices[write + 3] = corner + 1
			indices[write + 4] = corner + side
			indices[write + 5] = corner + side + 1
			write += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	chunk.arrays = arrays
	chunk.triangles = indices.size() / 3

	if chunk.depth >= _collision_min_depth:
		chunk.collision_faces = _collision_from(vertices, side, resolution)


## Triangles for the collider, taken from the patch only: the skirt hangs below
## the ground and would catch anything that walked over the chunk's edge.
func _collision_from(vertices: PackedVector3Array, side: int,
		resolution: int) -> PackedVector3Array:
	var faces := PackedVector3Array()
	faces.resize(resolution * resolution * 6)
	var write := 0
	for row in resolution:
		for col in resolution:
			var corner := (row + 1) * side + col + 1
			faces[write] = vertices[corner]
			faces[write + 1] = vertices[corner + side]
			faces[write + 2] = vertices[corner + 1]
			faces[write + 3] = vertices[corner + 1]
			faces[write + 4] = vertices[corner + side]
			faces[write + 5] = vertices[corner + side + 1]
			write += 6
	return faces


# --- Collision --------------------------------------------------------------

func _update_collision(eye: Vector3) -> void:
	var built := 0
	for chunk in _visible:
		var near := _distance(chunk, eye) < collision_range and not chunk.collision_faces.is_empty()
		if near and chunk.body == null:
			if built >= bodies_per_frame:
				continue
			built += 1
			chunk.body = _make_body(chunk)
		elif not near and chunk.body != null:
			chunk.body.queue_free()
			chunk.body = null


func _make_body(chunk: Chunk) -> StaticBody3D:
	var shape_resource := ConcavePolygonShape3D.new()
	shape_resource.set_faces(chunk.collision_faces)
	var collider := CollisionShape3D.new()
	collider.shape = shape_resource
	var body := StaticBody3D.new()
	body.position = chunk.origin
	body.add_child(collider)
	add_child(body, false, Node.INTERNAL_MODE_BACK)
	return body


# --- Geometry ---------------------------------------------------------------

## The unit direction at a point inside a chunk, given in the chunk's own [0, 1]
## coordinates.
func _direction(chunk: Chunk, u: float, v: float) -> Vector3:
	var basis_axes: Array = FACES[chunk.face]
	var face_u := chunk.offset.x + u * chunk.size
	var face_v := chunk.offset.y + v * chunk.size
	return (basis_axes[0] as Vector3
		+ (basis_axes[1] as Vector3) * _spread(face_u)
		+ (basis_axes[2] as Vector3) * _spread(face_v)).normalized()


## Pushes cube coordinates out toward the edges before they are normalized.
## Without it a face's middle quads project far larger than its corner ones, and
## triangle size — which is what the LOD is budgeting — varies by about 1.4x
## across a single chunk.
func _spread(coordinate: float) -> float:
	return tan(coordinate * PI * 0.25)


## Where the detail is being built around, in planet-local metres. Public because
## the sea has to follow the same point the ground does, and because working out
## what counts as a viewer in the editor is a job with one right answer.
func viewer_position() -> Vector3:
	if is_instance_valid(viewer):
		return to_local(viewer.global_position)
	# In the editor the detail has to follow the camera being flown around the
	# scene, which is not the edited scene's own camera and is not reachable
	# through this node's viewport. Reached through the engine rather than named
	# outright, because `EditorInterface` does not exist in an exported build and
	# naming it there is a compile error rather than a branch never taken.
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var editor := Engine.get_singleton(&"EditorInterface")
		var view := editor.call(&"get_editor_viewport_3d", 0) as SubViewport
		var editor_camera := view.get_camera_3d() if view != null else null
		if editor_camera != null:
			return to_local(editor_camera.global_position)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		return to_local(camera.global_position)
	return Vector3.ZERO
