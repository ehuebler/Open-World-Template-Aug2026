class_name LaserBeams
extends Node3D

## The two beams a player's eyes are firing, and the burn where they land.
##
## Kept apart from [LaserEyes] because the ability only exists on the machine
## whose player is firing, and everybody else has to see the beam too. This is
## the part both paths share: the local ability aims it every physics tick so it
## tracks the head smoothly, and the beam packet aims it on remote peers ten
## times a second. Either way it puts itself away shortly after the last aim it
## was given, so a player who disconnects mid-beam does not leave one hanging in
## the air.
##
## Unshaded and emissive, the same choice [LaserBolt] makes and for the same
## reason: everything else in this world is drawn in pencil, and light reads as
## light only if it is not shaded like the rest.

const COLOR := Color(1.0, 0.32, 0.22)
## What the middle of a beam is, as opposed to the glow around it. Nearly white:
## a laser is over-exposed at its centre, and a core in the same red as the glow
## reads as a plastic rod rather than as something too bright to look at.
const CORE_COLOR := Color(1.0, 0.74, 0.58)
## Half-width of the glow. Two beams at this size read as a pair from behind the
## player's shoulder, which is where the game is played from; thinner and they
## merge into one line by the time they converge.
const RADIUS := 0.1
## How much of that width the white centre takes. Small: the core is what says
## the beam is too bright to look at, and the red around it is what says the beam
## is red, so a core wide enough to see on its own is a beam that is white.
const CORE_SHARE := 0.3
## Seconds a beam stays up after the last aim. A shade over one damage tick at
## ten hertz, so a dropped packet thins the beam rather than blinking it.
const HOLD := 0.16

## Core then glow, for each eye.
var _beams: Array[MeshInstance3D] = []
var _lamp: OmniLight3D
var _alive := 0.0


func _ready() -> void:
	# Two passes over one line: an opaque core that reads against anything, and
	# an additive sheath around it that does not. Additive alone disappears
	# against bright ground, which is most of the ground there is.
	var core := _beam_mesh(RADIUS * CORE_SHARE,
		_material(CORE_COLOR, 4.0, false))
	var glow := _beam_mesh(RADIUS, _material(COLOR, 2.4, true))
	for eye in 2:
		_beams.append(_beam_node(core))
		_beams.append(_beam_node(glow))

	_lamp = OmniLight3D.new()
	_lamp.light_color = COLOR
	_lamp.light_energy = 3.4
	_lamp.omni_range = 5.5
	add_child(_lamp)

	# Beams are placed in world space, so they must not inherit the player's
	# rotation on top of the placement.
	top_level = true
	_hide()
	set_process(false)


## Draws both beams from the two eyes onto one point.
func aim(left_eye: Vector3, right_eye: Vector3, at: Vector3) -> void:
	if _beams.is_empty():
		return
	_place(_beams[0], left_eye, at)
	_place(_beams[1], left_eye, at)
	_place(_beams[2], right_eye, at)
	_place(_beams[3], right_eye, at)
	_lamp.global_position = at
	_lamp.visible = true
	_alive = HOLD
	set_process(true)


## Takes the beams down now, for the firing player letting go.
func stop() -> void:
	_alive = 0.0
	_hide()
	set_process(false)


func _process(delta: float) -> void:
	_alive -= delta
	if _alive > 0.0:
		return
	_hide()
	set_process(false)


## Stretches one beam between two points. A cylinder stands along its own +Y, so
## the placement is a basis whose Y runs down the beam and whose scale carries
## the length — which also means the beam does not get fatter as it gets longer.
func _place(beam: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var along := to - from
	var span := along.length()
	if span < 0.001:
		beam.visible = false
		return
	var up := along / span
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		beam.visible = false
		return
	side = side.normalized()
	beam.global_transform = Transform3D(
		Basis(side, up * span, side.cross(up)), from + along * 0.5)
	beam.visible = true


func _hide() -> void:
	for beam in _beams:
		beam.visible = false
	if _lamp != null:
		_lamp.visible = false


func _beam_mesh(radius: float, material: StandardMaterial3D) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	# Tapered towards the far end, which is the end that is converging on a
	# point: two beams that met at full width would meet as a blunt join.
	mesh.top_radius = radius * 0.55
	mesh.bottom_radius = radius
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 0
	mesh.material = material
	return mesh


func _beam_node(mesh: CylinderMesh) -> MeshInstance3D:
	var beam := MeshInstance3D.new()
	beam.mesh = mesh
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.visible = false
	add_child(beam)
	return beam


func _material(tint: Color, energy: float,
		additive: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = tint
	material.emission_enabled = true
	material.emission = tint
	material.emission_energy_multiplier = energy
	material.disable_receive_shadows = true
	if not additive:
		return material
	# Additive, so two beams crossing brighten rather than cutting a seam into
	# each other. Held back from full strength: added at full value onto ground
	# this bright the red saturates to white, which is the one colour a beam
	# whose whole job is to look like heat must not be.
	material.albedo_color = Color(tint, 0.72)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return material
