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

@onready var render_distance_slider: HSlider = $Center/SettingsPanel/VBox/RenderDistanceSlider
@onready var render_distance_value: Label = $Center/SettingsPanel/VBox/RenderDistanceRow/Value
@onready var fov_slider: HSlider = $Center/SettingsPanel/VBox/FOVSlider
@onready var fov_value: Label = $Center/SettingsPanel/VBox/FOVRow/Value
@onready var window_mode_option: OptionButton = $Center/SettingsPanel/VBox/WindowModeRow/WindowModeOption

var worlds: Array[Dictionary] = []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	_show_panel(main_panel)
	_refresh_worlds()
	_load_settings_ui()


func _show_panel(panel: Control) -> void:
	main_panel.visible = panel == main_panel
	worlds_panel.visible = panel == worlds_panel
	create_panel.visible = panel == create_panel
	settings_panel.visible = panel == settings_panel


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
	_show_panel(settings_panel)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_back_pressed() -> void:
	_show_panel(main_panel)


func _refresh_worlds() -> void:
	worlds = WorldStore.list_worlds()
	world_list.clear()
	for world_data in worlds:
		var seed_value: int = int(world_data.get("seed", 0))
		world_list.add_item("%s    (seed %d)" % [str(world_data.get("name", "World")), seed_value])
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
	render_distance_slider.value = GameSettings.render_distance
	render_distance_value.text = str(GameSettings.render_distance)
	fov_slider.value = GameSettings.fov
	fov_value.text = "%d°" % roundi(GameSettings.fov)
	window_mode_option.select(1 if GameSettings.fullscreen else 0)


func _on_render_distance_changed(value: float) -> void:
	GameSettings.set_render_distance(roundi(value))
	render_distance_value.text = str(GameSettings.render_distance)


func _on_fov_changed(value: float) -> void:
	GameSettings.set_fov(value)
	fov_value.text = "%d°" % roundi(GameSettings.fov)


func _on_window_mode_changed(index: int) -> void:
	GameSettings.set_fullscreen(index == 1)
