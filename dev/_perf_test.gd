extends Node

## Where the frame time goes, at the places in the world that cost the most.
##
##     & $godot --path . dev/_perf_test.tscn
##     & $godot --path . dev/_perf_test.tscn -- --noshadow --nooutline --draw=unshaded
##     & $godot --path . dev/_perf_test.tscn -- --distance
##
## Runs the real `world.tscn` with the real player, parks it at a series of
## vantage points, and reports the settled frame time at each along with what the
## renderer and the LOD were doing to earn it. **Vsync is off and the frame rate
## is uncapped**, because a capped 60 says nothing about how much headroom is
## left for the towns and water still to come.
##
## Flags peel one suspect off at a time, which is the only way to attribute cost
## honestly: `--noshadow` drops the sun's shadow map, `--nooutline` strips the
## outline pass off the terrain, `--noclouds` hides the cloud deck, which is the
## one thing here that is marched per pixel and so the one whose cost is all fill
## rate, `--draw=unshaded` takes the surface shader out of the picture, and
## `--near=` moves the LOD's collision range.
##
## `--mat=name:value` sets one uniform on the terrain material, which is how
## anything living inside the surface shader gets priced: run the same build
## twice, once with the feature turned off. Editing the material between runs
## would measure the shader compiler as much as the feature.
##
##     -- --mat=texture_blend:0     the procedural ground
##     -- --mat=texture_blend:0.85  the photographed one
##
## `--distance` runs one stop at every level of [constant Planet.DETAIL_LEVELS]
## instead of the usual sweep, which is what the render distance setting is priced
## from. It reads at low air looking out: standing on the ground almost nothing is
## far enough away for the level to matter, and from orbit nothing is near enough,
## so either would price the setting at nothing.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

## Long enough for the LOD to settle. Counted in seconds rather than frames
## because the quadtree is walked on a clock now, so a fixed number of frames at
## 400 fps is a handful of LOD passes and nowhere near converged.
const SETTLE_SECONDS := 8.0
const SAMPLE_FRAMES := 180

## Ground speed and height of the moving pass. 200 m/s is close to what the
## flight model tops out at, and 80 m is low enough that the terrain under it is
## being built at full detail the whole way.
const TRAVERSE_SPEED := 200.0
const TRAVERSE_ALTITUDE := 80.0

## `--speed=` overrides the crossing, because the pipeline's two ends fail at
## different speeds: the frame cost is worst where the tree is deep and the
## supply runs out where the ground arrives faster than it can be built.
var _traverse_speed := TRAVERSE_SPEED

## Where `--distance` prices the render distance: a name, an altitude and a pitch.
## Both are aimed so that the ground is the frame rather than the sky, since a
## level's whole effect is on ground it can barely be seen against otherwise.
const DISTANCE_STOPS: Array = [
	["air", 300.0, -0.32],
	["foot", 1.5, -0.06],
]

## Each stop is a name, an altitude in metres and whether to look out or down.
const STOPS: Array = [
	["orbit", 9000.0, true],
	["high air", 1800.0, false],
	["low air", 300.0, false],
	["treetop", 60.0, false],
	["standing", 1.5, true],
]

var _player: OnlinePlayer
var _planet: Planet
var _site: Node3D
var _sun: DirectionalLight3D
var _up := Vector3.UP
## Worst seen for each stage of the planet's update, by the key `statistics`
## reports it under.
var _parts := {"refine": 0.0, "dispatch": 0.0, "show": 0.0}
var _means := {
	"refine": 0.0, "dispatch": 0.0, "show": 0.0,
	"collision": 0.0, "apply": 0.0, "frame": 0.0,
}
var _worst_nodes := 0
var _worst_visible := 0


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	# The measurement is meaningless behind a vsync wait.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# Without a state the world opens its home screen instead of spawning
	# anybody, and there is no player here to park at the vantage points.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())
	# The world does not spawn anybody on the frame it is added: the roster is
	# walked from its own _ready, and the player arrives a frame or two later.
	for _frame in 30:
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
		if _player != null:
			break

	var scene := get_tree().current_scene
	_planet = scene.find_child("Planet", true, false) as Planet
	_site = scene.find_child("LandingSite", true, false) as Node3D
	_sun = scene.find_child("Sun", true, false) as DirectionalLight3D
	if _player == null or _planet == null or _site == null:
		push_error("perf_test: player=%s planet=%s site=%s" % [_player, _planet, _site])
		get_tree().quit(1)
		return
	_up = _site.global_basis.y
	_apply_flags()

	print("perf_test: %s, vsync off, %dx%d" % [
		RenderingServer.get_video_adapter_name(), 1600, 900])
	print("perf_test: %-18s %8s %8s %8s %7s %8s %7s %6s" % [
		"where", "fps", "frame", "worst", "lod", "tris", "draws", "bodies"])
	if "--distance" in OS.get_cmdline_user_args():
		await _distances()
		get_tree().quit()
		return
	if "--arrive" in OS.get_cmdline_user_args():
		await _arrive()
		get_tree().quit()
		return
	for argument in OS.get_cmdline_user_args():
		if String(argument).begins_with("--at="):
			await _inspect(String(argument).trim_prefix("--at="))
			get_tree().quit()
			return
	for stop in STOPS:
		await _measure(str(stop[0]), float(stop[1]), bool(stop[2]))
	await _traverse()
	get_tree().quit()


## How long the ground underfoot takes to reach full detail after arriving
## somewhere new, which is a different question from how much ground the pipe
## delivers while crossing and is not answered by it. Throughput is chunks built
## anywhere; this is whether any of them are where the player is standing.
##
## The chain it measures is serial and no amount of parallelism shortens it: a
## chunk cannot split until its own mesh has landed, so each level costs a walk to
## notice, a build, an attach, and another walk to notice the children. Depth is
## reported per half second so the ladder is visible rather than just its total —
## a run that stalls at one level for a second is a different fault from one that
## climbs steadily but starts late.
func _arrive() -> void:
	# Somewhere with nothing pre-built. Settling at the landing site first is the
	# point: it reproduces arriving with a full tree and a busy pool behind you,
	# which is the case the player is describing and is strictly worse than
	# arriving from a cold start.
	_park(TRAVERSE_ALTITUDE, true)
	await _settle()

	var axis := _up.cross(_site.global_basis.z).normalized()
	var far := _up.rotated(axis, 0.35)
	print("perf_test: %-9s depth underfoot after arriving, max_depth %d" % [
		"arrive", _planet.max_depth])
	_player.global_position = _planet.standing_position(far, TRAVERSE_ALTITUDE)
	_player.velocity = Vector3.ZERO

	var began := Time.get_ticks_msec()
	var full_at := -1
	var ladder := PackedStringArray()
	var next_report := 250
	var built_before := int(_planet.statistics()["built"])
	# The same three numbers `--traverse` prints, but taken only over the window
	# between arriving and converging. Averaged over a whole run they say nothing:
	# a planet that has caught up sits idle, and the idle frames outnumber the
	# busy ones badly enough to report a starved pool as a comfortable one.
	var frames := 0
	var pending_total := 0.0
	var requests_total := 0.0
	var pool_full := 0
	var floorless_peak := 0
	var floorless_until := 0
	var probed := false
	while Time.get_ticks_msec() - began < 8000:
		await get_tree().process_frame
		var stats := _planet.statistics()
		var elapsed := Time.get_ticks_msec() - began
		var floorless := int(stats["floorless"])
		floorless_peak = maxi(floorless_peak, floorless)
		if floorless > 0:
			floorless_until = elapsed
		if elapsed >= 500 and not probed:
			probed = true
			_probe_floor(far, "0.5s")
		if int(stats["depth"]) >= _planet.max_depth and full_at < 0:
			full_at = elapsed
		if full_at < 0:
			frames += 1
			pending_total += float(stats["pending"])
			requests_total += float(stats["requests"])
			if int(stats["pending"]) >= _planet.pending_limit:
				pool_full += 1
		if elapsed >= next_report:
			ladder.append("%.1fs:d%d" % [float(elapsed) / 1000.0, int(stats["depth"])])
			next_report += 500
	var settled := _planet.statistics()
	print("perf_test: arrive     %s" % " ".join(ladder))
	print("perf_test: arrive     full detail underfoot at %s, %d chunks built getting there" % [
		"%.2fs" % (float(full_at) / 1000.0) if full_at >= 0 else "never within 8s",
		int(settled["built"]) - built_before])
	if frames > 0:
		print("perf_test: arrive     %.1f of %d slots busy, pool full %d%% of frames, queue %.0f mean, %.2f ms a chunk" % [
			pending_total / float(frames), _planet.pending_limit,
			roundi(100.0 * float(pool_full) / float(frames)),
			requests_total / float(frames), float(settled["build_ms"])])
	print("perf_test: arrive     %d drawn chunks in reach peaked without a collider, last one %.2fs in, %d bodies now" % [
		floorless_peak, float(floorless_until) / 1000.0, int(settled["bodies"])])
	_probe_floor(far, "settled")


## Everything about the floor at one reported place, in the terms of the report.
##
## Somebody says "I fall through the ground here" and quotes the latitude and
## longitude off [CoordinatePlate]. This stands a settled player on that spot and
## answers the two questions that follow: is there a collider, and does it agree
## with the surface being drawn. It exists because neither is visible — a hole in
## the floor and a collider a metre under the mesh photograph identically, and
## both photograph identically to nothing being wrong.
func _inspect(quoted: String) -> void:
	var parts := quoted.split(",", false)
	if parts.size() != 2:
		push_error("--at wants LAT,LON, for example --at=\"41.98 S,39.21 E\"")
		return
	var lat := deg_to_rad(_signed(parts[0], "S"))
	var lon := deg_to_rad(_signed(parts[1], "W"))
	var direction := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)).normalized()
	_player.global_position = _planet.standing_position(direction, 2.0)
	_player.velocity = Vector3.ZERO
	print("perf_test: at        %s  dir %.4f, %.4f, %.4f" % [
		quoted, direction.x, direction.y, direction.z])
	# Half a second in, which is the window the fault lives in: the ground drawn
	# here is still coarse, and a coarse chunk has no canyon in it. Settled, the
	# drawn surface and the finest field agree and there is nothing to find.
	var began := Time.get_ticks_msec()
	while Time.get_ticks_msec() - began < 500:
		await get_tree().process_frame
	_report_spacings("arriving")
	_probe_floor(direction, "0.5s", 10.0)
	await _settle()
	_report_spacings("settled")
	var stats := _planet.statistics()
	print("perf_test: at        lod %d/%d, %d colliders, %d drawn chunks still without one" % [
		int(stats["depth"]), _planet.max_depth, int(stats["bodies"]),
		int(stats["floorless"])])
	# Ten metres rather than the arrival probe's twenty-five: this one is aimed at
	# a fault somebody has already found, so it wants to resolve the shape of it
	# rather than to establish that the floor exists at all.
	_probe_floor(direction, "settled", 10.0)
	await _report_stance()


## Where the body comes to rest, as against where the floor is.
##
## The probe above asks whether the collider is in the right place. This asks the
## other half — whether the player is standing *on* it — and the two failures are
## indistinguishable from inside the game: a body held a decimetre up and ground
## drawn a decimetre low photograph identically. What tells them apart is
## anything that grows out of the true surface, which is why this got written the
## day the flowers went in and the player turned out to be wading over them.
const STANCE_FRAMES := 120

func _report_stance() -> void:
	var shape: PlanetShape = _planet.shape
	var space := get_viewport().world_3d.direct_space_state
	# Over a couple of seconds rather than off one frame. A body at rest is not
	# quite at rest — it settles, and the guard and the solver hand it back and
	# forth by millimetres — so a single sample lands anywhere in that band and
	# reads as a difference when nothing has changed.
	var field_total := 0.0
	var mesh_total := 0.0
	var worst := -INF
	var down := 0
	for _i in STANCE_FRAMES:
		await get_tree().physics_frame
		var local := _planet.to_local(_player.global_position)
		var out := local.normalized()
		var over_field := local.length() - shape.radius \
				- shape.elevation(out, _planet.spacing_underfoot())
		field_total += over_field
		worst = maxf(worst, over_field)
		if _player.is_on_floor():
			down += 1
		var up := _planet.global_transform.basis * out
		var query := PhysicsRayQueryParameters3D.create(
				_player.global_position + up * 3.0, _player.global_position - up * 30.0)
		query.collision_mask = 1
		query.exclude = [_player.get_rid()]
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			mesh_total += hit["position"].distance_to(_player.global_position + up * 3.0) - 3.0
	# The capsule's lowest point in body space. If this is not zero then the body
	# origin is not the feet, and every other number here has to be read against
	# it rather than against the ground.
	var sole := INF
	var mount := _player.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if mount != null and mount.shape is CapsuleShape3D:
		sole = mount.position.y - (mount.shape as CapsuleShape3D).height * 0.5
	print("perf_test: stance    standing still, the feet sit %.3f m over the field on average (worst %.3f m), %.3f m over the collider" % [
		field_total / float(STANCE_FRAMES), worst, mesh_total / float(STANCE_FRAMES)])
	print("perf_test: stance    capsule sole %.3f m from origin, on the floor %d of %d frames, snap %.2f m, margin %.3f m" % [
		sole, down, STANCE_FRAMES, _player.floor_snap_length, _player.safe_margin])


## The two spacings the ground can be asked about, and the depth behind them.
func _report_spacings(when: String) -> void:
	print("perf_test: at        %-9s depth underfoot %d/%d, drawn spacing %.1f m, finest %.1f m" % [
		when, int(_planet.statistics()["depth"]), _planet.max_depth,
		_planet.spacing_underfoot(), _planet.finest_spacing()])


## Degrees with a hemisphere letter after them, as [CoordinatePlate] writes one.
func _signed(text: String, negative: String) -> float:
	var trimmed := text.strip_edges().to_upper()
	var flip := trimmed.ends_with(negative)
	var digits := trimmed.trim_suffix("N").trim_suffix("S").trim_suffix("E") \
		.trim_suffix("W").strip_edges()
	return -absf(digits.to_float()) if flip else digits.to_float()


## Whether the ground you can see is the ground you would land on.
##
## The hole this catches does not show in a screenshot and does not show in a
## chunk count: the mesh is drawn, the collider is absent, and the only symptom
## is a body passing through a surface onto the one below it. So it is asked as
## the player asks it — a ray straight down at the terrain, against the height
## field the same ray should have hit.
##
## The disagreement is reported **signed**, because the two directions are
## different faults. A collider above the field is the mesh standing proud of it
## and is harmless: you walk on the mesh. A collider below the field is ground
## the player's own guard will haul them up out of, and past
## `OnlinePlayer.TUNNEL_DEPTH` that reads as sinking and being spat back out.
## The field is sampled at [method Planet.finest_spacing], because that is what
## the guard samples at and an unlimited-detail reading measures a terrain
## nothing in the game is standing on.
func _probe_floor(direction: Vector3, when: String, step := 25.0) -> void:
	var space := get_viewport().world_3d.direct_space_state
	var shape: PlanetShape = _planet.shape
	var fine := _planet.finest_spacing()
	var drawn := _planet.spacing_underfoot()
	var basis_u := direction.cross(Vector3.UP).normalized()
	var basis_v := direction.cross(basis_u).normalized()
	var missed := 0
	var tested := 0
	var worst_fine := 0.0
	var worst_drawn := 0.0
	var worst_at := Vector3.ZERO
	for u in range(-4, 5):
		for v in range(-4, 5):
			var spot := (direction * shape.radius + basis_u * (u * step)
					+ basis_v * (v * step)).normalized()
			var query := PhysicsRayQueryParameters3D.create(
					_planet.standing_position(spot, 200.0),
					_planet.standing_position(spot, -120.0))
			tested += 1
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				missed += 1
				continue
			var mesh_at := _planet.to_local(hit["position"]).length()
			var off_fine := absf(mesh_at - shape.radius - shape.elevation(spot, fine))
			var off_drawn := absf(mesh_at - shape.radius - shape.elevation(spot, drawn))
			if off_fine > worst_fine:
				worst_fine = off_fine
				worst_at = spot
			worst_drawn = maxf(worst_drawn, off_drawn)
	# Both, because the gap between them is the fault. The guard used to sample at
	# the finest and stand a body on ground that is not drawn; it now samples at
	# the drawn spacing, so the second number is the one that has to stay small
	# and the first is free to be as large as the canyon the lid is over.
	print("perf_test: floor probe %-8s %d of %d rays found no collider, collider off the finest field by %.2f m, off the drawn field by %.2f m" % [
		when, missed, tested, worst_fine, worst_drawn])
	if worst_fine > 2.0:
		var lat := rad_to_deg(asin(clampf(worst_at.y, -1.0, 1.0)))
		var lon := rad_to_deg(atan2(worst_at.x, worst_at.z))
		print("perf_test:             worst at lat %.2f %s lon %.2f %s" % [
			absf(lat), "N" if lat >= 0.0 else "S",
			absf(lon), "E" if lon >= 0.0 else "W"])


## What each render distance costs, which is the only honest way to choose the
## scales in [constant Planet.DETAIL_LEVELS]: they are an area of ground held at
## each level of detail, so the triangle count goes up with the square of them and
## guessing lands an order of magnitude out.
func _distances() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	_check_wire()
	# Both vantages, because they disagree about which end of the ladder matters.
	# From the air the near ground dominates and a longer reach buys little for a
	# lot; on foot almost everything in frame is far away, which is the case a top
	# level has to earn its triangles in.
	for stop: Array in DISTANCE_STOPS:
		for level in Planet.DETAIL_LEVELS.size():
			_planet.detail_level = level
			var named: Dictionary = Planet.DETAIL_LEVELS[level]
			await _measure("%s %s %.1fx" % [stop[0], named["label"], named["scale"]],
				stop[1] as float, true, stop[2] as float)
			# The one setting in the menu whose whole point is what it looks like,
			# so the frame times are only half the answer. A level that costs more
			# and cannot be told apart from the one under it is not a level.
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(
				"%sdistance_%s_%d.png" % [SHOT_DIR, stop[0], level])


## The case the parked stops cannot show. Standing still, the LOD has nothing to
## do and the thread pool is idle; crossing the ground at 200 m/s it is building,
## uploading and throwing away chunks continuously, and that is where a stutter
## would live. Reported as a distribution, because the mean is the one number
## guaranteed to hide it.
func _traverse() -> void:
	_park(TRAVERSE_ALTITUDE, true)
	await _settle()

	# Driven rather than flown. The flight model winds its speed up over seconds,
	# so a run that stutters flies slower and therefore stutters less — a
	# benchmark whose load depends on its own result cannot be compared with
	# anything, which is exactly what the first attempts at this did.
	var axis := _up.cross(_site.global_basis.z).normalized()
	var angle := 0.0
	var samples: Array[float] = []
	var built_before := int(_planet.statistics()["built"])
	var until := Time.get_ticks_msec() + 20000
	var worst_apply := 0.0
	var worst_collision := 0.0
	var worst_lod := 0.0
	# Which end of the pipe is narrow. `pending` is how many builds are running
	# and `requests` is how many chunks are waiting to be one; a full pool with a
	# long queue is supply, and free slots with a queue is demand asked for too
	# late to fill them.
	var pending_total := 0.0
	var requests_total := 0.0
	var worst_requests := 0
	var starved := 0
	# What the ground under the player is drawn at *while* they are moving, which
	# is the complaint the throughput figures cannot see. Ground delivered per
	# second says the pipe is working; this says whether it is keeping up.
	var depth_total := 0.0
	var depth_worst := 99
	var lod_rate_total := 0.0
	var lead_total := 0.0
	var lead_peak := 0.0
	while Time.get_ticks_msec() < until:
		var started := Time.get_ticks_usec()
		await get_tree().process_frame
		var spent := float(Time.get_ticks_usec() - started) / 1000.0
		samples.append(spent)
		angle += _traverse_speed * (spent / 1000.0) / _planet.shape.radius
		var direction := _up.rotated(axis, angle)
		_player.global_position = _planet.standing_position(direction, TRAVERSE_ALTITUDE)
		var stats := _planet.statistics()
		pending_total += float(stats["pending"])
		requests_total += float(stats["requests"])
		worst_requests = maxi(worst_requests, int(stats["requests"]))
		depth_total += float(stats["depth"])
		depth_worst = mini(depth_worst, int(stats["depth"]))
		lod_rate_total += float(stats["lod_hz"])
		lead_total += float(stats["lead"])
		lead_peak = maxf(lead_peak, float(stats["lead"]))
		if int(stats["pending"]) >= _planet.pending_limit:
			starved += 1
		worst_apply = maxf(worst_apply, float(stats["apply_ms"]))
		worst_collision = maxf(worst_collision, float(stats["collision_ms"]))
		worst_lod = maxf(worst_lod, float(stats["frame_ms"]))
		for part in _parts:
			_parts[part] = maxf(float(_parts[part]), float(stats[part + "_ms"]))
			_means[part] = float(_means[part]) + float(stats[part + "_ms"])
		_means["collision"] = float(_means["collision"]) + float(stats["collision_ms"])
		_means["apply"] = float(_means["apply"]) + float(stats["apply_ms"])
		_means["frame"] = float(_means["frame"]) + float(stats["frame_ms"])
		_worst_nodes = maxi(_worst_nodes, int(stats["nodes"]))
		_worst_visible = maxi(_worst_visible, int(stats["visible"]))
	var top := _traverse_speed

	samples.sort()
	var count := float(samples.size())
	var total := 0.0
	var dropped := 0
	for sample in samples:
		total += sample
		if sample > 16.7:
			dropped += 1
	var mean := total / float(samples.size())
	# Median as well as mean: one 200 ms hiccup from something outside the game
	# moves a mean of a thousand frames by a fifth of a millisecond per frame, and
	# the runs this is comparing differ by less than that.
	var median := samples[samples.size() / 2]
	print("perf_test: %-9s %8.1f %7.2fms  median %5.2fms  p99 %5.2fms  worst %5.2fms  built %d at %.0f m/s" % [
		"crossing", 1000.0 / maxf(median, 0.001), mean, median,
		samples[int(float(samples.size()) * 0.99)], samples[samples.size() - 1],
		int(_planet.statistics()["built"]) - built_before, top])
	print("perf_test: dropped frames  %d of %d over 16.7 ms" % [dropped, samples.size()])
	print("perf_test: underfoot       depth %.1f mean, %d worst, against max_depth %d while moving" % [
		depth_total / count, depth_worst, _planet.max_depth])
	print("perf_test: flight lead     %.0f m mean, %.0f m peak, quadtree walked at %.1f Hz mean" % [
		lead_total / count, lead_peak, lod_rate_total / count])
	print("perf_test: build pipe      %.1f of %d slots busy, pool full %d%% of frames, queue %.0f mean %d worst" % [
		pending_total / count, _planet.pending_limit,
		int(round(100.0 * float(starved) / count)),
		requests_total / count, worst_requests])
	print("perf_test: planet update   worst %.2fms, of which colliders %.2fms and mesh upload %.2fms" % [
		worst_lod, worst_collision, worst_apply])
	print("perf_test: of which        refine %.2fms  dispatch %.2fms  show %.2fms" % [
		_parts["refine"], _parts["dispatch"], _parts["show"]])
	print("perf_test: tree            %d nodes at its largest, %d chunks drawn, %d stranded" % [
		_worst_nodes, _worst_visible, int(_planet.statistics()["stranded"])])
	print("perf_test: mean planet     %.2fms = refine %.2f + dispatch %.2f + show %.2f + collide %.2f + apply %.2f" % [
		float(_means["frame"]) / count, float(_means["refine"]) / count,
		float(_means["dispatch"]) / count, float(_means["show"]) / count,
		float(_means["collision"]) / count, float(_means["apply"]) / count])
	print("perf_test: unaccounted     %.2fms of the %.2fms frame is outside the planet" % [
		mean - float(_means["frame"]) / count, mean])


## Parks the player and reports what the frame costs there. Frame time is taken
## as a distribution rather than an average: a mean of 8 ms with a worst of 40 is
## a stutter, and a mean on its own cannot tell the two apart.
func _measure(where: String, altitude: float, outward: bool, aim := INF) -> void:
	_park(altitude, outward, aim)
	await _settle()

	var total := 0.0
	var worst := 0.0
	var lod := 0.0
	var triangles := 0
	var draws := 0
	var bodies := 0
	for frame in SAMPLE_FRAMES:
		var started := Time.get_ticks_usec()
		await get_tree().process_frame
		var spent := float(Time.get_ticks_usec() - started) / 1000.0
		total += spent
		worst = maxf(worst, spent)
		var stats := _planet.statistics()
		lod += float(stats["update_ms"])
		triangles = maxi(triangles, int(stats["triangles"]))
		bodies = maxi(bodies, int(stats["bodies"]))
		draws = maxi(draws, int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	var mean := total / float(SAMPLE_FRAMES)
	print("perf_test: %-18s %8.1f %7.2fms %7.2fms %6.2fms %8s %7d %6d" % [
		where, 1000.0 / maxf(mean, 0.001), mean, worst, lod / float(SAMPLE_FRAMES),
		_thousands(triangles), draws, bodies])


## The wire the sweep below assumes, and the half of this feature the sweep cannot
## see: the menu writes an index into the settings, and the planet has to be
## following it. Left unchecked, a planet that never read the setting would sweep
## exactly as well as one that did, and the row in the menu would do nothing.
func _check_wire() -> void:
	var settings := get_node_or_null("/root/SettingsManager") as GameSettingsManager
	if settings == null:
		push_error("perf_test: no SettingsManager to write the render distance through")
		return
	var was := int(settings.get_setting(&"graphics", &"render_distance", 1))
	var wanted := Planet.DETAIL_LEVELS.size() - 1
	# Not saved: `set_setting` applies and announces, and writing settings.cfg is a
	# separate call. A benchmark should not leave the player on a new setting.
	settings.set_setting(&"graphics", &"render_distance", wanted)
	var took := _planet.detail_level
	settings.set_setting(&"graphics", &"render_distance", was)
	print("perf_test: settings wire   wrote %d, the planet went to %d, back to %d" % [
		wanted, took, _planet.detail_level])
	if took != wanted:
		push_error("perf_test: the planet is not following graphics/render_distance")


## Puts the player where the stop asks for, flying unless it is on the ground.
## [param aim] overrides the pitch, in radians, for a stop that wants neither of
## the two the flag offers.
func _park(altitude: float, outward: bool, aim := INF) -> void:
	_player.global_transform = Transform3D(
		_site.global_basis, _site.global_position + _up * altitude)
	_player.velocity = Vector3.ZERO
	if altitude > 3.0:
		_player.start_flying()
	# Looking out along the ground is the expensive view: it puts the whole
	# visible cap of the planet in shot instead of a few chunks underfoot.
	var pitch := (0.0 if outward else -0.9) if is_inf(aim) else aim
	_player.rotation = _player.rotation
	_player.camera.rotation.x = pitch


## Waits for the LOD to stop changing, or for the patience to run out. Settled
## means the tree has stopped growing, which is a better test than any fixed wait
## when the walk runs on its own clock.
func _settle() -> void:
	# Steadiness measured in seconds, not frames. Twenty frames at 800 fps is
	# twenty-five milliseconds, which every run cleared long before the LOD had
	# converged — and left each run starting from a different tree, which is why
	# the same code first measured anywhere between 37 and 94 fps.
	var deadline := Time.get_ticks_msec() + int(SETTLE_SECONDS * 1000.0)
	var was := -1
	var steady_since := Time.get_ticks_msec()
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var now := int(_planet.statistics()["visible"])
		if now != was:
			steady_since = Time.get_ticks_msec()
			was = now
		elif Time.get_ticks_msec() - steady_since > 750:
			return


func _apply_flags() -> void:
	var arguments := OS.get_cmdline_user_args()
	for argument in arguments:
		if argument == "--noshadow" and _sun != null:
			_sun.shadow_enabled = false
		elif argument == "--noclouds":
			var deck := _planet.find_child("Clouds", false, false) as MeshInstance3D
			if deck != null:
				deck.visible = false
		elif argument == "--nooutline":
			var material := _planet.SURFACE_MATERIAL as ShaderMaterial
			material.next_pass = null
		elif argument.begins_with("--draw="):
			var mode := argument.split("=")[1]
			var viewport := get_viewport()
			if mode == "unshaded":
				viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
			elif mode == "wireframe":
				viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
			elif mode == "overdraw":
				viewport.debug_draw = Viewport.DEBUG_DRAW_OVERDRAW
		elif argument.begins_with("--mat="):
			# One uniform on the terrain material, by name, as `_planet_test`
			# spells it. Pricing a shader feature wants the same build measured
			# with it on and off, and editing the material in between measures
			# the shader compiler as much as it measures the feature.
			for pair in argument.split("=", true, 1)[1].split(",", false):
				var halves := pair.split(":", true, 1)
				if halves.size() == 2:
					Planet.SURFACE_MATERIAL.set_shader_parameter(
						StringName(halves[0].strip_edges()), halves[1].to_float())
					print("perf_test: mat %s = %s" % [halves[0], halves[1]])
		elif argument.begins_with("--near="):
			_planet.collision_range = float(argument.split("=")[1])
		elif argument.begins_with("--splits="):
			_planet.splits_per_frame = int(argument.split("=")[1])
		elif argument.begins_with("--queue="):
			_planet.queue_depth = int(argument.split("=")[1])
		elif argument.begins_with("--applies="):
			_planet.applies_per_frame = int(argument.split("=")[1])
		elif argument.begins_with("--bodies="):
			_planet.bodies_per_frame = int(argument.split("=")[1])
		elif argument.begins_with("--lodhz="):
			# An explicit benchmark rate disables the adaptive distinction so
			# `--lodhz=30` still means thirty throughout a 1000 m/s crossing.
			var rate := int(argument.split("=")[1])
			_planet.lod_updates_per_second = rate
			_planet.fast_lod_updates_per_second = rate
		elif argument.begins_with("--fastlodhz="):
			_planet.fast_lod_updates_per_second = int(argument.split("=")[1])
		elif argument.begins_with("--pending="):
			_planet.pending_limit = int(argument.split("=")[1])
		elif argument.begins_with("--speed="):
			_traverse_speed = float(argument.split("=")[1])
		elif argument.begins_with("--lead="):
			_planet.lead_time = float(argument.split("=")[1])
		elif argument.begins_with("--leadmax="):
			_planet.lead_distance = float(argument.split("=")[1])


func _thousands(value: int) -> String:
	if value < 1000:
		return str(value)
	return "%.1fk" % (float(value) / 1000.0)
