extends CanvasLayer


@onready var fps_label: Label = $FPSLabel
@onready var coordinate_label: Label = $CoordinateLabel

@onready var player: CharacterBody3D = $"../Player"
@onready var run_icon: TextureRect = $RunIcon
@onready var hotbar_slots: Array[Panel] = [
	$Hotbar/Slots/Slot1,
	$Hotbar/Slots/Slot2,
	$Hotbar/Slots/Slot3,
	$Hotbar/Slots/Slot4,
	$Hotbar/Slots/Slot5,
	$Hotbar/Slots/Slot6,
	$Hotbar/Slots/Slot7,
	$Hotbar/Slots/Slot8,
	$Hotbar/Slots/Slot9
]

const HOTBAR_ICONS: Array[Texture2D] = [
	preload("res://textures/grass-top.png"),
	preload("res://textures/dirt.png"),
	preload("res://textures/stone.png"),
	preload("res://textures/sand.png"),
	preload("res://textures/water.png")
]

const HOTBAR_NAMES: Array[String] = [
	"Grass",
	"Dirt",
	"Stone",
	"Sand",
	"Water"
]

var last_hotbar_slot: int = -1


func _ready() -> void:
	_build_hotbar()


func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

	var position := player.global_position

	coordinate_label.text = "XYZ: %d, %d, %d" % [
		floori(position.x),
		floori(position.y),
		floori(position.z)
	]

	run_icon.visible = GameSettings.toggle_sprint or player.running

	if player.selected_hotbar_slot != last_hotbar_slot:
		_update_hotbar_selection()



func _hotbar_slot_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = (
		Color(0.36, 0.36, 0.36, 0.96)
		if selected
		else Color(0.12, 0.12, 0.12, 0.92)
	)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = (
		Color(1.0, 1.0, 1.0, 1.0)
		if selected
		else Color(0.45, 0.45, 0.45, 1.0)
	)
	return style


func _build_hotbar() -> void:
	for index in range(hotbar_slots.size()):
		var slot := hotbar_slots[index]
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_theme_stylebox_override(
			"panel",
			_hotbar_slot_style(false)
		)

		if index >= HOTBAR_ICONS.size():
			continue

		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 5.0
		icon.offset_top = 5.0
		icon.offset_right = -5.0
		icon.offset_bottom = -5.0
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.texture = HOTBAR_ICONS[index]
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		slot.add_child(icon)

		var number := Label.new()
		number.name = "Number"
		number.position = Vector2(4.0, 2.0)
		number.size = Vector2(16.0, 16.0)
		number.mouse_filter = Control.MOUSE_FILTER_IGNORE
		number.text = str(index + 1)
		number.add_theme_font_size_override("font_size", 12)
		number.add_theme_color_override("font_color", Color.WHITE)
		number.add_theme_color_override("font_outline_color", Color.BLACK)
		number.add_theme_constant_override("outline_size", 3)
		slot.add_child(number)

	_update_hotbar_selection()


func _update_hotbar_selection() -> void:
	last_hotbar_slot = player.selected_hotbar_slot

	for index in range(hotbar_slots.size()):
		var slot := hotbar_slots[index]
		slot.add_theme_stylebox_override(
			"panel",
			_hotbar_slot_style(index == player.selected_hotbar_slot)
		)
