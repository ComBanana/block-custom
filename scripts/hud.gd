extends CanvasLayer


@onready var fps_label: Label = $FPSLabel
@onready var coordinate_label: Label = $CoordinateLabel

@onready var player: CharacterBody3D = $"../Player"


func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

	var position := player.global_position

	coordinate_label.text = "XYZ: %d, %d, %d" % [
		floori(position.x),
		floori(position.y),
		floori(position.z)
	]
