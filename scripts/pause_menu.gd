extends CanvasLayer


@onready var pause_menu: Control = $PauseMenu
var version_label: Label

@onready var resume_button: Button = (
	$PauseMenu/Center/Panel/Buttons/ResumeButton
)

@onready var settings_button: Button = (
	$PauseMenu/Center/Panel/Buttons/SettingsButton
)

@onready var statistics_button: Button = (
	$PauseMenu/Center/Panel/Buttons/StatisticsButton
)

@onready var quit_button: Button = (
	$PauseMenu/Center/Panel/Buttons/QuitButton
)

@onready var main_menu_button: Button = (
	$PauseMenu/Center/Panel/Buttons/MainMenuButton
)


@onready var center: Control = (
	$PauseMenu/Center
)

@onready var settings_center: Control = (
	$PauseMenu/SettingsCenter
)

@onready var statistics_center: Control = (
	$PauseMenu/StatisticsCenter
)

@onready var statistics_world_value: Label = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/WorldRow/Value
)

@onready var statistics_seed_value: Label = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/SeedRow/Value
)

@onready var statistics_play_time_value: Label = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/PlayTimeRow/Value
)

@onready var statistics_distance_value: Label = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/DistanceRow/Value
)

@onready var statistics_blocks_broken_value: Label = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/BlocksBrokenRow/Value
)

@onready var statistics_blocks_placed_value: Label = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/BlocksPlacedRow/Value
)

@onready var statistics_back_button: Button = (
	$PauseMenu/StatisticsCenter/StatisticsPanel/Content/BackButton
)


@onready var video_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/CategoryButtons/VideoButton
)

@onready var controls_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/CategoryButtons/ControlsButton
)

@onready var video_options: Control = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions
)

@onready var controls_options: Control = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/ControlsOptions
)

@onready var render_distance_slider: HSlider = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/RenderDistanceSlider
)

@onready var render_distance_value: Label = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/RenderDistanceRow/RenderDistanceValue
)

@onready var fov_slider: HSlider = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/FOVSlider
)

@onready var fov_value: Label = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/FOVRow/FOVValue
)

@onready var window_mode_option: OptionButton = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/WindowModeRow/WindowModeOption
)

@onready var fog_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/FogButton
)

@onready var view_bobbing_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/ViewBobbingButton
)

@onready var light_shaders_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/VideoOptions/LightShadersButton
)

@onready var toggle_sprint_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/ControlsOptions/ToggleSprintButton
)

@onready var toggle_crouch_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/ControlsOptions/ToggleCrouchButton
)

@onready var keybinds_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/ControlsOptions/KeybindsButton
)

const KEYBINDS_DIALOG_SCENE = preload("res://scenes/KeybindsDialog.tscn")

@onready var back_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/BackButton
)


@onready var world = $"../World"
@onready var player: CharacterBody3D = $"../Player"


var is_paused: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	version_label = get_node_or_null("PauseMenu/VersionLabel") as Label
	if version_label != null:
		version_label.text = "v%s" % ProjectSettings.get_setting(
			"application/config/version",
			"0.2.1"
		)

	pause_menu.visible = false
	settings_center.visible = false
	statistics_center.visible = false

	resume_button.pressed.connect(resume_game)
	settings_button.pressed.connect(open_settings)
	statistics_button.pressed.connect(open_statistics)
	quit_button.pressed.connect(quit_game)
	main_menu_button.pressed.connect(exit_to_main_menu)

	render_distance_slider.value_changed.connect(
		_on_render_distance_changed
	)

	fov_slider.value_changed.connect(
		_on_fov_changed
	)

	window_mode_option.item_selected.connect(
		_on_window_mode_changed
	)

	video_button.pressed.connect(_on_video_tab_pressed)
	controls_button.pressed.connect(_on_controls_tab_pressed)
	toggle_sprint_button.pressed.connect(_on_toggle_sprint_pressed)
	toggle_crouch_button.pressed.connect(_on_toggle_crouch_pressed)
	fog_button.pressed.connect(_on_fog_pressed)
	view_bobbing_button.pressed.connect(_on_view_bobbing_pressed)
	light_shaders_button.pressed.connect(_on_light_shaders_pressed)
	keybinds_button.pressed.connect(_on_keybinds_pressed)

	back_button.pressed.connect(close_settings)
	statistics_back_button.pressed.connect(close_statistics)

	window_mode_option.clear()
	window_mode_option.add_item("Windowed")
	window_mode_option.add_item("Fullscreen")

	load_current_settings()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE:
				if settings_center.visible:
					close_settings()
				elif statistics_center.visible:
					close_statistics()
				else:
					toggle_pause()


func toggle_pause() -> void:
	if is_paused:
		resume_game()
	else:
		pause_game()


func pause_game() -> void:
	if is_paused:
		return

	is_paused = true

	get_tree().paused = true

	pause_menu.visible = true
	center.visible = true
	settings_center.visible = false
	statistics_center.visible = false

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func resume_game() -> void:
	if not is_paused:
		return

	is_paused = false

	pause_menu.visible = false

	get_tree().paused = false

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func open_settings() -> void:
	center.visible = false
	statistics_center.visible = false
	settings_center.visible = true

	load_current_settings()
	_show_settings_tab("video")

func _show_settings_tab(tab: String) -> void:
	var show_video: bool = tab == "video"
	video_options.visible = show_video
	controls_options.visible = not show_video

func _on_video_tab_pressed() -> void:
	_show_settings_tab("video")

func _on_controls_tab_pressed() -> void:
	_show_settings_tab("controls")

func _on_toggle_sprint_pressed() -> void:
	GameSettings.set_toggle_sprint(not GameSettings.toggle_sprint)
	_update_toggle_buttons()

func _on_toggle_crouch_pressed() -> void:
	GameSettings.set_toggle_crouch(not GameSettings.toggle_crouch)
	_update_toggle_buttons()

func _on_fog_pressed() -> void:
	GameSettings.set_fog_enabled(not GameSettings.fog_enabled)
	world._apply_fog_settings()
	_update_video_toggle_buttons()

func _on_view_bobbing_pressed() -> void:
	GameSettings.set_view_bobbing(not GameSettings.view_bobbing)
	_update_video_toggle_buttons()

func _on_light_shaders_pressed() -> void:
	GameSettings.set_light_shaders_enabled(not GameSettings.light_shaders_enabled)
	world.sun_light.shadow_enabled = GameSettings.light_shaders_enabled
	_update_video_toggle_buttons()

func _on_keybinds_pressed() -> void:
	var dialog = KEYBINDS_DIALOG_SCENE.instantiate()
	add_child(dialog)

func _update_video_toggle_buttons() -> void:
	fog_button.text = "Fog: %s" % ("ON" if GameSettings.fog_enabled else "OFF")
	view_bobbing_button.text = "View Bobbing: %s" % ("ON" if GameSettings.view_bobbing else "OFF")
	light_shaders_button.text = "Light Shaders: %s" % ("ON" if GameSettings.light_shaders_enabled else "OFF")

func _update_toggle_buttons() -> void:
	toggle_sprint_button.text = "Toggle Sprint: %s" % (
		"ON" if GameSettings.toggle_sprint else "OFF"
	)
	toggle_crouch_button.text = "Toggle Crouch: %s" % (
		"ON" if GameSettings.toggle_crouch else "OFF"
	)


func close_settings() -> void:
	settings_center.visible = false
	center.visible = true


func open_statistics() -> void:
	center.visible = false
	settings_center.visible = false
	statistics_center.visible = true
	_refresh_statistics()


func close_statistics() -> void:
	statistics_center.visible = false
	center.visible = true


func _refresh_statistics() -> void:
	var stats: Dictionary = world.get_statistics()

	statistics_world_value.text = str(stats.get("world_name", "World"))
	statistics_seed_value.text = str(stats.get("seed", 0))

	var total_seconds: int = maxi(
		0,
		roundi(float(stats.get("play_time_seconds", 0.0)))
	)
	var hours: int = total_seconds / 3600
	var minutes: int = (total_seconds % 3600) / 60
	var seconds: int = total_seconds % 60

	if hours > 0:
		statistics_play_time_value.text = "%dh %02dm %02ds" % [
			hours,
			minutes,
			seconds
		]
	else:
		statistics_play_time_value.text = "%dm %02ds" % [
			minutes,
			seconds
		]

	statistics_distance_value.text = "%.1f blocks" % float(
		stats.get("distance_travelled", 0.0)
	)
	statistics_blocks_broken_value.text = str(
		stats.get("blocks_broken", 0)
	)
	statistics_blocks_placed_value.text = str(
		stats.get("blocks_placed", 0)
	)


func quit_game() -> void:
	world.save_world()
	get_tree().quit()


func exit_to_main_menu() -> void:
	world.save_world()
	GameSession.clear()
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


func load_current_settings() -> void:
	render_distance_slider.value = world.render_distance
	render_distance_value.text = "%d" % world.render_distance

	fov_slider.value = player.camera.fov
	fov_value.text = "%d°" % roundi(player.camera.fov)

	var current_mode := DisplayServer.window_get_mode()

	if current_mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		window_mode_option.select(1)
	else:
		window_mode_option.select(0)

	_update_toggle_buttons()
	_update_video_toggle_buttons()


func _on_render_distance_changed(value: float) -> void:
	var distance: int = roundi(value)

	GameSettings.set_render_distance(distance)
	world.render_distance = GameSettings.render_distance
	render_distance_value.text = "%d" % GameSettings.render_distance

	world.update_chunks()
	world._apply_fog_settings()


func _on_fov_changed(value: float) -> void:
	var fov: float = value

	GameSettings.set_fov(fov)
	player.normal_fov = GameSettings.fov
	player.camera.fov = GameSettings.fov

	fov_value.text = "%d°" % roundi(fov)


func _on_window_mode_changed(index: int) -> void:
	GameSettings.set_fullscreen(index == 1)
