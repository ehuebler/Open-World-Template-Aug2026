extends SceneTree

## Deterministic visual probe for the shared frontier between two maximum-reach
## cities. It uses the production claim flood and writes a top-down occupancy map:
## blue and amber are exclusively owned cells, charcoal is the neutral seam, and
## magenta would expose an overlap.
##
##     godot --headless --path . --script dev/_meep_claim_preview.gd

const WIDTH := 720
const HEIGHT := 480
const MAX_RADIUS := 185.0
const VIEW_MIN := Vector2(-100.0, -110.0)
const VIEW_MAX := Vector2(220.0, 110.0)
const OUTPUT := "res://dev/captures/meep_neighbor_claims.png"


func _initialize() -> void:
	call_deferred(&"_render")


func _render() -> void:
	var planet_radius := 1000.0
	var centre_a := Vector3.UP
	var site_a := MeepSite.new(centre_a, planet_radius, 0.0, 190.0)
	var centre_b := site_a.direction_at(Vector2(120.0, 0.0))
	var site_b := MeepSite.new(centre_b, planet_radius, 17.0, 190.0)
	var grid_a := _flat_grid(site_a)
	var grid_b := _flat_grid(site_b)
	var claim_a := MeepClaim.new()
	var claim_b := MeepClaim.new()
	claim_a.build(grid_a, Vector2.ZERO, MAX_RADIUS, false,
		PackedVector3Array([centre_b]), PackedByteArray([0]))
	claim_b.build(grid_b, Vector2.ZERO, MAX_RADIUS, false,
		PackedVector3Array([centre_a]), PackedByteArray([1]))

	var ownership := PackedByteArray()
	ownership.resize(WIDTH * HEIGHT)
	var overlap := 0
	var owned_a := 0
	var owned_b := 0
	for y in HEIGHT:
		var north := lerpf(VIEW_MAX.y, VIEW_MIN.y,
			float(y) / float(HEIGHT - 1))
		for x in WIDTH:
			var east := lerpf(VIEW_MIN.x, VIEW_MAX.x,
				float(x) / float(WIDTH - 1))
			var direction := site_a.direction_at(Vector2(east, north))
			var in_a := claim_a.contains(site_a.to_local(direction))
			var in_b := claim_b.contains(site_b.to_local(direction))
			var bits := (1 if in_a else 0) | (2 if in_b else 0)
			ownership[y * WIDTH + x] = bits
			if bits == 1:
				owned_a += 1
			elif bits == 2:
				owned_b += 1
			elif bits == 3:
				overlap += 1

	var image := Image.create(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8)
	for y in HEIGHT:
		for x in WIDTH:
			var at := y * WIDTH + x
			var bits := ownership[at]
			var colour := Color("111824")
			if bits == 1:
				colour = Color("2477d4")
			elif bits == 2:
				colour = Color("e28a2b")
			elif bits == 3:
				colour = Color("ff21d7")
			if bits != 0 and _is_edge(ownership, x, y):
				colour = colour.lightened(0.28)
			image.set_pixel(x, y, colour)
	_draw_marker(image, _pixel_of(Vector2.ZERO), Color.WHITE)
	_draw_marker(image, _pixel_of(site_a.to_local(centre_b)), Color.WHITE)

	var absolute := ProjectSettings.globalize_path(OUTPUT)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var saved := image.save_png(absolute)
	print("meep_claim_preview: %d blue, %d amber, %d overlap pixels -> %s"
		% [owned_a, owned_b, overlap, absolute])
	quit(0 if saved == OK and owned_a > 0 and owned_b > 0 and overlap == 0 else 1)


func _flat_grid(site: MeepSite) -> MeepGrid:
	var grid := MeepGrid.new(site, 192, MeepGrid.CELL)
	grid.terrain.fill(MeepGrid.Terrain.PASSABLE)
	grid.heights.fill(0.0)
	grid.surface_heights.fill(NAN)
	grid.flags.fill(MeepGrid.FLAG_NONE)
	grid.built = true
	grid.revision += 1
	return grid


func _is_edge(ownership: PackedByteArray, x: int, y: int) -> bool:
	var here := ownership[y * WIDTH + x]
	for step in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbour: Vector2i = Vector2i(x, y) + step
		if neighbour.x < 0 or neighbour.y < 0 \
				or neighbour.x >= WIDTH or neighbour.y >= HEIGHT:
			continue
		if ownership[neighbour.y * WIDTH + neighbour.x] != here:
			return true
	return false


func _pixel_of(local: Vector2) -> Vector2i:
	return Vector2i(
		roundi(remap(local.x, VIEW_MIN.x, VIEW_MAX.x, 0.0, WIDTH - 1.0)),
		roundi(remap(local.y, VIEW_MAX.y, VIEW_MIN.y, 0.0, HEIGHT - 1.0)))


func _draw_marker(image: Image, centre: Vector2i, colour: Color) -> void:
	for y in range(-6, 7):
		for x in range(-6, 7):
			var at := centre + Vector2i(x, y)
			if at.x < 0 or at.y < 0 or at.x >= WIDTH or at.y >= HEIGHT:
				continue
			var distance := Vector2(float(x), float(y)).length()
			if distance >= 3.0 and distance <= 6.0:
				image.set_pixelv(at, colour)
