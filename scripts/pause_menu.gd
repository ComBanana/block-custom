extends CanvasLayer


@onready var pause_menu: Control = $PauseMenu

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


@onready var render_distance_slider: HSlider = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/RenderDistanceSlider
)

@onready var render_distance_value: Label = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/RenderDistanceRow/RenderDistanceValue
)


@onready var fov_slider: HSlider = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/FOVSlider
)

@onready var fov_value: Label = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/FOVRow/FOVValue
)


@onready var window_mode_option: OptionButton = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/WindowModeRow/WindowModeOption
)

@onready var back_button: Button = (
	$PauseMenu/SettingsCenter/SettingsPanel/Content/BackButton
)


@onready var world = $"../World"
@onready var player: CharacterBody3D = $"../Player"


var is_paused: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	pause_menu.visible = false
	settings_center.visible = false

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

	back_button.pressed.connect(close_settings)

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
	settings_center.visible = true

	load_current_settings()


func close_settings() -> void:
	settings_center.visible = false
	center.visible = true


func open_statistics() -> void:
	print("Statistics menu coming later.")


func quit_game() -> void:
	get_tree().quit()


func exit_to_main_menu() -> void:
	print("Main menu coming later.")


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


func _on_render_distance_changed(value: float) -> void:
	var distance: int = roundi(value)

	world.render_distance = distance
	render_distance_value.text = "%d" % distance

	world.update_chunks()


func _on_fov_changed(value: float) -> void:
	var fov: float = value

	player.normal_fov = fov
	player.camera.fov = fov

	fov_value.text = "%d°" % roundi(fov)


func _on_window_mode_changed(index: int) -> void:
	match index:
		0:
			DisplayServer.window_set_mode(
				DisplayServer.WINDOW_MODE_WINDOWED
			)

		1:
			DisplayServer.window_set_mode(
				DisplayServer.WINDOW_MODE_FULLSCREEN
			)
