@tool
class_name FishSchool
extends Node3D

## Schools of VAT-animated fish, kept over whatever ocean the viewer is near.
##
## The body animation is entirely the GPU's: the swim cycle is a baked vertex
## texture and no bone is posed anywhere. What the CPU keeps is where each fish
## is, and it keeps it the cheap way — a school is a circle, a fish is a fixed
## seat in that school's formation, and both are closed-form functions of the
## clock. There is no per-fish velocity, no neighbour search and no state that
## can drift, so a shoal is a few hundred vector operations and one MultiMesh
## buffer write a frame however many fish are in it.
##
## Each school is its own MultiMesh, which is what lets the field be as wide as
## the sea: a school out of sight is not drawn and a school out of earshot is
## not even re-posed, so the cost is what is in front of you rather than what
## exists.
##
## The one thing that is not a function of the clock alone is people. A swimmer
## inside a school pushes the fish nearest them outward, and because the push is
## a function of distance rather than something integrated over time, the
## formation opens as you arrive and closes behind you without ever being able
## to wander off its circle.
##
## Where the schools are is streamed rather than authored. A fixed pool of them
## is sited on the sea floor around the viewer's own ground track, and a school
## the viewer has swum away from is re-sited somewhere ahead rather than being
## built again: the nodes, the MultiMeshes and the seats in each formation all
## outlive the water they are swimming in. That is what puts fish in every ocean
## on the planet for the cost of the one you are in, and it is deliberately the
## same bargain the coral makes — both are a small live set picked out of an
## endless field by distance from the viewer. It is also what finally ties the
## two together: a swarm told to hold station over a bed eight to thirty metres
## down now finds coral wherever coral grows, instead of only in the bay it
## happened to be built in.

## How much further along the ground than [member scatter_radius] the viewer has
## to be before a school is retired. Hysteresis, and nothing more: a school sited
## at the very edge of the ring must not be retired by the next step taken.
const RETIRE_MARGIN := 1.25
## Nearest a fresh school is sited, as a multiple of [member draw_within]. Just
## outside the distance anything is drawn from, so a school arriving behind the
## viewer arrives out of sight and is swum up to rather than appearing.
const SITE_CLEARANCE := 1.15
## Sea floors tried before a school gives up and waits.
const SITE_ATTEMPTS := 12
## Seconds a school waits before searching again after finding nowhere to be.
## Over land — or over an ocean too deep for a swarm that wants a reef — every
## school would otherwise search the height field again on every frame forever.
const SITE_RETRY := 0.7

@export var model: PackedScene
@export var material: ShaderMaterial
@export var vat: VatClip
## Fish in total, shared out between the schools.
##
## Both of these are now the size of the pool the streaming ring draws from, not
## the size of a place. What reaches the screen is set by [member scatter_radius]
## and [member draw_within] between them: raising the count at a fixed radius
## makes the sea denser and costs frame time, while raising both together widens
## the ring at the same density and costs only memory.
@export_range(1, 96000) var instance_count := 540
@export_range(1, 128) var cluster_count := 18
@export var random_seed := 20260808
@export var fish_length := 1.15
## MeshMaker authored this fish lengthwise on local +X.
@export_range(-1.0, 1.0, 2.0) var model_forward_sign := 1.0

@export_group("Where they live")
@export var minimum_depth := 2.5
@export var maximum_depth := 12.0
@export var seabed_clearance := 1.4
## Hold station just over the sea bed instead of hanging in the column. This is
## what puts a swarm on the reef: the coral grows in a fixed band of depth, so a
## school told to stay [member hover_above_bed] over a bed that is between
## [member bed_between] metres down is over coral without either of them ever
## having been told about the other.
@export var hug_seabed := false
@export var hover_above_bed := 2.6
@export var bed_between := Vector2(8.0, 30.0)
## Metres of sea floor around the viewer that schools are kept sited over.
##
## This is the whole extent of the field, and it is a streaming radius rather
## than the size of a place: schools beyond it are retired and re-sited nearer,
## so the ring travels with the viewer and every ocean on the planet has fish in
## it. Worth being comfortably wider than [member draw_within] — the gap between
## the two is the room a school has to be sited in unseen and then swum up to.
@export var scatter_radius := 1100.0
## Schools sited or re-sited per frame.
##
## Siting reads the height field, so this is a budget and not a preference. A
## school that misses its turn is simply still retired on the next frame, and a
## retired school is one nobody could have seen anyway.
@export_range(1, 16) var max_sites_per_frame := 2
## Radius of the shoal itself. Small on purpose: real fish hold station about a
## body length apart, and a school you can see the shape of is a school.
@export var cluster_radius := 2.6

@export_group("Swimming")
## Metres a second the schools travel, and the radius of the loop they travel
## it on. Together these are the turn rate, which is what actually reads as
## speed from the shore.
@export var cruise_speed := 3.6
@export var school_orbit := 15.0
## Metres a fish weaves either side of its seat, and how fast.
@export var weave := 0.55
@export var weave_rate := 1.7
## Past this from the viewer a school stops being drawn, and past the nearer of
## the two it stops being re-posed as well. A school nobody can see does not
## need to be anywhere in particular.
@export var simulate_within := 220.0
@export var draw_within := 340.0

@export_group("CPU pose budget")
## VAT keeps every body swimming smoothly on the GPU. These rates only control
## how often the CPU refreshes a school's formation movement and avoidance.
## Nearby updates remain faster than a fish can visibly cross its own length;
## distant schools can update less often without changing their count or path.
@export var pose_near_within := 55.0
@export_range(1.0, 120.0, 1.0) var pose_rate_near := 45.0
@export_range(1.0, 60.0, 1.0) var pose_rate_far := 15.0
## Prevent several due schools from uploading large MultiMesh buffers on the
## same rendered frame. Overdue schools are first in line on the next frame.
@export_range(1, 16) var max_pose_updates_per_frame := 4

@export_group("Colour")
## Give every fish its own colour through the MultiMesh colour channel.
##
## The alternative would be a material per colour and a MultiMesh per material,
## which is a draw call per colour and an end to one school being one call. The
## catch is that an instance colour multiplies the mesh's own vertex colour, so
## the model has to have been painted pale for anything to come through — the
## swarm fish is repainted grey in `build_reef_assets.py` for exactly this.
@export var random_colours := false
@export_range(0.0, 1.0) var colour_saturation := 0.7
@export_range(0.0, 2.0) var colour_brightness := 1.0

@export_group("Avoiding people")
## Metres from a swimmer the fish start giving way, and how far they are pushed
## by someone right on top of them.
@export var avoid_reach := 4.5
@export var avoid_push := 3.4
## How much of the push also turns a fish, as a share of a right angle. Fish
## that slide sideways without facing where they are going read as debris.
@export_range(0.0, 1.0) var avoid_turn := 0.75

var _planet: Planet
var _shape: PlanetShape
var _water: PlanetWater
## One entry per school: the circle it swims, the seats in it, its own MultiMesh
## and the buffer that is written back into it.
var _schools: Array[Dictionary] = []
var _transforms: Array[Transform3D] = []
var _clock := 0.0
## Kept past the build, because siting is now something that happens for as long
## as the game runs rather than once. Seeded, so the formations are the same
## every run even though where they end up swimming depends on where you go.
var _rng := RandomNumberGenerator.new()
## Passed to the pose of a school that has just been sited. Sited schools start
## further off than anything is drawn from, so there is nobody to give way to.
var _nobody: Array[Vector3] = []


func _ready() -> void:
	set_process(false)
	set_physics_process(false)
	if Engine.is_editor_hint():
		return
	call_deferred("_build")


func _build() -> void:
	_planet = get_parent() as Planet
	if _planet == null or _planet.shape == null or _planet.water == null:
		push_error("FishSchool must be a child of a watery Planet")
		return
	_shape = _planet.shape
	_water = _planet.water
	if model == null or material == null or vat == null:
		push_error("FishSchool is missing its model, material, or VAT")
		return
	var mesh := _mesh_from(model)
	if mesh == null:
		push_error("FishSchool model contains no mesh")
		return
	var school_material := material.duplicate(true) as ShaderMaterial
	if not vat.validate_mesh(mesh) or not vat.apply(school_material):
		return

	_rng.seed = random_seed
	var authored := maxf(maxf(mesh.get_aabb().size.x, mesh.get_aabb().size.y),
		mesh.get_aabb().size.z)
	var base_scale := fish_length / maxf(authored, 0.01)

	# Every school is built retired: it has its fish, its formation and its own
	# MultiMesh, and no water yet. Where it swims is decided by the first survey
	# and re-decided for the rest of the run, so nothing here needs to know
	# whether there is an ocean anywhere near the viewer at the moment.
	#
	# Shared out rather than divided, so a count that does not go evenly into
	# the schools still spends all of itself.
	_transforms.resize(instance_count)
	var placed := 0
	for index in cluster_count:
		var share := (instance_count * (index + 1)) / cluster_count - placed
		if share <= 0:
			continue
		var school := {
			"first": placed,
			"seats": _formation(share, base_scale, _rng),
			"sited": false,
			# Held so the survey can measure and the pose can read before either
			# has anywhere real to point at.
			"direction": Vector3.UP,
			"centre": Vector3.ZERO,
			"orbit": school_orbit,
			"next_site": 0.0,
			"next_pose": 0.0,
		}
		placed += share

		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_custom_data = true
		multimesh.use_colors = random_colours
		multimesh.instance_count = share
		multimesh.mesh = mesh

		var node := MultiMeshInstance3D.new()
		node.name = "Fish%d" % index
		node.multimesh = multimesh
		node.material_override = school_material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		# Nothing is in the buffer and the bounds are meaningless until this
		# school is given somewhere to be, which is also why it is hidden.
		node.visible = false
		# Whole-school poses already arrive from _process at a distance-scaled
		# rate. Server-side physics interpolation would duplicate those buffer
		# updates even though no physics transform drives the fish.
		node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(node, false, Node.INTERNAL_MODE_BACK)
		school["node"] = node
		_schools.append(school)
	set_process(true)


func _process(delta: float) -> void:
	if not RuntimeTelemetry.deep_enabled():
		_advance(delta)
		return
	var began := Time.get_ticks_usec()
	_advance(delta)
	RuntimeTelemetry.record_process_step(
		&"aerial", &"school_process", Time.get_ticks_usec() - began)


func _advance(delta: float) -> void:
	_clock += delta
	var eye := _planet.viewer_position()
	_keep_sited(eye)
	var due: Array[Dictionary] = []
	for school in _schools:
		if not bool(school["sited"]):
			continue
		var away := eye.distance_to(school["centre"] as Vector3) \
			- float(school["orbit"])
		var node := school["node"] as MultiMeshInstance3D
		node.visible = away < draw_within
		if away > simulate_within:
			continue
		if _clock < float(school.get("next_pose", 0.0)):
			continue
		school["pose_away"] = away
		due.append(school)
	if due.is_empty():
		return
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["pose_away"]) < float(b["pose_away"]))
	var swimmers := _swimmers()
	for index in mini(due.size(), max_pose_updates_per_frame):
		var school := due[index]
		var node := school["node"] as MultiMeshInstance3D
		node.multimesh.buffer = _pose(school, _clock, swimmers)
		var rate := lerpf(pose_rate_near, pose_rate_far,
			smoothstep(pose_near_within, simulate_within,
				maxf(float(school["pose_away"]), 0.0)))
		school["next_pose"] = _clock + 1.0 / maxf(rate, 1.0)


# --- Swimming ---------------------------------------------------------------

## One school's transforms for one instant, as a MultiMesh buffer. Planet-local
## throughout: this node sits on the planet with no transform of its own, so
## what goes into the MultiMesh is what comes out of here.
##
## Built fresh and returned rather than written in place. A PackedFloat32Array
## is a value: one fetched out of the school's dictionary would be a copy the
## moment it was written to, and the school would keep the buffer it had.
func _pose(school: Dictionary, seconds: float,
		swimmers: Array[Vector3]) -> PackedFloat32Array:
	var radius := _shape.radius
	var anchor: Vector3 = school["direction"]
	var east: Vector3 = school["east"]
	var north: Vector3 = school["north"]
	var orbit: float = school["orbit"]
	var rate: float = school["rate"]
	var first := int(school["first"])
	var seats: Array = school["seats"]
	var buffer := PackedFloat32Array()
	buffer.resize(seats.size() * _stride())

	# Where the school is on its circle, and which way that has it facing. The
	# tangent is the derivative with respect to *time*, so it carries the sign
	# of the rate — without that the half of the schools that circle the other
	# way swim backwards along their own path.
	var angle := float(school["phase"]) + seconds * rate
	var centre := (anchor
		+ (east * cos(angle) + north * sin(angle)) * (orbit / radius)).normalized()
	var travel := (-east * sin(angle) + north * cos(angle)) * rate
	var school_heading := (travel - centre * travel.dot(centre)).normalized()
	if school_heading.is_zero_approx():
		school_heading = east

	for index in seats.size():
		var seat: Dictionary = seats[index]
		var heading := school_heading

		# The fish's seat, plus a weave of its own so a school is not a lattice.
		var seat_offset: Vector3 = seat["offset"]
		var beat: float = seconds * weave_rate + float(seat["phase"])
		var across := seat_offset.z + sin(beat) * weave
		var along := seat_offset.x + sin(beat * 0.73 + 1.1) * weave * 0.6
		var side := centre.cross(heading).normalized()
		var at := (centre + (heading * along + side * across) / radius).normalized()

		var depth: float = float(school["depth"]) + seat_offset.y \
			+ sin(beat * 0.51 + 2.3) * 0.35
		depth = clampf(depth, minimum_depth, float(school["deepest"]))
		var point := at * (radius - depth)

		# Giving way. Both the displacement and the turn come from the same
		# push, so a fish that is being shoved aside is also looking that way.
		var shove := Vector3.ZERO
		for swimmer in swimmers:
			var away: Vector3 = point - swimmer
			var span := away.length()
			if span >= avoid_reach or span < 0.0001:
				continue
			var force := 1.0 - span / avoid_reach
			shove += (away / span) * (force * force * avoid_push)
		if not shove.is_zero_approx():
			point += shove
			at = point.normalized()
			# Back onto the shell: a push from below would otherwise beach them.
			point = at * (radius - clampf(radius - point.length(),
				minimum_depth, float(school["deepest"])))
			var flat := shove - at * shove.dot(at)
			if not flat.is_zero_approx():
				heading = heading.lerp(flat.normalized(),
					clampf(flat.length() / maxf(avoid_push, 0.01), 0.0, 1.0)
						* avoid_turn)

		heading = (heading - at * heading.dot(at)).normalized()
		if heading.is_zero_approx():
			heading = east
		# A little roll into the turn, which is most of what tells a swimming
		# fish from a towed one.
		var up := (Basis(heading, sin(beat * 0.9) * 0.12) * at).normalized()
		var forward := heading * model_forward_sign
		var body := Transform3D(
			Basis(forward, up, forward.cross(up).normalized())
				.scaled(Vector3.ONE * float(seat["scale"])),
			point)
		_transforms[first + index] = body
		_write_instance(buffer, index, body, seat["custom"] as Color,
			seat["tint"] as Color)
	return buffer


## Everyone who might be swimming through a school, in planet-local metres. Read
## per frame rather than cached: people join and leave, and there are never many.
func _swimmers() -> Array[Vector3]:
	var found: Array[Vector3] = []
	for node in get_tree().get_nodes_in_group(&"network_players"):
		var body := node as Node3D
		if body != null:
			found.append(_planet.to_local(body.global_position))
	return found


func _formation(count: int, base_scale: float,
		rng: RandomNumberGenerator) -> Array:
	var seats := []
	for _index in count:
		seats.append({
			# A flattened ball of seats: schools are wider than they are deep.
			"offset": Vector3(rng.randfn(0.0, cluster_radius),
				rng.randfn(0.0, cluster_radius * 0.35),
				rng.randfn(0.0, cluster_radius)),
			"phase": rng.randf() * TAU,
			"scale": base_scale * rng.randf_range(0.82, 1.2),
			# x is unused by the fish shader; y is the VAT phase, so each fish
			# is at its own point in the same baked swim cycle.
			"custom": Color(rng.randf(), rng.randf(), rng.randf(), rng.randf()),
			"tint": (Color.from_hsv(rng.randf(),
					colour_saturation * rng.randf_range(0.7, 1.0),
					colour_brightness * rng.randf_range(0.85, 1.0))
				if random_colours else Color.WHITE),
		})
	return seats


## The water one school passes through, as a box, grown by everything that can
## move a fish out of its seat. Culling is against this and it is never
## recomputed, so it has to be generous rather than tight.
func _swimming_bounds(school: Dictionary) -> AABB:
	var reach := cluster_radius * 3.0 + weave + avoid_push + fish_length * 2.0
	var span: float = float(school["orbit"]) + reach
	return AABB((school["centre"] as Vector3) - Vector3.ONE * span,
		Vector3.ONE * span * 2.0)


## Floats a MultiMesh spends on one instance: twelve of transform, then the
## optional colour, then the custom data. Godot packs them in that order and
## reads the buffer by stride, so the colour channel moves the custom data.
func _stride() -> int:
	return 20 if random_colours else 16


func _write_instance(buffer: PackedFloat32Array, index: int,
		placed: Transform3D, custom: Color, tint: Color) -> void:
	var at := index * _stride()
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
	if random_colours:
		buffer[at + 12] = tint.r
		buffer[at + 13] = tint.g
		buffer[at + 14] = tint.b
		buffer[at + 15] = tint.a
		at += 4
	buffer[at + 12] = custom.r
	buffer[at + 13] = custom.g
	buffer[at + 14] = custom.b
	buffer[at + 15] = custom.a


# --- Where the schools are ---------------------------------------------------

## Retires the schools the viewer has left behind and sites them again around
## wherever the viewer is now.
##
## Measured along the ground rather than through the air, which is the one thing
## this has to get right: climbing to nine kilometres must not read as having
## left every ocean on the planet. A school under a flying player keeps its water
## and is simply neither drawn nor re-posed by the ordinary distance rules, so it
## is still there on the way back down — and a school is never retired while it
## could be seen, because the ring is wider than the draw distance by design.
func _keep_sited(eye: Vector3) -> void:
	var eye_direction := eye.normalized()
	if eye_direction.is_zero_approx():
		return
	var retire_beyond := scatter_radius * RETIRE_MARGIN
	var budget := max_sites_per_frame
	for school in _schools:
		if bool(school["sited"]):
			var along_ground := eye_direction.angle_to(
				school["direction"] as Vector3) * _shape.radius
			if along_ground <= retire_beyond:
				continue
			school["sited"] = false
			(school["node"] as MultiMeshInstance3D).visible = false
		if budget <= 0 or _clock < float(school["next_site"]):
			continue
		budget -= 1
		if not _site(school, eye_direction):
			school["next_site"] = _clock + SITE_RETRY


## Finds one school a circle of sea floor within [member scatter_radius] of the
## viewer's ground track, or reports that there was nowhere for it to be.
func _site(school: Dictionary, eye_direction: Vector3) -> bool:
	var radius := _shape.radius
	var east := eye_direction.cross(Vector3.UP if absf(eye_direction.y) < 0.9
		else Vector3.RIGHT).normalized()
	var north := eye_direction.cross(east).normalized()
	var nearest := draw_within * SITE_CLEARANCE
	if nearest >= scatter_radius:
		# A field configured to draw further than it streams would otherwise
		# never site anything at all. Half the ring is not what was asked for,
		# but it is somewhere, and the alternative is an empty sea.
		nearest = scatter_radius * 0.5
	for _attempt in SITE_ATTEMPTS:
		# Spread over the ring's area rather than over its width, which would
		# crowd every school onto the inner edge of it.
		var span := sqrt(lerpf(nearest * nearest,
			scatter_radius * scatter_radius, _rng.randf()))
		var bearing := _rng.randf() * TAU
		var direction_at := (eye_direction
			+ (east * cos(bearing) + north * sin(bearing))
				* (span / radius)).normalized()
		# One reading of the height field before the nine below. Most of any
		# planet is land, and most of the sea is too shallow for a given school,
		# so throwing those out on a single sample is what makes searching again
		# every frame affordable.
		#
		# Only the shallow half of each rule is applied here, which is what keeps
		# this a pre-filter rather than a second opinion: the depth read at the
		# centre is the deepest the circle can be, so water too shallow here is
		# certainly too shallow somewhere, while water deeper than a reef swarm
		# wants may still shoal to exactly the right band a few metres around.
		var here := -_shape.elevation(direction_at, _planet.finest_spacing())
		if here < minimum_depth + seabed_clearance:
			continue
		if hug_seabed and here < bed_between.x:
			continue
		var orbit := school_orbit * _rng.randf_range(0.75, 1.25)
		# The whole circle has to be swimmable, not just its middle, so the
		# shallowest water anywhere on it is what sets the depths below.
		var shallowest := _shallowest_over(direction_at, orbit)
		if shallowest < minimum_depth + seabed_clearance:
			continue
		if hug_seabed and (shallowest < bed_between.x
				or shallowest > bed_between.y):
			continue
		var floor_limit := shallowest - seabed_clearance
		var depth := clampf(shallowest * _rng.randf_range(0.3, 0.6),
			minimum_depth, minf(maximum_depth, floor_limit))
		if hug_seabed:
			# Measured up from the bed rather than down from the surface, which
			# is the whole difference between a swarm on a reef and a swarm that
			# happens to be over one.
			depth = clampf(shallowest - hover_above_bed,
				minimum_depth, floor_limit)
		if _water.depth_at(_planet.to_global(
				direction_at * (radius - depth))) < minimum_depth:
			continue
		var facing := (east - direction_at * east.dot(direction_at)).normalized()
		if facing.is_zero_approx():
			facing = direction_at.cross(Vector3.UP
				if absf(direction_at.y) < 0.9 else Vector3.RIGHT).normalized()
		school["direction"] = direction_at
		school["centre"] = direction_at * (radius - depth)
		school["east"] = facing
		school["north"] = direction_at.cross(facing).normalized()
		school["orbit"] = orbit
		school["depth"] = depth
		school["deepest"] = floor_limit if hug_seabed \
			else minf(maximum_depth, floor_limit)
		school["phase"] = _rng.randf() * TAU
		# Signed, so half the schools circle the other way and two that meet do
		# not look like one animation played twice.
		school["rate"] = (cruise_speed / maxf(orbit, 1.0)) \
			* (1.0 if _rng.randf() < 0.5 else -1.0)
		school["sited"] = true
		# Staggered, so schools sited on the same frame do not go on to upload
		# their live poses on the same frame as each other for ever after.
		school["next_pose"] = _clock + _rng.randf() / maxf(pose_rate_near, 1.0)
		var multimesh := (school["node"] as MultiMeshInstance3D).multimesh
		# The school travels, so its bounds are the water it travels through
		# rather than where the fish are on the frame it was sited.
		multimesh.custom_aabb = _swimming_bounds(school)
		# Written as one whole-buffer assignment rather than instance by
		# instance: at this count the per-instance setters cost more than the
		# array does.
		multimesh.buffer = _pose(school, _clock, _nobody)
		return true
	return false


## Depth of water at the shallowest point of a school's circle, in metres.
##
## The nine samples are taken when a school is sited and never again while it is
## swimming there, which is why siting is budgeted and posing is not: this is the
## only part of the whole system that reads the height field at all.
func _shallowest_over(direction_at: Vector3, orbit: float) -> float:
	var east := direction_at.cross(Vector3.UP if absf(direction_at.y) < 0.9
		else Vector3.RIGHT).normalized()
	var north := direction_at.cross(east)
	var reach := (orbit + cluster_radius * 2.5 + avoid_push) / _shape.radius
	var shallowest := -_shape.elevation(direction_at, _planet.finest_spacing())
	for step in 8:
		var angle := TAU * float(step) / 8.0
		var around := (direction_at
			+ (east * cos(angle) + north * sin(angle)) * reach).normalized()
		shallowest = minf(shallowest,
			-_shape.elevation(around, _planet.finest_spacing()))
	return shallowest


func _mesh_from(scene_resource: PackedScene) -> Mesh:
	var scene := scene_resource.instantiate()
	var best: Mesh
	var most_vertices := -1
	for found in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		var candidate := mesh_instance.mesh
		if candidate == null:
			continue
		var vertices := 0
		for surface in candidate.get_surface_count():
			vertices += candidate.surface_get_array_len(surface)
		if vertices > most_vertices:
			most_vertices = vertices
			best = candidate
	scene.queue_free()
	return best


## Every fish that is actually somewhere, in planet-local metres.
##
## Retired schools are left out rather than reported at the origin. A school with
## nowhere to be has no position to give, and a caller checking that the fish are
## all in water would otherwise be handed the centre of the planet.
func fish_transforms() -> Array[Transform3D]:
	var found: Array[Transform3D] = []
	for school in _schools:
		if not bool(school["sited"]):
			continue
		var first := int(school["first"])
		for index in (school["seats"] as Array).size():
			found.append(_transforms[first + index])
	return found


## Seats across every school, sited or not — what the field would draw if the
## viewer were somewhere every one of them had found water.
func seat_count() -> int:
	var seats := 0
	for school in _schools:
		seats += (school["seats"] as Array).size()
	return seats


## Schools with water under them at the moment.
func sited_schools() -> int:
	var sited := 0
	for school in _schools:
		sited += 1 if bool(school["sited"]) else 0
	return sited
