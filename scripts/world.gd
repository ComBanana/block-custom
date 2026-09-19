extends Node3D


const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 64

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


@export_category("World")
@export var render_distance: int = 12


@export_category("Loading")
@export var spawn_load_radius: int = 1


@export_category("Streaming")
@export var chunks_loaded_per_frame: int = 8
@export var max_generation_tasks: int = 8
@export var max_mesh_tasks: int = 6
@export var mesh_columns_per_frame: int = 16
@export var mesh_budget_ms: float = 3.0
@export var max_mesh_chunks_per_frame: int = 12
@export var collisions_per_frame: int = 3
@export var critical_chunk_distance: int = 2


@export_category("Collision")
@export var collision_distance: int = 2

@export_category("Water")
@export var water_updates_per_frame: int = 64
@export var water_tick_interval: float = 0.25


var terrain_noise := FastNoiseLite.new()
var hill_noise := FastNoiseLite.new()
var mountain_region_noise := FastNoiseLite.new()
var mountain_shape_noise := FastNoiseLite.new()

@onready var player: CharacterBody3D = $"../Player"
@onready var loading_screen: Control = $"../LoadingLayer/LoadingScreen"

var chunk_scene := preload("res://scenes/Chunk.tscn")

const TERRAIN_GENERATOR := preload(
	"res://scripts/terrain_generator.gd"
)

class GenerationResult:
	var blocks: PackedByteArray
	var chunk_coordinate: Vector2i


class MeshResult:
	var chunk_coordinate: Vector2i
	var job_id: int = 0
	var snapshot: PackedByteArray
	var buffer: ChunkMesher.MeshBuffer


# ===================================================================
# Loaded chunks
# ===================================================================

var loaded_chunks: Dictionary = {}


# ===================================================================
# Required chunks
# ===================================================================

var required_chunks: Dictionary = {}


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

func _water_flow_level(block_id: int) -> int:
	if block_id >= WATER_FLOW_1 and block_id <= WATER_FLOW_7:
		return block_id - WATER_FLOW_1 + 1
	return 0

func _is_water_flowing(block_id: int) -> bool:
	return block_id >= WATER_FLOW_1 and block_id <= WATER_FLOW_7

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
	return get_block_world(Vector3(position.x + 0.001, position.y + 0.001, position.z + 0.001))

func _water_set(position: Vector3i, block_id: int) -> bool:
	if _water_get(position) == block_id:
		return false
	set_block_world(Vector3(position.x + 0.001, position.y + 0.001, position.z + 0.001), block_id, false)
	return true

func _water_count_source_neighbors(position: Vector3i) -> int:
	var count := 0
	for offset in [Vector3i(-1,0,0), Vector3i(1,0,0), Vector3i(0,0,-1), Vector3i(0,0,1)]:
		if _water_get(position + offset) == WATER:
			count += 1
	return count

func _water_try_source_conversion(position: Vector3i) -> bool:
	var current := _water_get(position)
	if current != AIR and not _is_water_flowing(current):
		return false
	if _water_count_source_neighbors(position) < 2:
		return false
	var below := _water_get(position + Vector3i(0,-1,0))
	if below == AIR or _is_water(below):
		return false
	return _water_set(position, WATER)

func _water_spread_horizontal(position: Vector3i, current_level: int) -> void:
	var target_level := current_level + 1
	if target_level > 7:
		return
	var offsets := [Vector3i(-1,0,0), Vector3i(1,0,0), Vector3i(0,0,-1), Vector3i(0,0,1)]
	var drops: Array[Vector3i] = []
	var opens: Array[Vector3i] = []
	for offset in offsets:
		var target: Vector3i = position + offset
		var target_id := _water_get(target)
		if target_id != AIR and not _is_water_flowing(target_id):
			continue
		if _water_get(target + Vector3i(0,-1,0)) == AIR:
			drops.append(target)
		else:
			opens.append(target)
	var targets := drops if not drops.is_empty() else opens
	for target in targets:
		var target_id := _water_get(target)
		if target_id == WATER or target_id == WATER_FALLING:
			continue
		if _is_water_flowing(target_id) and _water_flow_level(target_id) <= target_level:
			continue
		_water_set(target, WATER + target_level)

func _process_water_position(position: Vector3i) -> void:
	var current := _water_get(position)
	if not _is_water(current):
		return
	var below := position + Vector3i(0,-1,0)
	if _water_get(below) == AIR:
		_water_set(below, WATER_FALLING)
		_water_schedule(below)
		_water_schedule_neighbors(below)
		return
	var level := _water_flow_level(current)
	if not _is_water_flowing(current):
		level = 0
	_water_try_source_conversion(position)
	current = _water_get(position)
	if current == WATER:
		level = 0
	_water_spread_horizontal(position, level)
	_water_schedule_neighbors(position)

func process_water_queue(delta: float) -> void:
	water_tick_accumulator += delta
	if water_tick_accumulator < water_tick_interval:
		return
	water_tick_accumulator = fmod(water_tick_accumulator, water_tick_interval)
	var processed := 0
	while processed < water_updates_per_frame and not water_update_queue.is_empty():
		var position: Vector3i = water_update_queue.pop_front()
		water_updates_queued.erase(position)
		_process_water_position(position)
		processed += 1

func enqueue_water_updates_for_chunk(chunk_coord: Vector2i) -> void:
	if not loaded_chunks.has(chunk_coord):
		return
	var chunk = loaded_chunks[chunk_coord]
	if not chunk.is_generated:
		return
	const WATER_LEVEL: int = 10
	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			if chunk.get_block(x, WATER_LEVEL, z) == WATER:
				_water_schedule(Vector3i(chunk_coord.x * CHUNK_SIZE + x, WATER_LEVEL, chunk_coord.y * CHUNK_SIZE + z))

# ===================================================================
# Collision
# ===================================================================

var collision_queue: Array[Vector2i] = []
var collision_queued: Dictionary = {}

var water_update_queue: Array[Vector3i] = []
var water_updates_queued: Dictionary = {}
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


func _ready() -> void:
	terrain_noise.seed = 12345
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	terrain_noise.frequency = 0.0075
	terrain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	terrain_noise.fractal_octaves = 3
	terrain_noise.fractal_gain = 0.45


	hill_noise.seed = 23456
	hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	hill_noise.frequency = 0.018
	hill_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	hill_noise.fractal_octaves = 2
	hill_noise.fractal_gain = 0.45


	mountain_region_noise.seed = 34567
	mountain_region_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_region_noise.frequency = 0.0035
	mountain_region_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	mountain_region_noise.fractal_octaves = 2
	mountain_region_noise.fractal_gain = 0.5


	mountain_shape_noise.seed = 45678
	mountain_shape_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_shape_noise.frequency = 0.009
	mountain_shape_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_shape_noise.fractal_octaves = 3
	mountain_shape_noise.fractal_gain = 0.5

	player.set_physics_process(false)
	player.velocity = Vector3.ZERO

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	player_chunk = world_to_chunk(
		player.global_position
	)

	update_chunks()


func _process(delta: float) -> void:
	if player_spawned:
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

	if not player_spawned:
		update_loading_progress()
		try_spawn_player()


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

	return (
		dx <= critical_chunk_distance
		and dz <= critical_chunk_distance
	)

# ===================================================================
# Required chunks
# ===================================================================

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

				if not required_chunks.has(
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


	# Unload chunks outside render distance.
	var chunks_to_remove: Array[Vector2i] = []

	for chunk_coord in loaded_chunks:

		if not required_chunks.has(
			chunk_coord
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

	while (
		loads_done < chunks_loaded_per_frame
		and not load_queue.is_empty()
	):

		var chunk_coord: Vector2i = (
			load_queue.pop_front()
		)

		load_queued.erase(
			chunk_coord
		)

		if not required_chunks.has(
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


func load_chunk(
	chunk_coord: Vector2i
) -> void:

	var chunk = chunk_scene.instantiate()

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

	loaded_chunks[chunk_coord] = chunk

	add_child(chunk)

	# The current chunk.gd still uses the original generate_terrain().
	if is_chunk_critical(chunk_coord):

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
	chunk_coordinate: Vector2i
) -> void:

	result.chunk_coordinate = chunk_coordinate
	result.blocks = (
		TERRAIN_GENERATOR.generate_chunk_data(
			chunk_coordinate
		)
	)


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
		if not required_chunks.has(
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

		enqueue_water_updates_for_chunk(chunk_coord)

		enqueue_mesh_chunk(
			chunk_coord
		)


		enqueue_neighbor_meshes(
			chunk_coord
		)


	# ---------------------------------------------------------------
	# SUBMIT NEW GENERATION TASKS
	# ---------------------------------------------------------------

	if max_generation_tasks <= 0:
		return


	while (
		generation_tasks.size()
		< max_generation_tasks
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


		if not required_chunks.has(
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
				chunk_coord
			)
		)


		var high_priority: bool = (
			is_chunk_critical(
				chunk_coord
			)
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

	# ---------------------------------------------------------------
	# CRITICAL GENERATION
	# ---------------------------------------------------------------

	while not critical_generation_queue.is_empty():

		var critical_coord: Vector2i = (
			critical_generation_queue.pop_front()
		)

		critical_generation_queued.erase(
			critical_coord
		)


		if not loaded_chunks.has(
			critical_coord
		):
			continue


		if not required_chunks.has(
			critical_coord
		):
			continue


		var critical_chunk = loaded_chunks[
			critical_coord
		]


		if critical_chunk.is_generated:
			continue


		return critical_coord


	# ---------------------------------------------------------------
	# NORMAL GENERATION
	# ---------------------------------------------------------------

	while not generation_queue.is_empty():

		var chunk_coord: Vector2i = (
			generation_queue.pop_front()
		)

		generation_queued.erase(
			chunk_coord
		)


		if not loaded_chunks.has(
			chunk_coord
		):
			continue


		if not required_chunks.has(
			chunk_coord
		):
			continue


		var chunk = loaded_chunks[
			chunk_coord
		]


		if chunk.is_generated:
			continue


		# A chunk can become critical while waiting in
		# the normal queue.
		if is_chunk_critical(
			chunk_coord
		):

			if not critical_generation_queued.has(
				chunk_coord
			):

				critical_generation_queue.push_back(
					chunk_coord
				)

				critical_generation_queued[
					chunk_coord
				] = true

			continue


		return chunk_coord


	return INVALID_CHUNK


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
	
	if is_chunk_critical(chunk_coord):

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

func process_mesh_queue() -> void:

	var start_usec: int = Time.get_ticks_usec()
	var processed_chunks: int = 0

	while (
		processed_chunks < max_mesh_chunks_per_frame
	):

		var elapsed_ms: float = (
			float(
				Time.get_ticks_usec() -
				start_usec
			) / 1000.0
		)

		if elapsed_ms >= mesh_budget_ms:
			return

		var chunk_coord: Vector2i = (
			get_next_mesh_candidate()
		)

		if chunk_coord == INVALID_CHUNK:
			return

		if not loaded_chunks.has(
			chunk_coord
		):
			continue

		var chunk = loaded_chunks[
			chunk_coord
		]

		if not chunk.is_generated:
			continue

		var remaining_ms: float = (
			mesh_budget_ms - elapsed_ms
		)

		if not chunk.mesh_building:
			chunk.begin_mesh_build()

		chunk.process_mesh_step(
			mesh_columns_per_frame,
			remaining_ms
		)

		if chunk.mesh_building:

			# The chunk did not finish this frame.
			# Put it back into the appropriate priority queue.

			if player_edit_queued.has(chunk_coord):

				player_edit_queue.push_back(
					chunk_coord
				)

				player_edit_queued[chunk_coord] = true

			elif is_chunk_critical(chunk_coord):

				critical_mesh_queue.push_back(
					chunk_coord
				)

				critical_mesh_queued[chunk_coord] = true

			elif get_chunk_stream_priority(chunk_coord) == PRIORITY_NEAR:

				near_mesh_queue.push_back(
					chunk_coord
				)

				near_mesh_queued[chunk_coord] = true

			else:

				far_mesh_queue.push_back(
					chunk_coord
				)

				far_mesh_queued[chunk_coord] = true

		else:

			enqueue_collision_chunk(
				chunk_coord
			)

		processed_chunks += 1


# ===================================================================
# Choose next mesh job
# ===================================================================

func get_next_mesh_candidate() -> Vector2i:

	# ---------------------------------------------------------------
	# PLAYER EDIT
	# ---------------------------------------------------------------

	while not player_edit_queue.is_empty():

		var player_coord: Vector2i = (
			player_edit_queue.pop_front()
		)

		if not player_edit_queued.has(
			player_coord
		):
			continue

		player_edit_queued.erase(
			player_coord
		)

		active_mesh_priority = PRIORITY_PLAYER

		return player_coord


	# ---------------------------------------------------------------
	# CRITICAL
	# ---------------------------------------------------------------

	while not critical_mesh_queue.is_empty():

		var critical_coord: Vector2i = (
			critical_mesh_queue.pop_front()
		)

		if not critical_mesh_queued.has(
			critical_coord
		):
			continue

		critical_mesh_queued.erase(
			critical_coord
		)

		active_mesh_priority = PRIORITY_NEAR

		return critical_coord


	# ---------------------------------------------------------------
	# NEAR
	# ---------------------------------------------------------------

	while not near_mesh_queue.is_empty():

		var near_coord: Vector2i = (
			near_mesh_queue.pop_front()
		)

		if not near_mesh_queued.has(
			near_coord
		):
			continue

		near_mesh_queued.erase(
			near_coord
		)

		active_mesh_priority = PRIORITY_NEAR

		return near_coord


	# ---------------------------------------------------------------
	# FAR
	# ---------------------------------------------------------------

	while not far_mesh_queue.is_empty():

		var far_coord: Vector2i = (
			far_mesh_queue.pop_front()
		)

		if not far_mesh_queued.has(
			far_coord
		):
			continue

		far_mesh_queued.erase(
			far_coord
		)

		active_mesh_priority = PRIORITY_FAR

		return far_coord


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

	if not is_chunk_within_collision_distance(
		chunk_coord
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

	if is_chunk_critical(chunk_coord):

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

		if is_chunk_within_collision_distance(
			chunk_coord
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

	while collisions_done < collisions_per_frame:

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

		if not is_chunk_within_collision_distance(
			chunk_coord
		):
			continue

		if not chunk.mesh_ready:
			continue

		if chunk.collision_ready:
			continue

		chunk.build_collision()

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

	loaded_chunks.erase(
		chunk_coord
	)

	load_queued.erase(
		chunk_coord
	)

	generation_queued.erase(
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
	schedule_water: bool = true
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

	var old_block_id: int = chunk.get_block(local_x, local_y, local_z)

	chunk.set_block(local_x, local_y, local_z, block_id)

	enqueue_player_edit(chunk_coord)

	if schedule_water and old_block_id != block_id:
		var changed := Vector3i(floori(world_position.x), floori(world_position.y), floori(world_position.z))
		if _is_water(old_block_id) or _is_water(block_id):
			_water_schedule(changed)
			_water_schedule_neighbors(changed)

	# Update neighboring chunk if the edited voxel is on an edge.
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
			var chunk_coord := Vector2i(x, z)

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

	var spawn_chunk_coord := Vector2i.ZERO

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

	player_spawned = true

	player.set_physics_process(true)

	player.enable_controls()

	loading_screen.finish()


func _exit_tree() -> void:

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
