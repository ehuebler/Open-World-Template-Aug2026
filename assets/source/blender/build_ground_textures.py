"""Turns the ground material photographs in `assets/source/texture_inputs/` into the two
packed maps per material that `vivid_terrain` reads.

Run headless from the project root; it opens no .blend and needs no input beyond
the source images:

    $blender = "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe"
    & $blender --background --factory-startup --python assets/source/blender/build_ground_textures.py

Sources, per material, are either four separate PNGs or one contact sheet with
the four maps in quadrants — both are what the generators hand out, so both are
read. What comes out is two files for all four materials together:
`game/planet/textures/ground_albedo.png` and `ground_surface.png`, each a
vertical strip of one square per material in LAYERS order, imported as a
Texture2DArray.

Two files and not thirty-two, and the arithmetic is the whole reason. A ground
pixel can be standing on more than one material at once, and each material is
read along two projections, so what costs is taps per pixel and it multiplies:
four maps a material, sampled biplanar, on a hillside where grass meets rock is
sixteen. Packing the four maps into two takes that to eight. Stacking the
materials into an array takes the *sampler* count from eight to two and lets the
shader choose which material to read at each pixel instead of reading all of
them and throwing three quarters away — which is what separate uniforms would
force, since a sampler cannot be picked at runtime but an array layer can.

    _albedo    RGB  the colour, normalised (see below)
               A    ambient occlusion
    _surface   RG   the normal's X and Y, Z rebuilt in the shader
               B    roughness
               A    unused, and free for a height map if parallax is ever wanted

Two things are done to the images rather than just copied:

- **The albedo is normalised to a mean of 0.5 and mostly desaturated.** It is
  not used as a colour. The ground already has one — the biome writes it per
  vertex and the region wheel turns it — and the request is that the texture
  tint *with* that rather than paint over it, so light green grass stays light
  green. So what is stored is the material's light and shade about its own
  average, with a fraction of its hue left in, and the shader multiplies. A map
  stored at its own brightness would drag every biome toward the colour of the
  photograph it came from.
- **Seams are healed if they need it.** A texture tiled every couple of metres
  shows its edges as a grid across a whole hillside. The seam is measured
  against the image's own average variation before anything is done, so a
  source that really is seamless is left alone.

  Healing is the offset trick. Rolling the image by half its width puts its own
  broken edge down the middle and brings its continuous interior out to the
  border, so from that point on the border is never touched and the tile is
  exact by construction rather than by approximation. What is left to deal with
  is the break in the middle, and that gets patched over with a strip of
  texture found elsewhere in the same image: the search keeps whichever
  candidate agrees best with the two edges it has to sit between, which is what
  a clone tool does, decided by measurement instead of by eye.

  Crossfading the two sides together is the obvious alternative and it is
  worse, which is worth saying because it is what this used to do. Averaging
  two unrelated halves reads as a soft ghosted band, and a band repeats exactly
  as much as the seam it replaced — so it trades a hard grid for a blurred one
  and loses the detail under it as well.

The output is 512 a layer and not 1024 on purpose. The sheets carry about 500 px
a quadrant, so 1024 would be upscaling invented detail, and all eight layers are
resident at once while the whole point of the exercise is that it stays cheap.
"""

import os
import sys

import bpy
import numpy as np

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
IN_DIR = os.path.join(PROJECT_DIR, "assets", "source", "texture_inputs")
OUT_DIR = os.path.join(PROJECT_DIR, "game", "planet", "textures")
PREVIEW_DIR = os.path.join(PROJECT_DIR, "assets", "previews", "authoring")

SIZE = 512
# How much worse than the image's own average column-to-column change an edge
# has to be before it counts as a seam worth healing. A source that really
# tiles sits at 1; the four here came in at 1.7, 3.8, 5.5 and 9.9, so this is
# set low enough to catch the mildest of them.
SEAM_LIMIT = 1.2
# The seam patch, in pixels at SIZE. `BAND` is how wide a strip gets replaced,
# `EASE` how much of each of its four sides is spent easing into what was
# already there, and `BLOCK` how far down the seam one donor is asked to reach
# before another is found — 512 of seam is far more than any one patch of grass
# can cover, so it is done in eight bites. `STRIDE` is how finely the image is
# searched for those donors, and is the one knob here that only costs time.
SEAM_BAND = 40
SEAM_EASE = 10
SEAM_BLOCK = 64
SEAM_STRIDE = 8
# How much of the photograph's own colour survives normalisation. The rest is
# its luminance, which is the part that carries the grain. Kept low: this is
# multiplied into a biome colour that has already been through the region wheel.
KEEP_CHROMA = 0.25

# What each material is built from. A sheet is one image holding the four maps
# in quadrants, read left to right and top to bottom.
MATERIALS = {
    "grass": {
        "albedo": "grass_base.png",
        "normal": "grass_normal.png",
        "rough": "grass_rough.png",
        "ao": "grass_ao.png",
    },
    "sand": {"sheet": "sand_sheet.png"},
    "stone": {"sheet": "stone_sheet.png"},
    "ice": {"sheet": "ice_sheet.png"},
}
# Layer order in the arrays, and a contract: `vivid_terrain` names these as
# constants and picks between them by index, so reordering this reorders the
# planet's ground. Grass is layer 0 because it is what a pixel gets when nothing
# else claims it.
LAYERS = ("grass", "sand", "stone", "ice")
# The order the maps appear in a sheet's quadrants.
SHEET_ORDER = ("albedo", "normal", "rough", "ao")


def read(path):
    """A PNG as a float array, top row first, in the values the file holds.

    Non-Color matters: left as sRGB, Blender hands back light-linear values and
    every threshold below would be measured against a curve that is not the one
    in the file. What goes out has to be encoded the way Godot will decode it.
    """
    image = bpy.data.images.load(path)
    image.colorspace_settings.name = "Non-Color"
    width, height = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)
    bpy.data.images.remove(image)
    # Blender counts rows from the bottom; everything here is written top down.
    return pixels[::-1]


def write(array, path):
    height, width = array.shape[:2]
    image = bpy.data.images.new(
        os.path.basename(path), width, height, alpha=True, float_buffer=False)
    image.colorspace_settings.name = "Non-Color"
    image.pixels = np.clip(array[::-1], 0.0, 1.0).ravel().tolist()
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    bpy.data.images.remove(image)
    print("  wrote {0} ({1}x{2}, {3:.0f} KB)".format(
        os.path.basename(path), width, height, os.path.getsize(path) / 1024.0))


def runs(profile, floor, least):
    """Contiguous stretches of `profile` above `floor`, longest first.

    This is how a contact sheet is cut up. The background between the quadrants
    is black and the labels over them are thin white text on black, so a row
    average finds the picture bands and nothing else — which beats hard-coded
    offsets, because the generator does not promise the same margins twice.
    """
    found = []
    start = None
    for index, value in enumerate(profile):
        if value > floor and start is None:
            start = index
        elif value <= floor and start is not None:
            found.append((start, index))
            start = None
    if start is not None:
        found.append((start, len(profile)))
    found = [span for span in found if span[1] - span[0] >= least]
    return sorted(found, key=lambda span: span[0] - span[1])


def quadrants(sheet):
    """The four maps out of a contact sheet, in reading order."""
    grey = sheet[:, :, :3].mean(axis=2)
    height, width = grey.shape
    down = grey.mean(axis=1)
    across = grey.mean(axis=0)
    # The cut is taken between the background and the pictures rather than at a
    # fixed value, because "black" in a generated sheet is whatever dark grey
    # the generator felt like and the labels lift it further.
    floor = min(down.min(), across.min()) + 0.35 * (
        max(down.max(), across.max()) - min(down.min(), across.min()))
    bands = runs(down, floor, height // 8)[:2]
    columns = runs(across, floor, width // 8)[:2]
    if len(bands) < 2 or len(columns) < 2:
        raise SystemExit(
            "could not find four quadrants: rows {0} in {1}, columns {2} in {3}, "
            "cut at {4:.3f} of {5:.3f}..{6:.3f}".format(
                len(bands), height, len(columns), width, floor,
                min(down.min(), across.min()), max(down.max(), across.max())))
    bands = sorted(bands)
    columns = sorted(columns)
    cut = []
    for top, bottom in bands:
        for left, right in columns:
            cut.append(sheet[top:bottom, left:right])
    print("  sheet cut into {0} at {1}".format(
        len(cut), " ".join("%dx%d" % (part.shape[1], part.shape[0]) for part in cut)))
    return cut


def square(array, size):
    """Centre crop to a square and resample to `size`, bilinear."""
    height, width = array.shape[:2]
    side = min(height, width)
    top = (height - side) // 2
    left = (width - side) // 2
    array = array[top:top + side, left:left + side]
    # Sample centres rather than corners, or the result is shifted half a pixel
    # and a normal map derived from it no longer lines up with its albedo.
    at = (np.arange(size, dtype=np.float32) + 0.5) * (side / size) - 0.5
    low = np.clip(np.floor(at).astype(np.int32), 0, side - 1)
    high = np.clip(low + 1, 0, side - 1)
    frac = (at - low).astype(np.float32)[:, None]
    rows = array[low] * (1.0 - frac[:, :, None]) + array[high] * frac[:, :, None]
    frac = frac.T[:, :, None]
    return rows[:, low] * (1.0 - frac) + rows[:, high] * frac


def seam(array):
    """How much worse the wrap-around edge is than an average step inside the
    image. 1 is seamless; anything much over that is a visible grid."""
    grey = array[:, :, :3].mean(axis=2)
    inside = np.abs(np.diff(grey, axis=1)).mean() + np.abs(np.diff(grey, axis=0)).mean()
    across = np.abs(grey[:, -1] - grey[:, 0]).mean() + np.abs(grey[-1] - grey[0]).mean()
    return across / max(inside, 1e-6)


def roughest(array):
    """The most abrupt column or row step anywhere inside the image, against the
    average one.

    This is the check on the patching below, and it is needed because `seam`
    cannot do the job: `seam` only looks at the border, and after the offset the
    border is continuous whatever else went wrong. A donor strip that did not
    fit leaves a line somewhere in the middle instead, and a line in the middle
    of a tile repeats just as visibly as one at its edge. So the number to watch
    is the worst step in the whole image, before and after — if patching has not
    moved it, it has not left an edge anywhere.
    """
    grey = array[:, :, :3].mean(axis=2)
    columns = np.abs(np.diff(grey, axis=1)).mean(axis=0)
    rows = np.abs(np.diff(grey, axis=0)).mean(axis=1)
    inside = (columns.mean() + rows.mean()) * 0.5
    return max(columns.max(), rows.max()) / max(inside, 1e-6)


def ease(count):
    """A smoothstep from nothing to everything across `count` pixels."""
    step = (np.arange(count, dtype=np.float32) + 0.5) / count
    return step * step * (3.0 - 2.0 * step)


def upright(array, axis):
    """The image turned so that `axis`'s seam is a vertical line.

    Its own inverse, so the same call puts the image back: swapping two axes
    twice is the identity, and the offset that actually moves the seam is
    applied separately and only on the way in.
    """
    return array if axis == 1 else array.transpose(1, 0, 2)


def find_donors(view, cyclic):
    """Where to take the patch from, for one seam standing down the middle.

    Worked out on the albedo alone and then replayed onto the other three maps,
    because they describe the same surface: a roughness patch lifted from
    somewhere the colour patch did not come from is a place where the ground is
    smooth for no visible reason.

    A candidate is scored only on the two edges it has to meet — what it does
    in between is free, since it is covering a break and any plausible texture
    will do there. Candidates straddling the seam are not offered at all: their
    middle holds the very discontinuity being patched out.
    """
    span, width = view.shape[:2]
    mid = width // 2
    left = mid - SEAM_BAND // 2
    grey = view[:, :, :3].mean(axis=2)
    columns = (list(range(0, mid - SEAM_BAND + 1, SEAM_STRIDE))
               + list(range(mid, width - SEAM_BAND + 1, SEAM_STRIDE)))
    donors = []
    starts = range(0, span, SEAM_BLOCK) if cyclic else range(0, span - SEAM_EASE, SEAM_BLOCK)
    for start in starts:
        reach = SEAM_BLOCK + SEAM_EASE if cyclic else min(SEAM_BLOCK + SEAM_EASE, span - start)
        here = grey[np.arange(start, start + reach) % span]
        want_left = here[:, left:left + SEAM_EASE]
        want_right = here[:, left + SEAM_BAND - SEAM_EASE:left + SEAM_BAND]
        # Down the seam the donor may sit anywhere, except that in the first
        # pass it may not straddle the far border: that one is still broken, and
        # is what the second pass is for.
        rows = (range(0, span, SEAM_STRIDE) if cyclic
                else range(0, span - reach + 1, SEAM_STRIDE))
        best = None
        for row in rows:
            there = grey[np.arange(row, row + reach) % span]
            for column in columns:
                cost = (np.abs(there[:, column:column + SEAM_EASE] - want_left).mean()
                        + np.abs(there[:, column + SEAM_BAND - SEAM_EASE:
                                       column + SEAM_BAND] - want_right).mean())
                if best is None or cost < best[0]:
                    best = (cost, row, column)
        donors.append((start, reach, best[1], best[2]))
    return donors


def patch(view, donors, cyclic):
    """Lay the chosen strips over the seam down the middle of `view`."""
    span, width = view.shape[:2]
    left = width // 2 - SEAM_BAND // 2
    strip = np.array(view[:, left:left + SEAM_BAND])
    for index, (start, reach, row, column) in enumerate(donors):
        here = np.arange(start, start + reach) % span
        taken = view[np.arange(row, row + reach) % span][:, column:column + SEAM_BAND]
        # Full strength except where this donor overlaps its neighbours, which
        # is every join but the first, and the last as well when the strip has
        # to close back onto the first.
        weight = np.ones(reach, dtype=np.float32)
        if index > 0:
            weight[:SEAM_EASE] = ease(SEAM_EASE)
        if cyclic and index == len(donors) - 1:
            weight[-SEAM_EASE:] = ease(SEAM_EASE)[::-1]
        weight = weight[:, None, None]
        strip[here] = strip[here] * (1.0 - weight) + taken * weight

    across = np.ones(SEAM_BAND, dtype=np.float32)
    across[:SEAM_EASE] = ease(SEAM_EASE)
    across[-SEAM_EASE:] = ease(SEAM_EASE)[::-1]
    across = across[None, :, None]
    healed = np.array(view)
    healed[:, left:left + SEAM_BAND] = (
        healed[:, left:left + SEAM_BAND] * (1.0 - across) + strip * across)
    return healed


def heal(array):
    """Makes an image tile. Returns it, and the recipe to do the same to another
    map of the same surface.

    The two axes go one after the other, and only the second may wrap its strip
    around. On the first pass the far border is still broken, so a strip closed
    into a loop would be closing across that break; by the second pass the first
    axis tiles, and the strip has to close or it would undo it.
    """
    recipe = []
    for axis, cyclic in ((1, False), (0, True)):
        view = upright(array, axis)
        view = np.roll(view, view.shape[1] // 2, axis=1)
        donors = find_donors(view, cyclic)
        array = upright(patch(view, donors, cyclic), axis)
        recipe.append((axis, donors, cyclic))
    return array, recipe


def replay(array, recipe):
    """The same offsets and the same donors, on another map of the same surface."""
    for axis, donors, cyclic in recipe:
        view = upright(array, axis)
        view = np.roll(view, view.shape[1] // 2, axis=1)
        array = upright(patch(view, donors, cyclic), axis)
    return array


def tileable(array, label):
    before = seam(array)
    if before <= SEAM_LIMIT:
        print("  {0}: seam {1:.2f}, already tiles".format(label, before))
        return array, []
    healed, recipe = heal(array)
    print("  {0}: seam {1:.2f} -> {2:.2f}, patched; worst step inside {3:.2f} -> "
          "{4:.2f}".format(label, before, seam(healed), roughest(array), roughest(healed)))
    return healed, recipe


def is_normal_map(array):
    """Whether an image is a tangent-space normal map or a picture that has been
    tinted to look like one. Generators hand out both."""
    means = array[:, :, :3].reshape(-1, 3).mean(axis=0)
    upright = means[2] > 0.72
    centred = abs(means[0] - 0.5) < 0.12 and abs(means[1] - 0.5) < 0.12
    print("  normal channels average {0:.2f} {1:.2f} {2:.2f} — {3}".format(
        means[0], means[1], means[2],
        "a normal map" if upright and centred else "not a normal map, deriving one"))
    return upright and centred


def derive_normal(albedo, strength=2.4):
    """A normal map out of an albedo's own brightness, read as height.

    Wrong in principle — a dark blade of grass is not a low one — and right
    enough in practice on ground, where nearly everything dark is dark because
    it is shaded by being lower down. It is also the only option when the map
    that arrived is a photograph with a blue filter over it.
    """
    height = albedo[:, :, :3].mean(axis=2)
    # Rolled rather than clamped, so the gradient wraps the same way the image
    # does and the seam heal above is not undone here.
    along = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    across = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    normal = np.stack([-along, across, np.ones_like(height)], axis=2)
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)
    return normal * 0.5 + 0.5


def normalise(albedo):
    """Albedo to something that can be multiplied into a biome colour: mean 0.5,
    most of the hue taken out. See the module note for why."""
    luma = albedo[:, :, :3] @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    toned = albedo[:, :, :3] * KEEP_CHROMA + luma[:, :, None] * (1.0 - KEEP_CHROMA)
    scaled = toned * (0.5 / max(float(luma.mean()), 1e-4))
    clipped = float((scaled > 1.0).mean())
    if clipped > 0.01:
        print("  {0:.1f}% of the albedo clips after normalising".format(clipped * 100.0))
    return np.clip(scaled, 0.0, 1.0)


def build(name, recipe):
    print("{0}".format(name))
    maps = {}
    if "sheet" in recipe:
        parts = quadrants(read(os.path.join(IN_DIR, recipe["sheet"])))
        maps = dict(zip(SHEET_ORDER, parts))
    else:
        for key, filename in recipe.items():
            maps[key] = read(os.path.join(IN_DIR, filename))
    for key in SHEET_ORDER:
        if key not in maps:
            raise SystemExit("{0} is missing its {1} map".format(name, key))
        maps[key] = square(maps[key], SIZE)

    # The other three follow the albedo's healing rather than being measured
    # separately: they describe the same surface, and healing them by different
    # amounts is what puts a roughness edge where the colour has none. A derived
    # normal is the exception, and needs no replay — it is read off the albedo
    # after the fact, so it already carries everything done to it.
    albedo, recipe = tileable(maps["albedo"], "albedo")
    normal = (replay(maps["normal"], recipe) if is_normal_map(maps["normal"])
              else derive_normal(albedo))
    maps["rough"] = replay(maps["rough"], recipe)
    maps["ao"] = replay(maps["ao"], recipe)

    packed_albedo = np.empty((SIZE, SIZE, 4), dtype=np.float32)
    packed_albedo[:, :, :3] = normalise(albedo)
    packed_albedo[:, :, 3] = maps["ao"][:, :, :3].mean(axis=2)

    packed_surface = np.empty((SIZE, SIZE, 4), dtype=np.float32)
    packed_surface[:, :, 0] = normal[:, :, 0]
    packed_surface[:, :, 1] = normal[:, :, 1]
    packed_surface[:, :, 2] = maps["rough"][:, :, :3].mean(axis=2)
    packed_surface[:, :, 3] = 1.0
    return packed_albedo, packed_surface, albedo


def tiled(array, size):
    """Two by two of a material, for looking at whether it tiles.

    Shown at its own colours rather than normalised, because normalising takes
    the contrast out and a seam is easiest to see with all of it left in.
    """
    small = square(array, size)
    return np.tile(small, (2, 2, 1))


def main():
    if not os.path.isdir(OUT_DIR):
        os.makedirs(OUT_DIR)
    albedos = []
    surfaces = []
    previews = []
    for name in LAYERS:
        packed_albedo, packed_surface, plain = build(name, MATERIALS[name])
        albedos.append(packed_albedo)
        surfaces.append(packed_surface)
        previews.append(tiled(plain, SIZE // 2))
    if os.path.isdir(PREVIEW_DIR):
        write(np.concatenate(previews, axis=1),
              os.path.join(PREVIEW_DIR, "ground_tiling.png"))
    # Stacked top to bottom, which is what the importer's `slices/vertical`
    # cuts back apart. A strip rather than a grid because one cut is harder to
    # get the wrong way round than two.
    print("stacking {0}".format(", ".join(LAYERS)))
    write(np.concatenate(albedos, axis=0), os.path.join(OUT_DIR, "ground_albedo.png"))
    write(np.concatenate(surfaces, axis=0), os.path.join(OUT_DIR, "ground_surface.png"))


if __name__ == "__main__":
    main()
