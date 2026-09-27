extends Node

# BlockCraft all-round performance recorder.
#
# The recorder samples the game at a fixed, low overhead interval instead of
# saving every frame. Each sample is one rectangular CSV row containing:
# - frame timing and hitch statistics
# - CPU/process and physics timings
# - engine memory/object counts
# - renderer objects/primitives/draw calls
# - renderer/video/texture/buffer memory
# - 3D physics counters
# - pipeline compilation counters
# - BlockCraft streaming/world queues
# - water/block activity
# - every instrumented world phase (sum + max)
#
# At the end of a session it writes:
#   performance_<timestamp>.csv
#       Main table: one row per sample window.
#   performance_<timestamp>_summary.csv
#       Session-level summary table.
#   performance_<timestamp>_phases.csv
#       Session-level phase timing table.
#
# CSV is deliberate: it opens cleanly in Excel/Google Sheets/LibreOffice and
# can be converted to a DataFrame without parsing nested JSON.

const REPORT_ROOT_NAME: String = "BlockCraft"
const REPORT_FOLDER_NAME: String = "performance"

# Four samples per second keeps long recordings small while still catching
# streaming hitches. Individual frame maxima/percentiles are preserved inside
# each sample window.
const SAMPLE_INTERVAL_SECONDS: float = 0.25

# Hard safety cap for the number of retained sample rows. At 4 Hz this is
# roughly 100 minutes of data. Oldest rows are discarded once the cap is hit.
const MAX_SAMPLE_ROWS: int = 24000

const FRAME_HISTOGRAM_BOUNDS: Array[float] = [
	0.5,
	1.0,
	2.0,
	4.0,
	8.0,
	16.67,
	33.33,
	50.0,
	100.0,
	250.0,
	500.0,
	1000.0,
	2000.0
]

const SAMPLE_BASE_HEADERS: Array[String] = [
	"session_id",
	"wall_clock",
	"elapsed_seconds",
	"sample_seconds",
	"sample_index",
	"frames",
	"fps_average",
	"fps_monitor",
	"frame_ms_average",
	"frame_ms_min",
	"frame_ms_p50",
	"frame_ms_p95",
	"frame_ms_p99",
	"frame_ms_max",
	"frames_over_16_67ms",
	"frames_over_33_33ms",
	"frames_over_50ms",
	"frames_over_100ms",
	"process_ms",
	"physics_process_ms",
	"navigation_process_ms",
	"process_cpu_percent_of_frame",
	"physics_cpu_percent_of_frame",
	"memory_static_mb",
	"memory_static_max_mb",
	"message_buffer_max_mb",
	"object_count",
	"resource_count",
	"node_count",
	"orphan_node_count",
	"render_objects",
	"render_primitives",
	"render_draw_calls",
	"video_memory_mb",
	"texture_memory_mb",
	"buffer_memory_mb",
	"physics3d_active_objects",
	"physics3d_collision_pairs",
	"physics3d_islands",
	"audio_output_latency_ms",
	"pipeline_canvas_total",
	"pipeline_mesh_total",
	"pipeline_surface_total",
	"pipeline_draw_total",
	"pipeline_specialization_total",
	"block_actions",
	"block_actions_per_second",
	"water_ticks",
	"water_ticks_per_second",
	"water_updates",
	"water_updates_per_second",
	"chunk_boundary_events",
	"chunk_boundary_total_ms",
	"chunk_boundary_max_ms",
	"chunk_boundary_update_chunks_max_ms",
	"chunk_boundary_render_region_max_ms",
	"chunk_boundary_visual_max_ms",
	"chunk_boundary_collision_range_max_ms",
	"player_chunk_x",
	"player_chunk_z",
	"loaded_chunks",
	"required_chunks",
	"generation_tasks",
	"generation_revisions",
	"mesh_tasks",
	"load_queue",
	"chunk_load_tasks",
	"cached_chunk_data",
	"chunk_release_queue",
	"chunk_reuse_pool",
	"generation_queue",
	"critical_mesh_queue",
	"near_mesh_queue",
	"far_mesh_queue",
	"water_mesh_queue",
	"collision_queue",
	"player_x",
	"player_y",
	"player_z",
	"player_velocity_x",
	"player_velocity_y",
	"player_velocity_z",
	"world_play_time_seconds",
	"world_blocks_broken",
	"world_blocks_placed"
]

var _session_active: bool = false
var _session_saved: bool = false
var _session_start_usec: int = 0
var _session_id: String = ""

var _frame_count: int = 0
var _frame_time_total_ms: float = 0.0
var _frame_time_min_ms: float = INF
var _frame_time_max_ms: float = 0.0
var _frame_histogram: Array[int] = []

var _sample_elapsed_seconds: float = 0.0
var _sample_index: int = 0
var _sample_frame_times: Array[float] = []
var _sample_phase_sums: Dictionary = {}
var _sample_phase_max: Dictionary = {}
var _sample_block_actions: int = 0
var _sample_water_ticks: int = 0
var _sample_water_updates: int = 0
var _sample_chunk_boundary_count: int = 0
var _sample_chunk_boundary_total_ms: float = 0.0
var _sample_chunk_boundary_max_ms: float = 0.0
var _sample_chunk_boundary_update_max_ms: float = 0.0
var _sample_chunk_boundary_render_region_max_ms: float = 0.0
var _sample_chunk_boundary_visual_max_ms: float = 0.0
var _sample_chunk_boundary_collision_max_ms: float = 0.0

var _sample_rows: Array[Dictionary] = []
var _phase_names: Dictionary = {}
var _session_phase_stats: Dictionary = {}
var _session_chunk_boundary_count: int = 0
var _session_chunk_boundary_max_ms: float = 0.0
var _session_peak_metrics: Dictionary = {}

var _block_actions_queued: int = 0
var _water_ticks: int = 0
var _water_updates: int = 0
var _context: Dictionary = {}
var _latest_world_state: Dictionary = {}


func _ready() -> void:
	_reset_frame_histogram()


func _process(delta: float) -> void:
	if not _session_active:
		return

	record_frame(delta)


func _reset_frame_histogram() -> void:
	_frame_histogram = [
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0
	]


func start_session(context: Dictionary) -> void:
	_session_active = true
	_session_saved = false
	_session_start_usec = Time.get_ticks_usec()

	var wall_clock: String = Time.get_datetime_string_from_system(false)
	_session_id = wall_clock.replace(":", "-")

	_frame_count = 0
	_frame_time_total_ms = 0.0
	_frame_time_min_ms = INF
	_frame_time_max_ms = 0.0

	_sample_elapsed_seconds = 0.0
	_sample_index = 0
	_sample_frame_times.clear()
	_sample_phase_sums.clear()
	_sample_phase_max.clear()
	_sample_block_actions = 0
	_sample_water_ticks = 0
	_sample_water_updates = 0
	_reset_sample_chunk_boundary_stats()

	_sample_rows.clear()
	_phase_names.clear()
	_session_phase_stats.clear()
	_session_chunk_boundary_count = 0
	_session_chunk_boundary_max_ms = 0.0
	_session_peak_metrics.clear()

	_block_actions_queued = 0
	_water_ticks = 0
	_water_updates = 0
	_latest_world_state.clear()
	_reset_frame_histogram()

	_context = context.duplicate(true)


func set_world_state(state: Dictionary) -> void:
	if not _session_active:
		return

	_latest_world_state = state.duplicate(true)


func record_frame(delta: float) -> void:
	if not _session_active:
		return

	var frame_ms: float = maxf(delta * 1000.0, 0.0)

	_frame_count += 1
	_frame_time_total_ms += frame_ms
	_frame_time_min_ms = minf(_frame_time_min_ms, frame_ms)
	_frame_time_max_ms = maxf(_frame_time_max_ms, frame_ms)

	var histogram_index: int = _frame_histogram_index(frame_ms)
	_frame_histogram[histogram_index] += 1

	_sample_elapsed_seconds += maxf(delta, 0.0)
	_sample_frame_times.append(frame_ms)

	if _sample_elapsed_seconds >= SAMPLE_INTERVAL_SECONDS:
		_finalize_sample()


func record_phase(phase_name: String, milliseconds: float) -> void:
	if not _session_active or phase_name.is_empty():
		return

	var phase_ms: float = maxf(milliseconds, 0.0)
	_phase_names[phase_name] = true

	var sample_sum_ms: float = float(
		_sample_phase_sums.get(phase_name, 0.0)
	)
	_sample_phase_sums[phase_name] = sample_sum_ms + phase_ms

	var sample_max_ms: float = float(
		_sample_phase_max.get(phase_name, 0.0)
	)
	_sample_phase_max[phase_name] = maxf(sample_max_ms, phase_ms)

	var session_sample: Dictionary = {}
	if _session_phase_stats.has(phase_name):
		session_sample = _session_phase_stats[phase_name]

	var count: int = int(session_sample.get("count", 0)) + 1
	var total_ms: float = (
		float(session_sample.get("total_ms", 0.0))
		+ phase_ms
	)
	var max_ms: float = maxf(
		float(session_sample.get("max_ms", 0.0)),
		phase_ms
	)

	_session_phase_stats[phase_name] = {
		"count": count,
		"total_ms": total_ms,
		"max_ms": max_ms
	}


func record_chunk_boundary(
	from_chunk: Vector2i,
	to_chunk: Vector2i,
	frame_delta: float,
	update_chunks_ms: float,
	render_region_ms: float,
	boundary_visual_ms: float,
	collision_range_ms: float,
	total_boundary_ms: float,
	boundary_change_count: int,
	state: Dictionary
) -> void:
	if not _session_active:
		return

	var total_ms: float = maxf(total_boundary_ms, 0.0)
	_sample_chunk_boundary_count += 1
	_sample_chunk_boundary_total_ms += total_ms
	_sample_chunk_boundary_max_ms = maxf(
		_sample_chunk_boundary_max_ms,
		total_ms
	)
	_sample_chunk_boundary_update_max_ms = maxf(
		_sample_chunk_boundary_update_max_ms,
		maxf(update_chunks_ms, 0.0)
	)
	_sample_chunk_boundary_render_region_max_ms = maxf(
		_sample_chunk_boundary_render_region_max_ms,
		maxf(render_region_ms, 0.0)
	)
	_sample_chunk_boundary_visual_max_ms = maxf(
		_sample_chunk_boundary_visual_max_ms,
		maxf(boundary_visual_ms, 0.0)
	)
	_sample_chunk_boundary_collision_max_ms = maxf(
		_sample_chunk_boundary_collision_max_ms,
		maxf(collision_range_ms, 0.0)
	)

	_session_chunk_boundary_count += 1
	_session_chunk_boundary_max_ms = maxf(
		_session_chunk_boundary_max_ms,
		total_ms
	)


func record_block_action() -> void:
	if not _session_active:
		return

	_block_actions_queued += 1
	_sample_block_actions += 1


func record_water_tick(processed_updates: int) -> void:
	if not _session_active:
		return

	var update_count: int = maxi(processed_updates, 0)
	_water_ticks += 1
	_water_updates += update_count
	_sample_water_ticks += 1
	_sample_water_updates += update_count


func finish_session(extra: Dictionary = {}) -> String:
	if not _session_active or _session_saved:
		return ""

	# Include the final partial sample in the table.
	if not _sample_frame_times.is_empty():
		_finalize_sample()

	_session_saved = true
	_session_active = false

	var paths: Dictionary = _write_reports(extra)
	var sample_path: String = str(paths.get("samples", ""))

	if not sample_path.is_empty():
		print("BlockCraft performance samples saved to: " + sample_path)

	var summary_path: String = str(paths.get("summary", ""))
	if not summary_path.is_empty():
		print("BlockCraft performance summary saved to: " + summary_path)

	var phase_path: String = str(paths.get("phases", ""))
	if not phase_path.is_empty():
		print("BlockCraft performance phase table saved to: " + phase_path)

	return sample_path


func _finalize_sample() -> void:
	if _sample_frame_times.is_empty():
		return

	var sample_seconds: float = maxf(
		_sample_elapsed_seconds,
		0.000001
	)

	var frames: int = _sample_frame_times.size()
	var sample_frame_total_ms: float = 0.0
	var sample_frame_min_ms: float = INF
	var sample_frame_max_ms: float = 0.0
	var frames_over_16_67: int = 0
	var frames_over_33_33: int = 0
	var frames_over_50: int = 0
	var frames_over_100: int = 0

	for frame_ms in _sample_frame_times:
		sample_frame_total_ms += frame_ms
		sample_frame_min_ms = minf(sample_frame_min_ms, frame_ms)
		sample_frame_max_ms = maxf(sample_frame_max_ms, frame_ms)

		if frame_ms > 16.67:
			frames_over_16_67 += 1
		if frame_ms > 33.33:
			frames_over_33_33 += 1
		if frame_ms > 50.0:
			frames_over_50 += 1
		if frame_ms > 100.0:
			frames_over_100 += 1

	var sorted_frame_times: Array[float] = _sample_frame_times.duplicate()
	sorted_frame_times.sort()

	var frame_average_ms: float = sample_frame_total_ms / float(frames)
	var average_fps: float = float(frames) / sample_seconds
	var fps_monitor: float = _monitor_float(
		Performance.TIME_FPS
	)

	var snapshot: Dictionary = _performance_snapshot()
	_update_peak_metrics(snapshot)

	var row: Dictionary = {
		"session_id": _session_id,
		"wall_clock": Time.get_datetime_string_from_system(false),
		"elapsed_seconds": (
			float(Time.get_ticks_usec() - _session_start_usec)
			/ 1000000.0
		),
		"sample_seconds": sample_seconds,
		"sample_index": _sample_index + 1,
		"frames": frames,
		"fps_average": average_fps,
		"fps_monitor": fps_monitor,
		"frame_ms_average": frame_average_ms,
		"frame_ms_min": sample_frame_min_ms,
		"frame_ms_p50": _percentile(
			sorted_frame_times,
			0.50
		),
		"frame_ms_p95": _percentile(
			sorted_frame_times,
			0.95
		),
		"frame_ms_p99": _percentile(
			sorted_frame_times,
			0.99
		),
		"frame_ms_max": sample_frame_max_ms,
		"frames_over_16_67ms": frames_over_16_67,
		"frames_over_33_33ms": frames_over_33_33,
		"frames_over_50ms": frames_over_50,
		"frames_over_100ms": frames_over_100,
		"process_ms": _ms_monitor(
			Performance.TIME_PROCESS
		),
		"physics_process_ms": _ms_monitor(
			Performance.TIME_PHYSICS_PROCESS
		),
		"navigation_process_ms": _ms_monitor(
			Performance.TIME_NAVIGATION_PROCESS
		),
		"process_cpu_percent_of_frame": _ratio_percent(
			_ms_monitor(Performance.TIME_PROCESS),
			frame_average_ms
		),
		"physics_cpu_percent_of_frame": _ratio_percent(
			_ms_monitor(Performance.TIME_PHYSICS_PROCESS),
			frame_average_ms
		),
		"memory_static_mb": _bytes_to_mb(
			_monitor_float(Performance.MEMORY_STATIC)
		),
		"memory_static_max_mb": _bytes_to_mb(
			_monitor_float(Performance.MEMORY_STATIC_MAX)
		),
		"message_buffer_max_mb": _bytes_to_mb(
			_monitor_float(Performance.MEMORY_MESSAGE_BUFFER_MAX)
		),
		"object_count": _monitor_int(
			Performance.OBJECT_COUNT
		),
		"resource_count": _monitor_int(
			Performance.OBJECT_RESOURCE_COUNT
		),
		"node_count": _monitor_int(
			Performance.OBJECT_NODE_COUNT
		),
		"orphan_node_count": _monitor_int(
			Performance.OBJECT_ORPHAN_NODE_COUNT
		),
		"render_objects": _monitor_int(
			Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
		),
		"render_primitives": _monitor_int(
			Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
		),
		"render_draw_calls": _monitor_int(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		),
		"video_memory_mb": _bytes_to_mb(
			_monitor_float(Performance.RENDER_VIDEO_MEM_USED)
		),
		"texture_memory_mb": _bytes_to_mb(
			_monitor_float(Performance.RENDER_TEXTURE_MEM_USED)
		),
		"buffer_memory_mb": _bytes_to_mb(
			_monitor_float(Performance.RENDER_BUFFER_MEM_USED)
		),
		"physics3d_active_objects": _monitor_int(
			Performance.PHYSICS_3D_ACTIVE_OBJECTS
		),
		"physics3d_collision_pairs": _monitor_int(
			Performance.PHYSICS_3D_COLLISION_PAIRS
		),
		"physics3d_islands": _monitor_int(
			Performance.PHYSICS_3D_ISLAND_COUNT
		),
		"audio_output_latency_ms": _ms_monitor(
			Performance.AUDIO_OUTPUT_LATENCY
		),
		"pipeline_canvas_total": _monitor_int(
			Performance.PIPELINE_COMPILATIONS_CANVAS
		),
		"pipeline_mesh_total": _monitor_int(
			Performance.PIPELINE_COMPILATIONS_MESH
		),
		"pipeline_surface_total": _monitor_int(
			Performance.PIPELINE_COMPILATIONS_SURFACE
		),
		"pipeline_draw_total": _monitor_int(
			Performance.PIPELINE_COMPILATIONS_DRAW
		),
		"pipeline_specialization_total": _monitor_int(
			Performance.PIPELINE_COMPILATIONS_SPECIALIZATION
		),
		"block_actions": _sample_block_actions,
		"block_actions_per_second": (
			float(_sample_block_actions) / sample_seconds
		),
		"water_ticks": _sample_water_ticks,
		"water_ticks_per_second": (
			float(_sample_water_ticks) / sample_seconds
		),
		"water_updates": _sample_water_updates,
		"water_updates_per_second": (
			float(_sample_water_updates) / sample_seconds
		),
		"chunk_boundary_events": _sample_chunk_boundary_count,
		"chunk_boundary_total_ms": _sample_chunk_boundary_total_ms,
		"chunk_boundary_max_ms": _sample_chunk_boundary_max_ms,
		"chunk_boundary_update_chunks_max_ms": (
			_sample_chunk_boundary_update_max_ms
		),
		"chunk_boundary_render_region_max_ms": (
			_sample_chunk_boundary_render_region_max_ms
		),
		"chunk_boundary_visual_max_ms": (
			_sample_chunk_boundary_visual_max_ms
		),
		"chunk_boundary_collision_range_max_ms": (
			_sample_chunk_boundary_collision_max_ms
		)
	}

	_add_world_state_columns(row)
	_add_phase_columns(row)

	_sample_rows.append(row)
	if _sample_rows.size() > MAX_SAMPLE_ROWS:
		_sample_rows.pop_front()

	_sample_index += 1
	_sample_elapsed_seconds = 0.0
	_sample_frame_times.clear()
	_sample_phase_sums.clear()
	_sample_phase_max.clear()
	_sample_block_actions = 0
	_sample_water_ticks = 0
	_sample_water_updates = 0
	_reset_sample_chunk_boundary_stats()


func _add_world_state_columns(row: Dictionary) -> void:
	var state: Dictionary = _latest_world_state

	var player_chunk: Array = state.get(
		"player_chunk",
		[0, 0]
	) as Array
	var player_position: Array = state.get(
		"player_position",
		[0.0, 0.0, 0.0]
	) as Array
	var player_velocity: Array = state.get(
		"player_velocity",
		[0.0, 0.0, 0.0]
	) as Array

	row["player_chunk_x"] = (
		int(player_chunk[0])
		if player_chunk.size() >= 2
		else 0
	)
	row["player_chunk_z"] = (
		int(player_chunk[1])
		if player_chunk.size() >= 2
		else 0
	)

	var scalar_keys: Array[String] = [
		"loaded_chunks",
		"required_chunks",
		"generation_tasks",
		"generation_revisions",
		"mesh_tasks",
		"load_queue",
		"chunk_load_tasks",
		"cached_chunk_data",
		"chunk_release_queue",
		"chunk_reuse_pool",
		"generation_queue",
		"critical_mesh_queue",
		"near_mesh_queue",
		"far_mesh_queue",
		"water_mesh_queue",
		"collision_queue"
	]

	for key in scalar_keys:
		row[key] = int(state.get(key, 0))

	row["player_x"] = (
		float(player_position[0])
		if player_position.size() >= 3
		else 0.0
	)
	row["player_y"] = (
		float(player_position[1])
		if player_position.size() >= 3
		else 0.0
	)
	row["player_z"] = (
		float(player_position[2])
		if player_position.size() >= 3
		else 0.0
	)

	row["player_velocity_x"] = (
		float(player_velocity[0])
		if player_velocity.size() >= 3
		else 0.0
	)
	row["player_velocity_y"] = (
		float(player_velocity[1])
		if player_velocity.size() >= 3
		else 0.0
	)
	row["player_velocity_z"] = (
		float(player_velocity[2])
		if player_velocity.size() >= 3
		else 0.0
	)

	row["world_play_time_seconds"] = float(
		state.get("play_time_seconds", 0.0)
	)
	row["world_blocks_broken"] = int(
		state.get("blocks_broken", 0)
	)
	row["world_blocks_placed"] = int(
		state.get("blocks_placed", 0)
	)


func _add_phase_columns(row: Dictionary) -> void:
	for phase_name in _phase_names.keys():
		var phase_key: String = str(phase_name)
		var column_name: String = _phase_column_name(
			phase_key,
			"sum"
		)
		row[column_name] = float(
			_sample_phase_sums.get(phase_key, 0.0)
		)

		column_name = _phase_column_name(
			phase_key,
			"max"
		)
		row[column_name] = float(
			_sample_phase_max.get(phase_key, 0.0)
		)


func _phase_column_name(
	phase_name: String,
	stat_name: String
) -> String:
	var safe_name: String = phase_name
	safe_name = safe_name.replace("/", "_")
	safe_name = safe_name.replace("\\", "_")
	safe_name = safe_name.replace(" ", "_")
	safe_name = safe_name.replace(".", "_")
	safe_name = safe_name.replace(":", "_")
	return "phase_" + safe_name + "_" + stat_name + "_ms"


func _performance_snapshot() -> Dictionary:
	return {
		"memory_static_mb": _bytes_to_mb(
			_monitor_float(Performance.MEMORY_STATIC)
		),
		"memory_static_max_mb": _bytes_to_mb(
			_monitor_float(Performance.MEMORY_STATIC_MAX)
		),
		"object_count": _monitor_int(Performance.OBJECT_COUNT),
		"node_count": _monitor_int(Performance.OBJECT_NODE_COUNT),
		"orphan_node_count": _monitor_int(
			Performance.OBJECT_ORPHAN_NODE_COUNT
		),
		"render_objects": _monitor_int(
			Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
		),
		"render_primitives": _monitor_int(
			Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
		),
		"render_draw_calls": _monitor_int(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		),
		"video_memory_mb": _bytes_to_mb(
			_monitor_float(Performance.RENDER_VIDEO_MEM_USED)
		),
		"texture_memory_mb": _bytes_to_mb(
			_monitor_float(Performance.RENDER_TEXTURE_MEM_USED)
		),
		"buffer_memory_mb": _bytes_to_mb(
			_monitor_float(Performance.RENDER_BUFFER_MEM_USED)
		),
		"physics3d_active_objects": _monitor_int(
			Performance.PHYSICS_3D_ACTIVE_OBJECTS
		),
		"physics3d_collision_pairs": _monitor_int(
			Performance.PHYSICS_3D_COLLISION_PAIRS
		),
		"physics3d_islands": _monitor_int(
			Performance.PHYSICS_3D_ISLAND_COUNT
		)
	}


func _update_peak_metrics(snapshot: Dictionary) -> void:
	for key in snapshot.keys():
		var metric_name: String = str(key)
		var value: float = float(snapshot[key])
		var current_peak: float = float(
			_session_peak_metrics.get(metric_name, -INF)
		)
		_session_peak_metrics[metric_name] = maxf(
			current_peak,
			value
		)


func _build_sample_headers() -> Array[String]:
	var headers: Array[String] = SAMPLE_BASE_HEADERS.duplicate()

	var phase_names: Array[String] = []
	for phase_name in _phase_names.keys():
		phase_names.append(str(phase_name))
	phase_names.sort()

	for phase_name in phase_names:
		headers.append(
			_phase_column_name(phase_name, "sum")
		)
		headers.append(
			_phase_column_name(phase_name, "max")
		)

	return headers


func _build_summary_rows(extra: Dictionary) -> Array[Array]:
	var elapsed_ms: float = float(
		Time.get_ticks_usec() - _session_start_usec
	) / 1000.0

	var average_ms: float = (
		_frame_time_total_ms / float(_frame_count)
		if _frame_count > 0
		else 0.0
	)

	var average_fps: float = (
		1000.0 / average_ms
		if average_ms > 0.0
		else 0.0
	)

	var rows: Array[Array] = []

	_append_summary(
		rows,
		"session",
		"elapsed_seconds",
		elapsed_ms / 1000.0,
		"seconds"
	)
	_append_summary(
		rows,
		"session",
		"frames",
		_frame_count,
		"frames"
	)
	_append_summary(
		rows,
		"session",
		"samples_retained",
		_sample_rows.size(),
		"rows"
	)
	_append_summary(
		rows,
		"frame_time",
		"average_ms",
		average_ms,
		"ms"
	)
	_append_summary(
		rows,
		"frame_time",
		"min_ms",
		_frame_time_min_ms if _frame_count > 0 else 0.0,
		"ms"
	)
	_append_summary(
		rows,
		"frame_time",
		"max_ms",
		_frame_time_max_ms,
		"ms"
	)
	_append_summary(
		rows,
		"frame_time",
		"p50_ms_approx",
		_histogram_percentile_ms(0.50),
		"ms"
	)
	_append_summary(
		rows,
		"frame_time",
		"p95_ms_approx",
		_histogram_percentile_ms(0.95),
		"ms"
	)
	_append_summary(
		rows,
		"frame_time",
		"p99_ms_approx",
		_histogram_percentile_ms(0.99),
		"ms"
	)
	_append_summary(
		rows,
		"fps",
		"average",
		average_fps,
		"fps"
	)
	_append_summary(
		rows,
		"activity",
		"block_actions_total",
		_block_actions_queued,
		"actions"
	)
	_append_summary(
		rows,
		"activity",
		"water_ticks_total",
		_water_ticks,
		"ticks"
	)
	_append_summary(
		rows,
		"activity",
		"water_updates_total",
		_water_updates,
		"updates"
	)
	_append_summary(
		rows,
		"chunk_boundary",
		"events_total",
		_session_chunk_boundary_count,
		"events"
	)
	_append_summary(
		rows,
		"chunk_boundary",
		"max_total_ms",
		_session_chunk_boundary_max_ms,
		"ms"
	)

	for key in _session_peak_metrics.keys():
		var metric_name: String = str(key)
		_append_summary(
			rows,
			"peak",
			metric_name,
			_session_peak_metrics[metric_name],
			"peak"
		)

	var context_keys: Array[String] = []
	for key in _context.keys():
		context_keys.append(str(key))
	context_keys.sort()

	for key in context_keys:
		_append_summary(
			rows,
			"context",
			key,
			_context.get(key, ""),
			"value"
		)

	for key in extra.keys():
		_append_summary(
			rows,
			"extra",
			str(key),
			extra.get(key, ""),
			"value"
		)

	return rows


func _append_summary(
	rows: Array[Array],
	category: String,
	metric: String,
	value: Variant,
	unit: String
) -> void:
	rows.append([
		category,
		metric,
		value,
		unit
	])


func _build_phase_rows() -> Array[Array]:
	var rows: Array[Array] = []
	var phase_names: Array[String] = []

	for phase_name in _session_phase_stats.keys():
		phase_names.append(str(phase_name))
	phase_names.sort()

	for phase_name in phase_names:
		var stats: Dictionary = _session_phase_stats[phase_name]
		var count: int = int(stats.get("count", 0))
		var total_ms: float = float(stats.get("total_ms", 0.0))
		var max_ms: float = float(stats.get("max_ms", 0.0))
		var average_ms: float = (
			total_ms / float(count)
			if count > 0
			else 0.0
		)

		rows.append([
			phase_name,
			count,
			total_ms,
			average_ms,
			max_ms
		])

	return rows


func _write_reports(extra: Dictionary) -> Dictionary:
	var directory: String = _report_directory()
	var make_directory_error: Error = (
		DirAccess.make_dir_recursive_absolute(directory)
	)

	if (
		make_directory_error != OK
		and make_directory_error != ERR_ALREADY_EXISTS
	):
		push_error(
			"Could not create performance report directory: "
			+ str(make_directory_error)
		)
		return {}


	var timestamp: String = (
		Time.get_datetime_string_from_system(false)
		.replace(":", "-")
	)
	var base_path: String = directory.path_join(
		"performance_" + timestamp
	)

	var sample_path: String = base_path + ".csv"
	var summary_path: String = base_path + "_summary.csv"
	var phase_path: String = base_path + "_phases.csv"

	if not _write_sample_csv(sample_path):
		return {}

	if not _write_summary_csv(summary_path, extra):
		return {}

	if not _write_phase_csv(phase_path):
		return {}

	return {
		"samples": sample_path,
		"summary": summary_path,
		"phases": phase_path
	}


func _write_sample_csv(file_path: String) -> bool:
	var file: FileAccess = FileAccess.open(
		file_path,
		FileAccess.WRITE
	)

	if file == null:
		push_error(
			"Could not open performance sample table for writing: "
			+ file_path
		)
		return false

	var headers: Array[String] = _build_sample_headers()
	_write_csv_row(file, headers)

	for row in _sample_rows:
		var cells: Array[Variant] = []
		for header in headers:
			cells.append(row.get(header, ""))
		_write_csv_row(file, cells)

	file.close()
	return true


func _write_summary_csv(
	file_path: String,
	extra: Dictionary
) -> bool:
	var file: FileAccess = FileAccess.open(
		file_path,
		FileAccess.WRITE
	)

	if file == null:
		push_error(
			"Could not open performance summary table for writing: "
			+ file_path
		)
		return false

	_write_csv_row(
		file,
		[
			"category",
			"metric",
			"value",
			"unit"
		]
	)

	var rows: Array[Array] = _build_summary_rows(extra)
	for row in rows:
		_write_csv_row(file, row)

	file.close()
	return true


func _write_phase_csv(file_path: String) -> bool:
	var file: FileAccess = FileAccess.open(
		file_path,
		FileAccess.WRITE
	)

	if file == null:
		push_error(
			"Could not open performance phase table for writing: "
			+ file_path
		)
		return false

	_write_csv_row(
		file,
		[
			"phase",
			"calls",
			"total_ms",
			"average_ms",
			"max_ms"
		]
	)

	var rows: Array[Array] = _build_phase_rows()
	for row in rows:
		_write_csv_row(file, row)

	file.close()
	return true


func _write_csv_row(
	file: FileAccess,
	values: Array
) -> void:
	var cells: PackedStringArray = PackedStringArray()

	for value in values:
		cells.append(_csv_escape(value))

	file.store_string(",".join(cells) + "\n")


func _csv_escape(value: Variant) -> String:
	var text_value: String = str(value)
	text_value = text_value.replace('"', '""')

	return '"' + text_value + '"'


func _frame_histogram_index(frame_ms: float) -> int:
	if frame_ms < FRAME_HISTOGRAM_BOUNDS[0]:
		return 0

	for index in range(1, FRAME_HISTOGRAM_BOUNDS.size()):
		if frame_ms < FRAME_HISTOGRAM_BOUNDS[index]:
			return index

	return FRAME_HISTOGRAM_BOUNDS.size()


func _histogram_percentile_ms(percentile: float) -> float:
	if _frame_count <= 0:
		return 0.0

	var clamped_percentile: float = clampf(
		percentile,
		0.0,
		1.0
	)

	var target_frame: int = maxi(
		1,
		ceili(float(_frame_count) * clamped_percentile)
	)
	var cumulative: int = 0

	for index in range(_frame_histogram.size()):
		cumulative += _frame_histogram[index]
		if cumulative >= target_frame:
			if index < FRAME_HISTOGRAM_BOUNDS.size():
				return FRAME_HISTOGRAM_BOUNDS[index]
			return FRAME_HISTOGRAM_BOUNDS[
				FRAME_HISTOGRAM_BOUNDS.size() - 1
			]

	return FRAME_HISTOGRAM_BOUNDS[
		FRAME_HISTOGRAM_BOUNDS.size() - 1
	]


func _percentile(
	sorted_values: Array[float],
	percentile: float
) -> float:
	if sorted_values.is_empty():
		return 0.0

	var clamped_percentile: float = clampf(
		percentile,
		0.0,
		1.0
	)

	var index: int = clampi(
		ceili(
			float(sorted_values.size()) * clamped_percentile
		) - 1,
		0,
		sorted_values.size() - 1
	)

	return sorted_values[index]


func _monitor_float(
	monitor: Performance.Monitor
) -> float:
	return float(Performance.get_monitor(monitor))


func _monitor_int(
	monitor: Performance.Monitor
) -> int:
	return int(Performance.get_monitor(monitor))


func _ms_monitor(
	monitor: Performance.Monitor
) -> float:
	return _monitor_float(monitor) * 1000.0


func _bytes_to_mb(bytes: float) -> float:
	return bytes / (1024.0 * 1024.0)


func _ratio_percent(
	numerator: float,
	denominator: float
) -> float:
	if denominator <= 0.0:
		return 0.0

	return (numerator / denominator) * 100.0


func _reset_sample_chunk_boundary_stats() -> void:
	_sample_chunk_boundary_count = 0
	_sample_chunk_boundary_total_ms = 0.0
	_sample_chunk_boundary_max_ms = 0.0
	_sample_chunk_boundary_update_max_ms = 0.0
	_sample_chunk_boundary_render_region_max_ms = 0.0
	_sample_chunk_boundary_visual_max_ms = 0.0
	_sample_chunk_boundary_collision_max_ms = 0.0


func _update_peak_metrics(snapshot: Dictionary) -> void:
	for key in snapshot.keys():
		var metric_name: String = str(key)
		var value: float = float(snapshot[key])
		var current_peak: float = float(
			_session_peak_metrics.get(metric_name, -INF)
		)

		_session_peak_metrics[metric_name] = maxf(
			current_peak,
			value
		)


func _report_directory() -> String:
	var appdata: String = OS.get_environment("APPDATA")
	if appdata.is_empty():
		return "user://BlockCraft/performance"

	return appdata.path_join(REPORT_ROOT_NAME).path_join(
		REPORT_FOLDER_NAME
	)
