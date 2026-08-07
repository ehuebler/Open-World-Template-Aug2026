class_name ColourWheel
extends Control

## A hue-and-saturation disc with a value bar under it and the chosen colour
## along the bottom: the one control the character screen recolours anything
## with.
##
## It replaced ten fixed swatches. A tint here multiplies an authored-white body,
## so every colour in the space is reachable and there is no natural shortlist of
## ten to offer instead — the swatches were a menu standing in front of a
## continuum.
##
## **The commit is on release, not during the drag**, and that is a cost decision
## rather than a matter of feel. Both owners of [signal picked] write the look to
## `user://settings.cfg`, and the in-game one reads it back first, so a signal per
## frame of a drag would be a file round trip per frame. The swatch along the
## bottom is what the drag feeds instead: you see the colour you are about to
## commit without anything outside this control being told about it.

## The colour was let go of. Continuous feedback is the swatch, not this.
signal picked(colour: Color)

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

## Side of the disc, and of everything under it — the block is one column wide.
## Height is what the character card runs out of, and this control is the tallest
## thing on it, so the disc is as small as it can be and still be aimed: at 118 a
## degree of hue is a pixel of rim.
const DISC := 118.0
## Wedges around the disc. Hue is interpolated across each one by the rasteriser,
## so this is how many straight edges the rim has rather than how many colours
## are on offer.
const WEDGES := 48
## Slices of the value bar, for the same reason: it is a gradient drawn as rects.
const BAR_STEPS := 24
const BAR := 14.0
const SWATCH := 14.0
const GAP := 6.0
## Radius of the ring marking where on the disc the colour was taken from.
const MARKER := 5.0

enum Grip { NONE, DISC, BAR }

var _hue := 0.0
var _saturation := 0.0
## Starts at white, which is a tint that changes nothing — the honest resting
## state for a control that multiplies.
var _value := 1.0
var _grip := Grip.NONE


func _init() -> void:
	custom_minimum_size = Vector2(DISC, DISC + GAP + BAR + GAP + SWATCH)


func colour() -> Color:
	return Color.from_hsv(_hue, _saturation, _value)


## Puts the marker where a colour already is, so opening the wheel on a garment
## that has been painted before starts from that paint rather than from white.
func set_colour(value: Color) -> void:
	_hue = value.h
	_saturation = value.s
	_value = value.v
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_grip = _grip_at(button.position)
			if _grip != Grip.NONE:
				_take(button.position)
				accept_event()
		elif _grip != Grip.NONE:
			_grip = Grip.NONE
			picked.emit(colour())
			accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _grip != Grip.NONE:
		_take(motion.position)
		accept_event()


## Which half of the control a press landed in. Decided once, on the press, so a
## drag that wanders out of the disc keeps steering the disc rather than jumping
## to whatever it is now over.
func _grip_at(at: Vector2) -> Grip:
	if at.distance_to(_centre()) <= DISC * 0.5:
		return Grip.DISC
	if _bar().has_point(at):
		return Grip.BAR
	return Grip.NONE


func _take(at: Vector2) -> void:
	if _grip == Grip.DISC:
		var offset := at - _centre()
		_hue = fposmod(atan2(offset.y, offset.x), TAU) / TAU
		_saturation = clampf(offset.length() / (DISC * 0.5), 0.0, 1.0)
	else:
		_value = clampf((at.x - _bar().position.x) / _bar().size.x, 0.0, 1.0)
	queue_redraw()


func _centre() -> Vector2:
	return Vector2(DISC, DISC) * 0.5


func _bar() -> Rect2:
	return Rect2(0.0, DISC + GAP, DISC, BAR)


func _swatch() -> Rect2:
	return Rect2(0.0, DISC + GAP + BAR + GAP, DISC, SWATCH)


func _draw() -> void:
	_draw_disc()
	_draw_bar()
	var swatch := _swatch()
	draw_rect(swatch, colour())
	draw_rect(swatch, Color(PALETTE.text_muted, 0.9), false, 1.6)


## Wedges from the centre out, each one Gouraud-shaded from the grey the current
## value gives to the two hues at its edges. Cheap enough to leave as immediate
## drawing: it is repainted on a drag and on nothing else.
func _draw_disc() -> void:
	var centre := _centre()
	var radius := DISC * 0.5
	var hub := Color.from_hsv(0.0, 0.0, _value)
	for step in WEDGES:
		var from := TAU * float(step) / float(WEDGES)
		var to := TAU * float(step + 1) / float(WEDGES)
		draw_polygon(
			PackedVector2Array([
				centre,
				centre + Vector2(cos(from), sin(from)) * radius,
				centre + Vector2(cos(to), sin(to)) * radius]),
			PackedColorArray([hub,
				Color.from_hsv(from / TAU, 1.0, _value),
				Color.from_hsv(to / TAU, 1.0, _value)]))
	var at := centre + Vector2(cos(_hue * TAU), sin(_hue * TAU)) * (_saturation * radius)
	# Two rings, dark under light: the marker has to be found over both the white
	# hub and a fully saturated rim, and neither ink alone survives both.
	draw_arc(at, MARKER + 1.0, 0.0, TAU, 20, PALETTE.ink, 2.6, true)
	draw_arc(at, MARKER, 0.0, TAU, 20, PALETTE.text_primary, 1.6, true)


func _draw_bar() -> void:
	var bar := _bar()
	var slice := bar.size.x / float(BAR_STEPS)
	for step in BAR_STEPS:
		var level := (float(step) + 0.5) / float(BAR_STEPS)
		draw_rect(Rect2(bar.position + Vector2(slice * step, 0.0),
			Vector2(ceilf(slice), bar.size.y)),
			Color.from_hsv(_hue, _saturation, level))
	var x := bar.position.x + bar.size.x * _value
	draw_line(Vector2(x, bar.position.y - 2.0),
		Vector2(x, bar.end.y + 2.0), PALETTE.ink, 3.4)
	draw_line(Vector2(x, bar.position.y - 2.0),
		Vector2(x, bar.end.y + 2.0), PALETTE.text_primary, 1.6)
