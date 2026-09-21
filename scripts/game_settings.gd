extends Node

const LEGACY_SETTINGS_PATH := "user://settings.cfg"
const WINDOWS_SETTINGS_DIR_SUFFIX := "BlockCraft"
const SETTINGS_FILE_NAME := "settings.cfg"

var fov: float = 75.0
var render_distance: int = 12
var fullscreen: bool = false
var toggle_sprint: bool = false
var toggle_crouch: bool = false
var username: String = "Player"


func _ready() -> void:
	load_from_disk()
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

	# Migrate the old Godot user:// settings file once.
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
		16
	)
	fullscreen = bool(
		config.get_value("video", "fullscreen", fullscreen)
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

	# A file loaded from the legacy user:// location is immediately
	# rewritten to the new Windows AppData location.
	if loaded_legacy_settings:
		save_to_disk()


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("video", "fov", fov)
	config.set_value("video", "render_distance", render_distance)
	config.set_value("video", "fullscreen", fullscreen)
	config.set_value("controls", "toggle_sprint", toggle_sprint)
	config.set_value("controls", "toggle_crouch", toggle_crouch)
	config.set_value("player", "username", username)

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
	render_distance = clampi(value, 2, 16)
	save_to_disk()


func set_fullscreen(enabled: bool) -> void:
	fullscreen = enabled
	apply_window_mode()
	save_to_disk()


func set_toggle_sprint(enabled: bool) -> void:
	toggle_sprint = enabled
	save_to_disk()


func set_toggle_crouch(enabled: bool) -> void:
	toggle_crouch = enabled
	save_to_disk()


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
