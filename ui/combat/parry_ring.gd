class_name ParryRing
extends Control

## Cooldown / readiness ring used by [ParryIndicator].


func _draw() -> void:
	var share := clampf(float(get_meta(&"share", 1.0)), 0.0, 1.0)
	var color: Color = get_meta(&"color", Color.WHITE)
	var centre := size * 0.5
	var radius := minf(size.x, size.y) * 0.46
	draw_arc(centre, radius, 0.0, TAU, 24, Color(0.05, 0.06, 0.12, 0.55), 3.0, true)
	if share <= 0.001:
		return
	draw_arc(centre, radius, -PI * 0.5,
		-PI * 0.5 + TAU * share, 28, color, 3.0, true)
