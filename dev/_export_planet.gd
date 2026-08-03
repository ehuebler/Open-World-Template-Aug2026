extends SceneTree

## Bakes the planet into a single mesh and writes it out as a .glb, so the
## terrain can be taken into Blender and painted on.
##
##     & $godot --headless --path . --script dev/_export_planet.gd
##     & $godot --headless --path . --script dev/_export_planet.gd -- --faces=512
##
## There is no mesh in the game to export. The planet is a height field, and the
## quadtree only ever builds the few hundred chunks near the camera, each at
## whatever resolution its distance earns — so at any moment most of the world
## does not exist as geometry and the part that does is a patchwork of six
## different densities. This samples the same field on a uniform grid over the
## same cube-sphere instead, which gives one mesh of one density, the same one
## every time it is run.
##
## The height field comes off the [Planet] in `game/world.tscn` rather than from
## a fresh [PlanetShape], so a bake is always of the planet in the game and not
## of the defaults it happened to start from.
##
## The biome colours ride along as a colour attribute, so there is something to
## paint over rather than a grey ball. Blender wires that into base colour on
## import; **Godot does not** — its own glTF importer leaves
## `vertex_color_use_as_albedo` off, and a bake read back into Godot arrives
## white until that is switched on. The colours are in the file either way.
##
## Flags, all optional:
##
## [codeblock]
## --faces=N     vertices along one cube-face edge; 256 by default. Cost is
##               6N^2 triangles and roughly (pi/2 * radius / N) metres between
##               vertices, so 256 is 786k triangles at about 49 m.
## --out=PATH    where to write, res:// or absolute.
## --scale=S     multiplies every coordinate. 1 keeps real metres.
## --no-sea      leave out the sea-level shell.
## [/codeblock]

const WORLD := "res://game/world.tscn"
const DEFAULT_OUT := "res://dev/exports/planet.glb"
const DEFAULT_FACES := 256

## The six faces are laid out three across and two down in one square of UV
## space, so the whole planet paints into a single texture. Face f takes column
## f % 3 of row f / 3, in the order of [constant Planet.FACES].
const ATLAS_COLUMNS := 3
const ATLAS_ROWS := 2

## Fraction of a cell left unpainted around its edge. Texture filtering and any
## bake with a dilation pass both reach past the edge of an island, and without
## a gutter what they reach into is the neighbouring face.
const GUTTER := 0.003

## Vertices along a sea shell's face edge, as a fraction of the terrain's. The
## shell is a sphere: it needs enough triangles not to cut visible corners off
## the coastline and no more.
const SEA_SHARE := 0.25
const SEA_FLOOR := 32

## What the sea shell is coloured, so it reads as water in a viewport that is
## showing vertex colours. Its alpha marks it as fully wet, the same signal the
## terrain's vertex alpha carries.
const SEA_COLOR := Color(0.04, 0.20, 0.46, 1.0)


func _initialize() -> void:
	var args := _flags()
	var resolution := maxi(int(args.get("faces", DEFAULT_FACES)), 4)
	var scale := maxf(float(args.get("scale", 1.0)), 0.0001)
	var out := String(args.get("out", DEFAULT_OUT))

	var shape := _shape()
	if shape == null:
		quit(1)
		return
	# On this thread and before anything samples: the field builds its noise and
	# solves the shoreline bias here, and elevation() is only safe afterwards.
	shape.prepare()

	# Band-limited to the grid it is being sampled on, the way a chunk is to its
	# own. Sampling the true field at 49 m would alias every ridge in the world.
	var spacing := PI * 0.5 * shape.radius / float(resolution)
	print("export_planet: radius %.0f m, %d per face edge, %.1f m between vertices"
		% [shape.radius, resolution, spacing])

	var root := Node3D.new()
	root.name = "PlanetBake"
	get_root().add_child(root)

	var started := Time.get_ticks_msec()
	root.add_child(_terrain(shape, resolution, spacing, scale))
	if not args.has("no-sea"):
		root.add_child(_sea(shape, maxi(int(resolution * SEA_SHARE), SEA_FLOOR), scale))
	print("export_planet: sampled in %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))

	if not _write(root, out, scale):
		quit(1)
		return
	quit()


## The height field the game is actually using. Instantiating the world does not
## start the quadtree — that waits for [method Node._ready], which wants a tree —
## so this costs the scene's resources and nothing else.
func _shape() -> PlanetShape:
	var scene := load(WORLD) as PackedScene
	if scene == null:
		push_error("export_planet: cannot load %s" % WORLD)
		return null
	var world := scene.instantiate()
	var planet := world.find_child("Planet", true, false) as Planet
	var shape: PlanetShape = planet.shape if planet != null else null
	if shape == null:
		push_error("export_planet: no Planet with a shape in %s" % WORLD)
		world.free()
		return null
	# The resource outlives the scene it was reached through.
	world.free()
	return shape


func _terrain(shape: PlanetShape, resolution: int, spacing: float, scale: float) -> MeshInstance3D:
	var side := resolution + 1
	var per_face := side * side
	var count := per_face * Planet.FACES.size()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	uvs.resize(count)

	var lowest := INF
	var highest := -INF
	for face in Planet.FACES.size():
		for row in side:
			var v := float(row) / float(resolution)
			for col in side:
				var u := float(col) / float(resolution)
				var direction := _direction(face, u, v)
				var height := shape.elevation(direction, spacing)
				var normal := shape.normal_at(direction, spacing)
				var index := face * per_face + row * side + col
				vertices[index] = direction * ((shape.radius + height) * scale)
				normals[index] = normal
				colors[index] = shape.color_at(direction, height, normal)
				uvs[index] = _atlas(face, u, v)
				lowest = minf(lowest, height)
				highest = maxf(highest, height)
		print("export_planet: face %d of %d" % [face + 1, Planet.FACES.size()])

	print("export_planet: elevation %.0f m .. %.0f m" % [lowest, highest])
	return _instance("Terrain", vertices, normals, colors, uvs,
		_grid_indices(resolution, Planet.FACES.size()))


## A sphere at sea level, as its own object so it can be switched off. It is
## worth having: on a bake of the bare ground every coastline in the world is
## invisible, because what marks one is the height the water comes up to and not
## anything about the shape of the land.
func _sea(shape: PlanetShape, resolution: int, scale: float) -> MeshInstance3D:
	var side := resolution + 1
	var per_face := side * side
	var count := per_face * Planet.FACES.size()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	vertices.resize(count)
	normals.resize(count)
	colors.resize(count)
	uvs.resize(count)

	for face in Planet.FACES.size():
		for row in side:
			var v := float(row) / float(resolution)
			for col in side:
				var u := float(col) / float(resolution)
				var direction := _direction(face, u, v)
				var index := face * per_face + row * side + col
				vertices[index] = direction * (shape.radius * scale)
				normals[index] = direction
				colors[index] = SEA_COLOR
				uvs[index] = _atlas(face, u, v)

	return _instance("Sea", vertices, normals, colors, uvs,
		_grid_indices(resolution, Planet.FACES.size()))


## The unit direction at a point on a cube face, in the face's own [0, 1]
## coordinates. The same mapping [Planet] builds its chunks on, including the
## tangent spread that keeps quads near a face's corners the same size as the
## ones in its middle — a bake on the raw cube would have a third more vertices
## per square kilometre at the corners than at the centres.
func _direction(face: int, u: float, v: float) -> Vector3:
	var axes: Array = Planet.FACES[face]
	return ((axes[0] as Vector3)
		+ (axes[1] as Vector3) * _spread(u * 2.0 - 1.0)
		+ (axes[2] as Vector3) * _spread(v * 2.0 - 1.0)).normalized()


## Mirrors `Planet._spread`, and has to keep mirroring it: a bake mapped
## differently from the game cannot be painted and brought back.
func _spread(coordinate: float) -> float:
	return tan(coordinate * PI * 0.25)


## Where a point on a face lands in the shared texture.
func _atlas(face: int, u: float, v: float) -> Vector2:
	var column := face % ATLAS_COLUMNS
	var row := face / ATLAS_COLUMNS
	var span := 1.0 - GUTTER * 2.0
	return Vector2(
		(float(column) + GUTTER + u * span) / float(ATLAS_COLUMNS),
		(float(row) + GUTTER + v * span) / float(ATLAS_ROWS))


## Triangles for [param faces] separate grids laid end to end in one vertex
## array. Wound the way [Planet] winds its chunks, which is clockwise seen from
## outside the planet.
func _grid_indices(resolution: int, faces: int) -> PackedInt32Array:
	var side := resolution + 1
	var per_face := side * side
	var indices := PackedInt32Array()
	indices.resize(resolution * resolution * 6 * faces)
	var write := 0
	for face in faces:
		var base := face * per_face
		for row in resolution:
			for col in resolution:
				var corner := base + row * side + col
				indices[write] = corner
				indices[write + 1] = corner + side
				indices[write + 2] = corner + 1
				indices[write + 3] = corner + 1
				indices[write + 4] = corner + side
				indices[write + 5] = corner + side + 1
				write += 6
	return indices


func _instance(node_name: String, vertices: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, uvs: PackedVector2Array,
		indices: PackedInt32Array) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# A plain material, not the game's: the pencil-and-vivid shaders mean nothing
	# to glTF and would arrive in Blender as a grey lump. This one asks for the
	# vertex colours to be shown, which is what makes the biomes visible to paint
	# over.
	var material := StandardMaterial3D.new()
	material.resource_name = node_name
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	mesh.surface_set_material(0, material)

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	print("export_planet: %s, %d vertices, %d triangles"
		% [node_name, vertices.size(), indices.size() / 3])
	return instance


func _write(root: Node3D, out: String, scale: float) -> bool:
	var path := ProjectSettings.globalize_path(out) if out.begins_with("res://") else out
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_scene(root, state)
	if error != OK:
		push_error("export_planet: cannot read the scene, error %d" % error)
		return false
	error = document.write_to_filesystem(state, path)
	if error != OK:
		push_error("export_planet: cannot write %s, error %d" % [path, error])
		return false

	var size := 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		size = file.get_length()
		file.close()
	print("export_planet: wrote %s (%.1f MB)" % [path, size / 1048576.0])
	if is_equal_approx(scale, 1.0):
		# Sixteen kilometres across, and Blender's viewport stops drawing at one.
		print("export_planet: it is 16 km wide — set View > Clip Start 1 m, End 100 km,")
		print("export_planet: or re-run with --scale=0.001 to get it in kilometres")
	return true


## `--name=value` and bare `--name` from everything after the `--`.
func _flags() -> Dictionary:
	var found := {}
	for argument in OS.get_cmdline_user_args():
		var text := argument.lstrip("-")
		var split := text.find("=")
		if split < 0:
			found[text] = true
		else:
			found[text.left(split)] = text.substr(split + 1)
	return found
