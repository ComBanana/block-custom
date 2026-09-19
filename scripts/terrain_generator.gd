extends RefCounted


const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 64

const AIR: int = 0
const GRASS: int = 1
const DIRT: int = 2
const STONE: int = 3
const SAND: int = 4
const WATER: int = 5

const WATER_LEVEL: int = 10


static func _get_index(
	x: int,
	y: int,
	z: int
) -> int:

	return (
		x
		+ z * CHUNK_SIZE
		+ y * CHUNK_SIZE * CHUNK_SIZE
	)


static func _get_dirt_depth(
	world_x: int,
	world_z: int,
	world_seed: int
) -> int:

	var value: int = (
		world_x * 374761393
		+ world_z * 668265263
		+ world_seed * 1442695041
	)

	value = value ^ (value >> 13)
	value = value * 1274126177
	value = value ^ (value >> 16)

	return 1 + posmod(
		absi(value),
		3
	)


static func generate_chunk_data(
	chunk_coordinate: Vector2i,
	world_seed: int = 12345
) -> PackedByteArray:

	var blocks := PackedByteArray()

	blocks.resize(
		CHUNK_SIZE
		* CHUNK_HEIGHT
		* CHUNK_SIZE
	)

	blocks.fill(AIR)


	# ---------------------------------------------------------------
	# Create private noise generators for this worker task.
	#
	# These are NOT shared with the main thread or other workers.
	# ---------------------------------------------------------------

	var terrain_noise := FastNoiseLite.new()
	terrain_noise.seed = world_seed
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	terrain_noise.frequency = 0.0075
	terrain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	terrain_noise.fractal_octaves = 3
	terrain_noise.fractal_gain = 0.45


	var hill_noise := FastNoiseLite.new()
	hill_noise.seed = world_seed + 11111
	hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	hill_noise.frequency = 0.018
	hill_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	hill_noise.fractal_octaves = 2
	hill_noise.fractal_gain = 0.45


	var mountain_region_noise := FastNoiseLite.new()
	mountain_region_noise.seed = world_seed + 22222
	mountain_region_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_region_noise.frequency = 0.0035
	mountain_region_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	mountain_region_noise.fractal_octaves = 2
	mountain_region_noise.fractal_gain = 0.5


	var mountain_shape_noise := FastNoiseLite.new()
	mountain_shape_noise.seed = world_seed + 33333
	mountain_shape_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_shape_noise.frequency = 0.009
	mountain_shape_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_shape_noise.fractal_octaves = 3
	mountain_shape_noise.fractal_gain = 0.5


	# ---------------------------------------------------------------
	# Store the terrain height of every X/Z column.
	# 16 * 16 = only 256 integers.
	# ---------------------------------------------------------------

	var heights := PackedInt32Array()

	heights.resize(
		CHUNK_SIZE * CHUNK_SIZE
	)


	# ---------------------------------------------------------------
	# TERRAIN GENERATION
	# ---------------------------------------------------------------

	for x in range(CHUNK_SIZE):

		for z in range(CHUNK_SIZE):

			var world_x: int = (
				chunk_coordinate.x * CHUNK_SIZE
				+ x
			)

			var world_z: int = (
				chunk_coordinate.y * CHUNK_SIZE
				+ z
			)


			var base_value: float = (
				terrain_noise.get_noise_2d(
					world_x,
					world_z
				)
			)


			var hill_value: float = (
				hill_noise.get_noise_2d(
					world_x,
					world_z
				)
			)


			var mountain_region_value: float = (
				mountain_region_noise.get_noise_2d(
					world_x,
					world_z
				)
			)


			var mountain_shape_value: float = (
				mountain_shape_noise.get_noise_2d(
					world_x,
					world_z
				)
			)


			var base_height: float = (
				12.0
				+ base_value * 4.0
			)


			var hill_height: float = (
				hill_value * 5.0
			)


			var mountain_mask: float = (
				mountain_region_value * 0.5
			) + 0.5


			mountain_mask = smoothstep(
				0.58,
				0.78,
				mountain_mask
			)


			var mountain_height: float = (
				mountain_shape_value * 28.0
			)


			var height_float: float = (
				base_height
				+ hill_height
				+ (
					mountain_height
					* mountain_mask
				)
			)


			var height: int = clampi(
				roundi(height_float),
				4,
				CHUNK_HEIGHT
			)


			heights[
				x + z * CHUNK_SIZE
			] = height


			var dirt_depth: int = (
				_get_dirt_depth(
					world_x,
					world_z,
					world_seed
				)
			)


			# Generate the actual solid terrain.
			for y in range(height):

				var index: int = _get_index(
					x,
					y,
					z
				)


				if y == height - 1:

					blocks[index] = GRASS

				elif y >= height - dirt_depth:

					blocks[index] = DIRT

				else:

					blocks[index] = STONE


	# ---------------------------------------------------------------
	# WATER
	#
	# Equivalent to:
	# AIR at Y <= 10 -> WATER
	#
	# Because terrain occupies Y < height, everything from height
	# through Y=10 is known to be AIR.
	# ---------------------------------------------------------------

	for x in range(CHUNK_SIZE):

		for z in range(CHUNK_SIZE):

			var height: int = heights[
				x + z * CHUNK_SIZE
			]


			if height > WATER_LEVEL:
				continue


			for y in range(
				height,
				WATER_LEVEL + 1
			):

				blocks[
					_get_index(
						x,
						y,
						z
					)
				] = WATER


	# ---------------------------------------------------------------
	# SAND
	#
	# Reproduces the current in-chunk rule:
	#
	# A solid block becomes sand when it touches water.
	#
	# We use the already-known column heights instead of scanning
	# all 16,384 block positions again.
	# ---------------------------------------------------------------

	for x in range(CHUNK_SIZE):

		for z in range(CHUNK_SIZE):

			var height: int = heights[
				x + z * CHUNK_SIZE
			]


			var max_y: int = mini(
				height - 1,
				WATER_LEVEL
			)


			if max_y < 0:
				continue


			for y in range(
				max_y + 1
			):

				var touching_water: bool = false


				# Water directly above this block.
				if (
					y == height - 1
					and height <= WATER_LEVEL
				):
					touching_water = true


				# Water beside this block.
				if not touching_water:

					if x > 0:

						var neighbor_height: int = heights[
							(x - 1)
							+ z * CHUNK_SIZE
						]

						if (
							neighbor_height <= y
							and neighbor_height <= WATER_LEVEL
						):
							touching_water = true


					if x < CHUNK_SIZE - 1:

						var neighbor_height: int = heights[
							(x + 1)
							+ z * CHUNK_SIZE
						]

						if (
							neighbor_height <= y
							and neighbor_height <= WATER_LEVEL
						):
							touching_water = true


					if z > 0:

						var neighbor_height: int = heights[
							x
							+ (z - 1) * CHUNK_SIZE
						]

						if (
							neighbor_height <= y
							and neighbor_height <= WATER_LEVEL
						):
							touching_water = true


					if z < CHUNK_SIZE - 1:

						var neighbor_height: int = heights[
							x
							+ (z + 1) * CHUNK_SIZE
						]

						if (
							neighbor_height <= y
							and neighbor_height <= WATER_LEVEL
						):
							touching_water = true


				if touching_water:

					blocks[
						_get_index(
							x,
							y,
							z
						)
					] = SAND


	return blocks
