extends CanvasLayer

@onready var fps_label: Label = $FPSLabel

func _process(_delta: float) -> void:
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
