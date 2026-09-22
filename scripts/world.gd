extends Node3D


const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 256
const LEGACY_CHUNK_HEIGHTS: Array[int] = [64, 16]

const AIR: int = 0
const GRASS: int = 1
const DIRT: int = 2
const STONE: int = 3
const SAND: int = 4
const WATER: int = 5
const WATER_FLOW_1: int = 6
const WATER_FLOW_2: int = 7
const WATER_FLOW_3: int = 8
const WATER_FLOW_4: int = 9
const WATER_FLOW_5: int = 10
const WATER_FLOW_6: int = 11
const WATER_FLOW_7: int = 12
const WATER_FALLING: int = 13

const INVALID_CHUNK := Vector2i(999999, 999999)

const PRIORITY_PLAYER: int = 0
const PRIORITY_NEAR: int = 1
const PRIORITY_FAR: int = 2
const TELEPORT_PRELOAD_RADIUS: int = 1

const DAY_LENGTH_SECONDS: float = 24.0 * 60.0
const DEFAULT_TIME_MINUTES: float = 720.0
const CELESTIAL_ORBIT_RADIUS: float = 240.0


@export_category("World")
@export_range(2, 64, 1) var render_distance: int = 12


@export_category("Loading")
@export var spawn_load_radius: int = 1
@export var loading_chunks_per_frame: int = 16
@export var loading_generation_boost: int = 6
@export var loading_mesh_boost: int = 4
@export var loading_mesh_apply_boost: int = 4
@export var loading_collision_boost: int = 3
@export var loading_focus_radius: int = 2
@export var loading_scheduler_scan_limit: int = 64
@export var loading_mesh_budget_ms: float = 8.0


@export_category("Streaming")
@export var chunks_loaded_per_frame: int = 8
@export var max_generation_tasks: int = 8
@export var max_mesh_tasks: int = 6
@export var mesh_columns_per_frame: int = 16
@export var mesh_budget_ms: float = 2.5
@export var max_mesh_chunks_per_frame: int = 2
@export var collisions_per_frame: int = 1
@export var critical_chunk_distance: int = 2


@export_category("Collision")
@export var collision_distance: int = 2

@export_category("Water")
@export var water_updates_per_tick: int = 512
@export var water_tick_interval: float = 0.25


var terrain_noise := FastNoiseLite.new()
var hill_noise := FastNoiseLite.new()
var mountain_region_noise := FastNoiseLite.new()
var mountain_shape_noise := FastNoiseLite.new()

@onready var player: CharacterBody3D = $"../Player"
@onready var loading_screen: Control = $"../LoadingLayer/LoadingScreen"
@onready var world_environment: WorldEnvironment = $"../WorldEnvironment"
@onready var sun_light: DirectionalLight3D = $"../Sun"

var chunk_scene := preload("res://scenes/Chunk.tscn")

const TERRAIN_GENERATOR := preload(
	"res://scripts/terrain_generator.gd"
)
const GENERATION_PROFILER := preload(
	"res://scripts/generation_profiler.gd"
)

const GRASS_SIDE_TEXTURE := preload("res://textures/grass-side.png")
const GRASS_TOP_TEXTURE := preload("res://textures/grass-top.png")
const DIRT_TEXTURE := preload("res://textures/dirt.png")
const STONE_TEXTURE := preload("res://textures/stone.png")
const SAND_TEXTURE := preload("res://textures/sand.png")
const WATER_TEXTURE := preload("res://textures/water.png")

var grass_side_material: StandardMaterial3D
var grass_top_material: StandardMaterial3D
var dirt_material: StandardMaterial3D
var stone_material: StandardMaterial3D
var sand_material: StandardMaterial3D
var water_material: StandardMaterial3D

var moon_light: DirectionalLight3D
var sun_visual: MeshInstance3D
var moon_visual: MeshInstance3D
var sky_material: ProceduralSkyMaterial
var world_time_minutes: float = DEFAULT_TIME_MINUTES


class GenerationResult:
	var blocks: PackedByteArray
	var chunk_coordinate: Vector2i
	var terrain_ms: float = 0.0


class MeshResult:
	var chunk_coordinate: Vector2i
	var job_id: int = 0
	var capture_ms: float = 0.0
	var mesh_ms: float = 0.0
	var center_blocks: PackedByteArray
	var neg_x_blocks: PackedByteArray
	var pos_x_blocks: PackedByteArray
	var neg_z_blocks: PackedByteArray
	var pos_z_blocks: PackedByteArray
	var buffer: ChunkMesher.MeshBuffer


# ===================================================================
# Loaded chunks
# ===================================================================

var loaded_chunks: Dictionary = {}


# ===================================================================
# Required chunks
# ===================================================================

var required_chunks: Dictionary = {}

# Temporary high-priority area kept loaded while a teleport is being prepared.
var teleport_required_chunks: Dictionary = {}
var teleport_pending: bool = false
var teleport_target := Vector3.ZERO
var teleport_destination_chunk := INVALID_CHUNK

signal teleport_completed(message: String)


# ===================================================================
# Chunk loading
# ===================================================================

var load_queue: Array[Vector2i] = []
var load_queued: Dictionary = {}


# ===================================================================
# Terrain generation
# ===================================================================

var critical_generation_queue: Array[Vector2i] = []
var critical_generation_queued: Dictionary = {}

var generation_queue: Array[Vector2i] = []
var generation_queued: Dictionary = {}

var generation_tasks: Dictionary = {}
var mesh_tasks: Dictionary = {}

var stream_direction := Vector2.ZERO
var stream_speed: float = 0.0
var adaptive_streaming_enabled: bool = true
var scheduler_scan_limit: int = 32

var generation_profiler: GenerationProfiler = GENERATION_PROFILER.new()


# ===================================================================
# Mesh queues
#
# Player edits have their own queue so they are never stuck behind
# background terrain.
# ===================================================================

var player_edit_queue: Array[Vector2i] = []
var player_edit_queued: Dictionary = {}

var critical_mesh_queue: Array[Vector2i] = []
var critical_mesh_queued: Dictionary = {}

var near_mesh_queue: Array[Vector2i] = []
var near_mesh_queued: Dictionary = {}

var far_mesh_queue: Array[Vector2i] = []
var far_mesh_queued: Dictionary = {}

var active_mesh_priority: int = PRIORITY_FAR


# ===================================================================
# Water physics
# ===================================================================

func _is_water(block_id: int) -> bool:
	return block_id >= WATER and block_id <= WATER_FALLING


func _is_water_source(block_id: int) -> bool:
	return block_id == WATER


func _is_water_falling(block_id: int) -> bool:
	return block_id == WATER_FALLING


func _is_water_flowing(block_id: int) -> bool:
	return block_id >= WATER_FLOW_1 and block_id <= WATER_FLOW_7


func _water_flow_level(block_id: int) -> int:
	if block_id == WATER:
		return 0

	if _is_water_flowing(block_id):
		return block_id - WATER_FLOW_1 + 1

	if block_id == WATER_FALLING:
		return 8

	return -1


func _water_block_for_level(level: int) -> int:
	if level <= 0:
		return WATER

	return WATER_FLOW_1 + mini(
		level - 1,
		6
	)


func _water_schedule(position: Vector3i) -> void:
	if position.y < 0 or position.y >= CHUNK_HEIGHT:
		return

	if not water_updates_queued.has(position):
		water_update_queue.append(position)
		water_updates_queued[position] = true


func _water_schedule_neighbors(position: Vector3i) -> void:
	_water_schedule(position + Vector3i(0, -1, 0))
	_water_schedule(position + Vector3i(0, 1, 0))
	_water_schedule(position + Vector3i(-1, 0, 0))
	_water_schedule(position + Vector3i(1, 0, 0))
	_water_schedule(position + Vector3i(0, 0, -1))
	_water_schedule(position + Vector3i(0, 0, 1))


func _water_get(position: Vector3i) -> int:
	return get_block_world(
		Vector3(
			position.x + 0.001,
			position.y + 0.001,
			position.z + 0.001
		)
	)


func _water_schedule_changed(position: Vector3i) -> void:
	# Fluid simulation is event-driven: only the changed cell and
	# its immediate neighbors need to be reconsidered.
	_water_schedule(position)
	_water_schedule_neighbors(position)


func _water_mark_mesh_dirty(position: Vector3i) -> void:
	var chunk_coord := world_to_chunk(
		Vector3(position.x, position.y, position.z)
	)
	water_dirty_mesh_chunks[chunk_coord] = true

	var local_x := posmod(position.x, CHUNK_SIZE)
	var local_z := posmod(position.z, CHUNK_SIZE)

	if local_x == 0:
		water_dirty_mesh_chunks[
			chunk_coord + Vector2i(-1, 0)
		] = true
	elif local_x == CHUNK_SIZE - 1:
		water_dirty_mesh_chunks[
			chunk_coord + Vector2i(1, 0)
		] = true

	if local_z == 0:
		water_dirty_mesh_chunks[
			chunk_coord + Vector2i(0, -1)
		] = true
	elif local_z == CHUNK_SIZE - 1:
		water_dirty_mesh_chunks[
			chunk_coord + Vector2i(0, 1)
		] = true


func _water_set(
	position: Vector3i,
	block_id: int
) -> bool:
	if _water_get(position) == block_id:
		return false

	set_block_world(
		Vector3(
			position.x + 0.001,
			position.y + 0.001,
			position.z + 0.001
		),
		block_id,
		false,
		false,
		false,
		false
	)

	# A failed write can happen when a target chunk is not loaded.
	# Do not keep an unloaded position alive in the fluid queue.
	if _water_get(position) != block_id:
		return false

	_water_mark_mesh_dirty(position)
	_water_schedule_changed(position)
	return true


func _water_count_source_neighbors(
	position: Vector3i
) -> int:
	var count: int = 0

	var offsets := [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	for offset in offsets:
		if _water_get(position + offset) == WATER:
			count += 1

	return count


func _water_try_source_conversion(
	position: Vector3i
) -> bool:
	var current := _water_get(position)

	if (
		current != AIR
		and not _is_water_flowing(current)
	):
		return false

	if _water_count_source_neighbors(position) < 2:
		return false

	var below := _water_get(
		position + Vector3i(0, -1, 0)
	)

	# Minecraft also permits source conversion when the block below
	# is another water source.
	if below == AIR or (_is_water(below) and below != WATER):
		return false

	return _water_set(
		position,
		WATER
	)


func _water_has_upstream_supply(
	position: Vector3i,
	current_level: int
) -> bool:
	var above := _water_get(
		position + Vector3i(0, 1, 0)
	)

	if (
		above == WATER
		or above == WATER_FALLING
	):
		return true

	if _is_water_flowing(above):
		var above_level := _water_flow_level(above)

		if above_level < current_level:
			return true

	if current_level <= 0:
		return true

	var offsets := [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	for offset in offsets:
		var neighbor := _water_get(
			position + offset
		)

		if neighbor == WATER:
			return true

		if _is_water_flowing(neighbor):
			var neighbor_level := _water_flow_level(
				neighbor
			)

			if neighbor_level < current_level:
				return true

	return false


func _water_amount(block_id: int) -> int:
	if block_id == WATER or block_id == WATER_FALLING:
		return 8

	if _is_water_flowing(block_id):
		return 8 - _water_flow_level(block_id)

	return 0


func _water_block_for_amount(amount: int) -> int:
	if amount >= 8:
		return WATER

	if amount <= 0:
		return AIR

	return WATER_FLOW_1 + clampi(
		8 - amount - 1,
		0,
		6
	)


func _water_is_solid_below(position: Vector3i) -> bool:
	var block_id := _water_get(position)
	return block_id != AIR and not _is_water(block_id)


func _water_new_state(position: Vector3i) -> int:
	var source_count: int = 0
	var max_amount: int = 0

	var offsets: Array[Vector3i] = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	for offset: Vector3i in offsets:
		var neighbor_id := _water_get(position + offset)

		if neighbor_id == WATER:
			source_count += 1
			max_amount = 8
		elif _is_water_flowing(neighbor_id):
			max_amount = maxi(
				max_amount,
				_water_amount(neighbor_id)
			)

	# Two or more horizontal source blocks create a new source when
	# this position sits on solid ground or another source.
	if source_count >= 2:
		var below := position + Vector3i(0, -1, 0)
		var below_id := _water_get(below)
		if _water_is_solid_below(below) or below_id == WATER:
			return WATER

	# Any water directly above makes this a falling fluid state.
	var above := _water_get(
		position + Vector3i(0, 1, 0)
	)
	if _is_water(above):
		return WATER_FALLING

	# Horizontal flow loses one level of strength per block.
	var next_amount: int = max_amount - 1
	if next_amount <= 0:
		return AIR

	return _water_block_for_amount(next_amount)


func _water_slope_distance(
	position: Vector3i,
	incoming_direction: Vector3i,
	remaining_steps: int,
	cache: Dictionary
) -> int:
	var cache_key := (
		"%d,%d,%d|%d,%d|%d" % [
			position.x,
			position.y,
			position.z,
			incoming_direction.x,
			incoming_direction.z,
			remaining_steps
		]
	)

	if cache.has(cache_key):
		return int(cache[cache_key])

	var below := position + Vector3i(0, -1, 0)
	if _water_get(below) == AIR:
		cache[cache_key] = 0
		return 0

	if remaining_steps <= 0:
		cache[cache_key] = 1000
		return 1000

	var best: int = 1000
	var directions: Array[Vector3i] = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	for direction: Vector3i in directions:
		if direction == incoming_direction:
			continue

		var next_position := position + direction
		var next_id := _water_get(next_position)

		if (
			next_id != AIR
			and not _is_water_flowing(next_id)
			and next_id != WATER_FALLING
		):
			continue

		var distance := _water_slope_distance(
			next_position,
			-direction,
			remaining_steps - 1,
			cache
		)

		if distance < best:
			best = distance

	cache[cache_key] = 1000 if best >= 1000 else best + 1
	return int(cache[cache_key])


func _water_spread_horizontal(
	position: Vector3i,
	current_id: int
) -> void:
	var current_amount: int = _water_amount(current_id)
	if current_amount <= 1:
		return

	var spread_amount: int = current_amount - 1
	if current_id == WATER_FALLING:
		spread_amount = 7

	var directions: Array[Vector3i] = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	var best_distance: int = 1000
	var best_directions: Array[Vector3i] = []
	var cache: Dictionary = {}

	for direction: Vector3i in directions:
		var target := position + direction
		var target_id := _water_get(target)

		if (
			target_id != AIR
			and not _is_water_flowing(target_id)
		):
			continue

		var distance: int = 0
		var below := target + Vector3i(0, -1, 0)

		if _water_get(below) != AIR:
			distance = _water_slope_distance(
				target,
				-direction,
				4,
				cache
			)

		if distance < best_distance:
			best_distance = distance
			best_directions.clear()
			best_directions.append(direction)
		elif distance == best_distance:
			best_directions.append(direction)

	if best_directions.is_empty() or best_distance >= 1000:
		return

	for direction: Vector3i in best_directions:
		var target := position + direction
		var target_id := _water_get(target)
		var desired_id: int = _water_block_for_amount(spread_amount)

		# A flowing target calculates its level from all of its neighbors,
		# just like Minecraft's getNewLiquid(), so it can strengthen or
		# weaken when surrounding water changes.
		if _is_water_flowing(target_id):
			desired_id = _water_new_state(target)
			if desired_id == WATER_FALLING:
				desired_id = _water_block_for_amount(spread_amount)

		if desired_id == AIR:
			continue

		if target_id == AIR:
			_water_set(target, desired_id)
		elif _is_water_flowing(target_id):
			var old_amount := _water_amount(target_id)
			var new_amount := _water_amount(desired_id)
			if new_amount != old_amount:
				_water_set(target, desired_id)


func _water_process_source(position: Vector3i) -> void:
	var below_position := position + Vector3i(0, -1, 0)
	var below := _water_get(below_position)

	if below == AIR:
		_water_set(
			below_position,
			WATER_FALLING
		)

		# Minecraft sources only spread sideways during a downward flow
		# when at least three horizontal source blocks support them.
		if _water_count_source_neighbors(position) < 3:
			return

	_water_spread_horizontal(position, WATER)


func _process_water_position(
	position: Vector3i
) -> void:
	var current := _water_get(position)

	# Empty cells can become infinite-water sources when two
	# horizontal source blocks surround them and the floor is solid.
	if (
		current == AIR
		and _water_try_source_conversion(position)
	):
		current = WATER

	if current == WATER:
		_water_process_source(position)
		return

	if current == WATER_FALLING:
		var below_falling := _water_get(
			position + Vector3i(0, -1, 0)
		)

		if below_falling == AIR:
			_water_set(
				position + Vector3i(0, -1, 0),
				WATER_FALLING
			)
			return

		# Falling water can feed a horizontal flow when it reaches a
		# surface, while retaining its falling state as in Java Edition.
		_water_spread_horizontal(position, WATER_FALLING)
		return

	if not _is_water_flowing(current):
		return

	var below_position := position + Vector3i(0, -1, 0)
	var below := _water_get(below_position)

	if below == AIR:
		_water_set(
			below_position,
			WATER_FALLING
		)
		return

	var updated_state := _water_new_state(position)

	if updated_state == AIR:
		_water_set(position, AIR)
		return

	if updated_state != current:
		_water_set(position, updated_state)
		if updated_state == WATER:
			return
		current = updated_state

	_water_spread_horizontal(position, current)


func process_water_queue(delta: float) -> void:
	water_tick_accumulator += delta

	if water_tick_accumulator < water_tick_interval:
		return

	water_tick_accumulator = fmod(
		water_tick_accumulator,
		water_tick_interval
	)

	var processed: int = 0
	# Fluid updates created while this tick is being processed are
	# deferred until the next tick, matching Minecraft's scheduled
	# fluid-tick behavior.
	var tick_queue_end: int = water_update_queue.size()

	while (
		processed < water_updates_per_tick
		and water_update_queue_head < tick_queue_end
	):
		var position: Vector3i = water_update_queue[
			water_update_queue_head
		]
		water_update_queue_head += 1

		water_updates_queued.erase(
			position
		)

		_process_water_position(position)
		processed += 1

	# Refresh each affected chunk at most once per water tick.
	for chunk_coord in water_dirty_mesh_chunks:
		enqueue_mesh_chunk(chunk_coord)
	water_dirty_mesh_chunks.clear()

	# Keep queue removal O(1) while avoiding an ever-growing backing array.
	if water_update_queue_head >= water_update_queue.size():
		water_update_queue.clear()
		water_update_queue_head = 0
	elif water_update_queue_head >= 1024 and water_update_queue_head * 2 >= water_update_queue.size():
		water_update_queue = water_update_queue.slice(
			water_update_queue_head
		)
		water_update_queue_head = 0


func _water_cell_has_open_destination(
	position: Vector3i
) -> bool:
	var offsets: Array[Vector3i] = [
		Vector3i(0, -1, 0),
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	for offset: Vector3i in offsets:
		if _water_get(position + offset) == AIR:
			return true

	return false


func enqueue_water_updates_for_chunk(
	chunk_coord: Vector2i,
	restore_saved_flow: bool = false
) -> void:
	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

	if not chunk.is_generated:
		return

	if not restore_saved_flow:
		# Newly generated terrain starts with source water at sea level.
		# Only exposed source cells need to enter the simulation.
		const SEA_LEVEL: int = 50

		for x in range(CHUNK_SIZE):
			for z in range(CHUNK_SIZE):
				if chunk.get_block(x, SEA_LEVEL, z) != WATER:
					continue

				var position := Vector3i(
					chunk_coord.x * CHUNK_SIZE + x,
					SEA_LEVEL,
					chunk_coord.y * CHUNK_SIZE + z
				)

				if _water_cell_has_open_destination(position):
					_water_schedule(position)

		return

	# Saved chunks may contain partially-spread or falling water below
	# sea level. Restore only active water frontiers rather than every
	# water voxel in the chunk.
	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			for y in range(CHUNK_HEIGHT):
				var block_id: int = chunk.get_block(x, y, z)
				var position := Vector3i(
					chunk_coord.x * CHUNK_SIZE + x,
					y,
					chunk_coord.y * CHUNK_SIZE + z
				)

				if block_id == WATER_FALLING:
					_water_schedule(position)
					continue

				if block_id == WATER:
					# Only the exposed source frontier needs to wake up.
					if _water_cell_has_open_destination(position):
						_water_schedule(position)
					continue

				if not _is_water_flowing(block_id):
					continue

				if _water_cell_has_open_destination(position):
					_water_schedule(position)


# ===================================================================
# Collision
# ===================================================================

var collision_queue: Array[Vector2i] = []
var collision_queued: Dictionary = {}

var water_update_queue: Array[Vector3i] = []
var water_update_queue_head: int = 0
var water_updates_queued: Dictionary = {}
var water_dirty_mesh_chunks: Dictionary = {}
var water_tick_accumulator: float = 0.0


# ===================================================================
# Player state
# ===================================================================

var player_chunk := Vector2i.ZERO

var selected_block: int = GRASS

var player_spawned: bool = false

var world_name: String = "World"
var world_seed: int = 12345
var world_metadata: Dictionary = {}
var dirty_chunks: Dictionary = {}
var save_accumulator: float = 0.0
const SAVE_INTERVAL: float = 15.0

var blocks_broken: int = 0
var blocks_placed: int = 0
var distance_travelled: float = 0.0
var play_time_seconds: float = 0.0
var last_player_position := Vector3.ZERO
var statistics_initialized: bool = false
var has_saved_player_position: bool = false


func _ready() -> void:
	_create_shared_materials()

	render_distance = GameSettings.render_distance
	world_name = GameSession.world_name
	if world_name == "":
		world_name = "World"

	world_metadata = WorldStore.load_metadata(world_name)

	if GameSession.load_existing and not world_metadata.is_empty():
		world_seed = int(
			world_metadata.get("seed", 12345)
		)
	else:
		world_seed = GameSession.world_seed
		if world_seed == 0:
			world_seed = int(
				world_metadata.get("seed", 12345)
			)
		if world_metadata.is_empty():
			world_metadata = WorldStore.create_world(
				world_name,
				world_seed
			)

	blocks_broken = int(
		world_metadata.get("blocks_broken", 0)
	)
	blocks_placed = int(
		world_metadata.get("blocks_placed", 0)
	)
	distance_travelled = float(
		world_metadata.get("distance_travelled", 0.0)
	)
	play_time_seconds = float(
		world_metadata.get("play_time_seconds", 0.0)
	)
	world_time_minutes = fmod(
		float(world_metadata.get("world_time_minutes", DEFAULT_TIME_MINUTES)),
		1440.0
	)
	if world_time_minutes < 0.0:
		world_time_minutes += 1440.0

	if world_metadata.has("player_x") and float(
		world_metadata.get("player_y", -1.0)
	) >= 0.0:
		has_saved_player_position = true
		player.global_position = Vector3(
			float(world_metadata.get("player_x", 8.5)),
			float(world_metadata.get("player_y", -1.0)),
			float(world_metadata.get("player_z", 8.5))
		)
		player.rotation.y = float(
			world_metadata.get("player_yaw", 0.0)
		)
		player.camera.rotation.x = float(
			world_metadata.get("player_pitch", 0.0)
		)

	terrain_noise.seed = world_seed
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	terrain_noise.frequency = 0.0075
	terrain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	terrain_noise.fractal_octaves = 3
	terrain_noise.fractal_gain = 0.45


	hill_noise.seed = world_seed + 11111
	hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	hill_noise.frequency = 0.018
	hill_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	hill_noise.fractal_octaves = 2
	hill_noise.fractal_gain = 0.45


	mountain_region_noise.seed = world_seed + 22222
	mountain_region_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_region_noise.frequency = 0.0035
	mountain_region_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	mountain_region_noise.fractal_octaves = 2
	mountain_region_noise.fractal_gain = 0.5


	mountain_shape_noise.seed = world_seed + 33333
	mountain_shape_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_shape_noise.frequency = 0.009
	mountain_shape_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_shape_noise.fractal_octaves = 3
	mountain_shape_noise.fractal_gain = 0.5

	player.set_physics_process(false)
	player.velocity = Vector3.ZERO

	_create_celestial_bodies()
	_apply_fog_settings()
	_update_day_night(0.0)

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	player_chunk = world_to_chunk(
		player.global_position
	)

	update_chunks()



func _apply_fog_settings() -> void:
	if world_environment == null or world_environment.environment == null:
		return

	var environment: Environment = world_environment.environment
	environment.fog_enabled = GameSettings.fog_enabled
	environment.fog_mode = Environment.FOG_MODE_DEPTH

	var view_distance := float(render_distance * CHUNK_SIZE)

	# Fog is tied directly to the active render distance.
	# It starts near the outer portion of the visible world and
	# reaches full strength exactly at the render-distance boundary.
	var fog_begin := view_distance * 0.70
	var fog_end := view_distance

	environment.fog_light_color = Color(
		0.75,
		0.90,
		1.0,
		1.0
	)
	environment.fog_density = 1.0
	environment.fog_sky_affect = 0.0
	environment.fog_depth_curve = 1.0
	environment.fog_depth_begin = fog_begin
	environment.fog_depth_end = fog_end


func _create_celestial_bodies() -> void:
	var environment: Environment = world_environment.environment
	if environment != null and environment.sky != null:
		sky_material = environment.sky.sky_material as ProceduralSkyMaterial

	if sun_light != null:
		sun_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		sun_light.shadow_enabled = GameSettings.light_shaders_enabled

	moon_light = DirectionalLight3D.new()
	moon_light.name = "MoonLight"
	moon_light.light_color = Color(
		0.58,
		0.70,
		1.0,
		1.0
	)
	moon_light.light_energy = 0.0
	moon_light.shadow_enabled = false
	moon_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(moon_light)

	sun_visual = _create_celestial_visual(
		"SunVisual",
		Color(1.0, 0.94, 0.68, 1.0),
		Color(1.0, 0.88, 0.55, 1.0),
		10.0
	)
	moon_visual = _create_celestial_visual(
		"MoonVisual",
		Color(0.72, 0.84, 1.0, 1.0),
		Color(0.52, 0.70, 1.0, 1.0),
		8.0
	)


func _create_celestial_visual(
	node_name: String,
	color: Color,
	emission_color: Color,
	size: float
) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	visual.name = node_name

	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	visual.mesh = quad

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.disable_fog = true
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = emission_color
	material.emission_energy_multiplier = 2.0
	visual.material_override = material
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	add_child(visual)
	return visual


func set_time_preset(preset: String) -> bool:
	var preset_minutes: Dictionary = {
		"sunrise": 360.0,
		"day": 480.0,
		"noon": 720.0,
		"evening": 1020.0,
		"sunset": 1080.0,
		"night": 1200.0,
		"midnight": 0.0
	}

	var key := preset.to_lower()

	if not preset_minutes.has(key):
		return false

	world_time_minutes = float(preset_minutes[key])
	return true


func _update_day_night(delta: float) -> void:
	world_time_minutes = fmod(
		world_time_minutes + delta,
		1440.0
	)

	var time_hours := world_time_minutes / 60.0
	var daylight_angle := (
		(time_hours - 6.0) / 24.0
	) * TAU
	var sun_offset := Vector3(
		cos(daylight_angle) * CELESTIAL_ORBIT_RADIUS,
		sin(daylight_angle) * CELESTIAL_ORBIT_RADIUS,
		0.0
	)
	var moon_offset := -sun_offset

	if sun_visual != null:
		sun_visual.global_position = player.global_position + sun_offset
		sun_visual.visible = sun_offset.y > -20.0

	if moon_visual != null:
		moon_visual.global_position = player.global_position + moon_offset
		moon_visual.visible = moon_offset.y > -20.0

	if sun_light != null:
		sun_light.global_position = player.global_position + sun_offset
		sun_light.look_at(player.global_position, Vector3.UP)

	if moon_light != null:
		moon_light.global_position = player.global_position + moon_offset
		moon_light.look_at(player.global_position, Vector3.UP)

	var daylight := clampf(
		sin((time_hours - 6.0) / 12.0 * PI),
		0.0,
		1.0
	)

	if sun_light != null:
		sun_light.light_color = Color(
			1.0,
			0.91,
			0.68,
			1.0
		)
		sun_light.light_energy = lerpf(
			0.0,
			0.72,
			daylight
		)

	if moon_light != null:
		moon_light.light_energy = lerpf(
			0.08,
			0.0,
			daylight
		)

	_update_sky_colors(time_hours, daylight)


func _update_sky_colors(time_hours: float, daylight: float) -> void:
	if world_environment == null or world_environment.environment == null:
		return

	var environment: Environment = world_environment.environment
	if sky_material == null:
		if environment.sky == null:
			return
		sky_material = environment.sky.sky_material as ProceduralSkyMaterial

	var day_top := Color(
		0.31,
		0.64,
		1.0,
		1.0
	)
	var day_horizon := Color(
		0.75,
		0.90,
		1.0,
		1.0
	)
	var day_ground_bottom := Color(
		0.68,
		0.82,
		0.85,
		1.0
	)
	var day_ground_horizon := Color(
		0.75,
		0.90,
		1.0,
		1.0
	)

	var sunset_top := Color(
		0.28,
		0.24,
		0.44,
		1.0
	)
	var sunset_horizon := Color(
		1.0,
		0.45,
		0.18,
		1.0
	)
	var sunset_ground_bottom := Color(
		0.28,
		0.18,
		0.20,
		1.0
	)
	var sunset_ground_horizon := Color(
		0.95,
		0.42,
		0.20,
		1.0
	)

	var night_top := Color(
		0.008,
		0.015,
		0.035,
		1.0
	)
	var night_horizon := Color(
		0.018,
		0.035,
		0.060,
		1.0
	)
	var night_ground_bottom := Color(
		0.004,
		0.008,
		0.018,
		1.0
	)
	var night_ground_horizon := Color(
		0.012,
		0.028,
		0.050,
		1.0
	)

	var top_color: Color
	var horizon_color: Color
	var ground_bottom_color: Color
	var ground_horizon_color: Color

	if time_hours >= 4.0 and time_hours < 5.5:
		var t := _smoothstep((time_hours - 4.0) / 1.5)
		top_color = night_top.lerp(sunset_top, t)
		horizon_color = night_horizon.lerp(sunset_horizon, t)
		ground_bottom_color = night_ground_bottom.lerp(sunset_ground_bottom, t)
		ground_horizon_color = night_ground_horizon.lerp(sunset_ground_horizon, t)
	elif time_hours >= 5.5 and time_hours < 7.0:
		var t := _smoothstep((time_hours - 5.5) / 1.5)
		top_color = sunset_top.lerp(day_top, t)
		horizon_color = sunset_horizon.lerp(day_horizon, t)
		ground_bottom_color = sunset_ground_bottom.lerp(day_ground_bottom, t)
		ground_horizon_color = sunset_ground_horizon.lerp(day_ground_horizon, t)
	elif time_hours >= 7.0 and time_hours < 17.0:
		top_color = day_top
		horizon_color = day_horizon
		ground_bottom_color = day_ground_bottom
		ground_horizon_color = day_ground_horizon
	elif time_hours >= 17.0 and time_hours < 18.5:
		var t := _smoothstep((time_hours - 17.0) / 1.5)
		top_color = day_top.lerp(sunset_top, t)
		horizon_color = day_horizon.lerp(sunset_horizon, t)
		ground_bottom_color = day_ground_bottom.lerp(sunset_ground_bottom, t)
		ground_horizon_color = day_ground_horizon.lerp(sunset_ground_horizon, t)
	elif time_hours >= 18.5 and time_hours < 20.0:
		var t := _smoothstep((time_hours - 18.5) / 1.5)
		top_color = sunset_top.lerp(night_top, t)
		horizon_color = sunset_horizon.lerp(night_horizon, t)
		ground_bottom_color = sunset_ground_bottom.lerp(night_ground_bottom, t)
		ground_horizon_color = sunset_ground_horizon.lerp(night_ground_horizon, t)
	else:
		top_color = night_top
		horizon_color = night_horizon
		ground_bottom_color = night_ground_bottom
		ground_horizon_color = night_ground_horizon

	sky_material.sky_top_color = top_color
	sky_material.sky_horizon_color = horizon_color
	sky_material.ground_bottom_color = ground_bottom_color
	sky_material.ground_horizon_color = ground_horizon_color

	environment.ambient_light_color = Color(
		0.14,
		0.19,
		0.26,
		1.0
	).lerp(Color.WHITE, daylight)
	environment.ambient_light_energy = lerpf(
		0.12,
		0.68,
		daylight
	)


func _smoothstep(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _create_shared_materials() -> void:
	grass_side_material = StandardMaterial3D.new()
	grass_side_material.albedo_texture = GRASS_SIDE_TEXTURE
	grass_side_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	grass_top_material = StandardMaterial3D.new()
	grass_top_material.albedo_texture = GRASS_TOP_TEXTURE
	grass_top_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	dirt_material = StandardMaterial3D.new()
	dirt_material.albedo_texture = DIRT_TEXTURE
	dirt_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	stone_material = StandardMaterial3D.new()
	stone_material.albedo_texture = STONE_TEXTURE
	stone_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	sand_material = StandardMaterial3D.new()
	sand_material.albedo_texture = SAND_TEXTURE
	sand_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	water_material = StandardMaterial3D.new()
	water_material.albedo_texture = WATER_TEXTURE
	water_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_material.albedo_color = Color(1.0, 1.0, 1.0, 0.5)
	water_material.cull_mode = BaseMaterial3D.CULL_DISABLED


func _process(delta: float) -> void:
	_update_day_night(delta)
	_update_stream_prediction()

	if player_spawned:
		if statistics_initialized:
			distance_travelled += (
				player.global_position.distance_to(last_player_position)
			)
		else:
			statistics_initialized = true

		last_player_position = player.global_position
		play_time_seconds += delta
		save_accumulator += delta

		if save_accumulator >= SAVE_INTERVAL:
			save_accumulator = 0.0
			save_world()

		var current_chunk := world_to_chunk(
			player.global_position
		)

		if current_chunk != player_chunk:
			player_chunk = current_chunk

			update_chunks()
			update_collision_range()

	process_load_queue()
	process_generation_queue()
	process_mesh_queue()
	process_water_queue(delta)
	process_collision_queue()
	_process_pending_teleport()

	if not player_spawned:
		update_loading_progress()
		try_spawn_player()


# ===================================================================
# Adaptive streaming and profiling
# ===================================================================

func _update_stream_prediction() -> void:
	if not player_spawned:
		return

	var horizontal_velocity := Vector2(
		player.velocity.x,
		player.velocity.z
	)
	var speed := horizontal_velocity.length()

	if speed > 0.15:
		stream_direction = horizontal_velocity / speed
		stream_speed = lerpf(stream_speed, speed, 0.25)
	else:
		stream_speed = move_toward(
			stream_speed,
			0.0,
			maxf(get_process_delta_time() * 10.0, 0.01)
		)


func _available_worker_budget() -> int:
	return maxi(1, OS.get_processor_count() - 1)


func _generation_task_limit() -> int:
	if max_generation_tasks <= 0:
		return 0

	var limit := max_generation_tasks
	if not player_spawned:
		limit += loading_generation_boost

	return mini(limit, _available_worker_budget())


func _mesh_task_limit() -> int:
	if max_mesh_tasks <= 0:
		return 0

	var limit := max_mesh_tasks
	if not player_spawned:
		limit += loading_mesh_boost

	return mini(limit, _available_worker_budget())


func _mesh_apply_limit() -> int:
	var limit := max_mesh_chunks_per_frame

	if not player_spawned:
		limit += loading_mesh_apply_boost

	return maxi(limit, 1)


func _mesh_apply_budget_ms() -> float:
	if not player_spawned:
		return maxf(
			0.0,
			loading_mesh_budget_ms
		)

	return mesh_budget_ms


func _collision_work_limit() -> int:
	var limit := collisions_per_frame

	if not player_spawned:
		limit += loading_collision_boost

	return maxi(limit, 1)


func _chunk_stream_score(chunk_coord: Vector2i) -> float:
	var offset := Vector2(
		float(chunk_coord.x - player_chunk.x),
		float(chunk_coord.y - player_chunk.y)
	)
	var distance_squared := offset.length_squared()

	if distance_squared <= 0.01:
		return 100000.0

	var score := -distance_squared * 1.25

	if is_chunk_critical(chunk_coord):
		score += 10000.0

	if not player_spawned:
		var spawn_dx: int = abs(
			chunk_coord.x - player_chunk.x
		)
		var spawn_dz: int = abs(
			chunk_coord.y - player_chunk.y
		)
		var spawn_radius: int = maxi(
			0,
			spawn_load_radius
		)
		var focus_radius: int = maxi(
			spawn_radius,
			loading_focus_radius
		)

		if (
			spawn_dx <= spawn_radius
			and spawn_dz <= spawn_radius
		):
			score += 50000.0
		elif (
			spawn_dx <= focus_radius
			and spawn_dz <= focus_radius
		):
			score += 20000.0

	if stream_direction.length_squared() > 0.01:
		var alignment := offset.normalized().dot(stream_direction)
		score += alignment * (12.0 + minf(stream_speed * 2.5, 24.0))

	return score


func _take_best_generation_candidate(
	queue: Array[Vector2i],
	queued: Dictionary
) -> Vector2i:
	var best_index := -1
	var best_score := -INF
	var scan_limit: int = scheduler_scan_limit

	if not player_spawned:
		scan_limit = maxi(
			scan_limit,
			loading_scheduler_scan_limit
		)

	var scan_count := mini(queue.size(), scan_limit)

	for index in range(scan_count):
		var coord: Vector2i = queue[index]

		if (
			not queued.has(coord)
			or not loaded_chunks.has(coord)
			or not _is_chunk_needed(coord)
		):
			continue

		var chunk = loaded_chunks[coord]
		if chunk.is_generated:
			continue

		var score := _chunk_stream_score(coord)
		if score > best_score:
			best_score = score
			best_index = index

	if best_index == -1:
		return INVALID_CHUNK

	var selected: Vector2i = queue[best_index]
	queue.remove_at(best_index)
	queued.erase(selected)
	return selected


func _take_best_mesh_candidate(
	queue: Array[Vector2i],
	queued: Dictionary
) -> Vector2i:
	var best_index := -1
	var best_score := -INF
	var scan_limit: int = scheduler_scan_limit

	if not player_spawned:
		scan_limit = maxi(
			scan_limit,
			loading_scheduler_scan_limit
		)

	var scan_count := mini(queue.size(), scan_limit)

	for index in range(scan_count):
		var coord: Vector2i = queue[index]

		if (
			not queued.has(coord)
			or not loaded_chunks.has(coord)
			or not _is_chunk_needed(coord)
		):
			continue

		var chunk = loaded_chunks[coord]
		if not chunk.is_generated or chunk.mesh_building:
			continue

		var score := _chunk_stream_score(coord)
		if score > best_score:
			best_score = score
			best_index = index

	if best_index == -1:
		return INVALID_CHUNK

	var selected: Vector2i = queue[best_index]
	queue.remove_at(best_index)
	queued.erase(selected)
	return selected


func get_generation_profile() -> String:
	return generation_profiler.get_summary()


# ===================================================================
# Coordinates
# ===================================================================

func world_to_chunk(
	world_position: Vector3
) -> Vector2i:

	return Vector2i(
		floori(
			world_position.x / CHUNK_SIZE
		),
		floori(
			world_position.z / CHUNK_SIZE
		)
	)


func is_chunk_within_collision_distance(
	chunk_coord: Vector2i
) -> bool:

	var dx: int = abs(
		chunk_coord.x - player_chunk.x
	)

	var dz: int = abs(
		chunk_coord.y - player_chunk.y
	)

	return (
		dx <= collision_distance
		and dz <= collision_distance
	)


func is_chunk_ready_for_player(
	chunk_coord: Vector2i
) -> bool:

	if not loaded_chunks.has(
		chunk_coord
	):
		return false

	var chunk = loaded_chunks[
		chunk_coord
	]

	return (
		chunk.is_generated
		and chunk.mesh_ready
		and chunk.collision_ready
	)


func can_player_enter_chunk(
	chunk_coord: Vector2i
) -> bool:

	return is_chunk_ready_for_player(
		chunk_coord
	)


func get_chunk_stream_priority(
	chunk_coord: Vector2i
) -> int:

	var dx: int = abs(
		chunk_coord.x - player_chunk.x
	)

	var dz: int = abs(
		chunk_coord.y - player_chunk.y
	)

	var distance: int = max(dx, dz)

	if distance <= 3:
		return 1

	return 2


func is_chunk_critical(
	chunk_coord: Vector2i
) -> bool:
	var dx: int = abs(
		chunk_coord.x - player_chunk.x
	)

	var dz: int = abs(
		chunk_coord.y - player_chunk.y
	)

	var active_critical_distance: int = critical_chunk_distance

	# Before the player enters the world, the bootstrap area must win
	# over the normal background streaming ring. This keeps the
	# loading phase focused on the chunks the player will immediately
	# see and interact with.
	if not player_spawned:
		active_critical_distance = maxi(
			active_critical_distance,
			maxi(
				loading_focus_radius,
				spawn_load_radius
			)
		)

	return (
		dx <= active_critical_distance
		and dz <= active_critical_distance
	)

# ===================================================================
# Required chunks
# ===================================================================

func _is_chunk_needed(
	chunk_coord: Vector2i
) -> bool:
	return (
		required_chunks.has(chunk_coord)
		or teleport_required_chunks.has(chunk_coord)
	)


func _is_chunk_teleport_required(
	chunk_coord: Vector2i
) -> bool:
	return teleport_required_chunks.has(chunk_coord)


func _queue_pending_teleport_chunks() -> void:
	if not teleport_pending:
		return

	for chunk_coord in teleport_required_chunks:
		if loaded_chunks.has(chunk_coord):
			continue

		if load_queued.has(chunk_coord):
			continue

		load_queue.push_front(chunk_coord)
		load_queued[chunk_coord] = true


func _prepare_teleport_chunk_area(
	destination_chunk: Vector2i
) -> void:
	teleport_required_chunks.clear()

	for x_offset in range(
		-TELEPORT_PRELOAD_RADIUS,
		TELEPORT_PRELOAD_RADIUS + 1
	):
		for z_offset in range(
			-TELEPORT_PRELOAD_RADIUS,
			TELEPORT_PRELOAD_RADIUS + 1
		):
			teleport_required_chunks[
				destination_chunk + Vector2i(
					x_offset,
					z_offset
				)
			] = true

	_queue_pending_teleport_chunks()

	# Promote already-loaded destination chunks to the critical
	# generation, mesh, and collision paths.
	for chunk_coord in teleport_required_chunks:
		if not loaded_chunks.has(chunk_coord):
			continue

		var chunk = loaded_chunks[chunk_coord]

		if not chunk.is_generated:
			if not critical_generation_queued.has(chunk_coord):
				critical_generation_queue.push_front(chunk_coord)
				critical_generation_queued[chunk_coord] = true
			continue

		enqueue_mesh_chunk(chunk_coord)

		if chunk.mesh_ready:
			enqueue_collision_chunk(chunk_coord)


func request_teleport(
	target: Vector3
) -> Dictionary:
	if teleport_pending:
		return {
			"success": false,
			"message": "A teleport is already being prepared."
		}

	teleport_target = target
	teleport_destination_chunk = world_to_chunk(target)
	teleport_pending = true

	_prepare_teleport_chunk_area(
		teleport_destination_chunk
	)

	return {
		"success": true,
		"pending": true,
		"message": "Preparing destination..."
	}


func _process_pending_teleport() -> void:
	if not teleport_pending:
		return

	for chunk_coord in teleport_required_chunks:
		if not loaded_chunks.has(chunk_coord):
			return

		var chunk = loaded_chunks[chunk_coord]

		if (
			not chunk.is_generated
			or not chunk.mesh_ready
			or not chunk.collision_ready
		):
			return

	player.global_position = teleport_target
	player.velocity = Vector3.ZERO
	player_chunk = teleport_destination_chunk

	var message := "Teleported to %s %s %s" % [
		_format_teleport_coordinate(teleport_target.x),
		_format_teleport_coordinate(teleport_target.y),
		_format_teleport_coordinate(teleport_target.z)
	]

	teleport_pending = false
	teleport_required_chunks.clear()
	teleport_destination_chunk = INVALID_CHUNK
	teleport_target = Vector3.ZERO

	update_chunks()
	update_collision_range()

	teleport_completed.emit(message)


func _format_teleport_coordinate(value: float) -> String:
	if is_equal_approx(value, round(value)):
		return str(int(round(value)))

	return "%.3f" % value


func update_chunks() -> void:

	required_chunks.clear()

	for x in range(
		player_chunk.x - render_distance,
		player_chunk.x + render_distance + 1
	):

		for z in range(
			player_chunk.y - render_distance,
			player_chunk.y + render_distance + 1
		):

			var chunk_coord := Vector2i(x, z)

			required_chunks[chunk_coord] = true


	# Rebuild the load queue.
	load_queue.clear()
	load_queued.clear()

	for radius in range(
		render_distance + 1
	):

		for x_offset in range(
			-radius,
			radius + 1
		):

			for z_offset in range(
				-radius,
				radius + 1
			):

				if max(
					abs(x_offset),
					abs(z_offset)
				) != radius:
					continue

				var chunk_coord := Vector2i(
					player_chunk.x + x_offset,
					player_chunk.y + z_offset
				)

				if not _is_chunk_needed(
					chunk_coord
				):
					continue

				if loaded_chunks.has(
					chunk_coord
				):
					continue

				load_queue.append(
					chunk_coord
				)

				load_queued[chunk_coord] = true


	_queue_pending_teleport_chunks()

	# Unload chunks outside render distance.
	var chunks_to_remove: Array[Vector2i] = []

	for chunk_coord in loaded_chunks:

		if (
			not required_chunks.has(chunk_coord)
			and not teleport_required_chunks.has(chunk_coord)
		):

			chunks_to_remove.append(
				chunk_coord
			)


	for chunk_coord in chunks_to_remove:
		unload_chunk(chunk_coord)


# ===================================================================
# Chunk loading
# ===================================================================

func process_load_queue() -> void:

	var loads_done: int = 0
	var load_limit: int = chunks_loaded_per_frame

	# During the loading screen the player is not moving, so loading
	# chunk nodes can be much more aggressive without competing with
	# gameplay input or physics.
	if not player_spawned:
		load_limit = maxi(
			load_limit,
			loading_chunks_per_frame
		)

	while (
		loads_done < load_limit
		and not load_queue.is_empty()
	):

		var chunk_coord: Vector2i = (
			load_queue.pop_front()
		)

		load_queued.erase(
			chunk_coord
		)

		if not _is_chunk_needed(
			chunk_coord
		):
			continue

		if loaded_chunks.has(
			chunk_coord
		):
			continue

		load_chunk(
			chunk_coord
		)

		loads_done += 1


func _migrate_saved_chunk_data(
	saved_blocks: PackedByteArray,
	expected_size: int
) -> PackedByteArray:
	if saved_blocks.size() == expected_size:
		return saved_blocks

	for legacy_height in LEGACY_CHUNK_HEIGHTS:
		var legacy_size: int = (
			CHUNK_SIZE *
			legacy_height *
			CHUNK_SIZE
		)

		if saved_blocks.size() != legacy_size:
			continue

		# Chunk storage is Y-contiguous, so the legacy data is the
		# exact prefix of the current buffer. The old formats ended
		# at their height ceiling, so the added upper area is air.
		var expanded := PackedByteArray()
		expanded.resize(expected_size)

		for index in range(saved_blocks.size()):
			expanded[index] = saved_blocks[index]

		return expanded

	return PackedByteArray()


func load_chunk(
	chunk_coord: Vector2i
) -> void:

	var chunk = chunk_scene.instantiate()
	chunk.set_generation_stage(
		Chunk.GenerationStage.LOADING
	)

	chunk.position = Vector3(
		chunk_coord.x * CHUNK_SIZE,
		0.0,
		chunk_coord.y * CHUNK_SIZE
	)

	chunk.chunk_coordinate = chunk_coord

	chunk.terrain_noise = terrain_noise
	chunk.hill_noise = hill_noise
	chunk.mountain_region_noise = mountain_region_noise
	chunk.mountain_shape_noise = mountain_shape_noise

	# Share the same materials across every chunk. This avoids
	# creating five new StandardMaterial3D resources per chunk.
	chunk.grass_side_material = grass_side_material
	chunk.grass_top_material = grass_top_material
	chunk.dirt_material = dirt_material
	chunk.stone_material = stone_material
	chunk.sand_material = sand_material
	chunk.water_material = water_material

	loaded_chunks[chunk_coord] = chunk

	add_child(chunk)

	var expected_size: int = CHUNK_SIZE * CHUNK_HEIGHT * CHUNK_SIZE
	var saved_blocks: PackedByteArray = WorldStore.load_chunk(
		world_name,
		chunk_coord
	)

	var migrated_blocks := _migrate_saved_chunk_data(
		saved_blocks,
		expected_size
	)

	if not migrated_blocks.is_empty():
		var was_legacy_format: bool = (
			saved_blocks.size() != expected_size
		)

		chunk.apply_generated_data(migrated_blocks)

		# Persist the upgraded representation on the next world save.
		# This keeps old edits while avoiding repeated migration work.
		if was_legacy_format:
			dirty_chunks[chunk_coord] = true

		# Restart the saved water simulation from existing source blocks.
		# Only source cells at sea level are queued, then normal water logic
		# propagates the update outward without creating a large backlog.
		enqueue_water_updates_for_chunk(
			chunk_coord,
			true
		)

		enqueue_mesh_chunk(chunk_coord)
		enqueue_neighbor_meshes(chunk_coord)
		return

	if (
		is_chunk_critical(chunk_coord)
		or _is_chunk_teleport_required(chunk_coord)
	):

		critical_generation_queue.append(
			chunk_coord
		)

		critical_generation_queued[chunk_coord] = true

	else:

		generation_queue.append(
			chunk_coord
		)

		generation_queued[chunk_coord] = true


func _generate_chunk_worker(
	result: GenerationResult,
	chunk_coordinate: Vector2i,
	seed: int
) -> void:

	result.chunk_coordinate = chunk_coordinate
	var start_usec := Time.get_ticks_usec()
	result.blocks = (
		TERRAIN_GENERATOR.generate_chunk_data(
			chunk_coordinate,
			seed
		)
	)
	result.terrain_ms = float(
		Time.get_ticks_usec() - start_usec
	) / 1000.0


# ===================================================================
# Terrain generation
# ===================================================================

func process_generation_queue() -> void:

	# ---------------------------------------------------------------
	# COLLECT COMPLETED WORKER TASKS
	# ---------------------------------------------------------------

	var completed_tasks: Array[int] = []

	for task_id in generation_tasks:

		if WorkerThreadPool.is_task_completed(
			task_id
		):
			completed_tasks.append(
				task_id
			)


	for task_id in completed_tasks:

		var result: GenerationResult = (
			generation_tasks[task_id]
		)

		var wait_error: Error = (
			WorkerThreadPool.wait_for_task_completion(
				task_id
			)
		)

		generation_tasks.erase(
			task_id
		)

		if wait_error != OK:
			push_error(
				"Chunk generation task failed: "
				+ str(wait_error)
			)
			continue


		var chunk_coord: Vector2i = (
			result.chunk_coordinate
		)

		var generated_data: PackedByteArray = (
			result.blocks
		)


		# The chunk may have been unloaded while the
		# worker was generating it.
		if not loaded_chunks.has(
			chunk_coord
		):
			continue


		# The player may have moved away while the
		# worker was generating it.
		if not _is_chunk_needed(
			chunk_coord
		):
			continue


		var chunk = loaded_chunks[
			chunk_coord
		]


		if chunk.is_generated:
			continue


		chunk.apply_generated_data(
			generated_data
		)

		# Kick the water simulation from exposed source cells only.
		# Interior ocean water needs no update until an exposed frontier
		# reaches it, keeping chunk generation from creating a huge queue.
		enqueue_water_updates_for_chunk(
			chunk_coord
		)

		enqueue_mesh_chunk(
			chunk_coord
		)


		enqueue_neighbor_meshes(
			chunk_coord
		)


	# ---------------------------------------------------------------
	# SUBMIT NEW GENERATION TASKS
	# ---------------------------------------------------------------

	var generation_limit := _generation_task_limit()
	if generation_limit <= 0:
		return


	while (
		generation_tasks.size()
		< generation_limit
	):

		var chunk_coord: Vector2i = (
			get_next_generation_candidate()
		)


		if chunk_coord == INVALID_CHUNK:
			return


		if not loaded_chunks.has(
			chunk_coord
		):
			continue


		if not _is_chunk_needed(
			chunk_coord
		):
			continue


		var chunk = loaded_chunks[
			chunk_coord
		]


		if chunk.is_generated:
			continue


		var result := GenerationResult.new()

		result.chunk_coordinate = (
			chunk_coord
		)


		var generation_callable: Callable = (
			Callable(
				self,
				"_generate_chunk_worker"
			).bind(
				result,
				chunk_coord,
				world_seed
			)
		)


		var high_priority: bool = (
			is_chunk_critical(chunk_coord)
			or _is_chunk_teleport_required(chunk_coord)
		)


		var task_id: int = (
			WorkerThreadPool.add_task(
				generation_callable,
				high_priority,
				"Generate chunk (%d, %d)"
				% [
					chunk_coord.x,
					chunk_coord.y
				]
			)
		)


		generation_tasks[
			task_id
		] = result


func get_next_generation_candidate() -> Vector2i:
	var critical := _take_best_generation_candidate(
		critical_generation_queue,
		critical_generation_queued
	)
	if critical != INVALID_CHUNK:
		return critical

	return _take_best_generation_candidate(
		generation_queue,
		generation_queued
	)


# ===================================================================
# Neighbor mesh updates
# ===================================================================

func enqueue_neighbor_meshes(
	chunk_coord: Vector2i
) -> void:

	var offsets: Array[Vector2i] = [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1)
	]

	for offset in offsets:

		var neighbor_coordinate: Vector2i = (
			chunk_coord + offset
		)

		if not loaded_chunks.has(
			neighbor_coordinate
		):
			continue

		var neighbor = loaded_chunks[
			neighbor_coordinate
		]

		if not neighbor.is_generated:
			continue

		# If the neighbor is currently building its mesh,
		# cancel that partial build. Its border may have
		# been generated against an incomplete neighbor.
		if neighbor.mesh_building:
			neighbor.cancel_mesh_build()

		enqueue_mesh_chunk(
			neighbor_coordinate
		)


# ===================================================================
# Normal mesh queue
# ===================================================================

func enqueue_mesh_chunk(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(
		chunk_coord
	):
		return

	var chunk = loaded_chunks[
		chunk_coord
	]

	if not chunk.is_generated:
		return

	# Spawn-area meshes are delayed until their required horizontal
	# neighbors have generated. The mesher needs those borders to avoid
	# treating unfinished neighbors as air, which otherwise causes the
	# same chunk to be rebuilt repeatedly during startup.
	if (
		not player_spawned
		and _is_chunk_in_spawn_area(chunk_coord)
		and not _loading_mesh_neighbors_ready(chunk_coord)
	):
		return
	
	if (
		is_chunk_critical(chunk_coord)
		or _is_chunk_teleport_required(chunk_coord)
	):

		if critical_mesh_queued.has(
			chunk_coord
		):
			return

		critical_mesh_queue.append(
			chunk_coord
		)

		critical_mesh_queued[
			chunk_coord
		] = true

		return

	if chunk.mesh_building:
		chunk.cancel_mesh_build()

	if player_edit_queued.has(
		chunk_coord
	):
		return

	if near_mesh_queued.has(
		chunk_coord
	):
		return

	if far_mesh_queued.has(
		chunk_coord
	):
		return

	if get_chunk_stream_priority(
		chunk_coord
	) == 1:

		near_mesh_queue.append(
			chunk_coord
		)

		near_mesh_queued[chunk_coord] = true

	else:

		far_mesh_queue.append(
			chunk_coord
		)

		far_mesh_queued[chunk_coord] = true


func _is_chunk_in_spawn_area(
	chunk_coord: Vector2i
) -> bool:
	var dx: int = abs(
		chunk_coord.x - player_chunk.x
	)
	var dz: int = abs(
		chunk_coord.y - player_chunk.y
	)
	var radius: int = maxi(
		0,
		spawn_load_radius
	)

	return (
		dx <= radius
		and dz <= radius
	)


func _loading_mesh_neighbors_ready(
	chunk_coord: Vector2i
) -> bool:
	var offsets: Array[Vector2i] = [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1)
	]

	for offset: Vector2i in offsets:
		var neighbor_coord := chunk_coord + offset

		# A neighbor outside the active render area will be treated as
		# air by the mesher, so it cannot invalidate this mesh later.
		if not required_chunks.has(neighbor_coord):
			continue

		if not loaded_chunks.has(neighbor_coord):
			return false

		var neighbor = loaded_chunks[neighbor_coord]

		if not neighbor.is_generated:
			return false

	return true


# ===================================================================
# Player edit queue
# ===================================================================

func enqueue_player_edit(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(
		chunk_coord
	):
		return

	var chunk = loaded_chunks[
		chunk_coord
	]

	if not chunk.is_generated:
		return

	# Cancel background mesh generation for this chunk.
	if chunk.mesh_building:
		chunk.cancel_mesh_build()

	# Old mesh no longer represents the block data.
	chunk.mesh_ready = false

	# Remove its logical queue state.
	near_mesh_queued.erase(
		chunk_coord
	)

	far_mesh_queued.erase(
		chunk_coord
	)

	# Player edits always go to the front of their own queue.
	if not player_edit_queued.has(
		chunk_coord
	):

		player_edit_queue.push_back(
			chunk_coord
		)

		player_edit_queued[chunk_coord] = true


# ===================================================================
# Mesh processing
# ===================================================================

func _capture_mesh_inputs(
	chunk_coord: Vector2i,
	result: MeshResult
) -> void:
	var start_usec := Time.get_ticks_usec()
	var chunk = loaded_chunks[chunk_coord]

	# Duplicating the compact block arrays is cheap compared to walking
	# the scene tree and doing thousands of cross-chunk lookups.
	result.center_blocks = chunk.blocks.duplicate()

	var neighbor_coord := chunk_coord + Vector2i(-1, 0)
	if loaded_chunks.has(neighbor_coord):
		var neighbor = loaded_chunks[neighbor_coord]
		if neighbor.is_generated:
			result.neg_x_blocks = neighbor.blocks.duplicate()

	neighbor_coord = chunk_coord + Vector2i(1, 0)
	if loaded_chunks.has(neighbor_coord):
		var neighbor = loaded_chunks[neighbor_coord]
		if neighbor.is_generated:
			result.pos_x_blocks = neighbor.blocks.duplicate()

	neighbor_coord = chunk_coord + Vector2i(0, -1)
	if loaded_chunks.has(neighbor_coord):
		var neighbor = loaded_chunks[neighbor_coord]
		if neighbor.is_generated:
			result.neg_z_blocks = neighbor.blocks.duplicate()

	neighbor_coord = chunk_coord + Vector2i(0, 1)
	if loaded_chunks.has(neighbor_coord):
		var neighbor = loaded_chunks[neighbor_coord]
		if neighbor.is_generated:
			result.pos_z_blocks = neighbor.blocks.duplicate()

	result.capture_ms = float(
		Time.get_ticks_usec() - start_usec
	) / 1000.0


func _build_mesh_worker(
	result: MeshResult
) -> void:
	var start_usec := Time.get_ticks_usec()
	result.buffer = ChunkMesher.build_from_blocks(
		result.center_blocks,
		result.neg_x_blocks,
		result.pos_x_blocks,
		result.neg_z_blocks,
		result.pos_z_blocks,
		result.chunk_coordinate
	)
	result.mesh_ms = float(
		Time.get_ticks_usec() - start_usec
	) / 1000.0


func _compare_completed_mesh_tasks(
	first_id: int,
	second_id: int
) -> bool:
	if not mesh_tasks.has(first_id):
		return false

	if not mesh_tasks.has(second_id):
		return true

	var first_result: MeshResult = mesh_tasks[first_id]
	var second_result: MeshResult = mesh_tasks[second_id]

	var first_score := _chunk_stream_score(
		first_result.chunk_coordinate
	)
	var second_score := _chunk_stream_score(
		second_result.chunk_coordinate
	)

	if is_equal_approx(first_score, second_score):
		return first_id < second_id

	return first_score > second_score


func process_mesh_queue() -> void:

	# ---------------------------------------------------------------
	# COLLECT COMPLETED WORKER MESH TASKS
	# ---------------------------------------------------------------

	var completed_tasks: Array[int] = []

	for task_id in mesh_tasks:
		if WorkerThreadPool.is_task_completed(task_id):
			completed_tasks.append(task_id)

	var apply_start_usec: int = Time.get_ticks_usec()
	var applied_count: int = 0

	if not player_spawned and completed_tasks.size() > 1:
		completed_tasks.sort_custom(
			_compare_completed_mesh_tasks
		)

	for task_id in completed_tasks:
		if (
			applied_count >= _mesh_apply_limit()
			and _mesh_apply_limit() > 0
		):
			break

		if (
			applied_count > 0
			and _mesh_apply_budget_ms() > 0.0
			and float(
				Time.get_ticks_usec() - apply_start_usec
			) / 1000.0 >= _mesh_apply_budget_ms()
		):
			break

		var result: MeshResult = mesh_tasks[task_id]

		var wait_error: Error = (
			WorkerThreadPool.wait_for_task_completion(
				task_id
			)
		)

		mesh_tasks.erase(task_id)

		if wait_error != OK:
			push_error(
				"Chunk mesh task failed: "
				+ str(wait_error)
			)
			continue

		if not loaded_chunks.has(result.chunk_coordinate):
			continue

		var chunk = loaded_chunks[result.chunk_coordinate]

		if not chunk.is_generated:
			continue

		# A newer edit or neighbor change may have invalidated
		# this worker result while it was running.
		if chunk.mesh_job_id != result.job_id:
			continue

		if result.buffer == null:
			push_error(
				"Chunk mesh task returned no mesh buffer."
			)
			continue

		var mesh_apply_start_usec := Time.get_ticks_usec()
		chunk.apply_mesh_buffer(result.buffer)
		generation_profiler.record(
			"mesh_apply",
			float(Time.get_ticks_usec() - mesh_apply_start_usec) / 1000.0
		)
		enqueue_collision_chunk(
			result.chunk_coordinate
		)
		applied_count += 1

	# ---------------------------------------------------------------
	# SUBMIT NEW WORK
	# ---------------------------------------------------------------

	var mesh_limit := _mesh_task_limit()
	if mesh_limit <= 0:
		return

	while mesh_tasks.size() < mesh_limit:
		var chunk_coord: Vector2i = (
			get_next_mesh_candidate()
		)

		if chunk_coord == INVALID_CHUNK:
			return

		if not loaded_chunks.has(chunk_coord):
			continue

		var chunk = loaded_chunks[chunk_coord]

		if not chunk.is_generated:
			continue

		# A duplicate queue entry cannot start two worker jobs.
		if chunk.mesh_building:
			continue

		chunk.mesh_building = true
		chunk.mesh_ready = false
		chunk.collision_ready = false
		chunk.mesh_job_id += 1

		var result := MeshResult.new()
		result.chunk_coordinate = chunk_coord
		result.job_id = chunk.mesh_job_id
		_capture_mesh_inputs(
			chunk_coord,
			result
		)

		var mesh_callable: Callable = (
			Callable(
				self,
				"_build_mesh_worker"
			).bind(
				result
			)
		)

		var task_id: int = WorkerThreadPool.add_task(
			mesh_callable,
			(
				is_chunk_critical(chunk_coord)
				or _is_chunk_teleport_required(chunk_coord)
			),
			"Mesh chunk (%d, %d)" % [
				chunk_coord.x,
				chunk_coord.y
			]
		)

		result.job_id = chunk.mesh_job_id
		mesh_tasks[task_id] = result


func get_next_mesh_candidate() -> Vector2i:
	while not player_edit_queue.is_empty():
		var player_coord: Vector2i = player_edit_queue.pop_front()
		if not player_edit_queued.has(player_coord):
			continue
		player_edit_queued.erase(player_coord)
		active_mesh_priority = PRIORITY_PLAYER
		return player_coord

	var critical := _take_best_mesh_candidate(
		critical_mesh_queue,
		critical_mesh_queued
	)
	if critical != INVALID_CHUNK:
		active_mesh_priority = PRIORITY_NEAR
		return critical

	var near := _take_best_mesh_candidate(
		near_mesh_queue,
		near_mesh_queued
	)
	if near != INVALID_CHUNK:
		active_mesh_priority = PRIORITY_NEAR
		return near

	var far := _take_best_mesh_candidate(
		far_mesh_queue,
		far_mesh_queued
	)
	if far != INVALID_CHUNK:
		active_mesh_priority = PRIORITY_FAR
		return far

	return INVALID_CHUNK


# ===================================================================
# Collision
# ===================================================================

func enqueue_collision_chunk(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(
		chunk_coord
	):
		return

	if (
		not is_chunk_within_collision_distance(chunk_coord)
		and not _is_chunk_teleport_required(chunk_coord)
	):
		return

	var chunk = loaded_chunks[
		chunk_coord
	]

	if not chunk.mesh_ready:
		return

	if chunk.collision_ready:
		return

	if collision_queued.has(
		chunk_coord
	):
		return

	if (
		is_chunk_critical(chunk_coord)
		or _is_chunk_teleport_required(chunk_coord)
	):

		collision_queue.push_front(
			chunk_coord
		)

	else:

		collision_queue.append(
			chunk_coord
		)

	collision_queued[
		chunk_coord
	] = true


func update_collision_range() -> void:

	for chunk_coord in loaded_chunks:

		var chunk = loaded_chunks[
			chunk_coord
		]

		if (
			is_chunk_within_collision_distance(chunk_coord)
			or _is_chunk_teleport_required(chunk_coord)
		):

			if (
				chunk.mesh_ready
				and not chunk.collision_ready
			):

				enqueue_collision_chunk(
					chunk_coord
				)

		else:

			if chunk.collision_ready:
				chunk.clear_collision()


func process_collision_queue() -> void:

	var collisions_done: int = 0
	var collision_limit := _collision_work_limit()

	while collisions_done < collision_limit:

		if collision_queue.is_empty():
			return

		var chunk_coord: Vector2i = (
			collision_queue.pop_front()
		)

		collision_queued.erase(
			chunk_coord
		)

		if not loaded_chunks.has(
			chunk_coord
		):
			continue

		var chunk = loaded_chunks[
			chunk_coord
		]

		if (
			not is_chunk_within_collision_distance(chunk_coord)
			and not _is_chunk_teleport_required(chunk_coord)
		):
			continue

		if not chunk.mesh_ready:
			continue

		if chunk.collision_ready:
			continue

		var collision_start_usec := Time.get_ticks_usec()
		chunk.build_collision()
		generation_profiler.record(
			"collision",
			float(Time.get_ticks_usec() - collision_start_usec) / 1000.0
		)

		collisions_done += 1


# ===================================================================
# Unloading
# ===================================================================

func unload_chunk(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(
		chunk_coord
	):
		return

	var chunk = loaded_chunks[
		chunk_coord
	]

	if dirty_chunks.has(chunk_coord) and chunk.is_generated:
		WorldStore.save_chunk(
			world_name,
			chunk_coord,
			chunk.blocks
		)
		dirty_chunks.erase(chunk_coord)

	loaded_chunks.erase(
		chunk_coord
	)

	load_queued.erase(
		chunk_coord
	)

	generation_queued.erase(
		chunk_coord
	)

	critical_generation_queued.erase(
		chunk_coord
	)

	critical_mesh_queued.erase(
		chunk_coord
	)

	near_mesh_queued.erase(
		chunk_coord
	)

	far_mesh_queued.erase(
		chunk_coord
	)

	player_edit_queued.erase(
		chunk_coord
	)

	collision_queued.erase(
		chunk_coord
	)

	chunk.queue_free()


# ===================================================================
# Block access
# ===================================================================

func get_block_world(
	world_position: Vector3
) -> int:

	var chunk_coord := world_to_chunk(
		world_position
	)

	if not loaded_chunks.has(
		chunk_coord
	):
		return AIR

	var chunk = loaded_chunks[
		chunk_coord
	]

	if not chunk.is_generated:
		return AIR

	var local_x: int = floori(
		world_position.x -
		chunk_coord.x * CHUNK_SIZE
	)

	var local_y: int = floori(
		world_position.y
	)

	var local_z: int = floori(
		world_position.z -
		chunk_coord.y * CHUNK_SIZE
	)

	return chunk.get_block(
		local_x,
		local_y,
		local_z
	)


func set_block_world(
	world_position: Vector3,
	block_id: int,
	schedule_water: bool = true,
	record_statistics: bool = true,
	prioritize_player_edit: bool = true,
	update_mesh: bool = true
) -> void:

	var chunk_coord := world_to_chunk(
		world_position
	)

	if not loaded_chunks.has(
		chunk_coord
	):
		return

	var chunk = loaded_chunks[
		chunk_coord
	]

	if not chunk.is_generated:
		return

	var local_x: int = floori(
		world_position.x -
		chunk_coord.x * CHUNK_SIZE
	)

	var local_y: int = floori(
		world_position.y
	)

	var local_z: int = floori(
		world_position.z -
		chunk_coord.y * CHUNK_SIZE
	)

	if local_x < 0 or local_x >= CHUNK_SIZE:
		return

	if local_y < 0 or local_y >= CHUNK_HEIGHT:
		return

	if local_z < 0 or local_z >= CHUNK_SIZE:
		return

	var old_block_id: int = chunk.get_block(
		local_x,
		local_y,
		local_z
	)

	if old_block_id == block_id:
		return

	chunk.set_block(
		local_x,
		local_y,
		local_z,
		block_id
	)

	dirty_chunks[chunk_coord] = true

	if record_statistics:
		if old_block_id != AIR and block_id == AIR:
			blocks_broken += 1
		elif old_block_id == AIR and block_id != AIR:
			blocks_placed += 1

	if update_mesh:
		if prioritize_player_edit:
			enqueue_player_edit(
				chunk_coord
			)
		else:
			# Non-player systems can request normal-priority mesh work
			# without stealing the player-edit queue.
			enqueue_mesh_chunk(
				chunk_coord
			)

	if schedule_water:
		var changed := Vector3i(
			floori(world_position.x),
			floori(world_position.y),
			floori(world_position.z)
		)

		_water_schedule(changed)
		_water_schedule_neighbors(changed)

	# Update neighboring chunks when an edit is on a chunk boundary.
	if prioritize_player_edit:
		if local_x == 0:
			enqueue_player_edit(
				chunk_coord + Vector2i(-1, 0)
			)
		elif local_x == CHUNK_SIZE - 1:
			enqueue_player_edit(
				chunk_coord + Vector2i(1, 0)
			)

		if local_z == 0:
			enqueue_player_edit(
				chunk_coord + Vector2i(0, -1)
			)
		elif local_z == CHUNK_SIZE - 1:
			enqueue_player_edit(
				chunk_coord + Vector2i(0, 1)
			)
	else:
		if local_x == 0:
			enqueue_mesh_chunk(
				chunk_coord + Vector2i(-1, 0)
			)
		elif local_x == CHUNK_SIZE - 1:
			enqueue_mesh_chunk(
				chunk_coord + Vector2i(1, 0)
			)

		if local_z == 0:
			enqueue_mesh_chunk(
				chunk_coord + Vector2i(0, -1)
			)
		elif local_z == CHUNK_SIZE - 1:
			enqueue_mesh_chunk(
				chunk_coord + Vector2i(0, 1)
			)


func get_statistics() -> Dictionary:
	return {
		"world_name": world_name,
		"seed": world_seed,
		"play_time_seconds": play_time_seconds,
		"distance_travelled": distance_travelled,
		"blocks_broken": blocks_broken,
		"blocks_placed": blocks_placed
	}


func save_world() -> void:
	if world_name == "":
		return

	for chunk_coord in dirty_chunks:
		if not loaded_chunks.has(chunk_coord):
			continue

		var chunk = loaded_chunks[chunk_coord]

		if not chunk.is_generated:
			continue

		WorldStore.save_chunk(
			world_name,
			chunk_coord,
			chunk.blocks
		)

	dirty_chunks.clear()

	world_metadata["seed"] = world_seed
	world_metadata["blocks_broken"] = blocks_broken
	world_metadata["blocks_placed"] = blocks_placed
	world_metadata["distance_travelled"] = distance_travelled
	world_metadata["play_time_seconds"] = play_time_seconds
	world_metadata["world_time_minutes"] = world_time_minutes

	if player_spawned:
		world_metadata["player_x"] = player.global_position.x
		world_metadata["player_y"] = player.global_position.y
		world_metadata["player_z"] = player.global_position.z
		world_metadata["player_yaw"] = player.rotation.y
		world_metadata["player_pitch"] = player.camera.rotation.x

	WorldStore.save_metadata(
		world_name,
		world_metadata
	)


# ===================================================================
# Loading screen / spawn
# ===================================================================

func get_spawn_area_total() -> int:

	var diameter: int = (
		spawn_load_radius * 2
	) + 1

	return diameter * diameter


func get_spawn_area_ready() -> int:
	var ready_count: int = 0

	for x in range(
		-spawn_load_radius,
		spawn_load_radius + 1
	):
		for z in range(
			-spawn_load_radius,
			spawn_load_radius + 1
		):
			var chunk_coord := Vector2i(
				player_chunk.x + x,
				player_chunk.y + z
			)

			if not loaded_chunks.has(chunk_coord):
				continue

			var chunk = loaded_chunks[chunk_coord]

			if not chunk.is_generated:
				continue

			if not chunk.mesh_ready:
				continue

			ready_count += 1

	return ready_count


func update_loading_progress() -> void:

	if player_spawned:
		return

	var total: int = get_spawn_area_total()
	var completed: int = get_spawn_area_ready()

	loading_screen.set_progress(
		completed,
		total
	)


func try_spawn_player() -> void:

	if player_spawned:
		return

	var spawn_chunk_coord := player_chunk

	if not loaded_chunks.has(
		spawn_chunk_coord
	):
		return

	var total: int = get_spawn_area_total()
	var completed: int = get_spawn_area_ready()

	if completed < total:
		return

	var spawn_chunk = loaded_chunks[
		spawn_chunk_coord
	]

	# The central chunk must have collision before the player is released.
	if not spawn_chunk.collision_ready:
		return

	if not has_saved_player_position:
		var spawn_x: int = 8
		var spawn_z: int = 8

		var highest_y: int = (
			spawn_chunk.get_highest_solid_block(
				spawn_x,
				spawn_z
			)
		)

		if highest_y < 0:
			return

		player.global_position = Vector3(
			spawn_x + 0.5,
			highest_y + 2.0,
			spawn_z + 0.5
		)

	player.velocity = Vector3.ZERO
	stream_direction = Vector2.ZERO
	stream_speed = 0.0

	player_spawned = true

	player.set_physics_process(true)

	last_player_position = player.global_position
	statistics_initialized = true
	player.enable_controls()

	generation_profiler.record(
		"world_loading",
		generation_profiler.get_elapsed_ms()
	)
	print(generation_profiler.get_summary())

	loading_screen.finish()


func _exit_tree() -> void:

	save_world()

	for task_id in generation_tasks:
		var wait_error: Error = (
			WorkerThreadPool.wait_for_task_completion(
				task_id
			)
		)

		if wait_error != OK:
			push_warning(
				"Chunk generation task shutdown error: "
				+ str(wait_error)
			)

	generation_tasks.clear()

	for task_id in mesh_tasks:
		var wait_error: Error = (
			WorkerThreadPool.wait_for_task_completion(
				task_id
			)
		)

		if wait_error != OK:
			push_warning(
				"Chunk mesh task shutdown error: "
				+ str(wait_error)
			)

	mesh_tasks.clear()
