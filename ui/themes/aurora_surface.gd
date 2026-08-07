class_name AuroraSurface
extends ColorRect

## A pane of lit space that backs a Control, so the menus are drawn out of the
## same material as the sky behind them.
##
##     AuroraSurface.add_to(button, AuroraSurface.Style.BUTTON)
##
## The surface becomes a child of the Control with show_behind_parent set, which
## puts it under the Control's own text and icons while leaving those crisp.
## Buttons and fields hand their hover, press and focus states to it, and each
## state is an amount of light rather than a change of colour.
##
## This replaced a coloured-pencil surface that drew every pane with traced
## borders and hatched shading. The seam is unchanged — one static call, one
## enum, the same nine styles — because the styles were never about pencils: they
## are the two families below, and which family a control belongs to is what
## keeps the UI legible whatever it is drawn in.

## Surfaces come in two families, and the split is what keeps the UI legible.
## PAPER, CARD, ROW, INPUT and HUD are **containers**: dark space, holding
## starlight type. BUTTON, PRIMARY and DANGER are **controls**: filled with one of
## the bright colours, holding void-dark type. A control is therefore never the
## colour of the thing it sits on, whatever nesting it ends up in.
enum Style {
	PAPER, ## Full-screen backdrop: open space, lit faintly towards the rim.
	CARD, ## The menu pane every screen is drawn on, lifted off the backdrop.
	ROW, ## A lobby entry or tooltip, recessed into the pane.
	INPUT, ## Text fields, recessed so typed starlight stays readable.
	HUD, ## A plate for text read over the world, where the backdrop is unknown.
	BUTTON, ## The default control: filled periwinkle.
	PRIMARY, ## The default action of a screen, filled ion cyan.
	DANGER, ## Quitting and leaving, filled nebula rose.
	RULE, ## A drawn line, standing in for HSeparator.
}

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const SHADER: Shader = preload("res://shaders/cosmic/cosmic_ui.gdshader")

## The drawn shape is always inset from the backing rect by this much, so the rim
## light has somewhere to bloom into. Outside a container the rect is grown by the
## same amount, which lands the shape exactly on the Control's bounds; inside one
## the container owns the rect, so the shape sits just inside the Control instead.
const BLEED := 6.0
## Light added to the resting tone per state. A hover lifts the pane, a press
## lifts it further — the opposite direction from the strokes this replaced, and
## the reason `fill_tone` now runs past 1.0.
const HOVER_LIFT := 0.16
const PRESS_LIFT := 0.34
const STATE_TIME := 0.09
## Tall enough to hold the rule's own glow, while the inset collapses the drawn
## shape to a single lit line through the middle of it.
const RULE_HEIGHT := 9.0

var _style := Style.CARD
## 1.0 is the pane at rest, and every state reads off this.
var _resting_tone := 1.0
var _resting_rim := 0.9
## What the rim goes back to once the focus ring is lifted off it.
var _resting_rim_color := PALETTE.ink_soft
var _held := false
var _tone_tween: Tween


static func add_to(target: Control, style: Style) -> AuroraSurface:
	var placed_by_container := target is Container
	var surface := AuroraSurface.new()
	surface.name = "AuroraSurface"
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
static func rule() -> AuroraSurface:
	var surface := AuroraSurface.new()
	surface.name = "AuroraRule"
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
	var fill := PALETTE.paper
	var fill_alpha := 1.0
	var depth_shade := 0.35
	var corner := 18.0
	var nebula := 0.30
	var nebula_scale := 1.6
	var stars := 0.35
	var twinkle := 0.5
	var rim := PALETTE.ink_soft
	var rim_strength := 0.9
	var rim_width := 26.0
	var edge_line := 1.4
	var edge_strength := 0.5

	match _style:
		Style.PAPER:
			# Open space with no edge of its own: the backdrop is the whole
			# window, so a rim on it would be a frame drawn around the screen.
			corner = 0.0
			depth_shade = 0.5
			nebula = 0.22
			nebula_scale = 0.55
			stars = 0.5
			rim_strength = 0.0
			edge_strength = 0.0
		Style.CARD:
			fill = PALETTE.paper_card
			# Not opaque. A pane of lit air is the whole idea, and the starfield
			# showing faintly through it is what says the menu is inside the
			# scene rather than laid over it. The nebula and the rim carry the
			# legibility that the missing opacity would have.
			fill_alpha = 0.93
			corner = 22.0
			nebula = 0.34
			nebula_scale = 1.1
			rim = PALETTE.secondary
			rim_strength = 0.5
			rim_width = 54.0
			edge_line = 1.6
			edge_strength = 0.55
		Style.ROW:
			fill = PALETTE.paper_shade
			fill_alpha = 0.9
			corner = 14.0
			depth_shade = 0.2
			nebula = 0.18
			nebula_scale = 2.4
			stars = 0.22
			rim = PALETTE.ink_soft
			rim_strength = 0.7
			rim_width = 18.0
			edge_line = 1.1
			edge_strength = 0.45
		Style.INPUT:
			fill = PALETTE.paper_shade
			fill_alpha = 0.95
			corner = 10.0
			depth_shade = 0.14
			nebula = 0.1
			nebula_scale = 3.0
			# Fields hold text the player is reading back, so nothing in them
			# moves: a caret is hard enough to find without a star behind it.
			stars = 0.0
			twinkle = 0.0
			rim = PALETTE.ink_soft
			rim_strength = 0.8
			rim_width = 10.0
			edge_line = 1.2
			edge_strength = 0.5
		Style.HUD:
			# The one style that cannot rely on what is behind it: grass, sky and
			# painted props all pass under the same prompt. So the plate is opaque
			# and quiet — no drifting cloud, no stars — and its contrast comes
			# from the fill rather than from the text colour.
			fill = PALETTE.paper_card
			fill_alpha = 1.0
			corner = 8.0
			depth_shade = 0.16
			nebula = 0.0
			stars = 0.0
			twinkle = 0.0
			rim = PALETTE.secondary
			rim_strength = 0.35
			rim_width = 9.0
			edge_line = 1.2
			edge_strength = 0.4
		# The three control fills. Each is a real colour rather than a tone of the
		# pane, so a button reads as a button before its label is even read, and
		# hover and press raise the light on it without changing its hue.
		Style.BUTTON:
			fill = PALETTE.secondary
			corner = 12.0
			depth_shade = 0.28
			# A control is a lit object, not a window onto space: no cloud and no
			# stars, or the label sits on a moving field.
			nebula = 0.0
			stars = 0.0
			twinkle = 0.0
			rim = PALETTE.highlight
			rim_strength = 0.3
			rim_width = 14.0
			edge_line = 1.2
			edge_strength = 0.35
		Style.PRIMARY:
			fill = PALETTE.accent
			corner = 12.0
			depth_shade = 0.28
			nebula = 0.0
			stars = 0.0
			twinkle = 0.0
			rim = PALETTE.highlight
			rim_strength = 0.42
			rim_width = 16.0
			edge_line = 1.4
			edge_strength = 0.45
		Style.DANGER:
			fill = PALETTE.danger
			corner = 12.0
			depth_shade = 0.3
			nebula = 0.0
			stars = 0.0
			twinkle = 0.0
			rim = PALETTE.highlight
			rim_strength = 0.34
			rim_width = 14.0
			edge_line = 1.3
			edge_strength = 0.4
		Style.RULE:
			# Only the lit line is drawn: no pane, since the rule sits on the
			# card's own sheet. The inset flattens the rect until the rounded
			# shape is a single horizontal line.
			fill_alpha = 0.0
			corner = 0.0
			nebula = 0.0
			stars = 0.0
			twinkle = 0.0
			rim = PALETTE.ink_soft
			rim_strength = 0.0
			edge_line = 1.0
			edge_strength = 0.7

	_resting_rim = rim_strength
	_resting_rim_color = rim
	# Pixel sizes in the shader are viewport units, so the rim keeps its weight
	# whatever window the project is stretched into.
	shader_material.set_shader_parameter(
		&"reference_height",
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 720))
	)
	shader_material.set_shader_parameter(&"fill_color", fill)
	shader_material.set_shader_parameter(&"fill_alpha", fill_alpha)
	shader_material.set_shader_parameter(&"depth_shade", depth_shade)
	shader_material.set_shader_parameter(&"fill_tone", _resting_tone)
	shader_material.set_shader_parameter(&"corner_radius", corner)
	shader_material.set_shader_parameter(&"inset_pixels", BLEED)
	shader_material.set_shader_parameter(&"nebula_color", PALETTE.secondary)
	shader_material.set_shader_parameter(&"nebula_deep", PALETTE.accent)
	shader_material.set_shader_parameter(&"nebula_strength", nebula)
	shader_material.set_shader_parameter(&"nebula_scale", nebula_scale)
	shader_material.set_shader_parameter(&"star_color", PALETTE.highlight)
	shader_material.set_shader_parameter(&"star_density", stars)
	shader_material.set_shader_parameter(&"star_twinkle", twinkle)
	shader_material.set_shader_parameter(&"rim_color", rim)
	shader_material.set_shader_parameter(&"rim_strength", rim_strength)
	shader_material.set_shader_parameter(&"rim_width_pixels", rim_width)
	shader_material.set_shader_parameter(&"edge_line_pixels", edge_line)
	shader_material.set_shader_parameter(&"edge_line_strength", edge_strength)
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
		# Unlit. A control with nothing behind it reads as off before its label
		# is read, which is the same job the greyed pencil fill used to do.
		_set_tone(0.55, true)
		return
	var tone := _resting_tone
	if button.is_hovered() or button.has_focus():
		tone += HOVER_LIFT
	if _held or button.button_pressed:
		tone += PRESS_LIFT
	_set_tone(tone, true)


## Focus is a brightened rim in starlight rather than a change to the fill, which
## would sit under the text the player is reading or typing. Starlight is used at
## this weight nowhere else, so wherever the keyboard is stays obvious on a screen
## where every control is already carrying a colour of its own.
func _set_focused(focused: bool) -> void:
	material.set_shader_parameter(
		&"rim_color", PALETTE.highlight if focused else _resting_rim_color
	)
	material.set_shader_parameter(
		&"rim_strength", maxf(_resting_rim, 0.3) * 2.2 if focused else _resting_rim
	)
	material.set_shader_parameter(&"edge_line_strength", 1.1 if focused else 0.5)


func _set_tone(tone: float, animated: bool) -> void:
	var target := clampf(tone, 0.0, 2.0)
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
