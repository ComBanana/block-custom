extends RefCounted
class_name WorldRenderRegions

const CHUNK_SIZE: int = 16
const REGION_CHUNKS: int = 4
const REGION_WORLD_SIZE: int = REGION_CHUNKS * CHUNK_SIZE
const BATCH_DISTANCE: int = 6


class RegionBuildInput:
	var region_coordinate := Vector2i.ZERO
	var center_chunk := Vector2i.ZERO
	var region_revision: int = 0
	var chunk_blocks: Dictionary = {}
	var chunk_max_y: Dictionary = {}
	var chunk_revisions: Dictionary = {}


class RegionBuildResult:
	var region_coordinate := Vector2i.ZERO
	var center_chunk := Vector2i.ZERO
	var region_revision: int = 0
	var chunk_revisions: Dictionary = {}
	var solid_vertices := PackedVector3Array()
	var solid_normals := PackedVector3Array()
	var solid_uvs := PackedVector2Array()
	var solid_indices := PackedInt32Array()
	var water_vertices := PackedVector3Array()
	var water_normals := PackedVector3Array()
	var water_uvs := PackedVector2Array()
	var water_indices := PackedInt32Array()


class RegionState:
	var region_coordinate := Vector2i.ZERO
	var node: Node3D
	var solid_mesh: MeshInstance3D
	var water_mesh: MeshInstance3D
	var revision: int = 0
	var building: bool = false
	var applied_revision: int = -1
	var applied_chunk_revisions: Dictionary = {}


var region_root: Node3D
var solid_material: Material
var water_material: Material
var snapshot_provider: Callable
var visibility_callback: Callable

var center_chunk := Vector2i.ZERO
var present_chunks: Dictionary = {}
var regions: Dictionary = {}
var dirty_regions: Dictionary = {}
var region_tasks: Dictionary = {}


func _init(
	root: Node3D,
	solid_mat: Material,
	water_mat: Material,
	provider: Callable,
	on_visibility_changed: Callable
) -> void:
	region_root = root
	solid_material = solid_mat
	water_material = water_mat
	snapshot_provider = provider
	visibility_callback = on_visibility_changed


func is_chunk_batched(chunk_coordinate: Vector2i) -> bool:
	return _is_chunk_batched_for_center(
		chunk_coordinate,
		center_chunk
	)


func _is_chunk_batched_for_center(
	chunk_coordinate: Vector2i,
	reference_chunk: Vector2i
) -> bool:
	return (
		abs(chunk_coordinate.x - reference_chunk.x) > BATCH_DISTANCE
		or abs(chunk_coordinate.y - reference_chunk.y) > BATCH_DISTANCE
	)


func _region_coordinate_for_chunk(
	chunk_coordinate: Vector2i
) -> Vector2i:
	return Vector2i(
		floori(
			float(chunk_coordinate.x) / float(REGION_CHUNKS)
		),
		floori(
			float(chunk_coordinate.y) / float(REGION_CHUNKS)
		)
	)


func _region_origin_chunk(
	region_coordinate: Vector2i
) -> Vector2i:
	return region_coordinate * REGION_CHUNKS


func register_chunk(
	chunk_coordinate: Vector2i
) -> void:
	present_chunks[chunk_coordinate] = true

	if is_chunk_batched(chunk_coordinate):
		mark_chunk_dirty(chunk_coordinate)


func remove_chunk(
	chunk_coordinate: Vector2i
) -> void:
	present_chunks.erase(chunk_coordinate)
	_mark_region_dirty(
		_region_coordinate_for_chunk(chunk_coordinate)
	)


func update_center(
	new_center_chunk: Vector2i
) -> Array[Vector2i]:
	var old_center := center_chunk
	if old_center == new_center_chunk:
		return []

	center_chunk = new_center_chunk

	var changed_chunks: Array[Vector2i] = []
	var delta_x := abs(new_center_chunk.x - old_center.x)
	var delta_z := abs(new_center_chunk.y - old_center.y)
	var full_scan_threshold := BATCH_DISTANCE * 2 + 2

	if (
		delta_x > full_scan_threshold
		or delta_z > full_scan_threshold
	):
		# Large teleports can move the batching boundary a long way.
		# Only those rare moves need to inspect the full loaded set.
		for chunk_variant in present_chunks.keys():
			var chunk_coordinate: Vector2i = chunk_variant

			var was_batched := _is_chunk_batched_for_center(
				chunk_coordinate,
				old_center
			)
			var is_batched := _is_chunk_batched_for_center(
				chunk_coordinate,
				center_chunk
			)

			if was_batched == is_batched:
				continue

			changed_chunks.append(chunk_coordinate)

			_mark_region_dirty(
				_region_coordinate_for_chunk(chunk_coordinate)
			)

		return changed_chunks

	# The batching decision is based on a fixed Chebyshev-distance near
	# square. For a normal one- or two-chunk move, only the union of the old
	# and new near squares can change state. This keeps boundary work bounded
	# by roughly (2*BATCH_DISTANCE)^2 instead of all loaded chunks.
	var min_x := mini(
		old_center.x,
		new_center_chunk.x
	) - BATCH_DISTANCE
	var max_x := maxi(
		old_center.x,
		new_center_chunk.x
	) + BATCH_DISTANCE
	var min_z := mini(
		old_center.y,
		new_center_chunk.y
	) - BATCH_DISTANCE
	var max_z := maxi(
		old_center.y,
		new_center_chunk.y
	) + BATCH_DISTANCE

	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var chunk_coordinate := Vector2i(x, z)

			if not present_chunks.has(chunk_coordinate):
				continue

			var was_batched := _is_chunk_batched_for_center(
				chunk_coordinate,
				old_center
			)
			var is_batched := _is_chunk_batched_for_center(
				chunk_coordinate,
				center_chunk
			)

			if was_batched == is_batched:
				continue

			changed_chunks.append(chunk_coordinate)

			_mark_region_dirty(
				_region_coordinate_for_chunk(chunk_coordinate)
			)

	return changed_chunks


func mark_chunk_dirty(
	chunk_coordinate: Vector2i
) -> void:
	# A chunk's border geometry can affect an adjacent render region.
	# Only mark neighboring regions when this chunk lies on their boundary.
	var region_coordinate := _region_coordinate_for_chunk(
		chunk_coordinate
	)

	_mark_region_dirty(region_coordinate)

	var local_x := posmod(
		chunk_coordinate.x,
		REGION_CHUNKS
	)
	var local_z := posmod(
		chunk_coordinate.y,
		REGION_CHUNKS
	)

	if local_x == 0:
		_mark_region_dirty(
			region_coordinate + Vector2i(-1, 0)
		)
	elif local_x == REGION_CHUNKS - 1:
		_mark_region_dirty(
			region_coordinate + Vector2i(1, 0)
		)

	if local_z == 0:
		_mark_region_dirty(
			region_coordinate + Vector2i(0, -1)
		)
	elif local_z == REGION_CHUNKS - 1:
		_mark_region_dirty(
			region_coordinate + Vector2i(0, 1)
		)


func _region_has_batched_chunks(
	region_coordinate: Vector2i
) -> bool:
	var origin := _region_origin_chunk(region_coordinate)

	for x in range(REGION_CHUNKS):
		for z in range(REGION_CHUNKS):
			var chunk_coordinate := origin + Vector2i(
				x,
				z
			)

			if not present_chunks.has(chunk_coordinate):
				continue

			if is_chunk_batched(chunk_coordinate):
				return true

	return false


func _mark_region_dirty(
	region_coordinate: Vector2i
) -> void:
	var state: RegionState = regions.get(
		region_coordinate,
		null
	)

	if state == null:
		state = _get_or_create_region(
			region_coordinate
		)

	state.revision += 1
	dirty_regions[region_coordinate] = true


func _get_or_create_region(
	region_coordinate: Vector2i
) -> RegionState:
	var existing: RegionState = regions.get(
		region_coordinate,
		null
	)

	if existing != null:
		return existing

	var state := RegionState.new()
	state.region_coordinate = region_coordinate

	var node := Node3D.new()
	node.name = (
		"RenderRegion_%d_%d"
		% [
			region_coordinate.x,
			region_coordinate.y
		]
	)
	node.position = Vector3(
		region_coordinate.x * REGION_WORLD_SIZE,
		0.0,
		region_coordinate.y * REGION_WORLD_SIZE
	)
	region_root.add_child(node)

	var solid_instance := MeshInstance3D.new()
	solid_instance.name = "Solid"
	solid_instance.material_override = solid_material
	node.add_child(solid_instance)

	var water_instance := MeshInstance3D.new()
	water_instance.name = "Water"
	water_instance.material_override = water_material
	water_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(water_instance)

	state.node = node
	state.solid_mesh = solid_instance
	state.water_mesh = water_instance

	regions[region_coordinate] = state
	return state


func _capture_region_input(
	region_coordinate: Vector2i
) -> RegionBuildInput:
	var state: RegionState = regions.get(
		region_coordinate,
		null
	)

	if state == null:
		return null

	if not _region_has_batched_chunks(region_coordinate):
		return null

	var input := RegionBuildInput.new()
	input.region_coordinate = region_coordinate
	input.center_chunk = center_chunk
	input.region_revision = state.revision

	var origin := _region_origin_chunk(
		region_coordinate
	)

	# Capture a one-chunk border around the 4x4 region so block-face
	# visibility is correct at region edges.
	for x_offset in range(-1, REGION_CHUNKS + 1):
		for z_offset in range(-1, REGION_CHUNKS + 1):
			var chunk_coordinate := origin + Vector2i(
				x_offset,
				z_offset
			)

			var snapshot_variant = snapshot_provider.call(
				chunk_coordinate
			)

			if not snapshot_variant is Dictionary:
				continue

			var snapshot: Dictionary = snapshot_variant

			if not snapshot.has("blocks"):
				continue

			var blocks: PackedByteArray = snapshot["blocks"]

			if blocks.is_empty():
				continue

			input.chunk_blocks[chunk_coordinate] = blocks
			input.chunk_max_y[chunk_coordinate] = int(
				snapshot.get("max_y_exclusive", 1)
			)

			if (
				x_offset >= 0
				and x_offset < REGION_CHUNKS
				and z_offset >= 0
				and z_offset < REGION_CHUNKS
				and _is_chunk_batched_for_center(
					chunk_coordinate,
					center_chunk
				)
			):
				input.chunk_revisions[chunk_coordinate] = int(
					snapshot.get("revision", 0)
				)

	return input


func process(
	max_submit_tasks: int = 1,
	max_apply_results: int = 1,
	apply_budget_ms: float = 1.0
) -> void:
	var completed_tasks: Array[int] = []

	for task_id in region_tasks:
		if WorkerThreadPool.is_task_completed(task_id):
			completed_tasks.append(task_id)

	var apply_start_usec := Time.get_ticks_usec()
	var applied_count: int = 0

	for task_id in completed_tasks:
		if applied_count >= max_apply_results:
			break

		if (
			applied_count > 0
			and apply_budget_ms > 0.0
			and float(
				Time.get_ticks_usec() - apply_start_usec
			) / 1000.0 >= apply_budget_ms
		):
			break

		var result: RegionBuildResult = region_tasks[task_id]
		var wait_error := WorkerThreadPool.wait_for_task_completion(
			task_id
		)
		region_tasks.erase(task_id)

		if wait_error != OK:
			continue

		if not regions.has(result.region_coordinate):
			continue

		var state: RegionState = regions[
			result.region_coordinate
		]
		state.building = false

		# A chunk or border changed while the worker was running.
		if state.revision != result.region_revision:
			dirty_regions[result.region_coordinate] = true
			continue

		# The player may have crossed the near/batched boundary while the
		# region was building. In that case, this result is stale even if
		# no block data changed.
		if center_chunk != result.center_chunk:
			dirty_regions[result.region_coordinate] = true
			continue

		_apply_region_result(
			state,
			result
		)
		applied_count += 1

	_submit_regions(
		max_submit_tasks
	)


func _submit_regions(
	max_submit_tasks: int
) -> void:
	if max_submit_tasks <= 0:
		return

	while region_tasks.size() < max_submit_tasks:
		var region_coordinate := _take_next_dirty_region()

		if region_coordinate == Vector2i(
			999999,
			999999
		):
			return

		var state: RegionState = regions.get(
			region_coordinate,
			null
		)

		if state == null:
			continue

		if state.building:
			continue

		var input := _capture_region_input(
			region_coordinate
		)

		if input == null:
			dirty_regions.erase(region_coordinate)
			state.building = false
			_clear_region_render_if_empty(state)
			continue

		dirty_regions.erase(region_coordinate)
		state.building = true

		var result := RegionBuildResult.new()
		result.region_coordinate = region_coordinate
		result.center_chunk = center_chunk
		result.region_revision = input.region_revision
		result.chunk_revisions = input.chunk_revisions.duplicate()

		var task_id := WorkerThreadPool.add_task(
			Callable(
				self,
				"_build_region_worker"
			).bind(
				input,
				result
			),
			false,
			"Render region (%d, %d)" % [
				region_coordinate.x,
				region_coordinate.y
			]
		)

		region_tasks[task_id] = result


func _take_next_dirty_region() -> Vector2i:
	var best_region := Vector2i(
		999999,
		999999
	)
	var best_score: float = -INF

	for region_variant in dirty_regions.keys():
		var region_coordinate: Vector2i = region_variant

		var origin := _region_origin_chunk(
			region_coordinate
		)
		var center := Vector2(
			float(origin.x + REGION_CHUNKS / 2),
			float(origin.y + REGION_CHUNKS / 2)
		)
		var player := Vector2(
			float(center_chunk.x),
			float(center_chunk.y)
		)
		var distance_squared := (
			center - player
		).length_squared()

		# Far regions are intentionally low priority. Near chunks are
		# rendered individually, so these builds should never compete with
		# player-visible edits.
		var score := -distance_squared

		if score > best_score:
			best_score = score
			best_region = region_coordinate

	return best_region


func _build_region_worker(
	input: RegionBuildInput,
	result: RegionBuildResult
) -> void:
	var origin := _region_origin_chunk(
		input.region_coordinate
	)

	for x_offset in range(REGION_CHUNKS):
		for z_offset in range(REGION_CHUNKS):
			var chunk_coordinate := origin + Vector2i(
				x_offset,
				z_offset
			)

			if not input.chunk_revisions.has(
				chunk_coordinate
			):
				continue

			if not input.chunk_blocks.has(
				chunk_coordinate
			):
				continue

			var center_blocks: PackedByteArray = (
				input.chunk_blocks[chunk_coordinate]
			)

			var neg_x_blocks: PackedByteArray = (
				input.chunk_blocks.get(
					chunk_coordinate + Vector2i(-1, 0),
					PackedByteArray()
				)
			)
			var pos_x_blocks: PackedByteArray = (
				input.chunk_blocks.get(
					chunk_coordinate + Vector2i(1, 0),
					PackedByteArray()
				)
			)
			var neg_z_blocks: PackedByteArray = (
				input.chunk_blocks.get(
					chunk_coordinate + Vector2i(0, -1),
					PackedByteArray()
				)
			)
			var pos_z_blocks: PackedByteArray = (
				input.chunk_blocks.get(
					chunk_coordinate + Vector2i(0, 1),
					PackedByteArray()
				)
			)

			var max_y_exclusive: int = int(
				input.chunk_max_y.get(
					chunk_coordinate,
					1
				)
			)

			var buffer := ChunkMesher.build_from_blocks(
				center_blocks,
				neg_x_blocks,
				pos_x_blocks,
				neg_z_blocks,
				pos_z_blocks,
				chunk_coordinate,
				max_y_exclusive,
				false
			)

			var chunk_offset := Vector3(
				float(x_offset * CHUNK_SIZE),
				0.0,
				float(z_offset * CHUNK_SIZE)
			)

			_append_surface(
				result.solid_vertices,
				result.solid_normals,
				result.solid_uvs,
				result.solid_indices,
				buffer.solid,
				chunk_offset
			)

			_append_surface(
				result.water_vertices,
				result.water_normals,
				result.water_uvs,
				result.water_indices,
				buffer.water,
				chunk_offset
			)


func _append_surface(
	destination_vertices: PackedVector3Array,
	destination_normals: PackedVector3Array,
	destination_uvs: PackedVector2Array,
	destination_indices: PackedInt32Array,
	source: ChunkMesher.MeshSurface,
	offset: Vector3
) -> void:
	var base_index: int = destination_vertices.size()

	for vertex in source.vertices:
		destination_vertices.append(
			vertex + offset
		)

	destination_normals.append_array(
		source.normals
	)
	destination_uvs.append_array(
		source.uvs
	)

	for index in source.indices:
		destination_indices.append(
			base_index + index
		)


func _apply_region_result(
	state: RegionState,
	result: RegionBuildResult
) -> void:
	var old_chunk_revisions := (
		state.applied_chunk_revisions
	)

	var solid_mesh := _create_mesh(
		result.solid_vertices,
		result.solid_normals,
		result.solid_uvs,
		result.solid_indices,
		solid_material
	)
	var water_mesh := _create_mesh(
		result.water_vertices,
		result.water_normals,
		result.water_uvs,
		result.water_indices,
		water_material
	)

	state.solid_mesh.mesh = solid_mesh
	state.water_mesh.mesh = water_mesh

	state.applied_revision = result.region_revision
	state.applied_chunk_revisions = result.chunk_revisions.duplicate()

	for chunk_variant in old_chunk_revisions.keys():
		var chunk_coordinate: Vector2i = chunk_variant
		if not result.chunk_revisions.has(chunk_coordinate):
			visibility_callback.call(
				chunk_coordinate,
				false
			)

	for chunk_variant in result.chunk_revisions.keys():
		var chunk_coordinate: Vector2i = chunk_variant
		visibility_callback.call(
			chunk_coordinate,
			true
		)

	# The region itself may now be empty after a partition change.
	if result.chunk_revisions.is_empty():
		_clear_region_render_if_empty(state)


func _create_mesh(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	material: Material
) -> ArrayMesh:
	var mesh := ArrayMesh.new()

	if vertices.is_empty():
		return mesh

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	mesh.add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES,
		arrays
	)
	mesh.surface_set_material(
		0,
		material
	)

	return mesh


func _clear_region_render_if_empty(
	state: RegionState
) -> void:
	if state.applied_chunk_revisions.size() > 0:
		return

	state.solid_mesh.mesh = null
	state.water_mesh.mesh = null
	state.applied_revision = state.revision

	if not _region_has_batched_chunks(state.region_coordinate):
		# Keep the small RegionState object around so future edits can reuse it,
		# but drop the scene node which would otherwise add a permanent culling
		# entry.
		if is_instance_valid(state.node):
			state.node.queue_free()
		regions.erase(state.region_coordinate)
		dirty_regions.erase(state.region_coordinate)


func shutdown() -> void:
	for task_id in region_tasks:
		WorkerThreadPool.wait_for_task_completion(
			task_id
		)
	region_tasks.clear()

	for state_variant in regions.values():
		var state: RegionState = state_variant
		if is_instance_valid(state.node):
			state.node.queue_free()

	regions.clear()
	dirty_regions.clear()
	present_chunks.clear()
