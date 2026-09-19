extends Node

var world_name: String = ""
var world_seed: int = 0
var load_existing: bool = false


func start_new_world(new_name: String, new_seed: int) -> void:
	world_name = new_name
	world_seed = new_seed
	load_existing = false


func start_existing_world(existing_name: String) -> void:
	world_name = existing_name
	world_seed = 0
	load_existing = true


func clear() -> void:
	world_name = ""
	world_seed = 0
	load_existing = false
