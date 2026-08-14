extends Node

## Checks that a scar is really part of the ground and not a picture of one.
##
##     godot --headless --path . dev/_terrain_scar_test.tscn
##
## The registry half runs against a bare [TerrainScars] and needs nothing. The
## rest opens the world, because the thing worth proving is that the crater is
## in the *same* height field the mesh is built from, the collider generated
## from, and the player's ground guard reads — and that is a claim about the
## live planet, not about a data structure.

const WORLD := preload("res://game/world.tscn")
const TERRAIN_FRAMES := 130
## Long enough for a marked region to be walked, queued, built on the pool and
## attached. The quadtree spends a per-frame budget on rebuilds rather than
## doing them all at once, which is the point of marking rather than rebuilding.
const REBUILD_FRAMES := 220

const CRATER_RADIUS := 6.0
const CRATER_DEPTH := 2.5

## The dive the punch is thrown out of. Well past the ability's own 200 m/s top
## speed, since being faster than the punch is the whole point of the case, and
## far enough up that the fifty metres of powered reach are long gone before the
## ground arrives.
const DIVE_SPEED := 600.0
const DIVE_HEIGHT := 400.0

## The swept-beam watch: how many points per ring, how far out the outermost
## ring sits, and how long to hold the trigger for. Long enough that rebuilds
## overlap one another rather than each finishing before the next is asked for.
const SWEEP_SAMPLES := 12
const SWEEP_REACH := 60.0
const SWEEP_FRAMES := 260

var _failures := 0
var _planet: Planet
var _world: GameWorld


func _ready() -> void:
	_check_registry()
	_check_profiles()
	_check_wire()
	_check_warped_rim()
	_check_authored_ability_scars()

	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _wait(10)
	_planet = _world.find_child("Planet", true, false) as Planet
	var site := _world.find_child("LandingSite", true, false) as Node3D
	var player := get_tree().get_first_node_in_group("network_players") \
		as OnlinePlayer
	if _planet == null or site == null or player == null:
		push_error("terrain_scar_test: planet=%s site=%s player=%s" % [
			_planet, site, player])
		get_tree().quit(1)
		return
	player.global_transform = site.global_transform
	player.velocity = Vector3.ZERO
	await _wait(TERRAIN_FRAMES)

	await _check_live_crater(player)
	await _check_no_hole_while_rebuilding(player)
	await _check_no_hole_while_sweeping(player)
	_check_snapshot()
	await _check_punch_landing(player)
	await _check_dive_punch(player)

	print("terrain_scar_test: %s" % (
		"all checks passed" if _failures == 0 else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


## The bucket lookup, which is the only reason this is fast enough to sit on the
## elevation path at all.
func _check_registry() -> void:
	var scars := TerrainScars.new()
	scars.planet_radius = 8000.0
	_expect(is_zero_approx(scars.depth_at(Vector3.UP)),
		"an empty registry costs nothing and cuts nothing")
	_expect(not scars.overlaps(Vector3.UP * 8000.0, 100.0),
		"and overlaps nothing")

	var here := Vector3(0.3, 0.9, 0.31).normalized()
	var scar := TerrainScars.Scar.new()
	scar.direction = here
	scar.radius = 10.0
	scar.depth = 3.0
	scars.add(scar)
	_expect(scars.count() == 1, "a scar is remembered")
	_expect(is_equal_approx(scars.depth_at(here), 3.0),
		"and is at full depth in its middle")
	# One metre across the surface is a hair of arc at this radius; the point is
	# that a query a long way off finds nothing, without walking every record.
	var away := (here + Vector3(0.02, 0.0, 0.0)).normalized()
	_expect(is_zero_approx(scars.depth_at(away)),
		"and nothing well outside its rim")
	_expect(scars.overlaps(here * 8000.0, 1.0),
		"a patch of ground over it reports the overlap")

	# Two marks on the same spot take the deeper, not the sum. A laser held on
	# one place commits several, and adding them would bore a shaft.
	var second := TerrainScars.Scar.new()
	second.direction = here
	second.radius = 10.0
	second.depth = 1.0
	scars.add(second)
	_expect(is_equal_approx(scars.depth_at(here), 3.0),
		"overlapping scars take the deepest rather than the sum")

	# Coarse sampling fades a mark out rather than aliasing it into a spike at
	# whichever vertex happened to land inside.
	_expect(scars.depth_at(here, 40.0) < 0.01,
		"a mark smaller than the sampling disappears instead of spiking")

	var burn := TerrainScars.Scar.new()
	burn.direction = here
	burn.radius = 10.0
	burn.char = 1.0
	burn.tint = Color.BLACK
	scars.add(burn)
	var ground := Color(0.6, 0.5, 0.4, 0.25)
	var burned := scars.tint(here, ground)
	_expect(burned.r < ground.r * 0.2, "a burn blackens the ground under it")
	_expect(is_equal_approx(burned.a, ground.a),
		"and leaves wetness alone, which is what the alpha channel is")

	scars.clear()
	_expect(scars.count() == 0 and is_zero_approx(scars.depth_at(here)),
		"clearing forgets everything")


func _check_profiles() -> void:
	var scars := TerrainScars.new()
	scars.planet_radius = 8000.0
	var here := Vector3.UP
	for profile: int in [TerrainScars.Profile.BOWL, TerrainScars.Profile.CONE,
			TerrainScars.Profile.GROOVE]:
		scars.clear()
		var scar := TerrainScars.Scar.new()
		scar.direction = here
		scar.radius = 20.0
		scar.depth = 4.0
		scar.profile = profile as TerrainScars.Profile
		scars.add(scar)
		_expect(is_equal_approx(scars.depth_at(here), 4.0),
			"profile %d is at full depth in the middle" % profile)
		var rim := _offset(here, 19.9, 8000.0)
		_expect(scars.depth_at(rim) < 0.5,
			"profile %d has come back up at its rim" % profile)
		var beyond := _offset(here, 21.0, 8000.0)
		_expect(is_zero_approx(scars.depth_at(beyond)),
			"profile %d cuts nothing outside itself" % profile)
	# The one thing the three shapes must not agree on: a beam planes a strip
	# off the top and an impact digs a pit, so half way out they differ.
	var half := _offset(here, 10.0, 8000.0)
	var groove := _depth_of(TerrainScars.Profile.GROOVE, half)
	var bowl := _depth_of(TerrainScars.Profile.BOWL, half)
	var cone := _depth_of(TerrainScars.Profile.CONE, half)
	_expect(groove > bowl and bowl > cone,
		"a groove is flatter-floored than a bowl, and a bowl than a cone")


func _check_wire() -> void:
	var scar := TerrainScars.Scar.new()
	scar.direction = Vector3(1.0, 2.0, 3.0).normalized()
	scar.radius = 7.0
	scar.depth = 1.25
	scar.profile = TerrainScars.Profile.CONE
	scar.char = 0.75
	scar.tint = Color(0.1, 0.09, 0.08)
	scar.warp = 0.3
	scar.seed = 2.75
	var back := TerrainScars.Scar.from_wire(scar.to_wire())
	_expect(back.direction.is_equal_approx(scar.direction)
		and is_equal_approx(back.radius, scar.radius)
		and is_equal_approx(back.depth, scar.depth)
		and back.profile == scar.profile
		and is_equal_approx(back.char, scar.char)
		and is_equal_approx(back.warp, scar.warp)
		and is_equal_approx(back.seed, scar.seed),
		"a scar survives the round trip to the wire")


## A blast big enough to throw the ground about does not leave a round hole. What
## has to hold is that the rim wanders, that it wanders the same way for everybody
## who received it, and that it still stops somewhere the registry knows about.
func _check_warped_rim() -> void:
	var scars := TerrainScars.new()
	scars.planet_radius = 8000.0
	var here := Vector3(0.41, 0.82, -0.4).normalized()
	var scar := TerrainScars.Scar.new()
	scar.direction = here
	scar.radius = 60.0
	scar.depth = 18.0
	scar.warp = 0.3
	scar.seed = 1.9
	scars.add(scar)

	_expect(is_equal_approx(scars.depth_at(here), scar.depth),
		"a warped crater is still at full depth in its middle")

	# On the nominal rim a round hole cuts nothing anywhere. This one has to be
	# inside the ground on some bearings and outside it on others.
	var inside := 0
	var outside := 0
	var deepest_beyond := 0.0
	for step in 32:
		var turn := TAU * float(step) / 32.0
		var on_rim := _bearing_from(scar, turn, scar.radius, scars.planet_radius)
		if scars.depth_at(on_rim) > 0.0:
			inside += 1
		else:
			outside += 1
		deepest_beyond = maxf(deepest_beyond, scars.depth_at(
			_bearing_from(scar, turn, scar.outer + 1.0, scars.planet_radius)))
	_expect(inside > 4 and outside > 4,
		"its rim crosses its own circle rather than tracing it (%d in, %d out)"
			% [inside, outside])
	_expect(is_zero_approx(deepest_beyond),
		"and stops inside the reach the registry filed it under")

	# The same scar over the wire has to be the same hole, or the crater a client
	# walks into is not the one the host dug.
	var copy := TerrainScars.new()
	copy.planet_radius = scars.planet_radius
	copy.add(TerrainScars.Scar.from_wire(scar.to_wire()))
	var agreed := true
	for step in 32:
		var turn := TAU * float(step) / 32.0
		var at := _bearing_from(scar, turn, scar.radius * 0.9, scars.planet_radius)
		agreed = agreed and is_equal_approx(scars.depth_at(at), copy.depth_at(at))
	_expect(agreed, "and is the same hole on the peer that received it")

	var round_scar := TerrainScars.Scar.new()
	round_scar.direction = here
	round_scar.radius = 60.0
	round_scar.depth = 18.0
	var plain := TerrainScars.new()
	plain.planet_radius = scars.planet_radius
	plain.add(round_scar)
	_expect(is_equal_approx(round_scar.outer, round_scar.radius),
		"a mark authored without warp is left exactly round")


func _check_authored_ability_scars() -> void:
	var scars := TerrainScars.new()
	scars.planet_radius = 8000.0
	var direction := Vector3(0.22, 0.91, -0.35).normalized()
	for profile: Dictionary in [
		{"id": "nuke", "radius": 72.0, "depth": 20.0, "warp": 0.3},
		{"id": "nausicaa", "radius": 2.0, "depth": 0.55, "warp": 0.0},
	]:
		var definition := ItemDB.ability_definition(String(profile["id"]))
		var scar := TerrainScars.Scar.new()
		scar.direction = direction
		scar.radius = float(definition.stats.get("crater_radius", 0.0))
		scar.depth = float(definition.stats.get("crater_depth", 0.0))
		scar.warp = float(definition.stats.get("crater_warp", 0.0))
		scar.profile = TerrainScars.Profile.BOWL
		scars.clear()
		scars.add(scar)
		_expect(is_equal_approx(scar.radius, float(profile["radius"]))
			and is_equal_approx(scar.warp, float(profile["warp"]))
			and is_equal_approx(scars.depth_at(direction), float(profile["depth"])),
			"%s authors its impact indent in the terrain registry" % (
				definition.title))


## A direction this many metres from a scar's middle on this bearing, measured in
## the scar's own frame so a test can aim at the part of the rim it means.
func _bearing_from(scar: TerrainScars.Scar, turn: float, away: float,
		planet_radius: float) -> Vector3:
	var step := away / maxf(planet_radius, 1.0)
	return (scar.direction
		+ (scar.east * cos(turn) + scar.north * sin(turn)) * step).normalized()


## The claim that matters: a crater cut into the live planet moves the height
## field, the chunk mesh and the collider together.
func _check_live_crater(player: OnlinePlayer) -> void:
	var shape := _planet.shape
	var here := _planet.to_local(player.global_position).normalized()
	var before := shape.elevation(here)
	_expect(not shape.needs_script_build(here * shape.radius, 20.0),
		"unmarked ground builds through the native field")

	var scar := TerrainScars.Scar.new()
	scar.direction = here
	scar.radius = CRATER_RADIUS
	scar.depth = CRATER_DEPTH
	scar.profile = TerrainScars.Profile.BOWL
	scar.char = 0.4
	_world.request_scar(scar)

	var after := shape.elevation(here)
	_expect(is_equal_approx(before - after, CRATER_DEPTH),
		"the height field drops by the crater's depth (%.2f m)" % (
			before - after))
	_expect(shape.needs_script_build(here * shape.radius, 20.0),
		"scarred ground is routed through the script build path")
	# The player's ground guard reads the field at whatever detail is under it,
	# so this is the same question asked the way the body asks it.
	var underfoot := shape.elevation(here, _planet.spacing_underfoot())
	_expect(underfoot < before,
		"and the guard the player's feet use agrees the ground has dropped")
	_expect(_planet.standing_position(here).distance_to(
		_planet.to_global(here * (shape.radius + after))) < 0.01,
		"standing height comes from the same scarred field")

	var built := _built_height(here)
	await _wait(REBUILD_FRAMES)
	var rebuilt := _built_height(here)
	_expect(rebuilt < built,
		"the collider follows it down (%.2f m to %.2f m)" % [built, rebuilt])
	# Compared as a drop rather than as a height. A ray meets a triangle's face
	# and the field is sampled at a point, so the two never agree exactly on a
	# slope; what has to agree is how far each of them moved.
	_expect(absf((built - rebuilt) - CRATER_DEPTH) < 1.0,
		"by the crater's own depth (%.2f m against %.2f m)" % [
			built - rebuilt, CRATER_DEPTH])


## The ground does not open up while a scar is being rebuilt.
##
## A rebuild frees the mesh it replaces and hangs a new one in its place, and the
## new one used to arrive switched off, waiting for the next quadtree walk to
## turn it on. Meshes are attached every frame and the walk runs at 30 Hz, so
## that was most of a walk interval with nothing drawn over that patch at all —
## and nothing else covering it either, because the parent chunk retired its own
## mesh when this one took the ground over. What is behind the ground is the
## inside of the planet. Held laser fire commits several scars a second, which is
## what made it read as the terrain flickering away under the beam.
func _check_no_hole_while_rebuilding(player: OnlinePlayer) -> void:
	var here := _planet.to_local(player.global_position).normalized()
	var at := _planet.shape.surface_point(here)
	await _wait(30)
	_expect(_covered(at), "the ground under the player is drawn to begin with")

	var scar := TerrainScars.Scar.new()
	scar.direction = here
	scar.radius = 2.0
	scar.depth = 0.2
	scar.profile = TerrainScars.Profile.GROOVE
	_world.request_scar(scar)

	# Every frame, not every walk. The gap this is looking for lives between the
	# two, so anything sampled at the walk rate would step straight over it.
	var bare := 0
	for _frame in REBUILD_FRAMES:
		await get_tree().process_frame
		if not _covered(at):
			bare += 1
	_expect(bare == 0,
		"and stays drawn all the way through the rebuild (%d frames of hole)"
			% bare)


## The same claim under what a player actually does: hold the beam and sweep it.
##
## One scar rebuilt in isolation is the easy case. A held beam commits several a
## second along a moving line, so rebuilds overlap each other and overlap the
## ordinary refine traffic, and the ground is sampled all around the player
## rather than at the one point the scar landed on.
func _check_no_hole_while_sweeping(player: OnlinePlayer) -> void:
	player.abilities.set_item(0, "laser_eyes")
	await _wait(4)
	var ability := player.ability_controller().ability_in(0)
	if ability == null:
		_expect(false, "the beam is in the first ability slot")
		return
	player._pitch = -0.5
	var around := _ring_around(player, SWEEP_SAMPLES, SWEEP_REACH)
	await _wait(20)
	var settled := _bare_of(around)
	_expect(settled == 0,
		"the ground all round the player is drawn before the beam starts (%d bare)"
			% settled)

	var bare := 0
	var worst := 0
	# The other way to end up looking through the ground is for the ground to
	# stop being solid, and that is the one that actually bites. The camera sits
	# on a `SpringArm3D`, which holds itself off the world by casting at the
	# bodies in it. Ground with no body under it is ground the arm cannot see, so
	# the camera runs straight into the hillside and draws its back faces —
	# looking through the planet, from a mesh that is present and correct the
	# whole time. Every scar invalidates the colliders it covers, and the beam
	# lays scars four times a second wherever the player is looking, which is
	# very often at their own feet.
	var sank := 0.0
	var floorless := 0
	for frame in SWEEP_FRAMES:
		if not ability.is_held():
			player.activate_ability(0)
		# Swept, not held on one spot: the mark has to keep moving or it lands
		# on ground that is already scarred and stops causing rebuilds.
		player.global_basis = player.global_basis.rotated(
			_planet.up_at(player.global_position), 0.004)
		await get_tree().process_frame
		var missing := _bare_of(around)
		if missing > 0:
			bare += 1
			worst = maxi(worst, missing)
		sank = minf(sank, _above_field(player.camera.global_position))
		floorless = maxi(floorless, int(_planet.statistics()["floorless"]))
	player.release_ability(0)
	_expect(bare == 0,
		"and stays drawn through a %d-frame sweep (%d frames bare, %d points at worst)"
			% [SWEEP_FRAMES, bare, worst])
	_expect(sank >= 0.0,
		"and the eye never goes under the ground it is burning (%.3f m)" % sank)
	_expect(floorless == 0,
		"and no drawn ground is left without a collider (%d chunks at worst)"
			% floorless)
	print("terrain_scar_test: the sweep left %d scars"
		% _planet.shape.scars.count())


## How far a world point is above the height field beneath it.
func _above_field(at: Vector3) -> float:
	var local := _planet.to_local(at)
	return local.length() - _planet.shape.radius \
		- _planet.shape.elevation(local.normalized(),
			_planet.spacing_underfoot())


## How many of a set of surface points have nothing drawn over them.
func _bare_of(points: PackedVector3Array) -> int:
	var missing := 0
	for at in points:
		if not _covered(at):
			missing += 1
	return missing


## A ring of points on the surface around the player, in the planet's own space,
## which is where the ground the player can see actually is.
func _ring_around(player: OnlinePlayer, count: int,
		reach: float) -> PackedVector3Array:
	var here := _planet.to_local(player.global_position).normalized()
	var side := here.cross(Vector3.UP).normalized()
	if side.length_squared() < 0.001:
		side = here.cross(Vector3.RIGHT).normalized()
	var other := here.cross(side)
	var points := PackedVector3Array([_planet.shape.surface_point(here)])
	for ring in 3:
		var span := reach * float(ring + 1) / 3.0 / _planet.shape.radius
		for step in count:
			var turn := TAU * float(step) / float(count)
			var out := (here + (side * cos(turn) + other * sin(turn)) * span) \
				.normalized()
			points.append(_planet.shape.surface_point(out))
	return points


## Whether the ground at a point is actually drawn, asked of the chunks that own
## that point rather than of anything whose bounding box happens to reach it.
##
## The looser question — "is any visible mesh's box over this point" — is worth
## naming because it is the one that looks right and proves nothing: a chunk's
## box is a box drawn round a curved patch, neighbouring boxes overlap each other
## generously, and the chunk next door answers yes while the ground in question
## is missing. It cannot see this fault at all.
##
## So: descend the quadtree picking the child that owns the point at each level,
## and ask whether anything along that path is on screen. One of them should be —
## the leaf normally, or an ancestor standing in while the leaf is built.
func _covered(at: Vector3) -> bool:
	var chunk: Variant = _owner_of(_planet.get("_roots"), at)
	while chunk != null:
		if chunk.instance != null and chunk.instance.visible:
			return true
		if chunk.children.is_empty():
			return false
		chunk = _owner_of(chunk.children, at)
	return false


## Which of a set of siblings owns a point. They partition their parent's patch
## between them, so the one whose centre is nearest is the one it falls in.
func _owner_of(chunks: Array, at: Vector3) -> Variant:
	var best: Variant = null
	var best_at := INF
	for chunk in chunks:
		var away: float = (chunk.origin as Vector3).distance_to(at)
		if away < best_at:
			best_at = away
			best = chunk
	return best


## The claim a player actually feels: a punch ends standing at the bottom of its
## own crater. The hole is cut under a body that is already on the old surface,
## so unless the landing puts the body in it, the ground is pulled out from under
## the pose and the player drops the crater's depth a moment after it finishes.
func _check_punch_landing(player: OnlinePlayer) -> void:
	player.abilities.set_item(1, "meteor_punch")
	await _wait(2)
	var ability := player.ability_controller().ability_in(1)
	if ability == null:
		_expect(false, "the punch is in the second ability slot")
		return
	for _frame in 900:
		if ability.can_use():
			break
		await get_tree().process_frame
	var scars_before := _planet.shape.scars.count()
	_expect(player.activate_ability(1), "a punch is thrown")

	# Until the pose takes over. The punch is only over once the body is out of
	# the flight it spends its reach in.
	for _frame in 600:
		await get_tree().process_frame
		if player.stance() != OnlinePlayer.Stance.METEOR:
			break
	_expect(_planet.shape.scars.count() > scars_before,
		"and leaves a crater behind it")

	var landed := _radius_of(player)
	var floor_radius := _planet.shape.radius + _planet.shape.elevation(
		_planet.to_local(player.global_position).normalized(),
		_planet.spacing_underfoot())
	_expect(absf(landed - floor_radius) < 1.0,
		"the body lands on the cratered field, not on the ground it removed " \
		+ "(%.2f m above it)" % (landed - floor_radius))

	# Long enough for the pose to finish and for the rebuilt collider to arrive,
	# which is when the old fall used to happen.
	await _wait(REBUILD_FRAMES)
	var settled := _radius_of(player)
	_expect(landed - settled < 0.5,
		"and stays there rather than falling in (%.2f m)" % (landed - settled))


## A punch thrown at the planet from a fast dive.
##
## This used to end with the player on the ground and no hole in it, three ways
## at once: the punch's reach was spent in the first fifty metres of a long fall
## and handed the flight back, the catalogue's top speed was read as a ceiling
## and braked the dive on the way down, and at these speeds the body crosses a
## chunk in a frame and arrives without ever generating a slide collision to
## notice it by.
func _check_dive_punch(player: OnlinePlayer) -> void:
	var ability := player.ability_controller().ability_in(1)
	for _frame in 900:
		if ability.can_use():
			break
		await get_tree().process_frame

	# Lifted first and flown second. Taking off while the last frame's footing is
	# still on record has the flight ended again immediately by the grounded
	# test, which leaves the punch on its standing branch — where it lands
	# whatever the flight branch does, and the check below quietly proves
	# nothing.
	var up := _planet.up_at(player.global_position)
	player.global_position += up * DIVE_HEIGHT
	await _wait(4)
	player.start_flying()
	player._pitch = -1.25
	await _wait(2)
	# The whole case is the *flight* branch of a spent reach, and a punch thrown
	# from anything else takes the other one and lands regardless.
	_expect(player.stance() == OnlinePlayer.Stance.FLY,
		"the dive is thrown out of a flight (stance %d)" % player.stance())
	_expect(player.look_direction().dot(up) < -0.9,
		"and is aimed at the planet (%.2f)" % player.look_direction().dot(up))
	player.velocity = player.look_direction() * DIVE_SPEED
	var scars_before := _planet.shape.scars.count()
	_expect(player.activate_ability(1), "a punch is thrown out of a dive")

	for _frame in 900:
		await get_tree().process_frame
		if player.stance() != OnlinePlayer.Stance.METEOR:
			break
	_expect(player.stance() != OnlinePlayer.Stance.FLY,
		"the dive commits to the ground instead of handing the flight back")
	_expect(_planet.shape.scars.count() > scars_before,
		"and arrives as a punch rather than as a landing")
	if _planet.shape.scars.count() <= scars_before:
		return

	var cut: Dictionary = _planet.shape.scars.to_wire().back()
	_expect(float(cut.get("radius", 0.0)) > CRATER_RADIUS + 0.5,
		"a dive at %.0f m/s digs wider than a standing punch (%.1f m against " \
		% [DIVE_SPEED, float(cut.get("radius", 0.0))] + "%.1f m)" % CRATER_RADIUS)
	_expect(float(cut.get("depth", 0.0)) > CRATER_DEPTH + 0.2,
		"and deeper (%.1f m against %.1f m)" % [
			float(cut.get("depth", 0.0)), CRATER_DEPTH])

	var landed := _radius_of(player)
	await _wait(REBUILD_FRAMES)
	_expect(landed - _radius_of(player) < 0.5,
		"and the body stands in the deeper hole too (%.2f m)" % (
			landed - _radius_of(player)))


func _radius_of(player: OnlinePlayer) -> float:
	return _planet.to_local(player.global_position).length()


func _check_snapshot() -> void:
	var wire := _world.scar_snapshot()
	_expect(wire.size() == _planet.shape.scars.count(),
		"every scar is in the join snapshot (%d)" % wire.size())
	# A joining peer applies the lot in one go, which must leave the same ground
	# rather than a doubled one.
	var here := (wire[0]["direction"] as Vector3).normalized()
	var depth := _planet.shape.elevation(here)
	_world.apply_scar_snapshot(wire)
	_expect(_planet.shape.scars.count() == wire.size(),
		"applying a snapshot replaces rather than appends")
	_expect(is_equal_approx(_planet.shape.elevation(here), depth),
		"and leaves the ground exactly where it was")


## Height of the built ground at a direction, read through physics rather than
## through the field, so it is the mesh's answer and not the field's.
func _built_height(direction: Vector3) -> float:
	var out := _planet.to_global(direction * (_planet.shape.radius + 200.0))
	var into := _planet.to_global(direction * (_planet.shape.radius - 200.0))
	var query := PhysicsRayQueryParameters3D.create(out, into)
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return INF
	return _planet.to_local(hit["position"]).length() - _planet.shape.radius


func _depth_of(profile: int, at: Vector3) -> float:
	var scars := TerrainScars.new()
	scars.planet_radius = 8000.0
	var scar := TerrainScars.Scar.new()
	scar.direction = Vector3.UP
	scar.radius = 20.0
	scar.depth = 4.0
	scar.profile = profile as TerrainScars.Profile
	scars.add(scar)
	return scars.depth_at(at)


## A direction that many metres across the surface from another one.
func _offset(from: Vector3, metres: float, radius: float) -> Vector3:
	var side := from.cross(
		Vector3.RIGHT if absf(from.x) < 0.9 else Vector3.FORWARD).normalized()
	return (from + side * (metres / radius)).normalized()


func _wait(frames: int) -> void:
	for _index in frames:
		await get_tree().process_frame


func _expect(condition: bool, message: String) -> bool:
	if condition:
		print("terrain_scar_test: PASS  %s" % message)
		return true
	_failures += 1
	push_error("terrain_scar_test: FAIL  %s" % message)
	return false
