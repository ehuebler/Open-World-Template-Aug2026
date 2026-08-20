class_name FaunaMatingHeart
extends Label3D

## One cheap, self-retiring courtship marker. It is a world-space label rather
## than a particle system so it has no shader warmup or per-species asset cost.

const LIFETIME := 1.8
const RISE := 1.15

var _elapsed := 0.0
var _up := Vector3.UP
var _origin := Vector3.ZERO


func _ready() -> void:
	name = &"MatingHeart"
	text = "♥"
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	font_size = 72
	outline_size = 12
	modulate = Color(1.0, 0.22, 0.48, 1.0)
	outline_modulate = Color(0.22, 0.015, 0.08, 0.92)
	no_depth_test = true
	add_to_group(&"fauna_mating_hearts")


func configure(at: Vector3, up: Vector3, body_height: float) -> void:
	_up = up.normalized() if up.length_squared() > 0.0001 else Vector3.UP
	_origin = at + _up * maxf(body_height * 0.72, 0.45)
	global_position = _origin
	pixel_size = clampf(body_height * 0.011, 0.006, 0.024)


func _process(delta: float) -> void:
	_elapsed += delta
	var share := clampf(_elapsed / LIFETIME, 0.0, 1.0)
	global_position = _origin + _up * (RISE * smoothstep(0.0, 1.0, share))
	var pulse := 1.0 + sin(share * PI * 5.0) * 0.12 * (1.0 - share)
	scale = Vector3.ONE * pulse
	var alpha := 1.0 - smoothstep(0.58, 1.0, share)
	modulate.a = alpha
	outline_modulate.a = alpha * 0.92
	if share >= 1.0:
		queue_free()
