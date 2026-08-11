extends SceneTree

## Checks that [member PlantSpecies.bare_share] means what it says.
##
## GroundCover gates every candidate on
## `randf() <= smoothstep(level, level + PATCH_EDGE, patch_noise)`. Smooth
## simplex spends almost none of its area near the ends of its nominal -1..1
## range — measured deviation 0.231, widest reading 0.80 over two hundred
## thousand samples — so a level read straight off that range is not a share of
## anything. Taking it literally cost the desert, ice and stone biomes every
## plant they had: "three quarters bare" was rejecting 99.6% of candidates.
##
## [method PlantSpecies.patch_level] inverts the measured curve instead. This
## run reports the share actually left bare against the share asked for; they
## should agree to about a point.
##
##     godot --headless --path . --script dev/_patch_probe.gd

const SAMPLES := 200000


func _initialize() -> void:
	for patch_size: float in [26.0, 52.0, 110.0]:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.seed = 20261601
		noise.frequency = 1.0 / patch_size
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345
		var readings := PackedFloat32Array()
		readings.resize(SAMPLES)
		for index in SAMPLES:
			readings[index] = noise.get_noise_3d(
				rng.randf_range(-4000.0, 4000.0),
				rng.randf_range(-4000.0, 4000.0),
				rng.randf_range(-4000.0, 4000.0))
		var total := 0.0
		var widest := 0.0
		for value in readings:
			total += value
			widest = maxf(widest, absf(value))
		var mean := total / float(SAMPLES)
		var spread := 0.0
		for value in readings:
			spread += (value - mean) * (value - mean)
		spread = sqrt(spread / float(SAMPLES))
		print("patch %.0f m  mean %+.3f  deviation %.3f  widest %.3f" % [
			patch_size, mean, spread, widest])
		var line := PackedStringArray()
		var worst := 0.0
		for share: float in [0.05, 0.2, 0.35, 0.5, 0.65, 0.8, 0.9]:
			var level := PlantSpecies.patch_level(share)
			var grown := 0.0
			for value in readings:
				grown += smoothstep(level, level + PlantSpecies.PATCH_EDGE,
					value)
			var bare := 1.0 - grown / float(SAMPLES)
			worst = maxf(worst, absf(bare - share))
			line.append("%.2f->%.2f" % [share, bare])
		print("   asked -> left bare:  %s   worst error %.3f" % [
			" ".join(line), worst])
	quit()
