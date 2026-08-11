@tool
class_name RedGlowPanel
extends Control

## A square-cornered black pane with a layered red rim.
##
## Use it directly as a responsive Control, or place it behind another Control:
##
##     var surface := RedGlowPanel.add_to(button)
##     surface.glow_intensity = 1.4
##
## The glow is drawn with CanvasItem lines rather than AuroraSurface, a shader,
## or a rounded StyleBox. It therefore stays sharp at every size and needs no
## external texture.

enum MouseBehavior {
	IGNORE,
	PASS,
	STOP,
}

@export_group("Surface")
@export var fill_color := Color(0.0, 0.0, 0.0, 0.40):
	set(value):
		fill_color = value
		queue_redraw()
@export var border_color := Color(1.0, 0.055, 0.11, 0.95):
	set(value):
		border_color = value
		queue_redraw()
@export_range(0.0, 12.0, 0.25, "or_greater") var border_width := 1.75:
	set(value):
		border_width = maxf(value, 0.0)
		queue_redraw()

@export_group("Glow")
@export_range(0.0, 4.0, 0.05, "or_greater") var glow_intensity := 1.0:
	set(value):
		glow_intensity = maxf(value, 0.0)
		queue_redraw()
@export_range(0.0, 40.0, 0.5, "or_greater") var glow_spread := 10.0:
	set(value):
		glow_spread = maxf(value, 0.0)
		queue_redraw()
@export_range(1, 8, 1) var glow_layers := 4:
	set(value):
		glow_layers = clampi(value, 1, 8)
		queue_redraw()

@export_group("Input")
@export var mouse_behavior: MouseBehavior = MouseBehavior.IGNORE:
	set(value):
		mouse_behavior = value
		_apply_mouse_behavior()


func _init() -> void:
	_apply_mouse_behavior()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	var shortest := minf(size.x, size.y)
	if shortest <= 0.0:
		return

	# Keeping the core line half a stroke inside the bounds gives it a crisp,
	# complete edge while the wider translucent strokes are still free to bloom
	# outside this Control when its parent does not clip children.
	var inset_limit := maxf(shortest * 0.5 - 0.01, 0.0)
	var inset := minf(maxf(border_width * 0.5, 0.5), inset_limit)
	var border_rect := Rect2(Vector2.ZERO, size).grow(-inset)

	_draw_glow(border_rect)
	draw_rect(border_rect, fill_color, true)
	if border_width > 0.0 and border_color.a > 0.0:
		draw_rect(border_rect, border_color, false, border_width, true)


func _draw_glow(border_rect: Rect2) -> void:
	if glow_intensity <= 0.0 or glow_spread <= 0.0 or border_color.a <= 0.0:
		return

	# Broadest first. Each successive layer is narrower and brighter, leaving a
	# hard core line over a soft but visibly layered red halo.
	for layer in range(glow_layers, 0, -1):
		var fraction := float(layer) / float(glow_layers)
		var width := border_width + glow_spread * 2.0 * fraction
		var falloff := (1.0 - fraction * 0.72)
		var alpha := border_color.a * glow_intensity * 0.11 * falloff * falloff
		draw_rect(border_rect, _with_alpha(border_color, alpha), false, width, true)


func _apply_mouse_behavior() -> void:
	match mouse_behavior:
		MouseBehavior.PASS:
			mouse_filter = Control.MOUSE_FILTER_PASS
		MouseBehavior.STOP:
			mouse_filter = Control.MOUSE_FILTER_STOP
		_:
			mouse_filter = Control.MOUSE_FILTER_IGNORE


func _with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))


## Adds a full-rect surface behind [param target] and returns it for tuning.
## The target keeps ownership of layout and input; callers can opt into PASS or
## STOP when the surface itself should participate in mouse routing.
static func add_to(
	target: Control,
	behavior: MouseBehavior = MouseBehavior.IGNORE
) -> RedGlowPanel:
	var surface := RedGlowPanel.new()
	surface.name = "RedGlowPanel"
	surface.mouse_behavior = behavior
	surface.show_behind_parent = true
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	target.add_child(surface)
	target.move_child(surface, 0)
	return surface
