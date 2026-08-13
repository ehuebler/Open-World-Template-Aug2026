class_name DodoIcon
extends Control

## Simple vector dodo-bird icon for Flightless status chips.


func _init() -> void:
	custom_minimum_size = Vector2(22.0, 22.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var edge := minf(size.x, size.y)
	if edge <= 2.0:
		return
	var origin := size * 0.5
	var unit := edge / 22.0
	var body := Color(0.78, 0.62, 0.34)
	var wing := Color(0.55, 0.42, 0.24)
	var beak := Color(0.95, 0.72, 0.18)
	draw_circle(origin + Vector2(-1.0, 1.0) * unit, 6.5 * unit, body)
	draw_colored_polygon(PackedVector2Array([
		origin + Vector2(-5.0, 0.0) * unit,
		origin + Vector2(-1.0, -4.0) * unit,
		origin + Vector2(2.0, 1.0) * unit,
	]), wing)
	draw_circle(origin + Vector2(4.0, -3.0) * unit, 3.2 * unit, body)
	draw_colored_polygon(PackedVector2Array([
		origin + Vector2(6.5, -3.0) * unit,
		origin + Vector2(10.0, -2.0) * unit,
		origin + Vector2(6.5, -0.5) * unit,
	]), beak)
	draw_circle(origin + Vector2(5.0, -4.0) * unit, 0.9 * unit, Color(0.08, 0.08, 0.12))
	draw_line(origin + Vector2(-1.0, 7.0) * unit,
		origin + Vector2(-2.0, 10.0) * unit, Color(0.35, 0.25, 0.15), 1.2 * unit)
	draw_line(origin + Vector2(2.0, 7.0) * unit,
		origin + Vector2(3.0, 10.0) * unit, Color(0.35, 0.25, 0.15), 1.2 * unit)
