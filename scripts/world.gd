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
const TELEPORT_PRELOAD_RADIUS: int = 1


@export_category("World")
@export_range(2, 64, 1) var render_distance: int = 12


@export_category("Loading")
@export var spawn_load_radius: int = 1


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
@export var water_updates_per_frame: int = 64
@export var water_tick_interval: float = 0.25


var terrain_noise := FastNoiseLite.new()
var hill_noise := FastNoiseLite.new()
var mountain_region_noise := FastNoiseLite.new()
var mountain_shape_noise := FastNoiseLite.new()

@onready var player: CharacterBody3D = $"../Player"
@onready var loading_screen: Control = $"../LoadingLayer/LoadingScreen"
@onready var world_environment: WorldEnvironment = $"../WorldEnvironment"

var chunk_scene := preload("res://scenes/Chunk.tscn")

const TERRAIN_GENERATOR := preload(
	"res://scripts/terrain_generator.gd"
)

const GRASS_TEXTURE := preload("res://textures/grass.png")
const DIRT_TEXTURE := preload("res://textures/dirt.png")
const STONE_TEXTURE := preload("res://textures/stone.png")
const SAND_TEXTURE := preload("res://textures/sand.png")
const WATER_TEXTURE := preload("res://textures/water.png")

var grass_material: StandardMaterial3D
var dirt_material: StandardMaterial3D
var stone_material: StandardMaterial3D
var sand_material: StandardMaterial3D
var water_material: StandardMaterial3D


class GenerationResult:
	var blocks: PackedByteArray
	var chunk_coordinate: Vector2i


class MeshResult:
	var chunk_coordinate: Vector2i
	var job_id: int = 0
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
		false
	)

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

	if below == AIR or _is_water(below):
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


func _water_spread_horizontal(
	position: Vector3i,
	current_level: int
) -> void:
	if current_level >= 7:
		return

	var next_level: int = current_level + 1
	var next_block: int = _water_block_for_level(
		next_level
	)

	var offsets: Array[Vector3i] = [
		Vector3i(-1, 0, 0),
		Vector3i(1, 0, 0),
		Vector3i(0, 0, -1),
		Vector3i(0, 0, 1)
	]

	for offset: Vector3i in offsets:
		var target: Vector3i = position + offset
		var target_id := _water_get(target)

		if target_id == WATER or target_id == WATER_FALLING:
			continue

		if target_id == AIR:
			_water_set(target, next_block)
			_water_schedule(target)
			_water_schedule_neighbors(target)
			continue

		if _is_water_flowing(target_id):
			var target_level := _water_flow_level(
				target_id
			)

			if target_level > next_level:
				_water_set(target, next_block)
				_water_schedule(target)
				_water_schedule_neighbors(target)


func _process_water_position(
	position: Vector3i
) -> void:
	var current := _water_get(position)

	# Empty cells can become infinite-water sources when two
	# source blocks surround them and the floor is solid.
	if (
		current == AIR
		and _water_try_source_conversion(position)
	):
		current = WATER

	if not _is_water(current):
		return

	var below_position := position + Vector3i(
		0,
		-1,
		0
	)

	var below := _water_get(below_position)

	# Water always takes an available block below before
	# attempting horizontal spread.
	if below == AIR:
		_water_set(
			below_position,
			WATER_FALLING
		)
		_water_schedule(below_position)
		_water_schedule_neighbors(below_position)
		return

	# Falling water becomes ordinary flowing water once
	# it has reached a solid surface. It is not promoted to
	# a permanent source block.
	if current == WATER_FALLING:
		if not _water_has_upstream_supply(position, 1):
			_water_set(position, AIR)
			_water_schedule_neighbors(position)
			return

		_water_set(position, WATER_FLOW_1)
		current = WATER_FLOW_1

	# Flowing water retracts when no source or lower-level
	# flow can still feed it.
	if _is_water_flowing(current):
		var current_level := _water_flow_level(current)

		if not _water_has_upstream_supply(
			position,
			current_level
		):
			_water_set(position, AIR)
			_water_schedule_neighbors(position)
			return

		_water_spread_horizontal(
			position,
			current_level
		)

		_water_schedule_neighbors(position)
		return

	# Sources remain in place and spread as level 1 flow.
	if current == WATER:
		_water_spread_horizontal(
			position,
			0
		)
		_water_schedule_neighbors(position)


func process_water_queue(delta: float) -> void:
	water_tick_accumulator += delta

	if water_tick_accumulator < water_tick_interval:
		return

	water_tick_accumulator = fmod(
		water_tick_accumulator,
		water_tick_interval
	)

	var processed: int = 0

	while (
		processed < water_updates_per_frame
		and not water_update_queue.is_empty()
	):
		var position: Vector3i = (
			water_update_queue.pop_front()
		)

		water_updates_queued.erase(
			position
		)

		_process_water_position(position)
		processed += 1


func enqueue_water_updates_for_chunk(
	chunk_coord: Vector2i
) -> void:
	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

	if not chunk.is_generated:
		return

	const WATER_LEVEL: int = 10

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			if chunk.get_block(
				x,
				WATER_LEVEL,
				z
			) == WATER:
				_water_schedule(
					Vector3i(
						chunk_coord.x * CHUNK_SIZE + x,
						WATER_LEVEL,
						chunk_coord.y * CHUNK_SIZE + z
					)
				)


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

	_apply_fog_settings()

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

	var view_distance := float(render_distance * CHUNK_SIZE)
	var fog_begin := maxf(
		32.0,
		view_distance * 0.55
	)
	var fog_end := maxf(
		fog_begin + 16.0,
		view_distance * 0.92
	)

	environment.fog_light_color = Color(
		0.75,
		0.90,
		1.0,
		1.0
	)
	environment.fog_density = 0.01
	environment.fog_sky_affect = 0.95
	environment.fog_depth_begin = fog_begin
	environment.fog_depth_end = fog_end


func _create_shared_materials() -> void:
	grass_material = StandardMaterial3D.new()
	grass_material.albedo_texture = GRASS_TEXTURE
	grass_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

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

	# Share the same materials across every chunk. This avoids
	# creating five new StandardMaterial3D resources per chunk.
	chunk.grass_material = grass_material
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

	if saved_blocks.size() == expected_size:
		chunk.apply_generated_data(saved_blocks)
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
	result.blocks = (
		TERRAIN_GENERATOR.generate_chunk_data(
			chunk_coordinate,
			seed
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

		# Generated terrain water is already filled to the world water
		# level. Do not enqueue every water source for simulation here;
		# that creates a large backlog as new chunks are explored.
		# Water will still be scheduled by actual block changes.
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


		if not _is_chunk_needed(
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


		if not _is_chunk_needed(
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
		if (
			is_chunk_critical(chunk_coord)
			or _is_chunk_teleport_required(chunk_coord)
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


func _build_mesh_worker(
	result: MeshResult
) -> void:
	result.buffer = ChunkMesher.build_from_blocks(
		result.center_blocks,
		result.neg_x_blocks,
		result.pos_x_blocks,
		result.neg_z_blocks,
		result.pos_z_blocks
	)


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

	for task_id in completed_tasks:
		if (
			applied_count >= max_mesh_chunks_per_frame
			and max_mesh_chunks_per_frame > 0
		):
			break

		if (
			applied_count > 0
			and mesh_budget_ms > 0.0
			and float(
				Time.get_ticks_usec() - apply_start_usec
			) / 1000.0 >= mesh_budget_ms
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

		chunk.apply_mesh_buffer(result.buffer)
		enqueue_collision_chunk(
			result.chunk_coordinate
		)
		applied_count += 1

	# ---------------------------------------------------------------
	# SUBMIT NEW WORK
	# ---------------------------------------------------------------

	if max_mesh_tasks <= 0:
		return

	while mesh_tasks.size() < max_mesh_tasks:
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

		if (
			not is_chunk_within_collision_distance(chunk_coord)
			and not _is_chunk_teleport_required(chunk_coord)
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
	record_statistics: bool = true
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

	enqueue_player_edit(
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

	player_spawned = true

	player.set_physics_process(true)

	last_player_position = player.global_position
	statistics_initialized = true
	player.enable_controls()

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
