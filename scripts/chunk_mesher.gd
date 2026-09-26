extends RefCounted
class_name ChunkMesher

const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 256
const PADDED_SIZE: int = CHUNK_SIZE + 2
const PADDED_HEIGHT: int = CHUNK_HEIGHT + 2
const CHUNK_VOLUME: int = CHUNK_SIZE * CHUNK_HEIGHT * CHUNK_SIZE
const PADDED_VOLUME: int = PADDED_SIZE * PADDED_HEIGHT * PADDED_SIZE

const AIR: int = 0
const GRASS: int = 1
const DIRT: int = 2
const STONE: int = 3
const SAND: int = 4
const WATER: int = 5
const WATER_FLOW_1: int = 6
const WATER_FLOW_7: int = 12
const WATER_FALLING: int = 13

const FACE_UP: int = 0
const FACE_DOWN: int = 1
const FACE_FORWARD: int = 2
const FACE_BACK: int = 3
const FACE_LEFT: int = 4
const FACE_RIGHT: int = 5


class MeshSurface:
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()

	static func _rotate_uv(
		uv: Vector2,
		rotation_steps: int
	) -> Vector2:
		match posmod(rotation_steps, 4):
			1:
				return Vector2(
					1.0 - uv.y,
					uv.x
				)
			2:
				return Vector2(
					1.0 - uv.x,
					1.0 - uv.y
				)
			3:
				return Vector2(
					uv.y,
					1.0 - uv.x
				)
			_:
				return uv

	func add_quad(
		v0: Vector3,
		v1: Vector3,
		v2: Vector3,
		v3: Vector3,
		normal: Vector3,
		uv_rotation_steps: int = 0,
		material_layer: int = -1
	) -> void:
		var base_index: int = vertices.size()

		vertices.append(v0)
		vertices.append(v1)
		vertices.append(v2)
		vertices.append(v3)

		normals.append(normal)
		normals.append(normal)
		normals.append(normal)
		normals.append(normal)

		match normal:
			Vector3.FORWARD, Vector3.RIGHT:
				uvs.append(Vector2(0.0, 1.0))
				uvs.append(Vector2(1.0, 1.0))
				uvs.append(Vector2(1.0, 0.0))
				uvs.append(Vector2(0.0, 0.0))

			Vector3.BACK, Vector3.LEFT:
				uvs.append(Vector2(0.0, 1.0))
				uvs.append(Vector2(0.0, 0.0))
				uvs.append(Vector2(1.0, 0.0))
				uvs.append(Vector2(1.0, 1.0))

			_:
				uvs.append(Vector2(0.0, 0.0))
				uvs.append(Vector2(1.0, 0.0))
				uvs.append(Vector2(1.0, 1.0))
				uvs.append(Vector2(0.0, 1.0))

		if uv_rotation_steps != 0:
			for i in range(4):
				uvs[base_index + i] = _rotate_uv(
					uvs[base_index + i],
					uv_rotation_steps
				)

		# Pack the opaque material layer into the unused range above U=1.
		# This keeps the vertex format compact: no extra color/attribute
		# buffer is required just to select a block texture in the shader.
		if material_layer >= 0 and material_layer <= 4:
			var material_offset := float(material_layer) * 2.0
			for i in range(4):
				uvs[base_index + i].x += material_offset

		indices.append(base_index)
		indices.append(base_index + 1)
		indices.append(base_index + 2)
		indices.append(base_index)
		indices.append(base_index + 2)
		indices.append(base_index + 3)



class MeshBuffer:
	# All opaque blocks share one geometry surface. The shader selects the
	# texture from the material layer packed into UV.x.
	var solid: MeshSurface = MeshSurface.new()
	var water: MeshSurface = MeshSurface.new()
	var collision_faces: PackedVector3Array = PackedVector3Array()

	func surface_for_layer(layer: int) -> MeshSurface:
		if layer == 5:
			return water
		return solid

	func add_quad(
		layer: int,
		v0: Vector3,
		v1: Vector3,
		v2: Vector3,
		v3: Vector3,
		normal: Vector3,
		uv_rotation_steps: int = 0
	) -> void:
		surface_for_layer(layer).add_quad(
			v0,
			v1,
			v2,
			v3,
			normal,
			uv_rotation_steps,
			layer
		)

	func add_collision_quad(
		v0: Vector3,
		v1: Vector3,
		v2: Vector3,
		v3: Vector3
	) -> void:
		collision_faces.append(v0)
		collision_faces.append(v1)
		collision_faces.append(v2)
		collision_faces.append(v0)
		collision_faces.append(v2)
		collision_faces.append(v3)


static func chunk_index(x: int, y: int, z: int) -> int:
	return x + z * CHUNK_SIZE + y * CHUNK_SIZE * CHUNK_SIZE


static func padded_index(x: int, y: int, z: int) -> int:
	return (
		(x + 1)
		+ (z + 1) * PADDED_SIZE
		+ (y + 1) * PADDED_SIZE * PADDED_SIZE
	)


static func is_water(block_id: int) -> bool:
	return block_id >= WATER and block_id <= WATER_FALLING


static func water_height(block_id: int) -> float:
	if block_id == WATER or block_id == WATER_FALLING:
		return 15.0 / 16.0

	if block_id >= WATER_FLOW_1 and block_id <= WATER_FLOW_7:
		var level: int = block_id - WATER_FLOW_1 + 1
		return maxf(
			1.0 / 16.0,
			(8.0 - float(level)) / 8.0
		)

	return 0.0


static func build_from_blocks(
	center_blocks: PackedByteArray,
	neg_x_blocks: PackedByteArray,
	pos_x_blocks: PackedByteArray,
	neg_z_blocks: PackedByteArray,
	pos_z_blocks: PackedByteArray,
	chunk_coordinate: Vector2i = Vector2i.ZERO,
	max_y_exclusive: int = CHUNK_HEIGHT,
	include_collision: bool = true
) -> MeshBuffer:
	max_y_exclusive = clampi(
		max_y_exclusive,
		1,
		CHUNK_HEIGHT
	)
	var snapshot := PackedByteArray()
	snapshot.resize(PADDED_VOLUME)
	snapshot.fill(AIR)

	_copy_center_blocks(
		snapshot,
		center_blocks,
		max_y_exclusive
	)

	_copy_x_border(
		snapshot,
		neg_x_blocks,
		-1,
		CHUNK_SIZE - 1,
		max_y_exclusive
	)

	_copy_x_border(
		snapshot,
		pos_x_blocks,
		CHUNK_SIZE,
		0,
		max_y_exclusive
	)

	_copy_z_border(
		snapshot,
		neg_z_blocks,
		-1,
		CHUNK_SIZE - 1,
		max_y_exclusive
	)

	_copy_z_border(
		snapshot,
		pos_z_blocks,
		CHUNK_SIZE,
		0,
		max_y_exclusive
	)

	return build(
		snapshot,
		chunk_coordinate,
		max_y_exclusive,
		include_collision
	)


static func _copy_center_blocks(
	snapshot: PackedByteArray,
	center_blocks: PackedByteArray,
	max_y_exclusive: int
) -> void:
	if center_blocks.size() != CHUNK_VOLUME:
		return

	for y in range(max_y_exclusive):
		var source_y_base: int = (
			y * CHUNK_SIZE * CHUNK_SIZE
		)
		var target_y_base: int = (
			(y + 1) * PADDED_SIZE * PADDED_SIZE
		)

		for z in range(CHUNK_SIZE):
			var source_base: int = (
				source_y_base + z * CHUNK_SIZE
			)
			var target_base: int = (
				target_y_base + (z + 1) * PADDED_SIZE + 1
			)

			for x in range(CHUNK_SIZE):
				snapshot[target_base + x] = (
					center_blocks[source_base + x]
				)


static func _copy_x_border(
	snapshot: PackedByteArray,
	neighbor_blocks: PackedByteArray,
	target_x: int,
	source_x: int,
	max_y_exclusive: int
) -> void:
	if neighbor_blocks.size() != CHUNK_VOLUME:
		return

	for y in range(max_y_exclusive):
		var source_y_base: int = (
			y * CHUNK_SIZE * CHUNK_SIZE
		)

		for z in range(CHUNK_SIZE):
			var source_index: int = (
				source_y_base
				+ z * CHUNK_SIZE
				+ source_x
			)

			snapshot[
				padded_index(
					target_x,
					y,
					z
				)
			] = neighbor_blocks[source_index]


static func _copy_z_border(
	snapshot: PackedByteArray,
	neighbor_blocks: PackedByteArray,
	target_z: int,
	source_z: int,
	max_y_exclusive: int
) -> void:
	if neighbor_blocks.size() != CHUNK_VOLUME:
		return

	for y in range(max_y_exclusive):
		var source_y_base: int = (
			y * CHUNK_SIZE * CHUNK_SIZE
		)

		for x in range(CHUNK_SIZE):
			var source_index: int = (
				source_y_base
				+ source_z * CHUNK_SIZE
				+ x
			)

			snapshot[
				padded_index(
					x,
					y,
					target_z
				)
			] = neighbor_blocks[source_index]


static func build(
	snapshot: PackedByteArray,
	chunk_coordinate: Vector2i = Vector2i.ZERO,
	max_y_exclusive: int = CHUNK_HEIGHT,
	include_collision: bool = true
) -> MeshBuffer:
	var buffer := MeshBuffer.new()

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			for y in range(max_y_exclusive):
				var block_id: int = (
					snapshot[
						padded_index(
							x,
							y,
							z
						)
					]
				)

				if block_id == AIR:
					continue

				if is_water(block_id):
					_add_water_faces(
						snapshot,
						x,
						y,
						z,
						block_id,
						buffer
					)
				else:
					_add_solid_faces(
						snapshot,
						x,
						y,
						z,
						block_id,
						buffer,
						chunk_coordinate,
						include_collision
					)

	return buffer


static func _layer_for_solid_face(
	block_id: int,
	face: int
) -> int:
	if block_id == GRASS:
		if face == FACE_UP:
			return 0
		if face == FACE_DOWN:
			return 2
		return 1

	match block_id:
		DIRT:
			return 2
		STONE:
			return 3
		SAND:
			return 4
		_:
			return 2


static func _is_uniform_texture_block(block_id: int) -> bool:
	var layer: int = _layer_for_solid_face(
		block_id,
		FACE_UP
	)

	return (
		layer == _layer_for_solid_face(block_id, FACE_DOWN)
		and layer == _layer_for_solid_face(block_id, FACE_FORWARD)
		and layer == _layer_for_solid_face(block_id, FACE_BACK)
		and layer == _layer_for_solid_face(block_id, FACE_LEFT)
		and layer == _layer_for_solid_face(block_id, FACE_RIGHT)
	)


static func _texture_rotation_steps(
	chunk_coordinate: Vector2i,
	x: int,
	y: int,
	z: int
) -> int:
	# Hash world-space coordinates so the same block keeps the same
	# rotation when its chunk is rebuilt or remeshed.
	var world_x: int = (
		chunk_coordinate.x * CHUNK_SIZE +
		x
	)
	var world_z: int = (
		chunk_coordinate.y * CHUNK_SIZE +
		z
	)

	var value: int = (
		world_x * 73428767
		+ world_z * 912931
		+ y * 19349663
	)

	value = value ^ (value >> 13)
	value = value * 1274126177
	value = value ^ (value >> 16)

	return posmod(value, 4)


static func _add_solid_faces(
	snapshot: PackedByteArray,
	x: int,
	y: int,
	z: int,
	block_id: int,
	buffer: MeshBuffer,
	chunk_coordinate: Vector2i,
	include_collision: bool = true
) -> void:
	var origin := Vector3(x, y, z)
	var random_rotation: int = _texture_rotation_steps(
		chunk_coordinate,
		x,
		y,
		z
	)

	# Uniform-texture blocks keep the existing randomized rotation on all
	# faces. Grass is different: its side texture stays aligned while only
	# the top and bottom textures receive a randomized rotation.
	var top_rotation: int = 0
	var bottom_rotation: int = 0
	var side_rotation: int = 0

	if block_id == GRASS:
		top_rotation = posmod(random_rotation + 1, 4)
		bottom_rotation = random_rotation
	elif _is_uniform_texture_block(block_id):
		top_rotation = random_rotation
		bottom_rotation = random_rotation
		side_rotation = random_rotation

	var neighbor: int = snapshot[
		padded_index(x, y + 1, z)
	]
	if neighbor == AIR or is_water(neighbor):
		_add_face(
			buffer,
			_layer_for_solid_face(block_id, FACE_UP),
			origin,
			FACE_UP,
			Vector3.UP,
			1.0,
			include_collision,
			top_rotation
		)

	neighbor = snapshot[
		padded_index(x, y - 1, z)
	]
	if neighbor == AIR or is_water(neighbor):
		_add_face(
			buffer,
			_layer_for_solid_face(block_id, FACE_DOWN),
			origin,
			FACE_DOWN,
			Vector3.DOWN,
			1.0,
			include_collision,
			bottom_rotation
		)

	neighbor = snapshot[
		padded_index(x, y, z - 1)
	]
	if neighbor == AIR or is_water(neighbor):
		_add_face(
			buffer,
			_layer_for_solid_face(block_id, FACE_FORWARD),
			origin,
			FACE_FORWARD,
			Vector3.FORWARD,
			1.0,
			include_collision,
			side_rotation
		)

	neighbor = snapshot[
		padded_index(x, y, z + 1)
	]
	if neighbor == AIR or is_water(neighbor):
		_add_face(
			buffer,
			_layer_for_solid_face(block_id, FACE_BACK),
			origin,
			FACE_BACK,
			Vector3.BACK,
			1.0,
			include_collision,
			side_rotation
		)

	neighbor = snapshot[
		padded_index(x - 1, y, z)
	]
	if neighbor == AIR or is_water(neighbor):
		_add_face(
			buffer,
			_layer_for_solid_face(block_id, FACE_LEFT),
			origin,
			FACE_LEFT,
			Vector3.LEFT,
			1.0,
			include_collision,
			side_rotation
		)

	neighbor = snapshot[
		padded_index(x + 1, y, z)
	]
	if neighbor == AIR or is_water(neighbor):
		_add_face(
			buffer,
			_layer_for_solid_face(block_id, FACE_RIGHT),
			origin,
			FACE_RIGHT,
			Vector3.RIGHT,
			1.0,
			include_collision,
			side_rotation
		)


static func _water_side_height(block_id: int) -> float:
	if block_id == WATER or block_id == WATER_FALLING:
		return 1.0

	return water_height(block_id)


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

	# Water's visible surface sits one pixel below a full block.
	# Keep that reduction for top faces, but full source/falling water
	# uses the full block height for its exposed sides.
	var side_height: float = _water_side_height(block_id)

	var above: int = snapshot[
		padded_index(x, y + 1, z)
	]

	if above == AIR:
		_add_face(
			buffer,
			5,
			origin,
			FACE_UP,
			Vector3.UP,
			height,
			false
		)

	var below: int = snapshot[
		padded_index(x, y - 1, z)
	]

	if below == AIR:
		_add_face(
			buffer,
			5,
			origin,
			FACE_DOWN,
			Vector3.DOWN,
			1.0,
			false
		)

	var neighbor: int = snapshot[
		padded_index(x, y, z - 1)
	]
	var neighbor_height: float = 0.0

	if neighbor == AIR:
		_add_face(
			buffer,
			5,
			origin,
			FACE_FORWARD,
			Vector3.FORWARD,
			side_height,
			false,
			0,
			0.0
		)
	elif is_water(neighbor):
		neighbor_height = _water_side_height(neighbor)
		if neighbor_height + 0.0001 < side_height:
			_add_face(
				buffer,
				5,
				origin,
				FACE_FORWARD,
				Vector3.FORWARD,
				side_height,
				false,
				0,
				neighbor_height
			)

	neighbor = snapshot[
		padded_index(x, y, z + 1)
	]

	if neighbor == AIR:
		_add_face(
			buffer,
			5,
			origin,
			FACE_BACK,
			Vector3.BACK,
			side_height,
			false,
			0,
			0.0
		)
	elif is_water(neighbor):
		neighbor_height = _water_side_height(neighbor)
		if neighbor_height + 0.0001 < side_height:
			_add_face(
				buffer,
				5,
				origin,
				FACE_BACK,
				Vector3.BACK,
				side_height,
				false,
				0,
				neighbor_height
			)

	neighbor = snapshot[
		padded_index(x - 1, y, z)
	]

	if neighbor == AIR:
		_add_face(
			buffer,
			5,
			origin,
			FACE_LEFT,
			Vector3.LEFT,
			side_height,
			false,
			0,
			0.0
		)
	elif is_water(neighbor):
		neighbor_height = _water_side_height(neighbor)
		if neighbor_height + 0.0001 < side_height:
			_add_face(
				buffer,
				5,
				origin,
				FACE_LEFT,
				Vector3.LEFT,
				side_height,
				false,
				0,
				neighbor_height
			)

	neighbor = snapshot[
		padded_index(x + 1, y, z)
	]

	if neighbor == AIR:
		_add_face(
			buffer,
			5,
			origin,
			FACE_RIGHT,
			Vector3.RIGHT,
			side_height,
			false,
			0,
			0.0
		)
	elif is_water(neighbor):
		neighbor_height = _water_side_height(neighbor)
		if neighbor_height + 0.0001 < side_height:
			_add_face(
				buffer,
				5,
				origin,
				FACE_RIGHT,
				Vector3.RIGHT,
				side_height,
				false,
				0,
				neighbor_height
			)


static func _add_face(
	buffer: MeshBuffer,
	layer: int,
	position: Vector3,
	face: int,
	normal: Vector3,
	height: float,
	include_collision: bool,
	uv_rotation_steps: int = 0,
	bottom_height: float = 0.0
) -> void:
	var v0: Vector3
	var v1: Vector3
	var v2: Vector3
	var v3: Vector3

	match face:
		FACE_UP:
			v0 = position + Vector3(0, height, 0)
			v1 = position + Vector3(1, height, 0)
			v2 = position + Vector3(1, height, 1)
			v3 = position + Vector3(0, height, 1)

		FACE_DOWN:
			v0 = position + Vector3(0, 0, 0)
			v1 = position + Vector3(0, 0, 1)
			v2 = position + Vector3(1, 0, 1)
			v3 = position + Vector3(1, 0, 0)

		FACE_FORWARD:
			v0 = position + Vector3(0, bottom_height, 0)
			v1 = position + Vector3(1, bottom_height, 0)
			v2 = position + Vector3(1, height, 0)
			v3 = position + Vector3(0, height, 0)

		FACE_BACK:
			v0 = position + Vector3(0, bottom_height, 1)
			v1 = position + Vector3(0, height, 1)
			v2 = position + Vector3(1, height, 1)
			v3 = position + Vector3(1, bottom_height, 1)

		FACE_LEFT:
			v0 = position + Vector3(0, bottom_height, 0)
			v1 = position + Vector3(0, height, 0)
			v2 = position + Vector3(0, height, 1)
			v3 = position + Vector3(0, bottom_height, 1)

		_:
			v0 = position + Vector3(1, bottom_height, 0)
			v1 = position + Vector3(1, bottom_height, 1)
			v2 = position + Vector3(1, height, 1)
			v3 = position + Vector3(1, height, 0)

	buffer.add_quad(
		layer,
		v0,
		v1,
		v2,
		v3,
		normal,
		uv_rotation_steps
	)

	if include_collision:
		buffer.add_collision_quad(
			v0,
			v1,
			v2,
			v3
		)
