extends Node

## Where the frame time goes while an ability is being used.
##
##     & $godot --path . dev/_ability_perf_test.tscn
##
## Runs the real world with the real player, settles it, and then measures the
## frame while the laser is held and while a punch is in the air, against the
## same view standing still. Each suspect is also priced on its own, because a
## frame time on its own says something is wrong and never what.
##
## Not headless: two of the four suspects are the renderer's and the terrain
## pipeline's, and the dummy driver has neither.

const WORLD := preload("res://game/world.tscn")
const SETTLE_FRAMES := 260
const SAMPLE_FRAMES := 150

var _player: OnlinePlayer
var _planet: Planet


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	var world := WORLD.instantiate()
	add_child(world)
	await _wait(10)
	_planet = world.find_child("Planet", true, false) as Planet
	var site := world.find_child("LandingSite", true, false) as Node3D
	_player = get_tree().get_first_node_in_group("network_players") \
		as OnlinePlayer
	if _planet == null or site == null or _player == null:
		push_error("ability_perf: nothing to measure")
		get_tree().quit(1)
		return
	_player.global_transform = site.global_transform
	_player.velocity = Vector3.ZERO
	_player.abilities.set_item(0, "laser_eyes")
	_player.abilities.set_item(1, "meteor_punch")
	await _wait(SETTLE_FRAMES)

	_price_damage_volume()
	await _price_scar_commit()
	_price_scar_lookup()
	_price_chunk_build()
	await _price_frames()
	get_tree().quit()


## What one tick of beam damage costs, and where it goes. The beam is the
## cheaper of the two abilities and it runs this ten times a second; the punch
## runs the same call sixty times a second.
func _price_damage_volume() -> void:
	var eye: Vector3 = _player.eye_points()[0]
	var at := eye + _player.aim_direction(eye) * 30.0
	var beam := DamageHit.beam(eye, at, 0.35, 18.0)
	var fist := DamageHit.beam(eye, eye + Vector3.ONE, 4.0, 3.0)

	var fields := get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP)
	print("ability_perf: %d damageable fields in the world" % fields.size())
	print("ability_perf: one beam volume  %.3f ms" % _volume_ms(beam))
	print("ability_perf: one fist volume  %.3f ms" % _volume_ms(fist))

	# Where inside that the time goes: how many fields even overlap the volume,
	# against how many are asked.
	var reached := 0
	for field in fields:
		if _field_reached(field, beam):
			reached += 1
	print("ability_perf: the beam is offered to %d fields and touches %d"
		% [fields.size(), reached])
	_price_buffer_reads(beam)


## What the volume walk spends purely on reading instance buffers back out of
## the MultiMeshes it is about to look at, which is a copy each time.
func _price_buffer_reads(hit: DamageHit) -> void:
	var stands: Array[MultiMeshInstance3D] = []
	var tiles_reached := 0
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		var tiles: Variant = field.get("_tiles")
		if tiles == null:
			continue
		var tallest := float(field.get("_tallest"))
		var bound := float(field.get("_tile")) * 0.71 + tallest
		for tile in (tiles as Dictionary).values():
			if not hit.reaches(tile.get("at"), bound):
				continue
			tiles_reached += 1
			for stand in tile.get("stands"):
				if stand != null and stand.visible:
					stands.append(stand)
	var floats := 0
	var began := Time.get_ticks_usec()
	for stand in stands:
		floats += stand.multimesh.buffer.size()
	var spent := float(Time.get_ticks_usec() - began) / 1000.0
	print("ability_perf: the beam reaches %d tiles, %d stands, and reading their buffers back is %.3f ms for %.2f MB"
		% [tiles_reached, stands.size(), spent, float(floats) * 4.0 / 1048576.0])

	# The scan that finds those few tiles, against the number it walks to do it.
	var all_tiles := 0
	var offered: Array[Vector3] = []
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		var tiles: Variant = field.get("_tiles")
		if tiles == null:
			continue
		all_tiles += (tiles as Dictionary).size()
		for tile in (tiles as Dictionary).values():
			offered.append(tile.get("at"))
	began = Time.get_ticks_usec()
	for at in offered:
		hit.reaches(at, 40.0)
	spent = float(Time.get_ticks_usec() - began) / 1000.0
	print("ability_perf: %d tiles are streamed in all, and testing every one is %.3f ms"
		% [all_tiles, spent])


func _volume_ms(hit: DamageHit) -> float:
	var began := Time.get_ticks_usec()
	for _pass in 10:
		DamageHit.apply_to_world(_player, hit)
	return float(Time.get_ticks_usec() - began) / 10000.0


## Whether a field has anything at all inside a volume, asked the cheap way.
func _field_reached(field: Node, hit: DamageHit) -> bool:
	var tiles: Variant = field.get("_tiles")
	if tiles == null:
		return false
	for tile in (tiles as Dictionary).values():
		if hit.reaches(tile.get("at"), 60.0):
			return true
	return false


## What committing one mark to the ground costs, split between filing it,
## finding the chunks it invalidates, and the frames spent rebuilding them. The
## laser commits up to four a second while it is held.
func _price_scar_commit() -> void:
	var scars: TerrainScars = _planet.shape.scars
	var here := _planet.to_local(_player.global_position).normalized()
	var decals := _planet.scorches.get_child_count() if _planet.scorches != null \
		else 0
	# The three sizes the game actually cuts, rather than the same one three
	# times. A scar's real cost is the terrain inside it that has to be rebuilt,
	# so the size is the whole variable: the widest is what a dive at flight's
	# top speed digs, and its footprint is four times the ordinary punch's.
	var sizes := [
		{"what": "laser groove", "radius": 2.0, "depth": 0.2,
			"profile": TerrainScars.Profile.GROOVE},
		{"what": "punch crater", "radius": 6.0, "depth": 2.5,
			"profile": TerrainScars.Profile.BOWL},
		{"what": "dive crater", "radius": 12.0, "depth": 5.0,
			"profile": TerrainScars.Profile.BOWL},
	]
	for round_index in sizes.size():
		var size: Dictionary = sizes[round_index]
		var scar := TerrainScars.Scar.new()
		scar.direction = _nearby(here, float(round_index))
		scar.radius = float(size["radius"])
		scar.depth = float(size["depth"])
		scar.profile = size["profile"]
		scar.char = 0.9
		var began := Time.get_ticks_usec()
		_planet.shape.scars.add(scar)
		var filed := float(Time.get_ticks_usec() - began)
		began = Time.get_ticks_usec()
		_planet.mark_region_stale(scar.direction, scar.radius, scar.depth)
		var marked := float(Time.get_ticks_usec() - began)
		began = Time.get_ticks_usec()
		if _planet.scorches != null:
			var at := _planet.global_transform * _planet.shape.surface_point(
				scar.direction)
			_planet.scorches.scorch(at, _planet.up_at(at), scar.radius, 0.9,
				true)
		var burned := float(Time.get_ticks_usec() - began)
		print("ability_perf: %s r=%.0f  file %.0f us  invalidate %.0f us  decal %.0f us"
			% [size["what"], scar.radius, filed, marked, burned])
		# What the invalidation then costs across the frames that answer it.
		var settle := 0.0
		var worst := 0.0
		for _frame in 90:
			var frame_began := Time.get_ticks_usec()
			await get_tree().process_frame
			var spent := float(Time.get_ticks_usec() - frame_began) / 1000.0
			settle += spent
			worst = maxf(worst, spent)
		print("ability_perf:        rebuilding it took %.1f ms over 90 frames, worst frame %.2f ms"
			% [settle - 90.0 * 5.0, worst])
	print("ability_perf: the scorch pool went from %d nodes to %d"
		% [decals, _planet.scorches.get_child_count() if _planet.scorches != null else 0])
	scars.clear()


## The two questions a scar asks of the terrain pipeline, priced at the counts a
## session actually reaches. `overlaps` is asked once per chunk build, of every
## chunk in the world; `depth_at` is asked once per vertex.
func _price_scar_lookup() -> void:
	var scars: TerrainScars = _planet.shape.scars
	var here := _planet.to_local(_player.global_position).normalized()
	var was := scars.count()
	for count in [1, 64, 512]:
		while scars.count() < count:
			var scar := TerrainScars.Scar.new()
			scar.direction = _nearby(here, float(scars.count()))
			scar.radius = 2.0
			scar.depth = 0.2
			scars.add(scar)
		var began := Time.get_ticks_usec()
		for _pass in 2000:
			scars.overlaps(here, 12.0)
		var overlap_us := float(Time.get_ticks_usec() - began) / 2000.0
		began = Time.get_ticks_usec()
		for _pass in 20000:
			scars.depth_at(here, 1.5)
		var depth_us := float(Time.get_ticks_usec() - began) / 20000.0
		print("ability_perf: %3d scars  overlaps %.2f us  depth_at %.3f us"
			% [count, overlap_us, depth_us])
	scars.clear()

	# A warped rim buys its shape with an arctangent and three sines per scar per
	# vertex, on the hottest path in the game. Priced against the round mark it
	# replaces, over a nuke crater wide enough to cover a good many chunks, so a
	# change that makes the lobes expensive shows up here rather than as a stutter
	# the first time somebody detonates one.
	for warp: float in [0.0, 0.3]:
		var scar := TerrainScars.Scar.new()
		scar.direction = here
		scar.radius = 72.0
		scar.depth = 20.0
		scar.warp = warp
		scars.clear()
		scars.add(scar)
		var inside := _nearby(here, 1.0)
		var began := Time.get_ticks_usec()
		for _pass in 20000:
			scars.depth_at(inside, 1.5)
		print("ability_perf: a 72 m crater warped %.1f  depth_at %.3f us"
			% [warp, float(Time.get_ticks_usec() - began) / 20000.0])
		print("ability_perf:        filed under %d cells, reaching %.0f m"
			% [scar.cells.size(), scar.outer])
	scars.clear()
	print("ability_perf: (registry had %d scars before this)" % was)


## The two ways a chunk can be built, on the same chunk. A scar anywhere on a
## chunk takes it off the native path for the rest of the session, so this is the
## cost a single laser burn signs the ground up to.
func _price_chunk_build() -> void:
	var depth: int = _planet.max_depth
	var resolution: int = _planet._resolution_at_depth(depth)
	var side := resolution + 3
	var here := _planet.to_local(_player.global_position).normalized()
	var arc: float = PI * 0.5 * _planet.shape.radius / pow(2.0, depth)
	var spacing := arc / float(resolution)
	var axes: Array = Planet.FACES[0]

	var began := Time.get_ticks_usec()
	_planet.shape.build_patch(axes[0], axes[1], axes[2], Vector2(0.1, 0.1),
		0.002, resolution, spacing, arc * 0.12, here * _planet.shape.radius,
		true)
	var native_ms := float(Time.get_ticks_usec() - began) / 1000.0

	# The script path's cost is its per-vertex work, which is what the loop in
	# `Planet._build` does and nothing else here can stand in for.
	began = Time.get_ticks_usec()
	for index in side * side:
		var direction := _nearby(here, float(index) * 0.01)
		var height := _planet.shape.elevation(direction, spacing)
		_planet.shape.color_at(direction, height, direction)
	var script_ms := float(Time.get_ticks_usec() - began) / 1000.0

	print("ability_perf: chunk of %d vertices  native %.2f ms  script %.2f ms (%.0fx)"
		% [side * side, native_ms, script_ms, script_ms / maxf(native_ms, 0.001)])


## The headline: the frame, standing still, then firing, then punching.
func _price_frames() -> void:
	_player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_FAR)
	_player._pitch = -0.3
	await _wait(40)
	print("ability_perf: idle           %s" % await _frame_ms())

	_player.activate_ability(0)
	await _wait(20)
	print("ability_perf: laser held     %s" % await _frame_ms())
	_player.release_ability(0)
	await _wait(60)
	print("ability_perf: after the beam %s" % await _frame_ms())

	# Rebuilds triggered by the burn are still draining here, which is the part
	# that is felt as a stutter rather than as a lower frame rate.
	print("ability_perf: chunks now %d built, %.2f ms each, %d pending" % [
		_planet.statistics()["built"], _planet.statistics()["build_ms"],
		_planet.statistics()["pending"]])

	await _wait(120)
	await _trace_punch()
	await _wait(180)
	print("ability_perf: after the punch %s" % await _frame_ms())


## Every frame of one punch that cost more than a comfortable budget, with what
## the planet and the flora were doing during it. A punch is one event rather
## than a sustained state, so a mean over it says nothing.
func _trace_punch() -> void:
	# The break-effect pool advances its cursor once per plant felled, which is
	# the only running count of destruction there is.
	var effects := get_tree().get_first_node_in_group(&"impact_break_effects")
	var seen := int(effects.get("_cursor")) if effects != null else 0
	_player.activate_ability(1)
	var total := 0.0
	for frame in 150:
		var began := Time.get_ticks_usec()
		await get_tree().process_frame
		var spent := float(Time.get_ticks_usec() - began) / 1000.0
		total += spent
		var now := int(effects.get("_cursor")) if effects != null else 0
		var broke := now - seen
		seen = now
		if spent < 10.0:
			continue
		var stats := _planet.statistics()
		print("ability_perf:   punch frame %3d  %6.2f ms  (script %.1f, physics %.1f, planet apply %.1f collision %.1f refine %.1f, %d pending, %d felled)"
			% [frame, spent,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
					* 1000.0,
				stats["apply_ms"], stats["collision_ms"], stats["refine_ms"],
				stats["pending"], broke])
	print("ability_perf: the punch cost %.1f ms over 150 frames" % total)


## Mean and worst frame over a sample, which is the pair that matters: a stutter
## is invisible in a mean and is the whole complaint. The worst frame is
## reported with what the planet was doing during it, since a hitch that big is
## never the ability itself.
func _frame_ms() -> String:
	var total := 0.0
	var worst := 0.0
	var blamed := ""
	for _frame in SAMPLE_FRAMES:
		var began := Time.get_ticks_usec()
		await get_tree().process_frame
		var spent := float(Time.get_ticks_usec() - began) / 1000.0
		total += spent
		if spent > worst:
			worst = spent
			var stats := _planet.statistics()
			blamed = " (planet: apply %.1f, collision %.1f, refine %.1f, %d pending)" % [
				stats["apply_ms"], stats["collision_ms"], stats["refine_ms"],
				stats["pending"]]
	return "%.2f ms mean, %.2f ms worst%s" % [total / SAMPLE_FRAMES, worst,
		blamed]


## A direction a few metres from another, for filling the registry with scars
## that are near enough to be found and apart enough to be separate.
func _nearby(direction: Vector3, index: float) -> Vector3:
	var east := direction.cross(
		Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := direction.cross(east)
	var step := (3.0 + index) / _planet.shape.radius
	return (direction + east * cos(index) * step
		+ north * sin(index) * step).normalized()


func _wait(frames: int) -> void:
	for _index in frames:
		await get_tree().process_frame
