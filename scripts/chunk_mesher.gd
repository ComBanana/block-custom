extends RefCounted
class_name ChunkMesher

const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 64
const PADDED_SIZE: int = CHUNK_SIZE + 2

const AIR: int = 0
const GRASS: int = 1
const DIRT: int = 2
const STONE: int = 3
const SAND: int = 4
const WATER: int = 5
const WATER_FLOW_1: int = 6
const WATER_FLOW_7: int = 12
const WATER_FALLING: int = 13


class MeshBuffer:
	var grass_verts: Array[Vector3] = []
	var grass_normals: Array[Vector3] = []
	var grass_uvs: Array[Vector2] = []
	var dirt_verts: Array[Vector3] = []
	var dirt_normals: Array[Vector3] = []
	var dirt_uvs: Array[Vector2] = []
	var stone_verts: Array[Vector3] = []
	var stone_normals: Array[Vector3] = []
	var stone_uvs: Array[Vector2] = []
	var sand_verts: Array[Vector3] = []
	var sand_normals: Array[Vector3] = []
	var sand_uvs: Array[Vector2] = []
	var water_verts: Array[Vector3] = []
	var water_normals: Array[Vector3] = []
	var water_uvs: Array[Vector2] = []
	var collision_faces: Array[Vector3] = []

	func add_quad(layer: int, corners: Array[Vector3], normal: Vector3) -> void:
		var verts: Array[Vector3]
		var normals: Array[Vector3]
		var uvs: Array[Vector2]
		match layer:
			0:
				verts = grass_verts
				normals = grass_normals
				uvs = grass_uvs
			1:
				verts = dirt_verts
				normals = dirt_normals
				uvs = dirt_uvs
			2:
				verts = stone_verts
				normals = stone_normals
				uvs = stone_uvs
			3:
				verts = sand_verts
				normals = sand_normals
				uvs = sand_uvs
			_:
				verts = water_verts
				normals = water_normals
				uvs = water_uvs

		verts.append(corners[0])
		verts.append(corners[1])
		verts.append(corners[2])
		verts.append(corners[0])
		verts.append(corners[2])
		verts.append(corners[3])
		for _i in range(6):
			normals.append(normal)
		uvs.append(Vector2(0, 0))
		uvs.append(Vector2(1, 0))
		uvs.append(Vector2(1, 1))
		uvs.append(Vector2(0, 0))
		uvs.append(Vector2(1, 1))
		uvs.append(Vector2(0, 1))

	func add_collision_quad(corners: Array[Vector3]) -> void:
		collision_faces.append(corners[0])
		collision_faces.append(corners[1])
		collision_faces.append(corners[2])
		collision_faces.append(corners[0])
		collision_faces.append(corners[2])
		collision_faces.append(corners[3])


static func padded_index(x: int, y: int, z: int) -> int:
	return (x + 1) + (z + 1) * PADDED_SIZE + y * PADDED_SIZE * PADDED_SIZE


static func is_water(block_id: int) -> bool:
	return block_id >= WATER and block_id <= WATER_FALLING


static func water_height(block_id: int) -> float:
	if block_id == WATER or block_id == WATER_FALLING:
		return 15.0 / 16.0
	if block_id >= WATER_FLOW_1 and block_id <= WATER_FLOW_7:
		var level: int = block_id - WATER_FLOW_1 + 1
		return maxf(1.0 / 16.0, (8.0 - float(level)) / 8.0)
	return 0.0


static func capture_snapshot(chunk, world) -> PackedByteArray:
	var snapshot := PackedByteArray()
	snapshot.resize(PADDED_SIZE * CHUNK_HEIGHT * PADDED_SIZE)
	snapshot.fill(AIR)

	for y in range(CHUNK_HEIGHT):
		for z in range(-1, CHUNK_SIZE + 1):
			for x in range(-1, CHUNK_SIZE + 1):
				var block_id: int = AIR
				if x >= 0 and x < CHUNK_SIZE and z >= 0 and z < CHUNK_SIZE:
					block_id = chunk.get_block(x, y, z)
				elif world != null:
					block_id = chunk.get_block_for_mesh(x, y, z)
				snapshot[padded_index(x, y, z)] = block_id

	return snapshot


static func build(snapshot: PackedByteArray) -> MeshBuffer:
	var buffer := MeshBuffer.new()

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			for y in range(CHUNK_HEIGHT):
				var block_id: int = snapshot[padded_index(x, y, z)]
				if block_id == AIR:
					continue
				if is_water(block_id):
					_add_water_faces(snapshot, x, y, z, block_id, buffer)
				else:
					_add_solid_faces(snapshot, x, y, z, block_id, buffer)

	return buffer


static func _add_solid_faces(
	snapshot: PackedByteArray,
	x: int,
	y: int,
	z: int,
	block_id: int,
	buffer: MeshBuffer
) -> void:
	var origin := Vector3(x, y, z)
	var checks := [
		[Vector3i(0, 1, 0), Vector3.UP],
		[Vector3i(0, -1, 0), Vector3.DOWN],
		[Vector3i(0, 0, -1), Vector3.FORWARD],
		[Vector3i(0, 0, 1), Vector3.BACK],
		[Vector3i(-1, 0, 0), Vector3.LEFT],
		[Vector3i(1, 0, 0), Vector3.RIGHT]
	]
	for check in checks:
		var offset: Vector3i = check[0]
		var neighbor: int = snapshot[padded_index(x + offset.x, y + offset.y, z + offset.z)]
		if neighbor != AIR and not is_water(neighbor):
			continue
		_add_face(buffer, block_id, origin, check[1], 1.0, true)


static func _add_water_faces(
	snapshot: PackedByteArray,
	x: int,
	y: int,
	z: int,
	block_id: int,
	buffer: MeshBuffer
) -> void:
	var origin := Vector3(x, y, z)
	var height: float = water_height(block_id)

	var above: int = AIR
	if y + 1 < CHUNK_HEIGHT:
		above = snapshot[padded_index(x, y + 1, z)]
	if above == AIR:
		_add_face(buffer, WATER, origin, Vector3.UP, height, false)

	var below: int = AIR
	if y > 0:
		below = snapshot[padded_index(x, y - 1, z)]
	if below == AIR:
		_add_face(buffer, WATER, origin, Vector3.DOWN, 1.0, false)

	var sides := [
		[Vector3i(0, 0, -1), Vector3.FORWARD],
		[Vector3i(0, 0, 1), Vector3.BACK],
		[Vector3i(-1, 0, 0), Vector3.LEFT],
		[Vector3i(1, 0, 0), Vector3.RIGHT]
	]
	for side in sides:
		var offset: Vector3i = side[0]
		var neighbor: int = snapshot[padded_index(x + offset.x, y + offset.y, z + offset.z)]
		if neighbor == AIR:
			_add_face(buffer, WATER, origin, side[1], height, false)


static func _add_face(
	buffer: MeshBuffer,
	block_id: int,
	position: Vector3,
	normal: Vector3,
	height: float,
	include_collision: bool
) -> void:
	var corners: Array[Vector3] = _face_corners(position, normal, height)
	var layer: int = 4
	match block_id:
		GRASS:
			layer = 0
		DIRT:
			layer = 1
		STONE:
			layer = 2
		SAND:
			layer = 3
		_:
			layer = 4
	buffer.add_quad(layer, corners, normal)
	if include_collision:
		buffer.add_collision_quad(corners)


static func _face_corners(position: Vector3, normal: Vector3, height: float) -> Array[Vector3]:
	var corners: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	if normal == Vector3.UP:
		corners[0] = position + Vector3(0, height, 0)
		corners[1] = position + Vector3(1, height, 0)
		corners[2] = position + Vector3(1, height, 1)
		corners[3] = position + Vector3(0, height, 1)
	elif normal == Vector3.DOWN:
		corners[0] = position + Vector3(0, 0, 0)
		corners[1] = position + Vector3(0, 0, 1)
		corners[2] = position + Vector3(1, 0, 1)
		corners[3] = position + Vector3(1, 0, 0)
	elif normal == Vector3.FORWARD:
		corners[0] = position + Vector3(0, 0, 0)
		corners[1] = position + Vector3(1, 0, 0)
		corners[2] = position + Vector3(1, height, 0)
		corners[3] = position + Vector3(0, height, 0)
	elif normal == Vector3.BACK:
		corners[0] = position + Vector3(0, 0, 1)
		corners[1] = position + Vector3(0, height, 1)
		corners[2] = position + Vector3(1, height, 1)
		corners[3] = position + Vector3(1, 0, 1)
	elif normal == Vector3.LEFT:
		corners[0] = position + Vector3(0, 0, 0)
		corners[1] = position + Vector3(0, height, 0)
		corners[2] = position + Vector3(0, height, 1)
		corners[3] = position + Vector3(0, 0, 1)
	else:
		corners[0] = position + Vector3(1, 0, 0)
		corners[1] = position + Vector3(1, 0, 1)
		corners[2] = position + Vector3(1, height, 1)
		corners[3] = position + Vector3(1, height, 0)
	return corners
