class_name NightGroundGlow
extends Node3D

## Couples the terrain's animated night emission to a small local pool of real
## lights. Raster emission cannot illuminate another mesh, so these lights are
## the bounded approximation that lets the same patches tint characters, props,
## foliage and bosses without enabling whole-world realtime GI.

const SURFACE := preload("res://game/planet/planet_surface.tres")
const FLOW_DAY_SECONDS := 960.0
const GOLDEN_HUE := 0.61803398875
const REFERENCE_GLOW_ENERGY := 0.16

@export var planet: Planet
@export var cycle: CelestialCycle

@export_group("Cast light")
@export_range(1, 6) var light_limit := 4
@export var light_range := 68.0
@export var light_energy := 2.0
@export var light_height := 7.0
@export var light_ring_radius := 26.0
@export var refresh_interval := 0.2

@export_group("Night palette")
@export var palette_transition_seconds := 12.0

var _lights: Array[OmniLight3D] = []
var _targets: Array[Vector3] = []
var _target_energy := PackedFloat32Array()
var _target_colours: Array[Color] = []
var _since_refresh := INF
var _flow_time := 0.0
var _palette_night := -1
var _palette_from: Array[Color] = []
var _palette_to: Array[Color] = []
var _palette: Array[Color] = []
var _palette_elapsed := 0.0
var _palette_shift := 0.0
var _palette_shift_from := 0.0
var _palette_shift_to := 0.0


func _ready() -> void:
	if planet == null or planet.shape == null or cycle == null or cycle.sun == null:
		push_error("NightGroundGlow needs its planet and celestial cycle")
		set_process(false)
		return
	_create_lights()
	_set_palette(cycle.day_index(), true)
	_publish_shader_state()
	_refresh_targets()


func _process(delta: float) -> void:
	var night := cycle.day_index()
	if night != _palette_night:
		_set_palette(night, false)
	_update_palette(delta)
	# Phase plus the synchronized full-day count is continuous over the wrap and
	# gives joining peers the same moving field rather than a fresh local clock.
	_flow_time = (float(cycle.day_index()) + cycle.phase()) * FLOW_DAY_SECONDS
	_publish_shader_state()

	_since_refresh += delta
	if _since_refresh >= refresh_interval:
		_since_refresh = 0.0
		_refresh_targets()
	_follow_targets(delta)


## Three separated hues, rotated by the irrational golden-ratio step. The
## sequence does not settle into a short red/green/blue loop, while a given night
## index always returns the same palette on every peer.
static func palette_for_night(night: int) -> Array[Color]:
	var base := fposmod(0.37 + float(maxi(night, 0)) * GOLDEN_HUE, 1.0)
	return [
		Color.from_hsv(base, 0.78, 0.96),
		Color.from_hsv(fposmod(base + 0.19, 1.0), 0.72, 1.0),
		Color.from_hsv(fposmod(base + 0.47, 1.0), 0.68, 0.94),
	]


func active_lights() -> Array[OmniLight3D]:
	return _lights


## Finds a nearby representative glow lobe for visual tests and scripted views.
## Gameplay never teleports anything here; its four lights remain viewer-local.
func brightest_direction_near(
		centre: Vector3, reach := 520.0, step := 65.0,
		prefer_non_green := false) -> Vector3:
	var root := centre.normalized()
	var east := root.cross(
		Vector3.UP if absf(root.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := east.cross(root).normalized()
	var best := root
	var best_level := -1.0
	var cells := maxi(1, floori(reach / maxf(step, 1.0)))
	for x in range(-cells, cells + 1):
		for y in range(-cells, cells + 1):
			var offset := Vector2(float(x), float(y)) * step
			if offset.length() > reach:
				continue
			var direction := (root
				+ (east * offset.x + north * offset.y)
					/ maxf(planet.shape.radius, 1.0)).normalized()
			var sample := sample_direction(direction)
			var level := float(sample.get("cast", 0.0))
			if prefer_non_green:
				var colour: Color = sample.get("color", Color.WHITE)
				level *= 1.0 + maxf(
					maxf(colour.r, colour.b) - colour.g, 0.0)
			if level > best_level:
				best_level = level
				best = direction
	return best


## CPU twin of the shader field, used only for four low-rate pooled lights.
func sample_direction(direction: Vector3) -> Dictionary:
	var unit := direction.normalized()
	var elevation := planet.shape.elevation(unit, planet.finest_spacing())
	var point := planet.to_global(unit * (planet.shape.radius + elevation))
	var up := (point - planet.global_position).normalized()
	var field := _field(point)
	var night := 1.0 - _smoothstep(
		-0.16, 0.12, up.dot(cycle.sun.global_basis.z.normalized()))
	var land := 1.0 if elevation > 0.0 else 0.0
	var patch := float(field["patch"])
	return {
		"position": point,
		"up": up,
		"patch": patch,
		"night": night,
		"land": land,
		"cast": patch * night * night * land,
		"color": _palette_colour(float(field["colour"])),
	}


func _create_lights() -> void:
	for index in light_limit:
		var light := OmniLight3D.new()
		light.name = "NightGroundGlow%d" % index
		light.light_color = Color.WHITE
		light.light_energy = 0.0
		light.omni_range = light_range
		light.omni_attenuation = 1.25
		light.light_specular = 0.35
		light.shadow_enabled = false
		# Every visual layer except layer two, which Planet reserves for the
		# emitting terrain itself. Characters and world objects remain layer one.
		light.light_cull_mask = 0xFFFFD
		light.visible = false
		add_child(light, false, Node.INTERNAL_MODE_BACK)
		_lights.append(light)
		_targets.append(Vector3.INF)
		_target_energy.append(0.0)
		_target_colours.append(Color.WHITE)


func _refresh_targets() -> void:
	var eye := planet.to_global(planet.viewer_position())
	var local_eye := planet.to_local(eye)
	if local_eye.is_zero_approx():
		return
	var surface_energy := maxf(float(SURFACE.get_shader_parameter(
		&"night_ground_glow_energy")), 0.0)
	var emission_scale := clampf(
		surface_energy / REFERENCE_GLOW_ENERGY, 0.0, 2.0)
	var centre := local_eye.normalized()
	var east := centre.cross(
		Vector3.UP if absf(centre.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := east.cross(centre).normalized()
	for index in _lights.size():
		var offset := Vector2.ZERO
		if index > 0:
			var angle := TAU * float(index - 1) / float(maxi(_lights.size() - 1, 1))
			offset = Vector2(cos(angle), sin(angle)) * light_ring_radius
		var direction := (centre
			+ (east * offset.x + north * offset.y)
				/ maxf(planet.shape.radius, 1.0)).normalized()
		var sample := sample_direction(direction)
		var at: Vector3 = sample["position"]
		var up: Vector3 = sample["up"]
		_targets[index] = at + up * light_height
		_target_energy[index] = light_energy * emission_scale * _smoothstep(
			0.04, 0.72, float(sample["cast"]))
		# A small neutral component lets a red patch illuminate blue clothing
		# instead of multiplying it to black, while the dominant hue still reads
		# as light reflected from that terrain lobe.
		var sampled_colour: Color = sample["color"]
		_target_colours[index] = sampled_colour.lerp(Color.WHITE, 0.22)


func _follow_targets(delta: float) -> void:
	var position_blend := 1.0 - exp(-delta * 8.0)
	var colour_blend := 1.0 - exp(-delta * 5.0)
	# Keep a non-zero fade rate when the authored target is switched to zero;
	# multiplying only by light_energy would leave every live light frozen on.
	var energy_step := delta * maxf(light_energy, 1.0) * 2.8
	for index in _lights.size():
		var light := _lights[index]
		var target := _targets[index]
		if target.is_finite():
			if light.global_position.distance_to(target) > light_range * 2.0:
				light.global_position = target
			else:
				light.global_position = light.global_position.lerp(
					target, position_blend)
		light.light_color = light.light_color.lerp(
			_target_colours[index], colour_blend)
		light.light_energy = move_toward(
			light.light_energy, _target_energy[index], energy_step)
		light.visible = light.light_energy > 0.001


func _set_palette(night: int, immediate: bool) -> void:
	var target := palette_for_night(night)
	_palette_night = maxi(night, 0)
	_palette_to = target
	_palette_shift_from = _palette_shift
	_palette_shift_to = float(_palette_night) * 0.271828
	_palette_elapsed = 0.0
	if immediate or _palette.is_empty() or palette_transition_seconds <= 0.0:
		_palette = target.duplicate()
		_palette_from = target.duplicate()
		_palette_shift = _palette_shift_to
		_palette_elapsed = palette_transition_seconds
		_publish_palette()
		return
	_palette_from = _palette.duplicate()


func _update_palette(delta: float) -> void:
	if _palette_to.is_empty():
		return
	if palette_transition_seconds <= 0.0:
		if _palette != _palette_to:
			_palette = _palette_to.duplicate()
			_publish_palette()
		return
	if _palette_elapsed >= palette_transition_seconds:
		return
	_palette_elapsed = minf(
		_palette_elapsed + delta, palette_transition_seconds)
	var amount := _smoothstep(
		0.0, 1.0, _palette_elapsed / palette_transition_seconds)
	_palette.clear()
	for index in 3:
		_palette.append(_palette_from[index].lerp(_palette_to[index], amount))
	_palette_shift = lerpf(_palette_shift_from, _palette_shift_to, amount)
	_publish_palette()


func _publish_palette() -> void:
	if _palette.size() < 3:
		return
	SURFACE.set_shader_parameter(&"night_ground_glow_color_a", _palette[0])
	SURFACE.set_shader_parameter(&"night_ground_glow_color_b", _palette[1])
	SURFACE.set_shader_parameter(&"night_ground_glow_color_c", _palette[2])
	SURFACE.set_shader_parameter(&"night_ground_glow_palette_shift",
		fposmod(_palette_shift, 1.0))


func _publish_shader_state() -> void:
	SURFACE.set_shader_parameter(&"night_ground_glow_time", _flow_time)


func _field(world_position: Vector3) -> Dictionary:
	var scale := float(SURFACE.get_shader_parameter(
		&"night_ground_glow_scale"))
	var speed := float(SURFACE.get_shader_parameter(
		&"night_ground_glow_speed"))
	var flow := float(SURFACE.get_shader_parameter(
		&"night_ground_glow_flow"))
	var threshold := float(SURFACE.get_shader_parameter(
		&"night_ground_glow_threshold"))
	var softness := maxf(float(SURFACE.get_shader_parameter(
		&"night_ground_glow_softness")), 0.001)
	var point := _pattern_frame(world_position - planet.global_position) * scale
	var phase := _flow_time * speed
	var drift_a := Vector3(
		sin(phase * 0.73),
		cos(phase * 0.61),
		sin(phase * 0.47 + 1.7)) * 0.78
	var drift_b := Vector3(
		cos(phase * 0.53 + 2.4),
		sin(phase * 0.67 + 0.8),
		cos(phase * 0.41)) * 0.72
	var warp_a := _noise3(
		point * 0.48 + drift_a + Vector3(11.3, 29.1, 5.7))
	var turned := Vector3(point.z, point.x, point.y)
	var warp_b := _noise3(
		turned * 0.43 + drift_b + Vector3(37.2, 3.9, 17.6))
	var warp := Vector3(
		warp_a - 0.5,
		warp_b - 0.5,
		warp_a - warp_b) * flow
	var body := _noise3(point + warp + drift_a * 0.24)
	var companion_point := Vector3(point.y, point.z, point.x) * 0.64
	var turned_warp := Vector3(warp.z, warp.x, warp.y)
	var companion := _noise3(
		companion_point - turned_warp * 0.38 - drift_b * 0.21
			+ Vector3(23.4, 7.1, 41.8))
	var value := lerpf(body, companion, 0.28)
	var patch := _smoothstep(
		threshold - softness, threshold + softness, value)
	return {
		"patch": patch,
		"colour": fposmod(
			warp_a * 0.58 + warp_b * 0.42 + _palette_shift, 1.0),
	}


func _palette_colour(selector: float) -> Color:
	if _palette.size() < 3:
		return Color.WHITE
	var band := fposmod(selector, 1.0) * 3.0
	var blend := _smoothstep(0.08, 0.92, fposmod(band, 1.0))
	var first := floori(band) % 3
	var second := (first + 1) % 3
	return _palette[first].lerp(_palette[second], blend)


static func _pattern_frame(point: Vector3) -> Vector3:
	return Vector3(
		point.dot(Vector3(0.8138, 0.3420, 0.4698)),
		point.dot(Vector3(-0.5127, 0.8397, 0.1830)),
		point.dot(Vector3(-0.3319, -0.3899, 0.8591)))


static func _noise3(point: Vector3) -> float:
	var cell := Vector3(floorf(point.x), floorf(point.y), floorf(point.z))
	var fraction := Vector3(
		_fract(point.x), _fract(point.y), _fract(point.z))
	fraction = Vector3(
		_quintic(fraction.x), _quintic(fraction.y), _quintic(fraction.z))
	var n000 := _hash13(cell)
	var n100 := _hash13(cell + Vector3(1.0, 0.0, 0.0))
	var n010 := _hash13(cell + Vector3(0.0, 1.0, 0.0))
	var n110 := _hash13(cell + Vector3(1.0, 1.0, 0.0))
	var n001 := _hash13(cell + Vector3(0.0, 0.0, 1.0))
	var n101 := _hash13(cell + Vector3(1.0, 0.0, 1.0))
	var n011 := _hash13(cell + Vector3(0.0, 1.0, 1.0))
	var n111 := _hash13(cell + Vector3(1.0, 1.0, 1.0))
	return lerpf(
		lerpf(lerpf(n000, n100, fraction.x),
			lerpf(n010, n110, fraction.x), fraction.y),
		lerpf(lerpf(n001, n101, fraction.x),
			lerpf(n011, n111, fraction.x), fraction.y),
		fraction.z)


static func _hash13(point: Vector3) -> float:
	var value := Vector3(
		_fract(point.x * 0.1031),
		_fract(point.y * 0.1031),
		_fract(point.z * 0.1031))
	var crossed := Vector3(value.z, value.y, value.x) + Vector3.ONE * 31.32
	value += Vector3.ONE * value.dot(crossed)
	return _fract((value.x + value.y) * value.z)


static func _quintic(value: float) -> float:
	return value * value * value * (
		value * (value * 6.0 - 15.0) + 10.0)


static func _fract(value: float) -> float:
	return value - floorf(value)


static func _smoothstep(low: float, high: float, value: float) -> float:
	var amount := clampf(
		(value - low) / maxf(high - low, 0.00001), 0.0, 1.0)
	return amount * amount * (3.0 - 2.0 * amount)
