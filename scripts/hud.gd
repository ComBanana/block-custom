extends CanvasLayer


@onready var fps_label: Label = $FPSLabel
@onready var coordinate_label: Label = $CoordinateLabel

@onready var player: CharacterBody3D = $"../Player"
@onready var run_icon: TextureRect = $RunIcon
@onready var version_label: Label = $VersionLabel


func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

	var position := player.global_position

	coordinate_label.text = "XYZ: %d, %d, %d" % [
		floori(position.x),
		floori(position.y),
		floori(position.z)
	]

	run_icon.visible = GameSettings.toggle_sprint or player.running
	version_label.text = "v%s" % ProjectSettings.get_setting(
		"application/config/version",
		"0.1.0"
	)
