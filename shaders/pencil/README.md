# Colored pencil shader

A reusable stylized material for Godot 4.7: flat banded colour, procedural pencil
hatching that thickens as a surface darkens, a parallax offset applied only to the
strokes, and a separate sketchy silhouette pass. Everything is procedural, so no
textures need importing before it works.

## Files

| File | Role |
| --- | --- |
| `pencil_lib.gdshaderinc` | Shared noise, stroke, tonal-art-map and banding helpers |
| `pencil_surface.gdshader` | The surface: fill + hatching + parallax + paper grain |
| `sketch_outline.gdshader` | One silhouette stroke pass (back-face extrusion) |
| `outline_passes.tres` | Three outline passes chained into one reusable resource |
| `pencil_material.tres` | Preset: the surface plus `outline_passes.tres` |
| `pencil_ui.gdshader` | The 2D counterpart, used for the menus (see below) |

## Using it

Assign `pencil_material.tres` as a mesh's material (or material override), then
duplicate it per object and set `base_color`. Duplicating is cheap: the outline
chain is shared by reference, so all copies keep the same line style.

```gdscript
var material := load("res://shaders/pencil/pencil_material.tres").duplicate()
material.set_shader_parameter(&"base_color", Color(0.84, 0.44, 0.36))
mesh_instance.material_override = material
```

In a scene file, do the same thing without the script: give the mesh a
`ShaderMaterial` whose shader is `pencil_surface.gdshader` and whose `next_pass`
points at `outline_passes.tres`. `game/world.tscn` has seven of these, one per
colour, all sharing the single outline chain.

Two things to know before tuning anything else:

**Ambient light is taken over by the shader.** `pencil_surface.gdshader` runs with
`ambient_light_disabled`, and the `Fill_Light` uniforms stand in for the
environment. That is what keeps the shadow side scribbled instead of flooded with
flat ambient colour. Everything a light does not reach is `fill_color *
fill_energy`, hatched at `fill_tone` density.

**`hatch_scale` means different things per space.** `hatch_space` picks where the
strokes live, and the scale unit follows from it:

| `hatch_space` | Strokes stick to | `hatch_scale` unit | Good for |
| --- | --- | --- | --- |
| Model UV | The mesh's UVs | strokes per UV tile | Meshes with deliberate UVs (start around 60) |
| Model Triplanar | The mesh, in object space | strokes per world unit | Default. Props and characters that move |
| World Triplanar | The world | strokes per world unit | Static level geometry |
| Screen | The screen | strokes per 100 px | Floors, walls, anything that reaches the horizon |

Large surfaces are the one case that needs attention. A floor 26 units across with
strokes every 1/14 unit turns to grey mush at the horizon, because the strokes fall
below pixel size. Either drop its `hatch_scale` or switch that material to Screen
space, which is what the shader lab and the game world both do for their floors.

## In the game

`game/world.tscn` runs the style end to end: the ground uses Screen-space hatching,
and six props (sphere, box, cylinder, torus, capsule, pillar) sit on it in different
colours with collision, so you can walk up to them and watch the strokes slide. The
sun there uses `shadow_blur = 0.0` on purpose — a blurred shadow edge reads as a
grey smudge next to hard pencil lines.

## Uniform groups

- **Fill** — `base_color`, `base_texture`, and `color_steps` to posterize the fill
  into flat bands.
- **Shading** — `light_bands` and `band_softness` control the posterized lighting,
  `light_wrap` softens the terminator, `shadow_leak` is how much direct light
  survives in the dark band, `terminator_wobble` breaks the light/shadow boundary
  so it looks drawn.
- **Fill_Light** — the ambient stand-in described above.
- **Pencil** — stroke look: `ink_color` and `ink_tint` (0 draws strokes in a darker
  shade of the fill, 1 in `ink_color`), `ink_strength`, `stroke_thickness`,
  `stroke_wobble`, `stroke_breakup`, the four `hatch_angles_degrees` and
  `hatch_layer_scales`, and `tone_gamma` to bias when layers switch on. To use a
  hatch texture instead of the procedural strokes, set `hatch_texture` and raise
  `hatch_texture_blend`; dark pixels in the texture become ink.
- **Redraw** — `redraw_jitter` and `redraw_fps` nudge the whole stroke field on a
  low frame rate, so it reads as a hand redrawing each frame. Set `redraw_fps` to
  0 to freeze it.
- **Parallax** — `parallax_strength` (0.03 is a good starting point) offsets the
  stroke layers along the view direction, scaled by a height value.
  `parallax_layer_depths` gives each of the four layers its own depth, so they
  separate slightly as the camera moves. `height_scale` sets the frequency of the
  procedural height; supply `height_texture` and raise `height_texture_blend` to
  paint it instead.
- **Paper** — `paper_grain` adds tooth to the fill, in screen space by default.
- **Edges** — `edge_ink` and `edge_width` press harder near the silhouette.

## Outline passes

`sketch_outline.gdshader` pushes back faces along their normals by a width
measured in pixels, so lines keep their weight at any distance. The preset chains
three passes with different `seed`, `width_pixels` and `stroke_gaps` values, which
is what makes the silhouette look redrawn rather than traced. `stroke_gaps` breaks
the line with an alpha scissor, so the pass stays in the opaque queue and out of
transparency sorting.

The pass needs closed geometry to work. Single-sided planes have no back faces to
extrude, and hard-edged meshes show a gap at each split normal.

## In the menus

`pencil_ui.gdshader` is the same style for `canvas_item`: it fills a rounded
rectangle with paper, shades it with the stroke layers above, and traces its
border with a few wandering passes. `fill_tone` stands in for lighting — 1.0 is
bare paper and lower values switch on more stroke layers — so a button's hover
and press states are drawn as pressing harder rather than as fill colours.

`ui/themes/pencil_surface.gd` puts it behind a Control:

```gdscript
PencilSurface.add_to(button, PencilSurface.Style.BUTTON)
```

That adds a `ColorRect` child with `show_behind_parent`, which leaves the
Control's text and icons crisp on top, and connects the Control's hover, press
and focus signals to the tone. `Style` covers the backdrop sheet, the card every
screen is drawn on, lobby rows, fields, buttons, the primary action and the
destructive one; `PencilSurface.rule()` draws a line where a menu would otherwise
use an `HSeparator`. Four details worth knowing before adding surfaces of your
own:

- **Text over the world needs `Style.HUD`.** A menu knows what is behind it; the
  interact prompt does not, and light text with a dark shadow loses against a
  pale sky as surely as dark text loses against grass. That style is an opaque
  plate — bare paper under the label, a firmer border, no redraw jitter — so
  contrast comes from the plate rather than from the text colour. The player's
  HUD in `game/player/player.tscn` shows the arrangement: a wrapper that
  positions, a `PanelContainer` that carries the surface, a `MarginContainer`
  that pads, and the label inside. The wrapper is what gets hidden, since an
  empty plate reads as a blank sticker stuck to the screen.

- **Colour carries meaning, hatching carries state.** Every surface takes its
  pencils from `ui/themes/ui_palette.tres`. Dark Cyan marks the default action of
  a screen, Mahogany Red marks leaving and failing, and Golden Orange rings
  whatever holds focus and fills the slider being dragged. Hover and press stay
  colourless — they are extra strokes, not a new hue — so a state change never
  competes with those three.

- **The theme leaves styleboxes empty.** `ui/themes/main_theme.tres` keeps only
  the content margins for anything the shader draws, since a stylebox behind the
  hatching would flatten it. A `PanelContainer` therefore has no content margin
  either — its padding lives in a `MarginContainer` inside it, which is what lets
  the drawn card reach the panel's edge.
- **Sizes are viewport units, not screen pixels.** The shader divides by the
  window's scale against `reference_height`, so line weight and stroke spacing
  hold up under the `canvas_items` stretch and on a hiDPI window. It reads the
  rect's size from `fwidth(UV)` rather than from a uniform, so nothing needs
  re-syncing when a Control resizes.

The rect is drawn `PencilSurface.BLEED` pixels inside its backing `ColorRect`,
which is what stops an outward-wandering border stroke from being clipped.
Outside a container the rect is grown by the same amount, so the drawn shape
lands exactly on the Control's bounds.

`dev/_menu_shot.gd` captures the menus the way the lab captures the material:

```powershell
godot --path . res://dev/_menu_shot.tscn -- --freeze
```

It walks the boot sheet, the title, settings, online, host and browser screens
and the in-game pause card, saving one PNG each to `dev/captures/`. `--freeze`
stops the redraw jitter so two runs can be compared.

## Shader lab

`dev/shader_lab.tscn` is the test bed: primitives and the astronaut model under the
material, with live sliders for the uniforms that matter.

```powershell
godot --path . res://dev/shader_lab.tscn
```

Drag to orbit, wheel to zoom. **Tab** hides the panel, **Space** orbits the sun,
**C** orbits the camera (the best way to see the parallax), **O** toggles the
outline passes, **F12** saves a screenshot to `dev/captures/`, **Esc** quits.

For scripted captures, arguments after `--` are read by the lab:

```powershell
godot --path . res://dev/shader_lab.tscn -- --shot --frames=200 --freeze --set=parallax_strength:0.2
```

- `--shot`, `--shot-path=<file>`, `--frames=<n>` — save one screenshot and quit
- `--freeze` — stop the redraw jitter on every pass, so captures are comparable
- `--set=<uniform>:<value>` — override one uniform everywhere
- `--no-outlines`, `--hide=<node>` — isolate parts of the scene
- `--look=<x,y,z>`, `--zoom=`, `--yaw=`, `--pitch=` — frame the shot
