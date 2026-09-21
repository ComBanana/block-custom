extends CharacterBody3D

# =========================
# Movement
# =========================

@export_category("Movement")
@export var walk_speed: float = 4.3
@export var sprint_speed: float = 5.6
@export var jump_velocity: float = 8.0
@export var gravity: float = 28.0
@export var crouch_speed: float = 1.3

@export_category("Movement Feel")
@export var ground_acceleration: float = 35.0
@export var ground_friction: float = 32.0
@export var air_acceleration: float = 7.0

@export_category("Water")

# These are the Java Edition water-travel constants, expressed
# in Minecraft's 20-tick-per-second model.
@export var water_acceleration_per_tick: float = 0.02
@export var water_gravity_per_tick: float = 0.08
@export var water_jump_impulse_per_tick: float = 0.04
@export var water_sneak_impulse_per_tick: float = 0.04

@export var water_normal_drag: float = 0.8
@export var water_swim_drag: float = 0.9
@export var water_vertical_drag: float = 0.8

# Java Edition only lets a player use a normal ground jump
# when the fluid depth is at or below this threshold.
@export var water_fluid_jump_threshold: float = 0.4

# Java Edition's fluid collision escape sets Y velocity to
# 0.3 blocks/tick when a horizontal collision has enough room above.
@export var water_edge_jump_velocity_per_tick: float = 0.45

const AIR: int = 0
const WATER: int = 5
const WATER_FALLING: int = 13


# =========================
# Mouse Look
# =========================

@export_category("Mouse Look")

@export var mouse_sensitivity: float = 0.002

# =========================
# References
# =========================

const BLOCK_RAY_LENGTH := 4.5

@onready var world = $"../World"
@onready var camera: Camera3D = $Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

@export_category("Sprint FOV")
@export var sprint_fov_multiplier: float = 1.10
@export var fov_change_speed: float = 8.0
@export var camera_transition_speed: float = 12.0

var normal_fov: float
var controls_enabled: bool = false
var is_crouching: bool = false

var break_requested: bool = false
var place_requested: bool = false


const STANDING_HEIGHT: float = 1.8
const CROUCH_HEIGHT: float = 1.5
const SWIM_CRAWL_HEIGHT: float = 0.6

const STANDING_CAMERA_HEIGHT: float = 1.62
const CROUCH_CAMERA_HEIGHT: float = 1.27
const SWIM_CRAWL_CAMERA_HEIGHT: float = 0.4

var standing_shape: BoxShape3D
var crouch_shape: BoxShape3D
var swim_crawl_shape: BoxShape3D

var swimming_mode: bool = false
var crawling_mode: bool = false
var sprint_toggled: bool = false
var crouch_toggled: bool = false
var target_camera_height: float = STANDING_CAMERA_HEIGHT
var current_pose: String = "standing"


func get_block_target() -> Dictionary:
	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z.normalized()
	var end := origin + direction * BLOCK_RAY_LENGTH

	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.exclude = [self]

	var result := get_world_3d().direct_space_state.intersect_ray(query)

	return result


func break_block() -> void:
	var result := get_block_target()

	if result.is_empty():
		return

	var hit_position: Vector3 = result["position"]
	var hit_normal: Vector3 = result["normal"]

	var block_position := (hit_position - hit_normal * 0.01).floor()

	world.set_block_world(
		block_position,
		0
	)

func place_block() -> void:
	var result := get_block_target()

	if result.is_empty():
		return

	var hit_position: Vector3 = result["position"]
	var hit_normal: Vector3 = result["normal"]

	var block_position: Vector3 = (
		hit_position + hit_normal * 0.01
	).floor()

	# Never allow the new block to overlap the player's hitbox.
	if block_overlaps_player(block_position):
		return

	world.set_block_world(
		block_position,
		world.selected_block
	)


func block_overlaps_player(
	block_position: Vector3
) -> bool:
	var collision_shape: CollisionShape3D = $CollisionShape3D

	if collision_shape.shape == null:
		return false

	if not collision_shape.shape is BoxShape3D:
		return false

	var player_box: BoxShape3D = (
		collision_shape.shape as BoxShape3D
	)

	var player_center: Vector3 = (
		collision_shape.global_position
	)

	var player_half_size: Vector3 = (
		player_box.size * 0.5
	)

	# Player hitbox bounds.
	var player_min: Vector3 = (
		player_center - player_half_size
	)

	var player_max: Vector3 = (
		player_center + player_half_size
	)

	# Candidate block bounds.
	var block_min: Vector3 = block_position
	var block_max: Vector3 = (
		block_position + Vector3.ONE
	)

	# Small tolerance prevents floating-point noise
	# from treating touching surfaces as overlapping.
	const EPSILON: float = 0.001

	var overlaps_x: bool = (
		player_min.x < block_max.x - EPSILON
		and player_max.x > block_min.x + EPSILON
	)

	var overlaps_y: bool = (
		player_min.y < block_max.y - EPSILON
		and player_max.y > block_min.y + EPSILON
	)

	var overlaps_z: bool = (
		player_min.z < block_max.z - EPSILON
		and player_max.z > block_min.z + EPSILON
	)

	return overlaps_x and overlaps_y and overlaps_z


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	normal_fov = GameSettings.fov
	camera.fov = normal_fov
	floor_snap_length = 0.1

	standing_shape = (collision_shape.shape as BoxShape3D).duplicate()

	crouch_shape = BoxShape3D.new()
	crouch_shape.size = Vector3(0.7, CROUCH_HEIGHT, 0.7)

	swim_crawl_shape = BoxShape3D.new()
	swim_crawl_shape.size = Vector3(0.7, SWIM_CRAWL_HEIGHT, 0.7)

	_apply_pose("standing", true)


func _apply_pose(pose: String, instant_camera: bool = false) -> void:
	current_pose = pose

	match pose:
		"swim", "crawl":
			collision_shape.shape = swim_crawl_shape
			collision_shape.position.y = SWIM_CRAWL_HEIGHT * 0.5
			target_camera_height = SWIM_CRAWL_CAMERA_HEIGHT
		"crouch":
			collision_shape.shape = crouch_shape
			collision_shape.position.y = CROUCH_HEIGHT * 0.5
			target_camera_height = CROUCH_CAMERA_HEIGHT
		_:
			collision_shape.shape = standing_shape
			collision_shape.position.y = STANDING_HEIGHT * 0.5
			target_camera_height = STANDING_CAMERA_HEIGHT

	if instant_camera:
		camera.position.y = target_camera_height


func _set_standing_pose() -> void:
	_apply_pose("standing")


func _set_crouch_pose() -> void:
	_apply_pose("crouch")


func _set_swim_crawl_pose() -> void:
	_apply_pose("swim" if swimming_mode else "crawl")


func _can_stand_up() -> bool:
	# Only check the vertical space that would be newly occupied when
	# moving from the current pose to the standing pose. A wall beside
	# the player must not count as blocked headroom just because the
	# player's full standing hitbox touches that wall.
	if standing_shape == null or collision_shape == null:
		return true

	if not standing_shape is BoxShape3D:
		return true

	var standing_box: BoxShape3D = standing_shape
	var current_height: float = (
		collision_shape.shape.size.y
		if collision_shape.shape is BoxShape3D
		else standing_box.size.y
	)

	# If already standing, there is no extra vertical space to check.
	if current_height >= standing_box.size.y - 0.001:
		return true

	var half_width_x: float = standing_box.size.x * 0.5
	var half_width_z: float = standing_box.size.z * 0.5

	# Small inset prevents exact face/corner touching from being treated
	# as an occupied cell. The important part is that Y starts at the top
	# of the current pose, not at the player's feet.
	const EPSILON: float = 0.001

	var min_x: float = global_position.x - half_width_x + EPSILON
	var max_x: float = global_position.x + half_width_x - EPSILON
	var min_y: float = global_position.y + current_height + EPSILON
	var max_y: float = global_position.y + standing_box.size.y - EPSILON
	var min_z: float = global_position.z - half_width_z + EPSILON
	var max_z: float = global_position.z + half_width_z - EPSILON

	if min_x > max_x or min_y > max_y or min_z > max_z:
		return true

	var min_block_x: int = floori(min_x)
	var max_block_x: int = floori(max_x)
	var min_block_y: int = floori(min_y)
	var max_block_y: int = floori(max_y)
	var min_block_z: int = floori(min_z)
	var max_block_z: int = floori(max_z)

	for y in range(min_block_y, max_block_y + 1):
		for x in range(min_block_x, max_block_x + 1):
			for z in range(min_block_z, max_block_z + 1):
				var block_id: int = world.get_block_world(
					Vector3(
						x + 0.5,
						y + 0.5,
						z + 0.5
					)
				)

				if _is_solid_block(block_id):
					return false

	return true


func _update_swim_crawl_state(
	in_water: bool,
	head_in_water: bool,
	sprinting: bool
) -> void:
	var moving_forward: bool = Input.is_action_pressed("move_forward")
	var want_crouch: bool = _is_crouch_active() and not in_water

	if swimming_mode:
		if in_water and moving_forward:
			_set_swim_crawl_pose()
			return

		swimming_mode = false
		if _can_stand_up():
			crawling_mode = want_crouch
			if want_crouch:
				_set_crouch_pose()
			else:
				_set_standing_pose()
		else:
			crawling_mode = true
			_set_swim_crawl_pose()
		return

	if crawling_mode:
		if in_water and head_in_water and sprinting:
			crawling_mode = false
			swimming_mode = true
			_set_swim_crawl_pose()
			return

		if _can_stand_up() and not want_crouch:
			crawling_mode = false
			_set_standing_pose()
		elif want_crouch and _can_stand_up():
			crawling_mode = false
			_set_crouch_pose()
		else:
			crawling_mode = true
			_set_swim_crawl_pose()
		return

	if in_water and head_in_water and sprinting and moving_forward:
		swimming_mode = true
		_set_swim_crawl_pose()
		return

	if want_crouch:
		_set_crouch_pose()
		return

	if not _can_stand_up():
		crawling_mode = true
		_set_swim_crawl_pose()
		return

	_set_standing_pose()


func _update_toggle_actions() -> void:
	if GameSettings.toggle_sprint:
		if Input.is_action_just_pressed("sprint"):
			sprint_toggled = not sprint_toggled
	else:
		sprint_toggled = false

	if GameSettings.toggle_crouch:
		if Input.is_action_just_pressed("crouch"):
			crouch_toggled = not crouch_toggled
	else:
		crouch_toggled = false


func _is_sprint_active() -> bool:
	if GameSettings.toggle_sprint:
		return sprint_toggled
	return Input.is_action_pressed("sprint")


func _is_crouch_active() -> bool:
	if GameSettings.toggle_crouch:
		return crouch_toggled
	return Input.is_action_pressed("crouch")


func enable_controls() -> void:
	controls_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not controls_enabled:
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			break_requested = true

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			place_requested = true

	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)

		camera.rotation.x -= event.relative.y * mouse_sensitivity
		camera.rotation.x = clamp(
			camera.rotation.x,
			deg_to_rad(-89.0),
			deg_to_rad(89.0)
		)

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				world.selected_block = 1

			KEY_2:
				world.selected_block = WATER

			KEY_3:
				world.selected_block = 0

			KEY_4:
				world.selected_block = 0

			KEY_5:
				world.selected_block = 0

			KEY_6:
				world.selected_block = 0

			KEY_7:
				world.selected_block = 0

			KEY_8:
				world.selected_block = 0

			KEY_9:
				world.selected_block = 0


func _is_water_block(block_id: int) -> bool:
	return block_id >= WATER and block_id <= WATER_FALLING


func _is_solid_block(block_id: int) -> bool:
	return block_id != AIR and not _is_water_block(block_id)


func is_in_water() -> bool:
	var height: float = (
		collision_shape.shape.size.y
		if collision_shape.shape is BoxShape3D
		else STANDING_HEIGHT
	)

	# Sample several points up the player's body rather than selecting
	# one voxel from the feet. The lowest sample is 0.125 blocks above
	# the feet, which is safely above a water surface that is exactly
	# one pixel (1/16 block) below the top of a supporting block.
	# Higher samples keep swimming active while the player rises
	# through the water.
	var sample_heights := [
		0.125,
		height * 0.25,
		height * 0.5,
		minf(height * 0.75, height - 0.05)
	]

	for sample_height in sample_heights:
		if _is_water_block(
			world.get_block_world(
				global_position + Vector3(
					0.0,
					sample_height,
					0.0
				)
			)
		):
			return true

	return false


func is_head_in_water() -> bool:
	return _is_water_block(
		world.get_block_world(camera.global_position)
	)


func _water_below_feet() -> bool:
	return _is_water_block(
		world.get_block_world(global_position + Vector3(0.0, -0.08, 0.0))
	)


func _solid_below_feet() -> bool:
	return _is_solid_block(
		world.get_block_world(global_position + Vector3(0.0, -0.08, 0.0))
	)


func _submerged_depth() -> float:
	var depth := 0.0
	var height: float = collision_shape.shape.size.y if collision_shape.shape is BoxShape3D else STANDING_HEIGHT
	var step := 0.1
	var y := 0.05
	while y < height:
		if _is_water_block(world.get_block_world(global_position + Vector3(0.0, y, 0.0))):
			depth += step
		y += step
	return depth


func _is_shallow_water_for_ground_jump() -> bool:
	if is_head_in_water():
		return false
	if _submerged_depth() > water_fluid_jump_threshold:
		return false
	return is_on_floor()


func _can_water_shore_jump(direction: Vector3) -> bool:
	var horizontal_direction := Vector3(direction.x, 0.0, direction.z)
	if horizontal_direction.length_squared() <= 0.0001:
		return false
	horizontal_direction = horizontal_direction.normalized()

	var sample_position: Vector3 = global_position + horizontal_direction * 0.55
	var shore_x: int = floori(sample_position.x)
	var shore_z: int = floori(sample_position.z)
	var base_y: int = floori(global_position.y)

	for y_offset in range(0, 2):
		var shore_y: int = base_y + y_offset
		var shore_block: int = world.get_block_world(Vector3(shore_x + 0.001, shore_y + 0.001, shore_z + 0.001))
		if not _is_solid_block(shore_block):
			continue

		var block_above: int = world.get_block_world(Vector3(shore_x + 0.001, shore_y + 1.001, shore_z + 0.001))
		if block_above != AIR and not _is_water_block(block_above):
			continue

		if test_move(global_transform, horizontal_direction * 0.45):
			return true

	return false


func is_swimming() -> bool:
	return swimming_mode


func get_swim_direction(input_vector: Vector2) -> Vector3:
	var camera_forward: Vector3 = (-camera.global_transform.basis.z).normalized()
	var camera_right: Vector3 = camera.global_transform.basis.x.normalized()
	var direction: Vector3 = camera_right * input_vector.x - camera_forward * input_vector.y
	if direction.length_squared() > 0.0001:
		direction = direction.normalized()
	return direction


func _physics_process(delta: float) -> void:
	if break_requested:
		break_requested = false
		break_block()

	if place_requested:
		place_requested = false
		place_block()

	var in_water: bool = is_in_water()
	var head_in_water: bool = is_head_in_water()

	# is_in_water() is the authoritative water-state test. Do not
	# override it with a "water below feet" check: at the edge of a
	# solid block, the center voxel can be water even while the player
	# is still standing on solid ground.
	if in_water:
		floor_snap_length = 0.0
	else:
		floor_snap_length = 0.1

	_update_toggle_actions()

	is_crouching = _is_crouch_active()
	var moving_forward: bool = Input.is_action_pressed(
		"move_forward"
	)

	var sprinting: bool = (
		_is_sprint_active()
		and not is_crouching
	)

	_update_swim_crawl_state(
		in_water,
		head_in_water,
		sprinting
	)

	var swimming: bool = swimming_mode

	var input_vector := Input.get_vector(
		"move_left",
		"move_right",
		"move_forward",
		"move_backward"
	)

	# ---------------------------------------------------------------
	# FOV
	# ---------------------------------------------------------------

	var effective_sprinting: bool = (
		sprinting
		or swimming
	)

	var target_fov := normal_fov

	if (
		effective_sprinting
		and input_vector.length_squared() > 0.0
	):
		target_fov = (
			normal_fov *
			sprint_fov_multiplier
		)

	camera.fov = lerp(
		camera.fov,
		target_fov,
		1.0 - exp(-fov_change_speed * delta)
	)
	camera.position.y = lerp(
		camera.position.y,
		target_camera_height,
		1.0 - exp(-camera_transition_speed * delta)
	)


	# ---------------------------------------------------------------
	# Direction
	# ---------------------------------------------------------------

	var direction := Vector3.ZERO

	if input_vector.length_squared() > 0.0:

		if swimming:

			# Swimming uses the full camera direction.
			direction = get_swim_direction(
				input_vector
			)

		else:

			# Normal walking/treading-water movement
			# stays horizontal.
			direction = (
				transform.basis *
				Vector3(
					input_vector.x,
					0.0,
					input_vector.y
				)
			).normalized()


	# ---------------------------------------------------------------
	# Chunk entry safety
	# ---------------------------------------------------------------

	if direction != Vector3.ZERO:

		var predicted_position: Vector3 = (
			global_position +
			direction * 0.15
		)

		var current_chunk: Vector2i = (
			world.world_to_chunk(
				global_position
			)
		)

		var predicted_chunk: Vector2i = (
			world.world_to_chunk(
				predicted_position
			)
		)

		if (
			predicted_chunk != current_chunk
			and not world.can_player_enter_chunk(
				predicted_chunk
			)
		):
			direction = Vector3.ZERO


	# ---------------------------------------------------------------
	# WATER MOVEMENT
	# ---------------------------------------------------------------

	# Godot's velocity is in blocks/second while Minecraft stores
	# entity velocity in blocks/tick. This fractional-tick update
	# preserves Minecraft's 20 TPS recurrence at arbitrary FPS.
	var tick_scale: float = delta * 20.0
	# is_on_floor() uses the actual collision contacts, so standing on the
	# edge of a block still counts as grounded. A center-voxel lookup can
	# miss that support and incorrectly disable jumping.
	var grounded_for_jump: bool = is_on_floor()

	var shallow_water_ground_jump: bool = (
		grounded_for_jump
		and _is_shallow_water_for_ground_jump()
	)

	var use_water_physics: bool = in_water and not shallow_water_ground_jump

	if use_water_physics:
		var water_drag: float = water_swim_drag if swimming else water_normal_drag
		var vertical_drag: float = water_swim_drag if swimming else water_vertical_drag
		var drag_factor: float = pow(water_drag, tick_scale)
		var vertical_drag_factor: float = pow(vertical_drag, tick_scale)
		var recurrence_factor: float = (1.0 - drag_factor) / (1.0 - water_drag)
		var vertical_recurrence_factor: float = (1.0 - vertical_drag_factor) / (1.0 - vertical_drag)

		var move_direction := direction
		if swimming and move_direction.length_squared() > 0.0001:
			move_direction = move_direction.normalized()

		var acceleration: float = water_acceleration_per_tick * 20.0
		var input_velocity := Vector3.ZERO
		if swimming:
			input_velocity = move_direction * acceleration * water_drag
		else:
			input_velocity = Vector3(move_direction.x, 0.0, move_direction.z) * acceleration * water_drag

		if is_crouching:
			input_velocity.y = -water_sneak_impulse_per_tick * 20.0 * vertical_drag
		elif Input.is_action_pressed("jump"):
			input_velocity.y += water_jump_impulse_per_tick * 20.0 * vertical_drag
		elif swimming:
			input_velocity.y = move_direction.y * acceleration * vertical_drag

		if not swimming:
			input_velocity.y -= water_gravity_per_tick * 20.0 / 16.0 * vertical_drag

		velocity.x = velocity.x * drag_factor + input_velocity.x * recurrence_factor
		velocity.z = velocity.z * drag_factor + input_velocity.z * recurrence_factor
		velocity.y = velocity.y * vertical_drag_factor + input_velocity.y * vertical_recurrence_factor

		if (
			moving_forward
			and Input.is_action_pressed("jump")
			and _can_water_shore_jump(direction)
		):
			velocity.y = maxf(velocity.y, water_edge_jump_velocity_per_tick * 20.0)
			if not swimming:
				velocity.y = maxf(velocity.y, jump_velocity * 0.85)

	else:

		# -------------------------------------------------------
		# NORMAL AIR / GROUND MOVEMENT
		# -------------------------------------------------------

		# Gravity.
		if not grounded_for_jump:
			velocity.y -= gravity * delta
		else:
			if velocity.y < 0.0:
				velocity.y = 0.0

			# Holding Space keeps the Minecraft-style bunny-hop.
			if Input.is_action_pressed("jump"):
				velocity.y = jump_velocity

		# Horizontal movement.
		is_crouching = _is_crouch_active()

		var current_speed := walk_speed

		if crawling_mode:
			current_speed = crouch_speed
		elif sprinting:
			current_speed = sprint_speed
		elif is_crouching:
			current_speed = crouch_speed

		var target_velocity := direction * current_speed

		if grounded_for_jump:

			if direction != Vector3.ZERO:

				velocity.x = move_toward(
					velocity.x,
					target_velocity.x,
					ground_acceleration * delta
				)

				velocity.z = move_toward(
					velocity.z,
					target_velocity.z,
					ground_acceleration * delta
				)

			else:

				velocity.x = move_toward(
					velocity.x,
					0.0,
					ground_friction * delta
				)

				velocity.z = move_toward(
					velocity.z,
					0.0,
					ground_friction * delta
				)

		else:

			velocity.x = move_toward(
				velocity.x,
				target_velocity.x,
				air_acceleration * delta
			)

			velocity.z = move_toward(
				velocity.z,
				target_velocity.z,
				air_acceleration * delta
			)


	# ---------------------------------------------------------------
	# Move
	# ---------------------------------------------------------------

	move_and_slide()

	# Re-check the water state after movement so the player
	# can transition out of the swimming/crawling pose immediately.
	var post_move_in_water: bool = is_in_water()
	var post_move_head_in_water: bool = is_head_in_water()

	# Re-check the pose after movement so leaving the water
	# immediately transitions to standing or crawling.
	if (
		post_move_in_water != in_water
		or post_move_head_in_water != head_in_water
	):
		_update_swim_crawl_state(
			post_move_in_water,
			post_move_head_in_water,
			sprinting
		)