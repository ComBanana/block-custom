extends Node

const SETTINGS_PATH := "user://settings.cfg"

var fov: float = 75.0
var render_distance: int = 12
var fullscreen: bool = false


func _ready() -> void:
	load_from_disk()
	apply_window_mode()


func load_from_disk() -> void:
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error != OK:
		return

	fov = clampf(float(config.get_value("video", "fov", fov)), 20.0, 120.0)
	render_distance = clampi(int(config.get_value("video", "render_distance", render_distance)), 2, 16)
	fullscreen = bool(config.get_value("video", "fullscreen", fullscreen))


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("video", "fov", fov)
	config.set_value("video", "render_distance", render_distance)
	config.set_value("video", "fullscreen", fullscreen)
	config.save(SETTINGS_PATH)


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
