class_name PencilSurface
extends ColorRect

## A sheet of shader-drawn paper that backs a Control, so the menus are drawn by
## the same pencil shader family as the game world.
##
##     PencilSurface.add_to(button, PencilSurface.Style.BUTTON)
##
## The surface becomes a child of the Control with show_behind_parent set, which
## puts it under the Control's own text and icons while leaving those crisp.
## Buttons and fields hand their hover, press and focus states to it, and each
## state is a hatching density rather than a fill colour.

## Surfaces come in two families, and the split is what keeps the UI legible.
## PAPER, CARD, ROW, INPUT and HUD are **containers**: violet, holding custard
## type. BUTTON, PRIMARY and DANGER are **controls**: filled with one of the
## bright colours, holding violet type. A control is therefore never the colour
## of the thing it sits on, whatever nesting it ends up in.
enum Style {
	PAPER, ## Full-screen backdrop: bare violet, shaded towards the edges.
	CARD, ## The menu panel every screen is drawn on, lifted off the backdrop.
	ROW, ## A lobby entry or tooltip, recessed into the card.
	INPUT, ## Text fields, recessed so typed custard stays readable.
	HUD, ## A plate for text read over the world, where the backdrop is unknown.
	BUTTON, ## The default control: filled celadon.
	PRIMARY, ## The default action of a screen, filled gold.
	DANGER, ## Quitting and leaving, filled tangerine.
	RULE, ## A drawn line, standing in for HSeparator.
}

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const SHADER: Shader = preload("res://shaders/pencil/pencil_ui.gdshader")

## The drawn shape is always inset from the backing rect by this much, so border
## strokes that wander outward are not cut off. Outside a container the rect is
## grown by the same amount, which lands the shape exactly on the Control's
## bounds; inside one the container owns the rect, so the shape sits just inside
## the Control instead.
const BLEED := 6.0
## Hatching added on top of the resting density per state. A hover presses one
## more stroke layer in, a press two.
const HOVER_SHADE := 0.10
const PRESS_SHADE := 0.24
const STATE_TIME := 0.09
## Tall enough to hold a wandering stroke, while the inset collapses the traced
## rect to a single line through the middle of it.
const RULE_HEIGHT := 9.0

var _style := Style.CARD
## 1.0 is bare paper, and only the styles that want a shaded fill lower it.
var _resting_tone := 1.0
var _resting_border := 2.0
## What the border goes back to once the focus ring is lifted off it.
var _resting_border_color := PALETTE.ink
var _held := false
var _tone_tween: Tween


static func add_to(target: Control, style: Style) -> PencilSurface:
	var placed_by_container := target is Container
	var surface := PencilSurface.new()
	surface.name = "PencilSurface"
	surface._style = style
	surface.color = Color.WHITE
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.show_behind_parent = true
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not placed_by_container:
		surface.offset_left = -BLEED
		surface.offset_top = -BLEED
		surface.offset_right = BLEED
		surface.offset_bottom = BLEED
	target.add_child(surface)
	surface._apply_style()
	surface._follow_states(target)
	return surface


## A drawn rule for places the menus would otherwise put an HSeparator. It needs
## no Control to back, so it goes straight into a container.
static func rule() -> PencilSurface:
	var surface := PencilSurface.new()
	surface.name = "PencilRule"
	surface._style = Style.RULE
	surface.color = Color.WHITE
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.custom_minimum_size = Vector2(0.0, RULE_HEIGHT)
	surface.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	surface._apply_style()
	return surface


func _apply_style() -> void:
	var shader_material := ShaderMaterial.new()
	shader_material.shader = SHADER
	var paper := PALETTE.paper
	var paper_alpha := 1.0
	var ink := PALETTE.ink
	var border := PALETTE.ink
	var ink_tint := 0.5
	var ink_strength := 0.5
	var corner := 14.0
	var border_passes := 2
	var border_pixels := 2.0
	var border_wander := 2.4
	var border_gaps := 0.16
	var edge_ink := 0.25
	var edge_width := 18.0
	var hatch_scale := 12.0
	var grain := 0.24
	var redraw_fps := 8.0

	match _style:
		Style.PAPER:
			# Bare paper. Only the rim is shaded, which frames the menu without
			# drawing one more border around the screen.
			corner = 0.0
			border_passes = 0
			edge_ink = 0.4
			edge_width = 240.0
			hatch_scale = 8.0
			# Kept fainter than the card's: at full strength the backdrop's tooth
			# reads as dirt across the whole screen.
			ink_strength = 0.26
			ink_tint = 0.15
			grain = 0.32
		Style.CARD:
			paper = PALETTE.paper_card
			# Framed in dimmed custard rather than ink: a card floats over open
			# space, and a dark border on a dark panel leaves it with no edge at
			# all on the side where the starfield shows through.
			border = PALETTE.text_secondary
			corner = 20.0
			border_pixels = 2.6
			edge_ink = 0.3
			edge_width = 90.0
			ink_strength = 0.36
		Style.ROW:
			paper = PALETTE.paper_shade
			border = PALETTE.text_muted
			corner = 12.0
			border_passes = 1
			border_pixels = 1.8
			edge_ink = 0.22
			edge_width = 24.0
			ink_strength = 0.4
		Style.INPUT:
			paper = PALETTE.paper_shade
			border = PALETTE.text_muted
			corner = 8.0
			border_passes = 1
			border_pixels = 1.7
			ink_tint = 0.3
			edge_ink = 0.14
			edge_width = 6.0
			# Fields hold text the player is reading back, so their strokes stay
			# put instead of boiling under it.
			redraw_fps = 0.0
		Style.HUD:
			# The one style that cannot rely on what is behind it: grass, sky and
			# painted props all pass under the same prompt. So the plate is opaque
			# and left bare under the label, contrast comes from the plate rather
			# than from the text colour, and the border is drawn firmly enough to
			# hold its own shape against a busy background.
			paper = PALETTE.paper_card
			border = PALETTE.text_secondary
			corner = 7.0
			border_pixels = 2.0
			border_wander = 1.2
			border_gaps = 0.08
			ink_strength = 0.3
			ink_tint = 0.3
			edge_ink = 0.16
			edge_width = 7.0
			grain = 0.18
			# Text the player is reading mid-game: the strokes hold still.
			redraw_fps = 0.0
		# The three control fills. Each is a real colour rather than a tone of the
		# card, so a button reads as a button before its label is even read, and
		# hover and press shade the fill further without changing its hue.
		Style.BUTTON:
			paper = PALETTE.secondary
			corner = 10.0
			border_pixels = 2.0
			ink_tint = 0.65
			_resting_tone = 0.92
			edge_ink = 0.22
			edge_width = 8.0
		Style.PRIMARY:
			paper = PALETTE.accent
			corner = 10.0
			border_pixels = 2.4
			ink_tint = 0.65
			_resting_tone = 0.92
			edge_ink = 0.22
			edge_width = 8.0
		Style.DANGER:
			paper = PALETTE.danger
			corner = 10.0
			border_pixels = 2.4
			# Tangerine is dark enough that ink hatching on it turns to mud, so
			# its shading is pulled towards the paper instead and the label above
			# it is custard rather than violet.
			ink_tint = 0.35
			ink_strength = 0.4
			_resting_tone = 0.94
			edge_ink = 0.18
			edge_width = 8.0
		Style.RULE:
			border = PALETTE.text_muted
			# Only the traced border is drawn: no paper, since the rule sits on
			# the card's own sheet. The inset flattens the rect to a single line,
			# which two passes then draw over twice.
			paper_alpha = 0.0
			corner = 0.0
			border_passes = 2
			border_pixels = 1.3
			border_wander = 1.1
			border_gaps = 0.1
			edge_ink = 0.0
			grain = 0.0

	_resting_border = border_pixels
	_resting_border_color = border
	# Pixel sizes in the shader are viewport units, so the strokes keep their
	# weight whatever window the project is stretched into.
	shader_material.set_shader_parameter(
		&"reference_height",
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 720))
	)
	shader_material.set_shader_parameter(&"paper_color", paper)
	shader_material.set_shader_parameter(&"paper_alpha", paper_alpha)
	shader_material.set_shader_parameter(&"paper_grain", grain)
	shader_material.set_shader_parameter(&"ink_color", ink)
	shader_material.set_shader_parameter(&"ink_tint", ink_tint)
	shader_material.set_shader_parameter(&"ink_strength", ink_strength)
	shader_material.set_shader_parameter(&"fill_tone", _resting_tone)
	shader_material.set_shader_parameter(&"hatch_scale", hatch_scale)
	shader_material.set_shader_parameter(&"corner_radius", corner)
	shader_material.set_shader_parameter(&"inset_pixels", BLEED)
	shader_material.set_shader_parameter(&"edge_ink", edge_ink)
	shader_material.set_shader_parameter(&"edge_width_pixels", edge_width)
	shader_material.set_shader_parameter(&"border_color", border)
	shader_material.set_shader_parameter(&"border_passes", border_passes)
	shader_material.set_shader_parameter(&"border_pixels", border_pixels)
	shader_material.set_shader_parameter(&"border_wander_pixels", border_wander)
	shader_material.set_shader_parameter(&"border_gaps", border_gaps)
	shader_material.set_shader_parameter(&"redraw_fps", redraw_fps)
	# Every surface gets its own stroke field, so two buttons side by side are
	# not scribbled identically.
	shader_material.set_shader_parameter(&"border_seed", randf() * 40.0)
	material = shader_material


func _follow_states(target: Control) -> void:
	if target is BaseButton:
		var button := target as BaseButton
		var refresh := func() -> void: _refresh_button(button)
		button.mouse_entered.connect(refresh)
		button.mouse_exited.connect(refresh)
		button.focus_entered.connect(refresh)
		button.focus_exited.connect(refresh)
		button.button_down.connect(func() -> void:
			_held = true
			refresh.call()
		)
		button.button_up.connect(func() -> void:
			_held = false
			refresh.call()
		)
		button.toggled.connect(func(_pressed: bool) -> void: refresh.call())
		# Callers disable buttons right after creating them, so the first read of
		# the state waits until they have had their say.
		refresh.call_deferred()
		return
	if target is LineEdit or target is SpinBox:
		target.focus_entered.connect(func() -> void: _set_focused(true))
		target.focus_exited.connect(func() -> void: _set_focused(false))


func _refresh_button(button: BaseButton) -> void:
	_set_focused(button.has_focus() and not button.disabled)
	if button.disabled:
		# Nothing pressed the pencil into the paper here.
		_set_tone(minf(_resting_tone + 0.09, 1.0), true)
		return
	var tone := _resting_tone
	if button.is_hovered() or button.has_focus():
		tone -= HOVER_SHADE
	if _held or button.button_pressed:
		tone -= PRESS_SHADE
	_set_tone(tone, true)


## Focus is gone over again in custard rather than shaded in, which would sit
## under the text the player is reading or typing. Custard is used at fill weight
## nowhere else, so wherever the keyboard is stays obvious on a screen where
## every control is already carrying a colour of its own.
func _set_focused(focused: bool) -> void:
	material.set_shader_parameter(
		&"border_color", PALETTE.highlight if focused else _resting_border_color
	)
	material.set_shader_parameter(&"border_pixels", _resting_border * (2.0 if focused else 1.0))


func _set_tone(tone: float, animated: bool) -> void:
	var target := clampf(tone, 0.0, 1.0)
	if _tone_tween != null and _tone_tween.is_valid():
		_tone_tween.kill()
	if not animated or not is_inside_tree():
		material.set_shader_parameter(&"fill_tone", target)
		return
	var from := float(material.get_shader_parameter(&"fill_tone"))
	_tone_tween = create_tween()
	_tone_tween.tween_method(
		func(value: float) -> void: material.set_shader_parameter(&"fill_tone", value),
		from,
		target,
		STATE_TIME
	)
