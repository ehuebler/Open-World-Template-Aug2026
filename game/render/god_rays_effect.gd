@tool
class_name GodRaysEffect
extends CompositorEffect

## Shafts of sunlight through whatever the depth buffer says is in the way.
##
## Two passes. A compute shader marches the depth buffer radially toward the sun's
## place on screen and writes how much of each walk was sky into its own
## quarter-resolution image; a fullscreen raster pass then adds that image to the
## colour buffer, tinted by the sun. The arithmetic is in
## [code]shaders/post/god_rays.glsl[/code] and its composite twin, with the
## reasoning for each.
##
## Both halves are shaped by one fact about the renderer this game uses: the
## Mobile backend never sets [code]TEXTURE_USAGE_STORAGE_BIT[/code] on its render
## buffers, because that flag disables framebuffer compression and costs more on
## mobile hardware than the compute access is worth. So a compute shader here
## cannot write to the screen at all. It reads depth through a sampler, which is
## allowed, writes to a texture this effect allocates itself with the bit set, and
## the raster pass carries it the rest of the way. Switching the project to
## Forward+ would remove the second pass and cost the whole project the mobile
## renderer's framebuffer compression, which is a much larger bill than one
## fullscreen triangle.
##
## The callback is POST_TRANSPARENT rather than POST_OPAQUE, and that is also not
## a preference. At post-opaque the sky has not been drawn yet, and the sky is
## precisely where the shafts have to appear — the pass would be marching a depth
## buffer whose sky pixels were still whatever the last frame left there. Being
## before Godot's glow and tonemapping is the bonus: the shafts bloom with the
## rest of the frame instead of sitting flat on top of a finished image.
##
## Everything the effect needs to know about the sun arrives through
## [method set_sun], written from the main thread and read on the render thread
## under a mutex. Nothing in here touches the scene tree.

const RAY_SHADER_PATH := "res://shaders/post/god_rays.glsl"
const COMPOSITE_SHADER_PATH := "res://shaders/post/god_rays_composite.glsl"
## Linear divisor on each axis of the render size. Sixteen times fewer marches
## than a full-resolution pass, and the shafts lose nothing by it: they are broad
## soft wedges, and the bilinear upsample in the composite is smoother than the
## march's own steps were.
const RAY_DIVISOR := 4
## Local size of the compute shader's workgroup, which must match the
## [code]local_size_x/y[/code] declared in god_rays.glsl.
const RAY_GROUP := 8

## How bright the shafts are at their root, right at the sun, before the sun's own
## energy scales them. Everything further out is a fraction of this.
@export_range(0.0, 2.0, 0.01) var strength := 0.45
## Share of the distance to the sun each pixel's march covers. Close to one: the
## light all lives within [member halo] of the sun, and a march that stops short of
## that gathers nothing at all.
@export_range(0.1, 1.0, 0.01) var density := 0.96
## What each step of the march is worth relative to the previous one. Near one
## gives long even shafts; lower pulls them into a tight burst at the sun.
@export_range(0.8, 1.0, 0.001) var decay := 0.975
## Radius of the light around the sun, in screen heights. The number that decides
## whether this draws shafts or fog — see `halo` in god_rays.glsl.
@export_range(0.05, 1.0, 0.01) var halo := 0.3
## Distances, in metres, over which a pixel's own share of the shaft comes in. A
## surface nearer than the first has no air in front of it worth speaking of and
## receives nothing; past the second it receives all of it, as does the sky.
##
## Read by [CelestialCycle], which converts both to raw depths — and the ramp
## between them is walked in raw depth rather than in metres, which is not even.
## Depth is reciprocal in distance, so most of the fade happens in the first tens of
## metres and everything past a hundred or so is already receiving nearly all of it.
## That is the right shape here and the reason it is left alone: the point of the
## pair is to keep light off surfaces close enough to have no air in front of them,
## not to grade the middle distance.
@export var veil_near := 25.0
@export var veil_far := 400.0
## Distance from the sun on screen, in screen heights, past which no shafts are
## drawn at all. A bound on the work rather than a look.
@export_range(0.05, 2.0, 0.01) var reach := 1.3

var _mutex := Mutex.new()
var _sun_uv := Vector2.ZERO
var _sun_tint := Color(1.0, 0.94, 0.82)
var _sun_energy := 0.0
## [member veil_near] and [member veil_far] as raw depths, in that order.
var _veil := Vector2(1.0, 0.0)

var _rd: RenderingDevice
var _ray_spirv: RDShaderSPIRV
var _composite_spirv: RDShaderSPIRV
var _ray_shader := RID()
var _ray_pipeline := RID()
var _composite_shader := RID()
var _composite_pipeline := RID()
## Framebuffer format the composite pipeline was compiled against. A pipeline is
## only valid for one, and the format changes when the window is resized past a
## buffer reallocation or the render scale is moved.
var _composite_format := -1
var _rays_texture := RID()
var _rays_size := Vector2i.ZERO
var _depth_sampler := RID()
var _rays_sampler := RID()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# Asks Godot to resolve the MSAA depth buffer down to a plain one. The
	# project runs 2x MSAA by default and an unresolved multisampled depth
	# texture cannot be read through a sampler at all.
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		# Headless, or a driver with no RenderingDevice. Every callback below
		# returns immediately and the effect is inert rather than an error.
		return
	# Loaded here, on whichever thread built this resource, because the render
	# thread should not be reaching into the resource loader. Only the RID
	# creation is deferred onto it.
	var ray_file := load(RAY_SHADER_PATH) as RDShaderFile
	var composite_file := load(COMPOSITE_SHADER_PATH) as RDShaderFile
	if ray_file == null or composite_file == null:
		push_warning("God rays: shader files missing or not imported; effect disabled.")
		return
	_ray_spirv = ray_file.get_spirv()
	_composite_spirv = composite_file.get_spirv()
	RenderingServer.call_on_render_thread(_create_resources)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freed straight rather than through the render thread: by the time a
	# resource is being deleted there is no guarantee a later callback will run,
	# and RenderingDevice tolerates this the way Godot's own compositor examples
	# do it.
	for rid: RID in [_ray_pipeline, _composite_pipeline, _ray_shader,
			_composite_shader, _rays_texture, _depth_sampler, _rays_sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)


## The sun as the render thread needs it: where it is in 0..1 screen UVs, what
## colour its light is, and how much of the effect to apply — zero for behind the
## camera, below the horizon, or the setting being off, which skips the passes
## entirely rather than running them and multiplying by nothing.
##
## [param veil] carries [member veil_near] and [member veil_far] already converted
## to raw depth by the caller, which is where the camera's projection lives.
##
## Called from the main thread. [CelestialCycle] is the only caller.
func set_sun(uv: Vector2, tint: Color, energy: float, veil: Vector2) -> void:
	_mutex.lock()
	_sun_uv = uv
	_sun_tint = tint
	_sun_energy = energy
	_veil = veil
	_mutex.unlock()


func _create_resources() -> void:
	if _rd == null or _ray_spirv == null or _composite_spirv == null:
		return
	_ray_shader = _rd.shader_create_from_spirv(_ray_spirv)
	if _ray_shader.is_valid():
		_ray_pipeline = _rd.compute_pipeline_create(_ray_shader)
	_composite_shader = _rd.shader_create_from_spirv(_composite_spirv)

	# Nearest on depth. See god_rays.glsl for why interpolating an occlusion
	# test is wrong; clamping is so a march that walks off the screen finds the
	# border rather than wrapping to the far side of the frame.
	var depth_state := RDSamplerState.new()
	depth_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	depth_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_depth_sampler = _rd.sampler_create(depth_state)

	# Linear on the ray texture, which is what buys the quarter resolution.
	var rays_state := RDSamplerState.new()
	rays_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	rays_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	rays_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	rays_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_rays_sampler = _rd.sampler_create(rays_state)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	if not _ray_pipeline.is_valid() or not _composite_shader.is_valid():
		return

	_mutex.lock()
	var sun_uv := _sun_uv
	var tint := _sun_tint
	var energy := _sun_energy
	var veil := _veil
	_mutex.unlock()
	if energy <= 0.0:
		return

	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	# The internal size, not the viewport's. `graphics/render_scale` renders 3D
	# at a fraction of the window and the depth buffer is that size; sizing the
	# march off the logical viewport would dispatch past the end of it.
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var rays_size := Vector2i(maxi(size.x / RAY_DIVISOR, 1),
		maxi(size.y / RAY_DIVISOR, 1))
	if rays_size != _rays_size and not _resize_rays(rays_size):
		return

	var ray_push := PackedFloat32Array([
		float(rays_size.x), float(rays_size.y),
		sun_uv.x, sun_uv.y,
		density, decay, strength, reach,
		halo, float(size.x) / float(maxi(size.y, 1)), veil.x, veil.y,
	])
	var composite_push := PackedFloat32Array([
		tint.r, tint.g, tint.b, energy,
	])
	var groups_x := (rays_size.x - 1) / RAY_GROUP + 1
	var groups_y := (rays_size.y - 1) / RAY_GROUP + 1

	for view in buffers.get_view_count():
		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 0
		depth_uniform.add_id(_depth_sampler)
		depth_uniform.add_id(buffers.get_depth_layer(view))
		var image_uniform := RDUniform.new()
		image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image_uniform.binding = 1
		image_uniform.add_id(_rays_texture)
		var ray_set := UniformSetCacheRD.get_cache(_ray_shader, 0,
			[depth_uniform, image_uniform])

		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _ray_pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, ray_set, 0)
		_rd.compute_list_set_push_constant(compute_list,
			ray_push.to_byte_array(), ray_push.size() * 4)
		_rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
		_rd.compute_list_end()

		# The resolved colour layer, not the multisampled one. By
		# post-transparent Godot has already resolved MSAA into it and is itself
		# working from it, so this is both a legal colour attachment and the
		# buffer the rest of the pipeline will read. Passing the MSAA texture
		# here instead would add the shafts to a buffer nothing looks at again.
		#
		# Colour alone, with no depth attachment. The pass needs no depth test —
		# the occlusion was decided in the march — and the resolved depth texture
		# carries no attachment bit, so asking for it would fail to build a
		# framebuffer at all whenever MSAA is on.
		var framebuffer := FramebufferCacheRD.get_cache_multipass(
			[buffers.get_color_layer(view)], [], 1)
		if not framebuffer.is_valid():
			return
		if not _ensure_composite_pipeline(_rd.framebuffer_get_format(framebuffer)):
			return
		var rays_uniform := RDUniform.new()
		rays_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		rays_uniform.binding = 0
		rays_uniform.add_id(_rays_sampler)
		rays_uniform.add_id(_rays_texture)
		var composite_set := UniformSetCacheRD.get_cache(_composite_shader, 0,
			[rays_uniform])

		var draw_list := _rd.draw_list_begin(framebuffer)
		_rd.draw_list_bind_render_pipeline(draw_list, _composite_pipeline)
		_rd.draw_list_bind_uniform_set(draw_list, composite_set, 0)
		_rd.draw_list_set_push_constant(draw_list,
			composite_push.to_byte_array(), composite_push.size() * 4)
		# Three procedural vertices and no vertex buffer; the triangle is built
		# from gl_VertexIndex in the composite shader.
		_rd.draw_list_draw(draw_list, false, 1, 3)
		_rd.draw_list_end()


func _resize_rays(rays_size: Vector2i) -> bool:
	if _rays_texture.is_valid():
		_rd.free_rid(_rays_texture)
		_rays_texture = RID()
	_rays_size = Vector2i.ZERO
	# R16, one channel and half a float. The march produces a single coverage
	# number and the sun's colour is applied in the composite, so three channels
	# here would be the same value stored three times.
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = rays_size.x
	format.height = rays_size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.samples = RenderingDevice.TEXTURE_SAMPLES_1
	# The storage bit, which is the whole reason this texture exists rather than
	# the compute pass writing to the screen.
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_rays_texture = _rd.texture_create(format, RDTextureView.new(), [])
	if not _rays_texture.is_valid():
		return false
	_rays_size = rays_size
	return true


func _ensure_composite_pipeline(format: int) -> bool:
	if _composite_pipeline.is_valid() and _composite_format == format:
		return true
	if _composite_pipeline.is_valid():
		_rd.free_rid(_composite_pipeline)
		_composite_pipeline = RID()
	_composite_format = format

	var attachment := RDPipelineColorBlendStateAttachment.new()
	attachment.enable_blend = true
	attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	# Alpha is left exactly as it was found. The colour buffer's alpha is not
	# ours and adding to it makes transparent things behind the composite read
	# as solid.
	attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [attachment]

	# INVALID_FORMAT_ID for the vertex format is the documented way to say there
	# is no vertex data: the triangle comes out of the vertex index.
	_composite_pipeline = _rd.render_pipeline_create(_composite_shader, format,
		RenderingDevice.INVALID_FORMAT_ID,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(), blend)
	return _composite_pipeline.is_valid()
