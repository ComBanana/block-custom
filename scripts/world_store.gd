extends RefCounted
class_name WorldStore


const WINDOWS_LEGACY_WORLDS_ROOT_SUFFIX := "Godot/app_userdata/BlockCraft/worlds"
const WINDOWS_WORLDS_ROOT_SUFFIX := "BlockCraft/worldsaves"
const FALLBACK_WORLDS_ROOT := "user://worlds"

const CURRENT_SAVE_FORMAT_VERSION: int = 2
const UNKNOWN_LEGACY_GAME_VERSION: String = "0.0.0"


static func worlds_dir() -> String:
	if OS.get_name() == "Windows":
		var appdata := OS.get_environment("APPDATA").strip_edges()
		if appdata != "":
			return "%s/%s" % [appdata, WINDOWS_WORLDS_ROOT_SUFFIX]

	return FALLBACK_WORLDS_ROOT


static func legacy_worlds_dir() -> String:
	if OS.get_name() != "Windows":
		return ""

	var appdata := OS.get_environment("APPDATA").strip_edges()
	if appdata == "":
		return ""

	return "%s/%s" % [appdata, WINDOWS_LEGACY_WORLDS_ROOT_SUFFIX]


static func worlds_display_path() -> String:
	return worlds_dir()


static func legacy_worlds_display_path() -> String:
	return legacy_worlds_dir()


static func world_dir(world_name: String) -> String:
	return _world_dir_in_root(_storage_root_for_existing_world(world_name), world_name)


static func _world_dir_in_root(root: String, world_name: String) -> String:
	return "%s/%s" % [root, world_name]


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
	if _world_exists_in_root(worlds_dir(), world_name):
		return true

	var legacy_root := legacy_worlds_dir()
	if legacy_root != "" and _world_exists_in_root(legacy_root, world_name):
		return true

	return false


static func _world_exists_in_root(root: String, world_name: String) -> bool:
	if root == "":
		return false
	return FileAccess.file_exists(
		"%s/%s/world.json" % [root, world_name]
	)


static func _storage_root_for_existing_world(world_name: String) -> String:
	var new_root := worlds_dir()
	if _world_exists_in_root(new_root, world_name):
		return new_root

	var legacy_root := legacy_worlds_dir()
	if legacy_root != "" and _world_exists_in_root(
		legacy_root,
		world_name
	):
		return legacy_root

	return new_root


static func _list_worlds_in_root(root: String) -> Array[Dictionary]:
	var worlds: Array[Dictionary] = []

	if root == "" or not DirAccess.dir_exists_absolute(root):
		return worlds

	for entry in DirAccess.get_directories_at(root):
		if entry.begins_with("."):
			continue

		var data := _load_metadata_from_root(root, entry)
		if data.is_empty():
			continue

		data["_storage_root"] = root
		worlds.append(data)

	return worlds


static func list_worlds() -> Array[Dictionary]:
	var worlds: Array[Dictionary] = []
	var seen_world_names: Dictionary = {}

	DirAccess.make_dir_recursive_absolute(worlds_dir())

	for data in _list_worlds_in_root(worlds_dir()):
		var world_name := str(data.get("name", ""))
		if world_name == "" or seen_world_names.has(world_name):
			continue

		seen_world_names[world_name] = true
		worlds.append(data)

	var legacy_root := legacy_worlds_dir()
	if legacy_root != "" and DirAccess.dir_exists_absolute(legacy_root):
		for data in _list_worlds_in_root(legacy_root):
			var world_name := str(data.get("name", ""))
			if world_name == "" or seen_world_names.has(world_name):
				continue

			seen_world_names[world_name] = true
			worlds.append(data)

	worlds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("modified_at", 0)) > int(b.get("modified_at", 0))
	)
	return worlds


static func has_legacy_worlds() -> bool:
	var legacy_root := legacy_worlds_dir()
	if legacy_root == "" or not DirAccess.dir_exists_absolute(legacy_root):
		return false

	for entry in DirAccess.get_directories_at(legacy_root):
		if entry.begins_with("."):
			continue

		if _world_exists_in_root(legacy_root, entry):
			return true

	return false


static func create_world(world_name: String, world_seed: int) -> Dictionary:
	# New worlds always go to the new BlockCraft save location.
	var root := worlds_dir()
	var directory := _world_dir_in_root(root, world_name)
	DirAccess.make_dir_recursive_absolute("%s/chunks" % directory)

	var now := Time.get_unix_time_from_system()
	var data := {
		"name": world_name,
		"seed": world_seed,
		"player_x": 8.5,
		"player_y": -1.0,
		"player_z": 8.5,
		"player_yaw": 0.0,
		"created_at": now,
		"modified_at": now
	}
	_save_metadata_to_root(root, world_name, data)
	return data


static func load_metadata(world_name: String) -> Dictionary:
	return _load_metadata_from_root(
		_storage_root_for_existing_world(world_name),
		world_name
	)


static func _load_metadata_from_root(
	root: String,
	world_name: String
) -> Dictionary:
	var path := "%s/%s/world.json" % [root, world_name]
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

	# Worlds created before version metadata existed remain readable.
	# Their chunk data is migrated by World when the chunk height changed.
	if not data.has("save_format_version"):
		data["save_format_version"] = 1

	if not data.has("game_version"):
		data["game_version"] = UNKNOWN_LEGACY_GAME_VERSION

	return data


static func save_metadata(world_name: String, data: Dictionary) -> void:
	_save_metadata_to_root(
		_storage_root_for_existing_world(world_name),
		world_name,
		data
	)


static func _save_metadata_to_root(
	root: String,
	world_name: String,
	data: Dictionary
) -> void:
	var directory := _world_dir_in_root(root, world_name)
	DirAccess.make_dir_recursive_absolute("%s/chunks" % directory)

	data["name"] = world_name
	data["modified_at"] = Time.get_unix_time_from_system()

	var path := "%s/world.json" % directory
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not save world metadata for %s" % world_name)
		return

	file.store_string(JSON.stringify(data, "\t"))


static func save_chunk(
	world_name: String,
	chunk_coord: Vector2i,
	blocks: PackedByteArray
) -> void:
	var root := _storage_root_for_existing_world(world_name)
	var path := "%s/%s/chunks/%d_%d.bin" % [
		root,
		world_name,
		chunk_coord.x,
		chunk_coord.y
	]

	DirAccess.make_dir_recursive_absolute(
		"%s/%s/chunks" % [root, world_name]
	)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Could not save chunk %s" % str(chunk_coord))
		return

	file.store_buffer(blocks)


static func load_chunk(
	world_name: String,
	chunk_coord: Vector2i
) -> PackedByteArray:
	var root := _storage_root_for_existing_world(world_name)
	var path := "%s/%s/chunks/%d_%d.bin" % [
		root,
		world_name,
		chunk_coord.x,
		chunk_coord.y
	]

	if not FileAccess.file_exists(path):
		return PackedByteArray()

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()

	return file.get_buffer(file.get_length())


static func delete_world(world_name: String) -> void:
	var root := _storage_root_for_existing_world(world_name)
	_delete_dir(_world_dir_in_root(root, world_name))


static func migrate_legacy_worlds() -> Dictionary:
	var result := {
		"success": false,
		"moved": 0,
		"failed": 0,
		"renamed": 0,
		"old_folder_deleted": false,
		"failed_worlds": []
	}

	var legacy_root := legacy_worlds_dir()
	if legacy_root == "" or not DirAccess.dir_exists_absolute(legacy_root):
		result["success"] = true
		return result

	var new_root := worlds_dir()
	var make_dir_error := DirAccess.make_dir_recursive_absolute(new_root)
	if make_dir_error != OK:
		result["failed"] = DirAccess.get_directories_at(legacy_root).size()
		result["failed_worlds"] = DirAccess.get_directories_at(legacy_root)
		return result

	var legacy_world_names := DirAccess.get_directories_at(legacy_root)

	for legacy_name in legacy_world_names:
		if legacy_name.begins_with("."):
			continue

		if not _world_exists_in_root(legacy_root, legacy_name):
			continue

		var destination_name := legacy_name

		if _world_exists_in_root(new_root, destination_name):
			destination_name = _find_migration_name(new_root, legacy_name)
			result["renamed"] += 1

		var source_path := _world_dir_in_root(legacy_root, legacy_name)
		var destination_path := _world_dir_in_root(new_root, destination_name)

		var error := DirAccess.rename_absolute(
			source_path,
			destination_path
		)

		if error == OK:
			result["moved"] += 1
		else:
			result["failed"] += 1
			result["failed_worlds"].append(legacy_name)

	if result["failed"] == 0:
		var remaining_directories := DirAccess.get_directories_at(
			legacy_root
		)

		if remaining_directories.is_empty():
			var remove_error := DirAccess.remove_absolute(legacy_root)
			if remove_error == OK:
				result["old_folder_deleted"] = true
			else:
				result["failed"] = 1
				result["failed_worlds"].append(
					"Could not delete old worlds folder"
				)
		else:
			result["failed"] = remaining_directories.size()
			result["failed_worlds"] = remaining_directories

	result["success"] = (
		result["failed"] == 0
		and result["old_folder_deleted"]
	)
	return result


static func _find_migration_name(
	root: String,
	base_name: String
) -> String:
	var candidate := "%s - Migrated" % base_name
	var suffix := 2

	while _world_exists_in_root(root, candidate):
		candidate = "%s - Migrated %d" % [
			base_name,
			suffix
		]
		suffix += 1

	return candidate


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
