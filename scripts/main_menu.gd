extends Control

@onready var main_panel: Control = $Center/MainPanel
@onready var worlds_panel: Control = $Center/WorldsPanel
@onready var create_panel: Control = $Center/CreatePanel
@onready var settings_panel: Control = $Center/SettingsPanel

@onready var world_list: ItemList = $Center/WorldsPanel/VBox/WorldList
@onready var play_world_button: Button = $Center/WorldsPanel/VBox/Buttons/PlayButton
@onready var delete_world_button: Button = $Center/WorldsPanel/VBox/Buttons/DeleteButton

@onready var world_name_input: LineEdit = $Center/CreatePanel/VBox/NameInput
@onready var seed_input: LineEdit = $Center/CreatePanel/VBox/SeedInput
@onready var create_error: Label = $Center/CreatePanel/VBox/ErrorLabel

@onready var video_button: Button = $Center/SettingsPanel/VBox/CategoryButtons/VideoButton
@onready var controls_button: Button = $Center/SettingsPanel/VBox/CategoryButtons/ControlsButton
@onready var video_options: Control = $Center/SettingsPanel/VBox/VideoOptions
@onready var controls_options: Control = $Center/SettingsPanel/VBox/ControlsOptions

@onready var render_distance_slider: HSlider = $Center/SettingsPanel/VBox/VideoOptions/RenderDistanceSlider
@onready var render_distance_value: Label = $Center/SettingsPanel/VBox/VideoOptions/RenderDistanceRow/Value
@onready var fov_slider: HSlider = $Center/SettingsPanel/VBox/VideoOptions/FOVSlider
@onready var fov_value: Label = $Center/SettingsPanel/VBox/VideoOptions/FOVRow/Value
@onready var window_mode_option: OptionButton = $Center/SettingsPanel/VBox/VideoOptions/WindowModeRow/WindowModeOption
@onready var fog_button: Button = $Center/SettingsPanel/VBox/VideoOptions/FogButton
@onready var view_bobbing_button: Button = $Center/SettingsPanel/VBox/VideoOptions/ViewBobbingButton
@onready var light_shaders_button: Button = $Center/SettingsPanel/VBox/VideoOptions/LightShadersButton
@onready var toggle_sprint_button: Button = $Center/SettingsPanel/VBox/ControlsOptions/ToggleSprintButton
@onready var toggle_crouch_button: Button = $Center/SettingsPanel/VBox/ControlsOptions/ToggleCrouchButton
@onready var keybinds_button: Button = $Center/SettingsPanel/VBox/ControlsOptions/KeybindsButton
const KEYBINDS_DIALOG_SCENE = preload("res://scenes/KeybindsDialog.tscn")

var version_label: Label
@onready var username_panel: Control = $UsernamePanel
@onready var username_input: LineEdit = $UsernamePanel/VBox/UsernameInput
@onready var username_save_button: Button = $UsernamePanel/VBox/SaveButton
@onready var username_saved_label: Label = $UsernamePanel/VBox/SavedLabel
@onready var username_error: Label = $UsernamePanel/VBox/ErrorLabel

var worlds: Array[Dictionary] = []
var legacy_migration_dialog: ConfirmationDialog


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	version_label = get_node_or_null("VersionLabel") as Label
	if version_label != null:
		version_label.text = "v%s" % ProjectSettings.get_setting(
			"application/config/version",
			"0.2.1"
		)
	video_button.pressed.connect(_on_video_tab_pressed)
	controls_button.pressed.connect(_on_controls_tab_pressed)
	toggle_sprint_button.pressed.connect(_on_toggle_sprint_pressed)
	toggle_crouch_button.pressed.connect(_on_toggle_crouch_pressed)
	fog_button.pressed.connect(_on_fog_pressed)
	view_bobbing_button.pressed.connect(_on_view_bobbing_pressed)
	light_shaders_button.pressed.connect(_on_light_shaders_pressed)
	keybinds_button.pressed.connect(_on_keybinds_pressed)
	username_save_button.pressed.connect(_on_username_save_pressed)
	get_tree().paused = false
	_show_panel(main_panel)

	if WorldStore.has_legacy_worlds():
		call_deferred("_show_legacy_world_migration_dialog")

	_refresh_worlds()
	_load_settings_ui()


func _show_panel(panel: Control) -> void:
	main_panel.visible = panel == main_panel
	worlds_panel.visible = panel == worlds_panel
	create_panel.visible = panel == create_panel
	settings_panel.visible = panel == settings_panel
	username_panel.visible = panel == main_panel


func _on_play_pressed() -> void:
	_refresh_worlds()
	_show_panel(worlds_panel)


func _on_create_pressed() -> void:
	world_name_input.text = _default_world_name()
	seed_input.text = ""
	create_error.text = ""
	_show_panel(create_panel)


func _on_settings_pressed() -> void:
	_load_settings_ui()
	_show_settings_tab("video")
	_show_panel(settings_panel)

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
	_update_video_toggle_buttons()

func _on_view_bobbing_pressed() -> void:
	GameSettings.set_view_bobbing(not GameSettings.view_bobbing)
	_update_video_toggle_buttons()

func _on_light_shaders_pressed() -> void:
	GameSettings.set_light_shaders_enabled(not GameSettings.light_shaders_enabled)
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


func _load_username_ui() -> void:
	username_input.text = GameSettings.username
	username_error.text = ""
	username_saved_label.visible = false


func _on_username_save_pressed() -> void:
	var entered := username_input.text.strip_edges()

	if entered.length() < 3 or entered.length() > 16:
		username_error.text = "Use 3-16 letters, numbers, or _."
		username_saved_label.visible = false
		return

	for character in entered:
		if not (
			(character >= "a" and character <= "z")
			or (character >= "A" and character <= "Z")
			or (character >= "0" and character <= "9")
			or character == "_"
		):
			username_error.text = "Use 3-16 letters, numbers, or _."
			username_saved_label.visible = false
			return

	GameSettings.set_username(entered)
	username_input.text = GameSettings.username
	username_error.text = ""
	username_saved_label.visible = true
	get_tree().create_timer(1.2).timeout.connect(
		func():
			if is_instance_valid(username_saved_label):
				username_saved_label.visible = false
	)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_back_pressed() -> void:
	_show_panel(main_panel)


func _refresh_worlds() -> void:
	worlds = WorldStore.list_worlds()
	world_list.clear()
	for world_data in worlds:
		var seed_value: int = int(world_data.get("seed", 0))
		world_list.add_item(
			"%s    (seed %d)" % [
				str(world_data.get("name", "World")),
				seed_value
			]
		)
	play_world_button.disabled = worlds.is_empty()
	delete_world_button.disabled = worlds.is_empty()
	if not worlds.is_empty():
		world_list.select(0)


func _selected_world_name() -> String:
	var selected := world_list.get_selected_items()
	if selected.is_empty() or selected[0] >= worlds.size():
		return ""
	return str(worlds[selected[0]].get("name", ""))


func _on_play_world_pressed(_index: int = 0) -> void:
	var world_name := _selected_world_name()
	if world_name == "":
		return
	GameSession.start_existing_world(world_name)
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_delete_world_pressed() -> void:
	var world_name := _selected_world_name()
	if world_name == "":
		return
	WorldStore.delete_world(world_name)
	_refresh_worlds()


func _on_random_seed_pressed() -> void:
	seed_input.text = str(randi())


func _on_create_world_pressed() -> void:
	var world_name := WorldStore.sanitize_world_name(world_name_input.text)
	if world_name == "":
		create_error.text = "Enter a world name."
		return
	if WorldStore.world_exists(world_name):
		create_error.text = "A world with that name already exists."
		return

	var world_seed: int = _parse_seed(seed_input.text)
	WorldStore.create_world(world_name, world_seed)
	GameSession.start_new_world(world_name, world_seed)
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _parse_seed(text: String) -> int:
	var trimmed := text.strip_edges()
	if trimmed == "":
		return randi()
	if trimmed.is_valid_int():
		return int(trimmed)
	return trimmed.hash()


func _default_world_name() -> String:
	var index := 1
	var candidate := "New World"
	while WorldStore.world_exists(candidate):
		index += 1
		candidate = "New World %d" % index
	return candidate


func _load_settings_ui() -> void:
	_load_username_ui()
	render_distance_slider.value = GameSettings.render_distance
	render_distance_value.text = str(GameSettings.render_distance)
	fov_slider.value = GameSettings.fov
	fov_value.text = "%d°" % roundi(GameSettings.fov)
	window_mode_option.select(1 if GameSettings.fullscreen else 0)
	_update_toggle_buttons()
	_update_video_toggle_buttons()


func _on_render_distance_changed(value: float) -> void:
	GameSettings.set_render_distance(roundi(value))
	render_distance_value.text = str(GameSettings.render_distance)


func _on_fov_changed(value: float) -> void:
	GameSettings.set_fov(value)
	fov_value.text = "%d°" % roundi(GameSettings.fov)


func _on_window_mode_changed(index: int) -> void:
	GameSettings.set_fullscreen(index == 1)


func _show_legacy_world_migration_dialog() -> void:
	if legacy_migration_dialog != null:
		return

	legacy_migration_dialog = ConfirmationDialog.new()
	legacy_migration_dialog.title = "World Save Migration"
	legacy_migration_dialog.ok_button_text = "Move Worlds & Delete Old Folder"
	legacy_migration_dialog.cancel_button_text = "Keep Old Folder"
	legacy_migration_dialog.dialog_text = (
		"BlockCraft found worlds in the old save location:\n\n"
		+ WorldStore.legacy_worlds_display_path()
		+ "\n\n"
		+ "These worlds can be moved to the new save location:\n"
		+ WorldStore.worlds_display_path()
		+ "\n\n"
		+ "Choose Move Worlds & Delete Old Folder to move the old worlds "
		+ "and delete the old worlds folder.\n\n"
		+ "Choose Keep Old Folder to leave the old worlds where they are. "
		+ "They will remain playable, and any new worlds will still save "
		+ "to the new location."
	)
	legacy_migration_dialog.size = Vector2i(760, 360)
	legacy_migration_dialog.confirmed.connect(
		_on_confirm_legacy_world_migration
	)
	legacy_migration_dialog.canceled.connect(
		_on_cancel_legacy_world_migration
	)
	add_child(legacy_migration_dialog)
	legacy_migration_dialog.popup_centered()


func _on_confirm_legacy_world_migration() -> void:
	var result := WorldStore.migrate_legacy_worlds()

	if result.get("success", false):
		_refresh_worlds()
		return

	var failed_worlds: Array = result.get(
		"failed_worlds",
		[]
	)
	var details := ""
	if not failed_worlds.is_empty():
		details = "\n\nCould not move/delete:\n" + "\n".join(
			PackedStringArray(failed_worlds)
		)

	var error_dialog := AcceptDialog.new()
	error_dialog.title = "World Migration Incomplete"
	error_dialog.dialog_text = (
		"Some old worlds could not be migrated. "
		+ "No remaining old worlds were deleted."
		+ details
	)
	error_dialog.size = Vector2i(650, 260)
	error_dialog.confirmed.connect(
		func(): error_dialog.queue_free()
	)
	add_child(error_dialog)
	error_dialog.popup_centered()
	_refresh_worlds()


func _on_cancel_legacy_world_migration() -> void:
	_refresh_worlds()
