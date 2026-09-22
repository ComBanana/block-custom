extends Control

@onready var status_label: Label = $Center/Content/Status
@onready var progress_bar: ProgressBar = $Center/Content/ProgressBar


func _ready() -> void:
	progress_bar.min_value = 0.0
	progress_bar.max_value = 100.0
	progress_bar.value = 0.0

	status_label.text = "Generating world data..."


func set_progress(completed: int, total: int) -> void:
	if total <= 0:
		progress_bar.value = 0.0
		status_label.text = "Generating world data..."
		return

	var percentage: float = (
		float(completed) / float(total)
	) * 100.0

	progress_bar.value = percentage

	status_label.text = (
		"Generating world data... %d%%"
		% roundi(percentage)
	)


func finish() -> void:
	status_label.text = "Entering world..."
	progress_bar.value = 100.0

	var tween := create_tween()

	tween.tween_property(
		self,
		"modulate:a",
		0.0,
		0.25
	)

	tween.finished.connect(_on_fade_finished)


func _on_fade_finished() -> void:
	visible = false
	modulate.a = 1.0
