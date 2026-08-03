class_name Snowfield
extends Node3D

## Everything the polar cap does that is not the shape of the ground: the snow
## falling through it, and the tracks left in it.
##
## Raised by [Planet] as an internal child at the planet's centre, the same way
## [PlanetWater] is, and for the same reason — both are one node standing in for
## something that covers a whole region, and both follow the viewer rather than
## existing everywhere at once. Where the arctic *is* is not decided here;
## [method PlanetShape.frost] owns that and this only asks.
##
## The snow is a single emitter that follows whoever is looking, throwing its
## particles into world space so they keep falling where they were emitted
## instead of being dragged along by the camera.
##
## **The flakes are sown through the whole column and not released from a slab at
## the top of it**, and that is the one thing here to keep. A slab is the obvious
## shape and it is only correct for a viewer standing still: the air around the
## eye is then filled by *transit*, and transit from eleven metres up takes four
## seconds, in which a walker covers more than the box is wide. So the fall was a
## snowfall while the player stood and a dozen stray flakes the moment they
## walked — measured at 2.6% of the frame against 0.5%, which is what
## `dev/_arctic_test.gd` now checks both of. Sown through the volume, the column
## around the eye is full the frame the box moves.
##
## What that costs is the density profile. A slab gives an even fall, because the
## flake count crossing any height is the whole of what was released above it; a
## volume gives a column that thickens downward, ramping up over the
## `FALL_SPEED * FLAKE_LIFE` metres a flake falls in its life and even below that.
## Hence a **short life and a tall box**: the ramp is spent in the air above
## `FALL_TOP - FALL_SPEED * FLAKE_LIFE`, and everything from there down to the
## ground — which is all of the fall anybody reads — is even.

## The column the flakes are sown through, in metres relative to the viewer's own
## eye, and how wide a patch of it is sown.
##
## The width is small on purpose, and the first pass at this had it at 34. What is
## seen is not the number of flakes but their number per cubic metre, and a box
## that size dilutes eleven hundred of them to nine to the thousand cubic metres —
## a snowfall nobody can find. Spending the same budget on a narrower box puts the
## flakes where they read, which is within about fifteen metres of the eye; past
## that a flake is under a pixel and pays nothing back.
##
## The base sits *below* the eye rather than at it. Level with the eye the whole
## fall is overhead, and the flakes that sell snow are the ones going past the
## camera. Below the ground they are hidden by it and cost a depth test each.
const FALL_TOP := 15.0
const FALL_BASE := -2.0
const FALL_SPREAD := 11.0
## Metres a second, which is roughly what snow actually does. It falls at a
## constant rate rather than accelerating because that is what terminal velocity
## looks like, and it saves the process material a gravity vector that would have
## to be rewritten every time the viewer walked round the curve.
const FALL_SPEED := 2.6
## Seconds a flake lasts, which with the fall speed is the 3.9 m it covers in that
## time. Short, and doing two jobs at once.
##
## It is the height of the uneven band above, and it is how long the box takes to
## refill — so `FALL_SPREAD / FLAKE_LIFE`, about 7 m/s, is the pace the fall keeps
## up with, and a walk is 4.6. A volume cannot be filled faster than the flakes
## are issued, so a wound-up run outpaces its own weather and the fall thins:
## measured at 92% of the standing density at a walk and 67% at 11 m/s. Anything
## much longer than this brings that speed down and puts the uneven band where it
## can be seen; anything much shorter and a flake's whole life is a blink of it
## crossing a couple of metres of air.
const FLAKE_LIFE := 1.5
## Share of a flake's life spent fading in, and the same again fading out. A flake
## sown in mid-air and taken away again in mid-air is what a short life costs, and
## within a couple of metres of the eye an abrupt one is plainly a flake blinking
## out. Nothing else here needs the process material's colour ramp.
const FLAKE_FADE := 0.22
## What reads on screen is flakes per cubic metre and pixels per flake, and both
## of the obvious numbers get them wrong. Twenty-four hundred flakes sounds like
## a blizzard and is nine hundredths of one per cube over a box 32 m wide; a
## seven-centimetre flake sounds generous and is under three pixels at fifteen
## metres. Together they measured at two hundredths of one per cent of the frame,
## which is four flakes. The box above is a third of the width it was and these
## are what fill it.
## Which leaves the other way to get it wrong. Sixteen centimetres filled the
## frame and did it as playing cards: a flake that passes a metre from the eye is
## a sixth of the screen at that size, and a hard-edged quad at that size is
## unmistakably a quad.
##
## Eleven centimetres rather than the seven a solid disc wanted, because an
## asterisk is mostly gaps: the arms cover about a fifth of the quad, so a star
## the size of a disc reads as a fifth of the disc and the same count comes back
## as a much lighter fall.
const FLAKES := 12000
const FLAKE_SIZE := 0.11
## Pixels per frame of the atlas. Thirty-two rather than sixteen because an arm
## two pixels wide has to have an inside as well as two edges, or the star comes
## out as a fuzzy blob with a suggestion of points.
const FLAKE_PIXELS := 32
## Arms per flake, one frame of the atlas each, picked per flake at random. Four
## shapes is enough that no two flakes near each other are obviously the same and
## few enough that the atlas stays one row.
const FLAKE_SPIKES: Array[int] = [5, 6, 7, 8]
## Half-width of an arm and how far it reaches, as shares of the quad's half
## width. The arms stop just short of the edge so the fade at the tip is inside
## the texture rather than cut off by it.
const ARM_HALF := 0.085
const ARM_REACH := 0.94
## The hub the arms come out of. Without it the centre is a knot of overlapping
## arm ends, which is darker on an odd count than an even one and makes the two
## read as different kinds of thing rather than as different flakes.
const ARM_HUB := 0.17

## Ceiling on the weather, in metres above sea level. Above this the player is
## inside or over the cloud deck and there is nothing overhead to fall out of it.
const SNOW_CEILING := 1500.0

## How many footprints stay on the ground. At [constant STRIDE] apart this is
## about fifty metres of trail behind each walker, after which the oldest print
## is picked up and put down again in front — a ring rather than a queue, so
## walking about for an hour costs exactly what walking about for a minute does.
const PRINTS := 72
## Metres between prints. Not measured from the animation: the walk clip is
## resampled by speed, so its cadence is not a distance, and a print every so
## many metres is the thing that actually stays put underfoot at any pace.
const STRIDE := 0.82
## How far to either side of the line of travel a print lands.
const STRADDLE := 0.14
## Footprint size on the ground, in metres, and how deep the decal box reaches.
## The box has to be deeper than the ground is uneven within one print or the
## projection clips off the back of a slope.
const PRINT_LENGTH := 0.42
const PRINT_WIDTH := 0.21
const PRINT_REACH := 0.7
## Prints are a dent, not a mark: what is seen is the shadow inside a hole in the
## snow, so this is dark rather than a colour. Nearly opaque, because the snow it
## has to show against is white in the sun and pale blue out of it, and the first
## pass at 0.62 read as a smudge in both.
const PRINT_TINT := Color(0.30, 0.36, 0.54, 0.88)
const SOLE_PIXELS := 48

## Read from [PlanetShape] rather than restated, so a cap moved in the shape
## moves the weather with it.
var shape: PlanetShape
## Where the detail is being drawn for, in planet-local space. Set by [Planet].
var viewer_source: Callable

var _snow: GPUParticles3D
var _prints: Array[Decal] = []
var _next_print := 0
var _sole: ImageTexture


func _ready() -> void:
	_snow = GPUParticles3D.new()
	_snow.name = "Snow"
	_snow.amount = FLAKES
	_snow.lifetime = FLAKE_LIFE
	# World space. A local emitter carries its live particles with it, so walking
	# would drag the whole snowfall along and the flakes would hang motionless
	# beside the player's head.
	_snow.local_coords = false
	_snow.process_material = _flake_process()
	_snow.draw_pass_1 = _flake_mesh()
	_snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The emitter's own bounds describe the box the flakes leave from, not the
	# volume they fall through, and world-space particles are not tracked by it
	# at all. Without a custom box the whole fall is culled the moment the box
	# above the camera leaves the frustum.
	var bound := FALL_SPREAD + (FALL_TOP - FALL_BASE)
	_snow.visibility_aabb = AABB(Vector3.ONE * -bound, Vector3.ONE * bound * 2.0)
	_snow.emitting = false
	add_child(_snow, false, Node.INTERNAL_MODE_BACK)
	_sole = _sole_texture()


func _process(_delta: float) -> void:
	if _snow == null or shape == null or not viewer_source.is_valid():
		return
	var eye: Vector3 = viewer_source.call()
	var span := eye.length()
	if span < 1.0:
		_snow.emitting = false
		return
	var up := eye / span
	# Snow falls where the cap is and only under the deck. Both are cheap, and
	# between them they mean the emitter is off for most of a game.
	var falling := shape.frost(up) > 0.05 and span - shape.radius < SNOW_CEILING
	# Written only when it changes. Assigning `emitting` goes straight through to
	# the server every time, and doing that once a frame leaves the buffer with
	# one frame's emission in it — four flakes, measured — rather than a whole
	# lifetime's worth.
	if falling != _snow.emitting:
		_snow.emitting = falling
	if not falling:
		return
	# Every frame, and there used to be a two-and-a-half-metre dead zone here on
	# the grounds that a write to a world-space emitter resets its emission and
	# reissues the live flakes where they started. It does not: the same walk
	# measured 0.5% of the frame with the dead zone and 0.7% without it, so the
	# write is worth what it costs and the dead zone was buying nothing but a box
	# lagging the eye by up to its own dead zone. What actually emptied the fall
	# for a walker is written at the top of this file.
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	_snow.transform = Transform3D(Basis(side, up, side.cross(up)),
		up * (span + (FALL_TOP + FALL_BASE) * 0.5))


## Puts a footprint on the ground at [param at], lying in the plane whose up is
## [param up] and pointing along [param facing]. [param left] picks which side of
## the line of travel it lands on.
##
## Callers own the cadence — see [method OnlinePlayer._track_footprints] — because
## what counts as a step is a property of the walker and not of the snow.
func stamp(at: Vector3, up: Vector3, facing: Vector3, left: bool) -> void:
	if _sole == null:
		return
	var side := facing.cross(up).normalized()
	if side.length_squared() < 0.5:
		return
	var print := _print()
	# Projected straight down onto the snow, and centred on it rather than
	# hovering over it. A decal fades toward the ends of its own box, so a print
	# parked near the top of a box that reaches down to the ground lands in its
	# own fade and comes out as a smudge — which is what these were until the
	# shot showed a trail of grey dots where there should have been boots.
	print.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		at + side * (STRADDLE if left else -STRADDLE))
	print.visible = true


## Whether snow is falling at a point, which is the same question as whether
## there is snow underfoot there. Asked by the player for the trudge.
func snowing(local_point: Vector3) -> bool:
	if shape == null:
		return false
	var span := local_point.length()
	return span > 1.0 and shape.frost(local_point / span) > 0.05


# --- Building ---------------------------------------------------------------

## The next print out of the ring, made on first use so a planet with no walkers
## on it never allocates seventy-two decals.
func _print() -> Decal:
	if _prints.size() < PRINTS:
		var fresh := Decal.new()
		fresh.texture_albedo = _sole
		fresh.size = Vector3(PRINT_WIDTH, PRINT_REACH, PRINT_LENGTH)
		fresh.modulate = PRINT_TINT
		# Fully the decal's colour where it is opaque, so the tint above is the
		# whole of what is seen rather than a wash over the snow's own white.
		fresh.albedo_mix = 1.0
		# A little fade at the top and bottom of the box, so a print on a slope
		# thins out instead of ending on the edge of its own projection. Only a
		# little: the box is 0.7 m for the unevenness within one boot, and most
		# of that height wants to be at full strength.
		fresh.upper_fade = 0.15
		fresh.lower_fade = 0.15
		fresh.visible = false
		add_child(fresh, false, Node.INTERNAL_MODE_BACK)
		_prints.append(fresh)
		return fresh
	var reused := _prints[_next_print]
	_next_print = (_next_print + 1) % PRINTS
	return reused


## A boot sole, drawn rather than authored. Two overlapping discs — a wide ball
## and a narrower heel — because a single ellipse reads as a paw print.
func _sole_texture() -> ImageTexture:
	var image := Image.create_empty(SOLE_PIXELS, SOLE_PIXELS, false, Image.FORMAT_RGBA8)
	for y in SOLE_PIXELS:
		for x in SOLE_PIXELS:
			var u := (float(x) + 0.5) / float(SOLE_PIXELS) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(SOLE_PIXELS) * 2.0 - 1.0
			var ball := Vector2(u / 0.68, (v + 0.30) / 0.52).length()
			var heel := Vector2(u / 0.50, (v - 0.44) / 0.36).length()
			var ink := 1.0 - smoothstep(0.74, 1.0, minf(ball, heel))
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, ink))
	return ImageTexture.create_from_image(image)


## The flakes: one row of asterisks, [constant FLAKE_SPIKES] arms apiece, which
## the material hands out at random one frame per flake.
##
## An asterisk is cheap to draw because the arms are all the same arm. Fold the
## pixel's bearing into one sector and the distance to the nearest arm is a
## single angle, whatever the count; the width of the arm on screen is then that
## angle's sine times the radius, which is the perpendicular distance to a line
## through the centre and is why an arm drawn this way is a strip of even width
## rather than a wedge.
##
## Mipmapped, and that matters more here than for a disc. Arms two pixels wide
## alias into a crawling glitter the moment a flake is far enough off to be a few
## pixels across, and there are a lot of far flakes. The mip chain averages the
## gaps in with the arms, so a distant flake fades toward a faint speck — which
## is what a distant snowflake does. Frames bleed into each other at the coarsest
## levels, where a flake is one pixel and they are all the same white.
func _flake_texture() -> ImageTexture:
	var frames := FLAKE_SPIKES.size()
	var image := Image.create_empty(FLAKE_PIXELS * frames, FLAKE_PIXELS, true,
		Image.FORMAT_RGBA8)
	for frame in frames:
		var sector := TAU / float(FLAKE_SPIKES[frame])
		for y in FLAKE_PIXELS:
			for x in FLAKE_PIXELS:
				var offset := Vector2(
					(float(x) + 0.5) / float(FLAKE_PIXELS) * 2.0 - 1.0,
					(float(y) + 0.5) / float(FLAKE_PIXELS) * 2.0 - 1.0)
				var reach := offset.length()
				# Bearing to the nearest arm. The half-sector shift is what makes
				# this a distance to an arm rather than to the gap between two.
				var turn := absf(fposmod(offset.angle() + sector * 0.5, sector)
					- sector * 0.5)
				var arm := (1.0 - smoothstep(ARM_HALF * 0.35, ARM_HALF,
						reach * sin(turn))) \
					* (1.0 - smoothstep(ARM_REACH * 0.7, ARM_REACH, reach))
				var hub := 1.0 - smoothstep(ARM_HUB * 0.3, ARM_HUB, reach)
				image.set_pixel(frame * FLAKE_PIXELS + x, y,
					Color(1.0, 1.0, 1.0, maxf(arm, hub)))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _flake_process() -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# The whole column, not a slab at the top of it. This is the line the file's
	# header is about, and the one that makes the fall survive a walk.
	process.emission_box_extents = Vector3(
		FALL_SPREAD, (FALL_TOP - FALL_BASE) * 0.5, FALL_SPREAD)
	# Emitted straight down the emitter's own -Y, which _process keeps pointed at
	# the planet. Gravity is left at zero: snow is at terminal velocity by the
	# time anyone sees it, and a constant rate saves rewriting a world-space
	# vector every time the viewer walks round the curve.
	process.direction = Vector3(0.0, -1.0, 0.0)
	# Wide, and doing a job. Turbulence is the obvious way to keep snow from
	# falling as a grid of parallel lines, and it is the wrong one here: its
	# influence is a blend *toward* the noise field's velocity, so even at the
	# 0.06 to 0.2 this had, it takes the fall out of the flakes and leaves a slab
	# of them hanging at head height. A wide spread and a wide velocity range
	# scatter the same way and cost nothing.
	process.spread = 18.0
	process.initial_velocity_min = FALL_SPEED * 0.5
	process.initial_velocity_max = FALL_SPEED * 1.5
	process.gravity = Vector3.ZERO
	process.scale_min = 0.5
	process.scale_max = 1.4
	# Which asterisk this flake is. The material lays the four out as animation
	# frames and the offset is the phase into them, so a random offset with no
	# speed is a frame picked once and held for the flake's life. Anything but
	# zero speed would riffle each flake through all four as it fell.
	process.anim_offset_min = 0.0
	process.anim_offset_max = 1.0
	process.anim_speed_min = 0.0
	process.anim_speed_max = 0.0
	# A star has an orientation and a disc does not, so this is new work rather
	# than a flourish: without it every flake on screen points the same way and
	# the fall reads as printed wallpaper. The spin is slow enough to be a tumble
	# rather than a propeller.
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -45.0
	process.angular_velocity_max = 45.0
	process.color_ramp = _fade_ramp()
	return process


## Alpha in and out over [constant FLAKE_FADE] of a flake's life. See there for
## why a flake needs it; the gradient is white throughout, so this is the alpha
## and nothing else.
func _fade_ramp() -> GradientTexture1D:
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, FLAKE_FADE, 1.0 - FLAKE_FADE, 1.0])
	fade.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0), Color.WHITE, Color.WHITE, Color(1.0, 1.0, 1.0, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	return ramp


func _flake_mesh() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * FLAKE_SIZE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.94, 0.97, 1.0)
	material.albedo_texture = _flake_texture()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Which is what carries the process material's fade: a particle's own colour
	# arrives as vertex colour and is dropped on the floor without this.
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	# Particle billboards carry their scale in the instance transform, and
	# without this the billboard rebuild throws it away and every flake is 1 m.
	material.billboard_keep_scale = true
	# The atlas of asterisks, one frame per arm count, addressed by the process
	# material's anim offset. Not looping: with the loop on, an offset past the
	# last frame wraps to the first and the frame stops being a choice of shape.
	material.particles_anim_h_frames = FLAKE_SPIKES.size()
	material.particles_anim_v_frames = 1
	material.particles_anim_loop = false
	material.disable_receive_shadows = true
	# After the sky. Transparent surfaces sort by render_priority before they
	# sort by distance, and the planet's shells claim 0, 1 and 2 — sea, cloud,
	# air — so a flake left at the default is painted over by a cloud deck
	# kilometres behind it. Correct as well as convenient: the flakes are always
	# the nearest transparent thing in the frame.
	material.render_priority = 3
	quad.material = material
	return quad
