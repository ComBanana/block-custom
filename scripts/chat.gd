extends Control


const MAX_VISIBLE_MESSAGES := 10
const MAX_HISTORY := 50
const MESSAGE_LIFETIME := 10.0
const MESSAGE_FADE_TIME := 2.0


@onready var messages_container: VBoxContainer = $Messages
@onready var chat_input_panel: PanelContainer = $ChatInputPanel
@onready var chat_input: LineEdit = $ChatInputPanel/Margin/ChatInput


var chat_open: bool = false
var history: Array[String] = []
var history_index: int = -1
var messages: Array[Dictionary] = []


func _ready() -> void:
	visible = false
	chat_input_panel.visible = false
	chat_input.gui_input.connect(_on_chat_input_gui_input)


func _process(_delta: float) -> void:
	_update_message_fades()


func _unhandled_input(event: InputEvent) -> void:
	if chat_open:
		return

	if event is InputEventKey:
		if event.pressed and not event.echo and event.is_action_pressed("chat"):
			_open_chat()
			get_viewport().set_input_as_handled()


func _open_chat() -> void:
	chat_open = true
	visible = true
	chat_input_panel.visible = true
	chat_input.text = ""
	history_index = -1
	chat_input.grab_focus()
	chat_input.edit()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	for entry in messages:
		var label: Label = entry["label"]
		label.modulate.a = 1.0


func _close_chat() -> void:
	chat_open = false
	visible = false
	chat_input_panel.visible = false
	chat_input.release_focus()
	chat_input.text = ""
	history_index = -1
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_chat_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE:
				_close_chat()
				chat_input.accept_event()
				return

			if event.keycode == KEY_UP:
				_set_history(-1)
				chat_input.accept_event()
				return

			if event.keycode == KEY_DOWN:
				_set_history(1)
				chat_input.accept_event()
				return


func _on_chat_input_submitted(message: String) -> void:
	var trimmed := message.strip_edges()

	if trimmed == "":
		_close_chat()
		return

	if history.is_empty() or history.back() != trimmed:
		history.append(trimmed)

	if history.size() > MAX_HISTORY:
		history.pop_front()

	_add_message("<%s> %s" % [GameSettings.username, trimmed])
	_close_chat()


func _set_history(direction: int) -> void:
	if history.is_empty():
		return

	if history_index == -1:
		history_index = history.size()
	
	history_index = clampi(
		history_index + direction,
		0,
		history.size()
	)

	if history_index >= history.size():
		chat_input.text = ""
	else:
		chat_input.text = history[history_index]

	chat_input.caret_column = chat_input.text.length()


func _add_message(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.theme_override_colors/font_outline_color = Color(0, 0, 0, 1)
	label.theme_override_constants/outline_size = 3
	label.theme_override_font_sizes/font_size = 16
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	messages_container.add_child(label)
	messages.append({
		"label": label,
		"time": Time.get_ticks_msec() / 1000.0
	})

	while messages.size() > MAX_VISIBLE_MESSAGES:
		_remove_message(0)


func _remove_message(index: int) -> void:
	if index < 0 or index >= messages.size():
		return

	var entry: Dictionary = messages[index]
	var label: Label = entry["label"]
	label.queue_free()
	messages.remove_at(index)


func _update_message_fades() -> void:
	var now := Time.get_ticks_msec() / 1000.0

	for i in range(messages.size() - 1, -1, -1):
		var entry: Dictionary = messages[i]
		var age: float = now - float(entry["time"])
		var label: Label = entry["label"]

		if chat_open or age <= MESSAGE_LIFETIME:
			label.modulate.a = 1.0
			continue

		var fade_progress := clampf(
			(age - MESSAGE_LIFETIME) / MESSAGE_FADE_TIME,
			0.0,
			1.0
		)

		label.modulate.a = 1.0 - fade_progress

		if fade_progress >= 1.0:
			_remove_message(i)
