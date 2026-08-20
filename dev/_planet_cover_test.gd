extends Node

## Checks that the terrain draw walk never leaves a hole in the planet.
##
##     godot --headless --path . dev/_planet_cover_test.tscn
##
## [method Planet._show] decides what to draw by asking whether a chunk's children have
## all managed to draw themselves, and keeps a coarse ancestor on screen until they have.
## It also memoizes that answer, because the tree runs to a thousand nodes and a walk that
## revisited all of them was one of the three expensive passes in the frame. The memo is
## the risk: a cached answer is a promise that the visibility to match it has already been
## applied, and anything that moves a chunk on or off screen behind the walk's back breaks
## that promise silently. What it looks like when it breaks is a parent standing aside for
## children that are not being drawn, which is a hole you can see the sea through.
##
## So this stands up a real planet, flies a viewer over it fast enough to keep the thread
## pool behind, and after every single frame requires each of the six faces to be covered
## — by its own mesh, or wholly by its descendants. It deliberately does not inspect the
## flags or the walk: coverage is the property that matters, and it is checkable from the
## outside without agreeing with the implementation about how it is achieved.

## How far the viewer flies, and how fast. Fast enough that levels are always part-built,
## which is the only condition under which a chunk is hidden for a reason that has nothing
## to do with itself — and that was the case the memo got wrong.
const FLIGHT_FRAMES := 900
const FLIGHT_SPEED := 90.0
## Frames the first faces are given to build before coverage is required at all. Nothing
## covers anything until the first six meshes land, and that is not a hole.
const SETTLE_FRAMES := 240
## Frames of standing still afterwards, since a viewer that stops is what lets the tree
## finish collapsing and settle — a different set of transitions from arriving somewhere.
const REST_FRAMES := 120
## Depth the flight has to reach for any of this to mean anything. A walk that never split
## would be covered by its six roots and would pass every check here while testing none.
const DEPTH_WANTED := 5

var _failures := 0


## A planet with a viewer that goes where it is told. Everything else is the real thing,
## including the worker-thread builds whose timing is what this is about.
class CoverPlanet extends Planet:
	var eye_local := Vector3.UP

	func _ready() -> void:
		if shape == null:
			shape = PlanetShape.new()
			# No city pads: they cost height samples on every build and change nothing
			# about which chunk is drawn.
			shape.settled = false
		super._ready()
		eye_local = Vector3.UP * (shape.radius + 40.0)

	func viewer_position() -> Vector3:
		return eye_local


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	await _check_cover()
	_finish()


func _check_cover() -> void:
	var planet := CoverPlanet.new()
	add_child(planet)
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame
	var axis := Vector3.RIGHT
	var facing := Vector3.UP
	var radius := planet.shape.radius
	var deepest := 0
	var holes := 0
	var first_hole := -1
	for frame in FLIGHT_FRAMES + REST_FRAMES:
		if frame < FLIGHT_FRAMES:
			facing = facing.rotated(
				axis, FLIGHT_SPEED * get_process_delta_time() / radius).normalized()
			planet.eye_local = facing * (radius + 40.0)
		await get_tree().process_frame
		deepest = maxi(deepest, _deepest_drawn(planet))
		if _uncovered(planet) > 0:
			holes += 1
			if first_hole < 0:
				first_hole = frame
	_expect(deepest >= DEPTH_WANTED,
		"flying over the planet splits it to depth %d" % deepest)
	if first_hole < 0:
		_expect(true, "not one of %d frames left a face uncovered"
			% (FLIGHT_FRAMES + REST_FRAMES))
	else:
		_expect(false, ("%d of %d frames left a face uncovered, from frame %d"
			+ " — a parent stood aside for children that were not drawn")
			% [holes, FLIGHT_FRAMES + REST_FRAMES, first_hole])
	planet.queue_free()
	await get_tree().process_frame


## Faces whose ground is not on screen anywhere.
func _uncovered(planet: CoverPlanet) -> int:
	var missing := 0
	for root: Variant in planet._roots:
		if not _covers(root):
			missing += 1
	return missing


## Whether this chunk's patch is drawn, by itself or by its descendants between them.
## The same question [method Planet._show] answers, asked of the scene rather than of
## the walk's own bookkeeping, so the two agreeing means something.
func _covers(chunk: Variant) -> bool:
	if chunk.instance != null and chunk.instance.visible:
		return true
	if chunk.children.is_empty():
		return false
	for child: Variant in chunk.children:
		if not _covers(child):
			return false
	return true


func _deepest_drawn(planet: CoverPlanet) -> int:
	var deepest := 0
	for chunk: Variant in planet._visible:
		deepest = maxi(deepest, int(chunk.depth))
	return deepest


func _expect(passed: bool, message: String) -> void:
	if passed:
		print("planet_cover_test: PASS  %s" % message)
		return
	_failures += 1
	printerr("planet_cover_test: FAIL  %s" % message)


func _finish() -> void:
	if _failures == 0:
		print("planet_cover_test: all checks passed")
	else:
		printerr("planet_cover_test: %d check(s) failed" % _failures)
	await get_tree().process_frame
	get_tree().quit(1 if _failures > 0 else 0)
