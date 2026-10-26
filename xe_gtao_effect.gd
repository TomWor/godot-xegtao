@tool
## Intel's XeGTAO ground-truth ambient occlusion
## (https://github.com/GameTechDev/XeGTAO, MIT licence) as a compositor
## effect for the Forward+ renderer. Add it to the Compositor of a
## WorldEnvironment or Camera3D.
##
## In MATERIALS mode it runs after the depth prepass and publishes its result
## as the global shader texture `xe_gtao_texture` (registered by the plugin),
## which shaders read with xe_gtao.gdshaderinc and feed into AO, so it only
## darkens ambient light. In MULTIPLY mode it darkens the rendered image after
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
## Strength in MULTIPLY mode. In MATERIALS mode the shaders decide.
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

## Render-thread textures of the last frame, for debugging.
var debug_textures: Dictionary = {}

var _rd: RenderingDevice
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _sampler: RID
## The published result. Owned here rather than by the render buffers, so it
## stays valid until the materials have switched to a resized replacement.
var _output := RID()
var _output_size := Vector2i.ZERO
var _retired: Array = []  # [rid, frames until it can be freed]
var _frame := 0
## Main thread: wraps _output for the materials.
var _texture: Texture2DRD


func _init() -> void:
	access_resolved_depth = true
	needs_normal_roughness = true
	_configure_callback()
	RenderingServer.call_on_render_thread(_initialize_compute)


## Turns the effect on or off at runtime. Use this rather than `enabled` in
## MATERIALS mode, so materials don't keep the last result.
func set_active(active: bool) -> void:
	enabled = active
	if not active:
		_publish.call_deferred(RID())


func _configure_callback() -> void:
	if apply_mode == ApplyMode.MATERIALS:
		effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
		access_resolved_color = false
	else:
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		access_resolved_color = true
		_publish.call_deferred(RID())


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	for retired: Array in _retired:
		_rd.free_rid(retired[0])
	if _output.is_valid():
		_rd.free_rid(_output)
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
	# Freeing a shader also frees its pipeline.
	for shader: RID in _shaders.values():
		_rd.free_rid(shader)


func _initialize_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
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
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size := buffers.get_internal_size()
	# The prepass normals only exist in Forward+.
	if size.x < 2 or size.y < 2 or not buffers.has_texture(&"forward_clustered", &"normal_roughness"):
		return
	_frame += 1
	_free_retired()
	_ensure_textures(buffers, size)

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
		float(preset.x), float(preset.y), _frame % 64 if temporal_noise else 0,
	]), size)

	# Ping-pong between the working textures; the last pass writes the output.
	# Without denoising, one pass with a huge centre weight just rescales.
	var passes := maxi(1, denoise_passes)
	var blur_beta := 1.2 if denoise_passes > 0 else 1e4
	var source := ao
	var target := ao_pong
	for i in passes:
		var final_pass := i == passes - 1
		var destination := _output if final_pass else target
		_dispatch("denoise", [_sampled(0, source), _sampled(1, edges), _image(2, destination)],
				_push([size.x, size.y, blur_beta, 1 if final_pass else 0]), size)
		var swap := source
		source = target
		target = swap

	if apply_mode == ApplyMode.MULTIPLY:
		_dispatch("apply", [_image(0, buffers.get_color_layer(0, false)), _sampled(1, _output), _sampled(2, view_depth), _uniform_buffer(3, scene_buffer)],
				_push([size.x, size.y, intensity, 0.0]), size)

	debug_textures = {&"depth": view_depth, &"ao": ao, &"edges": edges, &"output": _output}


func _ensure_textures(buffers: RenderSceneBuffersRD, size: Vector2i) -> void:
	if not buffers.has_texture(CONTEXT, &"depth") or buffers.get_texture_slice_size(CONTEXT, &"depth", 0) != size:
		buffers.clear_context(CONTEXT)
		var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		buffers.create_texture(CONTEXT, &"depth", RenderingDevice.DATA_FORMAT_R32_SFLOAT, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, DEPTH_MIP_LEVELS, true, false)
		for texture_name: StringName in [&"ao", &"ao_pong", &"edges"]:
			buffers.create_texture(CONTEXT, texture_name, RenderingDevice.DATA_FORMAT_R8_UNORM, usage, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)

	if _output_size != size:
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
		format.width = size.x
		format.height = size.y
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		if _output.is_valid():
			_retired.append([_output, 3])
		_output = _rd.texture_create(format, RDTextureView.new())
		_output_size = size
		if apply_mode == ApplyMode.MATERIALS:
			_publish.call_deferred(_output)


func _free_retired() -> void:
	for i in range(_retired.size() - 1, -1, -1):
		_retired[i][1] -= 1
		if _retired[i][1] <= 0:
			_rd.free_rid(_retired[i][0])
			_retired.remove_at(i)


## Main thread: points the materials' global texture at the output, or back
## at the plugin's white default for an invalid RID.
func _publish(rid: RID) -> void:
	# The rendering server only lists globals in the editor; the setting exists everywhere.
	if not ProjectSettings.has_setting("shader_globals/" + GLOBAL_TEXTURE):
		if rid.is_valid():
			push_warning("XeGTAO: the shader global `xe_gtao_texture` is missing; enable the XeGTAO plugin.")
		return
	if not rid.is_valid():
		RenderingServer.global_shader_parameter_set(GLOBAL_TEXTURE, load(get_script().resource_path.get_base_dir().path_join("white.png")))
		return
	if _texture == null:
		_texture = Texture2DRD.new()
	_texture.texture_rd_rid = rid
	RenderingServer.global_shader_parameter_set(GLOBAL_TEXTURE, _texture)


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
