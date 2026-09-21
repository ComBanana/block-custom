extends RefCounted


const CHUNK_SIZE: int = 16
const CHUNK_HEIGHT: int = 256

const AIR: int = 0
const GRASS: int = 1
const DIRT: int = 2
const STONE: int = 3
const SAND: int = 4
const WATER: int = 5

# Blockcraft world-gen targets.
#
# A "height" is the number of solid blocks in a column, so a
# height of 51 means the top solid block is Y=50.
const SEA_LEVEL: int = 50
const NORMAL_LAND_HEIGHT: float = 51.0
const MIN_TERRAIN_HEIGHT: float = 2.0
const MAX_TERRAIN_HEIGHT: float = CHUNK_HEIGHT - 1.0


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

	return 2 + posmod(absi(value), 3)


static func _smoothstep(
	edge_0: float,
	edge_1: float,
	x: float
) -> float:
	if is_equal_approx(edge_0, edge_1):
		return 1.0 if x >= edge_1 else 0.0

	var t := clampf(
		(x - edge_0) / (edge_1 - edge_0),
		0.0,
		1.0
	)

	return t * t * (3.0 - 2.0 * t)


static func _ridged(value: float) -> float:
	return 1.0 - absf(value)


static func _peaks_and_valleys(weirdness: float) -> float:
	# Minecraft-style folded ridges value:
	# 1 - |(3 * |W|) - 2|
	return clampf(
		1.0 - absf((3.0 * absf(weirdness)) - 2.0),
		-1.0,
		1.0
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
	# Noise fields
	#
	# These are local to the worker task. FastNoiseLite is therefore
	# never shared or mutated across WorkerThreadPool jobs.
	#
	# The frequencies deliberately operate at different scales:
	# - continentalness: huge landmasses / oceans
	# - erosion: regional flat-vs-mountain tendency
	# - peaks: mountain/valley structure
	# - detail: small hills and surface variation
	# - rivers: long winding depressions
	# - ocean floor: independent underwater relief
	# ---------------------------------------------------------------

	var continentalness := FastNoiseLite.new()
	continentalness.seed = world_seed + 10001
	continentalness.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	continentalness.frequency = 0.00115
	continentalness.fractal_type = FastNoiseLite.FRACTAL_FBM
	continentalness.fractal_octaves = 4
	continentalness.fractal_gain = 0.50

	var erosion := FastNoiseLite.new()
	erosion.seed = world_seed + 20002
	erosion.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	erosion.frequency = 0.0042
	erosion.fractal_type = FastNoiseLite.FRACTAL_FBM
	erosion.fractal_octaves = 3
	erosion.fractal_gain = 0.50

	var peaks := FastNoiseLite.new()
	peaks.seed = world_seed + 30003
	peaks.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	peaks.frequency = 0.0060
	peaks.fractal_type = FastNoiseLite.FRACTAL_FBM
	peaks.fractal_octaves = 4
	peaks.fractal_gain = 0.48

	var detail := FastNoiseLite.new()
	detail.seed = world_seed + 40004
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail.frequency = 0.022
	detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 3
	detail.fractal_gain = 0.45

	var river_noise := FastNoiseLite.new()
	river_noise.seed = world_seed + 50005
	river_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	river_noise.frequency = 0.0026
	river_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	river_noise.fractal_octaves = 2
	river_noise.fractal_gain = 0.55

	var ocean_floor_large := FastNoiseLite.new()
	ocean_floor_large.seed = world_seed + 60006
	ocean_floor_large.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ocean_floor_large.frequency = 0.0038
	ocean_floor_large.fractal_type = FastNoiseLite.FRACTAL_FBM
	ocean_floor_large.fractal_octaves = 3
	ocean_floor_large.fractal_gain = 0.50

	var ocean_floor_detail := FastNoiseLite.new()
	ocean_floor_detail.seed = world_seed + 70007
	ocean_floor_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ocean_floor_detail.frequency = 0.015
	ocean_floor_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	ocean_floor_detail.fractal_octaves = 2
	ocean_floor_detail.fractal_gain = 0.45

	var beach_noise := FastNoiseLite.new()
	beach_noise.seed = world_seed + 80008
	beach_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	beach_noise.frequency = 0.010
	beach_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	beach_noise.fractal_octaves = 2
	beach_noise.fractal_gain = 0.50

	# 256 height samples are unnecessary; this heightmap stores only
	# the 16x16 column tops and is then voxel-filled.
	var heights := PackedInt32Array()
	heights.resize(CHUNK_SIZE * CHUNK_SIZE)

	var continentalness_values := PackedFloat32Array()
	continentalness_values.resize(CHUNK_SIZE * CHUNK_SIZE)

	var erosion_values := PackedFloat32Array()
	erosion_values.resize(CHUNK_SIZE * CHUNK_SIZE)

	var mountain_values := PackedFloat32Array()
	mountain_values.resize(CHUNK_SIZE * CHUNK_SIZE)

	# ---------------------------------------------------------------
	# PASS 1: calculate the final surface height for every column.
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

			var index: int = x + z * CHUNK_SIZE

			var c: float = continentalness.get_noise_2d(
				world_x,
				world_z
			)
			var e: float = (
				erosion.get_noise_2d(
					world_x,
					world_z
				)
				* 0.5
				+ 0.5
			)
			var weirdness: float = peaks.get_noise_2d(
				world_x,
				world_z
			)
			var pv: float = (
				_peaks_and_valleys(weirdness)
				* 0.5
				+ 0.5
			)
			var detail_value: float = detail.get_noise_2d(
				world_x,
				world_z
			)
			var river_value: float = river_noise.get_noise_2d(
				world_x,
				world_z
			)
			var ocean_large: float = ocean_floor_large.get_noise_2d(
				world_x,
				world_z
			)
			var ocean_detail: float = ocean_floor_detail.get_noise_2d(
				world_x,
				world_z
			)

			continentalness_values[index] = c
			erosion_values[index] = e

			# Low erosion + positive continentalness produces the
			# mountain belts. High erosion produces flatter terrain.
			var inland_factor: float = _smoothstep(
				-0.08,
				0.55,
				c
			)
			var mountain_factor: float = (
				1.0
				- _smoothstep(
					0.24,
					0.60,
					e
				)
			)
			mountain_factor *= inland_factor
			mountain_values[index] = mountain_factor

			# -----------------------------------------------------------
			# LAND HEIGHT
			# -----------------------------------------------------------

			var inland_height: float = (
				NORMAL_LAND_HEIGHT
				+ _smoothstep(
					0.05,
					0.80,
					c
				) * 15.0
			)

			# Gentle rolling terrain exists almost everywhere on land.
			inland_height += detail_value * 4.0

			# Regional highlands/plateaus occur at middle erosion levels.
			var plateau_factor: float = (
				_smoothstep(0.38, 0.62, e)
				* _smoothstep(0.02, 0.35, c)
			)
			inland_height += plateau_factor * 18.0

			# Mountains are driven by low erosion plus folded peak/valley
			# structure. The exponent keeps most mountain slopes moderate
			# while preserving rare dramatic summits.
			var peak_power: float = pow(pv, 1.55)
			var valley_power: float = pow(
				1.0 - pv,
				1.25
			)

			var mountain_relief: float = (
				28.0
				+ peak_power * 82.0
				- valley_power * 26.0
			)
			inland_height += (
				mountain_factor
				* mountain_relief
			)

			# Rare extreme summits can push the terrain toward the 256
			# generation ceiling without making normal mountains too tall.
			var extreme_peak_factor: float = (
				_smoothstep(0.72, 0.94, pv)
				* mountain_factor
				* _smoothstep(0.12, 0.55, c)
			)
			inland_height += extreme_peak_factor * 72.0

			# Folded low-PV regions form enclosed valleys/basins.
			var basin_factor: float = (
				_smoothstep(0.62, 0.92, 1.0 - pv)
				* mountain_factor
			)
			inland_height -= basin_factor * 10.0

			# -----------------------------------------------------------
			# RIVERS
			#
			# Treat the river field as a carving pass rather than a blue
			# line. This produces actual low terrain that can intersect the
			# water level, producing natural river valleys.
			# -----------------------------------------------------------

			var river_mask: float = 1.0 - _smoothstep(
				0.035,
				0.16,
				absf(river_value)
			)
			river_mask *= _smoothstep(
				-0.05,
				0.22,
				c
			)
			river_mask *= (
				0.45
				+ 0.55 * _smoothstep(
					0.0,
					0.75,
					e
				)
			)

			inland_height -= river_mask * 13.0

			# -----------------------------------------------------------
			# OCEAN / COAST
			# -----------------------------------------------------------

			var ocean_blend: float = 1.0 - _smoothstep(
				-0.46,
				-0.075,
				c
			)

			var deep_ocean_blend: float = 1.0 - _smoothstep(
				-0.72,
				-0.30,
				c
			)

			# A shallow continental shelf is around Y=36-44. As
			# continentalness decreases, it transitions into a deeper
			# ocean basin around Y=18-30.
			var shallow_floor: float = (
				37.0
				+ ocean_large * 6.0
				+ ocean_detail * 5.0
			)

			var deep_floor: float = (
				20.0
				+ ocean_large * 8.0
				+ ocean_detail * 5.0
			)

			var ocean_floor: float = lerpf(
				shallow_floor,
				deep_floor,
				deep_ocean_blend
			)

			# Underwater hills and ridges.
			ocean_floor += maxf(
				0.0,
				pv - 0.55
			) * 14.0

			# A few ocean shelves can rise into small islands, mostly
			# near the coastal edge rather than in the deepest oceans.
			var island_factor: float = (
				_smoothstep(-0.19, -0.035, c)
				* _smoothstep(0.72, 0.94, pv)
				* (1.0 - deep_ocean_blend)
			)
			ocean_floor += island_factor * 17.0

			ocean_floor = clampf(
				ocean_floor,
				12.0,
				float(SEA_LEVEL - 1)
			)

			# Coastlines are raised above the ocean floor but remain
			# lower/rounder than ordinary inland terrain.
			var coast_factor: float = 1.0 - absf(
				clampf(
					(c + 0.03) / 0.18,
					-1.0,
					1.0
				)
			)
			coast_factor = _smoothstep(
				0.0,
				1.0,
				coast_factor
			)

			var coast_height: float = (
				46.0
				+ detail_value * 3.0
				+ _smoothstep(0.35, 0.75, e) * 3.0
			)

			var mixed_height: float = lerpf(
				inland_height,
				ocean_floor,
				ocean_blend
			)

			mixed_height = lerpf(
				mixed_height,
				coast_height,
				coast_factor * (1.0 - ocean_blend)
			)

			var height: int = clampi(
				roundi(mixed_height),
				int(MIN_TERRAIN_HEIGHT),
				int(MAX_TERRAIN_HEIGHT)
			)

			heights[index] = height

	# ---------------------------------------------------------------
	# PASS 2: fill the voxel columns.
	#
	# This is intentionally column-first. We write only the required
	# vertical range instead of doing an expensive terrain/noise query
	# for every block position in the 16x16x256 volume.
	# ---------------------------------------------------------------

	for x in range(CHUNK_SIZE):
		for z in range(CHUNK_SIZE):
			var index: int = x + z * CHUNK_SIZE
			var height: int = heights[index]
			var c: float = continentalness_values[index]
			var mountain_factor: float = mountain_values[index]
			var beach_value: float = beach_noise.get_noise_2d(
				chunk_coordinate.x * CHUNK_SIZE + x,
				chunk_coordinate.y * CHUNK_SIZE + z
			)

			var underwater: bool = height <= SEA_LEVEL

			# Beaches appear mostly on relatively low, flat coastlines.
			# Mountainous coastlines remain rocky/cliffy instead.
			var beach_candidate: bool = (
				height <= SEA_LEVEL + 3
				and c > -0.17
				and c < 0.16
				and mountain_factor < 0.42
				and beach_value > -0.55
			)

			# River banks also get a small chance to expose sand.
			var river_bank: bool = (
				height <= SEA_LEVEL + 2
				and c > -0.02
				and beach_value > 0.30
			)

			var sand_surface: bool = (
				beach_candidate
				or river_bank
				or (
					underwater
					and (SEA_LEVEL - height) <= 6
				)
			)

			var surface_depth: int = _get_dirt_depth(
				chunk_coordinate.x * CHUNK_SIZE + x,
				chunk_coordinate.y * CHUNK_SIZE + z,
				world_seed
			)

			if sand_surface:
				surface_depth = 2 + posmod(
					absi(
						(chunk_coordinate.x * CHUNK_SIZE + x)
						* 19349663
						+ (chunk_coordinate.y * CHUNK_SIZE + z)
						* 83492791
						+ world_seed * 97531
					),
					2
				) + 1

			# Steep/high mountains expose stone instead of pretending
			# every summit is covered by grass.
			var rocky_surface: bool = (
				not underwater
				and mountain_factor > 0.68
				and height >= 105
			)

			var top_block: int = GRASS
			if sand_surface:
				top_block = SAND
			elif rocky_surface:
				top_block = STONE

			for y in range(height):
				var block_id: int = STONE

				if y == height - 1:
					block_id = top_block
				elif y >= height - surface_depth:
					if sand_surface:
						block_id = SAND
					else:
						block_id = DIRT

				blocks[_get_index(x, y, z)] = block_id

			# Global sea-level fill. There is no requirement for this to
			# be processed by the gameplay water simulation: generated
			# oceans are static source water until a player edits them.
			if underwater:
				for y in range(height, SEA_LEVEL + 1):
					blocks[_get_index(x, y, z)] = WATER

	return blocks
