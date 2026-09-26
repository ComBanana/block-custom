extends Node

# BlockCraft performance recorder.
# This is intentionally an autoload so it can observe frame timing for the
# whole gameplay session and write the finished report automatically when
# the World scene exits.

const REPORT_ROOT_NAME: String = "BlockCraft"
const REPORT_FOLDER_NAME: String = "performance"
const TOP_SPIKE_COUNT: int = 100
const PHASE_STAT_KEYS: Array[String] = [
    "count",
    "total_ms",
    "max_ms"
]

var _session_active: bool = false
var _session_saved: bool = false
var _session_start_usec: int = 0
var _frame_count: int = 0
var _frame_time_total_ms: float = 0.0
var _frame_time_min_ms: float = INF
var _frame_time_max_ms: float = 0.0
var _frame_histogram: Array[int] = []
var _top_spikes: Array[Dictionary] = []
var _chunk_crossings: Array[Dictionary] = []
var _phase_stats: Dictionary = {}
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
    # 0-0.5, 0.5-1, 1-2, 2-4, 4-8, 8-16, 16-33, 33-50,
    # 50-100, 100-250, 250-500, 500-1000, 1000+ milliseconds.
    _frame_histogram = [
        0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0
    ]


func start_session(context: Dictionary) -> void:
    _session_active = true
    _session_saved = false
    _session_start_usec = Time.get_ticks_usec()
    _frame_count = 0
    _frame_time_total_ms = 0.0
    _frame_time_min_ms = INF
    _frame_time_max_ms = 0.0
    _top_spikes.clear()
    _chunk_crossings.clear()
    _phase_stats.clear()
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

    # Keep only the worst frames. We do not store every frame because a
    # 10-minute session at very high FPS would otherwise create a huge file.
    if frame_ms >= 8.0 or _top_spikes.size() < 10:
        var entry: Dictionary = {
            "frame": _frame_count,
            "frame_ms": frame_ms,
            "fps_equivalent": (
                1000.0 / frame_ms
                if frame_ms > 0.0
                else 0.0
            ),
            "world_state": _latest_world_state.duplicate(true),
            "performance": _performance_snapshot()
        }
        _insert_top_entry(_top_spikes, entry)


func record_phase(phase_name: String, milliseconds: float) -> void:
    if not _session_active or phase_name.is_empty():
        return

    var phase_ms: float = maxf(milliseconds, 0.0)
    var sample: Dictionary

    if _phase_stats.has(phase_name):
        sample = _phase_stats[phase_name]
    else:
        sample = {}
        for key in PHASE_STAT_KEYS:
            sample[key] = 0

    sample["count"] = int(sample["count"]) + 1
    sample["total_ms"] = float(sample["total_ms"]) + phase_ms
    sample["max_ms"] = maxf(
        float(sample["max_ms"]),
        phase_ms
    )
    _phase_stats[phase_name] = sample


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

    var dx: int = to_chunk.x - from_chunk.x
    var dz: int = to_chunk.y - from_chunk.y

    var event: Dictionary = {
        "event": _chunk_crossings.size() + 1,
        "from_chunk": [from_chunk.x, from_chunk.y],
        "to_chunk": [to_chunk.x, to_chunk.y],
        "chunk_delta": [dx, dz],
        "frame_delta_ms": maxf(frame_delta * 1000.0, 0.0),
        "boundary_total_ms": maxf(total_boundary_ms, 0.0),
        "update_chunks_ms": maxf(update_chunks_ms, 0.0),
        "render_region_update_ms": maxf(render_region_ms, 0.0),
        "boundary_visual_ms": maxf(boundary_visual_ms, 0.0),
        "collision_range_ms": maxf(collision_range_ms, 0.0),
        "boundary_changes": boundary_change_count,
        "state": state.duplicate(true),
        "performance": _performance_snapshot()
    }

    _chunk_crossings.append(event)

    if _chunk_crossings.size() > TOP_SPIKE_COUNT:
        _chunk_crossings.pop_front()


func record_block_action() -> void:
    if not _session_active:
        return

    _block_actions_queued += 1


func record_water_tick(processed_updates: int) -> void:
    if not _session_active:
        return

    _water_ticks += 1
    _water_updates += maxi(processed_updates, 0)


func finish_session(extra: Dictionary = {}) -> String:
    if not _session_active or _session_saved:
        return ""

    _session_saved = true
    _session_active = false

    var report: Dictionary = _build_report(extra)
    var report_path: String = _write_report(report)

    if not report_path.is_empty():
        print("BlockCraft performance report saved to: " + report_path)

    return report_path


func _build_report(extra: Dictionary) -> Dictionary:
    var elapsed_ms: float = (
        float(Time.get_ticks_usec() - _session_start_usec)
        / 1000.0
    )

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

    var report: Dictionary = {
        "format": "blockcraft-performance-v1",
        "generated_at": Time.get_datetime_string_from_system(false),
        "session": {
            "elapsed_ms": elapsed_ms,
            "frames": _frame_count,
            "average_fps": average_fps,
            "average_frame_ms": average_ms,
            "min_frame_ms": (
                _frame_time_min_ms
                if _frame_count > 0
                else 0.0
            ),
            "max_frame_ms": _frame_time_max_ms,
            "frame_time_percentiles_ms": {
                "p50": _histogram_percentile_ms(0.50),
                "p95": _histogram_percentile_ms(0.95),
                "p99": _histogram_percentile_ms(0.99)
            },
            "frame_time_histogram_ms": {
                "0-0.5": _frame_histogram[0],
                "0.5-1": _frame_histogram[1],
                "1-2": _frame_histogram[2],
                "2-4": _frame_histogram[3],
                "4-8": _frame_histogram[4],
                "8-16": _frame_histogram[5],
                "16-33": _frame_histogram[6],
                "33-50": _frame_histogram[7],
                "50-100": _frame_histogram[8],
                "100-250": _frame_histogram[9],
                "250-500": _frame_histogram[10],
                "500-1000": _frame_histogram[11],
                "1000+": _frame_histogram[12]
            }
        },
        "context": _context.duplicate(true),
        "activity": {
            "block_actions_queued": _block_actions_queued,
            "water_ticks": _water_ticks,
            "water_updates": _water_updates
        },
        "phase_timings": _phase_stats.duplicate(true),
        "chunk_boundary_events": _chunk_crossings.duplicate(true),
        "worst_frame_samples": _top_spikes.duplicate(true)
    }

    if not extra.is_empty():
        report["extra"] = extra.duplicate(true)

    return report


func _frame_histogram_index(frame_ms: float) -> int:
    if frame_ms < 0.5:
        return 0
    if frame_ms < 1.0:
        return 1
    if frame_ms < 2.0:
        return 2
    if frame_ms < 4.0:
        return 3
    if frame_ms < 8.0:
        return 4
    if frame_ms < 16.0:
        return 5
    if frame_ms < 33.0:
        return 6
    if frame_ms < 50.0:
        return 7
    if frame_ms < 100.0:
        return 8
    if frame_ms < 250.0:
        return 9
    if frame_ms < 500.0:
        return 10
    if frame_ms < 1000.0:
        return 11

    return 12


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

    var bounds: Array[float] = [
        0.5, 1.0, 2.0, 4.0, 8.0, 16.0,
        33.0, 50.0, 100.0, 250.0, 500.0,
        1000.0, 2000.0
    ]

    for index in range(_frame_histogram.size()):
        cumulative += _frame_histogram[index]
        if cumulative >= target_frame:
            return bounds[index]

    return bounds[bounds.size() - 1]


func _insert_top_entry(
    entries: Array[Dictionary],
    entry: Dictionary
) -> void:
    entries.append(entry)
    entries.sort_custom(_sort_by_frame_ms_desc)

    if entries.size() > TOP_SPIKE_COUNT:
        entries.resize(TOP_SPIKE_COUNT)


func _sort_by_frame_ms_desc(
    left: Dictionary,
    right: Dictionary
) -> bool:
    return float(left.get("frame_ms", 0.0)) > float(
        right.get("frame_ms", 0.0)
    )


func _performance_snapshot() -> Dictionary:
    return {
        "engine_process_ms": float(
            Performance.get_monitor(
                Performance.TIME_PROCESS
            )
        ) * 1000.0,
        "physics_process_ms": float(
            Performance.get_monitor(
                Performance.TIME_PHYSICS_PROCESS
            )
        ) * 1000.0,
        "render_objects": int(
            Performance.get_monitor(
                Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
            )
        ),
        "render_primitives": int(
            Performance.get_monitor(
                Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
            )
        ),
        "render_draw_calls": int(
            Performance.get_monitor(
                Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
            )
        ),
        "video_memory_bytes": int(
            Performance.get_monitor(
                Performance.RENDER_VIDEO_MEM_USED
            )
        ),
        "buffer_memory_bytes": int(
            Performance.get_monitor(
                Performance.RENDER_BUFFER_MEM_USED
            )
        )
    }


func _report_directory() -> String:
    var appdata: String = OS.get_environment("APPDATA")
    if appdata.is_empty():
        return "user://BlockCraft/performance"

    return appdata.path_join(REPORT_ROOT_NAME).path_join(
        REPORT_FOLDER_NAME
    )


func _write_report(report: Dictionary) -> String:
    var directory: String = _report_directory()
    var make_directory_error: Error = (
        DirAccess.make_dir_recursive_absolute(directory)
    )

    if make_directory_error != OK and make_directory_error != ERR_ALREADY_EXISTS:
        push_error(
            "Could not create performance report directory: "
            + str(make_directory_error)
        )
        return ""

    var timestamp: String = (
        Time.get_datetime_string_from_system(false)
        .replace(":", "-")
    )
    var file_path: String = directory.path_join(
        "performance_" + timestamp + ".json"
    )

    var file: FileAccess = FileAccess.open(
        file_path,
        FileAccess.WRITE
    )

    if file == null:
        push_error(
            "Could not open performance report for writing: "
            + file_path
        )
        return ""

    file.store_string(
        JSON.stringify(report, "\t")
    )
    file.close()

    return file_path
