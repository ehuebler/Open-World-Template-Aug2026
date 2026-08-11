class_name GlobalFloraGlow
extends Node

## Planet-wide aerial stand-in for luminous streamed populations.
##
## Localized colony flora can replay every accepted instance into a tangent
## mask. A global field cannot do that literally: even a modest tile size means
## millions of tiles over six cube faces. This instead evaluates the same
## habitat, material-claim and seeded patch rules at every texel of a
## planet-wide equirectangular atlas. At orbital scale a texel represents a
## density, not an individual plant, so this is the exact useful level of the
## generation law: reefs follow the shelf, cactus follows arid sand, ice flora
## follows frost, and every seeded clearing remains a clearing.
##
## Two RGB atlases preserve both colour and the established altitude laws:
## undergrowth fades in from 40 m, canopy from 80 m. They are built once on a
## worker; only two mipmapped textures survive.

## Temporary master switch for the planet-wide aerial stand-in. Ground-level
## plant emission and local OmniLights are separate and remain active.
@export var enabled := false
@export_range(128, 1024, 128) var atlas_width := 256
@export_range(64, 512, 64) var atlas_height := 128
@export var understory_energy := 0.23
@export var canopy_energy := 0.2
@export var canopy_from_height := 3.0
## Terrain chunks and the plants underfoot are the startup-critical worker
## jobs. The orbital atlas can arrive later, so it deliberately gives them the
## pool first instead of making the initial descent wait behind it.
@export var warmup_seconds := 2.5

var _planet: Planet
var _shape: PlanetShape
var _spacing := 1.0
var _task := -1
var _understory_image: Image
var _canopy_image: Image
var _understory_texture: ImageTexture
var _canopy_texture: ImageTexture
var _entry_count := 0
var _started := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_clear_surface()
	set_process(false)
	if not enabled:
		return
	call_deferred("_warmup")


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_clear_surface()


func _warmup() -> void:
	if warmup_seconds > 0.0:
		await get_tree().create_timer(warmup_seconds).timeout
	if is_inside_tree():
		_begin()


func _begin() -> void:
	if not enabled:
		return
	_started = true
	_planet = _planet_ancestor()
	if _planet == null or _planet.shape == null:
		push_warning("GlobalFloraGlow needs a Planet ancestor")
		return
	_shape = _planet.shape
	_shape.prepare()
	_spacing = _planet.finest_spacing()
	var entries := _luminous_species()
	_entry_count = entries.size()
	if entries.is_empty():
		return
	_task = WorkerThreadPool.add_task(_build.bind(entries))
	set_process(true)


func _process(_delta: float) -> void:
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if _understory_image == null or _canopy_image == null:
		push_warning("GlobalFloraGlow produced no atlas")
		set_process(false)
		return
	_understory_texture = ImageTexture.create_from_image(_understory_image)
	_canopy_texture = ImageTexture.create_from_image(_canopy_image)
	_understory_image = null
	_canopy_image = null
	var surface := Planet.SURFACE_MATERIAL
	surface.set_shader_parameter(&"global_flora_understory_glow_mask",
		_understory_texture)
	surface.set_shader_parameter(&"global_flora_canopy_glow_mask",
		_canopy_texture)
	surface.set_shader_parameter(&"global_flora_understory_glow_energy",
		understory_energy)
	surface.set_shader_parameter(&"global_flora_canopy_glow_energy",
		canopy_energy)
	set_process(false)


func ready_for_orbit() -> bool:
	if not enabled:
		return true
	return _started and _task < 0 \
		and (_entry_count == 0 or _understory_texture != null)


func luminous_species_count() -> int:
	return _entry_count


func _clear_surface() -> void:
	var surface := Planet.SURFACE_MATERIAL
	if surface == null:
		return
	surface.set_shader_parameter(&"global_flora_understory_glow_mask", null)
	surface.set_shader_parameter(&"global_flora_canopy_glow_mask", null)
	surface.set_shader_parameter(&"global_flora_understory_glow_energy", 0.0)
	surface.set_shader_parameter(&"global_flora_canopy_glow_energy", 0.0)


func _planet_ancestor() -> Planet:
	var node := get_parent()
	while node != null:
		if node is Planet:
			return node as Planet
		node = node.get_parent()
	return null


## Copies only immutable Resource data into the worker payload. Near/far copies
## of one population (the two grass horizons) have the same deterministic seed
## and habitat and are deliberately deduplicated.
func _luminous_species() -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var seen := {}
	for node in _planet.find_children("*", "Node", true, false):
		var field := node as GroundCover
		if field == null or not field.global_cover:
			continue
		for entry in field.species:
			var plant := entry as PlantSpecies
			if plant == null:
				continue
			var night_energy := 0.0
			if plant.material != null:
				var authored = plant.material.get_shader_parameter(
					&"night_emission_energy")
				if authored != null:
					night_energy = float(authored)
			if plant.glowing_patches <= 0.0 and night_energy <= 0.0:
				continue
			var key := "%d:%d:%d:%.2f:%.2f" % [
				plant.random_seed, plant.glow_seed, plant.ground_layer,
				plant.above_water, plant.below]
			if seen.has(key):
				continue
			seen[key] = true
			var colour := plant.local_light_color
			if colour.a <= 0.0:
				# Existing region-lit grass predates species light colours.
				# Violet-blue is its authored glow family; its local shader
				# still applies the exact region wheel at ground range.
				colour = Color(0.24, 0.08, 0.58, 1.0)
			found.append({
				"plant": plant,
				"colour": colour,
				"night": night_energy > 0.0,
				"keep_out": field.get("_keep_out") as Vector3,
				"keep_cos": float(field.get("_keep_cos")),
				"keep_edge": float(field.get("_keep_edge")),
			})
	return found


func _build(entries: Array[Dictionary]) -> void:
	var width := atlas_width
	var height := atlas_height
	var under := Image.create_empty(width, height, false, Image.FORMAT_RGBH)
	var canopy := Image.create_empty(width, height, false, Image.FORMAT_RGBH)
	under.fill(Color.BLACK)
	canopy.fill(Color.BLACK)

	# Noise objects are local to this task. Sharing GroundCover's instances would
	# save a handful of allocations once and couple two worker jobs forever.
	var prepared: Array[Dictionary] = []
	for entry in entries:
		var plant := entry["plant"] as PlantSpecies
		var patch := FastNoiseLite.new()
		patch.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		patch.seed = plant.random_seed
		patch.frequency = 1.0 / maxf(plant.patch_size, 1.0)
		var glow := FastNoiseLite.new()
		glow.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		glow.seed = plant.glow_seed
		glow.frequency = 1.0 / maxf(plant.glow_patch_size, 1.0)
		var copy := entry.duplicate()
		copy["patch"] = patch
		copy["glow"] = glow
		prepared.append(copy)

	for y in height:
		var latitude := (0.5 - (float(y) + 0.5) / float(height)) * PI
		var ring := cos(latitude)
		for x in width:
			var longitude := ((float(x) + 0.5) / float(width) - 0.5) * TAU
			var direction := Vector3(
				sin(longitude) * ring,
				sin(latitude),
				cos(longitude) * ring)
			var under_rgb := Vector3.ZERO
			var canopy_rgb := Vector3.ZERO
			for entry in prepared:
				var plant := entry["plant"] as PlantSpecies
				var here := direction * _shape.radius
				var bare := PlantSpecies.patch_level(plant.bare_share)
				var patch := entry["patch"] as FastNoiseLite
				var level := smoothstep(bare, bare + PlantSpecies.PATCH_EDGE,
					patch.get_noise_3d(here.x, here.y, here.z))
				if level <= 0.001:
					continue
				var keep_out: Vector3 = entry["keep_out"]
				if keep_out != Vector3.ZERO:
					level *= 1.0 - smoothstep(
						float(entry["keep_edge"]),
						float(entry["keep_cos"]),
						direction.dot(keep_out))
				if not bool(entry["night"]):
					var threshold := lerpf(
						0.62, -0.62, plant.glowing_patches)
					var glow := entry["glow"] as FastNoiseLite
					level *= smoothstep(threshold - 0.12, threshold + 0.12,
						glow.get_noise_3d(here.x, here.y, here.z))
				if level <= 0.001 or not _habitat(plant, direction):
					continue
				var density_scale := 4.0 if plant.height < canopy_from_height \
					else 1800.0
				level *= 1.0 - exp(
					-plant.per_square_metre * density_scale)
				level *= plant.local_light_energy
				var colour: Color = entry["colour"]
				var light := Vector3(colour.r, colour.g, colour.b) * level
				if plant.height < canopy_from_height:
					under_rgb += light
				else:
					canopy_rgb += light
			under.set_pixel(x, y, Color(
				minf(under_rgb.x, 1.0),
				minf(under_rgb.y, 1.0),
				minf(under_rgb.z, 1.0), 1.0))
			canopy.set_pixel(x, y, Color(
				minf(canopy_rgb.x, 1.0),
				minf(canopy_rgb.y, 1.0),
				minf(canopy_rgb.z, 1.0), 1.0))
	under.generate_mipmaps()
	canopy.generate_mipmaps()
	_understory_image = under
	_canopy_image = canopy


## CPU twin of GroundCover._growth. Kept explicit so the atlas remains safe on
## a worker and so a change to habitat rules has an obvious second call site.
func _habitat(plant: PlantSpecies, at: Vector3) -> bool:
	var here := _shape.elevation(at, _spacing)
	if here < plant.above_water or here > plant.below:
		return false
	var sample := _shape.sample(at)
	if float(sample["river"]) > 0.0 or float(sample["lake"]) > 0.0:
		return false
	var arid := float(sample.get("arid", 0.0))
	var frozen := _shape.frost(at)
	if arid < plant.minimum_arid or arid > plant.maximum_arid \
			or frozen < plant.minimum_frost or frozen > plant.maximum_frost:
		return false
	var east := at.cross(
		Vector3.UP if absf(at.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := at.cross(east)
	var step := plant.steady_over / _shape.radius
	var behind := _shape.elevation((at - east * step).normalized(), _spacing)
	var ahead := _shape.elevation((at + east * step).normalized(), _spacing)
	var left := _shape.elevation((at - north * step).normalized(), _spacing)
	var right := _shape.elevation((at + north * step).normalized(), _spacing)
	for near: float in [behind, ahead, left, right]:
		if near < plant.above_water or absf(near - here) > plant.steady_within:
			return false
	var gradient := Vector2(ahead - behind, right - left) \
		/ (plant.steady_over * 2.0)
	if gradient.length() > tan(deg_to_rad(plant.max_slope)):
		return false
	if plant.ground_layer == PlantSpecies.Ground.ANYWHERE:
		return true
	var normal := (at - east * gradient.x - north * gradient.y).normalized()
	var biome := _shape.color_at(at, here, normal)
	return _terrain_claims(at, here, normal, biome,
		plant.ground_layer, plant.minimum_claim)


func _terrain_claims(at: Vector3, height: float, normal: Vector3,
		biome: Color, layer: PlantSpecies.Ground, minimum: float) -> bool:
	var brightest := maxf(maxf(biome.r, biome.g), biome.b)
	var darkest := minf(minf(biome.r, biome.g), biome.b)
	var chroma := brightest - darkest
	var green := clampf(
		(biome.g - maxf(biome.r, biome.b)) * 7.0, 0.0, 1.0)
	var red := clampf(
		(biome.r - maxf(biome.g, biome.b)) * 7.0, 0.0, 1.0)
	var grey := 1.0 - clampf(chroma * 7.0, 0.0, 1.0)
	var cool := clampf((biome.b - biome.r) * 7.0, 0.0, 1.0)
	var pale := maxf(grey, cool) \
		* clampf((brightest - 0.7) * 7.0, 0.0, 1.0)
	var frozen := _shape.frost(at)
	var shore := 1.0 - smoothstep(0.0, 7.0, height)
	var ice := maxf(pale, frozen * 1.3)
	var sand := (red + shore) * (1.0 - minf(ice, 1.0))
	var slope := 1.0 - clampf(normal.dot(at), 0.0, 1.0)
	var cliff := smoothstep(0.22, 0.55, slope)
	var stone := maxf(grey - pale, 0.0) + cliff * 1.1
	var grass := maxf(green, 0.3 - maxf(maxf(sand, stone), ice))
	var scores := [grass, sand, stone, ice]
	var mine: float = scores[layer - 1]
	if mine < minimum:
		return false
	var ahead := 0
	for index in scores.size():
		if index != layer - 1 and float(scores[index]) > mine:
			ahead += 1
	return ahead <= 1
