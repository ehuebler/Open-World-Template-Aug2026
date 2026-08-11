"""Remove the generated black field from the home-screen title artwork.

Run from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" \
        --background --factory-startup \
        --python assets/source/blender/build_title_art.py

The source has softly glowing edges rather than a hard black/colour boundary.
A binary colour key would leave either a black fringe or clipped glow, so this
uses the brightest channel as coverage, un-premultiplies the edge colour, and
crops the result to the visible artwork.
"""

import os

import bpy
import numpy as np


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
SOURCE = os.path.join(SOURCE_DIR, "title_art", "my_strange_planet_source.png")
OUTPUT = os.path.join(ROOT, "ui", "menu", "my_strange_planet_title.png")

# Blender exposes pixels in linear colour. Values below LOW are compression
# noise in the black field; HIGH is bright enough to be fully opaque.
# The generated JPEG-like noise in the field reaches roughly 0.03 linear even
# though it looks black. Starting the key above it removes that block noise;
# the coloured edge glow becomes visible immediately above this range.
LOW = 0.035
HIGH = 0.095
PADDING = 14


def main():
    image = bpy.data.images.load(SOURCE, check_existing=False)
    width, height = image.size
    rgba = np.asarray(image.pixels[:], dtype=np.float32).reshape(height, width, 4)
    rgb = rgba[:, :, :3]

    strength = np.max(rgb, axis=2)
    coverage = np.clip((strength - LOW) / (HIGH - LOW), 0.0, 1.0)
    coverage = coverage * coverage * (3.0 - 2.0 * coverage)

    # Straight-alpha PNGs need the glow colour without its old black backing.
    # Dividing by coverage preserves the original appearance when composited
    # over dark space while avoiding a soot-coloured fringe over bright scenes.
    colour = np.zeros_like(rgb)
    visible = coverage > 0.0001
    colour[visible] = np.clip(
        (rgb[visible] - LOW) / coverage[visible, np.newaxis], 0.0, 1.0
    )

    keep = coverage > 0.01
    ys, xs = np.nonzero(keep)
    left = max(int(xs.min()) - PADDING, 0)
    right = min(int(xs.max()) + PADDING + 1, width)
    bottom = max(int(ys.min()) - PADDING, 0)
    top = min(int(ys.max()) + PADDING + 1, height)

    result = np.dstack((colour, coverage))[bottom:top, left:right]
    out_height, out_width = result.shape[:2]
    output = bpy.data.images.new(
        "My Strange Planet Title",
        width=out_width,
        height=out_height,
        alpha=True,
    )
    output.alpha_mode = "STRAIGHT"
    output.pixels.foreach_set(result.astype(np.float32).ravel())
    output.filepath_raw = OUTPUT
    output.file_format = "PNG"
    output.save()
    print(
        "wrote {0} ({1}x{2}, crop {3}:{4} x {5}:{6})".format(
            OUTPUT, out_width, out_height, left, right, bottom, top
        )
    )


if __name__ == "__main__":
    main()
