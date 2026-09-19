		var water_drag: float = (
			water_swim_drag
			if swimming
			else water_normal_drag
		)

		var vertical_drag: float = water_vertical_drag

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