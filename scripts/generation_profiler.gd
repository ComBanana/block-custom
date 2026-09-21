extends RefCounted
class_name GenerationProfiler


var _samples: Dictionary = {}
var _started_usec: int = 0


func _init() -> void:
	reset()


func reset() -> void:
	_samples.clear()
	_started_usec = Time.get_ticks_usec()


func record(
	stage: String,
	milliseconds: float,
	count: int = 1
) -> void:
	if stage == "":
		return

	if not _samples.has(stage):
		_samples[stage] = {
			"count": 0,
			"total_ms": 0.0,
			"max_ms": 0.0
		}

	var sample: Dictionary = _samples[stage]
	sample["count"] = int(sample["count"]) + count
	sample["total_ms"] = float(sample["total_ms"]) + milliseconds
	sample["max_ms"] = maxf(
		float(sample["max_ms"]),
		milliseconds
	)
	_samples[stage] = sample


func get_elapsed_ms() -> float:
	return float(
		Time.get_ticks_usec() - _started_usec
	) / 1000.0


func get_snapshot() -> Dictionary:
	return _samples.duplicate(true)


func get_summary() -> String:
	var lines: Array[String] = []
	lines.append("BlockCraft generation profile")
	lines.append(
		"Elapsed: %.2f ms"
		% get_elapsed_ms()
	)

	var stage_names: Array[String] = []
	for stage in _samples:
		stage_names.append(str(stage))
	stage_names.sort()

	for stage in stage_names:
		var sample: Dictionary = _samples[stage]
		var count: int = int(sample["count"])
		var total_ms: float = float(sample["total_ms"])
		var max_ms: float = float(sample["max_ms"])
		var average_ms: float = (
			total_ms / float(count)
			if count > 0
			else 0.0
		)

		lines.append(
			"%s: %d samples, %.2f ms total, %.2f ms avg, %.2f ms max"
			% [
				stage,
				count,
				total_ms,
				average_ms,
				max_ms
			]
		)

	return "\n".join(lines)
