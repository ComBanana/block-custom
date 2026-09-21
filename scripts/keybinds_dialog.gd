extends Window

var keybind_buttons: Dictionary = {}
var listening_action: String = ""


func _ready() -> void:
	close_requested.connect(_on_close_requested)
	_build_ui()
	popup_centered()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	margin.add_child(outer)

	var info := Label.new()
	info.text = "Click a binding, then press a key or mouse button."
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(info)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	for action in GameSettings.KEYBIND_ACTIONS:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, 36)

		var label := Label.new()
		label.text = GameSettings.get_keybind_label(action)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(label)

		var button := Button.new()
		button.custom_minimum_size = Vector2(180, 32)
		button.text = GameSettings.get_keybind_display(action)
		button.pressed.connect(
			_start_listening.bind(action, button)
		)
		row.add_child(button)

		list.add_child(row)
		keybind_buttons[action] = button

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 8)
	outer.add_child(bottom)

	var reset_button := Button.new()
	reset_button.text = "Reset Defaults"
	reset_button.custom_minimum_size = Vector2(150, 36)
	reset_button.pressed.connect(_reset_defaults)
	bottom.add_child(reset_button)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(120, 36)
	close_button.pressed.connect(_on_close_requested)
	bottom.add_child(close_button)


func _start_listening(action: String, button: Button) -> void:
	listening_action = action
	button.text = "Press a key..."
	get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if listening_action == "":
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cancel_listening()
			get_viewport().set_input_as_handled()
			return

		var binding_event := event.duplicate()
		GameSettings.set_keybind(listening_action, binding_event)
		_finish_listening()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed:
		var binding_event := event.duplicate()
		GameSettings.set_keybind(listening_action, binding_event)
		_finish_listening()
		get_viewport().set_input_as_handled()


func _finish_listening() -> void:
	if keybind_buttons.has(listening_action):
		var button: Button = keybind_buttons[listening_action]
		button.text = GameSettings.get_keybind_display(listening_action)
	listening_action = ""


func _cancel_listening() -> void:
	if keybind_buttons.has(listening_action):
		var button: Button = keybind_buttons[listening_action]
		button.text = GameSettings.get_keybind_display(listening_action)
	listening_action = ""


func _reset_defaults() -> void:
	listening_action = ""
	GameSettings.reset_keybinds()
	for action in keybind_buttons:
		var button: Button = keybind_buttons[action]
		button.text = GameSettings.get_keybind_display(action)


func _on_close_requested() -> void:
	listening_action = ""
	queue_free()
