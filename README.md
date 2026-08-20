# Godot Co-op Template

A reusable Godot 4.7 starter for offline play and Steam player-hosted online co-op. It includes a responsive colored-pencil menu, persistent settings, Steam lobby discovery and friend invites, relay-backed multiplayer, a networked test world, an animated first/third person character controller, inventory-based apparel and weapons, and text and push-to-talk voice chat.

This file explains how each system works and why. Asset provenance, regeneration commands and runtime contracts are documented in `assets/README.md`.

## Run it

Open `project.godot` in Godot 4.7 and press **F6/F5**.

- **Start Game** launches the world with an offline multiplayer peer.
- **Online > Create Lobby** creates a public, friends-only, or password-protected Steam lobby, then opens its waiting room.
- **Online > Join Lobby** searches Steam sessions by name and game mode. Steam friend invites enter through the same screen; no IP address is exposed.
- Press **Escape** in the world to resume or leave.

Controls:

| Input | Action |
| --- | --- |
| WASD, mouse | Move and look |
| Space | Jump, with coyote time and input buffering. Pressed again in clear air, take off and fly |
| Shift | Sprint, or boost a flight to over 200 m/s |
| Ctrl | Crouch, or slide when held while already moving. Brake, while flying |
| C | Cycle first person, third person close, third person far |
| Q | Swap the camera to the other shoulder |
| E | Use whatever the crosshair is on, within arm's reach |
| Tab | Open your inventory, from anywhere |
| 1 - 5, wheel | Draw a weapon. Numbers reach any slot, the wheel only stops on filled ones |
| Left click | Swing the sword, or fire the carbine |
| Right click, held | Sight down the carbine's optic |
| Enter | Type a line of chat; Enter again sends it, Escape throws it away |
| V, held | Talk to everyone in the session |
| Escape | Pause |

While flying, the mouse is the steering: hold forward and you go wherever you are looking, including straight down. There is no cancel key: ground ends a flight, while entering the sea hands it directly to swimming and carries 85% of the arrival speed into the water. The separate two-press launch from swimming remains a flight under water until it reaches the air. Space climbs. The controls and the current speed are on a card in the bottom-left corner for as long as the feet are off the ground.

**Tab** opens your inventory anywhere: what you are wearing, a live model of it, your numbered hotbar, and your pockets. Drag a garment onto a body slot to put it on, or shift-click it to send it straight to the slot it belongs in. Weapons and usable items go to the hotbar that the HUD mirrors. Hovering a tile names the item and describes it.

Sensitivity, invert-Y, FOV, and the camera-following rim-light color can be
changed under **Settings > Gameplay** and are saved in `user://settings.cfg`.
The rim control uses the same simple color circle, light-level bar, and example
bar as Hero Design; the outline previews while dragging and saves on release.
Ledges up to about shin height are stepped over automatically; see `step_height`
in `game/player/player.gd`.

Single-player **Sandbox** supports named world saves. Its pre-start mode-settings
panel offers **New Sandbox** plus every compatible save, while the in-game Tab
menu places **Save** and **Load** beside Settings. Save files are versioned,
mode-filtered, and atomically replaced under `user://saves/`; preferences stay in
`user://settings.cfg`. A snapshot restores planetary time, player transform,
health, stats, appearance, full loadout/progression/journal, captured fauna,
Meeps and their jobs, city buildings/roads/upgrades, settlement expeditions,
live fauna, bosses, terrain scars, broken flora, dropped items, ability walls,
and registered durable scene objects. Short-lived presentation such as particles
and projectiles is reconstructed from its durable result rather than serialized.

Run the persistence and cold-restore regression with:

```powershell
godot --headless --path . dev/_sandbox_save_test.tscn
```

## Catching a lag spike

`core/runtime_telemetry.gd` is an always-on thirty-second performance flight
recorder. Open **Tab > Admin** after a hitch: the curve is one point per rendered
frame, red below 30 FPS, and the cards show current FPS, the thirty-second
average, 1% low, worst frame and number of frames over 40 ms. Opening that menu in
single-player pauses the recorder along with the world, so time spent reading the
panel cannot overwrite the gameplay that led to it. Multiplayer does not pause
and remains live.

The quarter-second rows alongside the curve explain what was in those frames:
Godot process/physics/render CPU and GPU time, draw calls, primitives and memory;
terrain LOD queues and stage timings; resident and ledger cities, Meep rows,
roads, structures and street lights; flora tiles, workers, surveys, shared budget
and streaming phases; fauna actors and survey cost; live bosses; lights,
particles, audio and MultiMesh instances; player/network shape; and timed activity
for Meep stages, combat attacks, flora damage and terrain mutations. Repeated
attacks are rolled up by authored ability ID rather than logged once per target,
so a sustained beam stays readable.

**EXPORT 30s** writes one self-describing JSON file under
`user://performance_logs/` and copies its absolute path. Attach that one file to
the report: it contains every frame, all subsystem snapshots and hotspot events,
plus the engine version, OS/CPU/GPU, resolution, render scale, MSAA, VSync,
graphics settings and session role. **TRACE ON** controls the extra in-function
timers; the frame curve and engine counters continue even when it is off. A/B
benchmarks on save `Lag` put detailed tracing inside ordinary run-to-run noise
(53.9 versus 52.6 FPS over paired fifteen-second runs), while each coarse
recorder sample reports its own cost in the panel and export.

The ring, spike summary, activity rollup and exported schema are checked with:

```powershell
godot --headless --path . dev/_runtime_telemetry_test.tscn
godot --headless --path . dev/_menu_test.tscn
godot --headless --path . dev/_claim_spike_test.tscn
godot --headless --path . dev/_flora_prune_test.tscn
godot --headless --path . dev/_flora_glow_test.tscn
```

The last three are regressions taken from real sessions. Continuous border
growth now resumes from the previous claim frontier, updates only the new two-metre
band, traces only cells that can own a boundary edge, and uploads the wall as one
MultiMesh buffer; the production-sized check measures about 13–17 ms instead of the
captured 141–270 ms. The flora prune check loads 4,096 stale harvest keys and proves
their twenty-second cleanup is spread over 256-key slices (about 0.2 ms each) rather
than becoming a single long-session frame hitch. The glow check comes from a crash
report: a tile's glow anchors are written on a worker thread and were read on the main
thread while they were being replaced, so it proves that a tile the pool owns is never
read and that a tile mid-swap is walked to the shortest of its four arrays.

## Test Steam multiplayer

The project includes GodotSteam 4.21 GDExtension for Windows x64. Steam must be running and the testing accounts must have access to **My Strange Planet Playtest (5098060)**.

1. Sign into two different Steam accounts on separate machines or VMs.
2. Start a Playtest build on both.
3. Create a lobby on one machine, then either find it under **Join Lobby** or press **Invite Steam Friends**.
4. For a private lobby, the joining player is admitted to the game roster only after the host verifies the password.
5. The host presses **Start** after the roster is ready.

Steam supplies discovery, NAT traversal, and relay routing; one player's game remains the authoritative host. Valve is not running the world simulation as a dedicated server.

Development selects the Playtest ID with `steam/initialization/app_data/app_type=2` in `project.godot`. Change that App Type to `0` for the full store application **5098010**. Export with the normal Godot Windows templates; the GDExtension package carries the Steam runtime DLL.

## Optional local headless transport test

Godot can start a local host without navigating the menus:

```powershell
godot --headless --path . -- --server --port=7777 --max-players=8 --lobby-name="Local Test"
```

Replace `godot` with the full path to your Godot 4.7 executable if it is not on `PATH`. Stop the server with Ctrl+C. This hidden ENet path exists only for automated two-process chat checks. It is not used by the Online menu.

Add `--private --lobby-code=YOURCODE` to exercise host-side admission in that local harness. Steam lobby passwords likewise stay out of lobby metadata and are checked by the host before a player is registered.

## Customize the template

- UI control styling, spacing, and typography: `ui/themes/main_theme.tres`. The menus are drawn by the same colored-pencil shader as the world, so the theme deliberately leaves the styleboxes empty for the surfaces `ui/themes/pencil_surface.gd` paints; see `shaders/pencil/README.md`.
- Menu color tokens, i.e. the surfaces and the things drawn on them: `ui/themes/ui_palette.tres`. Five colors run the whole UI: Midnight Violet `#2d1e2f` is every panel, Vanilla Custard `#fcf6b1` is the type on those panels and the ring around whatever holds focus, Sunflower Gold `#f7b32b` is the default action of a screen and the color of its headings, Celadon `#a9e5bb` is every other button, and Burnt Tangerine `#e3170a` is reserved for leaving and for failing. The remaining tones — card and row sheets, secondary and muted type — are mixes of the first two, so recoloring the UI means editing those five and letting the mixes follow. Note that `main_theme.tres` cannot read the tokens and repeats them as floats, and that it owns the tab, popup, slider, and scrollbar fills as ordinary style boxes.

  The scheme is dark-surface, and it is held together by one rule: a control is never the color of the surface behind it. Panels are violet with custard type; buttons are filled with one of the bright colors and carry violet type. Hover and press shade a fill further in without changing its hue, so color says what a thing *is* and shading says what state it is in.
- Typeface: `fonts/Bungee-Regular.ttf`, set as the theme's default font and as `[gui] theme/custom_font` so anything outside the theme matches. It is imported with antialiasing, hinting, and subpixel positioning on. The size ladder is 15–17 for captions and dense in-game panels, 26 for body, 28 for buttons, and 32–64 for headings; swapping faces still requires checking those sizes because cap heights differ.
- Game title, drawn top left of the home screen: `title` under `[game]` in `project.godot`
- Home screen, camera poses and the hand-over into gameplay: `ui/menu/home_screen.gd`; the forms it puts up are `ui/menu/settings_panel.gd` and `ui/menu/lobby_panel.gd`
- Settings defaults and persistence: `core/settings_manager.gd`
- Test world: `game/world.tscn`. The round props deliberately collide as straight-sided cylinders: art that curves in under itself overhangs the player's feet, and a capsule character wedges under that instead of sliding off it.
- Alien-tech formations: `game/props/tech_formation_sites.gd` owns five deterministic 1.4 km-wide fields, including the north-pole floe. Each contains 36 instances ranging from the original room-sized shards to 300 m fragments, all from the one 562-panel mesh owned by `assets/source/blender/build_tech_fragment.py`; `game/props/tech_formation.tres` owns their reflective magenta/turquoise film. The five fields and the four tallest natural summits are orbital-range waypoints.
- Player tuning: exported values in `game/player/player.gd`, including the whole `Flight` group
- Items and their descriptions: `ItemDB.ITEMS` in `game/items/item_db.gd`
- Starter apparel and weapons: `STARTER_INVENTORY_REVISION` and `ensure_starter_inventory()` in `game/player/character_db.gd`
- Chat pacing, length limit and scrollback: constants in `core/chat_manager.gd`; the panel's size and how long it lingers: `ui/chat/chat_hud.gd`
- Voice bandwidth against quality: `RATE`, `PACKET_SAMPLES` and `PREBUFFER` in `core/voice_chat.gd`
- Colored pencil material and its test bed: `shaders/pencil/README.md`
- Player character proportions: section tables in `assets/source/blender/build_character.py`
- Character animation: pose tables in `assets/source/blender/build_animations.py`, arms via `arm_hang`
- How a weapon is held, and the swing: `HOLDS` and `SWING` in `game/player/weapon_pose.gd`

The settings file is intentionally stored outside the project at `user://settings.cfg`. Use **Reset Defaults** to restore template values.

## Flight

Press space in mid-air and the character takes off: it hovers upright with one knee drawn up, steers wherever the camera is pointing, climbs on space, and winds up past 200 m/s on a held shift while the body goes over from that hover into a flat-out flying line. Ctrl hauls it back down again. `dev/_player_test.tscn -- --flight` runs the whole arc and writes each pose to `dev/captures/`.

Flight is a fourth `Stance`, not a flag beside the other three. That one decision pays for most of the feature: the stance is already synced to every peer and already indexes the collider and eye-height tables, so a remote player animates and leans correctly with nothing added to the wire, and the host already knows which stance a submitted packet claims to be in. It borrows the standing capsule, which is why taking off and landing never have to ask whether there is room the way standing up out of a crouch does.

Four things are worth knowing before retuning it.

**The boost is a target, not an acceleration.** `_cruise` is the speed the player is asking for; `boost_time`, `ease_time` and `brake_time` move it across the whole range, and the velocity chases it with an acceleration that grows with it. Keeping the two apart is what lets the boost read as a long wind-up while a turn at 200 m/s stays a wide arc and a turn at hovering speed stays a pivot. Steering comes off the **camera's** basis rather than the body's, so looking down and holding forward is a dive; only the head pitches, so the camera's own X stays level and a strafe never rolls the flight path.

**The lean is the animation.** The two clips only cover the ends; everything between them is `character.rotation.x`, driven by one smoothed `_fly_blend` that also opens the field of view and picks the clip. It turns about the hips rather than the feet, because pitching about the feet would swing the head most of a body length forward and bury the shoulders. Pointed straight up, the same formula stands the body back upright; straight down, it goes head first.

**Water entry is a momentum handoff.** A flight arriving from the air changes to `SWIM` as soon as it is clearly through the surface, keeps `swim_entry_keep` of its velocity in the same direction, and lets the ordinary water drag slow it from there. The stroke target and swim lean are seeded from that carried speed, so the body starts in `Swim` rather than briefly standing upright in `Tread`. A flight deliberately launched by double-pressing space while swimming is exempt until it clears the sea; once airborne, its next entry becomes a swim normally.

**Space in clear air and space about to land are the same press.** The jump buffer exists to catch a press made just before touchdown, and a take-off would eat exactly those presses, so take-off additionally requires `TAKEOFF_CLEARANCE` of clear air below the feet. Under a metre, space is still asking to jump on landing. `dev/_player_test.gd` checks both halves, because getting one right silently breaks the other.

Two limits are deliberate. The host's teleport check and speed clamp are worked out from the stance in the packet, so a flying player is allowed the hundred-odd metres they can honestly cover between two 20 Hz updates — which means the ceiling on a client lying about its position is that much higher while it claims to be flying. And remote players are now dead-reckoned forward on their last known velocity for up to two packets, because sitting on a 50 ms-old position leaves a flying peer a building behind; a peer that goes quiet coasts to a stop rather than flying off on its last heading.

The test world's floor is 32 m across, which a boosted flight leaves in well under a second. That is fine for trying flight out and is not a bug to fix in `player.gd` — a game that keeps the player flying wants a world with something in it to fly over.

## Player character asset

`assets/runtime/characters/player_character.glb` is the rigged stylised character, bare. It imports in Godot as `Node3D > CharacterRig > Skeleton3D > Character`, and garments are added under that same skeleton at runtime.

- 1.45 m tall, feet on `y = 0`, faces Godot forward (`-Z`), so it can be dropped straight under a `CharacterBody3D`. The collider and eye heights in `player.gd` are derived from this height, so they need revisiting if the proportions change. Clothes deliberately do not change them: a hat is not a reason to stop fitting through a gap.
- One continuous 20.5k-quad body skin, decimated on export. There are no separate head/arm/leg objects and no seams to hide.
- 23 bones named to match Godot's `SkeletonProfileHumanoid` (`Hips`, `Spine`, `Chest`, `UpperChest`, `Neck`, `Head`, `Left/RightShoulder`, `UpperArm`, `LowerArm`, `Hand`, `UpperLeg`, `LowerLeg`, `Foot`, `Toes`), so retargeting and `BoneMap` work without renaming. `Root` is a transport handle and carries no weights.
- Modelled in an A-pose with at most four bone influences per vertex.
- One material, `CharacterBody`. `SurfaceSkin` gives every imported surface its own copy of `player_suit.tres` and copies that surface's albedo colour and texture into the vivid shader, so recolouring anything in Blender needs no script change. The body, its garments and the menu's model preview all go through it.
- The `Apparel` collection in the `.blend` is **excluded from this export**, because `build_apparel.py` writes each garment as its own `.glb` for the runtime equipment system to put on and take off. Exporting them into the body would weld the clothes to the character.
- Thirteen baked clips, imported as an `AnimationPlayer` beside the rig.

### Settler robotic textures

`assets/runtime/characters/player_character_3.glb` is the 1.60 m settler body. Its default look is `assets/runtime/characters/luke.png`; `character_3_clean_robotic.png` (red, cream and gold with cyan cores) and `character_3_integrated_robotic.png` (violet skin under graphite, silver and red armour with cyan lights) remain selectable alternatives. They are texture schemes on one body, not separate bodies: the skeleton, collider, animation set and `c3_*` apparel are shared.

The supplied front/back concept sheets are elevations of different proportions, not UV maps, and the source sculpt has no UV coordinates. `assets/source/blender/character_3_skins.py` therefore owns the adaptation. `build_character_3.py` asks it to make one packed atlas, evaluates those two designs in the mesh's original 3D metres, and rasterises both PNGs through that atlas. Luke is painted directly against the same atlas and is put on the exported material as the default:

```powershell
& $blender --background --python assets/source/blender/build_character_3.py
& $godot --headless --path . --import
```

The home-screen Hero Design tab lists all three schemes from `CharacterDB.SKINS`. The saved look and player metadata carry a `skin` id beside `body`; peers therefore draw the same scheme without duplicating the `.glb`. The colour wheel remains a multiplicative wash over the selected texture. **No tint** removes that sparse tint entry rather than saving white, so the authored texture is restored exactly and later texture edits are not hidden behind an override.

Both skins can be rendered from the same generated `.blend` without rebuilding:

```powershell
& $blender --background assets/work/character_3_rigged.blend --python dev/_render_dressed.py -- --hide=apparel --skin=integrated_robotic --out=c3_integrated
```

### Animation clips

| Clip | Loops | Driven by |
| --- | --- | --- |
| `Idle` | yes | Standing still |
| `Walk`, `Run` | yes | Ground speed, resampled with `speed_scale` so the feet keep up |
| `CrouchIdle`, `CrouchWalk` | yes | Crouch stance |
| `JumpRise`, `Fall`, `AirRun` | rise and air-run no, fall yes | Airborne: rise/fall initially, then a held landing stride after one second |
| `Land` | no | Touchdown, skipped if you land still running |
| `Slide` | no | Slide stance; eases into the pose and holds it |
| `Float`, `Fly` | yes | Flight stance, split on how much of the boost is in |
| `Tread`, `Swim` | yes | Swim stance, split the same way on how fast the stroke is going |

`player.gd` picks a clip from stance, speed and ground contact in `_update_animation()` and crossfades with `CLIP_BLEND`. glTF carries no loop flag, so the looping set is marked in `LOOPING_CLIPS` at load.

Two of those pairs are authored **upright**, and the game pitches the whole body forward as speed builds, so in the `.blend` "up" is the direction of travel: `Fly`'s arms swept behind the hips become a pair streaming off the shoulders, and its straight legs a trailing line, the moment the body leans over. `Swim` is the same trick under water — a front crawl written vertically, which is why its arms sweep the whole way round the shoulder rather than reaching forward. That split is what makes the hover and the flight one continuum rather than two unrelated poses, and the tread and the crawl likewise: the lean carries the change, and the clips only have to be right at each end of it. Authoring either flat-out clip lying down would fight the rig's rest pose and leave nothing usable at the hovering end.

The three poses the body holds at speed — `Run`, `JumpRise` and `Fly` — all sweep the arms **back**. Every one of them carried the arms forward first, which is what a body really does; the arm swing is where a third of a jump's height comes from. But at the top of that swing the palms are up and the elbows are bent, and with nothing else in the pose doing any work it reads as somebody feeling their way along a dark corridor. Arms back with the chest driven forward is the posture that says speed, and the legs then carry what separates the three: a stride, a split tuck, and a straight line. `Fly` spent a while on one arm up and one back as well, which reads at any size but dates the whole thing and is the one pose a held weapon cannot survive.

The clips are authored as code in `assets/source/blender/build_animations.py`, which opens the `.blend`, replaces every action, pushes each into its own NLA track and re-exports the `.glb`:

```powershell
& $blender --background --factory-startup assets/source/blender/player_character.blend --python assets/source/blender/build_animations.py
```

Each clip is a function of cycle phase returning per-bone rotations in **world** axes (X pitch, Y roll, Z yaw) rather than bone-local ones, because bone-local axes depend on whatever roll the rig builder calculated. Crouch, land and slide depths run through `leg_fold()`, a two-link solve that folds the legs by exactly as much as the hips drop, which is what keeps the soles on the floor; changing the depth of one of those poses is a single number. `dev/_player_test.gd` measures foot bone heights across every clip so a pose that sinks the boots shows up as a number rather than needing to be spotted by eye.

Arms go through `arm_hang()` for a similar reason. The rig rests in a wide A — 42 degrees out from vertical at the shoulder — so a clip that wants hands at the hips has to bring the arms most of the way down, and the forearm inherits the shoulder's part of that and would otherwise be adducted twice and end up across the body. So a pose names the angles the finished arm should read as, out from vertical and bent at the elbow, and the helper works out the rotations. It also matters that the drop is listed before the swing: rotations apply in order, and swinging an arm that is still held out sideways twists it rather than swinging it.

`assets/source/blender/_arm_check.py` reports the rest angles those numbers are relative to, and, for every clip, how close the arms come to the body:

```powershell
& $blender --background --factory-startup assets/source/blender/player_character.blend --python assets/source/blender/_arm_check.py
```

It compares the deformed mesh, not the bones, so an arm that has been brought in far enough to sink into a hip is a number in the output. Every clip currently clears by at least 7 mm.

### Regenerating the mesh

Everything under `assets/source/blender/` is the authoring side and is hidden from Godot by a `.gdignore`. The character is generated by script rather than hand-sculpted, so proportions are edited as numbers and rebuilt:

```powershell
$blender = "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"
& $blender --background --factory-startup --python assets/source/blender/build_character.py
& $blender --background --factory-startup assets/source/blender/player_character.blend --python assets/source/blender/render_previews.py
```

The first command rewrites `assets/source/blender/player_character.blend` and exports `assets/runtime/characters/player_character.glb`. The second writes orthographic, three-quarter, wireframe, and posed previews to `assets/previews/authoring/` for eyeballing changes.

### Re-exporting after editing the .blend by hand

`build_character.py` **overwrites the .blend**, discarding hand edits to the mesh and every baked action with it. Use the export-only script to pick up manual edits, which reads the file and writes the `.glb` without modifying or saving anything:

```powershell
& $blender --background assets/source/blender/player_character.blend --python assets/source/blender/export_glb.py
```

Run it with the Blender version that last saved the file; opening a newer `.blend` in an older Blender drops data silently. It prints the mesh and bone counts, modifier settings, bounds, floor offset, and the object list it is about to export, so a change that would break the Godot import is visible in the output.

Prefer it over Blender's **File > Export > glTF** dialog. The dialog defaults to the "Actions" animation mode, which writes nothing for the slotted actions Blender 4.4+ produces and so ships a `.glb` with no `AnimationPlayer` at all; `export_glb.py` exports the NLA tracks the clips actually live in.

Silhouette lives in the section tables at the top of `build_character.py`: `TORSO`, `ARM`, `LEG`, and `BOOT` are control points holding a centre plus a width and depth radius. They are resampled along a Catmull-Rom spline, lofted into closed tubes, then fused into a single watertight surface by a voxel remesh and a relaxation pass, which is what rounds the shoulders and hips instead of leaving intersecting primitives. `source/reference.png` is the concept sketch the proportions target.

Run `dev/_check_character.gd` to re-verify the export after a rebuild:

```powershell
godot --headless --path . --script dev/_check_character.gd
```

It prints the imported node tree, the bone list, the mesh bounds, and whether the character still faces `-Z`.

## Hats, items and getting dressed

The active apparel loadout is one hat slot. Owned hats are managed from the Hats page, while a completed Hat House offers the specialty catalogue; the numbered combat hotbar remains separate.

Four pieces move the clothes around, and only the last one knows anything about menus:

| Script | Holds |
| --- | --- |
| `game/items/item_db.gd` | Every item: title, description, the slot it occupies, and its `.glb` |
| `game/items/item_container.gd` | A run of slots holding item ids, with per-slot filters and the move rules |
| `game/player/wardrobe.gd` | Putting a garment `.glb` onto a character's skeleton, and taking it off |
| `ui/menu/red_catalogue_page.gd` | The Hats screen: owned tiles, equip/stow actions, details, and a live model |

Every grid on the screen is an `ItemContainer`: the player's `equipment`, numbered hotbar and `backpack`. That is what keeps equipping from being a special case. An equipment slot carries a filter naming its body slot, so it refuses a pair of shoes on the head; dropping a hat there is an ordinary move, and the player, watching its own equipment container, is what turns that into a garment on the skeleton. The same change drives the model in the menu, so the preview cannot drift from the body in the world.

The numbered hotbar accepts weapons and ordinary usable items. It is the same container the HUD bar along the bottom of the screen shows, so an item dropped there is immediately on the bar without anything being copied.

Adding a hat is an entry in `ItemDB.ITEMS` plus its scene, followed by adding its id to the compatible body in `CharacterDB`. The item's icon is rendered from its own mesh by `ui/inventory/item_icons.gd`, so there is no second copy of the art to keep in step.

The current specialty stock uses deterministic runtime fallback scenes in `assets/runtime/apparel/placeholder_c3_*.tscn`. They were added because no usable Blender/export executable was available during this pass, and keep the Hat House populated without checked-in generated binaries. Each scene is a broad primitive silhouette with an authored body-space transform; `metadata/wardrobe_preserve_transform` keeps that placement when `Wardrobe` mounts it. Replacing one with exported art only requires changing that item's `scene` path in `ItemDB`.

Two things about the 3D bits inside a menu are worth knowing before changing them. The icons and the model preview are rendered well above the size they are drawn at and scaled down, because the outline pass measures its strokes in pixels and would otherwise ring a 44-pixel icon in strokes as thick as the garment. And neither viewport is given an `Environment`: the pencil material ignores ambient light, so the only thing one could do there is escape into the world's own lighting.

Over the network, a player owns their own look: equipment changes are broadcast, other peers apply them to that player's skeleton, and a peer joining later is told what everyone has on with the rest of the world state.

Specialty hats have a separate persisted `owned_hats` entitlement ledger containing shop IDs only. With no account backend, a remote player's first progression bootstrap is the explicit trust boundary for sanitized local-save Gold, ability levels and hat ownership; after that handoff the host is authoritative. Loadout snapshots cannot manufacture an unowned shop hat, and Hat House buy/equip/stow actions all return to the nearby completed shop for host validation. A purchase is the only operation that adds a new shop ID to the ledger.

Run the headless apparel check after changing a body or garment:

```powershell
godot --headless --path . --script dev/_check_apparel.gd
```

It equips every compatible garment on both bodies and verifies skeleton bindings, surfaces and imported clips.

## Weapons

`assets/runtime/items/sword.glb` and `assets/runtime/items/laser_rifle.glb` are the two weapons. Each imports as a single `MeshInstance3D` with no skeleton and no animation. Both are held two-handed, with one hand on the grip and the other supporting.

They share one mount convention, so either weapon works in either hand:

| | |
| --- | --- |
| origin | the centre of the grip, i.e. the point that sits inside the fist |
| `-Z` | the direction the weapon points — blade tip, muzzle |
| `+Y` | the weapon's up — sword flat, rifle sight rail |

That means a weapon parented to a hand with an identity basis points where the character faces, since `-Z` is Godot forward.

- **Sword**, 0.823 m: a 0.61 m tapered blade with a hexagonal section and a drawn-out point, a brass crossguard, a waisted leather grip with four wrap ridges, and a brass pommel. 990 faces, 3 materials.
- **Laser rifle**, 0.613 m: a 0.10 m calibre cylindrical barrel with cooling rings and glowing energy bands, a flared muzzle with an emitter lens, an underslung power cell, a sight rail and optic, and a raked pistol grip. 2014 faces, 4 materials, with the glow surfaces carrying emission.

Sizes come out at 57% and 42% of the character's height, which are the same ratios a one-handed sword and a carbine have to a real person.

### Fitting the hands

Grips are **measured off `player_character.glb`**, not written down. `assets/source/blender/character_ref.py` finds the vertices weighted to each `Hand` bone and reports the fist's radius and where its centroid sits along the bone; grip thickness and length are ratios of that radius. Editing the character's hands and re-exporting is enough to keep the weapons fitting — there is no second copy of the character's dimensions anywhere.

`game/player/weapons.gd` derives the same offset on the Godot side from the skeleton alone: the hand bone gives the direction and its rest translation gives the length. A weapon hangs off a `BoneAttachment3D` on the hand bone, so it follows the hand through every clip the body plays without its own skeleton or animations.

```gdscript
const WeaponsScript := preload("res://game/player/weapons.gd")
WeaponsScript.dual_wield(character)                          # sword right, rifle left
WeaponsScript.equip(character, "left", "sword")              # or one hand at a time
WeaponsScript.unequip(character, "right")
```

`OnlinePlayer` builds its pencil materials by walking every `MeshInstance3D` under the character, so equip before that runs and weapons are shaded like the body, picking up the colours baked into their `.glb`.

### Holding them

A mount alone leaves a weapon pointing out of a hand that hangs at the side, because the rig's rest pose is an A-pose. The stance is not a clip: locomotion is full-body, so a hold clip would have to be authored per weapon per gait. `game/player/weapon_pose.gd` is a `SkeletonModifier3D` that solves the arms *after* the animation has been applied, which is why the same two holds work over idle, walk, run, crouch and mid-air alike.

Each hold in `WeaponPose.HOLDS` is written as two points relative to the sternum — where each hand grips — and the weapon is then aimed **along the line through both hands**. That is the part worth keeping: the support hand is on the weapon by construction rather than by an angle that needs re-tuning whenever a pose moves, and a swing is just the two points travelling, with the blade following from them.

The rest is bookkeeping the rig forces:

- A two-link solve puts each elbow somewhere plausible, pushed away from the body by a pole vector, and clamps a target that is out of reach. Bone lengths come off the rest pose, so re-proportioning the character needs nothing changed here.
- Targets are given in a frame that sits at the sternum and carries only what the animation *added* to it. Blender lays a bone's axes along the bone, which leaves this chest's `+X` pointing to the character's left, so targets written in the bone's own space come out mirrored.
- A hand is turned to the rotation that lands the weapon on the aim, and solved to where its wrist has to be for its grip — not its wrist — to reach the target, using the same `GRIP_ALONG_HAND` fraction the mount uses.
- `PITCH_FOLLOW` decides how much of the player's look angle a hold takes on: all of it for the carbine, so a shot aimed upwards does not leave a level barrel, and a quarter of it for the sword.

The holds themselves: the sword is two-handed off the character's right, blade straight up, with the support hand reaching across for it, and a cut travels right to left through three keys with the torso leading. The carbine is held with the trigger hand in and the support hand forward under the barrel; sighting in raises both to the eye. Each pose's `twist` turns the chest, and because the targets ride the chest it also steers the weapon, so the twists are set to leave the carbine pointing where the character faces.

Arms on this character reach about 0.385 m, which is what limits both holds: the support hand is the one that runs out of reach, and both poses sit at the edge of it.

### Drawing and firing

`ItemDB` carries three extra fields for a weapon — which hold takes it, whether the attack is a swing or a shot, and how many shots its cell holds — so arming the character is the same container move as putting on a hat. `OnlinePlayer.weapons` is the rack; selecting a slot equips what is in it and sets the hold, and selecting an empty slot puts the weapon away.

- The **sword** cuts on left click and ignores further clicks until the swing is done. It has no hit detection: there is nothing in this template to hit yet.
- The **carbine** fires `game/weapons/laser_bolt.gd`, which sweeps a ray over the ground it covered each frame rather than being a physics body, because a body at 74 m/s tunnels through walls. Bolts leave the muzzle but are aimed at the crosshair, so a shot lands where the player aimed instead of parallel to it. Its cell holds twelve and trickles one back every 0.85 s after a short pause, which paces the weapon without a reload key.
- Sighting in narrows the field of view, halves mouse sensitivity, draws the crosshair in, and raises the hold.

In first person the body is drawn as shadow only, but what is in the hands is not: a sword rising into view or a carbine held at the chest is most of the feedback there is. The exception is a weapon brought within 0.3 m of the eye, which is a wall of polygons rather than a weapon, so sighting in hides the model and leaves the zoom and the crosshair to say so.

Over the network only the weapon **in hand** is broadcast, since nobody can see anyone else's rack, and a peer joining later is told it with the rest of the world state. Swings and shots are sent as events rather than derived from state: both are instants, and a peer that misses the packet should miss the swing rather than play it late.

`dev/_weapon_test.gd` photographs every hold, the swing, and a bolt in flight into `dev/captures/`, and measures the parts that cannot be judged by eye:

```powershell
godot --path . dev/_weapon_test.tscn
```

For each pose it reports where the weapon points, how far the support hand sits off the weapon's axis, how far apart the two grips are, and the `cant` — how far off the character's facing the weapon points, which is what a rifle held across the chest shows up as. It also confirms the wheel skips empty slots, that a shot leaves along the crosshair and spends a charge, that the cell recovers, and that shift-clicking a weapon into the hotbar equips it. Hands are measured through `BoneAttachment3D` probes rather than `get_bone_global_pose()`, which reads a cache a frame behind the modifier that moved them.

### Regenerating

The weapons are built from the shared bmesh primitives in `assets/source/blender/propkit.py`. The build reads `player_character.glb`, so export the character first if you have changed it.

```powershell
$blender = "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"
& $blender --background --factory-startup --python assets/source/blender/build_weapons.py
& $blender --background assets/source/blender/weapons.blend --python assets/source/blender/render_weapons.py
```

The first command writes `assets/source/blender/weapons.blend` and both `.glb` files, printing the measured fist and the grip it derived. The second writes previews to `assets/previews/authoring/`: each weapon on its own, both dual wielded on the character, and `weapons_grip`, a close-up that shows the grip inside the mitten.

Run `dev/_check_weapons.gd` after a rebuild:

```powershell
godot --headless --path . --script dev/_check_weapons.gd
```

It checks the surfaces and dimensions, confirms the grip it derives lands within a couple of millimetres of the fist `character_ref.py` measured, and swings each arm to confirm the weapon stays locked to the hand. It poses bones directly rather than playing a clip: an `AnimationPlayer` never applies a pose in a headless `SceneTree` script, and `Skeleton3D.get_bone_global_pose()` reads a cache that is only refreshed while processing frames, so a clip-driven check silently measures the rest pose and passes for the wrong reason.

## Backpack

`assets/runtime/items/backpack.glb` is a soft-sided pack with a leather lid, a buckled closing tongue, a grab handle, side rivets and two padded shoulder straps. It imports as a single `MeshInstance3D` — 4,916 triangles, 3 materials — with no skeleton and no animation.

The pack body is 0.245 m wide, 0.307 m tall and stands 0.147 m off the back, which is 21% of the character's height; the mesh as a whole is wider and deeper than that because the straps reach out to the shoulders and forward to the chest.

It is a **rigid prop, not a skinned garment**. A pack does not deform, so it belongs on a bone rather than in the skin, and it uses the same convention as the weapons:

| | |
| --- | --- |
| origin | the `UpperChest` bone, so a `BoneAttachment3D` there needs no offset of its own |
| `-Z` | the direction the character faces, so the pack hangs off the `+Z` side |
| `+Y` | up |

Nothing in `game/` mounts it yet.

### Fitting the back

Every dimension is **measured off `player_character.glb`** by `character_ref.py` rather than written down, and two of those measurements are the difference between a pack that fits and one that does not.

The back panel **follows the spine's contour** instead of being flat. `ray_to_surface()` casts at each cross-section and sets that section's front face on the surface it hits. A flat panel set at the deepest point of the back stands off everywhere the back is shallower, which leaves a visible gap under the shoulder blades.

The straps **cross outboard of the head**. This character is a big head sitting almost straight on the body with no trapezius, so there is no gap beside the neck for a strap to pass through: the head reaches out to x ≈ 0.19 and the shoulder surface only begins at x ≈ 0.20. `shoulder_crossing()` walks outward casting downward and takes the first sharp drop, which finds that saddle. Two things follow from measuring it rather than assuming it:

- Nearest-point projection is useless here — beside the head the top of the shoulder and the side of the head are nearly equidistant, so it is a coin toss which one a strap lands on. A downward ray can only hit the shoulder.
- The pack hangs off the shoulder **surface**, not the shoulder **bone**, which sits 0.08 m below it. Placed off the bone the pack rides down by the whole difference and reads as a satchel on the mid-back.

Straps are then splined through ten ray hits along the route. Fewer waypoints and the curve cuts the corner and stands off the shoulder in a loop, and the run up the back is pinned just under the shoulder's rear slope — that slope is lower than the top of the pack, so letting the strap climb to the pack's top first makes it rise, dip and rise again in a visible kink.

### Regenerating

```powershell
$blender = "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"
& $blender --background --factory-startup --python assets/source/blender/build_backpack.py
& $blender --background assets/source/blender/backpack.blend --python assets/source/blender/render_backpack.py
```

The first command writes `assets/source/blender/backpack.blend` and the `.glb`, printing the span it fitted, where the back surface put the front face, and where it found the shoulder crossing. The second writes previews to `assets/previews/authoring/`: the pack alone, worn from three angles, and `backpack_strap`, a close-up that shows whether the strap lies on the shoulder or through it.

Render scripts share the camera, world and light rig in `assets/source/blender/previewkit.py`.

## Workbench

`assets/runtime/items/workbench.glb` is a joiner's bench: a thick top with a tool well along the back, a pegged backboard, a slatted lower shelf, and a face vice at one end. It imports as two `MeshInstance3D` nodes — 5,292 triangles, 4 materials — with no skeleton and no animation.

| | |
| --- | --- |
| footprint | 1.28 m long by 0.56 m deep |
| work surface | 0.639 m, with the backboard reaching 0.859 m |
| origin | the centre of the footprint at floor level |
| `-Z` | the working side you stand at, matching the other props |
| `+Y` | up |

The vice's sliding half is a second object, `WorkbenchViceJaw`. Its origin sits on the screw axis where the jaws close, so Godot winds the vice open by moving it along `-Z` with no offset node in between. It is modelled 0.030 m open and has about 0.085 m of useful travel. There is no collision shape; a box per leg and one for the top is enough, and cheaper than a trimesh.

Nothing in `game/` places it yet.

### Bench height comes from the elbow, not the height

Bench height is ergonomic rather than architectural — it is set by the arms — so scaling a real 0.90 m bench down by this character's height gets it wrong. The character is 1.447 m tall but its head is a fifth of that, which puts the shoulders at 0.68 of standing height where an adult's are at 0.82. Working from stature would stand the top near mid-chest.

`character_ref.arm_drop()` measures it properly. The rest pose holds the arms out in an A-pose, about 55° below horizontal, so no arm joint's rest position is where it sits on a standing figure; the heights have to be derived by dropping the bone lengths from the shoulder. That gives a shoulder at 0.982 m, elbow at 0.722 m and wrist at 0.597 m. A general-purpose bench sits a hand's width below the elbow, so the top lands at **0.639 m** — 0.082 m under the elbow and 0.042 m over the wrist, which `workbench_scale` confirms is right where the character's hands hang.

That works out at 44% of standing height where a real bench is 51%, which is the character's short arms showing up rather than a mistake.

### Two things that did not work first time

**The tool well's depth is not a free parameter.** It is fixed at the thickness of the top, because the trough floor has to sit flush with the underside of the slabs either side of it. Dropping the floor lower to deepen the well opens a slot running the whole length of the bench along both sides of the trough — between the floor and the slabs above it there is nothing left to bound the well with. The ends need closing separately, or three slabs and a floor leave a trough that reads as a slot sawn through the bench.

**A vice made of two iron plates does not read as a vice.** Nearly shut, it renders as a black box bolted to the bench, indistinguishable from a drawer. Three changes fixed it: a wooden liner over each jaw so the colour breaks up the mass, a gap wide enough to see the screw and guide rods crossing it, and the tommy bar hung vertically rather than across the bench, where it lay over the jaw and merged with it into one dark shape.

The jaws are also kept wholly below the underside of the top. Bringing them up level with the front edge, which is where a real vice sits, puts the jaw plate's faces exactly on the top's front face, and two coincident coplanar faces z-fight.

### Regenerating

```powershell
$blender = "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"
& $blender --background --factory-startup --python assets/source/blender/build_workbench.py
& $blender --background assets/source/blender/workbench.blend --python assets/source/blender/render_workbench.py
```

The first writes `assets/source/blender/workbench.blend` and the `.glb`, printing the arm measurements it worked from and where they put the top. The second writes previews to `assets/previews/authoring/`: front, three-quarter, a high angle for the tool well and shelf, `workbench_open` with the vice wound out to check the jaw really slides along its screw, and two character shots — `workbench_scale` stands the character beside the bench for a straight height comparison and `workbench_use` puts them at it.

`previewkit.Preview.ground()` provides the floor. Furniture reads as floating without one, and more to the point there is no contact shadow, which is the only cue that tells you whether the legs reach the ground.

## Cave entry room

`assets/runtime/environment/cave_room.glb` is an enclosed cave chamber with a tunnel mouth broken through one wall and glowing crystal clusters for light. It imports as three `MeshInstance3D` nodes and six `OmniLight3D` nodes — 18,470 triangles, 4 materials, no skeleton and no animation.

| | |
| --- | --- |
| chamber | ~10.5 m nominal radius, bulging to 11.7 m where the rock swells; 9.6 m to the highest point of the ceiling |
| tunnel | roughly 5 m wide by 4.7 m tall at the mouth, running 24 m out from the centre and bending as it narrows |
| origin | the centre of the floor, so the room drops straight in at the world origin |
| `+X` | the direction the tunnel leads |
| `+Y` | up |

The floor is uneven but deliberately kept walkable, dipping to −0.45 m and rising to about +0.5 m. **There is no collision shape** — add a trimesh collider on import, or rename the shell to `CaveRoom-col` in the build script to have Godot generate one.

### Turning the rock inside out

The shell is authored as a **solid volume and inverted at the end**, which is what `flip_normals` on `propkit.new_object()` is for. Carving a room out of nothing is far more awkward than modelling the rock it displaces, and it makes the tunnel a plain boolean union of two lathed volumes rather than a hole that has to be cut and stitched. The build asserts both halves of that: the shell must have zero open edges, and rays cast outward from inside must all hit faces looking back at them. Get the winding backwards and the room renders as nothing at all once backface culling is on.

Displacement is a function of **position, not surface normal**. Two coincident vertices either side of the boolean seam carry different normals, so displacing along normals tears the shell open along the join. It is also applied *after* the union — displacing first gives the exact solver two noisy surfaces to intersect and it starts producing slivers.

Three things had to be true before the room read as a cave rather than as a smooth dome:

- **Noise frequency has to be a fraction of the room.** `mathutils.noise` has a feature size of about one unit, so a frequency of 0.085 puts the whole 21 m chamber inside a single noise feature and the displacement flattens into a uniform offset. Features of a few metres are what break up the walls.
- **The rock has to facet.** Smoothing the shell across its own lumps turns metres of displacement into soft gradients that read as fog. A 24° smoothing angle lets the facets show.
- **Surface noise alone is not enough.** The dripstone is what says "cave". Stalagmites and stalactites are placed by casting rays at the finished shell, so each one stands on the displaced rock instead of hovering over where a smooth dome would have been, and rays that land on a steep face are rejected rather than left sliding off the silhouette.

`mathutils.noise` seeds itself from the clock and its vector variants read that seed, so an unseeded build produces a different cave every run — and because the dripstone and crystals are positioned by raycasting at the rock, they all move too. `noise.seed_set()` makes the build reproducible; three consecutive builds now agree to the last decimal place.

### Keeping the hole dark and still visible

The tunnel's faces keep their own near-black material through the boolean, which is what makes the passage read as dark rather than as a lit alcove, and it bends away from the chamber so none of its capped far end is ever in view.

That alone is not enough to see it, though. The wall around the mouth was originally as unlit as the mouth itself, and a dark hole in dark rock is not a hole — it needs lit rock around it to read against. Two small crystal clusters flank the opening at roughly ±40°, far enough to either side that their light grazes the wall rather than reaching down the passage.

The crystals are emissive, but **emission lights nothing on its own** without ray-traced GI, so each significant cluster carries a point light. Those export through `KHR_lights_punctual`, which Godot imports as real `OmniLight3D` nodes. Their energies are in the low hundreds of watts: a point light falls off as the inverse square, and lighting a 20 m chamber from 5 m away takes a few hundred watts, not the few thousand that sounds reasonable for a lamp in a small room. At 2,400 W every surface clipped to flat saturated colour and the geometry disappeared entirely.

### Regenerating

```powershell
$blender = "C:\Program Files\Blender Foundation\Blender 5.1\blender.exe"
& $blender --background --factory-startup --python assets/source/blender/build_cave.py
& $blender --background assets/source/blender/cave_room.blend --python assets/source/blender/render_cave.py
```

The first writes `assets/source/blender/cave_room.blend` and the `.glb`, printing the chamber's measured size, the polygon budget per object, how much dripstone was placed, and the two shell integrity checks. The second writes previews to `assets/previews/authoring/`: the chamber, the tunnel mouth from across the room, the arrival view from inside the passage, the ceiling, the crystals, and `cave_scale`, which stands the character in the room.

Unlike the prop previews, `render_cave.py` sets up **no light rig** — the room's own crystals are the subject and a three-point rig would flood out the only thing worth looking at. The world is left nearly, but not quite, black: at zero, every surface the crystals do not reach renders as a flat silhouette and the dripstone in front of a glow turns into a paper cut-out.

## Abilities

Two of them, on the two mouse buttons whenever nothing is drawn: **Laser Eyes** on left, **Meteor Punch** on right. They are not weapons and they do not go in the weapon rack — `OnlinePlayer.abilities` is its own container, `ItemDB` marks their entries `KIND_ABILITY`, and the same slot filter that keeps a hat out of the weapon wheel keeps a sword out of an ability slot.

They exist as a framework rather than as two special cases, because most of what an ability needs is the same for all of them. `game/abilities/ability.gd` holds the cooldown, the stances it is allowed from, and whether water stops it; `ability_controller.gd` is a node under the player that builds one ability per filled slot from the catalogue and drives press, hold and release. Adding a third ability is a script and an `ItemDB` entry.

Production progression seeds only **Laser Eyes** and **Meteor Punch** at level one. A valid ability already equipped by a legacy profile is grandfathered at level one; every other definition starts locked. The ordinary Abilities tab lists unlocked powers only, while a completed Abilities House deliberately lists the whole catalogue with host-authoritative unlock, upgrade and equip actions.

An Abilities House can be commissioned into a tower for 800 city biomass after its base building is complete. Meeps raise the existing structure to exactly twice its original height; the completed form, purchase flag, and work-in-progress floor state are carried by saves and late joins. The tower unlocks the house's **STATS** tab. It lists unlocked reusable abilities only and trains Power, Cooldown, Size, Speed, Range, and Duration independently to level five wherever the authored ability has those numbers. Each purchase is host-authoritative and persists in `ability_stat_progress`; the same resolved stats drive cooldowns, movement, projectiles, constructs, impacts, menus, and host combat checks. Power never increases the separate `player_damage` field.

Their numbers live in `ItemDB.ITEMS` rather than in the scripts, so the ability that quotes 180 damage a second in the menu is the ability that deals it:

```gdscript
"laser_eyes": {
	"title": "Laser Eyes",
	"kind": KIND_ABILITY,
	"script": "res://game/abilities/laser_eyes.gd",
	"stats": {"damage": 180.0, "damage_unit": "/s", "duration": 4.0,
		"range": 60.0, "cooldown": 3.0, "radius": 0.35},
},
```

`ItemDB.stat_lines(id)` turns that into the lines the menu shows (`Damage   180 / s`, `Range   60 m`), so every ability is formatted by one table instead of by whoever wrote its panel.

### What they do to the world

Neither ability knows what it is hitting. Both describe a **volume** — `game/combat/damage_hit.gd`: a capsule, an amount, and how fast the amount falls off across it — and hand it to every field in the `flora_damage_fields` group, which works out for itself which of the things it owns are inside. That is what lets one laser tick damage grass, a tree trunk and the ground with the same object, and it is the only way to hit grass and shrubs at all, since they are `MultiMesh` instances with no colliders anywhere.

What absorbs it is flora health. `PlantSpecies` now authors `health`, `health_per_metre` and a `toughness` band, and **derives** the old run-through break speed from them, so the two cannot drift apart; the migration set `health = break_speed * 12` across all 46 species, which preserves every previous break speed exactly. Toughness is what makes the beam slice grass instantly and grind on an orb giant. Damage short of a kill chars: it is written into the free alpha channel of the instance colour, which `shaders/vivid/vivid_plant.gdshader` reads to darken the albedo and kill the night emission, leaving the RGB semantic mask alone.

The ground is `game/planet/terrain_scars.gd`, a bucketed registry hanging off `PlanetShape`. `elevation()` subtracts `scars.depth_at()` **last**, after the native field, the volcano and the town pads, so a crater cuts through a city pad as readily as through sand; `color_at()` takes the matching tint. A scar therefore lands in the same height field the mesh is built from, the collider generated from and the player's ground guard reads, so there is one answer to where the ground is rather than three that have to be kept in step. `Planet.mark_region_stale()` re-queues the affected chunks through the existing per-frame build budget, so a burst of craters degrades into a slightly slower refresh instead of a hitch — and only the chunks whose vertices are close enough together to draw the mark are re-queued at all, since the height field already fades a scar out at coarser spacings and rebuilding those would produce the ground they already have.

A rebuilt mesh comes back **on screen immediately**, which a newly built one deliberately does not. A first build waits for the next quadtree walk to choose it, and should: the coarse ancestor covering that ground is still drawn, and letting half-refined patches appear the moment they land is how ground pops through the mesh standing in for it. A rebuild has no such cover — the ancestor retired its own mesh when this chunk took the ground over — so switching the replacement on only at the next walk leaves that patch with nothing drawn over it at all, and what is behind the ground is the inside of the planet. Meshes are attached every frame and the walk runs at 30 Hz, so it was up to a walk interval of hole, several times a second under a held beam. The two cases are told apart by `Chunk.rebuilding`, which also keeps the `stranded` counter meaningful: a rebuild lands on a chunk that already holds a mesh every single time by design, and counting those alongside the genuine overwrite-and-orphan fault would bury it.

**Its collider comes back in the same breath, and that turned out to be the half that mattered.** Seeing through the ground while a beam is swept over it looks like a mesh problem and is not: the camera rides a `SpringArm3D`, which holds itself out of the scenery by casting at the **bodies** in it, so ground with no body under it is ground the arm cannot see. The camera runs into the hillside, draws its back faces, and you are looking through a mesh that was present and correct the entire time. Two things were opening that window several times a second, and both are shut:

- A rebuild used to free its collider and leave `_update_collision` to make the next one. That pass is budgeted by `bodies_per_frame` and shares its allowance with all the ordinary streaming, so the chunk could spend frames drawn with nothing under it. The faces are in hand when the build lands, the work is the same work either way, and only chunks that already had a body — the handful near the viewer — pay it, so it is done there and then. Measured against the deferred version the difference is noise: 162 ms of laser-groove rebuild became 164 ms.
- Marking a region stale used to drop every collider over it outright. That is right for a crater, where the alternative is standing on a ledge of ground that no longer exists, and it is what stopped the fall after a punch. It is wrong for a laser groove, which cuts 0.2 m four times a second wherever the player happens to be looking — very often at their own feet. `mark_region_stale` now takes the depth of the cut and only drops colliders past `COLLIDER_DROP`, a stride.

The invariant this restores is `floorless` in `Planet.statistics()`: drawn ground within reach of a walker that has no body under it. Zero is the only steady-state answer, and a swept beam had been sitting at one chunk per scar.

Vertex tint alone is not a burn. At the range a scorch mark is actually looked at, the ground is drawn from a photographic material and a tint spread over a handful of vertices does not read at all, so `game/planet/scorch_decals.gd` keeps a pooled ring of `Decal` nodes — fading ones for the beam, permanent ones for a committed scar. Marks landing on top of each other merge rather than stack, since a held beam lands ten a second on one spot and ten decals multiply into a hole with no soot edge left in it.

### Laser Eyes

Two beams from the eye offsets in `CharacterDB.BODIES`, converging on the aim point. Those offsets are in the **body's** space, not the Head bone's, and the distinction is not pedantry: the two characters' Head bones are turned half a circle from one another, so one set of numbers authored "so far forward along the bone" was always going to come out backwards, and it did — the settler fired out of the back of its neck for a while. `eye_points()` anchors the offset to the bone's rest pose and carries it through `pose * rest⁻¹`, which is the head's movement away from rest, so the beams sit on the face and follow it through a clip without anything having to know which way the bone happens to point. The numbers themselves are measured off each body by `dev/_eye_probe.tscn` — the front of the head at eye height, and for the settler the goggles, which are worn on the eyes and so state the eye line rather than estimating it. Both now sit 2 mm inside the skin. Damage runs at 10 Hz: a `damage_capsule` along the segment cuts everything standing in the beam, and a `damage_sphere` at the landing point takes the larger share. The ray that finds that landing point **passes through** plant colliders — up to eight of them — because a beam stopped by the first tree trunk is not a beam that cuts through a wood; the trunk is damaged by the capsule like everything else in the line, and the beam carries on to the ground. Sustained fire commits a shallow `GROOVE` scar, about 2 m across and 0.2 m deep, which is broad enough to register on a 1.5 m vertex grid. It refuses to fire while submerged and plays no animation clip, only the beams and the light.

### Meteor Punch

A stance rather than a thing standing next to the movement code: `Stance.METEOR` sits beside `HERO` and `CRASH` with its own `_meteor_move`. The launch takes whichever is larger, the speed already carried or 60 m/s, and accelerates toward 200 m/s along the look direction for 50 m. A 4 m cylinder swept from the fist feeds a damage volume every tick — swept rather than stamped, because at 200 m/s the fist covers three metres between ticks and a stamp leaves the flora in between standing. Flora is resolved but its answer is thrown away: a punch that could be slowed by a hedge is not a punch.

Thrown from the air it is a dive, and the ground it hits opens as a `BOWL` about 6 m across and 2.5 m deep — more if it arrives faster, of which more below. Thrown from the feet it is a flat charge: the body lifts clear of the ground it launched off, and a surface only counts as struck if it **leans back into** the punch, since a flat charge grazes the floor it is travelling over on every tick and stopping on that would end the move where it started. Spend the reach with nothing hit and a dive returns to flight while a ground charge falls out of the sky and cuts a `CONE` ahead of its feet. Either ending hands off to `Stance.HERO`, whose pose and camera blend already existed for steep flight landings.

**Diving at the planet is the case the numbers were all written against.** Flight tops out at 1000 m/s, five times the punch's own 200, and thrown at that speed the move used to fire and then quietly not happen — you arrived on the ground with no crater. Three separate things had to be true for that, and all three were:

- The catalogue's top speed was read as a **ceiling**. `move_toward` toward 200 m/s from an 800 m/s dive is a brake, so the punch spent itself slowing the player down. It is a floor now: the punch can always reach the quoted speed under its own power and never takes speed away from someone who brought their own.
- The fifty-metre reach was treated as a **lifetime**. At 600 m/s that is a twelfth of a second, so a dive from any real height spent its reach in the first fifty metres of the fall, handed the flight back, and came down as an ordinary landing. Reach is how far the punch carries under power, not how long it is allowed to last: a punch thrown out across the sky still gives the flight back when it runs out, but one aimed at the planet commits and rides it in. Committed by *time* to the ground rather than by distance — a second and a half of flight — because that is the quantity that scales with the thing it is about.
- Arrival was only ever noticed as a **slide collision**. At flight speed the body crosses sixteen metres in a frame, straight through a chunk collider without generating one. `_catch_ground`'s swept test already caught the tunnelling and quietly planted the body on the surface; the punch just was not listening to it. It is an arrival now, filtered by the same facing test a slide contact gets so a flat charge still skims the ground it is travelling over.

The hole then scales with the speed it was dug at, `sqrt` of the ratio to the quoted top speed and capped at twice — 12 m across and 5 m deep at the top end. Square root rather than linear because that is roughly how a real impact scales, and because the crater's footprint is terrain that has to be rebuilt: the cap keeps the biggest hole to four times the area rather than twenty-five. It costs almost nothing in practice — 28.6 ms against the ordinary punch's 27.8 — because the resolvability gate below means a wider mark still only invalidates the chunks fine enough to draw it.

Landing in the hole took two more things than having cut it, and both were the same mistake in different places: something describing ground that no longer existed. The height field drops the moment the scar is registered, but the **collider** is generated from the mesh and was only replaced when the rebuild landed a few frames later, so the body spent those frames standing on the surface it had just removed and then fell the crater's depth when the new collider arrived. Marking a chunk stale now retires its collider immediately; a mesh may lag the field by a frame without anyone noticing, but the thing bodies stand on may not, and the height-field guard is a floor in the meantime. The other half is that nothing pulled the body *down*. `_catch_ground` only ever pushes a body out of ground it has ended up inside, and for ordinary terrain that is right — ground falling away from under you is just falling. A crater is the one case where the ground moving is the point, so a landed punch watches for its own hole and plants the feet on it, over a window rather than in one go, because a host cuts the hole on the frame it asks and a client is granted it a round trip later.

**The boss digs craters too, and got caught in his own by the far end of that same disagreement.** A chunk's collider is a triangulation of the height field, so the two never quite agree, and the sag of one chord across a curve is the size of the error: inside a crater bowl — the sharpest thing anything cuts at the metre and a half chunks are built at — the flat chords stand a quarter of a metre *above* the curve they cross. Bigfoot carries no weight of his own, every state he has sets a velocity along the surface, and `_snap_to_ground` used to keep him on the ground by setting his distance from the planet's middle to the field's answer once a tick. On open ground that is invisible. Inside his own crater it planted him a quarter of a metre inside the wall on every tick, and the solver spent each following frame pushing him back out along a normal that points up and inward — against the direction he was leaving in, and worth most of a stride at a run. He would climb to about seven metres from the middle of a hole ten metres across, at a full sprint, and run there until the fight ended. The way down is a swept `move_and_collide` now, so it stops on the ground that is there rather than on the ground the field describes; the way up is still a teleport, because a body that has gone through the world has nothing left to sweep against, but it waits for a gap deeper than a chord can explain. Four of six craters held him before that and none do after. The runtime suite walks him out of a real one, and the headless suite stands him on a plate above the field, which is the same claim without needing a chunk to have built.

The pose is `MeteorFly` in `assets/source/blender/build_animations.py`, authored upright like the other two flight clips so that the game's own forward lean is what turns a raised arm into a punch. It leans and cross-fades far faster than a flight does: fifty metres are gone in under a second, and the flight's own easing would spend most of that standing the body back up in mid-air.

Ahead of the fist is the shock — `game/abilities/meteor_shock.gd` and `shaders/vivid/vivid_shock.gdshader`, a red bow wave standing off the punch the way a vapour cone stands off a plane going through the sound barrier. **Its radius is the fist's damage radius**, taken from the same constant, so what the player sees coming is exactly what the punch is about to cut and there is no second number to keep in step. The surface is a paraboloid built in code rather than a `SphereMesh`, because the shader places its travelling bands and both end fades by how far along the shell a fragment is and that has to be a number this side decides — and because a paraboloid is the right shape anyway, rounder at the nose than a cone and flatter at the skirt than a sphere. How far it is drawn out along the travel direction comes from the speed, so the shape itself reads as acceleration over the third of the reach the punch spends getting up to two hundred metres a second.

Almost all of the look is one Fresnel term. A shock is a surface, not a volume: face on there is nothing to see, and edge on you are looking through metres of squeezed air, which is why it reads as a bright rim around a clear middle — and why an eight-metre shell can sit between the player and the world without hiding any of it. The trailing circle is drawn separately from that, because on a shell this wide the Fresnel alone lights only the two points of the rim that happen to be edge on, and the ring is what the shape is read from when the camera is behind the punch, which is where the camera nearly always is. Blending is premultiplied alpha rather than additive for the reason the laser is two passes: additive alone disappears against bright ground, of which this planet is mostly made.

Like `LaserBeams`, it is driven from the player's presentation pass rather than from the ability, and for the same reason — the ability only exists on the machine that threw the punch. `Stance.METEOR` replicates like any other stance, so a remote punch is drawn by exactly the same code as a local one with nothing added to the wire. It is aimed along the velocity rather than the launch direction, which matters only at the one moment the two disagree: a ground charge that has run out of reach and started to fall wants its shock in front of where it is actually going.

### Over the network

Craters are few and cheap, so they are sent whole: any peer asks via `rpc_id(1)`, the host validates and broadcasts, and a client does not cut its own ground while it waits. Flora is the opposite — far too many instances to name — so what replicates is the **effect volume**, applied by every peer to its own deterministic flora, with the host additionally confirming the handful of break keys a few times a second in case they disagreed. Both the scar list and the accumulated breaks ride along in the join snapshot, so a late arrival sees the same battered ground.

### Checking it

Three headless suites and one that puts a real socket between two peers:

```powershell
godot --headless --path . dev/_ability_model_test.tscn
godot --headless --path . dev/_flora_damage_test.tscn
godot --headless --path . dev/_terrain_scar_test.tscn
godot --headless --path . dev/_planet_cover_test.tscn
godot --headless --path . dev/_ability_net_test.tscn
```

The model test covers the catalogue, the stat formatting, slot filters, cooldowns and the stance and underwater gating. The flora test proves the migrated health reproduces every previous break speed exactly, then streams real cover in and cuts it with a beam and a blast. The scar test is the one worth reading: it checks that the crater is in the *same* height field the mesh, the collider and the player's ground guard all use, which is a claim about the live planet rather than about a data structure. It then throws two real punches. One from a standing start, measured against the cratered field on the frame it lands and again once the rebuilt collider has arrived — the fall into one's own hole showed up as 1.7 m out on the first of those and 1.5 m lost between them. One out of a 600 m/s dive from 400 m up, which is the case that used to hand the flight back and land with no crater at all. That second one is worth reading for what it has to assert *before* the interesting part: a punch thrown from anything but a flight takes the other branch of a spent reach and lands whatever the flight branch does, so without a check that the player is actually flying, the test passes against the bug. Last it holds the beam down for a 260-frame sweep and watches the ground all round the player: every sample point still drawn, the eye never under the surface, and `floorless` never off zero. The sweep is what the standing single-scar case cannot show, because the fault only appears when rebuilds overlap one another. The net test runs a host, a client and a late joiner as three branches in one process and sends everything across ENet.

`dev/_planet_cover_test.tscn` answers the same question from the other side, and cheaply. It flies a viewer over a real planet fast enough to keep the build pool behind, and after every frame requires each of the six faces to be covered — drawn by its own mesh, or wholly by its descendants. It asks the scene graph rather than the framebuffer, so it costs seventeen seconds and does not perturb what it is measuring, and it reads coverage as a property rather than agreeing with `_show` about how coverage is reached. It earned its place immediately: memoizing that walk introduced a fault where a chunk hidden because a *sibling* was still building went on claiming to cover its own ground, so the walk that finally saw the sibling arrive stood the parent aside for children that were not drawn. With the fault in, this reports every one of 1,020 frames uncovered; with it out, none.

Watching a *rendered* sweep for the same thing was tried and thrown away, and the reason is worth keeping. Graded against the real sky it reported sixty holes that were all one patch of purple desert flowers, the sky here being much the same mauve; repainting the background a flat magenta fixed that and left it reporting nothing at all — including on a run with the visibility fault deliberately put back, and again with the quadtree walk slowed to 5 Hz to stretch the gap to a quarter of a second. Reading the framebuffer back stalls the harness below the rate it is trying to sample. A test that passes with a known fault in front of it is worse than no test, because its pass is the thing that stops you looking.

The visual half is `dev/_ability_shot.tscn`, which is not headless because the dummy renderer never draws a frame:

```powershell
godot --path . dev/_ability_shot.tscn
```

It photographs both abilities close up and at the distance they are played at, plus the mark each leaves once the effect is over. Each also gets a shot from off to one side, which is not a gameplay view and is not meant to be: the game is played from behind the player's own head, and that is the one angle at which a beam fired from that head is a dot rather than a line.

### What they cost

`dev/_ability_perf_test.tscn` measures the frame while an ability is being used against the same view standing still, and prices each of the pieces on its own, because a frame time says something is wrong and never what:

```powershell
godot --path . dev/_ability_perf_test.tscn
```

Both abilities now run at the idle frame cost, with one spike left at the moment a crater forms. Getting there was four things, and the first was worth more than the other three together:

**A mark only invalidates ground fine enough to draw it.** Every scar already fades out at vertex spacings too coarse to resolve it, which is what stops a two-metre burn aliasing into a spike. But `mark_region_stale` was marking every chunk whose footprint contained the burn — including the ancestors, up to root patches tens of thousands of vertices across — and `needs_script_build` was then routing each of those onto the per-vertex GDScript path to compute, slowly, the exact terrain it already had. One 2 m laser burn cost **550 ms of worker time** and a 64 ms frame, four times a second while the beam was held. Both now take the chunk's spacing into account, so a burn costs the one or two chunks that can show it. Average chunk build time across a session went from 6.9 ms to 1.6 ms.

**Plant roots are cached where the damage sweep can read them.** `MultiMesh.buffer` hands out a copy through the rendering server, and the volume walk was fetching one per stand just to ask whether anything was in range, which for almost every stand it was not. `Tile.roots` keeps the origins alongside the existing `glow_points` cache, so the question is answered without asking the server at all. Nothing moves a standing plant, so the cache holds until the tile is re-sown.

**And the buffer itself is never read back.** The paragraph above used to end by saying the buffer was fetched once a plant had actually been hit, which sounded like the cheap half of the problem and was in fact the expensive one. That getter is not a copy — it is a **round trip**: it has to catch up with the render thread before it can answer, and the wait is roughly the same whether the stand holds nine plants or nine thousand. Measured against this world it is about half a millisecond a call, and a volume dragged along the ground overlaps tens of stands: one tick of a meteor charge spent **16 ms doing nothing but waiting**, and the worst offenders were the fields holding the *fewest* plants, since a colony of three trees per tile pays the same half millisecond as a tile of five thousand blades of grass. `Tile.rows` now keeps what was uploaded, on this side of the server, and `_rows_of` is the only way in. The setter has no such cost — it queues the upload and returns — so writes are unchanged. A charge tick went from 16 ms to 7 ms, a trample stride from 9 ms to 0.5 ms, and a meteor landing over standing jungle from 38 ms to 14 ms. It costs about 38 MB of the 495 MB the session holds, nearly all of it the two grass fields, which is the price of not asking a question whose answer we already knew.

**None of which was visible headless, and that is the part worth remembering.** Headless streams a few hundred plants where a real session carries hundreds of thousands, and it has no render thread to wait for. Between them those two facts understated everything above by roughly fifty times, and the flora budgets in `dev/_bigfoot_perf_test.tscn` were being met for months by a run that was not touching a jungle at all. Run that suite both ways and believe the graphical one for anything involving cover.

**The rejection tests are arithmetic.** A volume is offered to seventeen fields holding three thousand streamed tiles between them, and cuts a dozen plants, so what matters is the cost of turning things away rather than the cost of the ones that stay. Tiles are rejected against the volume's bounding sphere before the capsule maths, plants against a squared distance that needs neither their height nor their up vector, and the whole flower-tree colony against one sphere. A beam volume went from 4.8 ms to 1.6 ms and a fist volume from 3.7 ms to 0.7 ms.

**The fist deals damage on a clock, not every tick.** The laser always ran its damage at 10 Hz because each turn is also a packet; the punch was sweeping at 60 Hz, which was eight milliseconds a frame for the whole flight. It is 20 Hz now, and since the volume is swept from where the fist was to where it is, a slower clock makes each capsule longer rather than leaving gaps. Single-player sessions also stopped serialising every one of those ticks through the RPC layer to deliver them back to themselves — an offline peer is still a peer, so `has_multiplayer_peer()` was the wrong question.

What is left is a single ~27 ms frame when a meteor crater lands, which is the terrain genuinely rebuilding: twelve chunks, their collision shapes, and the meshes going to the GPU. It is one dropped frame on the most violent thing in the game.

## Meeps and the colony

Press **E** at the colony ship and the scrollable city panel opens. **RELEASE SETTLERS** puts six rigged Meeps on the grass and they get to work: they fell the trees around the lander for biomass, spend it raising a cloner, and once the cloner is up they walk into it and come out as more of themselves, which buys the town more hands to cut more trees. Their source creature is `assets/source/meshmaker/meep.blend`; the deterministic build gives it a 23-bone skeleton, `Idle`, `Walk`, `Run` and `Build` actions, external colour paint and the VAT exports used by the population renderer. **ADD 100 BIOMASS** grants the city one hundred even when the player carries none, while **ADD ALL** transfers the player's actual carried supply into the same construction bank. Everything under those buttons is built to end up as a planet of towns rather than as one town, so nothing here knows where Vacationer's Landing is: a second lander dropped anywhere gets its own colony by carrying its own `colony_site` name.

| Script | Holds |
| --- | --- |
| `game/meeps/meep_colonies.gd` | The registry under `Planet`: founding a site, releasing a wave, the residency line, and the joiner snapshot |
| `game/meeps/meep_colony.gd` | One settlement — the population, the tick, the draw call, and damage on their behalf |
| `game/meeps/meep_city_ledger.gd` | The same settlement with nobody near it: a few dozen scalars integrating the same rates |
| `game/meeps/meep_city_plan.gd` | The terrain-aware founding blueprint: district shapes, parks, ordered lots and street skeletons |
| `game/meeps/meep_region_plan.gd` | One deterministic 2 m ownership grid for every nearby cluster of cities |
| `game/meeps/meep_border_walls.gd` | Shared paid wall contracts, deterministic gates, presentation and collision |
| `game/meeps/meep_distant_cities.gd` | Every unwatched town on the planet, as one `MultiMesh` of massing boxes |
| `game/meeps/meep_site.gd` | The town's own flat map: an azimuthal-equidistant frame pinned to its centre |
| `game/meeps/meep_grid.gd` | 192×192 2 m cells over 384 m, classified as walkable, steep, shallow/deep water or void, plus constructed-surface height |
| `game/meeps/meep_claim.gd` | The boundary: a terrain-shaped flood clipped by radius and neighbouring-city territory |
| `game/meeps/meep_boundary_wall.gd` | That boundary, as one purple `MultiMesh` |
| `game/meeps/meep_flow_field.gd` | One cost field per destination, shared by everyone walking to it |
| `game/props/settlement_ship.gd` | Deterministic replicated expedition flight and the landed child-city anchor |
| `game/meeps/meep_tasks.gd` | The job board: what wants doing, and how many may do it |
| `game/meeps/meep_structures.gd` | What they have built: footprints, construction, one `MultiMesh` per kind, a pool of colliders |
| `game/meeps/meep_roads.gd` | Their streets: packed grid paths, terrain-conforming concrete, black edges and cheaper routing |
| `game/meeps/meep_pick_proxy.gd` | Eight collision bodies, lent to the nearest Meeps so E works on one |
| `game/meeps/meep_block_proxy.gd` | Thirty-two nearby capsule bodies on the dedicated crowd layer, lent so the player cannot walk through them |
| `game/meeps/meep_stats.gd` | A settler's numbers |
| `assets/source/blender/build_meep.py` | Deterministic rig, four actions, paint/UVs, skeletal GLB, VAT clips, manifest and preview build |
| `ui/city/city_menu.gd` | Two-tab city panel: controls/upgrades plus the living roster and memorial |
| `ui/city/meep_roster_grid.gd` | Childless three-column tile canvas for hundreds of living or dead Meeps |

**A Meep is a row, not a node.** A settler is one index across packed arrays and every resident in a colony is drawn by one `MultiMesh`, which is the bargain `GroundCover` makes for three hundred thousand plants rather than the one `FaunaMob` makes for fourteen creatures. The editable work asset keeps its real armature and actions, but the four poses are baked into position textures; one shader chooses the clip, phase and upgrade-scaled playback rate from `INSTANCE_CUSTOM`, so a visible crowd remains one draw instead of thousands of skeletons and animation players. The same shader samples the deterministic `meep_paint.png` through `TEXCOORD_0`, retains `COLOR_0` semantic regions and uses paint alpha only for the broad night-glow markings.

The row design does not mean ghosts. Meeps walk on the analytical height field and keep out of holes by consulting the town grid, while a fixed 2 m spatial index lets each mover inspect only the surrounding 3×3 cells, separate from nearby residents and consistently pass on the right shoulder. Thirty-two upright capsule bodies follow the nearest visible Meeps on a dedicated collision layer, enough for the local player to slide around a crowd without turning the whole population into physics nodes. Eight overlapping pick capsules remain on their isolated interaction layer; both proxy kinds forward the same name, activity and health prompt, so whichever ray result wins still identifies the right resident.

**The boundary is derived, not a growing circle.** Founding bakes one deterministic, terrain-aware city plan from the site's seed. Its compact permit mask starts with the landing district and adds a connected shaped district only when queued construction needs one of that district's lots; when no building needs land, the border stops. The host advances an exact floating-point reach toward that district while the claim and visible wall add only the new two-metre band. Additive district activation seeds its lobe from the existing boundary instead of re-flooding all 36,864 navigation cells. A compact offscreen city advances the same request arithmetically, so streaming out cannot stop demanded growth. Terrain still wins: the flood cannot cross a chasm, steep hill or shoreline until Bridges or Coasts supplies the relevant route. Border speed is automatic: population adds a bounded survey bonus to the base rate, and there is no border-speed purchase.

**Nearby cities share one regional answer.** When maximum growth envelopes can meet, the registry samples one 2 m tangent grid and solves a deterministic multi-source arrival-time flood off-thread. Forecast population growth and expansion speed give faster-growing cities more undeveloped room, while every existing claim, road and building is an immutable owner anchor; no replan confiscates developed land and no cell can belong to two cities. An 8 m setback on each side leaves breathing room at the seam. A settlement landing or Bridges/Coasts purchase queues one coalesced solve immediately. Population forecasts are audited every thirty seconds, but must stay more than 25% wrong for two minutes and pass a five-minute regional cooldown before another solve; only significant overlapping terrain deformation queues the same bounded work. Region plans, forecast history and links are saved once at registry scope and sent reliably to late joiners, while each city carries only its region ID and revision.

**A reached seam becomes shared infrastructure.** Either city can reserve a planned span and the first builder pays once; one global progress record prevents the neighbour from posting or charging a duplicate. Builders work the same contract from their own claim, and completion raises a visible, collidable wall with deterministic road-aligned player gates. The purple provisional marker disappears beneath completed spans. Completed walls resettle after terrain rebakes, while superseded unfinished contracts reroute and refund atomically. Roads, claims, lots and structure placement all enforce the same owner and setback masks during the transition.

**Every city gets a different long-term shape at founding.** The seed selects grid boroughs, rings and spokes, organic branches, park courtyards or terraces, then scores nearby terrain for district centres and reserves the whole build order before the first cloner rises. Parks and future lots remain protected; planned trunks, loops, cross streets and connectors wake with their district, with streets widening through avenues, boulevards and grand boulevards as density rises. Meeps therefore fill coherent blocks instead of scattering houses randomly. Tier 0 keeps two-resident huts; later districts stage six-resident townhouses and sixteen-resident mid-rises before filling a real skyline grid with 360-resident skyscrapers, 640-resident mega towers and compact vertical arcologies. A maximum projection physically houses 12,000 Meeps while retaining seeded parks, civic gaps and multiple roadways instead of concentrating the population in one building. At least four generic 9×9 pads plus 12×12 and 15×15 pads are seed-distributed through ordinary districts rather than grouped into an upgrade quarter, covering every current civic commission while leaving larger future contracts without erasing parks or housing streets. The packed plan is saved and late-joined directly, survives terrain rebakes without regeneration, and costs nothing to rescan during ordinary construction. All forms still share construction crews, flora clearing, pooled collision, road connection and replication.

**Housing is capacity plus explicit deeds.** Every completed residential site carries floors, target floors, slots and upgrade progress in an additive wire sidecar. Stable deed rows assign sibling pairs to the first parent-district vacancy before the cloner or planner creates more capacity, so a tower is functional housing rather than a large box counted like one hut. Building prompts show compact occupancy and only the first few resident names instead of forcing forty-eight names into one line. The compatibility Tier 0 allocation/completion booleans remain in snapshots beside generalized per-tier bitsets.

**Meeps grow into fixed roles.** Cloner births begin as roughly 55%-scale Children, play only on completed streets or the ship plaza, and grow smoothly to adult render, interaction, blocking and combat size over two minutes. At maturity each row permanently becomes a Builder, Homebody or Harvester by the largest deterministic quota deficit. Builders alone take road, structure, upgrade and shared-wall work; Homebodies visit cloners and otherwise stay home or walk; Harvesters gather flora, with up to four entering each biomass harvester as persistent indoor staff for a capped production bonus. A biomass stockpile wakes the already-reserved Builder pool and can fund the next authored housing lot without rerolling anyone's role. The compact ledger matures the same cohorts and applies the same role gates, so leaving a city cannot improve its economy.

**The city remembers its Meeps.** The second **MEEPS** tab has an **ALIVE / DEAD** segmented toggle and exactly three equal tiles per row. One custom-drawn, scroll-culled canvas handles the full 12,000-resident roster without creating a Control tree per resident; each placeholder-icon tile shows the immutable name, type and health plus extensible compact stats. Death does not compact the row: the resident moves into a permanent memorial with final age, elapsed game time since death and the named attacker/attack when the hit can identify them. Ages, roles, workplaces, health and mortality records survive settlement transfer, ledgers, saves, late joins and reliable death replication.

**Distance decides how precisely a Meep reads the ground, not whether its life continues.** Every resident of a resident city advances authoritatively whether or not a player is nearby: inside 120 m it reads the field at the spacing the terrain is actually drawn at, while outer and unseen bands read the town grid's cached height. Presentation chases visible poses every rendered frame at the resident's real walk/run and turn rates, so the host never displays simulation steps and clients use the same interpolation policy as ordinary fauna. Past 400 m a resident is not drawn, but it still plans, walks, harvests, builds, clones and finishes jobs at normal game speed. A maximum 12,000-resident city advances outdoor rows in bounded 1,024-row chunks; residents at home or staffing a workplace need no wandering decision, and dead/departed historical rows consume no work budget because each pass uses maintained role and visibility indices rather than scanning the whole history.

**A city nobody is anywhere near is arithmetic rather than settlers.** Six hundred kilobytes of navigation grid and a ten-hertz pass over every row is the right price for the town underfoot and an absurd one for a town on the other side of the world, so a city has two residency states. Beyond 900 m it is *distilled*: `MeepCityLedger` takes its population, bank, housing, tier, identities, deeds and its whole physical layout, the node is freed, and the town continues by integrating the same constants the settlers realise — role-gated mining/building/cloning, `plan_of(kind).cost` and `work`, `CLONE_COST`, the tier ceilings, and streets at `MeepRoads.COST_PER_CELL`. Existing named residents retain packed identity rows, but a legacy or synthetic city without that sidecar stays as four role counts plus child cohorts until its roster is requested or it reifies; a fifty-city scale tick never manufactures and scans ten thousand placeholder names. Inside 700 m it is *reified* back into an ordinary `MeepColony`, nearest first and six resident at a time. The gap between the two ranges is deliberate: a player pacing a boundary would otherwise rebuild a navigation grid every few seconds.

The founding blueprint also gives the ledger a cheap answer to where future work belongs. An unwatched city consumes the same ordered lot queue, requests the same next district, and marks a finished lot owed; on return the resident planner realizes that promised building at its saved location instead of inventing a new layout. Population, biomass, housing, tier, border demand and physical build order therefore stay continuous while away. The ledger still stores completed structures as compact owed counts until their meshes and collision can be reified. An unwatched city remains tiny beside a resident town's 150-600 KiB grid and rows, so a planet of settled sites is an unremarkable save file, and all of them draw as one `MultiMesh` of massing boxes with shadows off, dithered out as the player approaches the real thing.

Three rates in the ledger cannot be borrowed from the colony because the colony never states them: what a miner actually brings home, what a builder actually delivers, and how much street a town lays per building. Those are measured from the real simulation by `dev/_scale_test.gd` and printed beside the shipped constants on every run, so retuning the walk speed or the flower yield is followed by reading a line and typing a number.

**Their working pace is five metres a second.** The first value was 2.4, less than a third of the player's walk, which turned a hundred-metre town into a minute and a half of watching every round trip before the work began. Five still leaves a Meep easy to catch beside a player walking at nine, but makes the work rather than the commute the thing a player sees. The authored Walk and Run loops put their planted-foot phase on the advancing half-cycle, so runtime plays those two loops in reverse time: planted feet now travel backward against forward world displacement instead of producing a moonwalk, while Idle and Build keep their authored direction. The close-detail obstacle ray follows the terrain height at both its ends: aiming it horizontally from the low end of an ordinary slope made the ray enter the hillside, call the ground a wall, and could leave a watched crew permanently short of its final hut while the identical unwatched town completed.

**Clients rebuild the town rather than being sent it.** The height field is identical on every peer, so a client bakes its own grid, fills its own claim and raises its own wall from the founding facts alone. What travels is the part that is genuinely a decision: where each Meep is, ten times a second, for the ones somebody is near, with the population, the bank and a byte of state per settler riding along in the same packet. Client presentation interpolates those targets every physics frame, as fauna does, rather than showing the packet cadence. The state is included because a client that did not know which Meeps are inside the cloner would draw them standing in its wall. Where a building **is** cannot be recomputed that way, because it was a choice, so placements go reliably with additive form/upgrade/deed sidecars; completed road cells retain an additive width-class sidecar. How far construction has advanced rides the frequent packet with everything else, since a wrong construction fraction corrects itself a tenth of a second later.

**The colony takes hits for everyone in it.** It joins the `combatants` group as one allied node, then resolves player and enemy damage against the feet, torso and head points of each 1.2 m upright capsule. Every settler starts with 24 health, shown with its name and activity when inspected. A nonlethal hit releases its job and switches it to the `Run`-animated flee state; a lethal hit clears its job and deed, removes it from rendering and both collider pools, and replicates the death from the host. Every accepted hit also publishes a networked number anchored above that exact row: player damage uses the ordinary outgoing colour, mob damage is red, and stable colony/row keys prevent simultaneous residents from merging into one label. Only clients close enough and facing the event draw it, so an offscreen wildlife attack cannot put a stray number in the middle of the HUD. Fauna horn charges and body slaps use the shared combat-volume path, contact quills select the nearest resident in reach, and spit sweeps stop at the nearest actual Meep row rather than at the colony's coarse centre. The town-wide bounds are only a cheap offer test, so they remain generous without applying falloff against a centre nobody occupied.

**The economy is one number, and it comes out of the flora inside the wall.** A Meep sent to mine walks to the nearest harvestable plant whose root and work cell are both in the dynamic claim, works for two seconds, and asks that field to harvest the exact root it selected. Success cannot come from grass or a neighbouring plant merely absorbing the same damage volume. The break still enters the world's flora ledger, so the selected mesh and collider vanish immediately, every client receives the result, and it stays absent after streaming. The field owns the payout: a giant flower-tree scales its fourteen-per-metre yield with real height, while a meadow flower pays four per metre. Targets are taken nearest-first, so a town eats its way outward and the clearing around the lander is the resource ledger.

**The player can carry that same biomass.** Running hard enough to break a collidable plant pays a height-scaled yield into `PlayerStats.BIOMASS`. Colony-enabled fields retain their authored rate; other breakable biome cover pays a conservative one unit per metre without becoming a Meep timber source. Grass without impact collision and unbreakable monumental growth still pay nothing because the player did not break an instance. The Hero page's Stats panel lists the carried total automatically, and the break raises a small green `+X` through the same local number layer damage uses. The movement owner sends the plant's deterministic break key to the host, which deduplicates it, computes the payout, updates the authoritative player bank and confirms the flora break. At the ship, depositing debits that bank before crediting the colony, so stale or repeated presses cannot duplicate a unit.

**Streamed flowers can still be honest offscreen resources.** `GroundCover.standing_near` records the deterministic tile, species and instance index behind every root it offers. A Meep keeps that stable identity with its job. If the player leaves and the tile retires before the worker arrives, `harvest_at` marks the same instance broken in the persistent ledger without rebuilding the visual tile; deterministic resowing applies that ledger before the flower can reappear. A removed instance is micro-scaled rather than given a singular transform, its emission channels are shut off, and a glow anchor owned by it is excluded from the bounded light pool, so neither a pulsing point nor a pulsing patch of bare ground survives the flower. `harvest_yield = 0` opts a field out, which excludes `GlobalGrass`, distant filler, reefs and unapproved biome growth without guessing from a resource name. `LandingFlowers` explicitly opts in. Roughly three thousand of its flowers fall inside this claim, so continued Tier 0 growth is funded by many visible small harvests rather than by turning five in-boundary trees into implausibly valuable jackpots.

**The bank is two numbers, because a job that has not started has already been paid for.** Posting a building reserves its cost against `committed` rather than spending it; the reservation is only drawn down as the thing goes up, and cancelling a job hands it back. Without that the planner would happily queue three huts against one hut's worth of biomass and stall with all three at nine-tenths, which is the failure mode that looks like a bug and is arithmetic. The panel shows both, so biomass sitting in `committed` reads as *promised* rather than as missing.

**City upgrades are exact host-authoritative purchases, not client-side toggles.** The fixed +100 button is authoritative too: its request carries no amount, so the host either rejects it for distance/session state or grants exactly one hundred without touching player inventory. Five Build Speed levels cost 80, 130, 210, 340 and 550 biomass and add ten percent work rate each; five Meep Move Speed levels use the same costs and add eight percent movement each. The multipliers belong to one colony rather than its shared `MeepStats`, so upgrading a capital cannot accelerate every child settlement. Border Expansion Rate, Bridges, Coasts, Hat House, Abilities House, Biomass Harvester and Send New Settlement use append-only purchase IDs: the panel sends one exact ID, while the host rechecks proximity, prerequisites and uncommitted biomass and supplies the canonical price. Repeating a packet cannot buy the next level. Instant unlocks spend immediately; a physical specialty commission holds its cost until Meep construction completes, including while it waits for future border space; an expedition purchase arms one launch token. Paid, requested and built flags, speed and expansion levels, continuous radius, token count, bank and held biomass travel in reliable live state and late-join snapshots.

**The housed starter city comes before commissioned work; after thirty-two living settlers, the order reverses.** A Hat House, Abilities House or Biomass Harvester may be paid for earlier, but it reports `QUEUED — STARTS AT 32 SETTLERS` and does not pull builders away from the cloner-and-housing runway. At the milestone the oldest commissioned project is pegged out first and its job priority outweighs routine work across even a future Tier 3 city; ordinary new houses pause while a legal project site exists. If the large footprint cannot fit, the purchase and held biomass remain queued as `WAITING FOR BORDER SPACE`, routine growth resumes, and the negative placement cache expires at the next boundary or road step. The green and blue houses occupy 6×6 cells and the pink harvester 9×9. Projects prefer the current outer development band, then use an unallocated inner civic gap that otherwise reads as a park. Completed projects enter the normal road, collision, flora-clearing and replication pipelines.

**A completed Biomass Harvester belongs to its city, not to the flora or workforce.** The host credits that colony's bank at one biomass per second even when nobody is watching, clamps any single stalled elapsed interval, and replicates the exact bank and lifetime output instead of deriving catch-up from wall-clock timestamps. Using the finished pink building opens its local report with current rate, lifetime production and the next permanent upgrade. Five append-only level purchases cost 500, 1000, 2000, 4000 and 8000 city biomass and add 0.5 per second each, reaching 3.5; the server accepts them only near that exact completed structure and only from uncommitted funds. Every child settlement keeps an independent machine, level and production total.

**Settlement expeditions transfer residents rather than copying them.** `SEND NEW SETTLEMENT` costs 1000 uncommitted parent-city biomass and becomes available only when three complete living sibling pairs exist. The authoritative purchase arms one launch token for the requesting peer and cannot be bought again while armed. Leaving the city panel enters a temporary landing reticle independent of the combat hotbar: its rectangular preview follows the planet surface, primary fire submits the normalized direction, and Escape only cancels aiming. Attack release, secondary ability, parry, interaction, holster and weapon-selection inputs are consumed while targeting; movement and camera look remain available. The host rechecks the owner at the parent ship, all six founders, a dry level 18×10 m footprint, the 150 m ship clearance, and enough centre separation that the permanent midpoint frontier cannot retract an existing claim. Rejected targets retain the token; accepted and replayed requests can produce only one immutable `settlement_N`.

**A valid launch leaves history in both cities.** The six parent rows release their jobs and deeds and become append-only `DEPARTED` records—never dead, simulated, drawn or counted—while their exact explicit names, former deed references and three mutual sibling links form replicated history and the child manifest. Vacant home prompts and dense-building resident lists can therefore name former owners without counting them, while those vacancies remain immediately available to the parent's normal vacancy-first cloning. A visible rectangular `SettlementShip` follows a deterministic eight-second spherical arc and has no collision in flight. Clients may visually reach its destination, but collision and interaction remain disabled until the reliable authoritative landing/founding RPC; a landed late-join snapshot carries that authority explicitly. The child starts with an independent bank and upgrades, a connected 70 m Tier 0 claim, and exactly those six founders. Its immutable network key stays separate from its moderated `Settlement N` display name; child menus can rename it near the landed ship, child reports name their parent, and parent reports list each direct child's display name, tier and living population. Live RPCs and late-join snapshots carry armed owner, lineage, identity/deed state and complete flight or landed state without founding twice.

**Buildings are rows too, and their footprint is the interesting part.** Each kind is one `MultiMesh` — a purple cube for the cloner, an orange box for a hut — and a finished one blocks its 3×3 of grid cells, so from then on it steers walkers and it stops the next building from being placed on top of it, using the same passability the chasm uses. Completing one also clears the flora under it and shoves any Meep standing inside it back onto open ground. The two completed footprints nearest a viewer are re-swept once a second, which catches finer streamed cover that did not exist when an unwatched building first went up without turning every distant town into recurring work. Twelve `MeepStructureProxy` colliders are lent to whichever finished structures are within 90 m of a player, on exactly the same argument as the Meep pick proxies: you can only walk into the ones you can see, and a planet of towns cannot afford a body per shed. They are still the physical walls, but now also answer the interaction ray; looking at a hut reports its two named owners and live `Occupied 0/2` count. Starter placement spirals outward from the ship, keeps every complete footprint outside a 20 m landing plaza, and refuses ground that is not level to within a metre. After the seventeen-structure starter core, the next plot is the valid one furthest from existing plots, with a slight outward tie-break; houses therefore reach the usable boundary instead of forming a ninety-box knot around the ship.

**Tier 0 fills a civic density, not every cell that can hold an orange cube.** It allocates one structure per 150 square metres of claimed terrain, never fewer than the seventeen-building housed starter and never more than forty-eight. The six-metre inter-building clearance, open landing plaza and unallocated majority of claim cells preserve room for parks, lookouts, wider future buildings and readable streets. Terrain can still end it earlier if a complete scan finds no level plot. Allocation and completion are separate replicated facts: the panel says `TIER 0` while final sites or roads remain and `TIER 0 — FILLED` only after every allocated structure and branch is complete.

**The cloner is the town's only way to grow, and housing is its limit.** Five Meeps fit inside at once with three more allowed to wait at the door; one goes in, twelve biomass goes with it, and a second later two come out. The landed wave of six is the sole exception to house-first growth. From then on every completed hut supports exactly two settlers: sibling pair N owns hut N, and an even population builds the next empty pair's house before either new place can be cloned into. Every occupied machine slot counts as future population, so simultaneous uses cannot overrun completed housing. The old 32-settler starter population is therefore already housed in sixteen huts rather than temporarily packed three to a hut; builders then continue reserving affordable outward homes while the cloner consumes only finished slots, until Tier 0 space is allocated and its final forty-seven sibling homes hold ninety-four residents.

**What a Meep does next is a choice between posted work, then a life at home.** The colony posts what it wants doing — cut that tree, raise that wall, use the cloner — with a priority and a limit on how many may take it, and an idle settler takes the best score it can see. That score is the priority converted into metres minus the metres it would have to walk, so a job worth twice as much is worth a hundred metres further, plus a few metres of jitter that are a property of the settler rather than of the moment. With no work, a resident alternates between going inside its own hut for a seven-to-sixteen-second wait and following a short connected walk along completed street cells. Its identity is deterministic from the colony seed and stable row index: every Meep has a unique given and family name in its look prompt, adjacent sibling rows share the family name, and deaths never compact those deeds. An empty growth runway keeps roughly half the settlers harvesting. As free biomass covers the next building, a road allowance and usable cloner slots, mining offers and their priority taper toward an eight-percent background crew with a one-job floor. A large player deposit therefore releases most of the town to build immediately, while that floor prevents a city from deadlocking when the donation is spent.

**Roads grow from completed buildings rather than from one global street grid.** Every finished structure becomes an anchor. Its doorway follows the colony's one asynchronously baked home field until it reaches existing concrete or the ship, reserves those cells so the next building cannot be put over them, and posts one shared paving job. Tier 1 local streets, Tier 2 avenues and Tier 3 boulevards carry append-only width classes; each new connector renders, prices work and places lamps at its own width, while an old Tier 0 cell remains narrow where a boulevard meets it. Sharing the home field matters at mature scale, and one of the two worker lanes is reserved for rebuilding it so many individual routes home cannot starve the final district's road plan. Two paving branches are allowed in the starter town, rising by one per sixteen settlers to six. A completed road writes `FLAG_ROAD` into its two-metre cells and costs two routing units against dirt's ten. Walks home, trips to the cloner, builders and paving crews consult that cost field; mining remains direct for the final off-road trip to a plant.

**Bridge and coast purchases unlock city planning, not instant geometry.** Bridges still cost 150 and Coasts 175 biomass and remain permanent append-only city flags. Once bought, the colony AI scans only its connected frontier. It first paves a land approach back to existing concrete, then posts a higher-cost Meep road job for the shortest valid unsupported crossing. `BRIDGE` decks span void to reachable flat ground; `RAMP` decks may climb a steep riser only while the endpoint-to-endpoint grade stays bounded. Unsupported void and steep cells remain absent from both navigation and claim until that job physically finishes. Completion restores the surface flag and exact deck heights, rebuilds the connected claim, boundary, timber survey and route fields, and can therefore gain land only in the direction the new crossing actually connects.

**Coasts distinguish shallow seabed from deep water.** Raw water from the shoreline down to five metres is append-only `SHALLOW`; deeper cells remain `WATER`. Neither is walkable. Once Coasts is unlocked, connected shallow cells may belong to the claim before construction so the dock planner can grow through them, but routes still reject every undecked cell. Bridges never grant the equivalent exception: void and steep cells enter a connected claim only after a completed `FLAG_SURFACE` crossing allows reflood to reach them and the far land. The coast planner grows short organic pier branches from an existing walkable shore, adds a 3×3 dock platform only where every supporting cell is claimed shallow, and fixes its deck at water level. A completed collidable `DOCK` surface makes those cells walkable. Every dock cell also contributes one deterministic square pile from deck underside to cached seabed; all piles share one mesh/collision batch and never become navigation cells. Four-resident `DOCK_HUT` forms are appended after the land residence kinds and can be placed only on a complete platform outside the ship clearing; they use normal deeds, construction, pooled structure collision, road connection and snapshots, but do not pretend there is flora to clear under the pier.

**The concrete follows the ground.** `MeepRoads` rebuilds two small meshes only when a branch completes: a warm-grey ribbon sampled at the terrain height of every vertex and a slightly wider black ribbon underneath it. The overlap hides internal joins and leaves the requested dark edge along the outside, without spending a scar per paving cell or adding a node per slab. Paving clears flora through `DamageHit`, and while a viewer is near, four road cells nearest that viewer are swept every fifth of a second. That last pass matters because ground cover is streamed: a distant town can finish a street before the grass that would have occupied it exists. The far-distance filler grass still ignores damage just as it ignores craters, but the gameplay cover is gone by the time somebody can inspect the road.

The upper road/deck ribbon is also the single nearby-enabled `ConcavePolygonShape3D` source, so ordinary roads now collide and elevated decks have exactly the same triangles underfoot that are visible. Non-land cells carry an additive sidecar of cell index, `LAND/BRIDGE/RAMP/DOCK` kind and millimetre deck height beside the existing road-width snapshot. Late joiners restore that metadata before rebuilding collision and routing; old land-only snapshots still decode entirely as `LAND`.

Snapshot restore always queues one final coalesced ground pass after structures, forms, deeds, roads and surface metadata have all arrived, including expanded land-only towns. If a founding bake is already running, the request waits behind it rather than racing it. Dense residences keep their look prompt to title and occupancy; interaction opens a compact live resident roster, while ordinary huts retain their named-owner prompt. Nearby lending of structure and road collision remains unchanged.

**The paving crew leaves the lights behind.** Every fifth completed road cell deterministically receives a dark 3.6 m cylinder and a small warm-emissive cylinder on top, offset onto whichever kerb is clearer. Poles and heads are two `MultiMesh` draw calls for the whole town, and their cells are derived from the existing road snapshot plus the colony seed, so they add no replication payload. Twelve shadowless `OmniLight3D`s are lent to the nearest heads: they overlap across the street at night, fade before moving to another fixture, and return to zero in daylight. Distant streets retain readable emissive heads without paying for one real light node per lamp.

**Nothing about deciding what to do is allowed to cost a frame.** The planner runs every two seconds rather than every tick, and the flow field a job needs is baked on `WorkerThreadPool`, because a Dijkstra fill across sixteen thousand cells is not something to do between two frames — and it would happen at the worst possible moment, the instant a building is finished and everybody wants somewhere new to be. Until the field arrives the Meeps walk straight at the target and slide along whatever they bump into, which is a slightly worse route rather than a stutter. Twelve fields are kept, the least recently wanted is dropped, and two bakes are in flight at most; only one may be an individual destination, preserving the other lane for the shared road-planning field.

Refusing to build near mobs that have killed a settler is the next pass. The grid already carries the hazard byte and every flow field prices it, so that remains a writer rather than a pathfinding redesign.

```powershell
godot --headless --path . dev/_meep_test.tscn
godot --headless --path . dev/_meep_test.tscn -- --blueprint-only
godot --path . dev/_meep_test.tscn
godot --headless --path . dev/_scale_test.tscn
```

The headless half is the interesting one, because it asks the questions a screenshot cannot: the same seed and terrain produce a byte-exact founding plan; seed variation covers all five city styles; the plan reserves parks, street projects and enough ordered housing for 12,000 Meeps; demand opens only the next useful district; its non-radial claim exactly matches a full reference flood; an eight-plan setup batch remains bounded; and save, late-join, ledger and terrain-rebake round trips preserve opened districts and consumed lots. The real landing plan must retain skyscraper, mega-tower and arcology campuses, while one district activation stays under the frame-spike budget. It also checks that the grid finds the sea and crevasse, Bridges crosses the ship-side gap, structure/road flags and walls survive growth, dense footprints and capacities are exact, and form/deed/road-width sidecars round-trip. Synthetic frontier audits require unsupported void to reject a route before construction, a bridge and bounded ramp to reach the far level, shallow docks to stop before deep water, dock huts to use complete platforms, and collision triangles to match visible roads and decks. The world audit buys, cancels, resumes and launches a settlement token; rejects bad terrain, distance and owner claims; compares deterministic flight with a late joiner; lands a collidable ship; and verifies child-city identity, growth, lineage and replay-safe snapshots. The focused `--plan-only`, `--projection-only`, and `--megacity-only` runs isolate deterministic planning and physical 12,000-resident projection.

Then it lets the colony finish all of Tier 0 and audits the result as an economy rather than as a set of features: trees and exact streamed flowers disappear and stop being offered; harvesting continues after the old starter milestone; every settler after the landed wave has two-per-hut housing completed first; forty-eight structures spread into the outer claim while retaining most claimed ground for civic use; all forty-eight gain road branches; and cloning stops exactly at the resulting ninety-four places. Every full name is unique, each adjacent sibling pair shares a family and one hut, a pooled building collider reports both owners and occupancy, an owner can enter and leave that home, and generated leisure paths contain only adjacent completed road cells. Every road cell remains inside the dynamic claim and outside buildings, every derived lamp remains on one of those completed cells, and a joiner snapshot rebuilds both streets and lamps while carrying the authoritative Tier 0 completion state. The exact-flower probe also requires a non-singular microscopic hidden transform, zero emission channels and removal from pooled-light targeting. A representative run reaches the old starter population around fourteen simulated minutes and fills Tier 0 around twenty-three, which is why the harness advances colony time rather than making the suite wait in real time.

Run with a renderer it photographs the settlers at arm's length, the wall, the cloner, a road close enough to judge its concrete and black edge, the same street under its working night lights, the colony from gameplay distance, and the town from above. It requires the pooled lamps to cast at night and fade to zero at noon. It also asks the question headless cannot: whether finished construction is standing on bare ground, because the cover fields only sow tiles a viewer is near and a run with nobody in it has no grass to clear. It tries to clear one building and one road cell a second time and requires that neither has anything left to cut, while an identical control volume over standing cover still does.

The renderer-only tail is also the visual acceptance pass for city upgrades. After gameplay assertions finish, deterministic fixtures built by the production `MeepStructures`, `MeepRoads`, and `SettlementShip` classes save `city_hat_house.png`, `city_abilities_house.png`, `city_biomass_harvester.png`, `city_tier1_townhouse.png`, `city_tier2_midrise.png`, `city_tier3_skyscraper_blocks.png`, `city_bridge.png`, `city_ramp.png`, `city_dock_boardwalk.png`, `settlement_launch.png`, and `settlement_child_city.png` under `dev/captures/`. These fixtures use real planet/site projection, completed structure and road paths, pooled collision, surface metadata, dock piles, and the settlement flight transform. Bridge and ramp verification tries the classified landing grid and then 96 deterministic real-`PlanetShape` probes, printing the selected natural candidate; only if no production-valid crossing exists does it print and use the synthetic fallback. The dock independently requires a sunlit natural shallow-water site before falling back. Run the acceptance frame at 1600x900 with:

```powershell
godot --path . --rendering-method gl_compatibility --resolution 1600x900 dev/_meep_test.tscn
```

`dev/_scale_test.tscn` asks the questions that only appear at fifty towns. It stands up a planet of fifty two-hundred-settler ledgers and requires the settler total to be exactly ten thousand, a minute of their growth to lose nobody, the whole planet's arithmetic to cost well under a millisecond of CPU per simulated second, and one city to serialize inside four kilobytes. It checks the bucketed city-pad lookup in `PlanetShape` against the flat scan it replaced, over six thousand samples with fifty pads in the way, because that scan used to run per height sample. Then it runs one town both ways for twenty simulated minutes — real ground, real flora, real settlers walking to real trees on one side, arithmetic on the other — and requires the two to finish within a fifth of each other on population and on buildings, and the ledger's mining rate to be within 15% of what those settlers actually earned. Finally it walks away from that town and comes back: distil it, advance it ten minutes, reify it, and require the settlers it gained to be walking about and every building it banked to be standing finished on real ground. That is the reported bug as a check, and the pair of them is where the ledger's three measured rates come from.

Three things about it are deliberate, and all three exist because the reference is a live simulation rather than a number. It turns the colony's own physics tick off and steps the town by hand, since otherwise a fast machine would fit a different amount of extra town life alongside the loop and the measured rates would become a property of the hardware. It surveys the whole claim for timber before starting the clock, because `survey_harvestable` resolves a claim on worker threads a few cells at a time, and whether the first miners are told about a tree in the first minute or the fourth compounds through housing and cloning into a town half again as large — that alone was the difference between runs finishing at 32 settlers and at 48. And the tolerances are wide because what remains is irreducible: a warmed town still finishes anywhere between 36 and 40 settlers, so holding deterministic arithmetic to a tenth of one sample of that would be a test of the reference's variance rather than of the ledger. The rate check is the tight one, because it compares the constant against the thing it was measured from without twenty minutes of compounding in between.

```powershell
godot --path . dev/_settler_perf_test.tscn -- --save=Lag --seconds=30 --resolution=1920x1080
godot --path . dev/_settler_perf_test.tscn -- --cities=50
```

`dev/_settler_perf_test.tscn` is the other half: it replays a named sandbox save from its exact saved player transform, holds move-forward for a wall-clock span, and reports frame mean, p95, p99 and worst frame beside the resolution, render scale, MSAA and graphics settings the numbers came from, so two runs are comparable. `--cities=N` scatters unwatched towns over the whole planet, which is the population a save cannot describe — the towns in a save are the ones somebody walked to, all in one place. `--night` moves the saved daylight half an orbit; `--no-meeps`, `--no-meep-sim`, `--no-meep-present`, `--no-city-render`, `--no-shadows` and `--no-omni` attribute a frame to what is in it. The script's own header carries the current baselines. Unlike every other suite here it wants a window rather than `--headless`, because headless draws nothing at all — it still reports a useful CPU figure, but a framerate from it is not comparable to one measured with the pixels in it.

## Chat and voice

Both work anywhere a session is live. There is no separate waiting room in this template — hosting drops you straight into the world — so the two pieces live as autoloads rather than in a scene, show themselves whenever `NetworkManager.in_multiplayer_session()` is true, and go away again when you leave. They are on screen in the world, over the pause card, and would ride along into a lobby screen a project added later without being wired up again.

| Script | Holds |
| --- | --- |
| `core/chat_manager.gd` | The wire and the scrollback: sending, host validation, join and leave lines |
| `core/voice_chat.gd` | Push-to-talk: capture, compression, and a stream per talker |
| `ui/chat/chat_hud.gd` | The panel: the log, the line being typed, and who is talking |

**Enter** opens the line. Enter sends it, Escape throws it away — and Escape belongs to the field while it is open, so a half-typed message is not paid for with the pause menu. While the field has the keyboard the local player's controls are switched off: movement is polled rather than read from events, so a focused text field on its own would let W walk you away mid-sentence. Controls go back to what they were rather than to on, because chat can be opened over the inventory or a pause card that was already holding them.

The host is the authority on who said what. A client offers its line to the host, which paces it, moderates it with the same `core/text_moderation.gd` the lobby names use, and only then stamps it with the name from its own roster and sends it on, so a peer cannot put words in someone else's mouth. Someone arriving mid-conversation is handed the tail of the log; a blocked line is reported to its sender alone rather than repeated to the room.

**V**, held, talks. Godot ships no voice codec, so the compression here is deliberately plain: downmix, resample to 12 kHz, and one companded byte per sample on a square-law curve that spends its resolution on the quiet half of the range where speech lives. That costs 12 KB/s per talker for about 44 dB of signal to noise, and no dependencies. Packets are `unreliable_ordered`: a packet that arrives late is worth less than nothing, because waiting for it would delay everything behind it, so a lost one is left as a gap and the talker stays in real time.

Two details are load-bearing on the audio side. Capture runs on its own bus where the **order of the effects** keeps the microphone out of the speakers: the capture tap comes first and an amplifier at -80 dB comes after it, since muting that bus or pulling its volume down would silence the tap along with the output. And each talker is played through an `AudioStreamGenerator` fed from a short queue that holds back 100 ms before it starts — that prebuffer is what absorbs network jitter, and re-arming it when a talker goes quiet is what stops the next word arriving as a stutter. Voice plays on its own bus, so **Settings > Audio > Voice chat** rides on top of the master volume; the microphone needs `[audio] driver/enable_input` in `project.godot`, which is already set.

Voice is not positional: everyone in the session is heard at the same level wherever they are, which is what a co-op session usually wants. Making it spatial means moving the per-talker player to an `AudioStreamPlayer3D` on that peer's body, and deciding what should happen to a talker who has no body yet.

`dev/_comms_test.gd` drives both halves the way a player does, and measures the parts a screenshot cannot show:

```powershell
godot --path . dev/_comms_test.tscn
```

It types a line with real keystrokes and sends it, checks the body stays put while typing and walks again afterwards, checks V is a letter rather than the talk key while the field is open, and checks Escape closes the field without pausing — and, with the game already paused, that Escape closes the field and leaves it paused. Then it reports what the compression costs, plays a tone into the microphone bus to see it arrive at the capture tap at full level, holds the talk key over that tone to confirm audio is packetised at real time, feeds packets in as a second peer to watch a stream prime and drain, drives the real join and leave signals, and confirms leaving a session takes the panel, the scrollback and everyone's voice with it. Run it windowed: both halves need real devices.

That harness is one process with an offline peer, which makes it both ends of the wire at once and so cannot see the host doing its job. `dev/_chat_net_test.gd` is the other half, as a real client of a host in another process:

```powershell
godot --headless --path . -- --server --port=7777 --lobby-name="Chat Test"
godot --path . dev/_chat_net_test.tscn
```

It joins, waits for the announcement of its own arrival, says something, and checks the line comes back attributed to the name the **host** holds rather than one the client chose. Then it sends a burst to see the pacing drop most of it, and a line the moderation should stop, which comes back as a refusal addressed to nobody else.

## Multiplayer architecture

`SteamLobby` initializes GodotSteam, owns Steam lobby discovery/metadata, accepts friend-invite callbacks, and exposes the overlay invite dialog. `NetworkManager` owns the `SteamMultiplayerPeer`, admission, session state, scene changes, and the host-owned roster. `ChatManager` and `VoiceChat` are session-scoped in the same way and reject packets from peers that have not passed admission. Gameplay code talks to `NetworkManager`, not directly to the menu.

The host owns player spawning and validates/relays client movement snapshots. This starter is suitable for cooperative prototyping, but competitive games should replace snapshot validation with fully server-simulated input.

Hosting and starting are separate. Creating a Steam lobby opens a waiting room; connecting clients submit their profile and, for passworded lobbies, the password over Steam's encrypted transport. The host validates Steam membership and the password before adding that peer to the roster. Only the host can broadcast Start, which closes the lobby to late joins and opens the world for every admitted peer.

Public and passworded lobbies are discoverable in Steam's browser; friends-only lobbies are visible through Steam's relationship rules. Passwords are never lobby metadata. `+connect_lobby` launch arguments and in-game `join_requested` callbacks both return to the same Join UI, where a private invite asks for its password before connecting.
