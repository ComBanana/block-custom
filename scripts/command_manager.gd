extends RefCounted


func execute(
	raw_input: String,
	player: CharacterBody3D,
	world: Node3D
) -> Dictionary:
	var trimmed := raw_input.strip_edges()

	if not trimmed.begins_with("/"):
		return {
			"success": false,
			"message": "Commands must start with '/'."
		}

	var command_text := trimmed.substr(1).strip_edges()

	if command_text == "":
		return {
			"success": false,
			"message": "Usage: /tp <x> <y> <z>"
		}

	var parts := command_text.split(" ", false)
	var command := parts[0].to_lower()

	match command:
		"tp", "teleport":
			return _execute_tp(parts.slice(1), player, world)
		"time":
			return _execute_time(parts.slice(1), world)
		_:
			return {
				"success": false,
				"message": "Unknown command: /%s" % parts[0]
			}


func _execute_time(
	args: Array,
	world: Node3D
) -> Dictionary:
	if args.size() != 2 or args[0].to_lower() != "set":
		return {
			"success": false,
			"message": "Usage: /time set <sunrise|day|noon|evening|sunset|night|midnight>"
		}

	var preset := args[1].to_lower()

	if not world.set_time_preset(preset):
		return {
			"success": false,
			"message": "Unknown time: %s" % args[1]
		}

	return {
		"success": true,
		"message": "Time set to %s." % preset
	}


func _execute_tp(
	args: Array,
	player: CharacterBody3D,
	world: Node3D
) -> Dictionary:
	if args.size() != 3:
		return {
			"success": false,
			"message": "Usage: /tp <x> <y> <z>"
		}

	for value in args:
		if not value.is_valid_float():
			return {
				"success": false,
				"message": "Invalid coordinate: %s" % value
			}

	var target := Vector3(
		float(args[0]),
		float(args[1]),
		float(args[2])
	)

	# Refuse destinations outside the generated world height.
	if target.y < 0.0 or target.y >= 64.0:
		return {
			"success": false,
			"message": "Y coordinate must be between 0 and 63."
		}

	# Let the world streamer prepare the destination instead of
	# requiring the destination chunk to already be loaded.
	return world.request_teleport(target)


func _format_coordinate(value: float) -> String:
	if is_equal_approx(value, round(value)):
		return str(int(round(value)))

	return "%.3f" % value
