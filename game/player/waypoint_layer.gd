class_name WaypointLayer
extends Control

## Names the places on the planet that are too far away to recognise.
##
## One marker per [Landmark] in the [constant Landmark.GROUP] group, drawn where
## that landmark projects onto the screen, and pinned to the nearest edge when it
## is off to one side or behind. Added to the local player's HUD; nobody sees
## anyone else's.
##
## A marker is a diamond and two lines of type in the landmark's own colour, with
## an ink outline behind the letters and nothing else — no plate. The plate was
## the honest thing to draw while there was one waypoint, because [PencilSurface]
## is how everything else in this game keeps text legible over the world. With
## five of them it stopped being legibility and started being five opaque cards
## hanging in the sky, so the outline does that job instead: it costs no area,
## and unlike a drop shadow it works over both the pale sky and the dark sea.
##
## Three rules decide whether a marker is drawn at all, and all of them are about
## getting out of the way rather than about being seen:
##
## - **Near.** A name over somewhere you have arrived at is in front of the thing
##   it names. Each landmark carries its own range, and a second, longer one for
##   when it is under the crosshair — looking straight at a place is the clearest
##   statement that it has been found.
## - **Far.** From the spawn the whole planet is in frame, and naming all of it
##   at once is a contents page rather than a view: every place there is, none of
##   them anywhere you could go from here, over ground too small to put a name
##   on. So a marker has an outer range too, and the planet is approached
##   unlabelled — the names arrive on the way down, as the ground under them
##   turns into somewhere rather than a patch of colour.
## - **Through the planet.** A globe of this size hides most of itself, and a
##   name floating over the far side reads as a place that is somehow in front of
##   the ground. The cheap half of the test is one dot product: the eye is above
##   a landmark's horizon exactly when it is on the outward side of the tangent
##   plane there, which is exact for the sphere and costs nothing. The rest is
##   [method Planet.sight_blocked], which walks the height field along the line
##   and catches the ranges that stand above it — that one is throttled, because
##   it is a dozen noise lookups and the answer does not change between frames.

## How close to the screen's edge a pinned marker is allowed to sit.
const MARGIN := 46.0
## How close to the edge the type may come. Separate from [constant MARGIN]
## because the type slides along the edge to stay on screen while the diamond
## stays put at the point it is actually indicating.
const EDGE := 10.0
const TITLE_SIZE := 12
const DISTANCE_SIZE := 10
## Ink around the type, in pixels. Enough to close up under the pixel font's
## one-pixel stems at these sizes, which is what stops the letters breaking up
## against busy ground; more than this and the outlines of neighbouring glyphs
## merge into a slab and the plate is back.
const TITLE_OUTLINE := 4
const DISTANCE_OUTLINE := 3
## Half-width of the diamond, in pixels.
const DIAMOND := 4.5
## How much longer the diamond gets along the way it points, once pinned. The
## same shape either way: a diamond marks a spot and a stretched one aims at it,
## so nothing has to appear or disappear as a marker leaves the screen.
const POINT_STRETCH := 2.6
## Ink around the diamond, in pixels, added as an offset rather than a scale so
## the stretched one is not outlined more heavily along its long axis.
const DIAMOND_OUTLINE := 1.6
## Gap between the diamond and the first line of type.
const GAP := 7.0
## Share of a landmark's range spent fading, so a marker arrives and leaves
## rather than blinking on at a threshold the player crosses back and forth.
const FADE := 0.3
## Cosines of the angle off the crosshair that counts as looking at a place, and
## of the wider angle the longer range fades in from.
const AIM_TIGHT := 0.996
const AIM_WIDE := 0.94
## Seconds between terrain sight checks for one landmark. At a flat sprint the
## eye moves 8 m in this, against a test that answers to the nearest hilltop.
const SIGHT_INTERVAL := 0.25
const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

var _camera: Camera3D
## Landmark to the marker drawn for it, so markers are built once rather than per
## frame and a landmark that goes out of range keeps its own.
var _markers: Dictionary = {}


func _init() -> void:
	name = "Waypoints"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## The camera the markers are projected through. Without one there is nothing to
## project against and the layer draws nothing.
func bind(camera: Camera3D) -> void:
	_camera = camera


## Which places are being named right now, in the order they were first drawn.
## Whether a marker is up is the whole of this layer's behaviour, and it is far
## easier to read off a list than off a screenshot — which is why the harness
## asks for this rather than counting pixels.
##
## [param least] is the alpha a marker has to reach to count. The default is what
## a player would call named; drop it to catch a marker that has begun to fade in
## but cannot be read yet, which is the difference between the range a name
## arrives at and the range it arrives by.
func drawn(least := 0.5) -> PackedStringArray:
	var titles := PackedStringArray()
	for landmark: Landmark in _markers:
		var marker: Control = _markers[landmark]
		if marker.visible and marker.modulate.a > least:
			titles.append(landmark.title)
	return titles


func _process(_delta: float) -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	var now := float(Time.get_ticks_msec()) * 0.001
	var eye := _camera.global_position
	var forward := -_camera.global_basis.z
	var half := size * 0.5
	for node in get_tree().get_nodes_in_group(Landmark.GROUP):
		var landmark := node as Landmark
		if landmark != null:
			_place(landmark, _marker_for(landmark), eye, forward, half, now)


func _place(landmark: Landmark, marker: Control, eye: Vector3, forward: Vector3,
		half: Vector2, now: float) -> void:
	var at := landmark.global_position
	var away := eye.distance_to(at)
	var toward_here := (at - eye) / maxf(away, 0.001)
	var aim := smoothstep(AIM_WIDE, AIM_TIGHT, forward.dot(toward_here))
	var near := lerpf(landmark.show_beyond, landmark.aimed_beyond, aim)
	var shown := clampf((away - near) / maxf(near * FADE, 1.0), 0.0, 1.0)
	if landmark.hide_beyond > 0.0:
		var far := landmark.hide_beyond
		shown = minf(shown, clampf((far - away) / maxf(far * FADE, 1.0), 0.0, 1.0))
	if shown <= 0.0 \
			or (eye - at).dot(landmark.global_basis.y) <= 0.0 \
			or _out_of_sight(landmark, marker, eye, at, now):
		marker.visible = false
		return

	marker.visible = true
	marker.modulate.a = shown
	(marker.get_meta(&"distance") as Label).text = Landmark.distance_text(away)

	var pinned := false
	var toward := Vector2.ZERO
	var screen := half
	if _camera.is_position_behind(at):
		# unproject_position mirrors anything behind the lens, so the only usable
		# direction back there is the one in the camera's own space.
		var local := _camera.global_transform.affine_inverse() * at
		toward = -Vector2(local.x, -local.y)
		pinned = true
	else:
		screen = _camera.unproject_position(at)
		toward = screen - half
		pinned = absf(toward.x) > half.x - MARGIN or absf(toward.y) > half.y - MARGIN
	if pinned:
		screen = half + _to_edge(toward, half - Vector2(MARGIN, MARGIN))
	marker.position = screen

	var aimed := toward.normalized() if pinned else Vector2.ZERO
	if marker.get_meta(&"toward") != aimed:
		marker.set_meta(&"toward", aimed)
		marker.queue_redraw()
	_lay_out(marker, screen)


## Puts the type under the diamond, or over it near the bottom of the screen, and
## slides it along the edge rather than letting a long name run off the side. The
## diamond does not move with it: it is pointing at something.
func _lay_out(marker: Control, screen: Vector2) -> void:
	var column := marker.get_meta(&"column") as Control
	column.size = column.get_combined_minimum_size()
	# Cleared for the pointed diamond whether or not it is pointing, so the type
	# does not hop by a dozen pixels at the moment a marker crosses the edge of
	# the screen and the diamond grows.
	var reach := DIAMOND * POINT_STRETCH + GAP
	var below := screen.y + reach + column.size.y < size.y - EDGE
	column.position = Vector2(
		clampf(screen.x - column.size.x * 0.5, EDGE, maxf(EDGE, size.x - column.size.x - EDGE)) - screen.x,
		reach if below else -(reach + column.size.y))


## Whether the ground is in the way, answered at most every [constant
## SIGHT_INTERVAL] and remembered in between.
func _out_of_sight(landmark: Landmark, marker: Control, eye: Vector3, at: Vector3,
		now: float) -> bool:
	if now < float(marker.get_meta(&"checked")) + SIGHT_INTERVAL:
		return bool(marker.get_meta(&"blocked"))
	var planet := landmark.planet_host()
	var blocked := planet != null and planet.sight_blocked(eye, at)
	marker.set_meta(&"checked", now)
	marker.set_meta(&"blocked", blocked)
	return blocked


## Scales a direction until it lands on the edge of a box that size, which is
## what pins an off-screen marker to the side it is actually off.
func _to_edge(toward: Vector2, half: Vector2) -> Vector2:
	var reach := INF
	if absf(toward.x) > 0.001:
		reach = minf(reach, half.x / absf(toward.x))
	if absf(toward.y) > 0.001:
		reach = minf(reach, half.y / absf(toward.y))
	if reach == INF:
		return Vector2.ZERO
	return toward * reach


# --- Markers ----------------------------------------------------------------

## A marker is one zero-sized [Control] parked at the projected point, with the
## diamond drawn about its own origin and the type in a box hung off it. Zero
## sized on purpose: everything about the marker is positioned relative to the
## one point that means anything, and a rect would only be something else to keep
## in step with it.
func _marker_for(landmark: Landmark) -> Control:
	if _markers.has(landmark):
		return _markers[landmark]

	var marker := Control.new()
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.set_meta(&"toward", Vector2.ZERO)
	marker.set_meta(&"tint", landmark.tint)
	marker.set_meta(&"blocked", false)
	# Spread the first sight check over the interval rather than having every
	# marker on the HUD do its dozen height lookups in the same frame.
	marker.set_meta(&"checked", -randf() * SIGHT_INTERVAL)
	marker.draw.connect(_draw_marker.bind(marker))
	add_child(marker)

	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 2)
	marker.add_child(column)

	column.add_child(_line(landmark.title, TITLE_SIZE, TITLE_OUTLINE, landmark.tint))
	var distance := _line("", DISTANCE_SIZE, DISTANCE_OUTLINE,
		landmark.tint.lerp(PALETTE.text_muted, 0.55))
	column.add_child(distance)

	marker.set_meta(&"column", column)
	marker.set_meta(&"distance", distance)
	_markers[landmark] = marker
	return marker


func _line(text: String, font_size: int, outline: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", colour)
	label.add_theme_color_override(&"font_outline_color", PALETTE.ink)
	label.add_theme_constant_override(&"outline_size", outline)
	return label


## Drawn rather than typed: the pixel font has no diamond or arrow glyph, and a
## letter standing in for one reads as a letter.
func _draw_marker(marker: Control) -> void:
	var toward: Vector2 = marker.get_meta(&"toward")
	var tint: Color = marker.get_meta(&"tint")
	marker.draw_colored_polygon(_diamond(toward, DIAMOND_OUTLINE), PALETTE.ink)
	marker.draw_colored_polygon(_diamond(toward, 0.0), tint)


func _diamond(toward: Vector2, grow: float) -> PackedVector2Array:
	var wide := DIAMOND + grow
	if toward == Vector2.ZERO:
		return PackedVector2Array([
			Vector2(0.0, -wide), Vector2(wide, 0.0),
			Vector2(0.0, wide), Vector2(-wide, 0.0)])
	var side := toward.orthogonal()
	return PackedVector2Array([
		toward * (DIAMOND * POINT_STRETCH + grow), side * wide,
		-toward * wide, -side * wide])
