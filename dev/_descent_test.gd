extends Node

## Checks that a player falling toward the planet is turned the right way up by
## the time their feet reach it, and that touching down leaves them walking.
##
##     & $godot --path . dev/_descent_test.tscn
##
## Three things are measured. The **ramp**: how much of a wrong orientation is
## left after a second at a given altitude, which should be all of it out in space
## and none of it near the ground. The **landing**: whether a dive into the surface
## ends in the standing stance with the feet down. The **walk**: whether a run
## across the curve stays on it. Shots land in dev/captures/.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

# OnlinePlayer.Stance, which is private to the player and read here by index.
const STAND := 0
const FLY := 3
const CRASH := 4

## The most the capsule may be left behind by the limp body, metres along the
## ground. The camera hangs off the capsule, so this is how far off the character
## the view is allowed to sit; a body length is generous and the coasting capsule
## this replaced managed seven metres on a hillside.
const CRASH_ADRIFT := 2.5

## Altitudes the ramp is sampled at, metres. Straddles the atmosphere so the
## gating shows up as a step rather than having to be taken on trust.
const RAMP_ALTITUDES: Array[float] = [
	12000.0, 6000.0, 3000.0, 2200.0, 1500.0, 800.0, 300.0, 80.0, 10.0,
]

var _player: OnlinePlayer
var _planet: Planet
var _site: Node3D
var _up := Vector3.UP


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# Without a state the world opens its home screen and spawns nobody, and
	# without the wait the roster has not been walked yet: the world builds its
	# players from its own _ready, so they arrive a frame or two behind it.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())
	for _frame in 30:
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
		if _player != null:
			break

	_planet = get_tree().current_scene.find_child("Planet", true, false) as Planet
	_site = get_tree().current_scene.find_child("LandingSite", true, false) as Node3D
	if _player == null or _planet == null or _site == null:
		push_error("descent_test: player=%s planet=%s site=%s" % [_player, _planet, _site])
		get_tree().quit(1)
		return
	_up = _site.global_basis.y
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	if "--yaw" in OS.get_cmdline_user_args():
		await _yaw()
		get_tree().quit()
		return

	await _spawn()
	await _ramp()
	await _landing()
	await _ridge()
	await _fast_dive()
	await _walk()
	await _yaw()
	get_tree().quit()


## The tick that used to go through the world, staged rather than flown.
##
## A boost covers seventeen metres between one physics frame and the next, and
## the height field that stands in for the missing colliders is asked about one
## point. Anything narrower than that is crossed between two questions: the body
## is over the ground where the tick began, over it again where the tick ended,
## and the hill it went through was never in front of anything that could see it.
##
## Flown, this is luck — `_fast_dive` gets a different heading and a different
## hillside every run. So the chord is placed by hand on a ridge the planet
## actually has, with both ends deliberately clear of the ground, and the guard
## is asked the same question the tick would have asked it.
func _ridge() -> void:
	var span := 1000.0 / 60.0
	var found := _find_ridge(span)
	if found.is_empty():
		print("descent_test: ridge          none found, nothing to cross")
		return
	var from: Vector3 = _planet.to_global(found["from"])
	var to: Vector3 = _planet.to_global(found["to"])
	# Flying first: `start_flying` clears the velocity and the speed the crash is
	# judged on, so anything written before it is thrown away.
	_player.start_flying()
	_player.global_position = to
	_player.velocity = (to - from).normalized() * 1000.0
	_player.set("_swept_from", from)
	_player.set("_flight_velocity", _player.velocity)
	var caught: bool = _player.call("_catch_ground")
	var stopped := _player.global_position.length() - _ground_height()
	print("descent_test: ridge          %.0f m of travel with %.0f m of hill in the middle of it," % [
		from.distance_to(to), found["deepest"]])
	print("descent_test: ridge caught   %s, stopped %.1f m in at %+.2f m of clearance" % [
		"yes" if caught else "NO — WENT THROUGH", from.distance_to(_player.global_position), stopped])
	var limp: bool = _player._ragdoll != null and _player._ragdoll.limp()
	print("descent_test: ridge crash    stance=%s, ragdoll %s" % [
		_name_of(_player._stance), "limp" if limp else "NOT LIMP"])
	if not caught or stopped < -0.5:
		push_error("descent_test: the ridge was crossed, %.1f m under the ground" % -stopped)
	if _player._stance != CRASH:
		push_error("descent_test: 1000 m/s into a hillside ended as %s"
			% _name_of(_player._stance))


## Two points a tick's travel apart with both ends above the ground and ground
## in between. Searched rather than written down, so it follows the planet's
## seed instead of pinning the check to one hillside that a reseed would move.
func _find_ridge(span: float) -> Dictionary:
	var shape := _planet.shape
	var spacing := _planet.finest_spacing()
	var best := {}
	var deepest := 0.0
	for index in 6000:
		var out := PlanetShape.even_direction(index, 6000)
		var side := out.cross(Vector3.UP)
		if side.length_squared() < 0.01:
			continue
		side = side.normalized()
		# Half a metre off their own ground at each end, which is where a flight
		# skimming a hillside actually is.
		var from := _clear_of(out * shape.radius - side * (span * 0.5), spacing)
		var to := _clear_of(out * shape.radius + side * (span * 0.5), spacing)
		var sank := 0.0
		for step in range(1, 32):
			sank = maxf(sank, -_field_clearance(from.lerp(to, float(step) / 32.0), spacing))
		if sank > deepest:
			deepest = sank
			best = {"from": from, "to": to, "deepest": sank}
	return best


func _clear_of(point: Vector3, spacing: float) -> Vector3:
	var out := point.normalized()
	return out * (_planet.shape.radius + _planet.shape.elevation(out, spacing) + 0.5)


## How far a point in the planet's own space is above the height field, negative
## inside it.
func _field_clearance(at: Vector3, spacing: float) -> float:
	var span := at.length()
	return span - (_planet.shape.radius + _planet.shape.elevation(at / span, spacing))


## A boosted flight held level a little way above the ground, which is the case
## that goes through the planet: a chunk only gets a collider once it is close,
## deep enough and finished building, and a flight at 200 m/s arrives at the next
## hill before that pipeline does. Reports the deepest the player ever got below
## the ground under them, and how many colliders were standing while it happened.
func _fast_dive() -> void:
	# From the spawn altitude, which is the one descent a player actually flies
	# and the only one with 9 km to reach full boost in.
	#
	# Put down already facing the planet rather than pitched round to it. Out
	# here nothing has squared the body to the surface — it still holds the
	# attitude it spawned with, 79 degrees off radial — and pitch sweeps the
	# body's own meridian, which that far off radial does not pass through the
	# planet at all. Aimed with the mouse the view swings as far as it can and
	# stops short, and the flight leaves at a tangent.
	_put(Basis.looking_at(-_up, Vector3.UP), 9000.0)
	_player._pitch = 0.0
	_player.head.rotation.x = 0.0
	await _wait(90)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	var deepest := INF
	var fewest := 1 << 30
	var top := 0.0
	var crashed := false
	var rolled := 0.0
	var adrift := 0.0
	var left := 0.0
	for frame in 3600:
		await get_tree().physics_frame
		# Everything the player sees with hangs off the capsule and the limp body
		# does not, so how far the two part is how far the camera is from the
		# character it is meant to be watching. Read while the body is still down;
		# what is kept is the last frame before it got up.
		if _player._stance == CRASH and _player._ragdoll != null and _player._ragdoll.limp():
			var body: Vector3 = _player._ragdoll.centre()
			var up := _player.global_basis.y
			var apart := body - _player.global_position
			adrift = maxf(adrift, (apart - up * apart.dot(up)).length())
			left = _player.global_position.distance_to(body)
		# Steered at the ground every frame, not aimed once. The view is pitched
		# against the body, and the body squares up to the planet as it falls —
		# so a dive lined up at nine kilometres is pointing at the horizon by
		# two, and the flight orbits instead of arriving. Nudged rather than
		# written, because `_fly_move` steers off the camera and the camera only
		# moves for real motion events. Pitch alone is enough from any heading:
		# straight down is a pole, and every meridian reaches it.
		var down := -_player.global_position.normalized()
		if (-_player.camera.global_basis.z).dot(down) < 0.995:
			var event := InputEventMouseMotion.new()
			event.relative = Vector2(0.0,
				20.0 if down.dot(_player.camera.global_basis.y) < 0.0 else -20.0)
			Input.parse_input_event(event)
		deepest = minf(deepest, _player.global_position.length() - _ground_height())
		fewest = mini(fewest, int(_planet.statistics().get("bodies", 0)))
		top = maxf(top, _player.velocity.length())
		crashed = crashed or _player._stance == CRASH
		rolled = maxf(rolled, absf(_player._tumble))
		if deepest < -400.0 or (_player._stance == STAND and _player.is_on_floor() and crashed):
			break
		if deepest < -400.0 or (not crashed and _player._stance != FLY and _player.is_on_floor()):
			break
	Input.action_release("move_forward")
	Input.action_release("sprint")
	await _wait(30)
	print("descent_test: fast flight    %s — deepest %.1f m %s the ground at up to %.0f m/s" % [
		"WENT THROUGH IT" if deepest < -2.0 else "stayed above it",
		absf(deepest), "below" if deepest < 0.0 else "above", top])
	print("descent_test: colliders      %d at the thinnest moment of that run" % fewest)
	print("descent_test: crash          %s, rolled %.0f°, ended as %s" % [
		"went down" if crashed else "NO CRASH", rad_to_deg(rolled),
		_name_of(_player._stance)])
	print("descent_test: crash view     camera %.2f m off the body at worst, got up %.2f m from it" % [
		adrift, left])
	if not crashed:
		push_error("descent_test: hitting the ground at %.0f m/s did not crash" % top)
	if adrift > CRASH_ADRIFT:
		push_error("descent_test: the camera was left %.1f m from the body it is watching" % adrift)
	await _buried()


## The guarantee the collider cannot give: a body already inside the planet, put
## there by whatever means, has to come back out. Colliders are built around the
## viewer and there are none down here, so only the height field can answer this.
func _buried() -> void:
	_put(Basis.IDENTITY, -120.0)
	var sank := _player.global_position.length() - _ground_height()
	await _wait(60)
	var now := _player.global_position.length() - _ground_height()
	print("descent_test: buried 120 m   came back to %.1f m %s the ground, stance=%s" % [
		absf(now), "below" if now < 0.0 else "above", _name_of(_player._stance)])
	if sank > -60.0:
		push_error("descent_test: the burial did not take, started %.1f m off" % sank)


## Turning left and right, which is the one thing the mouse is always expected to
## do. Reports how far the view actually went and whether the turn tipped the
## body off the ground, which is what a turn about the wrong axis does: on a
## sphere the parent's up is the way up at one point and a lie everywhere else.
##
## Runs alone under `-- --yaw`, since it is the only check here that wants no
## flying done beforehand.
func _yaw() -> void:
	# Above the air nothing has squared the body to the planet, so it still has
	# the attitude it spawned with; down in the air the alignment has had it.
	# Turning should feel the same in both, and the third case is the honest
	# limit — a view lying along the axis it turns about goes nowhere, in this or
	# any other first-person game.
	var cases: Array[Array] = [
		["space, level     ", Basis.looking_at(-_up, Vector3.UP), 5000.0, 0.0],
		["air, level       ", _site.global_basis, 1000.0, 0.0],
		["air, looking down", _site.global_basis, 1000.0, -1.4],
	]
	for case in cases:
		_put(case[1] as Basis, case[2] as float)
		# Written straight in rather than pitched into place, because an earlier
		# test leaves the view looking at its own feet and every case here has to
		# start from a stated attitude.
		_player._pitch = case[3] as float
		_player.head.rotation.x = case[3] as float
		await _wait(90)
		var tilt := _tilt()
		# Where the view ends up against where it started, rather than the distance
		# it covered getting there: a camera that jitters a couple of degrees a
		# frame racks up a convincing-looking total while pointing where it began.
		var eye := -_player.camera.global_basis.z
		var aimed := _eye_off()
		# A view that turns 90 degrees over two seconds of frames is locked as far
		# as anyone holding the mouse is concerned, so the frames are worth
		# reporting alongside the angle.
		var spent := 0.0
		for push in 40:
			var event := InputEventMouseMotion.new()
			event.relative = Vector2(40.0, 0.0)
			Input.parse_input_event(event)
			await get_tree().process_frame
			spent += get_process_delta_time()
		var swept := rad_to_deg(eye.angle_to(-_player.camera.global_basis.z))
		print("descent_test: yaw %s   view %3.0f° off the turn axis   tilt %2.0f°->%2.0f°   moved %3.0f°   frame %4.1f ms" % [
			case[0], aimed, tilt, _tilt(), swept, spent / 40.0 * 1000.0])
		if absf(_tilt() - tilt) > 2.0:
			push_error("descent_test: turning tipped the body %.0f° off the ground"
				% absf(_tilt() - tilt))


## How far the body leans off the way out of the planet's centre.
func _tilt() -> float:
	return rad_to_deg(_player.global_basis.y.angle_to(_player.global_position.normalized()))


## How far the view is off the axis the mouse turns it about. At 90° a turn is a
## turn; approaching 0 or 180 the same rotation is a roll and the view goes
## nowhere.
func _eye_off() -> float:
	return rad_to_deg((-_player.camera.global_basis.z).angle_to(_player.global_basis.y))


## Ground level under the player, from the same band-limited field the chunk
## meshes are built from rather than from whatever collider happens to exist.
func _ground_height() -> float:
	var direction := _player.global_position.normalized()
	return _planet.shape.radius + _planet.shape.elevation(direction, _planet.finest_spacing())


## The orbital spawn, left exactly as world.tscn places it. Out here the planet is
## dead ahead and the way out of its centre is straight behind, so forcing the
## body's up to radial has no tangent to keep the heading in — the view whips
## sideways and the shot the spawn was framed for is lost.
func _spawn() -> void:
	await _wait(90)
	var to_planet := -_player.global_position.normalized()
	var facing := -_player.camera.global_basis.z
	print("descent_test: spawn          altitude=%.0f m  error=%.1f°  looking %.1f° off the planet" % [
		_altitude(), _error(), rad_to_deg(facing.angle_to(to_planet))])
	await _shoot("descent_spawn")


## Drops the player in at each altitude with the orientation they spawn with —
## upright in world terms, which at this site is 79 degrees wrong — and reports
## what is left of that error a second later.
func _ramp() -> void:
	print("descent_test: ramp (error left after 1.0 s, starting from %.1f deg)"
		% rad_to_deg(Vector3.UP.angle_to(_up)))
	print("descent_test:   altitude   before    after   settled")
	for altitude in RAMP_ALTITUDES:
		_put(Basis.IDENTITY, altitude)
		var before := _error()
		await _wait(60)
		var after := _error()
		await _wait(180)
		print("descent_test:   %7.0f m  %6.1f°  %6.1f°   %6.1f°" % [
			altitude, before, after, _error()])


## A dive into the ground from low altitude, flown rather than teleported: the
## camera is pitched down with real mouse motion and forward is held, because
## `_fly_move` steers off the camera and a polled key is the only thing it reads.
func _landing() -> void:
	_put(Basis.IDENTITY, 90.0)
	await _wait(30)
	await _shoot("descent_entry")
	_look_down()
	Input.action_press("move_forward")
	var frames := 0
	while _player._stance == FLY and frames < 1200:
		await get_tree().physics_frame
		frames += 1
	Input.action_release("move_forward")
	await _wait(30)
	print("descent_test: landing        stance=%s floor=%s error=%.2f° after %.1f s" % [
		_name_of(_player._stance), str(_player.is_on_floor()), _error(), frames / 60.0])
	print("descent_test: standing on    %.2f m above sea level" % _altitude())
	# Back to level, or the shot is the dive's steep view of the grass rather than
	# the horizon a standing player is looking at.
	await _look_level()
	await _wait(20)
	await _shoot("descent_landed")


## A run along the ground, which is what turns the local up. Nothing should sink,
## and the body should still be square to the surface at the far end.
func _walk() -> void:
	# Started from the site rather than from wherever the dive finished, which is a
	# different patch of ground every time the flight model is touched — and
	# offset clear of the wardrobe, which stands at the site's own origin. Taking
	# the site's basis fixes which way the run goes, instead of leaving it to
	# whatever heading the alignment happened to end on.
	_player.global_transform = Transform3D(
		_site.global_basis, _site.global_position + _site.global_basis.x * 12.0 + _up * 1.0)
	_player.velocity = Vector3.ZERO
	_player.start_flying()
	await _wait(90)
	await _land_here()
	await _wait(120)
	var from := _player.global_position
	var start_altitude := _altitude()
	var crashes_before := _player._crashes
	Input.action_press("move_forward")
	Input.action_press("sprint")
	var grounded_for := 0
	for frame in 240:
		await get_tree().physics_frame
		if _player.is_on_floor():
			grounded_for += 1
	Input.action_release("move_forward")
	Input.action_release("sprint")
	await _wait(20)
	var travelled := from.distance_to(_player.global_position)
	print("descent_test: run            %.0f m in 4.0 s (%.0f m/s, a spooling sprint), stance=%s" % [
		travelled, travelled / 4.0, _name_of(_player._stance)])
	print("descent_test: run crashes    %d" % [_player._crashes - crashes_before])
	print("descent_test: stayed on it   floor %d%% of the time, altitude %.1f -> %.1f m" % [
		grounded_for * 100 / 240, start_altitude, _altitude()])
	print("descent_test: tracked curve  turned %.2f° of planet, still %.2f° off square" % [
		rad_to_deg(from.normalized().angle_to(_player.global_position.normalized())), _error()])
	await _shoot("descent_walked")


# --- Helpers ----------------------------------------------------------------

## Degrees between the body's own up and the way out of the planet's centre.
func _error() -> float:
	return rad_to_deg(_player.global_basis.y.angle_to(_player.global_position.normalized()))


func _altitude() -> float:
	return _player.global_position.length() - _planet.shape.radius


func _put(basis: Basis, altitude: float) -> void:
	# A limp body does not come along: the bones are simulating in world space
	# and would be left wherever the last stage crashed, kilometres from a
	# capsule that has just been carried across the planet. `_ridge` hands over
	# mid-crash, so without this every stage after it measures that gap.
	if _player._ragdoll != null and _player._ragdoll.limp():
		_player._ragdoll.stand_up()
	_player.global_transform = Transform3D(basis, _site.global_position + _up * altitude)
	_player.velocity = Vector3.ZERO
	_player.start_flying()
	# Both halves of "grounded" survive a teleport: `_footed` is the guard's
	# answer from wherever the body was standing, and `is_on_floor` is the last
	# move's, neither of which knows it has just been carried nine kilometres
	# up. The flight check reads them before it makes its first move, so left
	# alone the flight ends on the tick after it starts and everything below
	# measures a free fall instead. A zero-length move up here clears the
	# second; nothing in the game needs this, because taking off is refused
	# while grounded and a teleport is not a take-off.
	_player.set("_footed", false)
	_player.move_and_slide()


## Ends a hover by pressing the land key, which is what a player hanging a metre
## over the grass would do.
func _land_here() -> void:
	Input.action_press("land")
	await get_tree().physics_frame
	Input.action_release("land")


## Pitches the view down until it is looking along the way down, feeding real
## motion events because that is the only thing the look handler reads.
func _look_down() -> void:
	for attempt in 200:
		var down := -_player.global_position.normalized()
		if (-_player.camera.global_basis.z).dot(down) > 0.92:
			return
		var event := InputEventMouseMotion.new()
		event.relative = Vector2(0.0, 40.0)
		Input.parse_input_event(event)
		await get_tree().process_frame


## Pitches back up until the view is square to the local up, which on a sphere is
## the horizon rather than any world plane.
func _look_level() -> void:
	for attempt in 300:
		var facing := -_player.camera.global_basis.z
		if absf(facing.dot(_player.global_position.normalized())) < 0.02:
			return
		var event := InputEventMouseMotion.new()
		event.relative = Vector2(0.0, -20.0)
		Input.parse_input_event(event)
		await get_tree().process_frame


func _wait(frames: int) -> void:
	for frame in frames:
		await get_tree().process_frame


func _name_of(stance: int) -> String:
	return ["stand", "crouch", "slide", "fly", "crash", "swim"][stance]


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(SHOT_DIR + name + ".png")
