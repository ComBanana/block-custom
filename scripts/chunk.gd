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

const GRASS_TEXTURE := preload("res://textures/grass.png")
const DIRT_TEXTURE := preload("res://textures/dirt.png")
const STONE_TEXTURE := preload("res://textures/stone.png")
const SAND_TEXTURE := preload("res://textures/sand.png")
const WATER_TEXTURE := preload("res://textures/water.png")

var blocks := PackedByteArray()

var chunk_coordinate := Vector2i.ZERO

var terrain_noise: FastNoiseLite
var hill_noise: FastNoiseLite
var mountain_region_noise: FastNoiseLite
var mountain_shape_noise: FastNoiseLite

var generation_passes_done: bool = false
var mesh_ready: bool = false
var collision_ready: bool = false

var is_generated: bool = false
var terrain_generating: bool = false
var mesh_building: bool = false

var terrain_x: int = 0
var mesh_x: int = 0

var grass_material: StandardMaterial3D
var dirt_material: StandardMaterial3D
var stone_material: StandardMaterial3D
var sand_material: StandardMaterial3D
var water_material: StandardMaterial3D

var mesh_job_id: int = 0
var collision_faces := PackedVector3Array()


func _ready() -> void:
	# World assigns shared materials before this node enters the tree.
	# The fallback creation keeps Chunk.tscn safe to instantiate by itself.
	if grass_material == null:
		grass_material = StandardMaterial3D.new()
		grass_material.albedo_texture = GRASS_TEXTURE
		grass_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	if dirt_material == null:
		dirt_material = StandardMaterial3D.new()
		dirt_material.albedo_texture = DIRT_TEXTURE
		dirt_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	if stone_material == null:
		stone_material = StandardMaterial3D.new()
		stone_material.albedo_texture = STONE_TEXTURE
		stone_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	if sand_material == null:
		sand_material = StandardMaterial3D.new()
		sand_material.albedo_texture = SAND_TEXTURE
		sand_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	if water_material == null:
		water_material = StandardMaterial3D.new()
		water_material.albedo_texture = WATER_TEXTURE
		water_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		water_material.albedo_color = Color(1.0, 1.0, 1.0, 0.5)
		water_material.cull_mode = BaseMaterial3D.CULL_DISABLED


func _get_index(x: int, y: int, z: int) -> int:
	return x + (z * CHUNK_SIZE) + (y * CHUNK_SIZE * CHUNK_SIZE)


func set_block(x: int, y: int, z: int, block_id: int) -> void:
	if x < 0 or x >= CHUNK_SIZE:
		return

	if y < 0 or y >= CHUNK_HEIGHT:
		return

	if z < 0 or z >= CHUNK_SIZE:
		return

	blocks[_get_index(x, y, z)] = block_id


func get_block(x: int, y: int, z: int) -> int:
	if x < 0 or x >= CHUNK_SIZE:
		return AIR

	if y < 0 or y >= CHUNK_HEIGHT:
		return AIR

	if z < 0 or z >= CHUNK_SIZE:
		return AIR

	return blocks[_get_index(x, y, z)]


func begin_terrain_generation() -> void:
	blocks.resize(
		CHUNK_SIZE *
		CHUNK_HEIGHT *
		CHUNK_SIZE
	)

	blocks.fill(AIR)

	terrain_x = 0
	terrain_generating = true

	is_generated = false
	mesh_ready = false
	collision_ready = false


func process_terrain_generation_step(
	max_columns: int,
	budget_ms: float
) -> void:

	if not terrain_generating:
		begin_terrain_generation()

	var start_usec: int = Time.get_ticks_usec()
	var columns_done: int = 0

	while terrain_x < CHUNK_SIZE:

		var x: int = terrain_x

		for z in range(CHUNK_SIZE):

			var world_x: int = (
				chunk_coordinate.x *
				CHUNK_SIZE +
				x
			)

			var world_z: int = (
				chunk_coordinate.y *
				CHUNK_SIZE +
				z
			)

			var base_value: float = (
				terrain_noise.get_noise_2d(
					world_x,
					world_z
				)
			)

			var hill_value: float = (
				hill_noise.get_noise_2d(
					world_x,
					world_z
				)
			)

			var mountain_region_value: float = (
				mountain_region_noise.get_noise_2d(
					world_x,
					world_z
				)
			)

			var mountain_shape_value: float = (
				mountain_shape_noise.get_noise_2d(
					world_x,
					world_z
				)
			)

			var base_height: float = (
				12.0 +
				base_value * 4.0
			)

			var hill_height: float = (
				hill_value * 5.0
			)

			# Convert the mountain-region noise from roughly [-1, 1]
			# into a smooth 0-1 mask.
			var mountain_mask: float = (
				mountain_region_value * 0.5
			) + 0.5

			mountain_mask = smoothstep(
				0.58,
				0.78,
				mountain_mask
			)

			# Ridged noise gives the mountain area its actual relief.
			var mountain_height: float = (
				mountain_shape_value * 28.0
			)

			var height_float: float = (
				base_height +
				hill_height +
				(mountain_height * mountain_mask)
			)

			var height: int = clampi(
				roundi(height_float),
				4,
				CHUNK_HEIGHT
			)

			height = clampi(
				height,
				4,
				CHUNK_HEIGHT
			)

			var dirt_depth: int = _get_dirt_depth(
				world_x,
				world_z
			)

			for y in range(height):

				if y == height - 1:

					set_block(
						x,
						y,
						z,
						GRASS
					)

				elif y >= height - dirt_depth:

					set_block(
						x,
						y,
						z,
						DIRT
					)

				else:

					set_block(
						x,
						y,
						z,
						STONE
					)

		terrain_x += 1
		columns_done += 1

		var elapsed_ms: float = (
			float(
				Time.get_ticks_usec() -
				start_usec
			) / 1000.0
		)

		if columns_done >= max_columns:
			break

		if elapsed_ms >= budget_ms:
			break

	if terrain_x >= CHUNK_SIZE:
		terrain_generating = false
		is_generated = true


func _get_dirt_depth(
	world_x: int,
	world_z: int
) -> int:

	var value: int = (
		world_x * 374761393
		+ world_z * 668265263
		+ terrain_noise.seed * 1442695041
	)

	value = value ^ (value >> 13)
	value = value * 1274126177
	value = value ^ (value >> 16)

	return 1 + posmod(absi(value), 3)


func generate_terrain() -> void:
	if is_generated:
		return

	begin_terrain_generation()

	while terrain_generating:
		process_terrain_generation_step(
			CHUNK_SIZE,
			1000000.0
		)

	if not generation_passes_done:
		replace_air_with_water()
		replace_water_touching_blocks_with_sand()
		generation_passes_done = true

	is_generated = true


func replace_air_with_water() -> void:
	const WATER_LEVEL := 10

	for x in range(CHUNK_SIZE):
		for y in range(WATER_LEVEL + 1):
			for z in range(CHUNK_SIZE):

				if get_block(x, y, z) == AIR:
					set_block(
						x,
						y,
						z,
						WATER
					)


func replace_water_touching_blocks_with_sand() -> void:
	var blocks_to_sand: Array[Vector3i] = []

	for x in range(CHUNK_SIZE):
		for y in range(CHUNK_HEIGHT):
			for z in range(CHUNK_SIZE):

				var block_id: int = get_block(
					x,
					y,
					z
				)

				if block_id == AIR:
					continue

				if block_id == WATER:
					continue

				if _is_touching_water(
					x,
					y,
					z
				):
					blocks_to_sand.append(
						Vector3i(x, y, z)
					)

	for block_position in blocks_to_sand:
		set_block(
			block_position.x,
			block_position.y,
			block_position.z,
			SAND
		)


func _is_touching_water(
	x: int,
	y: int,
	z: int
) -> bool:

	if _get_block_for_generation(x, y + 1, z) == WATER:
		return true

	if _get_block_for_generation(x, y - 1, z) == WATER:
		return true

	if _get_block_for_generation(x - 1, y, z) == WATER:
		return true

	if _get_block_for_generation(x + 1, y, z) == WATER:
		return true

	if _get_block_for_generation(x, y, z - 1) == WATER:
		return true

	if _get_block_for_generation(x, y, z + 1) == WATER:
		return true

	return false


func _get_block_for_generation(
	x: int,
	y: int,
	z: int
) -> int:

	# Normal in-chunk lookup.
	if (
		x >= 0
		and x < CHUNK_SIZE
		and y >= 0
		and y < CHUNK_HEIGHT
		and z >= 0
		and z < CHUNK_SIZE
	):
		return get_block(x, y, z)

	# Outside the world vertically.
	if y < 0 or y >= CHUNK_HEIGHT:
		return AIR

	var world = get_parent()

	if world == null:
		return AIR

	var neighbor_coordinate := chunk_coordinate

	var neighbor_x := x
	var neighbor_z := z

	if x < 0:
		neighbor_coordinate.x -= 1
		neighbor_x += CHUNK_SIZE

	elif x >= CHUNK_SIZE:
		neighbor_coordinate.x += 1
		neighbor_x -= CHUNK_SIZE

	if z < 0:
		neighbor_coordinate.y -= 1
		neighbor_z += CHUNK_SIZE

	elif z >= CHUNK_SIZE:
		neighbor_coordinate.y += 1
		neighbor_z -= CHUNK_SIZE

	if not world.loaded_chunks.has(
		neighbor_coordinate
	):
		return AIR

	var neighbor = world.loaded_chunks[
		neighbor_coordinate
	]

	# The neighbor must have completed terrain + water generation.
	if not neighbor.is_generated:
		return AIR

	return neighbor.get_block(
		neighbor_x,
		y,
		neighbor_z
	)


func apply_generated_data(
	generated_blocks: PackedByteArray
) -> void:

	blocks = generated_blocks

	terrain_x = CHUNK_SIZE
	terrain_generating = false

	generation_passes_done = true

	is_generated = true
	mesh_ready = false
	collision_ready = false


func capture_mesh_snapshot() -> PackedByteArray:
	return ChunkMesher.capture_snapshot(self, get_parent())


func cancel_mesh_build() -> void:
	mesh_building = false
	mesh_ready = false
	mesh_job_id += 1


func apply_mesh_buffer(buffer: ChunkMesher.MeshBuffer) -> void:
	var solid_mesh := ArrayMesh.new()
	var water_mesh := ArrayMesh.new()

	_add_mesh_surface(
		solid_mesh,
		grass_material,
		buffer.grass
	)
	_add_mesh_surface(
		solid_mesh,
		dirt_material,
		buffer.dirt
	)
	_add_mesh_surface(
		solid_mesh,
		stone_material,
		buffer.stone
	)
	_add_mesh_surface(
		solid_mesh,
		sand_material,
		buffer.sand
	)
	_add_mesh_surface(
		water_mesh,
		water_material,
		buffer.water
	)

	$ChunkMesh.mesh = solid_mesh
	$WaterMesh.mesh = water_mesh

	# Packed arrays from the worker can be handed across directly;
	# avoid another full conversion/copy on the main thread.
	collision_faces = buffer.collision_faces
	mesh_building = false
	mesh_ready = true
	collision_ready = false


func _add_mesh_surface(
	mesh: ArrayMesh,
	material: Material,
	surface: ChunkMesher.MeshSurface
) -> void:
	if surface.vertices.is_empty():
		return

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = surface.vertices
	arrays[Mesh.ARRAY_NORMAL] = surface.normals
	arrays[Mesh.ARRAY_TEX_UV] = surface.uvs
	arrays[Mesh.ARRAY_INDEX] = surface.indices

	mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		arrays
	)
	mesh.surface_set_material(
		mesh.get_surface_count() - 1,
		material
	)


func clear_collision() -> void:
	$ChunkCollision/CollisionShape.shape = null
	collision_ready = false


func build_collision() -> void:
	if not mesh_ready:
		return

	if not is_inside_tree():
		return

	if collision_faces.is_empty():
		$ChunkCollision/CollisionShape.shape = null
		collision_ready = true
		return

	var collision_shape := ConcavePolygonShape3D.new()
	collision_shape.set_faces(collision_faces)
	$ChunkCollision/CollisionShape.shape = collision_shape
	collision_ready = true


func get_block_for_mesh(
	x: int,
	y: int,
	z: int
) -> int:

	# Inside this chunk.
	if (
		x >= 0
		and x < CHUNK_SIZE
		and y >= 0
		and y < CHUNK_HEIGHT
		and z >= 0
		and z < CHUNK_SIZE
	):
		return get_block(x, y, z)

	# Outside vertically = air.
	if y < 0 or y >= CHUNK_HEIGHT:
		return AIR

	var world = get_parent()

	if world == null:
		return AIR

	var neighbor_coordinate := chunk_coordinate

	var neighbor_x := x
	var neighbor_z := z

	if x < 0:
		neighbor_coordinate.x -= 1
		neighbor_x += CHUNK_SIZE

	elif x >= CHUNK_SIZE:
		neighbor_coordinate.x += 1
		neighbor_x -= CHUNK_SIZE

	if z < 0:
		neighbor_coordinate.y -= 1
		neighbor_z += CHUNK_SIZE

	elif z >= CHUNK_SIZE:
		neighbor_coordinate.y += 1
		neighbor_z -= CHUNK_SIZE

	if not world.loaded_chunks.has(
		neighbor_coordinate
	):
		return AIR

	var neighbor = world.loaded_chunks[
		neighbor_coordinate
	]

	# A chunk that has been loaded but hasn't generated yet
	# is treated as air for meshing.
	if not neighbor.is_generated:
		return AIR

	return neighbor.get_block(
		neighbor_x,
		y,
		neighbor_z
	)


func _add_block_faces(
	surface_tool: SurfaceTool,
	x: int,
	y: int,
	z: int
) -> void:

	var position := Vector3(x, y, z)

	# Top
	var neighbor := get_block_for_mesh(x, y + 1, z)

	if neighbor == AIR or _is_water(neighbor):
		_add_face(
			surface_tool,
			position,
			Vector3.UP
		)

	# Bottom
	neighbor = get_block_for_mesh(x, y - 1, z)

	if neighbor == AIR or _is_water(neighbor):
		_add_face(
			surface_tool,
			position,
			Vector3.DOWN
		)

	# Front
	neighbor = get_block_for_mesh(x, y, z - 1)

	if neighbor == AIR or _is_water(neighbor):
		_add_face(
			surface_tool,
			position,
			Vector3.FORWARD
		)

	# Back
	neighbor = get_block_for_mesh(x, y, z + 1)

	if neighbor == AIR or _is_water(neighbor):
		_add_face(
			surface_tool,
			position,
			Vector3.BACK
		)

	# Left
	neighbor = get_block_for_mesh(x - 1, y, z)

	if neighbor == AIR or _is_water(neighbor):
		_add_face(
			surface_tool,
			position,
			Vector3.LEFT
		)

	# Right
	neighbor = get_block_for_mesh(x + 1, y, z)

	if neighbor == AIR or _is_water(neighbor):
		_add_face(
			surface_tool,
			position,
			Vector3.RIGHT
		)


func _is_water(block_id: int) -> bool:
	return block_id >= WATER and block_id <= WATER_FALLING


func _water_height(block_id: int) -> float:
	if block_id == WATER or block_id == WATER_FALLING:
		return 15.0 / 16.0
	if block_id >= WATER_FLOW_1 and block_id <= WATER_FLOW_7:
		var level: int = block_id - WATER_FLOW_1 + 1
		return maxf(1.0 / 16.0, (8.0 - float(level)) / 8.0)
	return 0.0


func _add_water_block_faces(
	surface_tool: SurfaceTool,
	x: int,
	y: int,
	z: int
) -> void:

	var position := Vector3(x, y, z)
	var block_id := get_block(x, y, z)
	var water_height: float = _water_height(block_id)

	var above: int = get_block_for_mesh(x, y + 1, z)
	if above == AIR:
		_add_face(
			surface_tool,
			position,
			Vector3.UP,
			water_height
		)

	var below: int = get_block_for_mesh(x, y - 1, z)
	if below == AIR:
		_add_face(
			surface_tool,
			position,
			Vector3.DOWN
		)

	var neighbors := [
		[Vector3.FORWARD, get_block_for_mesh(x, y, z - 1)],
		[Vector3.BACK, get_block_for_mesh(x, y, z + 1)],
		[Vector3.LEFT, get_block_for_mesh(x - 1, y, z)],
		[Vector3.RIGHT, get_block_for_mesh(x + 1, y, z)]
	]

	for side in neighbors:
		var normal: Vector3 = side[0]
		var neighbor_id: int = side[1]

		if neighbor_id == AIR:
			_add_face(
				surface_tool,
				position,
				normal,
				water_height
			)


func _add_face(
	surface_tool: SurfaceTool,
	position: Vector3,
	normal: Vector3,
	height: float = 1.0
) -> void:

	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	# TOP
	if normal == Vector3.UP:
		v0 = position + Vector3(0, height, 0)
		v1 = position + Vector3(1, height, 0)
		v2 = position + Vector3(1, height, 1)
		v3 = position + Vector3(0, height, 1)

	# BOTTOM
	elif normal == Vector3.DOWN:
		v0 = position + Vector3(0, 0, 0)
		v1 = position + Vector3(0, 0, 1)
		v2 = position + Vector3(1, 0, 1)
		v3 = position + Vector3(1, 0, 0)

	# FRONT / -Z
	elif normal == Vector3.FORWARD:
		v0 = position + Vector3(0, 0, 0)
		v1 = position + Vector3(1, 0, 0)
		v2 = position + Vector3(1, height, 0)
		v3 = position + Vector3(0, height, 0)

	# BACK / +Z
	elif normal == Vector3.BACK:
		v0 = position + Vector3(0, 0, 1)
		v1 = position + Vector3(0, height, 1)
		v2 = position + Vector3(1, height, 1)
		v3 = position + Vector3(1, 0, 1)

	# LEFT / -X
	elif normal == Vector3.LEFT:
		v0 = position + Vector3(0, 0, 0)
		v1 = position + Vector3(0, height, 0)
		v2 = position + Vector3(0, height, 1)
		v3 = position + Vector3(0, 0, 1)

	# RIGHT / +X
	elif normal == Vector3.RIGHT:
		v0 = position + Vector3(1, 0, 0)
		v1 = position + Vector3(1, 0, 1)
		v2 = position + Vector3(1, height, 1)
		v3 = position + Vector3(1, height, 0)

	else:
		return

	_add_quad(
		surface_tool,
		v0,
		v1,
		v2,
		v3,
	)


func _add_quad(
	surface_tool: SurfaceTool,
	v0: Vector3,
	v1: Vector3,
	v2: Vector3,
	v3: Vector3,
) -> void:

	# First triangle
	surface_tool.set_smooth_group(-1)
	surface_tool.set_uv(Vector2(0.0, 0.0))
	surface_tool.add_vertex(v0)

	surface_tool.set_smooth_group(-1)
	surface_tool.set_uv(Vector2(1.0, 0.0))
	surface_tool.add_vertex(v1)

	surface_tool.set_smooth_group(-1)
	surface_tool.set_uv(Vector2(1.0, 1.0))
	surface_tool.add_vertex(v2)

	# Second triangle
	surface_tool.set_smooth_group(-1)
	surface_tool.set_uv(Vector2(0.0, 0.0))
	surface_tool.add_vertex(v0)

	surface_tool.set_smooth_group(-1)
	surface_tool.set_uv(Vector2(1.0, 1.0))
	surface_tool.add_vertex(v2)

	surface_tool.set_smooth_group(-1)
	surface_tool.set_uv(Vector2(0.0, 1.0))
	surface_tool.add_vertex(v3)


func get_highest_solid_block(
	x: int,
	z: int
) -> int:

	for y in range(
		CHUNK_HEIGHT - 1,
		-1,
		-1
	):
		var block_id: int = get_block(
			x,
			y,
			z
		)

		if block_id != AIR and not _is_water(block_id):
			return y

	return -1
