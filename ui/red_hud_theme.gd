class_name RedHudTheme
extends RefCounted

## Shared gameplay-HUD presentation: black type, square red plates, and the
## same red/green accents as the Tab menu. Bars may opt into rounded ends.

const RED := Color("ef151f")
const RED_BRIGHT := Color("ff3445")
const RED_PLATE := Color(0.91, 0.28, 0.31, 0.92)
const GREEN := Color("45df68")
const BLUE := Color("268bff")
const HEALTH := Color("ef151f")
const BLACK := Color(0.012, 0.014, 0.016, 0.96)
const INK := Color(0.008, 0.008, 0.010, 1.0)


static func panel(
		control: Control,
		padding := 0.0,
		fill := RED_PLATE,
		border := RED_BRIGHT,
		border_width := 2
	) -> void:
	control.add_theme_stylebox_override(
		&"panel", style(fill, border, border_width, padding)
	)


static func label(control: Label, font_size := 10) -> void:
	control.add_theme_font_size_override(&"font_size", font_size)
	control.add_theme_color_override(&"font_color", INK)
	control.add_theme_color_override(&"font_outline_color", Color.TRANSPARENT)
	control.add_theme_constant_override(&"outline_size", 0)


static func input(control: LineEdit, font_size := 11) -> void:
	control.add_theme_font_size_override(&"font_size", font_size)
	control.add_theme_color_override(&"font_color", INK)
	control.add_theme_color_override(&"font_placeholder_color", Color(INK, 0.56))
	control.add_theme_color_override(&"caret_color", INK)
	control.add_theme_color_override(&"selection_color", Color(GREEN, 0.72))
	control.add_theme_stylebox_override(
		&"normal", style(RED_PLATE, RED_BRIGHT, 2, 6.0)
	)
	control.add_theme_stylebox_override(
		&"focus", style(Color(GREEN, 0.92), GREEN, 2, 6.0)
	)


## Same red plate and black ink as [method input], and the same green for the
## state the player is about to commit to.
static func button(control: Button, font_size := 14, padding := 10.0) -> void:
	control.add_theme_font_size_override(&"font_size", font_size)
	control.add_theme_color_override(&"font_color", INK)
	control.add_theme_color_override(&"font_hover_color", INK)
	control.add_theme_color_override(&"font_pressed_color", INK)
	control.add_theme_color_override(&"font_focus_color", INK)
	control.add_theme_color_override(&"font_disabled_color", Color(INK, 0.45))
	control.add_theme_color_override(
		&"font_outline_color", Color.TRANSPARENT)
	control.add_theme_constant_override(&"outline_size", 0)
	control.add_theme_stylebox_override(
		&"normal", style(RED_PLATE, RED_BRIGHT, 2, padding))
	control.add_theme_stylebox_override(
		&"hover", style(Color(GREEN, 0.92), GREEN, 2, padding))
	control.add_theme_stylebox_override(
		&"pressed", style(Color(GREEN, 0.72), GREEN, 2, padding))
	control.add_theme_stylebox_override(
		&"focus", style(Color.TRANSPARENT, GREEN, 2, padding))
	control.add_theme_stylebox_override(
		&"disabled", style(Color(RED_PLATE, 0.38), Color(RED_BRIGHT, 0.42),
			2, padding))
	control.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


static func style(
		fill: Color,
		border: Color,
		border_width: int,
		padding: float,
		radius := 0
	) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = padding
	box.content_margin_top = padding
	box.content_margin_right = padding
	box.content_margin_bottom = padding
	return box
