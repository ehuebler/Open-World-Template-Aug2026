@tool
class_name PlanetWater
extends Node3D

## The planet's sea: everything below sea level is under it, and there is only
## one of it.
##
## Because [PlanetShape] measures elevation from sea level, the water is a sphere
## of exactly [member sea_level] metres and nothing has to be decided per lake.
## Oceans, the lakes the height field sinks below zero inland, and the lowland
## reaches of the rivers are all the same surface seen through different holes in
## the ground, and a swimmer's depth is one subtraction anywhere on the planet.
##
## Drawn as a single disc that follows the viewer and is bent onto the sphere by
## [code]vivid_water.gdshader[/code]. A mesh of the whole sea at a resolution that
## holds up from a beach would be millions of triangles, almost all of them over
## the horizon; this is nine thousand, always where they are being looked at. The
## disc is sized to the horizon, so it reaches exactly as far as the water can be
## seen from wherever the viewer is, from wading depth to orbit.
##
## The water has no collider on purpose. It is not a thing to bump into: flight
## goes through it, swimming happens inside it, and both ask [method depth_at],
## which is exact everywhere and costs nothing whether or not any ground has been
## built nearby.
##
## This node's origin must be the planet's centre. Every query here measures from
## it, and Planet places it there.

const SURFACE_MATERIAL := preload("res://game/planet/planet_water.tres")

## Rings and spokes of the disc. Rings are spaced by the square of their index, so
## the metre in front of the swimmer's face gets as many as the last kilometre
## before the horizon; the projection onto the sphere then compresses the outer
## ones in angle, which is where a uniform grid would have been wasting them.
const RINGS := 48
const SPOKES := 96

## Nearest the disc is ever sized, in metres. At sea level the horizon is 160 m
## away on an 8 km planet, and a disc that small shows its rim in the shallows.
const MIN_REACH := 320.0
## Widest angle from the viewer the disc is asked to cover. tan() runs away past
## this, and beyond about 150 km of altitude the missing sliver of ocean at the
## limb is thinner than the planet's own outline.
const HORIZON_LIMIT := 1.52
## How far past the eye's own depth a submerged disc is carried, as a multiple of
## the distance the surface takes to fall that far. At 2 the rim sits four depths
## under the swimmer, which is steeper than the line from a swimmer to the sea bed
## anywhere on this planet — so the rim is always behind ground, and the ground is
## always behind more water than can be seen through.
const UNDER_MARGIN := 2.0
## Where the sea sorts among the transparent shells, seen from outside it and from
## inside it. The first is written in `planet_water.tres`, next to the reason the
## three cannot be left to Godot's own sort; the second is above the air, which is
## the highest of them.
const SURFACE_PRIORITY := 0
const SUBMERGED_PRIORITY := 3

## Lifetime of a splash, and the speed a crossing needs before one is worth
## drawing. Wading in makes no splash.
const SPLASH_LIFETIME := 0.9
const SPLASH_DROPS := 14

## Radius of the surface, which is the radius the height field calls zero.
@export var sea_level := 8000.0

@export_group("Clarity")
## The light the water scatters back: the colour every view through more sea than
## can be seen through ends up as. Authored here in sRGB and published to the
## shaders converted, because they work in linear and a colour that crosses that
## line untold is a colour nobody can tune.
@export var murk_color := Color(0.06, 0.34, 0.42)
## How far can be seen along the water, in metres. Sight only — the light coming
## *down* the column is [member murk_daylight], and the two are far apart on
## purpose.
##
## Both of these are set against *this* sea and not against a real one, and the
## measurement that decides them is `_water_test`'s dive ladder. Its survey reports
## a bed averaging some two hundred metres down with two thirds of it past the
## shelf, so anything tuned to the clear-tropical-water figures — thirty metres of
## sight, sixty of light — puts every dive in the game beyond both on the way down
## and draws the whole sea floor as one flat panel of colour. These are what leave
## the ground still reading as ground over the depths a player actually swims,
## while a trench still goes to nothing.
@export_range(4.0, 400.0) var murk_visibility := 110.0
## What each channel of the light survives, as a multiple of the visibility. Red
## goes first and blue outlasts it, which is what leaves a shape readable in water
## too deep to show its colour. Green is 1 by convention.
@export var murk_channels := Vector3(0.4, 1.0, 1.7)
## Depth the daylight in the water falls off by, in metres.
@export_range(4.0, 400.0) var murk_daylight := 240.0

## Where the disc should centre itself, in this node's own space. Set by Planet,
## because finding a viewer in the editor as well as in the game is knowledge that
## already lives there and is not worth a second copy of.
var viewer_source: Callable

var _surface: MeshInstance3D
var _drop_mesh: QuadMesh


func _ready() -> void:
	_surface = MeshInstance3D.new()
	_surface.name = "Surface"
	_surface.mesh = _build_disc()
	_surface.material_override = SURFACE_MATERIAL
	_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The disc's own bounds describe a flat plate, and the shader then bends it
	# onto a sphere kilometres away from that. Without the margin it is culled
	# from exactly the views that are looking along it.
	_surface.extra_cull_margin = 16384.0
	add_child(_surface, false, Node.INTERNAL_MODE_BACK)
	publish_clarity()
	_place()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		publish_clarity()
	_place()


## Hands the sea's clarity to every shader that looks through it: the bed, the
## surface, the sky and the weather. They read it as global shader parameters
## because they meet at a swimmer's horizon and a copy each would draw that horizon
## at four different distances.
func publish_clarity() -> void:
	var linear := murk_color.srgb_to_linear()
	RenderingServer.global_shader_parameter_set(&"murk_color",
		Vector3(linear.r, linear.g, linear.b))
	RenderingServer.global_shader_parameter_set(&"murk_visibility", murk_visibility)
	RenderingServer.global_shader_parameter_set(&"murk_channels", murk_channels)
	RenderingServer.global_shader_parameter_set(&"murk_daylight", murk_daylight)


# --- Queries ----------------------------------------------------------------

## Metres of water above a point: positive under the surface, negative above it.
func depth_at(global_point: Vector3) -> float:
	return sea_level - global_position.distance_to(global_point)


## Which way is up out of the water at a point.
func up_at(global_point: Vector3) -> Vector3:
	var offset := global_point - global_position
	return offset.normalized() if offset.length_squared() > 0.0 else Vector3.UP


## The point on the surface directly above or below a point.
func surface_above(global_point: Vector3) -> Vector3:
	return global_position + up_at(global_point) * sea_level


# --- Splashes ---------------------------------------------------------------

## A burst of droplets where something crossed the surface. [param strength] is
## the speed it crossed at, in m/s; it decides how many drops there are and how
## far they are thrown.
func splash(at: Vector3, strength: float) -> void:
	var up := up_at(at)
	var burst := GPUParticles3D.new()
	burst.process_material = _drop_process(up, strength)
	burst.draw_pass_1 = _drops()
	burst.amount = clampi(SPLASH_DROPS + int(strength), SPLASH_DROPS, 90)
	burst.lifetime = SPLASH_LIFETIME
	burst.one_shot = true
	# The whole burst leaves at once. Without this the drops trickle out over the
	# lifetime and the splash reads as a fountain that was already running.
	burst.explosiveness = 1.0
	burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Parented to the water rather than to whatever made it, so a splash stays on
	# the sea instead of following the swimmer down.
	add_child(burst, false, Node.INTERNAL_MODE_BACK)
	burst.global_position = at
	burst.finished.connect(burst.queue_free)


func _drop_process(up: Vector3, strength: float) -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	process.emission_sphere_radius = 0.4
	# A full sphere of directions. Which space a process material reads its
	# `direction` in is not worth depending on, and a splash thrown every way at
	# once and pulled back by gravity is the shape either reading would give.
	process.spread = 180.0
	process.initial_velocity_min = 1.5 + strength * 0.16
	process.initial_velocity_max = 3.0 + strength * 0.4
	# Gravity is world space, which on a sphere means it has to be worked out per
	# splash: there is no one down.
	process.gravity = -up * float(ProjectSettings.get_setting("physics/3d/default_gravity", 24.0))
	process.damping_min = 0.4
	process.damping_max = 1.6
	process.scale_min = 0.05
	process.scale_max = 0.16
	return process


## The droplet, built once and shared by every burst.
func _drops() -> QuadMesh:
	if _drop_mesh != null:
		return _drop_mesh
	_drop_mesh = QuadMesh.new()
	_drop_mesh.size = Vector2.ONE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.78, 0.92, 1.0)
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	# Particle billboards carry their scale in the instance transform, and
	# without this the billboard rebuild throws it away and every drop is 1 m.
	material.billboard_keep_scale = true
	material.disable_receive_shadows = true
	_drop_mesh.material = material
	return _drop_mesh


# --- Following the viewer ---------------------------------------------------

func _place() -> void:
	if _surface == null:
		return
	var eye := _viewer_point()
	var out := eye.normalized() if eye.length_squared() > 1.0 else Vector3.UP
	var reach := _reach(eye.length() - sea_level)
	# Tangent frame with Y along the radius, so the disc lies flat on the water
	# under the viewer before the shader bends it round.
	var side := out.cross(Vector3.UP if absf(out.y) < 0.9 else Vector3.RIGHT).normalized()
	var frame := Basis(side, out, side.cross(out)).scaled(Vector3.ONE * reach)
	_surface.transform = Transform3D(frame, out * sea_level)
	# The three transparent shells are ordered sea, clouds, air — bottom to top,
	# which is the order they are in from outside the water and the reverse of the
	# order they are in from inside it. Under the surface the sea is the nearest of
	# the three and has to be drawn over both, or the weather is painted across it
	# at full brightness and a swimmer forty metres down is looking at clouds.
	#
	# Left alone in the editor: this writes to a shared resource, and a resource
	# the editor thinks has been edited is one it will offer to save.
	if not Engine.is_editor_hint():
		var paint: ShaderMaterial = SURFACE_MATERIAL
		paint.render_priority = SUBMERGED_PRIORITY if eye.length() < sea_level \
			else SURFACE_PRIORITY


## How wide the disc has to be to reach the horizon. The horizon is the edge of
## the cap the viewer can see, and the disc is a tangent plane, so the radius that
## covers it is the tangent of that cap's angle — a few hundred metres from a
## beach and tens of kilometres from orbit, which is the whole reason this is not
## a fixed-size patch.
##
## Under water it is a different question with a different answer, and asking the
## above-water one there was what made a deep dive look broken. From outside, the
## sea is a cap in front of the eye and it ends at a horizon. From inside, it is a
## shell *around* the eye: it covers every direction, including straight out and
## below, because the surface a swimmer is under curves down past their own depth
## and keeps going. A disc clamped to [constant MIN_REACH] covers a cone about the
## zenith and nothing else — from 40 m down that cone stops 8° above the horizon,
## and in the band under it there is no sea drawn at all. What was in that band was
## unfogged sky, with the disc's own outer rings picked out against it.
##
## So from below the reach is the distance at which the surface passes the eye's
## own depth, times a margin that carries the rim well under the bed's silhouette,
## where the murk and the ground have it covered. It grows as the root of the
## depth: 740 m at wading depth, 3.5 km at the bottom of the deepest trench here.
func _reach(altitude: float) -> float:
	if altitude < 0.0:
		return maxf(sqrt(2.0 * sea_level * -altitude) * UNDER_MARGIN, MIN_REACH)
	var cap := acos(clampf(sea_level / (sea_level + altitude), -1.0, 1.0))
	return maxf(sea_level * tan(minf(cap * 1.06, HORIZON_LIMIT)), MIN_REACH)


func _viewer_point() -> Vector3:
	if viewer_source.is_valid():
		return viewer_source.call() as Vector3
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	return to_local(camera.global_position) if camera != null else Vector3.UP * sea_level


# --- The disc ---------------------------------------------------------------

## A unit disc of concentric rings, centre first. Built flat in XZ; the shader is
## what puts it on the planet.
func _build_disc() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	vertices.append(Vector3.ZERO)
	normals.append(Vector3.UP)
	uvs.append(Vector2(0.5, 0.5))
	for ring in range(1, RINGS + 1):
		var share := float(ring) / float(RINGS)
		var radius := share * share
		for spoke in SPOKES:
			var angle := TAU * float(spoke) / float(SPOKES)
			vertices.append(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
			normals.append(Vector3.UP)
			uvs.append(Vector2(share, float(spoke) / float(SPOKES)))

	var indices := PackedInt32Array()
	for spoke in SPOKES:
		indices.append(0)
		indices.append(1 + (spoke + 1) % SPOKES)
		indices.append(1 + spoke)
	for ring in RINGS - 1:
		var inner := 1 + ring * SPOKES
		var outer := inner + SPOKES
		for spoke in SPOKES:
			var next := (spoke + 1) % SPOKES
			indices.append(inner + spoke)
			indices.append(inner + next)
			indices.append(outer + spoke)
			indices.append(inner + next)
			indices.append(outer + next)
			indices.append(outer + spoke)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
