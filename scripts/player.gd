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
@export var water_walk_speed: float = 1.8
@export var water_swim_speed: float = 5.6

@export var water_acceleration: float = 3.5
@export var water_swim_acceleration: float = 8.0

@export var water_drag: float = 0.8
@export var water_swim_drag: float = 0.9
@export var water_vertical_drag: float = 0.8

@export var water_gravity: float = 8.0
@export var water_sink_speed: float = 1.2
@export var water_fast_sink_speed: float = 3.0

@export var water_swim_up_speed: float = 3
@export var water_exit_jump_velocity: float = 6.0
@export var water_swim_down_speed: float = 2.5

const WATER: int = 5


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

		# Stay low while still in water.
		if in_water:
			_set_swim_crawl_pose()
			return

		# We have left the water.
		swimming_mode = false

		# Minecraft keeps the low posture when there isn't
		# enough room to stand up.
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
				world.selected_block = 0

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


func is_in_water() -> bool:
	var sample_positions := [
		global_position + Vector3(0.0, 0.15, 0.0),
		global_position + Vector3(0.0, 0.9, 0.0)
	]

	for sample_position in sample_positions:
		if world.get_block_world(
			sample_position
		) == WATER:
			return true

	return false


func is_head_in_water() -> bool:
	return (
		world.get_block_world(
			camera.global_position
		) == WATER
	)


func can_water_exit_jump() -> bool:
	if not is_on_wall():
		return false

	# Minecraft's water escape behavior checks whether
	# there is enough free space above the player.
	var motion := Vector3(
		0.0,
		0.75,
		0.0
	)

	return not test_move(
		global_transform,
		motion
	)


func is_swimming() -> bool:
	return (
		is_in_water()
		and is_head_in_water()
		and Input.is_action_pressed("sprint")
	)


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

	var target_fov := normal_fov

	if (
		sprinting
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

	if in_water:

		if swimming:

			# -------------------------------------------------------
			# FULL SWIMMING
			# -------------------------------------------------------

			var target_velocity: Vector3 = (
				direction *
				water_swim_speed
			)

			# Horizontal swimming.
			if direction != Vector3.ZERO:

				velocity.x = move_toward(
					velocity.x,
					target_velocity.x,
					water_swim_acceleration * delta
				)

				velocity.z = move_toward(
					velocity.z,
					target_velocity.z,
					water_swim_acceleration * delta
				)

			# -------------------------------------------------------
			# Vertical swimming
			# -------------------------------------------------------

			var target_vertical_velocity: float = (
				direction.y * water_swim_speed
			)

			# Holding Jump makes the player swim upward.
			if Input.is_action_pressed("jump"):

				target_vertical_velocity = (
					water_swim_up_speed
				)

			# Holding Crouch makes the player swim downward faster.
			elif is_crouching:

				target_vertical_velocity = (
					-water_fast_sink_speed
				)

			# No vertical input: gently sink.
			elif absf(target_vertical_velocity) < 0.01:

				target_vertical_velocity = (
					-water_sink_speed
				)

			velocity.y = move_toward(
				velocity.y,
				target_vertical_velocity,
				water_swim_acceleration * delta
			)

			# -------------------------------------------------------
			# Water drag
			# -------------------------------------------------------

			var swim_horizontal_drag: float = pow(
				water_swim_drag,
				delta * 20.0
			)

			var swim_vertical_drag: float = pow(
				water_vertical_drag,
				delta * 20.0
			)

			velocity.x *= swim_horizontal_drag
			velocity.z *= swim_horizontal_drag
			velocity.y *= swim_vertical_drag


		else:

			# -------------------------------------------------------
			# TREADING / WADING WATER
			# -------------------------------------------------------

			var target_velocity := (
				direction *
				water_walk_speed
			)

			if direction != Vector3.ZERO:

				velocity.x = move_toward(
					velocity.x,
					target_velocity.x,
					water_acceleration * delta
				)

				velocity.z = move_toward(
					velocity.z,
					target_velocity.z,
					water_acceleration * delta
				)

			else:

				var horizontal_drag: float = pow(
					water_drag,
					delta * 20.0
				)

				velocity.x *= horizontal_drag
				velocity.z *= horizontal_drag


			# -------------------------------------------------------
			# Natural sinking
			# -------------------------------------------------------

			velocity.y = move_toward(
				velocity.y,
				-water_sink_speed,
				water_vertical_drag * delta
			)


			# -------------------------------------------------------
			# Space = hop upward
			# -------------------------------------------------------

			if Input.is_action_pressed("jump"):
				velocity.y = move_toward(
					velocity.y,
					water_swim_up_speed,
					water_swim_acceleration * delta
				)

			if velocity.y < 0.0:
				velocity.y *= pow(
					water_vertical_drag,
					delta * 20.0
				)


	# ---------------------------------------------------------------
	# NORMAL AIR / GROUND MOVEMENT
	# ---------------------------------------------------------------

	else:

		# Gravity
		if not is_on_floor():

			velocity.y -= gravity * delta

		else:

			if velocity.y < 0.0:
				velocity.y = 0.0

			if Input.is_action_pressed("jump"):
				velocity.y = jump_velocity


		# Horizontal movement
		is_crouching = Input.is_action_pressed("crouch")

		var current_speed := walk_speed

		if crawling_mode:
			current_speed = crouch_speed
		elif sprinting:
			current_speed = sprint_speed
		elif is_crouching:
			current_speed = crouch_speed

		var target_velocity := direction * current_speed


		if is_on_floor():

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

	if (
		in_water
		and Input.is_action_pressed("jump")
		and can_water_exit_jump()
	):
		velocity.y = water_exit_jump_velocity

	# Re-check the pose after movement so leaving the water
	# immediately transitions to standing or crawling.
	var post_move_in_water: bool = is_in_water()
	var post_move_head_in_water: bool = is_head_in_water()

	if (
		post_move_in_water != in_water
		or post_move_head_in_water != head_in_water
	):
		_update_swim_crawl_state(
			post_move_in_water,
			post_move_head_in_water,
			sprinting
		)
