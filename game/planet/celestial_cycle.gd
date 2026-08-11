class_name CelestialCycle
extends Node

## Orbits the light and the celestial sphere while the planet remains still.
##
## The orbit axis is [member PlanetShape.frost_axis], the centre of the north
## polar cloud circle. The sun is constrained to the plane perpendicular to that
## axis, so the terminator always passes through both poles: exactly half of the
## ice cap is day and half is night at every phase.

@export var planet: Planet
@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
## The place under the sun at phase zero. Its radial is projected onto the
## equatorial orbit plane, making this the brightest/noon point possible without
## giving the sun a declination that would light the polar cap unevenly.
@export var noon_anchor: SurfaceAnchor
@export var period_seconds := 960.0
## Zero updates the realtime sky and light smoothly every frame. A positive
## interval is retained for low-end overrides, but should not be used with an
## incremental Sky: restarting that multi-frame radiance bake on a timer creates
## a regular whole-frame hitch.
@export_range(0.0, 1.0, 0.01) var update_interval := 0.0
@export_range(-1.0, 1.0) var orbit_direction := 1.0
@export var day_ambient_energy := 0.38
@export var night_ambient_energy := 0.055

var _phase := 0.0
var _phase_anchor := 0.0
var _clock_anchor_msec := 0
var _until_update := 0.0
var _pole := Vector3.UP
var _noon_to_sun := Vector3.FORWARD


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if planet == null or planet.shape == null or sun == null:
		push_error("CelestialCycle needs its planet and directional sun")
		set_process(false)
		return
	_pole = (planet.global_basis * planet.shape.frost_axis).normalized()
	var noon := sun.global_basis.z.normalized()
	if noon_anchor != null:
		noon = (planet.global_basis * noon_anchor.direction.normalized()).normalized()
	noon -= _pole * noon.dot(_pole)
	if noon.is_zero_approx():
		noon = _pole.cross(Vector3.FORWARD
			if absf(_pole.z) < 0.9 else Vector3.RIGHT)
	_noon_to_sun = noon.normalized()
	_phase_anchor = _phase
	_clock_anchor_msec = Time.get_ticks_msec()
	_apply()


func _process(delta: float) -> void:
	if period_seconds <= 0.0:
		return
	# A monotonic clock makes the sixteen minutes literal real time and prevents
	# pause/process cadence from slowing or silently stopping the celestial orbit.
	var elapsed := float(Time.get_ticks_msec() - _clock_anchor_msec) / 1000.0
	_phase = fposmod(_phase_anchor + elapsed / period_seconds, 1.0)
	if update_interval <= 0.0:
		_apply()
		return
	_until_update -= delta
	if _until_update > 0.0:
		return
	_until_update = update_interval
	_apply()


func _apply() -> void:
	var angle := _phase * TAU * orbit_direction
	var to_sun := (Basis(_pole, angle) * _noon_to_sun).normalized()
	# A DirectionalLight3D shines down -Z; +Z is therefore the direction from the
	# planet toward the sun, the same convention vivid_space receives as
	# LIGHT0_DIRECTION.
	var right := _pole.cross(to_sun).normalized()
	if right.is_zero_approx():
		right = to_sun.cross(Vector3.RIGHT
			if absf(to_sun.x) < 0.9 else Vector3.FORWARD).normalized()
	var up := to_sun.cross(right).normalized()
	sun.global_transform = Transform3D(Basis(right, up, to_sun),
		sun.global_position)
	if world_environment != null and world_environment.environment != null \
			and noon_anchor != null:
		var landing_up := (
			planet.global_basis * noon_anchor.direction.normalized()).normalized()
		var landing_daylight := smoothstep(-0.12, 0.18, landing_up.dot(to_sun))
		world_environment.environment.ambient_light_energy = lerpf(
			night_ambient_energy, day_ambient_energy, landing_daylight)
	RenderingServer.global_shader_parameter_set(&"celestial_angle", angle)


## Normalized 0..1 position in the sixteen-minute day. Used only to synchronize
## a client when it joins; after that every peer advances by the same delta.
func phase() -> float:
	return _phase


func set_phase(value: float) -> void:
	_phase = fposmod(value, 1.0)
	_phase_anchor = _phase
	_clock_anchor_msec = Time.get_ticks_msec()
	_until_update = 0.0
	if is_inside_tree() and sun != null:
		_apply()
