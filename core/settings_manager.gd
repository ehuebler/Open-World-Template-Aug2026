class_name GameSettingsManager
extends Node

signal settings_changed(section: StringName, key: StringName, value: Variant)

const SETTINGS_PATH := "user://settings.cfg"
const DEFAULTS := {
	"graphics": {
		"window_mode": 0,
		"resolution": "1280x720",
		"vsync": true,
		"max_fps": 120,
		"render_scale": 1.0,
		"quality": 1,
		## Index into [constant Planet.DETAIL_LEVELS]. Applied by the planet
		## rather than by `_apply_setting`, because there is nothing to apply it
		## to until a world is loaded.
		"render_distance": 1,
	},
	"audio": {
		"master_volume": 0.8,
		"music_volume": 0.7,
		"sfx_volume": 0.8,
		"voice_volume": 0.9,
	},
	"gameplay": {
		"mouse_sensitivity": 0.35,
		"invert_y": false,
		"fov": 75.0,
	},
	## Who you are: the name and the look. Body id, sparse slot→item map, and
	## sparse slot/"body"→HTML tint map. The home screen and the character editor
	## are the writers; spawning, the preview and the lobby all read.
	##
	## The name lives here rather than in [NetworkManager] because it outlives a
	## session — it is typed once under the figure on the home screen and is then
	## the name single player uses, the name the lobby fields start on, and the
	## name chat stamps.
	"appearance": {
		"name": "Player",
		"body": "settler",
		"worn": {},
		## The weapon bar, one entry per slot. A list rather than a map because a
		## rack slot means nothing except which number key draws it.
		"rack": [],
		"tints": {},
	},
	## Quests and achievements finished, as a list of [JournalDB] ids. Local to
	## this machine and never replicated: a co-op session shares a world, not a
	## diary. [Journal] is the only writer.
	"progress": {
		"done": [],
	},
}

var _config := ConfigFile.new()


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	_config = ConfigFile.new()
	var error := _config.load(SETTINGS_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("Could not load settings.cfg (error %s)." % error)
	_apply_defaults()
	_load_input_bindings()
	apply_all()


func save_settings() -> Error:
	_save_input_bindings()
	var error := _config.save(SETTINGS_PATH)
	if error != OK:
		push_error("Could not save settings.cfg (error %s)." % error)
	return error


func get_setting(section: StringName, key: StringName, fallback: Variant = null) -> Variant:
	return _config.get_value(String(section), String(key), fallback)


func set_setting(section: StringName, key: StringName, value: Variant, apply := true) -> void:
	_config.set_value(String(section), String(key), value)
	if apply:
		_apply_setting(section, key, value)
	settings_changed.emit(section, key, value)


func reset_to_defaults() -> void:
	for section: String in DEFAULTS:
		for key: String in DEFAULTS[section]:
			set_setting(section, key, DEFAULTS[section][key], false)
	apply_all()
	save_settings()


func apply_all() -> void:
	for section: String in DEFAULTS:
		for key: String in DEFAULTS[section]:
			_apply_setting(section, key, get_setting(section, key, DEFAULTS[section][key]))


func rebind_action(action: StringName, event: InputEvent, slot := 0) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var events := InputMap.action_get_events(action)
	if slot >= 0 and slot < events.size():
		InputMap.action_erase_event(action, events[slot])
	InputMap.action_add_event(action, event)
	save_settings()


func _apply_defaults() -> void:
	for section: String in DEFAULTS:
		for key: String in DEFAULTS[section]:
			if not _config.has_section_key(section, key):
				_config.set_value(section, key, DEFAULTS[section][key])


func _apply_setting(section: StringName, key: StringName, value: Variant) -> void:
	match "%s/%s" % [section, key]:
		"graphics/window_mode":
			match int(value):
				1:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
				2:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
				_:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		"graphics/resolution":
			var parts := String(value).split("x")
			if parts.size() == 2:
				DisplayServer.window_set_size(Vector2i(int(parts[0]), int(parts[1])))
		"graphics/vsync":
			DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if bool(value) else DisplayServer.VSYNC_DISABLED
			)
		"graphics/max_fps":
			Engine.max_fps = int(value)
		"graphics/render_scale":
			get_tree().root.scaling_3d_scale = float(value)
		"graphics/quality":
			match int(value):
				0:
					get_tree().root.msaa_3d = Viewport.MSAA_DISABLED
				2:
					get_tree().root.msaa_3d = Viewport.MSAA_4X
				_:
					get_tree().root.msaa_3d = Viewport.MSAA_2X
		"audio/master_volume":
			_set_bus_volume(&"Master", float(value))
		"audio/music_volume":
			_set_bus_volume(&"Music", float(value))
		"audio/sfx_volume":
			_set_bus_volume(&"SFX", float(value))
		"audio/voice_volume":
			_set_bus_volume(&"Voice", float(value))


func _set_bus_volume(bus_name: StringName, linear_volume: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	AudioServer.set_bus_volume_db(bus_index, linear_to_db(clampf(linear_volume, 0.0001, 1.0)))
	AudioServer.set_bus_mute(bus_index, is_zero_approx(linear_volume))


func _save_input_bindings() -> void:
	for action: StringName in InputMap.get_actions():
		if String(action).begins_with("ui_"):
			continue
		var serialized: Array[Dictionary] = []
		for event: InputEvent in InputMap.action_get_events(action):
			var data := _serialize_event(event)
			if not data.is_empty():
				serialized.append(data)
		_config.set_value("controls", String(action), serialized)


func _load_input_bindings() -> void:
	if not _config.has_section("controls"):
		return
	for action_key: String in _config.get_section_keys("controls"):
		var action := StringName(action_key)
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var saved_events: Array = _config.get_value("controls", action_key, [])
		InputMap.action_erase_events(action)
		for event_data: Variant in saved_events:
			if event_data is Dictionary:
				var event := _deserialize_event(event_data)
				if event != null:
					InputMap.action_add_event(action, event)


func _serialize_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {
			"type": "key",
			"keycode": event.keycode,
			"physical_keycode": event.physical_keycode,
		}
	if event is InputEventMouseButton:
		return {"type": "mouse_button", "button_index": event.button_index}
	if event is InputEventJoypadButton:
		return {"type": "joypad_button", "button_index": event.button_index}
	return {}


func _deserialize_event(data: Dictionary) -> InputEvent:
	match String(data.get("type", "")):
		"key":
			var key_event := InputEventKey.new()
			key_event.keycode = int(data.get("keycode", 0)) as Key
			key_event.physical_keycode = int(data.get("physical_keycode", 0)) as Key
			return key_event
		"mouse_button":
			var mouse_event := InputEventMouseButton.new()
			mouse_event.button_index = int(data.get("button_index", 1)) as MouseButton
			return mouse_event
		"joypad_button":
			var joypad_event := InputEventJoypadButton.new()
			joypad_event.button_index = int(data.get("button_index", 0)) as JoyButton
			return joypad_event
	return null
