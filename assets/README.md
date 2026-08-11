# Asset pipeline

`assets/` separates editable inputs from files Godot loads at runtime. Do not
put runtime resources under `source/` or `work/`; both are hidden from Godot by
`.gdignore`.

## Layout

- `source/blender/` contains Blender Python recipes, shared helpers, the authored
  astronaut `.blend`, and title-art source.
- `source/meshmaker/` contains read-only MeshMaker `.blend` inputs. Builders may
  open them but must never save over them.
- `source/texture_inputs/` contains source sheets used to bake terrain textures.
- `runtime/characters/`, `runtime/apparel/`, `runtime/items/` and
  `runtime/environment/` contain directly loaded models and character textures.
- `runtime/biomes/models/` and `runtime/biomes/paint/` contain the model/PNG
  pairs used by `PlantSpecies`.
- `runtime/biomes/manifests/` records provenance, authored size, triangle
  budgets, collision hints, color-paint paths and paint styles.
- `runtime/vat/` keeps each VAT mesh, EXR and JSON bundle together.
- `runtime/materials/meshmaker/` contains the external materials used by direct
  MeshMaker scenery imports.
- `work/` contains regenerable intermediate `.blend` files.
- `previews/` contains regenerable authoring and biome renders. It is ignored by
  Git and is not a runtime asset source.

## Regeneration

Run commands from the repository root with Blender 5.1:

```powershell
$blender = "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"

# Characters and apparel
& $blender --background --factory-startup --python assets/source/blender/build_character.py
& $blender --background --python assets/source/blender/build_character_3.py
& $blender --background assets/source/blender/player_character.blend --python assets/source/blender/build_apparel.py

# Procedural biome library and Godot catalogue
& $blender --background --factory-startup --python assets/source/blender/build_biome_assets.py
& $blender --background --factory-startup --python assets/source/blender/build_flower_tree.py
& $blender --background --factory-startup --python assets/source/blender/build_biome_catalog.py

# MeshMaker processing
& $blender --background --factory-startup --python assets/source/blender/build_landing.py
& $blender --background --factory-startup --python assets/source/blender/build_reef_assets.py
& $blender --background --factory-startup --python assets/source/blender/build_vat_assets.py

# Terrain texture arrays and title art
& $blender --background --factory-startup --python assets/source/blender/build_ground_textures.py
& $blender --background --factory-startup --python assets/source/blender/build_title_art.py
```

The catalogue builder can also run with a normal Python interpreter because it
does not import `bpy`.

## Flora and fauna contract

Population assets are deterministic recipes rather than individually placed
scene nodes. Dense and medium populations use streamed `GroundCover` tiles and
one `MultiMesh` per species/tile; moving life uses bounded MultiMesh clusters
with shader or VAT motion.

Every flora, fungus, coral, geological growth and small-creature variant must:

1. Export a grounded, gameplay-ready GLB with `TEXCOORD_0` UVs and retained
   `COLOR_0` semantic data.
2. Have a deterministic external PNG under `runtime/biomes/paint/`.
3. Record that PNG and its species-appropriate paint style in the manifest.
4. Bind the PNG through its `PlantSpecies` resource and runtime material.
5. Preserve biome tint, night-emission masks, VAT data, collision hints and
   MultiMesh batching.

Paint patterns must be broad and mip-safe: bark bands and knots, leaf veins and
margins, petal markings, mushroom spots and gills, grass streaks, coral
striations, cactus ribs and areoles, rock strata and lichen, or creature
markings. Avoid single-pixel noise and thin high-contrast lines that shimmer at
gameplay distance.

Species remain biome-specific. Habitat checks combine terrain material claims,
aridity, frost, elevation, slope and steadiness. Shrubs, grass, small mushrooms,
seaweed and small stones do not collide; trunked trees, giant mushrooms, stout
cacti, large rocks, crystal spires and glacier shards use streamed primitive
collision near the viewer. Emissive species submit candidates to bounded local
light pools rather than creating one light per instance.

After changing a recipe, validate the GLB/PNG/manifest contract, Godot imports,
representative biome counts, and both a close preview and a normal
gameplay-distance view.
