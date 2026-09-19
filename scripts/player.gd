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
@export var water_edge_jump_velocity_per_tick: float = 0.3

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

var normal_fov: float
var controls_enabled: bool = false
var is_crouching: bool = false

var break_requested: bool = false
var place_requested: bool = false


const STANDING_HEIGHT: float = 1.8
const SWIM_CRAWL_HEIGHT: float = 0.6

const STANDING_CAMERA_HEIGHT: float = 1.6
const SWIM_CRAWL_CAMERA_HEIGHT: float = 0.4

var standing_shape: BoxShape3D
var swim_crawl_shape: BoxShape3D

var swimming_mode: bool = false
var crawling_mode: bool = false


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
	normal_fov = camera.fov

	# Keep the original standing collision shape as our
	# reusable standing shape.
	standing_shape = (
		collision_shape.shape as BoxShape3D
	).duplicate()

	# Low hitbox used for swimming and crawling.
	swim_crawl_shape = BoxShape3D.new()
	swim_crawl_shape.size = Vector3(
		0.7,
		SWIM_CRAWL_HEIGHT,
		0.7
	)

	# Make sure the starting pose is standing.
	_set_standing_pose()


func _set_standing_pose() -> void:
	collision_shape.shape = standing_shape

	collision_shape.position.y = (
		STANDING_HEIGHT * 0.5
	)

	camera.position.y = STANDING_CAMERA_HEIGHT


func _set_swim_crawl_pose() -> void:
	collision_shape.shape = swim_crawl_shape

	collision_shape.position.y = (
		SWIM_CRAWL_HEIGHT * 0.5
	)

	camera.position.y = SWIM_CRAWL_CAMERA_HEIGHT


func _can_stand_up() -> bool:
	var query := PhysicsShapeQueryParameters3D.new()

	query.shape = standing_shape

	query.transform = Transform3D(
		global_transform.basis,
		global_position
		+ Vector3(
			0.0,
			STANDING_HEIGHT * 0.5,
			0.0
		)
	)

	query.collision_mask = collision_mask
	query.exclude = [get_rid()]

	var results := get_world_3d().direct_space_state.intersect_shape(
		query,
		1
	)

	return results.is_empty()


func _update_swim_crawl_state(
	in_water: bool,
	head_in_water: bool,
	sprinting: bool
) -> void:

	# ---------------------------------------------------------------
	# Currently swimming
	# ---------------------------------------------------------------

	if swimming_mode:

		var moving_forward: bool = Input.is_action_pressed(
			"move_forward"
		)

		# Keep swim mode latched while W is held. Physical sprint
		# input no longer matters once swimming has started.
		if (
			in_water
			and moving_forward
			and not is_on_floor()
		):
			_set_swim_crawl_pose()
			return

		# Leaving the water OR releasing W ends swim mode.
		swimming_mode = false

		# Preserve the low posture if the surrounding blocks prevent
		# the player from standing normally.
		if _can_stand_up():
			crawling_mode = false
			_set_standing_pose()
		else:
			crawling_mode = true
			_set_swim_crawl_pose()

		return


	# ---------------------------------------------------------------
	# Currently crawling
	# ---------------------------------------------------------------

	if crawling_mode:

		# Entering water while crawling can put the player
		# back into swimming.
		if (
			in_water
			and head_in_water
			and sprinting
		):
			crawling_mode = false
			swimming_mode = true
			_set_swim_crawl_pose()
			return

		# Automatically stand when the obstruction is gone.
		if _can_stand_up():
			crawling_mode = false
			_set_standing_pose()
		else:
			_set_swim_crawl_pose()

		return


	# ---------------------------------------------------------------
	# Enter swimming
	# ---------------------------------------------------------------

	if (
		in_water
		and head_in_water
		and sprinting
		and Input.is_action_pressed("move_forward")
	):
		swimming_mode = true
		_set_swim_crawl_pose()
		return


	# ---------------------------------------------------------------
	# Normal standing
	# ---------------------------------------------------------------

	_set_standing_pose()


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


func is_in_water() -> bool:
	var sample_positions := [
		global_position + Vector3(0.0, 0.15, 0.0),
		global_position + Vector3(0.0, 0.9, 0.0)
	]

	for sample_position in sample_positions:
		if _is_water_block(
			world.get_block_world(sample_position)
		):
			return true

	return false


func is_head_in_water() -> bool:
	return _is_water_block(
		world.get_block_world(camera.global_position)
	)


func _is_shallow_water_for_ground_jump() -> bool:
	if not is_in_water() or is_head_in_water():
		return false

	var block_y := floorf(global_position.y)
	var fluid_depth := 1.0 - (global_position.y - block_y)

	return fluid_depth <= water_fluid_jump_threshold


func _can_water_edge_jump() -> bool:
	if not is_on_wall():
		return false

	# Match Java's fluid collision escape check: there must be
	# enough free space for the upward escape motion.
	return not test_move(
		global_transform,
		Vector3(0.0, 0.6, 0.0)
	)


func is_swimming() -> bool:
	return swimming_mode


func get_swim_direction(
	input_vector: Vector2
) -> Vector3:

	var camera_forward: Vector3 = (
		-camera.global_transform.basis.z
	).normalized()

	var camera_right: Vector3 = (
		camera.global_transform.basis.x
	).normalized()

	var direction: Vector3 = (
		camera_right * input_vector.x
		- camera_forward * input_vector.y
	)

	if direction.length_squared() > 1.0:
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

	is_crouching = Input.is_action_pressed("crouch")
	var moving_forward: bool = Input.is_action_pressed(
		"move_forward"
	)

	var sprinting: bool = (
		Input.is_action_pressed("sprint")
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
		1.0 - exp(
			-fov_change_speed * delta
		)
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
	var grounded_for_jump: bool = is_on_floor()

	var shallow_water_ground_jump: bool = (
		grounded_for_jump
		and _is_shallow_water_for_ground_jump()
	)

	var use_water_physics: bool = (
		in_water
		and not shallow_water_ground_jump
	)

	if use_water_physics:

		var water_drag: float = (
			water_swim_drag
			if swimming
			else water_normal_drag
		)

		var vertical_drag: float = (
			water_swim_drag
			if swimming
			else water_vertical_drag
		)

		# Java's updateVelocity adds 0.02 blocks/tick of movement
		# acceleration before fluid drag.

		# Jumping and sneaking in water are +/-0.04 blocks/tick
		# impulses, applied before the same vertical drag.
		var water_vertical_input: float = 0.0

		if is_crouching:
			# While swimming, Shift is an explicit DOWN control.
			# It overrides camera pitch and the jump key.
			water_vertical_input -= (
				water_sneak_impulse_per_tick * 20.0
			)
		elif Input.is_action_pressed("jump"):
			water_vertical_input += (
				water_jump_impulse_per_tick * 20.0
			)
		elif swimming:
			# Swimming follows the camera pitch. This uses the same
			# 0.02/tick water acceleration as the horizontal movement.
			water_vertical_input += (
				direction.y *
				water_acceleration_per_tick *
				water_swim_drag *
				20.0
			)

		var horizontal_drag_factor: float = pow(
			water_drag,
			tick_scale
		)

		var vertical_drag_factor: float = pow(
			vertical_drag,
			tick_scale
		)

		var horizontal_input_per_tick: Vector3 = (
			direction *
			water_acceleration_per_tick *
			20.0 *
			water_drag
		)

		var horizontal_recurrence_factor: float = (
			(1.0 - horizontal_drag_factor) /
			(1.0 - water_drag)
		)

		velocity.x = (
			velocity.x * horizontal_drag_factor
			+ horizontal_input_per_tick.x *
			horizontal_recurrence_factor
		)

		velocity.z = (
			velocity.z * horizontal_drag_factor
			+ horizontal_input_per_tick.z *
			horizontal_recurrence_factor
		)

		var vertical_input_per_tick: float = (
			water_vertical_input * vertical_drag
		)

		# Non-sprinting water travel applies gravity/16 after drag.
		# Sprint-swimming deliberately skips this adjustment.
		if not swimming:
			vertical_input_per_tick -= (
				water_gravity_per_tick * 20.0 / 16.0
			)

		var vertical_recurrence_factor: float = (
			(1.0 - vertical_drag_factor) /
			(1.0 - vertical_drag)
		)

		velocity.y = (
			velocity.y * vertical_drag_factor
			+ vertical_input_per_tick *
			vertical_recurrence_factor
		)

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
		is_crouching = Input.is_action_pressed("crouch")

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

	# ---------------------------------------------------------------
	# Water → shore hop
	# ---------------------------------------------------------------

	# Re-check the water state after movement. A player can still
	# have their feet in water while their normal standing head
	# position has already reached the shore.
	var post_move_in_water: bool = is_in_water()
	var post_move_head_in_water: bool = is_head_in_water()
	var post_move_standing_head_in_water: bool = _is_water_block(
		world.get_block_world(
			global_position +
			Vector3(0.0, STANDING_CAMERA_HEIGHT, 0.0)
		)
	)

	if (
		in_water
		and head_in_water
		and moving_forward
		and Input.is_action_pressed("jump")
		and not post_move_standing_head_in_water
		and _can_water_edge_jump()
	):
		velocity.y = (
			water_edge_jump_velocity_per_tick * 20.0
		)

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