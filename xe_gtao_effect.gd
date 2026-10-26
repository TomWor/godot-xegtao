@tool
## Intel's XeGTAO ground-truth ambient occlusion
## (https://github.com/GameTechDev/XeGTAO, MIT licence) as a compositor
## effect for the Forward+ renderer. Add it to the Compositor of a
## WorldEnvironment or Camera3D.
##
## In MATERIALS mode it runs after the depth prepass and writes its result to
## the global shader texture `xe_gtao_texture` (registered by the plugin),
## which shaders read with xe_gtao.gdshaderinc and feed into AO, so it only
## darkens ambient light. Each view writes there right before its own opaque
## pass, so split-screen and picture-in-picture views each get their own
## occlusion. In MULTIPLY mode it darkens the rendered image after
## transparents instead, which works with any material, StandardMaterial3D
## included. Renderers without compositor effects leave the texture white.
class_name XeGTAOEffect
extends CompositorEffect

enum ApplyMode { MATERIALS, MULTIPLY }
enum Quality { LOW, MEDIUM, HIGH, ULTRA }

const CONTEXT := &"xe_gtao"
const DEPTH_MIP_LEVELS := 5
## Slices and steps per slice for each quality level (XeGTAO's presets).
const QUALITY_PRESETS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 3), Vector2i(9, 3)]
const SHADERS := ["prefilter_depths", "depth_mip", "main", "denoise", "apply"]
const GLOBAL_TEXTURE := &"xe_gtao_texture"

## How the occlusion reaches the image; see the class description.
@export var apply_mode := ApplyMode.MATERIALS:
	set(value):
		apply_mode = value
		_configure_callback()
## Strength of the occlusion. At 0 the effect skips its passes, and in
## MATERIALS mode only clears the shared texture, so its views draw without
## occlusion; use that for cameras that shouldn't show any.
@export_range(0.0, 1.0) var intensity := 1.0
@export var quality: Quality = Quality.HIGH
## Occlusion radius in world units.
@export var radius := 4.0
## Share of the radius over which occluders fade out.
@export_range(0.0, 1.0) var falloff_range := 0.615
@export var radius_multiplier := 1.457
## Higher values concentrate samples near the centre.
@export var sample_distribution_power := 2.0
@export_range(0.0, 0.7) var thin_occluder_compensation := 0.0
## Applied to the final visibility; higher is darker.
@export var final_value_power := 2.2
@export var depth_mip_sampling_offset := 3.3
## 0 = off, 1 = sharp, 2 = medium, 3 = soft.
@export_range(0, 3) var denoise_passes := 2
## Varies the sample pattern every frame; only useful with TAA.
@export var temporal_noise := false

## Render-thread textures of the last view rendered, for debugging.
var debug_textures: Dictionary = {}

var _rd: RenderingDevice
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _sampler: RID

# A material binds one texture for every view, so all views and all effects
# share the one the materials read. Each view writes its result to its
# top-left corner right before its own opaque pass, and RenderingDevice
# orders that write after the previous view's reads, so every view's
# materials read their own result. Render thread only, apart from _white.
static var _instances := 0
## Written by the views; sized for the largest view so far.
static var _shared := RID()
static var _shared_size := Vector2i.ZERO
## Read by the materials; behind _shared for a frame after it grows.
static var _published := RID()
static var _publish_queued := false
## Whether a view wrote to _published since it was last cleared.
static var _dirty := false
## Wraps _published for the materials.
static var _texture: Texture2DRD
## The global's default, for when no effect is left.
static var _white: Texture2D


func _init() -> void:
	access_resolved_depth = true
	needs_normal_roughness = true
	_configure_callback()
	if _white == null:
		_white = load(get_script().resource_path.get_base_dir().path_join("white.png"))
	if not RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
	RenderingServer.call_on_render_thread(_initialize_compute)


## Turns the effect on or off at runtime; the same as setting `enabled`.
func set_active(active: bool) -> void:
	enabled = active


func _configure_callback() -> void:
	if apply_mode == ApplyMode.MATERIALS:
		effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
		access_resolved_color = false
	else:
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		access_resolved_color = true


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing a shader also frees its pipeline.
	var rids: Array = _shaders.values()
	rids.append(_sampler)
	RenderingServer.call_on_render_thread(_release.bind(rids))


func _initialize_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	_instances += 1
	var shader_dir: String = get_script().resource_path.get_base_dir().path_join("shaders")
	for shader_name: String in SHADERS:
		var file := load(shader_dir.path_join("xe_gtao_%s.glsl" % shader_name)) as RDShaderFile
		var spirv := file.get_spirv()
		if not spirv.compile_error_compute.is_empty():
			push_error("XeGTAO %s: %s" % [shader_name, spirv.compile_error_compute])
			_pipelines.clear()
			return
		var shader := _rd.shader_create_from_spirv(spirv)
		_shaders[shader_name] = shader
		_pipelines[shader_name] = _rd.compute_pipeline_create(shader)

	# Depth must be point sampled: interpolation would distort the slopes.
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or _pipelines.is_empty() or callback_type != effect_callback_type:
		return
	if intensity <= 0.0:
		# Keeps this view's materials from reading an earlier view's result.
		if apply_mode == ApplyMode.MATERIALS:
			_clear_published()
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size := buffers.get_internal_size()
	# The prepass normals only exist in Forward+.
	if size.x < 2 or size.y < 2 or not buffers.has_texture(&"forward_clustered", &"normal_roughness"):
		return
	_ensure_textures(buffers, size)
	if apply_mode == ApplyMode.MATERIALS:
		_ensure_shared(size)

	var projection := scene_data.get_cam_projection()
	# The renderer's projection may flip Y (and be reverse-Z); the buffers' row
	# 0 is always the top of the view, so only the magnitudes matter here.
	var tan_half_fov := Vector2(1.0 / absf(projection.x.x), 1.0 / absf(projection.y.y))
	var pixel_size := Vector2(1.0 / size.x, 1.0 / size.y)
	var ndc_to_view_mul := Vector2(tan_half_fov.x * 2.0, tan_half_fov.y * -2.0)
	var ndc_to_view_add := Vector2(-tan_half_fov.x, tan_half_fov.y)
	var preset := QUALITY_PRESETS[quality]

	var depth_texture := buffers.get_depth_layer(0, false)
	var normal_texture := buffers.get_texture(&"forward_clustered", &"normal_roughness")
	var view_depth := buffers.get_texture(CONTEXT, &"depth")
	var ao := buffers.get_texture(CONTEXT, &"ao")
	var ao_pong := buffers.get_texture(CONTEXT, &"ao_pong")
	var edges := buffers.get_texture(CONTEXT, &"edges")

	# Linear view-space depth and its MIP chain.
	var scene_buffer := scene_data.get_uniform_buffer()
	_dispatch("prefilter_depths", [_sampled(0, depth_texture), _image(1, buffers.get_texture_slice(CONTEXT, &"depth", 0, 0, 1, 1)), _uniform_buffer(2, scene_buffer)],
			_push([size.x, size.y, 0.0, 0.0]), size)
	for mip in range(1, DEPTH_MIP_LEVELS):
		var mip_size := buffers.get_texture_slice_size(CONTEXT, &"depth", mip)
		var source_size := buffers.get_texture_slice_size(CONTEXT, &"depth", mip - 1)
		_dispatch("depth_mip", [
			_image(0, buffers.get_texture_slice(CONTEXT, &"depth", 0, mip - 1, 1, 1)),
			_image(1, buffers.get_texture_slice(CONTEXT, &"depth", 0, mip, 1, 1)),
		], _push([mip_size.x, mip_size.y, source_size.x, source_size.y, radius, falloff_range, radius_multiplier, 0.0]), mip_size)

	_dispatch("main", [_sampled(0, view_depth), _sampled(1, normal_texture), _image(2, ao), _image(3, edges)], _push([
		size.x, size.y, pixel_size.x, pixel_size.y,
		ndc_to_view_mul.x, ndc_to_view_mul.y, ndc_to_view_add.x, ndc_to_view_add.y,
		ndc_to_view_mul.x * pixel_size.x, ndc_to_view_mul.y * pixel_size.y,
		radius, falloff_range, radius_multiplier, final_value_power,
		sample_distribution_power, thin_occluder_compensation, depth_mip_sampling_offset,
		float(preset.x), float(preset.y), Engine.get_frames_drawn() % 64 if temporal_noise else 0,
	]), size)

	# Ping-pong between the working textures; in MATERIALS mode the last pass
	# writes the shared texture. Without denoising, one pass with a huge centre
	# weight just rescales.
	var passes := maxi(1, denoise_passes)
	var blur_beta := 1.2 if denoise_passes > 0 else 1e4
	var source := ao
	var target := ao_pong
	for i in passes:
		var final_pass := i == passes - 1
		if final_pass and apply_mode == ApplyMode.MATERIALS:
			target = _shared
		_dispatch("denoise", [_sampled(0, source), _sampled(1, edges), _image(2, target)],
				_push([size.x, size.y, blur_beta, 1 if final_pass else 0, intensity, 0.0, 0.0, 0.0]), size)
		var swap := source
		source = target
		target = swap

	if apply_mode == ApplyMode.MULTIPLY:
		_dispatch("apply", [_image(0, buffers.get_color_layer(0, false)), _sampled(1, source), _sampled(2, view_depth), _uniform_buffer(3, scene_buffer)],
				_push([size.x, size.y, 0.0, 0.0]), size)
	elif _shared == _published:
		_dirty = true

	debug_textures = {&"depth": view_depth, &"ao": ao, &"edges": edges, &"output": source}


func _ensure_textures(buffers: RenderSceneBuffersRD, size: Vector2i) -> void:
	if buffers.has_texture(CONTEXT, &"depth") and buffers.get_texture_slice_size(CONTEXT, &"depth", 0) == size:
		return
	buffers.clear_context(CONTEXT)
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	buffers.create_texture(CONTEXT, &"depth", RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, DEPTH_MIP_LEVELS, true, false)
	for texture_name: StringName in [&"ao", &"ao_pong", &"edges"]:
		buffers.create_texture(CONTEXT, texture_name, RenderingDevice.DATA_FORMAT_R8_UNORM, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)


## Grows the shared texture to fit a view. Until the new one is published
## between frames, the materials read the old one, cleared.
static func _ensure_shared(size: Vector2i) -> void:
	if _shared.is_valid() and size.x <= _shared_size.x and size.y <= _shared_size.y:
		return
	var rd := RenderingServer.get_rendering_device()
	if _shared != _published:
		# Never published, so nothing reads it.
		rd.free_rid(_shared)
	_shared_size = size.max(_shared_size)
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	format.width = _shared_size.x
	format.height = _shared_size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	_shared = rd.texture_create(format, RDTextureView.new())
	rd.texture_clear(_shared, Color.WHITE, 0, 1, 0, 1)
	if _published.is_valid():
		# The views left this frame would read an earlier view's result.
		rd.texture_clear(_published, Color.WHITE, 0, 1, 0, 1)
	if not _publish_queued:
		_publish_queued = true
		_queue_publish.call_deferred()


## Main thread: publishing has to wait for the render thread to be between frames.
static func _queue_publish() -> void:
	RenderingServer.call_on_render_thread(_publish)


## Render thread, between frames: points the materials at the grown texture.
static func _publish() -> void:
	_publish_queued = false
	if _shared == _published:
		return
	# The rendering server only lists globals in the editor; the setting exists everywhere.
	if not ProjectSettings.has_setting("shader_globals/" + GLOBAL_TEXTURE):
		push_warning("XeGTAO: the shader global `xe_gtao_texture` is missing; enable the XeGTAO plugin.")
		return
	if _texture == null:
		_texture = Texture2DRD.new()
	# Replaces the texture under the materials, which frees their view of the old one.
	_texture.texture_rd_rid = _shared
	RenderingServer.global_shader_parameter_set(GLOBAL_TEXTURE, _texture)
	if _published.is_valid():
		RenderingServer.get_rendering_device().free_rid(_published)
	_published = _shared
	# It holds the last view's result.
	_dirty = true


## Main thread, before each frame: reflection probes, which render first, and
## views without the effect mustn't pick up the previous frame's last view.
static func _on_frame_pre_draw() -> void:
	RenderingServer.call_on_render_thread(_clear_published)


## Render thread: whitens the texture the materials read, unless it's clean.
static func _clear_published() -> void:
	if _dirty:
		RenderingServer.get_rendering_device().texture_clear(_published, Color.WHITE, 0, 1, 0, 1)
		_dirty = false


## Render thread: frees an effect's resources, and the shared texture with
## the last effect.
static func _release(rids: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	for rid: RID in rids:
		if rid.is_valid():
			rd.free_rid(rid)
	_instances -= 1
	if _instances > 0:
		return
	if _texture != null:
		# Hand the materials the default before freeing what they read.
		if ProjectSettings.has_setting("shader_globals/" + GLOBAL_TEXTURE):
			RenderingServer.global_shader_parameter_set(GLOBAL_TEXTURE, _white)
		_texture = null
	if _shared != _published:
		rd.free_rid(_shared)
	if _published.is_valid():
		rd.free_rid(_published)
	_shared = RID()
	_shared_size = Vector2i.ZERO
	_published = RID()
	_dirty = false


func _dispatch(shader_name: String, uniforms: Array, push_constant: PackedByteArray, size: Vector2i) -> void:
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[shader_name])
	_rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(_shaders[shader_name], 0, uniforms), 0)
	_rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
	_rd.compute_list_dispatch(list, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	_rd.compute_list_end()


func _sampled(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(texture)
	return uniform


func _uniform_buffer(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _image(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


## std430 push constant data: ints and floats, padded to 16 bytes.
func _push(values: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ceili(values.size() / 4.0) * 16)
	for i in values.size():
		if values[i] is int:
			bytes.encode_s32(i * 4, values[i])
		else:
			bytes.encode_float(i * 4, values[i])
	return bytes
