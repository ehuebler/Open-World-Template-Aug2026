class_name ScorchDecals
extends Node3D

## Burn marks projected onto the ground, in a fixed ring of reused decals.
##
## The terrain already carries the burn: [TerrainScars] darkens the vertex
## colour and takes a groove out of the height field, and that is the version
## that survives, replicates and is what a chunk is rebuilt from. But a chunk
## has a vertex about every metre and a half at its finest, so a mark a couple
## of metres across is three or four vertices wide — enough to tint the ground
## and nowhere near enough to have an edge. From standing height that reads as
## the grass changing colour, not as something having been burned.
##
## So this puts the readable version on top: a projected texture with a real
## soot edge, immediately, on the frame the beam lands. The two are deliberately
## not the same lifetime. The decal is what you see while you are burning and
## for a while afterwards; the scar is what is still there tomorrow.
##
## A fixed ring rather than a decal per burn, for the same reason [Snowfield]
## uses one for footprints: a sustained beam would otherwise allocate a node
## every tick, and the oldest mark is always the one worth losing.

## Marks kept before the oldest is reused. A held beam commits one every
## quarter-second, so this is about twenty seconds of continuous fire.
const MARKS := 64

## How far above and below the ground the projection box reaches, in metres. It
## has to cover the unevenness the mark is laid across without being so deep
## that it paints the underside of an overhang.
const REACH := 1.6

## Seconds a mark takes to fade once nothing is refreshing it. Long, because the
## terrain scar underneath is doing the permanent half of the job and a decal
## that snapped out would read as the burn being undone.
const FADE := 22.0

## Pixels across the soot texture. Small on purpose: a burn is a blob with a
## frayed edge, and resolution spent on it would only be resolution spent on
## noise that shimmers when it is minified.
const SOOT_PIXELS := 96

## How close, as a share of the existing mark's radius, a new burn has to land
## before it counts as the same burn. A held beam lands ten a second on one
## spot: laid as ten separate decals they multiply into a black hole with no
## soot edge left in it, so the second one onwards refreshes the first instead.
const MERGE_SHARE := 0.6

var _marks: Array[Decal] = []
var _ages := PackedFloat32Array()
## Marks that belong to a scar rather than to a beam, and so never fade.
var _kept := PackedByteArray()
var _next := 0
var _soot: ImageTexture


func _ready() -> void:
	_soot = _soot_texture()
	set_process(false)


## Lays one burn on a surface.
##
## [param up] is the way out of that surface — the face normal where there is
## one, not the way out of the planet. A burn on the side of a boulder projected
## along the planet's up is a burn smeared the whole height of the boulder, and
## the beam lands on vertical rock as often as it lands on ground.
## [param keep] is for a mark that belongs to a committed [TerrainScars.Scar]
## rather than to the beam that made it. The height field carries a scar's own
## darkening as vertex colour, but the ground is drawn from a photographic
## material at the range a scar is looked at from, and a tint spread over a few
## vertices under that is not a burn anyone can see. This is: it does not fade,
## and it is what is still on the ground when the beam has long stopped.
func scorch(at: Vector3, up: Vector3, radius: float, strength := 1.0,
		keep := false) -> void:
	if _soot == null:
		return
	var axis := up.normalized()
	var side := axis.cross(
		Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		return
	side = side.normalized()
	var slot := _merged(at, radius)
	if slot < 0:
		slot = _take()
	var mark := _marks[slot]
	_kept[slot] = 1 if keep else _kept[slot]
	mark.global_transform = Transform3D(
		Basis(side, axis, side.cross(axis)), at)
	# A kept mark is allowed to be as wide as the scar it stands for; the box
	# has to be deep enough to reach the floor of a crater from its rim.
	mark.size = Vector3(radius * 2.0,
		maxf(REACH, radius * 0.75) * 2.0, radius * 2.0)
	mark.modulate = Color(1.0, 1.0, 1.0, clampf(strength, 0.0, 1.0))
	mark.albedo_mix = 1.0
	mark.visible = true
	set_process(true)


## The slot of a mark already burned into this spot, or -1. Returned so the
## caller overwrites it in place: the burn deepens and its clock restarts, and
## one held beam stays one mark however long it is held.
func _merged(at: Vector3, radius: float) -> int:
	var near := radius * MERGE_SHARE
	for index in _marks.size():
		if not _marks[index].visible:
			continue
		if _marks[index].global_position.distance_to(at) > near:
			continue
		_ages[index] = 0.0
		return index
	return -1


func _process(delta: float) -> void:
	var burning := false
	for index in _marks.size():
		var mark := _marks[index]
		if not mark.visible or _kept[index] == 1:
			continue
		burning = true
		_ages[index] += delta
		var left := 1.0 - _ages[index] / FADE
		if left <= 0.0:
			mark.visible = false
			continue
		# Rooted rather than linear, so a mark holds its darkness for most of
		# its life and then goes. A linear fade spends the whole time visibly
		# disappearing, which reads as the ground healing itself while you
		# watch; squaring it is worse still, since it fades fastest at the
		# start, when the burn is supposed to be at its blackest.
		mark.albedo_mix = sqrt(left)
	set_process(burning)


## The next slot in the ring, built on first use so a session in which nobody
## burns anything never allocates sixty-four of them.
func _take() -> int:
	if _marks.size() < MARKS:
		var fresh := Decal.new()
		fresh.texture_albedo = _soot
		fresh.modulate = Color.WHITE
		fresh.albedo_mix = 1.0
		# Faded hard at the top and bottom of the box. A burn laid across
		# uneven ground otherwise ends in a straight line where the box stops,
		# and a straight line is the one thing a scorch mark never has.
		fresh.upper_fade = 0.45
		fresh.lower_fade = 0.45
		fresh.visible = false
		add_child(fresh, false, Node.INTERNAL_MODE_BACK)
		_marks.append(fresh)
		_ages.append(0.0)
		_kept.append(0)
		return _marks.size() - 1
	var reused := _next
	_ages[reused] = 0.0
	_kept[reused] = 0
	_next = (_next + 1) % MARKS
	return reused


## Soot, drawn rather than authored: a dark core, a ring of ash around it, and
## an edge broken up by a few low-frequency lobes.
##
## Deliberately smooth. Everything here is either a radial ramp or a handful of
## sine lobes, so there is nothing in it finer than a tenth of its own width —
## which is what lets it be minified down to a few pixels at gameplay distance
## without the edge crawling.
func _soot_texture() -> ImageTexture:
	var image := Image.create_empty(SOOT_PIXELS, SOOT_PIXELS, true,
		Image.FORMAT_RGBA8)
	for y in SOOT_PIXELS:
		for x in SOOT_PIXELS:
			var offset := Vector2(
				(float(x) + 0.5) / float(SOOT_PIXELS) * 2.0 - 1.0,
				(float(y) + 0.5) / float(SOOT_PIXELS) * 2.0 - 1.0)
			var reach := offset.length()
			var turn := offset.angle()
			# Three lobes and five, which do not share a period, so the edge
			# wanders all the way round instead of repeating.
			var edge := 1.0 + 0.11 * sin(turn * 3.0) + 0.07 * sin(turn * 5.0 + 1.7)
			var ink := 1.0 - smoothstep(0.42 * edge, 1.0 * edge, reach)
			# Ash: warmer and paler at the rim, black in the middle.
			var ash := smoothstep(0.15, 0.72, reach)
			image.set_pixel(x, y, Color(
				lerpf(0.035, 0.30, ash),
				lerpf(0.030, 0.24, ash),
				lerpf(0.028, 0.20, ash),
				ink))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
