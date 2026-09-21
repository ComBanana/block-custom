extends Node

const LEGACY_SETTINGS_PATH := "user://settings.cfg"
const WINDOWS_SETTINGS_DIR_SUFFIX := "BlockCraft"
const SETTINGS_FILE_NAME := "settings.cfg"

const KEYBIND_ACTIONS := [
	"move_forward",
	"move_backward",
	"move_left",
	"move_right",
	"jump",
	"sprint",
	"crouch",
	"break_block",
	"place_block",
	"chat",
	"hotbar_1",
	"hotbar_2",
	"hotbar_3",
	"hotbar_4",
	"hotbar_5",
	"hotbar_6",
	"hotbar_7",
	"hotbar_8",
	"hotbar_9"
]

const KEYBIND_LABELS := {
	"move_forward": "Move Forward",
	"move_backward": "Move Backward",
	"move_left": "Move Left",
	"move_right": "Move Right",
	"jump": "Jump",
	"sprint": "Sprint",
	"crouch": "Crouch",
	"break_block": "Break Block",
	"place_block": "Place Block",
	"chat": "Chat",
	"hotbar_1": "Hotbar Slot 1",
	"hotbar_2": "Hotbar Slot 2",
	"hotbar_3": "Hotbar Slot 3",
	"hotbar_4": "Hotbar Slot 4",
	"hotbar_5": "Hotbar Slot 5",
	"hotbar_6": "Hotbar Slot 6",
	"hotbar_7": "Hotbar Slot 7",
	"hotbar_8": "Hotbar Slot 8",
	"hotbar_9": "Hotbar Slot 9"
}

var fov: float = 75.0
var render_distance: int = 12
var fullscreen: bool = false
var fog_enabled: bool = true
var view_bobbing: bool = true
var light_shaders_enabled: bool = true
var toggle_sprint: bool = false
var toggle_crouch: bool = false
var username: String = "Player"

var _saved_keybinds: Dictionary = {}


func _ready() -> void:
	load_from_disk()
	_apply_saved_keybinds()
	apply_window_mode()


func settings_path() -> String:
	if OS.get_name() == "Windows":
		var appdata := OS.get_environment("APPDATA").strip_edges()
		if appdata != "":
			return "%s/%s/%s" % [
				appdata,
				WINDOWS_SETTINGS_DIR_SUFFIX,
				SETTINGS_FILE_NAME
			]

	return "user://settings.cfg"


func load_from_disk() -> void:
	var path := settings_path()
	var config := ConfigFile.new()
	var error := config.load(path)
	var loaded_legacy_settings := false

	if error != OK and path != LEGACY_SETTINGS_PATH:
		if FileAccess.file_exists(LEGACY_SETTINGS_PATH):
			error = config.load(LEGACY_SETTINGS_PATH)
			loaded_legacy_settings = error == OK

	if error != OK:
		return

	fov = clampf(
		float(config.get_value("video", "fov", fov)),
		20.0,
		120.0
	)
	render_distance = clampi(
		int(config.get_value("video", "render_distance", render_distance)),
		2,
		64
	)
	fullscreen = bool(
		config.get_value("video", "fullscreen", fullscreen)
	)
	fog_enabled = bool(
		config.get_value("video", "fog_enabled", fog_enabled)
	)
	view_bobbing = bool(
		config.get_value("video", "view_bobbing", view_bobbing)
	)
	light_shaders_enabled = bool(
		config.get_value("video", "light_shaders_enabled", light_shaders_enabled)
	)
	toggle_sprint = bool(
		config.get_value(
			"controls",
			"toggle_sprint",
			toggle_sprint
		)
	)
	toggle_crouch = bool(
		config.get_value(
			"controls",
			"toggle_crouch",
			toggle_crouch
		)
	)
	username = sanitize_username(
		str(config.get_value("player", "username", username))
	)

	_saved_keybinds.clear()
	for action in KEYBIND_ACTIONS:
		if config.has_section_key("keybinds", action):
			_saved_keybinds[action] = config.get_value(
				"keybinds",
				action,
				{}
			)

	if loaded_legacy_settings:
		save_to_disk()


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("video", "fov", fov)
	config.set_value("video", "render_distance", render_distance)
	config.set_value("video", "fullscreen", fullscreen)
	config.set_value("video", "fog_enabled", fog_enabled)
	config.set_value("video", "view_bobbing", view_bobbing)
	config.set_value("video", "light_shaders_enabled", light_shaders_enabled)
	config.set_value("controls", "toggle_sprint", toggle_sprint)
	config.set_value("controls", "toggle_crouch", toggle_crouch)
	config.set_value("player", "username", username)

	for action in KEYBIND_ACTIONS:
		if not InputMap.has_action(action):
			continue
		var events := InputMap.action_get_events(action)
		if events.is_empty():
			continue
		config.set_value(
			"keybinds",
			action,
			_serialize_event(events[0])
		)

	var path := settings_path()
	if path.is_absolute_path():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	config.save(path)


func apply_window_mode() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


func set_fov(value: float) -> void:
	fov = clampf(value, 20.0, 120.0)
	save_to_disk()


func set_render_distance(value: int) -> void:
	render_distance = clampi(value, 2, 64)
	save_to_disk()


func set_fullscreen(enabled: bool) -> void:
	fullscreen = enabled
	apply_window_mode()
	save_to_disk()


func set_fog_enabled(enabled: bool) -> void:
	fog_enabled = enabled
	save_to_disk()


func set_view_bobbing(enabled: bool) -> void:
	view_bobbing = enabled
	save_to_disk()


func set_light_shaders_enabled(enabled: bool) -> void:
	light_shaders_enabled = enabled
	save_to_disk()


func set_toggle_sprint(enabled: bool) -> void:
	toggle_sprint = enabled
	save_to_disk()


func set_toggle_crouch(enabled: bool) -> void:
	toggle_crouch = enabled
	save_to_disk()


func get_keybind_label(action: String) -> String:
	return str(KEYBIND_LABELS.get(action, action))


func get_keybind_event(action: String) -> InputEvent:
	if not InputMap.has_action(action):
		return null

	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return null
	return events[0]


func get_keybind_display(action: String) -> String:
	var event := get_keybind_event(action)
	if event == null:
		return "Unbound"
	return event.as_text()


func set_keybind(action: String, event: InputEvent) -> void:
	if not KEYBIND_ACTIONS.has(action):
		return
	if not InputMap.has_action(action):
		return

	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event.duplicate())
	save_to_disk()


func reset_keybinds() -> void:
	var defaults := {
		"move_forward": _key_event(KEY_W),
		"move_backward": _key_event(KEY_S),
		"move_left": _key_event(KEY_A),
		"move_right": _key_event(KEY_D),
		"jump": _key_event(KEY_SPACE),
		"sprint": _key_event(KEY_CTRL),
		"crouch": _key_event(KEY_SHIFT),
		"break_block": _mouse_event(MOUSE_BUTTON_LEFT),
		"place_block": _mouse_event(MOUSE_BUTTON_RIGHT),
		"chat": _key_event(KEY_C),
		"hotbar_1": _key_event(KEY_1),
		"hotbar_2": _key_event(KEY_2),
		"hotbar_3": _key_event(KEY_3),
		"hotbar_4": _key_event(KEY_4),
		"hotbar_5": _key_event(KEY_5),
		"hotbar_6": _key_event(KEY_6),
		"hotbar_7": _key_event(KEY_7),
		"hotbar_8": _key_event(KEY_8),
		"hotbar_9": _key_event(KEY_9)
	}

	for action in KEYBIND_ACTIONS:
		if not defaults.has(action) or not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(
			action,
			defaults[action]
		)

	save_to_disk()


func _apply_saved_keybinds() -> void:
	for action in _saved_keybinds:
		var event := _deserialize_event(_saved_keybinds[action])
		if event == null or not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, event)
	_saved_keybinds.clear()


func _serialize_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		var key_event: InputEventKey = event
		return {
			"type": "key",
			"code": int(
				key_event.physical_keycode
				if key_event.physical_keycode != 0
				else key_event.keycode
			),
			"shift": key_event.shift_pressed,
			"ctrl": key_event.ctrl_pressed,
			"alt": key_event.alt_pressed,
			"meta": key_event.meta_pressed
		}

	if event is InputEventMouseButton:
		var mouse_event: InputEventMouseButton = event
		return {
			"type": "mouse",
			"button": int(mouse_event.button_index),
			"shift": mouse_event.shift_pressed,
			"ctrl": mouse_event.ctrl_pressed,
			"alt": mouse_event.alt_pressed,
			"meta": mouse_event.meta_pressed
		}

	return {}


func _deserialize_event(data: Variant) -> InputEvent:
	if not data is Dictionary:
		return null

	var event_type := str(data.get("type", ""))

	if event_type == "key":
		var key_event := InputEventKey.new()
		key_event.physical_keycode = int(data.get("code", 0))
		key_event.shift_pressed = bool(data.get("shift", false))
		key_event.ctrl_pressed = bool(data.get("ctrl", false))
		key_event.alt_pressed = bool(data.get("alt", false))
		key_event.meta_pressed = bool(data.get("meta", false))
		return key_event

	if event_type == "mouse":
		var mouse_event := InputEventMouseButton.new()
		mouse_event.button_index = int(
			data.get("button", MOUSE_BUTTON_LEFT)
		)
		mouse_event.shift_pressed = bool(data.get("shift", false))
		mouse_event.ctrl_pressed = bool(data.get("ctrl", false))
		mouse_event.alt_pressed = bool(data.get("alt", false))
		mouse_event.meta_pressed = bool(data.get("meta", false))
		return mouse_event

	return null


func _key_event(key: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = key
	return event


func _mouse_event(button: MouseButton) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	return event


func sanitize_username(value: String) -> String:
	var cleaned := ""

	for character in value.strip_edges():
		if (
			(character >= "a" and character <= "z")
			or (character >= "A" and character <= "Z")
			or (character >= "0" and character <= "9")
			or character == "_"
		):
			cleaned += character

		if cleaned.length() >= 16:
			break

	if cleaned.length() < 3:
		return "Player"

	return cleaned


func set_username(value: String) -> void:
	username = sanitize_username(value)
	save_to_disk()
