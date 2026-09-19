extends RefCounted
class_name WorldStore

const WORLDS_ROOT := "user://worlds"


static func worlds_dir() -> String:
	return WORLDS_ROOT


static func world_dir(world_name: String) -> String:
	return "%s/%s" % [WORLDS_ROOT, world_name]


static func chunks_dir(world_name: String) -> String:
	return "%s/chunks" % world_dir(world_name)


static func metadata_path(world_name: String) -> String:
	return "%s/world.json" % world_dir(world_name)


static func chunk_path(world_name: String, chunk_coord: Vector2i) -> String:
	return "%s/%d_%d.bin" % [chunks_dir(world_name), chunk_coord.x, chunk_coord.y]


static func sanitize_world_name(world_name: String) -> String:
	var cleaned := ""
	for character in world_name.strip_edges():
		if (
			(character >= "a" and character <= "z")
			or (character >= "A" and character <= "Z")
			or (character >= "0" and character <= "9")
			or character == "_"
			or character == "-"
			or character == " "
		):
			cleaned += character
	return cleaned.strip_edges()


static func ensure_world_folders(world_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(chunks_dir(world_name))


static func world_exists(world_name: String) -> bool:
	return FileAccess.file_exists(metadata_path(world_name))


static func list_worlds() -> Array[Dictionary]:
	var worlds: Array[Dictionary] = []
	DirAccess.make_dir_recursive_absolute(WORLDS_ROOT)

	var directory := DirAccess.open(WORLDS_ROOT)
	if directory == null:
		return worlds

	directory.list_dir_begin()
	var entry := directory.get_next()
	while entry != "":
		if directory.current_is_dir() and not entry.begins_with("."):
			var data := load_metadata(entry)
			if not data.is_empty():
				worlds.append(data)
		entry = directory.get_next()
	directory.list_dir_end()

	worlds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("modified_at", 0)) > int(b.get("modified_at", 0))
	)
	return worlds


static func create_world(world_name: String, world_seed: int) -> Dictionary:
	ensure_world_folders(world_name)
	var data := {
		"name": world_name,
		"seed": world_seed,
		"player_x": 8.5,
		"player_y": -1.0,
		"player_z": 8.5,
		"player_yaw": 0.0,
		"created_at": Time.get_unix_time_from_system(),
		"modified_at": Time.get_unix_time_from_system()
	}
	save_metadata(world_name, data)
	return data


static func load_metadata(world_name: String) -> Dictionary:
	var path := metadata_path(world_name)
	if not FileAccess.file_exists(path):
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}

	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}

	var data: Dictionary = parsed
	data["name"] = world_name
	return data


static func save_metadata(world_name: String, data: Dictionary) -> void:
	ensure_world_folders(world_name)
	data["name"] = world_name
	data["modified_at"] = Time.get_unix_time_from_system()

	var file := FileAccess.open(metadata_path(world_name), FileAccess.WRITE)
	if file == null:
		push_error("Could not save world metadata for %s" % world_name)
		return
	file.store_string(JSON.stringify(data, "\t"))


static func save_chunk(world_name: String, chunk_coord: Vector2i, blocks: PackedByteArray) -> void:
	ensure_world_folders(world_name)
	var file := FileAccess.open(chunk_path(world_name, chunk_coord), FileAccess.WRITE)
	if file == null:
		push_error("Could not save chunk %s" % str(chunk_coord))
		return
	file.store_buffer(blocks)


static func load_chunk(world_name: String, chunk_coord: Vector2i) -> PackedByteArray:
	var path := chunk_path(world_name, chunk_coord)
	if not FileAccess.file_exists(path):
		return PackedByteArray()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	return file.get_buffer(file.get_length())


static func delete_world(world_name: String) -> void:
	_delete_dir(world_dir(world_name))


static func _delete_dir(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return

	directory.list_dir_begin()
	var entry := directory.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child := "%s/%s" % [path, entry]
			if directory.current_is_dir():
				_delete_dir(child)
			else:
				directory.remove(entry)
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)
