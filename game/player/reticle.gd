class_name Reticle
extends Control

## Crosshair drawn in code so it stays crisp at any resolution. The player feeds
## `set_spread()` from its speed, which opens the ticks while running.

@export var gap := 4.0
@export var spread_gap := 7.0
@export var tick_length := 7.0
@export var thickness := 2.0
## Red over black, matching the square gameplay plates without losing the
## reticle against either snow or space.
@export var ink := Color(0.937, 0.082, 0.122, 0.96)
@export var halo := Color(0.008, 0.008, 0.010, 0.82)

var _spread := 0.0


func set_spread(value: float) -> void:
	var next := clampf(value, 0.0, 1.0)
	if absf(next - _spread) < 0.005:
		return
	_spread = next
	queue_redraw()


func _draw() -> void:
	var centre := size * 0.5
	var inner := gap + _spread * spread_gap
	var outer := inner + tick_length
	for direction: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var from := centre + direction * inner
		var to := centre + direction * outer
		draw_line(from, to, halo, thickness + 2.0)
		draw_line(from, to, ink, thickness)
	draw_circle(centre, thickness * 0.9 + 1.0, halo)
	draw_circle(centre, thickness * 0.9, ink)
