# Planet Flora and Fauna Generation Plan

This is the durable content plan for populating the planet. It extends the
existing deterministic `PlantSpecies` / `GroundCover`, sparse-tree, VAT fish,
night-emission, pooled-light, and terrain-classification systems rather than
placing individual scene nodes.

## Population families

1. **Underwater:** coral, kelp, sea fans, seaweed and sea grass.
2. **Grasses:** turf plus visibly different blade, fan and feather grasses.
3. **Shrubs and bushes:** broadleaf, heather-like and dry/silver scrub. These
   never receive collision.
4. **Trees:** flower trees plus canopy, spiral/conifer-like, umbrella,
   skyneedle-grove, closed-cloud-canopy, corkscrew, solitary orb-giant and
   desert tree silhouettes.
5. **Mushrooms:** small clusters, luminous lantern mushrooms and sparse
   tree-sized mushrooms.
6. **Geology:** weathered, rounded and layered boulders; true hex-column lava
   formations; emerald, amethyst and sky crystals; rune/tattoo stones; and
   ice-only glacier shards. Authored meshes scale from hand-sized outcrops to
   roughly 200 m skyscraper formations.
7. **Desert plants:** barrel and branching cactus, succulents, dry scrub and
   Joshua trees.
8. **Moving life:** multiple fish schools plus fireflies, moths and future bug
   swarms.

Every family has multiple deterministic variants. Variation can come from mesh
silhouette, proportions, vertex colour, regional tint, scale, lean, movement,
patch shape and night behaviour. Night behaviours include steady emission,
asynchronous breathing, twinkling, colour-shifted pulses and non-emissive
silhouettes mixed among luminous populations.

## Authoring model

- `blender_assets/source/build_biome_assets.py` is the reusable recipe-driven
  Blender factory for static population meshes. Recipes use curved tapered
  lofts, branching, phyllotaxis, layered leaves/petals and displaced hulls;
  exported meshes must not be primitive stacks.
- Models are rooted at the ground, carry `COLOR_0`, contain no runtime rig, and
  meet category-specific triangle budgets. Animation at population scale stays
  in the plant shader or VAT.
- Every generated variant carries `TEXCOORD_0` and a deterministic external
  `biome_paint/<name>_paint.png`. The manifest records its paint path and style,
  and its `PlantSpecies` resource must bind that PNG at runtime.
- A generated manifest records category, authored height, triangles, collision
  hint and suggested light treatment. New variants should normally be another
  recipe entry, not another one-off build script.
- Large hero assets may still be hand-authored, but must export through the same
  cleanup, origin, colour and validation contract.

## Runtime model

- Dense and medium populations use streamed `GroundCover` tiles and one
  `MultiMesh` per species/tile. Nothing becomes a node per plant.
- `PlantSpecies` owns habitat, scale, density, collision, LOD, glow and seed.
  Terrain material claims, aridity, frost, elevation, slope and steadiness are
  all checked before an instance is accepted.
- Shrubs, grass, small mushrooms, seaweed and small stones have no collision.
  Trunked trees, giant mushrooms, stout cactus, large rocks, crystal spires and
  glacier shards use streamed primitive collision only near the viewer.
- Monumental geology uses the same deterministic `GroundCover` model but
  re-surveys every member of a broad clump. A skyscraper rock therefore proves
  its own biome, slope and footing, while still appearing primarily in
  multi-member boulder, citadel, crystal and monolith sites.
- Moving life uses bounded `MultiMesh` clusters. Body/wing motion and emission
  are GPU-driven; closed-form cluster movement and player avoidance have capped
  CPU buffer updates.
- Emissive species also offer candidates to bounded local-light pools so glow
  reaches terrain, players and props. Light count never scales with instance
  count.

## Biome allocation

Terrain colour/material claims are the primary biome boundary. Aridity, frost,
height and slope make that boundary stricter and preserve deliberate barren
land.

| Biome | Main populations | Deliberately sparse or absent |
| --- | --- | --- |
| Reef shelf, -34 to -5 m | coral, sea fan, kelp, bulb seaweed, reef fish | deep trenches and steep underwater walls |
| Wet/mesic grassland | mixed grasses, shrubs, mushrooms, canopy and umbrella trees, rounded boulders, emerald crystals, fireflies | sharp ridges |
| Humid cloudbough forest | broadleaf shrubs, lantern mushrooms, canopy and overlapping cloudbough trees | dry benches and exposed uplands |
| Cool skywood grove | close clusters of very tall skyneedles, spiral trees, silver shrubs and feather grass | warm lowlands and steep ridges |
| Warm corkscrew savanna | corkscrew and umbrella trees, fan grass, heather and dry-edge scrub | wet lowlands and frost country |
| Ancient giant clearing | one rare orb-giant over mixed grass, mushrooms, stones and occasional shrubs | dense same-species forest |
| Upland/cool grass | feather grass, silver shrubs, spiral trees, mushrooms | high cliffs and snowfields |
| Mountain stone | weathered and layered rocks, rounded boulder falls, crystals and rare basalt citadels | steep faces, major summits and gullies |
| Polar ice | glacier shards, dark erratics, rare crystal spires and colossal boulder sites | broad areas of clean ice remain open |
| Desert floor/bench | cactus, dry shrubs, Joshua trees, rounded/layered boulders, hex lava fields, rune stones and moths | dune fields and large mesa/mountain zones remain barren |
| Colony meadow | dense grass, purple flowers, flower trees and mixed insects | ship clearance remains open |

No family is allowed everywhere. Species use independent patch seeds and
different patch scales, producing overlaps, transitions and clearings rather
than eight uniform planet-wide carpets.

## Initial variant library

- Underwater: `kelp_ribbon`, `sea_fan`, `bulb_seaweed`, four existing corals.
- Grass: existing VAT turf, `grass_feather`, `grass_fan`.
- Shrubs: `shrub_broadleaf`, `shrub_heather`, `shrub_silver`.
- Trees: existing flower tree, `tree_canopy`, `tree_spiral`,
  `tree_umbrella`, `tree_skyneedle`, `tree_cloudbough`,
  `tree_corkscrew`, `tree_orb_giant`, `joshua_tree`.
- Mushrooms: `mushroom_cluster`, `mushroom_lantern`, `mushroom_giant`.
- Geology: `rock_weathered`, `rock_basalt`, `glacier_shard`,
  `boulder_round`, `boulder_layered`, `boulder_colossus`,
  `basalt_hex_field`, `basalt_citadel`, `crystal_emerald`,
  `crystal_amethyst`, `crystal_spire`, `rune_boulder` and
  `rune_monolith`.
- Desert: `cactus_barrel`, `cactus_branching`, `joshua_tree` and silver scrub.
- Moving: existing large and reef fish, `firefly_lantern`, `moth_glimmer`.

## Quality and performance rules

1. Keep terrain and habitat CPU/GPU rules in agreement.
2. Preserve barren mountain, desert and polar compositions; density is not a
   substitute for variety.
3. Prefer silhouette, branching and colour variation over large texture memory.
4. Small animated geometry does not cast directional shadows at distance.
5. Use near/far topology or aggressive instance thinning before increasing a
   global radius.
6. Keep collision and real lights pooled/streamed and close to the viewer.
7. Deterministic seeds are content: adding a visual effect must not move an
   established population.
8. Validate GLB colour/origin/triangle contracts, Godot imports, runtime parser
   errors, representative biome counts and bounded light/pose budgets after
   every library expansion.
