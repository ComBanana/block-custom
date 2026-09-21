extends Control


const MAX_VISIBLE_MESSAGES := 10
const MAX_INPUT_HISTORY := 50
const MAX_CHAT_LOG := 100
const MESSAGE_LIFETIME := 5.0
const MESSAGE_FADE_TIME := 1.5


@onready var player: CharacterBody3D = $"../../Player"
@onready var messages_container: VBoxContainer = $Messages
@onready var chat_history_panel: PanelContainer = $ChatHistoryPanel
@onready var history_scroll: ScrollContainer = $ChatHistoryPanel/Scroll
@onready var history_messages_container: VBoxContainer = $ChatHistoryPanel/Scroll/HistoryMessages
@onready var chat_input_panel: PanelContainer = $ChatInputPanel
@onready var chat_input: LineEdit = $ChatInputPanel/Margin/ChatInput


var chat_open: bool = false
var input_history: Array[String] = []
var history_index: int = -1
var chat_log: Array[String] = []
var recent_messages: Array[Dictionary] = []


func _ready() -> void:
	visible = true
	chat_history_panel.visible = false
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
	chat_history_panel.visible = true
	chat_input_panel.visible = true
	chat_input.text = ""
	history_index = -1
	chat_input.grab_focus()
	chat_input.edit()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.set_chat_active(true)

	_rebuild_full_history()

	for entry in recent_messages:
		var label: Label = entry["label"]
		label.modulate.a = 1.0


func _close_chat() -> void:
	chat_open = false
	chat_history_panel.visible = false
	chat_input_panel.visible = false
	chat_input.release_focus()
	chat_input.text = ""
	history_index = -1
	player.set_chat_active(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_chat_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_ESCAPE:
				_close_chat()
				chat_input.accept_event()
				return

			if event.keycode == KEY_UP:
				_set_input_history(-1)
				chat_input.accept_event()
				return

			if event.keycode == KEY_DOWN:
				_set_input_history(1)
				chat_input.accept_event()
				return


func _on_chat_input_submitted(message: String) -> void:
	var trimmed := message.strip_edges()

	if trimmed == "":
		_close_chat()
		return

	if input_history.is_empty() or input_history.back() != trimmed:
		input_history.append(trimmed)

	if input_history.size() > MAX_INPUT_HISTORY:
		input_history.pop_front()

	var formatted := "<%s> %s" % [
		GameSettings.username,
		trimmed
	]

	chat_log.append(formatted)

	if chat_log.size() > MAX_CHAT_LOG:
		chat_log.pop_front()

	_add_recent_message(formatted)

	if chat_open:
		_rebuild_full_history()

	_close_chat()


func _set_input_history(direction: int) -> void:
	if input_history.is_empty():
		return

	if history_index == -1:
		history_index = input_history.size()

	history_index = clampi(
		history_index + direction,
		0,
		input_history.size()
	)

	if history_index >= input_history.size():
		chat_input.text = ""
	else:
		chat_input.text = input_history[history_index]

	chat_input.caret_column = chat_input.text.length()


func _create_message_label(message: String) -> Label:
	var label := Label.new()
	label.text = message
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override(
		"font_outline_color",
		Color(0, 0, 0, 1)
	)
	label.add_theme_constant_override(
		"outline_size",
		3
	)
	label.add_theme_font_size_override(
		"font_size",
		16
	)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _add_recent_message(message: String) -> void:
	var label := _create_message_label(message)

	messages_container.add_child(label)
	recent_messages.append({
		"label": label,
		"time": Time.get_ticks_msec() / 1000.0
	})

	while recent_messages.size() > MAX_VISIBLE_MESSAGES:
		_remove_recent_message(0)


func _remove_recent_message(index: int) -> void:
	if index < 0 or index >= recent_messages.size():
		return

	var entry: Dictionary = recent_messages[index]
	var label: Label = entry["label"]
	label.queue_free()
	recent_messages.remove_at(index)


func _rebuild_full_history() -> void:
	for child in history_messages_container.get_children():
		child.queue_free()

	for message in chat_log:
		history_messages_container.add_child(
			_create_message_label(message)
		)

	call_deferred("_scroll_history_to_bottom")


func _scroll_history_to_bottom() -> void:
	history_scroll.scroll_vertical = history_scroll.get_v_scroll_bar().max_value


func _update_message_fades() -> void:
	var now := Time.get_ticks_msec() / 1000.0

	for i in range(recent_messages.size() - 1, -1, -1):
		var entry: Dictionary = recent_messages[i]
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
			_remove_recent_message(i)
