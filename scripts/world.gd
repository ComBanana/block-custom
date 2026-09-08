extends Node3D


const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 24

const AIR: int = 0
const GRASS: int = 1
const DIRT: int = 2
const STONE: int = 3

const INVALID_CHUNK := Vector2i(999999, 999999)


@export_category("World")
@export var render_distance: int = 4


@export_category("Loading")
@export var spawn_load_radius: int = 1


@export_category("Streaming")
@export var chunks_loaded_per_frame: int = 1
@export var mesh_columns_per_frame: int = 4
@export var mesh_budget_ms: float = 2.0
@export var collisions_per_frame: int = 1


var terrain_noise := FastNoiseLite.new()

@onready var player: CharacterBody3D = $"../Player"
@onready var loading_screen: Control = $"../LoadingLayer/LoadingScreen"

var chunk_scene := preload("res://scenes/Chunk.tscn")


var loaded_chunks: Dictionary = {}

var load_queue: Array[Vector2i] = []
var load_queued: Dictionary = {}

var mesh_queue: Array[Vector2i] = []
var mesh_queued: Dictionary = {}

var collision_queue: Array[Vector2i] = []
var collision_queued: Dictionary = {}

var required_chunks: Dictionary = {}


var player_chunk := Vector2i.ZERO

var selected_block: int = GRASS

var player_spawned: bool = false


func _ready() -> void:
	terrain_noise.seed = 12345
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	terrain_noise.frequency = 0.015

	# Player must not move or receive gameplay control
	# while the loading screen is active.
	player.set_physics_process(false)
	player.velocity = Vector3.ZERO

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	player_chunk = world_to_chunk(player.global_position)

	update_chunks()


func _process(_delta: float) -> void:
	# Only let the player affect streaming after spawning.
	if player_spawned:
		var current_chunk := world_to_chunk(
			player.global_position
		)

		if current_chunk != player_chunk:
			player_chunk = current_chunk
			update_chunks()

	process_load_queue()
	process_generation_queue()
	process_mesh_queue()
	process_collision_queue()

	if not player_spawned:
		update_loading_progress()
		try_spawn_player()


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

			if not loaded_chunks.has(chunk_coord):
				if not load_queued.has(chunk_coord):
					load_queue.append(chunk_coord)
					load_queued[chunk_coord] = true

	var chunks_to_remove: Array[Vector2i] = []

	for chunk_coord in loaded_chunks:
		if not required_chunks.has(chunk_coord):
			chunks_to_remove.append(chunk_coord)

	for chunk_coord in chunks_to_remove:
		unload_chunk(chunk_coord)


func process_load_queue() -> void:
	var loads_done: int = 0

	while loads_done < chunks_loaded_per_frame:
		var chunk_coord := get_nearest_load_candidate()

		if chunk_coord == INVALID_CHUNK:
			return

		load_queued.erase(chunk_coord)

		if not required_chunks.has(chunk_coord):
			continue

		if loaded_chunks.has(chunk_coord):
			continue

		load_chunk(chunk_coord)

		loads_done += 1


func get_nearest_load_candidate() -> Vector2i:
	var best_coord := INVALID_CHUNK
	var best_distance: int = 2147483647

	for queued_coord in load_queue:
		if not load_queued.has(queued_coord):
			continue

		if not required_chunks.has(queued_coord):
			continue

		var dx: int = (
			queued_coord.x -
			player_chunk.x
		)

		var dz: int = (
			queued_coord.y -
			player_chunk.y
		)

		var distance: int = (
			dx * dx +
			dz * dz
		)

		if distance < best_distance:
			best_distance = distance
			best_coord = queued_coord

	if best_coord == INVALID_CHUNK:
		return INVALID_CHUNK

	load_queue.erase(best_coord)

	return best_coord


func load_chunk(
	chunk_coord: Vector2i
) -> void:

	var chunk = chunk_scene.instantiate()

	chunk.position = Vector3(
		chunk_coord.x * CHUNK_SIZE,
		0,
		chunk_coord.y * CHUNK_SIZE
	)

	chunk.chunk_coordinate = chunk_coord
	chunk.terrain_noise = terrain_noise

	loaded_chunks[chunk_coord] = chunk

	add_child(chunk)


func process_generation_queue() -> void:
	for chunk_coord in loaded_chunks:
		var chunk = loaded_chunks[chunk_coord]

		if not chunk.is_generated:
			chunk.generate_terrain()
			chunk.is_generated = true

			enqueue_mesh_chunk(chunk_coord)

			# If neighbors already exist, their boundary faces
			# may need to be rebuilt now that this chunk exists.
			enqueue_neighbor_meshes(chunk_coord)

			return


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

		if neighbor.is_generated:
			enqueue_mesh_chunk(
				neighbor_coordinate
			)


func enqueue_mesh_chunk(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

	if not chunk.is_generated:
		return

	if chunk.mesh_building:
		return

	if mesh_queued.has(chunk_coord):
		return

	mesh_queue.append(chunk_coord)
	mesh_queued[chunk_coord] = true


func enqueue_mesh_chunk_priority(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

	if not chunk.is_generated:
		return

	# If this chunk is currently being rebuilt, restart
	# its mesh from the beginning using the updated block data.
	if chunk.mesh_building:
		chunk.cancel_mesh_build()

		mesh_queue.erase(chunk_coord)
		mesh_queued.erase(chunk_coord)

	# Remove an existing queued copy so we don't duplicate it.
	if mesh_queued.has(chunk_coord):
		mesh_queue.erase(chunk_coord)
		mesh_queued.erase(chunk_coord)

	# Put edited chunks at the FRONT of the queue.
	mesh_queue.push_front(chunk_coord)
	mesh_queued[chunk_coord] = true


func process_mesh_queue() -> void:
	var chunk_coord: Vector2i = (
		get_next_mesh_candidate()
	)

	if chunk_coord == INVALID_CHUNK:
		return

	if not loaded_chunks.has(chunk_coord):
		return

	mesh_queued.erase(chunk_coord)

	var chunk = loaded_chunks[chunk_coord]

	if not chunk.is_generated:
		return

	if not chunk.mesh_building:
		chunk.begin_mesh_build()

	chunk.process_mesh_step(
		mesh_columns_per_frame,
		mesh_budget_ms
	)

	# CRITICAL:
	# If the mesh isn't finished, put it back into
	# the queue so it continues on a later frame.
	if chunk.mesh_building:
		if not mesh_queued.has(chunk_coord):
			mesh_queue.append(chunk_coord)
			mesh_queued[chunk_coord] = true
	else:
		enqueue_collision_chunk(chunk_coord)


func get_next_mesh_candidate() -> Vector2i:
	while not mesh_queue.is_empty():
		var coord: Vector2i = mesh_queue.pop_front()

		if mesh_queued.has(coord):
			return coord

	return INVALID_CHUNK


func enqueue_collision_chunk(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

	if not chunk.mesh_ready:
		return

	if collision_queued.has(chunk_coord):
		return

	collision_queue.append(chunk_coord)
	collision_queued[chunk_coord] = true


func process_collision_queue() -> void:
	var collisions_done: int = 0

	while collisions_done < collisions_per_frame:
		if collision_queue.is_empty():
			return

		var chunk_coord: Vector2i = (
			collision_queue.pop_front()
		)

		collision_queued.erase(chunk_coord)

		if not loaded_chunks.has(chunk_coord):
			continue

		var chunk = loaded_chunks[chunk_coord]

		chunk.build_collision()

		collisions_done += 1


func unload_chunk(
	chunk_coord: Vector2i
) -> void:

	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

	loaded_chunks.erase(chunk_coord)

	mesh_queued.erase(chunk_coord)
	collision_queued.erase(chunk_coord)
	load_queued.erase(chunk_coord)

	chunk.queue_free()

	# The neighbor may now need its boundary face again.
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

		if loaded_chunks.has(
			neighbor_coordinate
		):
			var neighbor = loaded_chunks[
				neighbor_coordinate
			]

			if neighbor.is_generated:
				enqueue_mesh_chunk(
					neighbor_coordinate
				)


func get_block_world(
	world_position: Vector3
) -> int:

	var chunk_coord := world_to_chunk(
		world_position
	)

	if not loaded_chunks.has(chunk_coord):
		return AIR

	var chunk = loaded_chunks[chunk_coord]

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
	block_id: int
) -> void:

	var chunk_coord := world_to_chunk(
		world_position
	)

	if not loaded_chunks.has(chunk_coord):
		return

	var chunk = loaded_chunks[chunk_coord]

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

	chunk.set_block(
		local_x,
		local_y,
		local_z,
		block_id
	)

	enqueue_mesh_chunk_priority(chunk_coord)

	# Update neighboring chunk when editing a boundary block.
	if local_x == 0:
		enqueue_mesh_chunk_priority(
			chunk_coord + Vector2i(-1, 0)
		)

	elif local_x == CHUNK_SIZE - 1:
		enqueue_mesh_chunk_priority(
			chunk_coord + Vector2i(1, 0)
		)

	if local_z == 0:
		enqueue_mesh_chunk_priority(
			chunk_coord + Vector2i(0, -1)
		)

	elif local_z == CHUNK_SIZE - 1:
		enqueue_mesh_chunk_priority(
			chunk_coord + Vector2i(0, 1)
		)


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

			var chunk = loaded_chunks[
				chunk_coord
			]

			if not chunk.is_generated:
				continue

			if not chunk.mesh_ready:
				continue

			if not chunk.collision_ready:
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

	# Require the entire spawn area to be ready.
	var total: int = get_spawn_area_total()
	var completed: int = get_spawn_area_ready()

	if completed < total:
		return

	var spawn_chunk = loaded_chunks[
		spawn_chunk_coord
	]

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

	# Put player safely above the surface.
	player.global_position = Vector3(
		spawn_x + 0.5,
		highest_y + 2.0,
		spawn_z + 0.5
	)

	player.velocity = Vector3.ZERO

	player_spawned = true

	# Enable player physics after the world is ready.
	player.set_physics_process(true)

	# Give the player back mouse/game control.
	player.enable_controls()

	loading_screen.finish()
