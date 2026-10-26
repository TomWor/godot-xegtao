@tool
## Registers the global shader texture XeGTAOEffect publishes its result to,
## in the project settings and in the running editor.
extends EditorPlugin

const GLOBAL_NAME := &"xe_gtao_texture"
const SETTING := "shader_globals/xe_gtao_texture"


func _enable_plugin() -> void:
	_register_global()


func _enter_tree() -> void:
	# Also covers projects that enabled the plugin before the global existed.
	_register_global()


func _disable_plugin() -> void:
	if RenderingServer.global_shader_parameter_get_list().has(GLOBAL_NAME):
		RenderingServer.global_shader_parameter_remove(GLOBAL_NAME)
	if ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, null)
		ProjectSettings.save()


func _register_global() -> void:
	var white_path: String = get_script().resource_path.get_base_dir().path_join("white.png")
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, {"type": "sampler2D", "value": white_path})
		ProjectSettings.save()
	if not RenderingServer.global_shader_parameter_get_list().has(GLOBAL_NAME):
		RenderingServer.global_shader_parameter_add(GLOBAL_NAME, RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, load(white_path))
