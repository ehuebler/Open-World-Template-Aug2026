"""Build a deterministic, PNG-painted library of procedural biome props.

Run from the repository root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_biome_assets.py

Optional arguments belong after Blender's ``--`` separator:

    ... --python assets/source/blender/build_biome_assets.py -- `
        --output-dir assets/runtime/biomes/models --only kelp_ribbon sea_fan

The generator deliberately authors all disconnected botanical parts into one
caller-owned bmesh.  Each result therefore exports as one static mesh node,
which is the shape Godot's MeshInstance3D and MultiMesh APIs can consume
directly.  Geometry is recipe-driven: recipes select a reusable archetype and
provide palettes, dimensions, budgets, collision guidance, and deterministic
seeds.  New variants should normally be added to ``RECIPES`` rather than as a
new standalone build script.

Runtime guarantees enforced after every export:

* exactly one mesh and one mesh node, named exactly like the manifest entry;
* one active ``Color`` attribute exported as glTF ``COLOR_0``;
* one active ``PaintUV`` map exported as glTF ``TEXCOORD_0``;
* one external, mip-safe PNG color-paint texture per recipe;
* no armature, skin, shape key, animation, or non-mesh scene node;
* authored ground contact at Blender Z=0 (glTF/Godot Y=0);
* triangle counts inside each recipe's explicit MultiMesh budget.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import math
import os
import random
import sys
from typing import Callable, Iterable, Sequence

import bmesh
import bpy
from mathutils import Matrix, Vector, noise


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
DEFAULT_OUTPUT_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "biomes", "models")
PAINT_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "biomes", "paint")
PREVIEW_DIR = os.path.join(PROJECT_DIR, "assets", "previews", "biomes")
MANIFEST_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "biomes", "manifests")
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_vat
import propkit


GOLDEN_ANGLE = math.pi * (3.0 - math.sqrt(5.0))
PALETTE_ATTRIBUTE = "_biome_palette"
COLOR_ATTRIBUTE = "Color"
PAINT_UV_NAME = "PaintUV"
PREVIEW_FOLDER = "assets/previews/biomes"
PAINT_FOLDER = "assets/runtime/biomes/paint"
PREVIEW_SIZE = 384
PREVIEW_SAMPLES = 24
PAINT_SIZE = 256
PAINT_GUTTER = 6
MANIFEST_VERSION = 2

RGBA = tuple[float, float, float, float]


@dataclass(frozen=True)
class AssetRecipe:
    """Everything needed to produce and document one runtime mesh.

    ``archetype`` chooses a reusable family builder and ``form`` chooses a
    variation inside it.  Geometry is authored in normalized proportions and
    uniformly fitted to ``height`` before export, so changing scale never
    changes topology or the deterministic silhouette.
    """

    name: str
    category: str
    archetype: str
    form: str
    seed: int
    height: float
    palette: tuple[RGBA, ...]
    triangle_budget: tuple[int, int]
    collision_hint: dict[str, object]
    vertex_colour_style: str
    emission_style: str = "none"
    emission_strength: float = 0.0
    roughness: float = 0.72
    smooth: bool = True
    parameters: dict[str, object] = field(default_factory=dict)


def _rgba(hex_value: str) -> RGBA:
    """Convert authored sRGB hex notation to a Blender-compatible RGBA tuple."""

    value = hex_value.removeprefix("#")
    if len(value) != 6:
        raise ValueError("palette colours must use six hex digits")
    return tuple(int(value[index:index + 2], 16) / 255.0
                 for index in (0, 2, 4)) + (1.0,)


# Palettes are intentionally shared by related recipes.  Cohesion comes from
# repeated shadow/midtone/highlight relationships, not identical silhouettes.
RECIPES: tuple[AssetRecipe, ...] = (
    AssetRecipe(
        "kelp_ribbon", "aquatic", "aquatic", "ribbon", 1101, 2.8,
        tuple(map(_rgba, ("173F3A", "256B54", "4E9A69", "D0B45D"))),
        (260, 720),
        {"shape": "capsule", "radius": 0.34, "height": 2.55,
         "centre": [0.0, 1.275, 0.0]},
        "dark holdfast; teal-to-sunlit green ribbons with amber tips",
    ),
    AssetRecipe(
        "sea_fan", "aquatic", "aquatic", "fan", 1102, 2.15,
        tuple(map(_rgba, ("38214F", "74406D", "B96782", "E9A58E"))),
        (480, 1050),
        {"shape": "box", "size": [1.8, 2.0, 0.22],
         "centre": [0.0, 1.0, 0.0]},
        "plum structural veins grading to warm coral fan tips",
    ),
    AssetRecipe(
        "bulb_seaweed", "aquatic", "aquatic", "bulb", 1103, 1.65,
        tuple(map(_rgba, ("183E43", "2C7771", "72B78A", "D7C86D"))),
        (420, 980),
        {"shape": "capsule", "radius": 0.42, "height": 1.45,
         "centre": [0.0, 0.725, 0.0]},
        "deep blue-green stems, sea-glass bulbs, chartreuse blade tips",
    ),
    AssetRecipe(
        "grass_feather", "grass", "grass", "feather", 2101, 0.72,
        tuple(map(_rgba, ("273D24", "4C6B32", "829348", "C1AF66"))),
        (260, 720),
        {"shape": "capsule", "radius": 0.22, "height": 0.62,
         "centre": [0.0, 0.31, 0.0]},
        "olive stems with alternating pale seed-feathers",
    ),
    AssetRecipe(
        "grass_fan", "grass", "grass", "fan", 2102, 0.58,
        tuple(map(_rgba, ("1F432C", "3C7542", "70A856", "B9CB78"))),
        (220, 620),
        {"shape": "capsule", "radius": 0.27, "height": 0.5,
         "centre": [0.0, 0.25, 0.0]},
        "deep green bases grading through fresh green blade faces",
    ),
    AssetRecipe(
        "shrub_broadleaf", "shrub", "shrub", "broadleaf", 3101, 1.35,
        tuple(map(_rgba, ("3A2B21", "294E31", "4E7B43", "91A95E"))),
        (620, 1280),
        {"shape": "sphere", "radius": 0.63, "centre": [0.0, 0.72, 0.0]},
        "warm bark under layered forest-green leaves with pale crowns",
    ),
    AssetRecipe(
        "shrub_heather", "shrub", "shrub", "heather", 3102, 0.95,
        tuple(map(_rgba, ("3B3428", "455A35", "925A79", "D49AB2"))),
        (520, 1320),
        {"shape": "capsule", "radius": 0.44, "height": 0.82,
         "centre": [0.0, 0.41, 0.0]},
        "muted twig and needle tones punctuated by mauve bell clusters",
    ),
    AssetRecipe(
        "shrub_silver", "shrub", "shrub", "silver", 3103, 1.05,
        tuple(map(_rgba, ("473E34", "667364", "98A996", "CDD1B8"))),
        (460, 1120),
        {"shape": "sphere", "radius": 0.52, "centre": [0.0, 0.55, 0.0]},
        "charcoal twigs with cool sage and silver leaf faces",
    ),
    AssetRecipe(
        "tree_canopy", "tree", "tree", "canopy", 4101, 5.8,
        tuple(map(_rgba, ("3A261B", "5A3B25", "315739", "668154", "A5A56D"))),
        (980, 1780),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 0.32, "height": 3.5,
              "centre": [0.0, 1.75, 0.0]},
             {"shape": "sphere", "radius": 1.65, "centre": [0.0, 4.25, 0.0]},
         ]},
        "umber branching visible beneath layered moss-green canopy leaves",
    ),
    AssetRecipe(
        "tree_spiral", "tree", "tree", "spiral", 4102, 6.4,
        tuple(map(_rgba, ("33251E", "67462D", "355D43", "729461", "C2B66E"))),
        (900, 1740),
        {"shape": "capsule", "radius": 1.05, "height": 5.9,
         "centre": [0.0, 2.95, 0.0]},
        "dark spiral trunk with golden-angle tiers of jade leaves",
    ),
    AssetRecipe(
        "tree_umbrella", "tree", "tree", "umbrella", 4103, 5.25,
        tuple(map(_rgba, ("3A2A20", "704B2E", "2D5C45", "5F8661", "A7A56D"))),
        (940, 1790),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 0.3, "height": 3.8,
              "centre": [0.0, 1.9, 0.0]},
             {"shape": "sphere", "radius": 1.75, "centre": [0.0, 4.0, 0.0]},
         ]},
        "copper-brown trunk and radial green canopy with sun-faded edges",
    ),
    AssetRecipe(
        "tree_skyneedle", "tree", "tree", "skyneedle", 4104, 13.5,
        tuple(map(_rgba, ("34251F", "60432F", "274F43", "4D7D65", "9AB184"))),
        (1050, 2180),
        {"shape": "capsule", "radius": 0.52, "height": 12.8,
         "centre": [0.0, 6.4, 0.0]},
        "fine charcoal bark rings below long blue-green leaves with pale vein flashes",
    ),
    AssetRecipe(
        "tree_cloudbough", "tree", "tree", "cloudbough", 4105, 11.8,
        tuple(map(_rgba, ("2E211D", "65442E", "234839", "4F7951", "91AC70"))),
        (1200, 2240),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 0.72, "height": 8.0,
              "centre": [0.0, 4.0, 0.0]},
             {"shape": "sphere", "radius": 7.2, "centre": [0.0, 9.15, 0.0]},
         ]},
        "deep walnut trunk below overlapping broad leaves painted with mossy margins and veins",
    ),
    AssetRecipe(
        "tree_orb_giant", "tree", "tree", "orb_giant", 4106, 18.0,
        tuple(map(_rgba, ("271C19", "563725", "244231", "52734A", "A0B36D"))),
        (1250, 2580),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 2.8, "height": 12.2,
              "centre": [0.0, 6.1, 0.0]},
             {"shape": "sphere", "radius": 7.0, "centre": [0.0, 14.0, 0.0]},
         ]},
        "massive dark banded trunk carrying a many-leaf spherical crown with chartreuse tips",
    ),
    AssetRecipe(
        "tree_corkscrew", "tree", "tree", "corkscrew", 4107, 8.4,
        tuple(map(_rgba, ("392036", "6B3B58", "225B59", "48A07E", "D3A85B"))),
        (980, 2100),
        {"shape": "capsule", "radius": 1.25, "height": 8.0,
         "centre": [0.0, 4.0, 0.0]},
        "paired plum corkscrew trunks with turquoise pinwheel leaves and broad gold markings",
    ),
    AssetRecipe(
        "mushroom_cluster", "fungus", "mushroom", "cluster", 5101, 0.85,
        tuple(map(_rgba, ("6A5746", "D2C4A4", "9A5E51", "D98B68"))),
        (500, 1180),
        {"shape": "sphere", "radius": 0.47, "centre": [0.0, 0.4, 0.0]},
        "cream stems under irregular terracotta caps and darker cap margins",
    ),
    AssetRecipe(
        "mushroom_lantern", "fungus", "mushroom", "lantern", 5102, 1.2,
        tuple(map(_rgba, ("35463E", "8FA58B", "B8CF96", "E9E2A1"))),
        (520, 1240),
        {"shape": "capsule", "radius": 0.42, "height": 1.05,
         "centre": [0.0, 0.525, 0.0]},
        "cool stems with pale chartreuse bell caps and luminous gill edges",
        "soft chartreuse vertex emission; preserve instance tint", 1.5,
    ),
    AssetRecipe(
        "mushroom_giant", "fungus", "mushroom", "giant", 5103, 3.2,
        tuple(map(_rgba, ("5A4436", "B7A17D", "6E4654", "B77277", "DEC6A0"))),
        (480, 1280),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 0.38, "height": 2.25,
              "centre": [0.0, 1.125, 0.0]},
             {"shape": "sphere", "radius": 1.1, "centre": [0.0, 2.45, 0.0]},
         ]},
        "earthy stem, wine cap, cream underside and layered radial gills",
    ),
    AssetRecipe(
        "rock_weathered", "rock", "rock", "weathered", 6101, 1.35,
        tuple(map(_rgba, ("3D4140", "5B6059", "797B6C", "A39778"))),
        (260, 720),
        {"shape": "convex_hull"},
        "noise-banded charcoal, lichen grey, and sand-worn upper planes",
        roughness=0.92, smooth=False,
    ),
    AssetRecipe(
        "rock_basalt", "rock", "rock", "basalt", 6102, 2.25,
        tuple(map(_rgba, ("25282C", "383C42", "535760", "77766F"))),
        (300, 780),
        {"shape": "box", "size": [1.35, 2.1, 1.2],
         "centre": [0.0, 1.05, 0.0]},
        "near-black column sides with cool fractured top planes",
        roughness=0.88, smooth=False,
    ),
    AssetRecipe(
        "glacier_shard", "rock", "rock", "glacier", 6103, 2.6,
        tuple(map(_rgba, ("274657", "3F7183", "77A9B6", "B8DADE"))),
        (180, 620),
        {"shape": "convex_hull"},
        "deep cyan cores grading to desaturated ice-blue shard ridges",
        "very low blue-white emission for readability in shadow", 0.18,
        roughness=0.34, smooth=False,
    ),
    AssetRecipe(
        "boulder_round", "rock", "rock", "round", 6104, 2.2,
        tuple(map(_rgba, ("303536", "555A56", "7B786A", "B4A98C"))),
        (260, 760),
        {"shape": "sphere", "radius": 1.1, "centre": [0.0, 1.0, 0.0]},
        "broad charcoal freckles, pale lichen islands and weather-soft strata",
        roughness=0.94, smooth=False,
    ),
    AssetRecipe(
        "boulder_layered", "rock", "rock", "layered", 6105, 3.1,
        tuple(map(_rgba, ("342B28", "644C3E", "987052", "C3A36F"))),
        (260, 780),
        {"shape": "sphere", "radius": 1.5, "centre": [0.0, 1.45, 0.0]},
        "wide umber and ochre sediment ribbons broken by softened dark cracks",
        roughness=0.91, smooth=False,
    ),
    AssetRecipe(
        "boulder_colossus", "rock", "rock", "colossus", 6106, 12.0,
        tuple(map(_rgba, ("252A29", "46504B", "6E786C", "A4AA8E"))),
        (260, 820),
        {"shape": "sphere", "radius": 5.8, "centre": [0.0, 5.7, 0.0]},
        "continent-dark lower shelves, broad sage lichen shelves and pale crowns",
        roughness=0.96, smooth=False,
    ),
    AssetRecipe(
        "basalt_hex_field", "rock", "rock", "hex_field", 6107, 5.0,
        tuple(map(_rgba, ("15191C", "282E31", "41484A", "70736B"))),
        (520, 1180),
        {"shape": "box", "size": [4.5, 5.0, 4.2],
         "centre": [0.0, 2.5, 0.0]},
        "near-black hexagonal cooling columns with vertical ash streaks and pale broken caps",
        roughness=0.9, smooth=False,
    ),
    AssetRecipe(
        "basalt_citadel", "rock", "rock", "hex_citadel", 6108, 14.0,
        tuple(map(_rgba, ("0F1417", "20282B", "354144", "68736D"))),
        (700, 1580),
        {"shape": "compound",
         "parts": [
             {"shape": "box", "size": [7.5, 14.0, 7.5],
              "centre": [0.0, 7.0, 0.0]},
             {"shape": "box", "size": [15.0, 5.0, 14.0],
              "centre": [0.0, 2.5, 0.0]},
         ]},
        "towering soot-black hex columns, graphite cooling seams and silver-grey caps",
        roughness=0.89, smooth=False,
    ),
    AssetRecipe(
        "crystal_emerald", "rock", "rock", "crystal_emerald", 6109, 6.5,
        tuple(map(_rgba, ("08251D", "105741", "20A46B", "8CFFD0"))),
        (280, 920),
        {"shape": "convex_hull"},
        "deep bottle-green crystal bodies with mint facet bands and broad luminous veins",
        "green facet veins glow in daylight and strengthen at night", 0.7,
        roughness=0.25, smooth=False,
    ),
    AssetRecipe(
        "crystal_amethyst", "rock", "rock", "crystal_amethyst", 6110, 8.0,
        tuple(map(_rgba, ("21162E", "56356D", "9C5DC2", "F0BCFF"))),
        (340, 1040),
        {"shape": "convex_hull"},
        "smoky violet bases, amethyst planes and pale branching crystal veins",
        "violet vein tattoos breathe and twinkle after sunset", 0.65,
        roughness=0.29, smooth=False,
    ),
    AssetRecipe(
        "crystal_spire", "rock", "rock", "crystal_spire", 6111, 18.0,
        tuple(map(_rgba, ("082833", "12667A", "20BACF", "B4FFF5"))),
        (300, 980),
        {"shape": "compound",
         "parts": [
             {"shape": "box", "size": [5.0, 18.0, 4.6],
              "centre": [0.0, 9.0, 0.0]},
             {"shape": "sphere", "radius": 5.0, "centre": [0.0, 2.5, 0.0]},
         ]},
        "dark teal roots rising through cyan facets to broad white-aqua energy seams",
        "aqua seams remain visible under sun and cast stronger light at night", 0.78,
        roughness=0.22, smooth=False,
    ),
    AssetRecipe(
        "rune_monolith", "rock", "rock", "rune_monolith", 6112, 13.0,
        tuple(map(_rgba, ("211E29", "413A4D", "6A5D72", "72FFE0"))),
        (100, 420),
        {"shape": "box", "size": [6.2, 13.0, 4.4],
         "centre": [0.0, 6.5, 0.0]},
        "purple-black standing stone crossed by broad angular turquoise tattoos",
        "turquoise glyph paths emerge at dusk with asynchronous breathing", 0.62,
        roughness=0.82, smooth=False,
    ),
    AssetRecipe(
        "rune_boulder", "rock", "rock", "rune_boulder", 6113, 3.8,
        tuple(map(_rgba, ("292630", "4D4658", "71667B", "D187FF"))),
        (260, 780),
        {"shape": "sphere", "radius": 1.9, "centre": [0.0, 1.75, 0.0]},
        "dark plum stone carrying broad lavender loops, chevrons and glyph scars",
        "lavender tattoo paths glow and occasionally twinkle at night", 0.58,
        roughness=0.88, smooth=False,
    ),
    AssetRecipe(
        "cactus_barrel", "desert", "cactus", "barrel", 7101, 1.25,
        tuple(map(_rgba, ("24452F", "397044", "69A25A", "D6C47C", "D27A63"))),
        (360, 960),
        {"shape": "capsule", "radius": 0.48, "height": 1.08,
         "centre": [0.0, 0.54, 0.0]},
        "rib-shadowed green body, straw areoles, and coral crown petals",
    ),
    AssetRecipe(
        "cactus_branching", "desert", "cactus", "branching", 7102, 3.0,
        tuple(map(_rgba, ("203E2E", "356B43", "62A15C", "D6C884", "DF846A"))),
        (520, 1380),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 0.32, "height": 2.75,
              "centre": [0.0, 1.375, 0.0]},
             {"shape": "sphere", "radius": 1.0, "centre": [0.0, 1.85, 0.0]},
         ]},
        "dark rib valleys, sunlit green arms, straw spines, coral flowers",
    ),
    AssetRecipe(
        "joshua_tree", "desert", "cactus", "joshua", 7103, 4.8,
        tuple(map(_rgba, ("403226", "6C5137", "405C3B", "71805A", "B5A36C"))),
        (850, 1780),
        {"shape": "compound",
         "parts": [
             {"shape": "capsule", "radius": 0.3, "height": 3.45,
              "centre": [0.0, 1.725, 0.0]},
             {"shape": "sphere", "radius": 1.25, "centre": [0.0, 3.7, 0.0]},
         ]},
        "fibrous umber branches ending in dense dusty-green blade rosettes",
    ),
    AssetRecipe(
        "firefly_lantern", "glimmer", "glimmer", "firefly", 8101, 1.55,
        tuple(map(_rgba, ("283A31", "4E7051", "A0B86B", "F0DB72", "FFF2B0"))),
        (440, 1180),
        {"shape": "capsule", "radius": 0.43, "height": 1.35,
         "centre": [0.0, 0.675, 0.0]},
        "night-green stems with yellow lantern pods and pale firefly wings",
        "warm yellow-green emission concentrated on pods and motes", 2.2,
        roughness=0.56,
    ),
    AssetRecipe(
        "moth_glimmer", "glimmer", "glimmer", "moth", 8102, 1.75,
        tuple(map(_rgba, ("2B3035", "59616A", "8E91A7", "C8B5D0", "F0D9A1"))),
        (320, 980),
        {"shape": "capsule", "radius": 0.48, "height": 1.5,
         "centre": [0.0, 0.75, 0.0]},
        "charcoal perch and body, layered lavender-grey wings, warm markings",
        "subtle lavender wing emission with warm antenna and dust accents", 1.25,
        roughness=0.62,
    ),
    AssetRecipe(
        "firefly_mote", "flyer", "flyer", "firefly", 9101, 0.16,
        tuple(map(_rgba, ("1A211B", "344332", "697052", "D0A936", "FFF39A"))),
        (150, 300),
        {"shape": "none", "placement": "airborne MultiMesh mote"},
        "black-green beetle shell, smoky pale wings, concentrated gold rear lantern",
        "strong warm yellow rear-segment emission; retain dark body contrast", 3.4,
        roughness=0.52,
    ),
    AssetRecipe(
        "moth_flyer", "flyer", "flyer", "moth", 9102, 0.24,
        tuple(map(_rgba, ("24202A", "5C4A68", "8D7392", "C1A8BC", "E1C982"))),
        (250, 420),
        {"shape": "none", "placement": "airborne MultiMesh moth"},
        "charcoal fur, layered plum wings, pale scallops, and warm eyespots",
        "low violet wing-edge emission with muted warm eyespots", 0.85,
        roughness=0.68,
    ),
    AssetRecipe(
        "dragon_gnat", "flyer", "flyer", "dragon", 9103, 0.28,
        tuple(map(_rgba, ("17272B", "28545B", "4D8990", "96C4C0", "D8E3C8"))),
        (130, 300),
        {"shape": "none", "placement": "airborne MultiMesh dart"},
        "blue-black segmented body, teal compound eyes, and desaturated glass wings",
        "subtle cool bioluminescence along thorax and compound eyes", 0.7,
        roughness=0.46,
    ),
    AssetRecipe(
        "pollen_bug", "flyer", "flyer", "pollen", 9104, 0.14,
        tuple(map(_rgba, ("241E18", "59432B", "A9752D", "D2A84C", "DDD2AD"))),
        (120, 300),
        {"shape": "none", "placement": "airborne MultiMesh pollinator"},
        "dark-and-ochre abdomen bands, russet thorax, and short cream wings",
        "effectively unlit; optional near-zero amber response only", 0.04,
        roughness=0.76,
    ),
)

RECIPE_BY_NAME = {recipe.name: recipe for recipe in RECIPES}


# ---------------------------------------------------------------------------
# Low-level bmesh construction
# ---------------------------------------------------------------------------

def _tag_faces(bm: bmesh.types.BMesh,
               faces: Iterable[bmesh.types.BMFace],
               palette_index: int) -> list[bmesh.types.BMFace]:
    """Attach a palette index without creating material-split GLB primitives."""

    layer = (bm.faces.layers.int.get(PALETTE_ATTRIBUTE)
             or bm.faces.layers.int.new(PALETTE_ATTRIBUTE))
    tagged = list(faces)
    for face in tagged:
        face[layer] = palette_index
        face.smooth = True
    return tagged


def _organic_profile(segments: int, *, lobes: int = 3,
                     amount: float = 0.035, phase: float = 0.0
                     ) -> list[tuple[float, float]]:
    """A subtly imperfect ring avoids machine-perfect cylindrical stems."""

    result = []
    for index in range(segments):
        angle = math.tau * index / segments
        radius = 1.0 + amount * math.sin(lobes * angle + phase)
        result.append((radius * math.cos(angle), radius * math.sin(angle)))
    return result


LEAF_PROFILE = (
    (1.0, 0.0), (0.48, 0.76), (-0.48, 0.76),
    (-1.0, 0.0), (-0.48, -0.76), (0.48, -0.76),
)
RIBBON_PROFILE = ((1.0, 0.0), (0.0, 1.0), (-1.0, 0.0), (0.0, -1.0))


def _safe_side(direction: Vector, hint: Vector | Sequence[float] | None = None
               ) -> Vector:
    direction = Vector(direction).normalized()
    candidate = Vector(hint) if hint is not None else Vector((1.0, 0.0, 0.0))
    candidate -= direction * candidate.dot(direction)
    if candidate.length < 1.0e-5:
        candidate = Vector((0.0, 1.0, 0.0))
        candidate -= direction * candidate.dot(direction)
    return candidate.normalized()


def _add_tube(
    bm: bmesh.types.BMesh,
    points: Sequence[Vector | Sequence[float]],
    radii: Sequence[float] | float,
    palette_index: int,
    *,
    segments: int = 6,
    aspect: float = 1.0,
    phase: float = 0.0,
) -> list[bmesh.types.BMFace]:
    """Create one curved, tapered botanical path with a transported frame."""

    centres = [Vector(point) for point in points]
    if len(centres) < 2:
        raise ValueError("a tube needs at least two path points")
    if isinstance(radii, (int, float)):
        values = [float(radii)] * len(centres)
    else:
        values = [float(radius) for radius in radii]
    if len(values) != len(centres):
        raise ValueError("tube radius count must match path point count")
    direction = centres[1] - centres[0]
    faces = propkit.add_path_loft(
        bm,
        centres,
        [(radius, radius * aspect) for radius in values],
        palette_index,
        wide_hint=_safe_side(direction),
        profile=_organic_profile(segments, phase=phase),
        cap_start=True,
        cap_end=True,
    )
    return _tag_faces(bm, faces, palette_index)


def _add_banded_tube(
    bm: bmesh.types.BMesh,
    points: Sequence[Vector | Sequence[float]],
    radii: Sequence[float],
    palette_indices: Sequence[int],
    *,
    segments: int = 6,
    aspect: float = 1.0,
    phase: float = 0.0,
) -> list[bmesh.types.BMFace]:
    """Create one continuous loft whose axial spans carry different colours.

    This keeps striped insect abdomens topologically coherent.  Building one
    primitive per colour band would read as stacked capsules and would also
    violate the one-primitive GLB contract.
    """

    centres = [Vector(point) for point in points]
    values = [float(radius) for radius in radii]
    if len(centres) < 2 or len(values) != len(centres):
        raise ValueError("banded tube points and radii must match")
    if len(palette_indices) != len(centres) - 1:
        raise ValueError("banded tube needs one palette index per axial span")
    faces = propkit.add_path_loft(
        bm,
        centres,
        [(radius, radius * aspect) for radius in values],
        int(palette_indices[0]),
        wide_hint=_safe_side(centres[1] - centres[0]),
        profile=_organic_profile(segments, phase=phase),
        cap_start=True,
        cap_end=True,
    )
    # add_loft emits `segments` side faces per span, then its two caps.
    for span, palette_index in enumerate(palette_indices):
        _tag_faces(
            bm,
            faces[span * segments:(span + 1) * segments],
            int(palette_index),
        )
    _tag_faces(bm, faces[-2:-1], int(palette_indices[0]))
    _tag_faces(bm, faces[-1:], int(palette_indices[-1]))
    return faces


def _add_ribbon(
    bm: bmesh.types.BMesh,
    points: Sequence[Vector | Sequence[float]],
    half_widths: Sequence[float],
    palette_index: int,
    *,
    thickness: float,
    side_hint: Vector | Sequence[float] | None = None,
    leaf_profile: bool = False,
) -> list[bmesh.types.BMFace]:
    """Create a closed, thin lamina instead of a zero-thickness billboard."""

    centres = [Vector(point) for point in points]
    if len(centres) != len(half_widths):
        raise ValueError("ribbon widths must match path points")
    direction = centres[1] - centres[0]
    profile = LEAF_PROFILE if leaf_profile else RIBBON_PROFILE
    faces = propkit.add_path_loft(
        bm,
        centres,
        [(float(width), thickness * (0.72 + 0.28 * math.sin(
            math.pi * index / max(1, len(centres) - 1))))
         for index, width in enumerate(half_widths)],
        palette_index,
        wide_hint=_safe_side(direction, side_hint),
        profile=profile,
        cap_start=True,
        cap_end=True,
    )
    return _tag_faces(bm, faces, palette_index)


def _add_leaf(
    bm: bmesh.types.BMesh,
    origin: Vector | Sequence[float],
    direction: Vector | Sequence[float],
    length: float,
    half_width: float,
    palette_index: int,
    *,
    side_hint: Vector | Sequence[float] | None = None,
    curl: float = 0.12,
    wave: float = 0.025,
    samples: int = 4,
    low_poly: bool = False,
) -> list[bmesh.types.BMFace]:
    """Loft a pointed, cambered leaf/petal along a curved centre line."""

    start = Vector(origin)
    axis = Vector(direction).normalized()
    side = _safe_side(axis, side_hint)
    normal = axis.cross(side).normalized()
    points: list[Vector] = []
    widths: list[float] = []
    for index in range(samples):
        t = index / (samples - 1)
        centre = (
            start
            + axis * length * t
            + normal * length * curl * math.sin(math.pi * t)
            + side * length * wave * math.sin(math.tau * t)
        )
        points.append(centre)
        envelope = math.sin(math.pi * t) ** 0.68
        widths.append(half_width * max(0.035, (0.14 + 0.86 * envelope) * (1.0 - 0.16 * t)))
    if low_poly:
        return _add_ribbon(
            bm, points, widths, palette_index,
            thickness=max(half_width * 0.065, 0.0025),
            side_hint=side, leaf_profile=False,
        )
    return _add_ribbon(
        bm, points, widths, palette_index,
        thickness=max(half_width * 0.075, 0.003),
        side_hint=side, leaf_profile=True,
    )


def _add_profiled_hull(
    bm: bmesh.types.BMesh,
    centre: Vector | Sequence[float],
    axis: Vector | Sequence[float],
    levels: Sequence[tuple[float, float, float]],
    palette_index: int,
    *,
    segments: int = 8,
    lobes: int = 0,
    lobe_amount: float = 0.0,
    phase: float = 0.0,
    skew: Vector | Sequence[float] = (0.0, 0.0, 0.0),
) -> list[bmesh.types.BMFace]:
    """Build an authored radial profile with optional lobes and axial skew.

    A level is ``(distance_along_axis, radius_u, radius_v)``.  Zero-radius
    levels become true poles, so caps do not contain collapsed duplicate rings.
    """

    origin = Vector(centre)
    axis_vector = Vector(axis).normalized()
    u = _safe_side(axis_vector)
    v = axis_vector.cross(u).normalized()
    skew_vector = Vector(skew)
    rings: list[list[bmesh.types.BMVert]] = []
    for level_index, (distance, radius_u, radius_v) in enumerate(levels):
        level_centre = origin + axis_vector * distance + skew_vector * distance * distance
        if max(abs(radius_u), abs(radius_v)) < 1.0e-6:
            rings.append([bm.verts.new(level_centre)])
            continue
        ring = []
        for index in range(segments):
            angle = math.tau * index / segments
            modulation = 1.0
            if lobes:
                modulation += lobe_amount * math.cos(lobes * angle + phase)
            modulation += 0.018 * math.sin(
                angle * (3 + (level_index % 2)) + phase + level_index * 0.73)
            point = (
                level_centre
                + u * (radius_u * modulation * math.cos(angle))
                + v * (radius_v * modulation * math.sin(angle))
            )
            ring.append(bm.verts.new(point))
        rings.append(ring)

    faces: list[bmesh.types.BMFace] = []
    for lower, upper in zip(rings, rings[1:]):
        if len(lower) == 1 and len(upper) == 1:
            continue
        if len(lower) == 1:
            pole = lower[0]
            for index in range(segments):
                faces.append(bm.faces.new(
                    (pole, upper[index], upper[(index + 1) % segments])))
        elif len(upper) == 1:
            pole = upper[0]
            for index in range(segments):
                faces.append(bm.faces.new(
                    (lower[index], pole, lower[(index + 1) % segments])))
        else:
            for index in range(segments):
                next_index = (index + 1) % segments
                faces.append(bm.faces.new(
                    (lower[index], upper[index], upper[next_index], lower[next_index])))
    if len(rings[0]) > 1:
        faces.append(bm.faces.new(tuple(reversed(rings[0]))))
    if len(rings[-1]) > 1:
        faces.append(bm.faces.new(tuple(rings[-1])))
    return _tag_faces(bm, faces, palette_index)


def _curved_stem(
    bm: bmesh.types.BMesh,
    start: Vector,
    direction: Vector,
    length: float,
    base_radius: float,
    palette_index: int,
    *,
    sway: Vector = Vector((0.0, 0.0, 0.0)),
    samples: int = 4,
    segments: int = 6,
    tip_ratio: float = 0.28,
    phase: float = 0.0,
) -> tuple[list[Vector], Vector]:
    """Add a tapered path and return its sampled path and final tangent."""

    axis = direction.normalized()
    points = []
    radii = []
    for index in range(samples):
        t = index / (samples - 1)
        points.append(
            start + axis * length * t
            # t*sin(pi*t) has zero derivative at the origin.  Grounded stems
            # therefore begin upright with a level cap, then acquire their
            # authored sweep farther up instead of balancing on a tilted edge.
            + sway * length * 1.35 * t * math.sin(math.pi * t))
        radii.append(base_radius * ((1.0 - t) * (1.0 - tip_ratio) + tip_ratio))
    _add_tube(
        bm, points, radii, palette_index,
        segments=segments, phase=phase,
    )
    tangent = (points[-1] - points[-2]).normalized()
    return points, tangent


def _direction(azimuth: float, elevation: float) -> Vector:
    horizontal = math.cos(elevation)
    return Vector((
        math.cos(azimuth) * horizontal,
        math.sin(azimuth) * horizontal,
        math.sin(elevation),
    ))


def _grow_branches(
    bm: bmesh.types.BMesh,
    rng: random.Random,
    start: Vector,
    direction: Vector,
    length: float,
    radius: float,
    depth: int,
    palette_index: int,
    *,
    phase: float,
    segments: int = 6,
    spread: float = 0.72,
) -> list[tuple[Vector, Vector]]:
    """Deterministic binary botanical branching with tapered curved paths."""

    side_angle = phase + rng.uniform(-0.32, 0.32)
    sway = Vector((math.cos(side_angle), math.sin(side_angle), 0.12))
    path, tangent = _curved_stem(
        bm, start, direction, length, radius, palette_index,
        sway=sway * (0.10 + 0.035 * depth),
        samples=4, segments=segments,
        tip_ratio=0.42 if depth else 0.2, phase=phase,
    )
    if depth <= 0:
        return [(path[-1], tangent)]

    tips: list[tuple[Vector, Vector]] = []
    child_start = path[-2].lerp(path[-1], 0.30)
    for child_index in range(2):
        azimuth = phase + child_index * math.pi + rng.uniform(-0.22, 0.22)
        outward = Vector((math.cos(azimuth), math.sin(azimuth), 0.0))
        child_direction = (
            tangent * 0.38
            + outward * spread
            + Vector((0.0, 0.0, 0.42 + rng.uniform(-0.08, 0.11)))
        ).normalized()
        tips.extend(_grow_branches(
            bm, rng, child_start, child_direction,
            length * rng.uniform(0.58, 0.68),
            radius * 0.61, depth - 1, palette_index,
            phase=azimuth + rng.uniform(-0.2, 0.2),
            segments=max(5, segments - 1), spread=spread * 0.92,
        ))
    return tips


def _grow_planar_fan(
    bm: bmesh.types.BMesh,
    rng: random.Random,
    start: Vector,
    direction: Vector,
    length: float,
    radius: float,
    depth: int,
    palette_index: int,
    *,
    sign: float = 1.0,
) -> list[tuple[Vector, Vector]]:
    """Recursive sea-fan veins constrained to a gently rippled XZ plane."""

    lateral = Vector((sign * 0.08, rng.uniform(-0.018, 0.018), 0.0))
    path, tangent = _curved_stem(
        bm, start, direction, length, radius, palette_index,
        sway=lateral, samples=4, segments=5,
        tip_ratio=0.42 if depth else 0.18,
        phase=depth * 0.9 + sign,
    )
    if depth <= 0:
        return [(path[-1], tangent)]

    tips = []
    branch_start = path[-2].lerp(path[-1], 0.22)
    spread = math.radians(22.0 + depth * 4.0)
    for child_sign in (-1.0, 1.0):
        rotated = Matrix.Rotation(child_sign * spread, 4, "Y") @ tangent
        rotated.y += rng.uniform(-0.035, 0.035)
        rotated.normalize()
        tips.extend(_grow_planar_fan(
            bm, rng, branch_start, rotated,
            length * rng.uniform(0.61, 0.69), radius * 0.62,
            depth - 1, palette_index,
            sign=child_sign,
        ))
    return tips


def _petal_whorl(
    bm: bmesh.types.BMesh,
    centre: Vector,
    count: int,
    length: float,
    width: float,
    palette_index: int,
    *,
    elevation: float = 0.15,
    phase: float = 0.0,
    droop: float = 0.08,
    low_poly: bool = True,
) -> None:
    for index in range(count):
        angle = phase + math.tau * index / count
        direction = _direction(angle, elevation)
        side = Vector((-math.sin(angle), math.cos(angle), 0.0))
        _add_leaf(
            bm, centre, direction, length, width, palette_index,
            side_hint=side, curl=-droop, wave=0.012,
            samples=3 if low_poly else 4, low_poly=low_poly,
        )


# ---------------------------------------------------------------------------
# Reusable archetype builders
# ---------------------------------------------------------------------------

def _build_aquatic(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form == "ribbon":
        _add_profiled_hull(
            bm, (0.0, 0.0, 0.0), (0.0, 0.0, 1.0),
            ((0.0, 0.18, 0.14), (0.055, 0.22, 0.17),
             (0.11, 0.13, 0.11), (0.15, 0.025, 0.025)),
            0, segments=9, lobes=5, lobe_amount=0.08, phase=0.4,
        )
        for index in range(5):
            angle = index * GOLDEN_ANGLE
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
            start = radial * 0.07 + Vector((0.0, 0.0, 0.10))
            points = []
            widths = []
            for sample in range(7):
                t = sample / 6.0
                points.append(
                    start
                    + Vector((0.0, 0.0, 0.92 * t))
                    + radial * (0.11 * t + 0.07 * math.sin(math.pi * t))
                    + tangent * (0.075 * math.sin(math.tau * (t + index * 0.13))
                                 * (0.3 + 0.7 * t))
                )
                widths.append((0.035 + 0.075 * math.sin(math.pi * t) ** 0.7)
                              * (0.9 + rng.uniform(-0.06, 0.06)))
            _add_ribbon(
                bm, points, widths, 1 + index % 3,
                thickness=0.009, side_hint=tangent,
            )
        return

    if recipe.form == "fan":
        _add_profiled_hull(
            bm, (0.0, 0.0, 0.0), (0.0, 0.0, 1.0),
            ((0.0, 0.20, 0.09), (0.045, 0.24, 0.10),
             (0.10, 0.11, 0.055), (0.15, 0.025, 0.018)),
            0, segments=8, lobes=4, lobe_amount=0.07,
        )
        tips = _grow_planar_fan(
            bm, rng, Vector((0.0, 0.0, 0.10)),
            Vector((0.0, 0.0, 1.0)), 0.43, 0.042, 3, 1,
        )
        for index, (tip, tangent) in enumerate(tips):
            outward = Vector((tangent.x, 0.0, max(0.15, tangent.z))).normalized()
            _add_leaf(
                bm, tip - tangent * 0.03, outward,
                0.15, 0.043, 2 + index % 2,
                side_hint=(0.0, 1.0, 0.0), curl=0.06,
                samples=3, low_poly=True,
            )
        # Fine cross-veins join neighbouring terminals into a recognisable
        # reticulated fan instead of leaving a bare tree-shaped skeleton.
        ordered_tips = sorted((tip for tip, _tangent in tips), key=lambda item: item.x)
        for index, (left, right) in enumerate(zip(ordered_tips, ordered_tips[1:])):
            midpoint = left.lerp(right, 0.5)
            midpoint.y += 0.012 * (-1.0 if index % 2 else 1.0)
            _add_tube(
                bm, (left, midpoint, right),
                (0.008, 0.0065, 0.008), 3,
                segments=4, phase=index * 0.7,
            )
        return

    if recipe.form == "bulb":
        _add_profiled_hull(
            bm, (0.0, 0.0, 0.0), (0.0, 0.0, 1.0),
            ((0.0, 0.20, 0.17), (0.045, 0.23, 0.19),
             (0.10, 0.13, 0.12), (0.14, 0.025, 0.025)),
            0, segments=9, lobes=5, lobe_amount=0.06,
        )
        for index in range(5):
            angle = index * GOLDEN_ANGLE + 0.4
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            start = radial * 0.065 + Vector((0.0, 0.0, 0.09))
            path, tangent = _curved_stem(
                bm, start, Vector((radial.x * 0.12, radial.y * 0.12, 1.0)),
                0.53 + index * 0.035, 0.022, 1,
                sway=radial * (0.10 + index * 0.012),
                samples=4, segments=5, phase=angle,
            )
            bulb_centre = path[-1] - tangent * 0.018
            _add_profiled_hull(
                bm, bulb_centre, tangent,
                ((-0.07, 0.018, 0.018), (-0.04, 0.065, 0.055),
                 (0.02, 0.085, 0.070), (0.09, 0.055, 0.050),
                 (0.13, 0.012, 0.012)),
                2, segments=8, lobes=3, lobe_amount=0.055, phase=angle,
                skew=radial * 0.03,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            _add_leaf(
                bm, bulb_centre + tangent * 0.10,
                (tangent * 0.65 + radial * 0.35).normalized(),
                0.32, 0.045, 3,
                side_hint=side, curl=0.17, samples=3, low_poly=True,
            )
        return

    raise ValueError("unknown aquatic form {!r}".format(recipe.form))


def _build_grass(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    _add_profiled_hull(
        bm, (0.0, 0.0, 0.0), (0.0, 0.0, 1.0),
        ((0.0, 0.11, 0.10), (0.025, 0.14, 0.12),
         (0.055, 0.07, 0.065), (0.075, 0.015, 0.015)),
        0, segments=7, lobes=3, lobe_amount=0.08,
    )

    if recipe.form == "fan":
        for index in range(9):
            angle = -1.10 + index * 2.20 / 8.0
            depth = (index % 3 - 1) * 0.045
            side = Vector((math.cos(angle), math.sin(angle), 0.0))
            start = Vector((depth, depth * 0.5, 0.035))
            direction = Vector((0.42 * math.sin(angle), depth, 0.91)).normalized()
            points = []
            widths = []
            for sample in range(5):
                t = sample / 4.0
                points.append(
                    start + direction * (0.62 + 0.06 * math.cos(index)) * t
                    + side * 0.09 * math.sin(math.pi * t) * (index / 8.0 - 0.5))
                widths.append(0.012 + 0.035 * math.sin(math.pi * t) ** 0.72)
            _add_ribbon(
                bm, points, widths, 1 + index % 3,
                thickness=0.0045, side_hint=side,
            )
        return

    if recipe.form == "feather":
        for stem_index in range(4):
            angle = math.tau * stem_index / 4.0 + 0.35
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            path, tangent = _curved_stem(
                bm, radial * 0.035 + Vector((0.0, 0.0, 0.045)),
                Vector((radial.x * 0.16, radial.y * 0.16, 1.0)),
                0.64 + rng.uniform(-0.035, 0.035), 0.011, 1,
                sway=radial * 0.12, samples=4, segments=4,
                tip_ratio=0.18, phase=angle,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            for leaf_index in range(4):
                t = 0.38 + leaf_index * 0.14
                position = path[0].lerp(path[-1], t)
                sign = -1.0 if leaf_index % 2 else 1.0
                feather_direction = (
                    tangent * 0.30 + side * sign * 0.88
                    + Vector((0.0, 0.0, 0.10))
                ).normalized()
                _add_leaf(
                    bm, position, feather_direction,
                    0.12 + 0.018 * (3 - leaf_index),
                    0.018, 2 + leaf_index % 2,
                    side_hint=radial, curl=0.07, wave=0.01,
                    samples=3, low_poly=True,
                )
        return

    raise ValueError("unknown grass form {!r}".format(recipe.form))


def _build_shrub(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form == "heather":
        for stem_index in range(7):
            angle = stem_index * GOLDEN_ANGLE
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            start = radial * 0.055
            path, tangent = _curved_stem(
                bm, start, Vector((radial.x * 0.22, radial.y * 0.22, 1.0)),
                0.66 + rng.uniform(-0.08, 0.08), 0.012, 0,
                sway=radial * 0.15, samples=4, segments=4,
                tip_ratio=0.16, phase=angle,
            )
            for flower_index in range(2):
                t = 0.70 + flower_index * 0.20
                centre = path[0].lerp(path[-1], t)
                flower_axis = (
                    tangent * 0.45 + radial * 0.65
                    + Vector((0.0, 0.0, 0.10))
                ).normalized()
                _add_profiled_hull(
                    bm, centre, flower_axis,
                    ((-0.028, 0.018, 0.018), (0.0, 0.040, 0.038),
                     (0.055, 0.050, 0.047), (0.088, 0.028, 0.027)),
                    2 + flower_index, segments=6, lobes=4,
                    lobe_amount=0.07, phase=angle,
                )
            needle_side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            _add_leaf(
                bm, path[1], (radial + Vector((0.0, 0.0, 0.2))).normalized(),
                0.13, 0.014, 1,
                side_hint=needle_side, curl=0.06,
                samples=3, low_poly=True,
            )
        return

    depth = 2
    tips = _grow_branches(
        bm, rng, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
        0.39 if recipe.form == "broadleaf" else 0.36,
        0.055, depth, 0, phase=0.4,
        segments=6 if recipe.form == "broadleaf" else 5,
        spread=0.82,
    )
    if recipe.form == "broadleaf":
        all_sites = list(tips)
        for index in range(6):
            angle = index * GOLDEN_ANGLE
            all_sites.append((
                Vector((0.12 * math.cos(angle), 0.12 * math.sin(angle),
                        0.28 + 0.075 * index)),
                _direction(angle, 0.36),
            ))
        for index, (tip, tangent) in enumerate(all_sites):
            for layer in range(2):
                angle = index * GOLDEN_ANGLE + layer * 1.32
                side = Vector((-math.sin(angle), math.cos(angle), 0.0))
                direction = (
                    tangent * (0.42 - 0.08 * layer)
                    + _direction(angle, 0.24 - 0.10 * layer) * 0.72
                ).normalized()
                _add_leaf(
                    bm, tip - tangent * (0.025 + 0.008 * layer), direction,
                    0.23 + 0.025 * (index % 3) - 0.02 * layer,
                    0.082 - 0.008 * layer,
                    2 + (index + layer) % 2, side_hint=side,
                    curl=0.11 - 0.035 * layer,
                    wave=0.018, samples=4,
                )
        return

    if recipe.form == "silver":
        sites = list(tips)
        for index in range(8):
            angle = index * GOLDEN_ANGLE + 0.6
            sites.append((
                Vector((0.10 * math.cos(angle), 0.10 * math.sin(angle),
                        0.20 + 0.072 * index)),
                _direction(angle, 0.25),
            ))
        for index, (tip, tangent) in enumerate(sites):
            for layer in range(2):
                angle = index * GOLDEN_ANGLE + layer * 1.48
                side = Vector((-math.sin(angle), math.cos(angle), 0.0))
                outward = (
                    tangent * (0.38 - layer * 0.08)
                    + _direction(angle, 0.18 - layer * 0.08) * 0.82
                ).normalized()
                _add_leaf(
                    bm, tip - tangent * 0.008 * layer, outward,
                    0.21 - 0.025 * layer, 0.038 - 0.004 * layer,
                    2 + (index + layer) % 2, side_hint=side,
                    curl=0.07 - 0.025 * layer,
                    wave=0.012, samples=3, low_poly=True,
                )
        return

    raise ValueError("unknown shrub form {!r}".format(recipe.form))


def _build_tree(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form == "canopy":
        tips = _grow_branches(
            bm, rng, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
            0.43, 0.070, 3, 0, phase=0.2, segments=7, spread=0.72,
        )
        for index, (tip, tangent) in enumerate(tips):
            for layer in range(3):
                angle = index * GOLDEN_ANGLE + layer * 1.32
                outward = _direction(angle, 0.22 - layer * 0.18)
                direction = (tangent * 0.28 + outward * 0.88).normalized()
                side = Vector((-math.sin(angle), math.cos(angle), 0.0))
                _add_leaf(
                    bm, tip - tangent * 0.025, direction,
                    0.27 - layer * 0.022, 0.105 - layer * 0.008,
                    2 + (index + layer) % 3,
                    side_hint=side, curl=0.12 - layer * 0.035,
                    wave=0.018, samples=4,
                )
        return

    if recipe.form == "spiral":
        trunk_points = []
        trunk_radii = []
        for index in range(7):
            t = index / 6.0
            angle = math.tau * 0.72 * t
            trunk_points.append(Vector((
                0.055 * math.sin(angle) * t,
                0.055 * math.cos(angle) * t,
                0.76 * t,
            )))
            trunk_radii.append(0.074 * (1.0 - 0.62 * t))
        _add_tube(bm, trunk_points, trunk_radii, 0, segments=8, phase=0.3)
        for index in range(14):
            t = 0.16 + index * 0.055
            angle = index * GOLDEN_ANGLE + 0.5
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            origin = Vector((0.0, 0.0, 0.76 * t))
            branch_direction = (radial * 0.82 + Vector((0.0, 0.0, 0.34))).normalized()
            branch_path, tangent = _curved_stem(
                bm, origin, branch_direction,
                0.20 + 0.045 * math.sin(math.pi * t),
                0.020 * (1.0 - 0.42 * t), 1,
                sway=radial * 0.06, samples=3, segments=5,
                tip_ratio=0.25, phase=angle,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            _add_leaf(
                bm, branch_path[-1] - tangent * 0.02,
                (tangent * 0.65 + radial * 0.35).normalized(),
                0.25, 0.065, 2 + index % 3,
                side_hint=side, curl=0.13, samples=4, low_poly=True,
            )
        _petal_whorl(
            bm, trunk_points[-1] - Vector((0.0, 0.0, 0.015)),
            5, 0.24, 0.058, 4, elevation=0.42,
            phase=0.7, droop=-0.08, low_poly=True,
        )
        return

    if recipe.form == "umbrella":
        trunk, _tangent = _curved_stem(
            bm, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
            0.72, 0.070, 0, sway=Vector((0.045, -0.02, 0.0)),
            samples=5, segments=8, tip_ratio=0.45, phase=0.8,
        )
        crown = trunk[-1]
        for index in range(8):
            angle = math.tau * index / 8.0 + 0.16
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            points = [
                crown,
                crown + radial * 0.16 + Vector((0.0, 0.0, 0.035)),
                crown + radial * 0.34 + Vector((0.0, 0.0, 0.005)),
                crown + radial * 0.49 + Vector((0.0, 0.0, -0.09)),
            ]
            _add_tube(
                bm, points, (0.033, 0.028, 0.020, 0.010),
                1, segments=6, phase=angle,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            for layer in range(2):
                leaf_origin = points[2 + layer]
                direction = (
                    radial * (0.92 - 0.08 * layer)
                    + Vector((0.0, 0.0, -0.25 - layer * 0.12))
                    + side * (0.18 if layer else -0.12)
                ).normalized()
                _add_leaf(
                    bm, leaf_origin, direction,
                    0.30 - 0.025 * layer, 0.105,
                    2 + (index + layer) % 3,
                    side_hint=side, curl=-0.08 - layer * 0.04,
                    wave=0.02, samples=4,
                )
        _petal_whorl(
            bm, crown + Vector((0.0, 0.0, 0.018)),
            8, 0.31, 0.090, 3, elevation=0.04,
            phase=0.53, droop=0.055, low_poly=False,
        )
        return

    if recipe.form == "skyneedle":
        # A genuinely slender high tree. Runtime clustering, rather than extra
        # trunks baked into this mesh, creates the close cathedral-like groves.
        trunk_points = []
        trunk_radii = []
        for index in range(9):
            t = index / 8.0
            bend = math.sin(t * math.pi * 0.82)
            trunk_points.append(Vector((
                0.018 * bend * math.sin(t * 3.2),
                -0.014 * bend * math.cos(t * 2.6),
                0.91 * t,
            )))
            trunk_radii.append(0.031 * (1.0 - 0.64 * t))
        _add_tube(bm, trunk_points, trunk_radii, 0, segments=8, phase=0.15)

        for index in range(15):
            t = 0.43 + index * 0.035
            angle = index * GOLDEN_ANGLE + 0.28
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            bend = math.sin(t * math.pi * 0.82)
            origin = Vector((
                0.018 * bend * math.sin(t * 3.2),
                -0.014 * bend * math.cos(t * 2.6),
                0.91 * t,
            ))
            crown_envelope = math.sin(
                math.pi * _clamp01((t - 0.40) / 0.60)) ** 0.72
            branch_length = 0.10 + crown_envelope * 0.15
            branch_path, tangent = _curved_stem(
                bm, origin,
                (radial * 0.86 + Vector((0.0, 0.0, 0.24))).normalized(),
                branch_length, 0.0105 * (1.0 - 0.45 * t), 1,
                sway=radial * 0.035, samples=3, segments=5,
                tip_ratio=0.20, phase=angle,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            for layer in range(3):
                leaf_angle = angle + (layer - 1) * 0.34
                leaf_radial = Vector((
                    math.cos(leaf_angle), math.sin(leaf_angle), 0.0))
                direction = (
                    leaf_radial * (0.72 + layer * 0.05)
                    + Vector((0.0, 0.0, 0.42 - layer * 0.17))
                    + tangent * 0.18
                ).normalized()
                _add_leaf(
                    bm, branch_path[-1] - tangent * (0.012 * layer),
                    direction, 0.25 - layer * 0.018,
                    0.040 - layer * 0.003,
                    2 + (index + layer) % 3,
                    side_hint=side, curl=0.09 - layer * 0.02,
                    wave=0.010 * (-1.0 if layer == 0 else 1.0),
                    samples=4, low_poly=True,
                )
        _petal_whorl(
            bm, trunk_points[-1], 6, 0.22, 0.038, 4,
            elevation=0.58, phase=0.42, droop=-0.04, low_poly=True,
        )
        return

    if recipe.form == "cloudbough":
        # The leaf laminae overlap in several horizontal tiers, producing a
        # real shadow-casting ceiling while keeping collision on the trunk only.
        trunk, _tangent = _curved_stem(
            bm, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
            0.69, 0.074, 0, sway=Vector((0.035, -0.025, 0.0)),
            samples=6, segments=9, tip_ratio=0.44, phase=0.67,
        )
        crown = trunk[-1]
        for index in range(10):
            angle = math.tau * index / 10.0 + 0.11
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            lift = 0.020 + 0.035 * (index % 3)
            points = (
                crown + Vector((0.0, 0.0, -0.035 * (index % 2))),
                crown + radial * 0.19 + Vector((0.0, 0.0, lift)),
                crown + radial * 0.43 + Vector((0.0, 0.0, lift * 0.6)),
                crown + radial * 0.66 + Vector((0.0, 0.0, -0.025)),
            )
            _add_tube(
                bm, points, (0.040, 0.032, 0.021, 0.008),
                1, segments=6, phase=angle,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            for layer in range(4):
                along = 0.31 + layer * 0.105
                leaf_origin = crown + radial * along + Vector((
                    0.0, 0.0, 0.035 + 0.022 * (layer % 2)))
                sweep = (layer - 1.5) * 0.25
                direction = (
                    radial * 0.76 + side * sweep
                    + Vector((0.0, 0.0, -0.06 + layer * 0.025))
                ).normalized()
                _add_leaf(
                    bm, leaf_origin, direction,
                    0.43 - 0.025 * (layer % 2),
                    0.170 - 0.012 * (layer % 3),
                    2 + (index + layer) % 3,
                    side_hint=side, curl=-0.035 + layer * 0.018,
                    wave=0.018 * (-1.0 if index % 2 else 1.0),
                    samples=5, low_poly=True,
                )
        # A second rosette seals the skylight directly above the trunk.
        _petal_whorl(
            bm, crown + Vector((0.0, 0.0, 0.055)),
            10, 0.50, 0.155, 3, elevation=0.05,
            phase=0.43, droop=0.015, low_poly=True,
        )
        return

    if recipe.form == "orb_giant":
        # Buttressed, deliberately oversized trunk.
        _add_profiled_hull(
            bm, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
            ((0.0, 0.170, 0.160), (0.12, 0.145, 0.135),
             (0.48, 0.105, 0.098), (0.73, 0.082, 0.078),
             (0.79, 0.052, 0.050)),
            0, segments=12, lobes=5, lobe_amount=0.07, phase=0.4,
            skew=(0.012, -0.008, 0.0),
        )
        for root_index in range(7):
            angle = root_index * math.tau / 7.0 + 0.12
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            _add_tube(
                bm,
                (Vector((0.0, 0.0, 0.10)),
                 radial * 0.16 + Vector((0.0, 0.0, 0.045)),
                 radial * 0.30 + Vector((0.0, 0.0, 0.006))),
                (0.050, 0.027, 0.004), 1, segments=6, phase=angle,
            )

        crown = Vector((0.008, -0.005, 0.82))
        for branch_index in range(12):
            angle = branch_index * GOLDEN_ANGLE
            elevation = -0.30 + 0.60 * ((branch_index % 4) / 3.0)
            radial = _direction(angle, elevation)
            _add_tube(
                bm,
                (Vector((0.008, -0.005, 0.69)),
                 crown + radial * 0.15,
                 crown + radial * 0.34),
                (0.038, 0.024, 0.007), 1,
                segments=6, phase=angle,
            )

        # A Fibonacci distribution of broad individual laminae reads as a
        # sphere of leaves, but has a much richer silhouette than a solid ball.
        leaf_count = 46
        for index in range(leaf_count):
            z = 1.0 - 2.0 * ((index + 0.5) / leaf_count)
            radius = math.sqrt(max(0.0, 1.0 - z * z))
            angle = index * GOLDEN_ANGLE + 0.2
            direction = Vector((
                radius * math.cos(angle), radius * math.sin(angle), z))
            origin = crown + direction * (0.055 + 0.030 * (index % 3))
            tangent_side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            _add_leaf(
                bm, origin, direction,
                0.38 + 0.055 * (index % 4),
                0.145 + 0.018 * (index % 3),
                2 + index % 3,
                side_hint=tangent_side,
                curl=0.08 * (1.0 if index % 2 else -1.0),
                wave=0.020 * (1.0 if index % 3 else -1.0),
                samples=5, low_poly=True,
            )
        return

    if recipe.form == "corkscrew":
        # Two living ribbons spiral around one another. The paired stems remain
        # inside one conservative trunk collision cylinder at runtime.
        for stem_index in range(2):
            points = []
            radii = []
            phase = stem_index * math.pi
            for index in range(12):
                t = index / 11.0
                angle = phase + t * math.tau * 1.72
                helix_radius = 0.050 + 0.030 * math.sin(math.pi * t)
                points.append(Vector((
                    math.cos(angle) * helix_radius,
                    math.sin(angle) * helix_radius,
                    0.82 * t,
                )))
                radii.append(0.046 * (1.0 - 0.60 * t))
            _add_tube(
                bm, points, radii, stem_index,
                segments=7, phase=phase + 0.2,
            )

        for index in range(16):
            t = 0.17 + index * 0.045
            angle = index * GOLDEN_ANGLE + 0.36
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            helix = angle + (index % 2) * math.pi
            origin = Vector((
                math.cos(helix) * (0.052 + 0.026 * math.sin(math.pi * t)),
                math.sin(helix) * (0.052 + 0.026 * math.sin(math.pi * t)),
                0.82 * t,
            ))
            path, tangent = _curved_stem(
                bm, origin,
                (radial * 0.85 + Vector((0.0, 0.0, 0.30))).normalized(),
                0.20 + 0.07 * math.sin(math.pi * t),
                0.015 * (1.0 - 0.45 * t), 1,
                sway=radial * 0.075, samples=3, segments=5,
                tip_ratio=0.18, phase=angle,
            )
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            for layer in range(2):
                leaf_angle = angle + (-0.38 if layer == 0 else 0.42)
                leaf_radial = Vector((
                    math.cos(leaf_angle), math.sin(leaf_angle), 0.0))
                _add_leaf(
                    bm, path[-1] - tangent * 0.012,
                    (leaf_radial * 0.78
                     + Vector((0.0, 0.0, 0.22 - layer * 0.28))).normalized(),
                    0.26 + 0.025 * ((index + layer) % 3),
                    0.082 + 0.008 * (index % 2),
                    2 + (index + layer) % 3,
                    side_hint=side, curl=0.12 * (-1.0 if layer else 1.0),
                    wave=0.025 * (-1.0 if index % 2 else 1.0),
                    samples=4, low_poly=True,
                )
        _petal_whorl(
            bm, Vector((0.0, 0.0, 0.83)),
            9, 0.34, 0.105, 4, elevation=0.18,
            phase=0.67, droop=-0.015, low_poly=True,
        )
        return

    raise ValueError("unknown tree form {!r}".format(recipe.form))


def _mushroom_cap(
    bm: bmesh.types.BMesh,
    centre: Vector,
    radius: float,
    palette_index: int,
    *,
    phase: float,
    bell: bool = False,
    segments: int = 8,
) -> None:
    if bell:
        levels = (
            (-0.08 * radius, 0.48 * radius, 0.45 * radius),
            (0.00, 0.88 * radius, 0.84 * radius),
            (0.25 * radius, radius, 0.94 * radius),
            (0.66 * radius, 0.72 * radius, 0.68 * radius),
            (0.94 * radius, 0.18 * radius, 0.18 * radius),
        )
    else:
        levels = (
            (-0.18 * radius, 0.42 * radius, 0.40 * radius),
            (-0.04 * radius, radius, 0.92 * radius),
            (0.20 * radius, 0.92 * radius, 0.86 * radius),
            (0.52 * radius, 0.48 * radius, 0.46 * radius),
            (0.68 * radius, 0.08 * radius, 0.08 * radius),
        )
    _add_profiled_hull(
        bm, centre, (0.0, 0.0, 1.0), levels, palette_index,
        segments=segments, lobes=5, lobe_amount=0.055, phase=phase,
        skew=(0.025 * math.cos(phase), 0.025 * math.sin(phase), 0.0),
    )


def _build_mushroom(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form in {"cluster", "lantern"}:
        count = 7 if recipe.form == "cluster" else 4
        for index in range(count):
            angle = index * GOLDEN_ANGLE
            ring = 0.05 + 0.045 * (index % 3)
            start = Vector((math.cos(angle) * ring, math.sin(angle) * ring, 0.0))
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            length = (
                0.35 + rng.uniform(-0.07, 0.09)
                if recipe.form == "cluster"
                else 0.58 + rng.uniform(-0.08, 0.08)
            )
            path, tangent = _curved_stem(
                bm, start, Vector((radial.x * 0.08, radial.y * 0.08, 1.0)),
                length, 0.030 if recipe.form == "cluster" else 0.025,
                1 if recipe.form == "cluster" else 0,
                sway=radial * (0.08 if recipe.form == "cluster" else 0.15),
                samples=4, segments=6,
                tip_ratio=0.68 if recipe.form == "cluster" else 0.52,
                phase=angle,
            )
            cap_radius = (
                0.12 + 0.018 * (index % 3)
                if recipe.form == "cluster"
                else 0.15 + 0.012 * (index % 2)
            )
            _mushroom_cap(
                bm, path[-1] - tangent * cap_radius * 0.08,
                cap_radius, 2 + index % 2, phase=angle,
                bell=recipe.form == "lantern",
                segments=8 if recipe.form == "cluster" else 10,
            )
            if recipe.form == "lantern":
                for gill in range(2):
                    gill_angle = angle + (gill * 2 - 1) * 0.6
                    direction = _direction(gill_angle, -0.72)
                    _add_leaf(
                        bm, path[-1], direction, 0.105, 0.024, 3,
                        side_hint=(-math.sin(gill_angle), math.cos(gill_angle), 0.0),
                        curl=-0.08, samples=3, low_poly=True,
                    )
        return

    if recipe.form == "giant":
        stem_points = [
            Vector((0.0, 0.0, 0.0)),
            Vector((-0.025, 0.01, 0.24)),
            Vector((0.025, -0.02, 0.50)),
            Vector((0.015, 0.01, 0.70)),
        ]
        _add_tube(
            bm, stem_points, (0.13, 0.16, 0.12, 0.085),
            1, segments=10, aspect=0.86, phase=0.3,
        )
        cap_centre = stem_points[-1]
        _mushroom_cap(
            bm, cap_centre, 0.39, 2, phase=0.5, segments=14,
        )
        for index in range(12):
            angle = math.tau * index / 12.0
            origin = cap_centre + Vector((
                0.055 * math.cos(angle), 0.055 * math.sin(angle), -0.025))
            direction = _direction(angle, -0.15)
            _add_leaf(
                bm, origin, direction, 0.29, 0.020, 4,
                side_hint=(-math.sin(angle), math.cos(angle), 0.0),
                curl=-0.08, wave=0.0, samples=3, low_poly=True,
            )
        for index in range(2):
            angle = 1.1 + index * 2.7
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            shelf_origin = stem_points[1 + index] + radial * 0.075
            _add_profiled_hull(
                bm, shelf_origin, (0.0, 0.0, 1.0),
                ((-0.025, 0.05, 0.032), (0.0, 0.13, 0.082),
                 (0.035, 0.115, 0.074), (0.07, 0.025, 0.020)),
                3, segments=8, lobes=4, lobe_amount=0.06, phase=angle,
                skew=radial * 0.14,
            )
        return

    raise ValueError("unknown mushroom form {!r}".format(recipe.form))


def _mathutils_noise(point: Vector, seed: int) -> float:
    """Stable coherent noise with a trigonometric fallback for API portability."""

    offset = Vector((seed * 0.0131, seed * 0.0217, seed * 0.0089))
    try:
        value = noise.noise_vector(point + offset, noise_basis="PERLIN_ORIGINAL")
        return float(value.x * 0.62 + value.y * 0.27 + value.z * 0.11)
    except (TypeError, AttributeError):
        q = point + offset
        return (
            math.sin(q.x * 2.37 + q.y * 1.13)
            + 0.55 * math.sin(q.y * 4.11 - q.z * 1.73)
            + 0.28 * math.cos(q.z * 7.07 + q.x * 2.41)
        ) / 1.83


def _build_weathered_rock(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    result = bmesh.ops.create_icosphere(
        bm, subdivisions=3, radius=0.5,
        matrix=Matrix.Translation((0.0, 0.0, 0.48)),
        calc_uvs=False,
    )
    vertices = list(result["verts"])
    vertex_set = set(vertices)
    for vertex in vertices:
        local = vertex.co - Vector((0.0, 0.0, 0.48))
        normal = local.normalized()
        coarse = _mathutils_noise(local * 3.2, recipe.seed)
        fine = _mathutils_noise(local * 8.1, recipe.seed + 19)
        strata = 0.035 * math.sin(local.z * 19.0 + coarse * 1.7)
        scale = 1.0 + 0.16 * coarse + 0.055 * fine + strata
        local = Vector((local.x * 1.14, local.y * 0.91, local.z * 0.84))
        vertex.co = Vector((0.0, 0.0, 0.48)) + local * scale
        # A slight prevailing-weather lean keeps the hull from reading as a ball.
        vertex.co.x += 0.08 * (vertex.co.z - 0.48)
    faces = {
        face for vertex in vertices for face in vertex.link_faces
        if all(corner in vertex_set for corner in face.verts)
    }
    layer = (bm.faces.layers.int.get(PALETTE_ATTRIBUTE)
             or bm.faces.layers.int.new(PALETTE_ATTRIBUTE))
    for face in faces:
        centre = face.calc_center_median()
        normal = face.normal
        level = 1
        if centre.z > 0.64:
            level = 2
        if normal.z > 0.55 and centre.z > 0.72:
            level = 3
        face[layer] = level
        face.smooth = False


def _build_round_rock(
    recipe: AssetRecipe,
    bm: bmesh.types.BMesh,
    style: str,
) -> None:
    """Build one grounded boulder with a silhouette specific to its geology."""

    result = bmesh.ops.create_icosphere(
        bm, subdivisions=3, radius=0.5,
        matrix=Matrix.Translation((0.0, 0.0, 0.5)),
        calc_uvs=False,
    )
    vertices = list(result["verts"])
    vertex_set = set(vertices)
    aspects = {
        "round": Vector((1.08, 1.0, 0.94)),
        "layered": Vector((1.36, 1.02, 0.76)),
        "colossus": Vector((1.22, 1.08, 1.04)),
        "rune_boulder": Vector((1.13, 0.97, 0.91)),
    }
    aspect = aspects[style]
    for vertex in vertices:
        local = vertex.co - Vector((0.0, 0.0, 0.5))
        coarse = _mathutils_noise(local * 2.7, recipe.seed)
        broad = _mathutils_noise(local * 5.4, recipe.seed + 31)
        height_share = _clamp01(local.z + 0.5)
        shaped = Vector((
            local.x * aspect.x,
            local.y * aspect.y,
            local.z * aspect.z,
        ))
        scale = 1.0 + coarse * 0.12 + broad * 0.045
        if style == "round":
            # Soft enough to read as a circular boulder, but not a perfect ball.
            scale += 0.025 * math.sin(
                math.atan2(local.y, local.x) * 5.0 + local.z * 8.0)
        elif style == "layered":
            # Broad ledges make the sediment bands legible in silhouette as well
            # as in the paint PNG.
            ledge = 0.5 + 0.5 * math.sin(
                height_share * math.tau * 5.0 + coarse * 0.8)
            scale += 0.09 * _smoothstep(0.43, 0.72, ledge)
            shaped.x += 0.09 * (height_share - 0.5)
        elif style == "colossus":
            shelf = 0.5 + 0.5 * math.sin(
                height_share * math.tau * 4.0 + broad)
            scale += 0.115 * _smoothstep(0.38, 0.68, shelf)
            shaped.x += 0.10 * math.sin(height_share * math.pi)
            shaped.y -= 0.06 * height_share
        else:
            # Rune boulders keep large quiet faces for the painted glyphs.
            scale += 0.035 * math.sin(
                math.atan2(local.y, local.x) * 3.0 + local.z * 5.0)
            shaped.x -= 0.055 * height_share
        vertex.co = Vector((0.0, 0.0, 0.5)) + shaped * scale

    # A mathematically round icosphere balances on one vertex. Flatten the
    # buried bottom into a broad contact patch so these read as immense weight
    # on the terrain rather than as spheres hovering over their own shadows.
    low = min(vertex.co.z for vertex in vertices)
    high = max(vertex.co.z for vertex in vertices)
    contact = low + (high - low) * (0.13 if style == "layered" else 0.10)
    for vertex in vertices:
        if vertex.co.z < contact:
            vertex.co.z = contact

    bm.normal_update()
    faces = {
        face for vertex in vertices for face in vertex.link_faces
        if all(corner in vertex_set for corner in face.verts)
    }
    layer = (bm.faces.layers.int.get(PALETTE_ATTRIBUTE)
             or bm.faces.layers.int.new(PALETTE_ATTRIBUTE))
    for face in faces:
        centre = face.calc_center_median()
        if style == "layered":
            palette_index = 1 + int((centre.z * 8.0) % 3)
        elif style == "colossus":
            palette_index = 2 if centre.z > 0.55 else 1
            if face.normal.z > 0.62:
                palette_index = 3
        elif style == "rune_boulder":
            palette_index = 0 if face.normal.z < -0.2 else (
                1 if centre.z < 0.58 else 2)
        else:
            palette_index = 1
            if centre.z > 0.62:
                palette_index = 2
            if face.normal.z > 0.62 and centre.z > 0.68:
                palette_index = 3
        face[layer] = min(palette_index, len(recipe.palette) - 1)
        face.smooth = False


def _build_hex_formation(
    recipe: AssetRecipe,
    bm: bmesh.types.BMesh,
    citadel: bool,
) -> None:
    """Build aligned hexagonal lava columns with a broken stepped skyline."""

    rng = random.Random(recipe.seed)
    count = 22 if citadel else 14
    for index in range(count):
        angle = index * GOLDEN_ANGLE
        radial_share = math.sqrt(index / max(count - 1, 1))
        ring = radial_share * (0.34 if citadel else 0.37)
        centre = Vector((
            math.cos(angle) * ring * (1.08 if citadel else 1.2),
            math.sin(angle) * ring,
            0.0,
        ))
        envelope = max(0.0, 1.0 - radial_share * (
            0.62 if citadel else 0.48))
        if index == 0:
            height = 1.0
        elif citadel:
            height = 0.27 + envelope * rng.uniform(0.34, 0.88)
            if index in {2, 5, 8}:
                height = max(height, rng.uniform(0.72, 0.92))
        else:
            height = 0.30 + envelope * rng.uniform(0.24, 0.63)
        radius = (
            rng.uniform(0.065, 0.092) if citadel
            else rng.uniform(0.074, 0.105))
        radius *= 0.88 + envelope * 0.18
        _add_profiled_hull(
            bm, centre, (0.0, 0.0, 1.0),
            (
                (0.0, radius * 0.97, radius),
                (height * 0.18, radius, radius * 0.98),
                (height * 0.58, radius * 0.98, radius * 0.96),
                (height * 0.91, radius * 0.94, radius * 0.93),
                (height, radius * 0.78, radius * 0.76),
            ),
            min(1 + index % 3, len(recipe.palette) - 1),
            segments=6, lobes=0, phase=0.0,
            skew=Vector((
                rng.uniform(-0.007, 0.007),
                rng.uniform(-0.007, 0.007),
                0.0,
            )),
        )


def _build_crystal_formation(
    recipe: AssetRecipe,
    bm: bmesh.types.BMesh,
    spire: bool,
) -> None:
    """Build a cluster of six-sided shards with one readable dominant crown."""

    rng = random.Random(recipe.seed)
    count = 8 if spire else (
        11 if recipe.form == "crystal_amethyst" else 9)
    for index in range(count):
        angle = index * GOLDEN_ANGLE + 0.22
        radial_share = 0.0 if index == 0 else math.sqrt(index / (count - 1))
        ring = radial_share * (0.29 if spire else 0.34)
        centre = Vector((
            math.cos(angle) * ring,
            math.sin(angle) * ring * 0.9,
            0.0,
        ))
        if index == 0:
            height = 1.0
        elif spire:
            height = rng.uniform(0.20, 0.52) * (1.0 - radial_share * 0.18)
        else:
            height = rng.uniform(0.34, 0.76) * (1.0 - radial_share * 0.12)
        radius = (
            rng.uniform(0.075, 0.11) if spire
            else rng.uniform(0.065, 0.098))
        radial = Vector((math.cos(angle), math.sin(angle), 0.0))
        lean = radial * (
            rng.uniform(0.04, 0.11) if index > 0
            else rng.uniform(-0.015, 0.015))
        _add_profiled_hull(
            bm, centre, (0.0, 0.0, 1.0),
            (
                (0.0, radius * 1.08, radius),
                (height * 0.16, radius, radius * 0.93),
                (height * 0.67, radius * 0.82, radius * 0.76),
                (height * 0.88, radius * 0.55, radius * 0.49),
                (height, 0.0, 0.0),
            ),
            min(1 + index % 3, len(recipe.palette) - 1),
            segments=6, lobes=0, phase=angle,
            skew=lean,
        )


def _build_rune_monolith(
    recipe: AssetRecipe,
    bm: bmesh.types.BMesh,
) -> None:
    """Build a split standing stone with broad planes for painted glyph paths."""

    _add_profiled_hull(
        bm, (0.0, 0.0, 0.0), (0.0, 0.0, 1.0),
        (
            (0.0, 0.25, 0.18),
            (0.12, 0.29, 0.20),
            (0.34, 0.27, 0.18),
            (0.61, 0.24, 0.17),
            (0.82, 0.20, 0.145),
            (0.96, 0.15, 0.11),
            (1.0, 0.04, 0.03),
        ),
        1, segments=8, lobes=2, lobe_amount=0.045, phase=0.3,
        skew=(0.055, -0.025, 0.0),
    )
    for index, (angle, height, radius) in enumerate((
        (2.7, 0.46, 0.11),
        (-0.35, 0.34, 0.09),
    )):
        radial = Vector((math.cos(angle), math.sin(angle), 0.0))
        centre = radial * (0.24 + radius)
        _add_profiled_hull(
            bm, centre, (0.0, 0.0, 1.0),
            (
                (0.0, radius, radius * 0.72),
                (height * 0.16, radius * 1.06, radius * 0.75),
                (height * 0.72, radius * 0.78, radius * 0.56),
                (height, 0.0, 0.0),
            ),
            2 + index, segments=6, lobes=2, lobe_amount=0.04,
            phase=angle, skew=radial * 0.08,
        )


def _build_rock(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form == "weathered":
        _build_weathered_rock(recipe, bm)
        return

    if recipe.form in {"round", "layered", "colossus", "rune_boulder"}:
        _build_round_rock(recipe, bm, recipe.form)
        return

    if recipe.form in {"hex_field", "hex_citadel"}:
        _build_hex_formation(recipe, bm, recipe.form == "hex_citadel")
        return

    if recipe.form in {
            "crystal_emerald", "crystal_amethyst", "crystal_spire"}:
        _build_crystal_formation(
            recipe, bm, recipe.form == "crystal_spire")
        return

    if recipe.form == "rune_monolith":
        _build_rune_monolith(recipe, bm)
        return

    if recipe.form == "basalt":
        for index in range(8):
            angle = index * GOLDEN_ANGLE
            ring = 0.07 + 0.18 * math.sqrt(index / 7.0)
            centre = Vector((
                math.cos(angle) * ring * 1.25,
                math.sin(angle) * ring,
                0.0,
            ))
            height = 0.48 + rng.uniform(-0.16, 0.24) + (0.13 if index < 2 else 0.0)
            radius = 0.115 + rng.uniform(-0.015, 0.022)
            lean = Vector((rng.uniform(-0.025, 0.025),
                           rng.uniform(-0.025, 0.025), 0.0))
            _add_profiled_hull(
                bm, centre, (0.0, 0.0, 1.0),
                ((0.0, radius * 0.94, radius),
                 (height * 0.28, radius, radius * 0.96),
                 (height * 0.61, radius * 0.94, radius * 0.91),
                 (height * 0.90, radius * 0.88, radius * 0.86),
                 (height, radius * 0.76, radius * 0.73)),
                1 + index % 3, segments=6, lobes=3,
                lobe_amount=0.035, phase=angle, skew=lean,
            )
        return

    if recipe.form == "glacier":
        for index in range(6):
            angle = index * GOLDEN_ANGLE + 0.2
            ring = 0.055 + 0.12 * math.sqrt(index / 5.0)
            centre = Vector((math.cos(angle) * ring,
                             math.sin(angle) * ring, 0.0))
            height = 0.45 + rng.uniform(-0.09, 0.32)
            radius = 0.09 + rng.uniform(-0.014, 0.024)
            lean = Vector((math.cos(angle), math.sin(angle), 0.0)) * rng.uniform(0.05, 0.13)
            _add_profiled_hull(
                bm, centre, (0.0, 0.0, 1.0),
                ((0.0, radius, radius * 0.78),
                 (height * 0.30, radius * 0.90, radius * 0.69),
                 (height * 0.62, radius * 0.66, radius * 0.50),
                 (height * 0.86, radius * 0.40, radius * 0.30),
                 (height, 0.0, 0.0)),
                1 + index % 3, segments=5, lobes=2,
                lobe_amount=0.04, phase=angle, skew=lean,
            )
        return

    raise ValueError("unknown rock form {!r}".format(recipe.form))


def _build_cactus(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form == "barrel":
        _add_profiled_hull(
            bm, (0.0, 0.0, 0.0), (0.0, 0.0, 1.0),
            ((0.0, 0.28, 0.28), (0.08, 0.33, 0.33),
             (0.24, 0.37, 0.37), (0.48, 0.39, 0.39),
             (0.70, 0.38, 0.38), (0.86, 0.33, 0.33),
             (0.96, 0.22, 0.22), (1.0, 0.08, 0.08)),
            1, segments=16, lobes=8, lobe_amount=0.11, phase=0.1,
        )
        _petal_whorl(
            bm, Vector((0.0, 0.0, 0.95)), 10,
            0.17, 0.045, 4, elevation=0.32,
            phase=0.15, droop=0.04, low_poly=True,
        )
        # Golden-angle areoles break up the broad hull and make the ribbed
        # profile legible from every instancing rotation.
        for index in range(14):
            t = 0.16 + index * 0.052
            angle = index * GOLDEN_ANGLE + 0.25
            radius = 0.36 - 0.035 * max(0.0, (t - 0.62) / 0.30)
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            origin = radial * radius + Vector((0.0, 0.0, t))
            _add_leaf(
                bm, origin, (radial + Vector((0.0, 0.0, 0.12))).normalized(),
                0.065, 0.007, 3,
                side_hint=(-math.sin(angle), math.cos(angle), 0.0),
                curl=0.02, wave=0.0, samples=3, low_poly=True,
            )
        return

    if recipe.form == "branching":
        trunk, _ = _curved_stem(
            bm, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
            0.86, 0.10, 1, sway=Vector((0.025, -0.01, 0.0)),
            samples=6, segments=8, tip_ratio=0.72, phase=0.3,
        )
        flower_sites = [trunk[-1]]
        for index in range(4):
            angle = 0.45 + index * math.tau / 4.0
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            z = 0.32 + 0.12 * index
            origin = Vector((0.0, 0.0, z))
            elbow = origin + radial * (0.16 + 0.025 * (index % 2))
            tip = elbow + radial * 0.11 + Vector((0.0, 0.0, 0.22 + 0.025 * index))
            _add_tube(
                bm, (origin, origin + radial * 0.10, elbow, tip),
                (0.073, 0.070, 0.065, 0.050),
                2, segments=8, phase=angle,
            )
            if index % 2 == 0:
                flower_sites.append(tip)
        for index, site in enumerate(flower_sites):
            _petal_whorl(
                bm, site, 6, 0.13, 0.036, 4,
                elevation=0.28, phase=index * 0.7,
                droop=0.02, low_poly=True,
            )
        return

    if recipe.form == "joshua":
        tips = _grow_branches(
            bm, rng, Vector((0.0, 0.0, 0.0)), Vector((0.0, 0.0, 1.0)),
            0.44, 0.068, 2, 0, phase=0.3, segments=7, spread=0.64,
        )
        for tip_index, (tip, tangent) in enumerate(tips):
            for leaf_index in range(8):
                angle = leaf_index * GOLDEN_ANGLE + tip_index * 0.55
                radial = Vector((math.cos(angle), math.sin(angle), 0.0))
                direction = (
                    tangent * 0.32 + radial * 0.85
                    + Vector((0.0, 0.0, 0.12 - 0.045 * leaf_index))
                ).normalized()
                side = Vector((-math.sin(angle), math.cos(angle), 0.0))
                _add_leaf(
                    bm, tip - tangent * 0.025, direction,
                    0.24 - 0.012 * (leaf_index % 3),
                    0.030, 2 + leaf_index % 3,
                    side_hint=side, curl=-0.035,
                    wave=0.008, samples=4, low_poly=True,
                )
        return

    raise ValueError("unknown cactus form {!r}".format(recipe.form))


def _small_glimmer(
    bm: bmesh.types.BMesh,
    centre: Vector,
    direction: Vector,
    scale: float,
    body_palette: int,
    wing_palette: int,
    phase: float,
) -> None:
    """A tiny authored insect: tapered body plus two closed wing laminae."""

    axis = direction.normalized()
    body_start = centre - axis * scale * 0.45
    body_end = centre + axis * scale * 0.45
    _add_tube(
        bm, (body_start, centre, body_end),
        (scale * 0.12, scale * 0.15, scale * 0.045),
        body_palette, segments=5, phase=phase,
    )
    side = _safe_side(axis, Vector((0.0, 0.0, 1.0)))
    normal = axis.cross(side).normalized()
    for sign in (-1.0, 1.0):
        wing_direction = (side * sign * 0.86 + axis * 0.28 + normal * 0.12).normalized()
        _add_leaf(
            bm, centre, wing_direction, scale * 0.72, scale * 0.22,
            wing_palette, side_hint=axis, curl=0.05 * sign,
            wave=0.0, samples=3, low_poly=True,
        )


def _build_glimmer(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    rng = random.Random(recipe.seed)
    if recipe.form == "firefly":
        for index in range(4):
            angle = index * GOLDEN_ANGLE
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            path, tangent = _curved_stem(
                bm, radial * 0.045,
                Vector((radial.x * 0.15, radial.y * 0.15, 1.0)),
                0.58 + index * 0.055, 0.014, 0,
                sway=radial * 0.17, samples=4, segments=5,
                tip_ratio=0.18, phase=angle,
            )
            pod_centre = path[-1]
            _add_profiled_hull(
                bm, pod_centre, tangent,
                ((-0.055, 0.025, 0.025), (-0.025, 0.07, 0.065),
                 (0.035, 0.085, 0.078), (0.095, 0.045, 0.042),
                 (0.125, 0.01, 0.01)),
                3, segments=8, lobes=4, lobe_amount=0.07, phase=angle,
            )
            _petal_whorl(
                bm, pod_centre + tangent * 0.085, 2,
                0.12, 0.030, 4, elevation=0.18,
                phase=angle, droop=-0.08, low_poly=True,
            )
        for index in range(3):
            angle = 0.8 + index * 2.1
            centre = Vector((
                0.25 * math.cos(angle),
                0.22 * math.sin(angle),
                0.44 + index * 0.13,
            ))
            _small_glimmer(
                bm, centre, _direction(angle + 1.0, 0.12),
                0.11, 3, 4, angle,
            )
        return

    if recipe.form == "moth":
        perch, tangent = _curved_stem(
            bm, Vector((0.0, 0.0, 0.0)), Vector((0.02, 0.0, 1.0)),
            0.62, 0.018, 0, sway=Vector((0.16, 0.03, 0.0)),
            samples=4, segments=5, tip_ratio=0.22, phase=0.4,
        )
        moth_centre = perch[-1] + tangent * 0.02
        body_axis = Vector((0.05, -0.10, 0.99)).normalized()
        _add_profiled_hull(
            bm, moth_centre - body_axis * 0.08, body_axis,
            ((0.0, 0.025, 0.022), (0.07, 0.045, 0.036),
             (0.18, 0.035, 0.030), (0.25, 0.008, 0.008)),
            1, segments=7, lobes=2, lobe_amount=0.03, phase=0.5,
        )
        wing_side = Vector((1.0, 0.0, -0.05)).normalized()
        for sign in (-1.0, 1.0):
            for layer in range(2):
                direction = Vector((
                    sign * (0.82 - layer * 0.10),
                    0.18 + layer * 0.12,
                    0.40 - layer * 0.20,
                )).normalized()
                _add_leaf(
                    bm, moth_centre + body_axis * (0.05 - layer * 0.02),
                    direction, 0.32 - layer * 0.055,
                    0.105 - layer * 0.018,
                    2 + layer, side_hint=wing_side,
                    curl=0.07 * sign, wave=0.015 * sign,
                    samples=4,
                )
        head = moth_centre + body_axis * 0.19
        antenna_side = Vector((0.7, 0.0, 0.3))
        for sign in (-1.0, 1.0):
            points = (
                head,
                head + body_axis * 0.07 + antenna_side * sign * 0.035,
                head + body_axis * 0.12 + antenna_side * sign * 0.085,
            )
            _add_tube(
                bm, points, (0.007, 0.0045, 0.002),
                4, segments=4, phase=sign,
            )
        # Dust motes are tiny faceted hulls, kept sparse so the moth remains the
        # silhouette rather than becoming a particle cloud.
        for index in range(4):
            angle = index * GOLDEN_ANGLE + 0.4
            centre = moth_centre + Vector((
                0.29 * math.cos(angle),
                0.20 * math.sin(angle),
                0.04 + 0.07 * index,
            ))
            size = 0.018 + rng.uniform(-0.003, 0.004)
            _add_profiled_hull(
                bm, centre, (0.0, 0.0, 1.0),
                ((-size, 0.0, 0.0), (0.0, size, size * 0.8),
                 (size, 0.0, 0.0)),
                4, segments=5, lobes=2, lobe_amount=0.08, phase=angle,
            )
        return

    raise ValueError("unknown glimmer form {!r}".format(recipe.form))


def _flyer_head(
    bm: bmesh.types.BMesh,
    centre: Vector,
    radius: float,
    palette_index: int,
    *,
    segments: int = 6,
    phase: float = 0.0,
) -> None:
    """A compact tapered head whose axis follows Blender +Y/runtime -Z."""

    _add_profiled_hull(
        bm, centre, (0.0, 1.0, 0.0),
        ((-radius * 0.65, radius * 0.66, radius * 0.72),
         (0.0, radius, radius * 0.92),
         (radius * 0.58, radius * 0.72, radius * 0.68),
         (radius * 0.92, 0.0, 0.0)),
        palette_index, segments=segments, lobes=2,
        lobe_amount=0.025, phase=phase,
    )


def _build_firefly_flyer(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    """Beetle-like flyer with a luminous rear abdomen and swept wing layers."""

    forward = Vector((0.0, 1.0, 0.0))
    _add_banded_tube(
        bm,
        ((0.0, -0.38, 0.0), (0.0, -0.25, 0.0),
         (0.0, -0.08, 0.005), (0.0, 0.09, 0.008),
         (0.0, 0.20, 0.004)),
        (0.055, 0.095, 0.115, 0.090, 0.048),
        (4, 3, 1, 1),
        segments=6, aspect=0.82, phase=0.25,
    )
    _add_profiled_hull(
        bm, (0.0, 0.13, 0.005), forward,
        ((-0.09, 0.085, 0.075), (0.0, 0.125, 0.105),
         (0.10, 0.105, 0.090), (0.16, 0.055, 0.048)),
        1, segments=6, lobes=3, lobe_amount=0.035, phase=0.5,
    )
    _flyer_head(bm, Vector((0.0, 0.29, 0.004)), 0.075, 0, phase=0.8)

    for sign in (-1.0, 1.0):
        # Dark folded elytra sit close to the abdomen.
        _add_leaf(
            bm, Vector((sign * 0.025, 0.10, 0.045)),
            Vector((sign * 0.14, -0.98, 0.10)).normalized(),
            0.30, 0.050, 2,
            side_hint=(1.0, 0.0, 0.0), curl=0.045 * sign,
            wave=0.0, samples=3, low_poly=True,
        )
        # Pale flight wings sweep wider and farther back.
        _add_leaf(
            bm, Vector((sign * 0.045, 0.12, 0.015)),
            Vector((sign * 0.52, -0.84, 0.16)).normalized(),
            0.36, 0.078, 4,
            side_hint=(0.0, 0.0, 1.0), curl=-0.035,
            wave=0.012 * sign, samples=3, low_poly=True,
        )


def _build_moth_flyer(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    """Layered scalloped moth with lofted fur and feathered antennae."""

    _add_tube(
        bm,
        ((0.0, -0.28, 0.0), (0.0, -0.12, 0.005),
         (0.0, 0.04, 0.012), (0.0, 0.15, 0.008)),
        (0.045, 0.072, 0.088, 0.052), 0,
        segments=6, aspect=0.78, phase=0.4,
    )
    # Two overlapping tapered lofts make a soft thorax silhouette without a
    # sphere; the offset ridge reads as fur at swarm scale.
    _add_tube(
        bm,
        ((0.0, 0.00, 0.00), (0.0, 0.105, 0.015),
         (0.0, 0.215, 0.006)),
        (0.090, 0.125, 0.078), 1,
        segments=7, aspect=0.88, phase=1.1,
    )
    _flyer_head(bm, Vector((0.0, 0.275, 0.006)), 0.070, 0, phase=0.2)

    # Three overlapping laminae per side form a scalloped outline.  Alternating
    # palette tags author subtle eyespot/band patterning directly in COLOR_0.
    for sign in (-1.0, 1.0):
        wing_specs = (
            (Vector((sign * 0.86, -0.34, 0.38)), 0.42, 0.145, 2),
            (Vector((sign * 0.96, -0.18, 0.18)), 0.36, 0.125, 3),
            (Vector((sign * 0.78, -0.61, -0.04)), 0.30, 0.105, 4),
        )
        for layer, (direction, length, width, palette) in enumerate(wing_specs):
            _add_leaf(
                bm, Vector((sign * 0.03, 0.10 - layer * 0.025,
                            0.015 - layer * 0.008)),
                direction.normalized(), length, width, palette,
                side_hint=(0.0, 0.0, 1.0),
                curl=(0.045 - layer * 0.018) * sign,
                wave=0.010 * sign, samples=3, low_poly=True,
            )

    head = Vector((0.0, 0.33, 0.008))
    for sign in (-1.0, 1.0):
        antenna_points = (
            head + Vector((sign * 0.025, 0.0, 0.010)),
            head + Vector((sign * 0.060, 0.105, 0.025)),
            head + Vector((sign * 0.105, 0.205, 0.018)),
        )
        _add_tube(
            bm, antenna_points, (0.010, 0.006, 0.0025),
            4, segments=4, phase=sign,
        )
        for plume_index in range(3):
            t = 0.25 + plume_index * 0.30
            base = antenna_points[0].lerp(antenna_points[-1], t)
            for plume_sign in (-1.0, 1.0):
                plume_direction = Vector((
                    sign * 0.32, 0.12, plume_sign * 0.94)).normalized()
                _add_tube(
                    bm, (base, base + plume_direction * (0.045 - 0.006 * plume_index)),
                    (0.0035, 0.0012), 4,
                    segments=3, phase=plume_sign + plume_index,
                )


def _build_dragon_flyer(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    """Slender damselfly body, four narrow wings, and compound eyes."""

    _add_banded_tube(
        bm,
        ((0.0, -0.48, 0.0), (0.0, -0.34, 0.0),
         (0.0, -0.20, 0.002), (0.0, -0.06, 0.004),
         (0.0, 0.08, 0.005), (0.0, 0.19, 0.003),
         (0.0, 0.27, 0.0)),
        (0.018, 0.027, 0.030, 0.034, 0.048, 0.040, 0.020),
        (1, 2, 1, 2, 1, 0),
        segments=5, aspect=0.80, phase=0.7,
    )
    _add_profiled_hull(
        bm, (0.0, 0.12, 0.004), (0.0, 1.0, 0.0),
        ((-0.07, 0.045, 0.040), (0.0, 0.075, 0.060),
         (0.09, 0.064, 0.052), (0.14, 0.030, 0.026)),
        2, segments=6, lobes=3, lobe_amount=0.03, phase=0.3,
    )
    _flyer_head(bm, Vector((0.0, 0.30, 0.0)), 0.055, 0, phase=0.6)
    for sign in (-1.0, 1.0):
        _add_profiled_hull(
            bm, (sign * 0.043, 0.315, 0.018), (0.0, 1.0, 0.0),
            ((-0.022, 0.0, 0.0), (0.0, 0.045, 0.040),
             (0.035, 0.0, 0.0)),
            3, segments=5, lobes=2, lobe_amount=0.025, phase=sign,
        )
        for wing_index in range(2):
            direction = Vector((
                sign * (0.88 - wing_index * 0.10),
                -0.42 - wing_index * 0.26,
                0.18 - wing_index * 0.13,
            )).normalized()
            _add_leaf(
                bm, Vector((sign * 0.025, 0.11 - wing_index * 0.035,
                            0.018 - wing_index * 0.010)),
                direction, 0.37 - wing_index * 0.035,
                0.035, 4,
                side_hint=(0.0, 0.0, 1.0),
                curl=0.018 * sign, wave=0.006 * sign,
                samples=3, low_poly=True,
            )
        antenna_base = Vector((sign * 0.022, 0.345, 0.008))
        _add_tube(
            bm,
            (antenna_base, antenna_base + Vector((sign * 0.035, 0.085, 0.018))),
            (0.0035, 0.0012), 0, segments=3, phase=sign,
        )


def _build_pollen_flyer(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    """Compact pollinator with a continuous banded abdomen and rounded wings."""

    _add_banded_tube(
        bm,
        ((0.0, -0.30, 0.0), (0.0, -0.20, 0.0),
         (0.0, -0.09, 0.004), (0.0, 0.03, 0.006),
         (0.0, 0.14, 0.004), (0.0, 0.22, 0.0)),
        (0.055, 0.105, 0.135, 0.142, 0.105, 0.045),
        (3, 0, 3, 0, 2),
        segments=6, aspect=0.90, phase=0.35,
    )
    _add_profiled_hull(
        bm, (0.0, 0.13, 0.008), (0.0, 1.0, 0.0),
        ((-0.10, 0.095, 0.088), (0.0, 0.145, 0.125),
         (0.10, 0.125, 0.108), (0.17, 0.060, 0.055)),
        1, segments=6, lobes=4, lobe_amount=0.045, phase=0.9,
    )
    _flyer_head(bm, Vector((0.0, 0.30, 0.006)), 0.066, 0, phase=0.4)
    for sign in (-1.0, 1.0):
        _add_leaf(
            bm, Vector((sign * 0.035, 0.12, 0.025)),
            Vector((sign * 0.70, -0.66, 0.27)).normalized(),
            0.24, 0.080, 4,
            side_hint=(0.0, 0.0, 1.0),
            curl=0.075 * sign, wave=0.0,
            samples=3, low_poly=True,
        )
        antenna_base = Vector((sign * 0.020, 0.34, 0.012))
        _add_tube(
            bm,
            (antenna_base, antenna_base + Vector((sign * 0.045, 0.075, 0.020))),
            (0.005, 0.0015), 0, segments=3, phase=sign,
        )
    for leg_index in range(3):
        y = -0.05 + leg_index * 0.09
        for sign in (-1.0, 1.0):
            start = Vector((sign * 0.065, y, -0.045))
            end = start + Vector((sign * (0.085 - leg_index * 0.008),
                                  -0.025, -0.055 + leg_index * 0.010))
            _add_tube(
                bm, (start, end), (0.005, 0.0015),
                1, segments=3, phase=leg_index + sign,
            )


def _build_flyer(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> None:
    builders = {
        "firefly": _build_firefly_flyer,
        "moth": _build_moth_flyer,
        "dragon": _build_dragon_flyer,
        "pollen": _build_pollen_flyer,
    }
    try:
        builder = builders[recipe.form]
    except KeyError as error:
        raise ValueError("unknown flyer form {!r}".format(recipe.form)) from error
    builder(recipe, bm)


BUILDERS: dict[str, Callable[[AssetRecipe, bmesh.types.BMesh], None]] = {
    "aquatic": _build_aquatic,
    "grass": _build_grass,
    "shrub": _build_shrub,
    "tree": _build_tree,
    "mushroom": _build_mushroom,
    "rock": _build_rock,
    "cactus": _build_cactus,
    "glimmer": _build_glimmer,
    "flyer": _build_flyer,
}


# ---------------------------------------------------------------------------
# Mesh finishing, material, export, validation, and previews
# ---------------------------------------------------------------------------

def _bounds(vertices: Iterable[bmesh.types.BMVert | bpy.types.MeshVertex]
            ) -> tuple[Vector, Vector]:
    low = Vector((math.inf, math.inf, math.inf))
    high = Vector((-math.inf, -math.inf, -math.inf))
    found = False
    for vertex in vertices:
        found = True
        coordinate = vertex.co
        for axis in range(3):
            low[axis] = min(low[axis], coordinate[axis])
            high[axis] = max(high[axis], coordinate[axis])
    if not found:
        raise ValueError("procedural asset produced no vertices")
    return low, high


def _fit_to_height_and_ground(
    bm: bmesh.types.BMesh,
    height: float,
    *,
    contact_share: float = 0.012,
) -> None:
    """Uniformly scale, centre the footprint, and make a planar Z=0 contact."""

    low, high = _bounds(bm.verts)
    source_height = high.z - low.z
    if source_height <= 1.0e-6:
        raise ValueError("procedural asset has zero height")
    scale = height / source_height
    centre_x = (low.x + high.x) * 0.5
    centre_y = (low.y + high.y) * 0.5
    for vertex in bm.verts:
        vertex.co.x = (vertex.co.x - centre_x) * scale
        vertex.co.y = (vertex.co.y - centre_y) * scale
        vertex.co.z = (vertex.co.z - low.z) * scale

    # A narrow flattened band gives rocks, holdfasts, and stems a reliable
    # contact patch while leaving the visible silhouette untouched.
    contact_band = max(1.0e-5, height * contact_share)
    for vertex in bm.verts:
        if vertex.co.z < contact_band:
            vertex.co.z = 0.0


def _fit_to_longest_and_center(bm: bmesh.types.BMesh, longest: float) -> None:
    """Fit an airborne mesh to its longest dimension and centre all three axes.

    Blender +Z becomes runtime +Y and Blender +Y becomes runtime -Z, so flyer
    builders author their dorsal side toward +Z and their nose toward +Y.
    """

    low, high = _bounds(bm.verts)
    spans = high - low
    source_longest = max(spans)
    if source_longest <= 1.0e-6:
        raise ValueError("procedural flyer has zero extent")
    scale = longest / source_longest
    centre = (low + high) * 0.5
    for vertex in bm.verts:
        vertex.co = (vertex.co - centre) * scale


def _colour_value(
    base: RGBA,
    coordinate: Vector,
    height: float,
    seed: int,
    palette_index: int,
) -> RGBA:
    """Apply a restrained height/noise modulation to authored palette colours."""

    normalized_height = max(0.0, min(1.0, coordinate.z / max(height, 1.0e-6)))
    grain = math.sin(
        coordinate.x * 19.31 + coordinate.y * 13.77
        + coordinate.z * 7.11 + seed * 0.017 + palette_index * 1.37)
    value = 0.88 + 0.12 * normalized_height + 0.035 * grain
    return (
        max(0.0, min(1.0, base[0] * value)),
        max(0.0, min(1.0, base[1] * value)),
        max(0.0, min(1.0, base[2] * value)),
        base[3],
    )


def _clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def _smoothstep(low: float, high: float, value: float) -> float:
    if high <= low:
        return 1.0 if value >= high else 0.0
    position = _clamp01((value - low) / (high - low))
    return position * position * (3.0 - 2.0 * position)


def _mix_colour(first: RGBA, second: RGBA, share: float) -> RGBA:
    amount = _clamp01(share)
    return tuple(
        first[index] * (1.0 - amount) + second[index] * amount
        for index in range(4)
    )


def _paint_style(recipe: AssetRecipe) -> str:
    """Human-readable contract recorded beside each generated PNG."""

    if recipe.archetype == "rock":
        if recipe.form.startswith("crystal"):
            return (
                "broad crystal facets, branching luminous veins, pale tips, "
                "and a mip-safe emission mask in PNG alpha")
        if recipe.form in {"rune_monolith", "rune_boulder"}:
            return (
                "wide strata under looping glyphs, broken chevrons, and a "
                "mip-safe tattoo emission mask in PNG alpha")
        if recipe.form in {"hex_field", "hex_citadel", "basalt"}:
            return (
                "vertical cooling striations, broad charcoal seams, ash bands, "
                "and pale fractured hex caps")
        if recipe.form == "layered":
            return "wide sediment ribbons, softened cracks, and lichen islands"
        if recipe.form == "colossus":
            return "monumental shelf strata, broad cracks, and large lichen continents"
    styles = {
        "aquatic": "broad current stripes, reticulated veins, and bulb freckles",
        "grass": "long blade veins, alternating seed bands, and pale margins",
        "shrub": "twig rings, leaf veins, margins, and flower freckles",
        "tree": "chunky wavy bark bands and knots with veined leaf markings",
        "mushroom": "stem striations, cap spots, margins, and radial gill bands",
        "rock": "broad strata, softened cracks, lichen islands, and ice facets",
        "cactus": "rib shadows, staggered areoles, fibrous bark, and petal marks",
        "glimmer": "stem bands, pod freckles, wing eyespots, and dust marks",
        "flyer": "body bands, scalloped wing marks, eyespots, and vein accents",
    }
    return styles[recipe.archetype]


def _paint_pixel(
    recipe: AssetRecipe,
    palette_index: int,
    u: float,
    v: float,
) -> RGBA:
    """Paint one texel with broad, deterministic, species-appropriate marks.

    This is color paint, not procedural surface noise.  Frequencies are kept
    deliberately low so the PNG retains recognizable marks through its mip
    chain rather than turning into the shimmer that fine terrain detail once
    produced.
    """

    palette = recipe.palette
    base = palette[palette_index]
    dark = (
        base[0] * 0.52,
        base[1] * 0.52,
        base[2] * 0.52,
        base[3],
    )
    pale = _mix_colour(
        base,
        palette[min(palette_index + 1, len(palette) - 1)],
        0.42,
    )
    pale = _mix_colour(pale, (1.0, 0.96, 0.78, 1.0), 0.16)
    phase = recipe.seed * 0.00073 + palette_index * 0.317
    tau = math.tau

    # Shared broad masks.  The ingredients are continuous at the texture edge,
    # which keeps repeated U coordinates and generated mip levels quiet.
    horizontal = 0.5 + 0.5 * math.sin(
        tau * (v * (4.0 + recipe.seed % 3)
               + 0.12 * math.sin(tau * u * 2.0) + phase))
    vertical = 0.5 + 0.5 * math.sin(
        tau * (u * (3.0 + palette_index % 3)
               + 0.10 * math.sin(tau * v * 2.0) + phase * 1.7))
    islands = (
        (0.5 + 0.5 * math.sin(tau * (u * 3.0 + v * 1.7 + phase)))
        * (0.5 + 0.5 * math.sin(tau * (v * 4.0 - u * 1.3 + phase * 2.1)))
    )
    dots = _smoothstep(0.61, 0.83, islands)
    result = base
    emission_mask = 1.0

    if recipe.archetype == "tree":
        if palette_index <= 1:
            # Broad wavy amber/dark bands are the trunk's readable motif, with
            # occasional knots.  This is the same simple graphic language as
            # the reference stump rather than photographic bark noise.
            bark_wave = 0.5 + 0.5 * math.sin(
                tau * (v * 4.0 + 0.19 * math.sin(tau * u * 2.0) + phase))
            rings = _smoothstep(0.32, 0.63, bark_wave)
            knots = dots * _smoothstep(0.58, 0.84, vertical)
            bark_light = _mix_colour(
                pale, (0.88, 0.68, 0.34, 1.0), 0.42)
            bark_dark = (
                base[0] * 0.27, base[1] * 0.24,
                base[2] * 0.21, base[3])
            result = _mix_colour(result, bark_dark, rings * 0.68)
            result = _mix_colour(
                result, bark_light, (1.0 - rings) * (0.38 + vertical * 0.30))
            result = _mix_colour(result, bark_dark, knots * 0.58)
        else:
            vein = 1.0 - _smoothstep(
                0.035, 0.13,
                abs((u - 0.5) - 0.09 * math.sin(tau * v * 2.0 + phase)),
            )
            chevron = _smoothstep(0.72, 0.94, vertical * horizontal)
            result = _mix_colour(result, pale, vein * 0.42)
            result = _mix_colour(result, dark, chevron * 0.20)
    elif recipe.archetype == "mushroom":
        if palette_index <= 1:
            result = _mix_colour(result, pale, vertical * 0.18)
            result = _mix_colour(result, dark, horizontal * 0.18)
        else:
            spots = dots * _smoothstep(0.42, 0.74, vertical)
            gills = _smoothstep(0.67, 0.92, vertical)
            result = _mix_colour(result, pale, spots * 0.58)
            result = _mix_colour(
                result, dark, gills * (0.34 if palette_index >= 4 else 0.16))
    elif recipe.archetype == "cactus":
        if recipe.form == "joshua" and palette_index <= 1:
            result = _mix_colour(result, dark, horizontal * 0.32)
            result = _mix_colour(result, pale, vertical * 0.17)
        elif palette_index <= 2:
            ribs = _smoothstep(0.56, 0.86, vertical)
            areoles = dots * _smoothstep(0.55, 0.82, horizontal)
            result = _mix_colour(result, dark, ribs * 0.31)
            result = _mix_colour(result, pale, areoles * 0.66)
        else:
            result = _mix_colour(result, pale, dots * 0.42)
            result = _mix_colour(result, dark, horizontal * 0.13)
    elif recipe.archetype == "grass":
        vein = _smoothstep(0.66, 0.91, vertical)
        seed_band = _smoothstep(0.58, 0.85, horizontal)
        result = _mix_colour(result, pale, vein * 0.31)
        result = _mix_colour(result, dark, seed_band * 0.20)
    elif recipe.archetype == "shrub":
        if palette_index == 0:
            result = _mix_colour(result, dark, horizontal * 0.31)
            result = _mix_colour(result, pale, vertical * 0.13)
        else:
            vein = _smoothstep(0.70, 0.93, vertical)
            margin = _smoothstep(0.64, 0.90, horizontal)
            result = _mix_colour(result, pale, vein * 0.34)
            result = _mix_colour(result, dark, margin * 0.16)
            result = _mix_colour(result, pale, dots * 0.22)
    elif recipe.archetype == "aquatic":
        current = _smoothstep(0.52, 0.84, horizontal)
        vein = _smoothstep(0.67, 0.91, vertical)
        result = _mix_colour(result, dark, current * 0.22)
        result = _mix_colour(result, pale, vein * 0.32)
        if palette_index >= 2:
            result = _mix_colour(result, pale, dots * 0.37)
    elif recipe.archetype == "rock":
        if recipe.form.startswith("crystal"):
            # Wide branching seams survive the mip chain on a skyscraper-size
            # instance. Alpha is semantic emission, not transparency.
            branch_phase = (
                u * 2.15 + v * 3.35
                + 0.18 * math.sin(tau * (v * 1.5 + phase)))
            branch_distance = abs((branch_phase - math.floor(branch_phase)) - 0.5)
            branch = 1.0 - _smoothstep(0.035, 0.125, branch_distance)
            facet = _smoothstep(
                0.64, 0.88,
                0.5 + 0.5 * math.sin(
                    tau * (u * 1.35 - v * 1.8 + phase)))
            crown = _smoothstep(0.62, 0.94, v)
            emission_mask = _clamp01(
                branch * 0.82 + facet * 0.20 + crown * 0.24)
            result = _mix_colour(result, dark, horizontal * 0.16)
            result = _mix_colour(
                result, palette[-1],
                emission_mask * (0.62 + 0.16 * vertical))
        elif recipe.form in {"rune_monolith", "rune_boulder"}:
            # One looping path and two broken chevrons read as tattoos rather
            # than a regular grid. Their widths are intentionally generous.
            loop_distance = abs(
                math.hypot((u - 0.5) * 1.08, (v - 0.5) * 0.82)
                - (0.26 + 0.035 * math.sin(tau * phase)))
            loop = 1.0 - _smoothstep(0.028, 0.085, loop_distance)
            chevron_coordinate = abs(u - 0.5) * 1.55 \
                + ((v * 2.0 + phase) % 1.0)
            chevron_distance = abs(
                (chevron_coordinate - math.floor(chevron_coordinate)) - 0.5)
            chevron = 1.0 - _smoothstep(0.035, 0.105, chevron_distance)
            spine = 1.0 - _smoothstep(
                0.025, 0.075,
                abs((u - 0.5) - 0.12 * math.sin(tau * (v * 2.0 + phase))))
            gaps = _smoothstep(
                0.20, 0.42,
                0.5 + 0.5 * math.sin(tau * (v * 4.0 - u + phase)))
            emission_mask = _clamp01(max(loop, chevron * gaps, spine * 0.8))
            strata = _smoothstep(0.40, 0.72, horizontal)
            result = _mix_colour(result, dark, strata * 0.26)
            result = _mix_colour(result, palette[-1], emission_mask * 0.82)
        elif recipe.form in {"hex_field", "hex_citadel", "basalt"}:
            cooling = _smoothstep(0.52, 0.82, vertical)
            ash = _smoothstep(0.48, 0.76, horizontal)
            cap_scars = dots * _smoothstep(0.54, 0.8, vertical)
            result = _mix_colour(result, dark, cooling * 0.34 + ash * 0.18)
            result = _mix_colour(result, pale, cap_scars * 0.36)
        else:
            strata = _smoothstep(0.43, 0.72, horizontal)
            crack = _smoothstep(
                0.78, 0.96,
                0.5 + 0.5 * math.sin(
                    tau * (u * 1.5 + v * 5.0
                           + 0.20 * math.sin(tau * u * 3.0) + phase)))
            result = _mix_colour(result, dark, strata * 0.27 + crack * 0.18)
            lichen_share = 0.38 if recipe.form == "colossus" else 0.29
            result = _mix_colour(result, pale, dots * lichen_share)
    elif recipe.archetype in {"glimmer", "flyer"}:
        if palette_index <= 1:
            band = _smoothstep(0.48, 0.73, horizontal)
            result = _mix_colour(result, dark, band * 0.35)
            result = _mix_colour(result, pale, (1.0 - band) * vertical * 0.18)
        else:
            eyespot = dots * _smoothstep(0.50, 0.78, horizontal)
            vein = _smoothstep(0.71, 0.93, vertical)
            result = _mix_colour(result, pale, eyespot * 0.55)
            result = _mix_colour(result, dark, vein * 0.19)

    # A broad value drift keeps a repeated paint tile from looking stamped while
    # remaining well below the contrast of the authored motifs above.
    drift = 0.94 + 0.06 * math.sin(
        tau * (u * 1.0 + v * 0.63 + phase * 0.41))
    return (
        _clamp01(result[0] * drift),
        _clamp01(result[1] * drift),
        _clamp01(result[2] * drift),
        emission_mask,
    )


def _write_paint_texture(recipe: AssetRecipe, path: str) -> bpy.types.Image:
    """Generate and save the external PNG sampled by the runtime material."""

    os.makedirs(os.path.dirname(path), exist_ok=True)
    image = bpy.data.images.new(
        recipe.name + "_color_paint",
        width=PAINT_SIZE,
        height=PAINT_SIZE,
        alpha=True,
        float_buffer=False,
    )
    try:
        image.colorspace_settings.name = "sRGB"
    except TypeError:
        pass
    palette_count = len(recipe.palette)
    band_pixels = PAINT_SIZE / palette_count
    gutter_share = PAINT_GUTTER / band_pixels
    pixels: list[float] = []
    for y in range(PAINT_SIZE):
        atlas_v = (y + 0.5) / PAINT_SIZE * palette_count
        palette_index = min(int(atlas_v), palette_count - 1)
        local_v = atlas_v - palette_index
        # The gutter repeats the nearest interior texel rather than introducing
        # transparent or foreign colours into the mip chain.
        local_v = _clamp01(
            (local_v - gutter_share)
            / max(1.0 - gutter_share * 2.0, 1.0e-5))
        for x in range(PAINT_SIZE):
            u = (x + 0.5) / PAINT_SIZE
            pixels.extend(_paint_pixel(recipe, palette_index, u, local_v))
    image.pixels.foreach_set(pixels)
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise ValueError("color paint did not produce {}".format(path))
    return image


def _paint_projection_scale(recipe: AssetRecipe, palette_index: int) -> float:
    """World-space size of one broad paint motif before atlas packing."""

    if recipe.archetype == "grass":
        return max(0.07, recipe.height * 0.16)
    if recipe.archetype == "tree":
        return (
            max(0.28, recipe.height * 0.16)
            if palette_index <= 1
            else max(0.14, recipe.height * 0.045)
        )
    if recipe.archetype == "mushroom":
        return max(0.09, recipe.height * (0.14 if palette_index <= 1 else 0.09))
    if recipe.archetype == "rock":
        return max(0.20, recipe.height * 0.18)
    if recipe.archetype in {"glimmer", "flyer"}:
        return max(0.025, recipe.height * 0.20)
    return max(0.08, recipe.height * 0.10)


def _face_phase(values: Sequence[float]) -> list[float]:
    """Move a projected polygon into one repeat without wrapping through it."""

    centre = sum(values) / len(values)
    phase = 0.18 + (centre - math.floor(centre)) * 0.64
    result = []
    for value in values:
        # A face is much smaller than a motif by construction.  Clamping is a
        # safety net for the broad faces on rocks, not the normal path.
        result.append(max(0.035, min(0.965, phase + (value - centre) * 0.74)))
    return result


def _polygon_paint_uvs(
    recipe: AssetRecipe,
    polygon: bpy.types.MeshPolygon,
    coordinates: Sequence[Vector],
    palette_index: int,
) -> list[tuple[float, float]]:
    """Project one polygon into its semantic palette band in the paint atlas."""

    woody = (
        palette_index <= 1
        and recipe.archetype in {
            "tree", "cactus", "mushroom", "aquatic", "grass", "shrub", "glimmer",
        }
    )
    if woody:
        raw_u = [
            math.atan2(coordinate.y, coordinate.x) / math.tau
            for coordinate in coordinates
        ]
        anchor = raw_u[0]
        raw_u = [
            anchor + ((value - anchor + 0.5) % 1.0) - 0.5
            for value in raw_u
        ]
        local_u = raw_u
        local_v = [
            _clamp01(coordinate.z / max(recipe.height, 1.0e-6))
            for coordinate in coordinates
        ]
    else:
        scale = _paint_projection_scale(recipe, palette_index)
        normal = polygon.normal
        dominant = max(range(3), key=lambda axis: abs(normal[axis]))
        if dominant == 0:
            first_axis, second_axis = 1, 2
        elif dominant == 1:
            first_axis, second_axis = 0, 2
        else:
            first_axis, second_axis = 0, 1
        local_u = _face_phase([
            coordinate[first_axis] / scale for coordinate in coordinates
        ])
        local_v = _face_phase([
            coordinate[second_axis] / scale for coordinate in coordinates
        ])

    palette_count = len(recipe.palette)
    band_pixels = PAINT_SIZE / palette_count
    gutter = PAINT_GUTTER / band_pixels
    usable = 1.0 - gutter * 2.0
    return [
        (
            u,
            (palette_index + gutter + _clamp01(v) * usable) / palette_count,
        )
        for u, v in zip(local_u, local_v)
    ]


def _make_material(recipe: AssetRecipe) -> bpy.types.Material:
    material = bpy.data.materials.new(recipe.name + "_material")
    material.use_nodes = True
    material.diffuse_color = recipe.palette[min(1, len(recipe.palette) - 1)]
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    if principled is None:
        raise RuntimeError("Blender's default material has no Principled BSDF")
    principled.inputs["Roughness"].default_value = recipe.roughness

    colour = nodes.new("ShaderNodeVertexColor")
    colour.name = "BiomeVertexColor"
    colour.layer_name = COLOR_ATTRIBUTE
    links.new(colour.outputs["Color"], principled.inputs["Base Color"])
    if recipe.emission_strength > 0.0:
        for socket_name in ("Emission Color", "Emission"):
            if socket_name in principled.inputs:
                links.new(colour.outputs["Color"], principled.inputs[socket_name])
                break
        if "Emission Strength" in principled.inputs:
            principled.inputs["Emission Strength"].default_value = recipe.emission_strength
    return material


def _preview_with_paint(
    material: bpy.types.Material,
    image: bpy.types.Image,
) -> None:
    """Switch the post-export preview to the same PNG the game will sample."""

    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    if principled is None:
        raise RuntimeError("paint preview material has no Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = "BiomeColorPaint"
    texture.image = image
    texture.interpolation = "Linear"
    texture.extension = "REPEAT"
    for link in list(principled.inputs["Base Color"].links):
        links.remove(link)
    links.new(texture.outputs["Color"], principled.inputs["Base Color"])
    if image.name.startswith("mushroom_"):
        texture.projection_blend = 0.0
    for socket_name in ("Emission Color", "Emission"):
        if socket_name in principled.inputs and principled.inputs[socket_name].is_linked:
            for link in list(principled.inputs[socket_name].links):
                links.remove(link)
            links.new(texture.outputs["Color"], principled.inputs[socket_name])
            break


def _finish_object(recipe: AssetRecipe, bm: bmesh.types.BMesh) -> bpy.types.Object:
    if not bm.faces:
        raise ValueError("{} produced no faces".format(recipe.name))
    if recipe.category == "flyer":
        _fit_to_longest_and_center(bm, recipe.height)
    else:
        _fit_to_height_and_ground(
            bm,
            recipe.height,
            # The weathered hull begins as a closed icosphere; a broader planar
            # cut turns its rounded underside into a stable geological footprint.
            contact_share=0.16 if recipe.form == "weathered" else 0.012,
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()

    mesh = bpy.data.meshes.new(recipe.name + "Mesh")
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate(clean_customdata=False)
    mesh.update(calc_edges=True)

    palette_attribute = mesh.attributes.get(PALETTE_ATTRIBUTE)
    colour_attribute = mesh.color_attributes.new(
        name=COLOR_ATTRIBUTE, type="BYTE_COLOR", domain="CORNER")
    paint_uv = mesh.uv_layers.new(name=PAINT_UV_NAME)
    for polygon in mesh.polygons:
        palette_index = (
            int(palette_attribute.data[polygon.index].value)
            if palette_attribute is not None else 0
        ) % len(recipe.palette)
        polygon.material_index = 0
        polygon.use_smooth = recipe.smooth
        coordinates = [
            mesh.vertices[mesh.loops[loop_index].vertex_index].co
            for loop_index in polygon.loop_indices
        ]
        polygon_uvs = _polygon_paint_uvs(
            recipe, polygon, coordinates, palette_index)
        for loop_index, uv in zip(polygon.loop_indices, polygon_uvs):
            coordinate = mesh.vertices[mesh.loops[loop_index].vertex_index].co
            colour_attribute.data[loop_index].color = _colour_value(
                recipe.palette[palette_index], coordinate,
                recipe.height, recipe.seed, palette_index,
            )
            paint_uv.data[loop_index].uv = uv
    if palette_attribute is not None:
        mesh.attributes.remove(palette_attribute)
    mesh.color_attributes.active_color_name = COLOR_ATTRIBUTE
    mesh.color_attributes.render_color_index = 0
    mesh.uv_layers.active = paint_uv
    mesh.uv_layers.active_index = list(mesh.uv_layers).index(paint_uv)
    mesh.materials.append(_make_material(recipe))
    mesh.update()

    obj = bpy.data.objects.new(recipe.name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = (0.0, 0.0, 0.0)
    obj.rotation_euler = (0.0, 0.0, 0.0)
    obj.scale = (1.0, 1.0, 1.0)
    return obj


def _select_only(obj: bpy.types.Object) -> None:
    for candidate in bpy.context.view_layer.objects:
        # Blender 5.1 can expose a transient null entry in the background view
        # layer immediately after the factory scene has been cleared.
        if candidate is not None:
            candidate.select_set(False)
    obj.hide_viewport = False
    obj.hide_render = False
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def _export_glb(obj: bpy.types.Object, path: str) -> None:
    _select_only(obj)
    settings = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_normals=True,
        export_tangents=False,
        export_texcoords=True,
        export_skins=False,
        export_animations=False,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
    )
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **settings)
    except TypeError:
        # Older compatible exporters lack this spelling.  Validation below is
        # authoritative and fails if COLOR_0 is absent.
        bpy.ops.export_scene.gltf(**settings)


def _validate_glb(
    path: str,
    recipe: AssetRecipe,
    expected_triangles: int,
) -> dict[str, int]:
    document, _binary = build_vat._read_glb(path)
    if document.get("skins"):
        raise ValueError("{} unexpectedly contains a skin".format(recipe.name))
    if document.get("animations"):
        raise ValueError("{} unexpectedly contains animation".format(recipe.name))
    if any("skin" in node for node in document.get("nodes", [])):
        raise ValueError("{} contains a skinned node".format(recipe.name))

    mesh_nodes = [node for node in document.get("nodes", []) if "mesh" in node]
    if len(mesh_nodes) != 1:
        raise ValueError("{} must have exactly one mesh node, got {}".format(
            recipe.name, len(mesh_nodes)))
    if mesh_nodes[0].get("name") != recipe.name:
        raise ValueError("mesh node {!r} does not match manifest name {!r}".format(
            mesh_nodes[0].get("name"), recipe.name))
    if len(document.get("meshes", [])) != 1:
        raise ValueError("{} must contain exactly one glTF mesh".format(recipe.name))

    primitive_count = 0
    glb_triangles = 0
    glb_vertices = 0
    for mesh in document["meshes"]:
        for primitive in mesh.get("primitives", []):
            primitive_count += 1
            if primitive.get("mode", 4) != 4:
                raise ValueError("{} contains a non-triangle primitive".format(recipe.name))
            attributes = primitive.get("attributes", {})
            missing = {"POSITION", "NORMAL", "COLOR_0", "TEXCOORD_0"} - set(attributes)
            if missing:
                raise ValueError("{} GLB is missing {}".format(
                    recipe.name, sorted(missing)))
            position = document["accessors"][attributes["POSITION"]]
            glb_vertices += int(position["count"])
            minimum_bounds = position.get("min")
            maximum_bounds = position.get("max")
            if minimum_bounds is None or maximum_bounds is None:
                raise ValueError("{} POSITION accessor has no bounds".format(
                    recipe.name))
            bounds_min = [float(value) for value in minimum_bounds]
            bounds_max = [float(value) for value in maximum_bounds]
            spans = [
                bounds_max[axis] - bounds_min[axis]
                for axis in range(3)
            ]
            if recipe.category == "flyer":
                longest = max(spans)
                if not 0.10 <= longest <= 0.30:
                    raise ValueError(
                        "{} longest dimension {} is outside flyer range".format(
                            recipe.name, longest))
                if abs(longest - recipe.height) > 2.0e-5:
                    raise ValueError(
                        "{} longest dimension {} differs from authored {}".format(
                            recipe.name, longest, recipe.height))
                centres = [
                    (bounds_min[axis] + bounds_max[axis]) * 0.5
                    for axis in range(3)
                ]
                tolerance = max(2.0e-5, recipe.height * 0.002)
                if max(abs(value) for value in centres) > tolerance:
                    raise ValueError(
                        "{} flyer bounds are off-centre: {}".format(
                            recipe.name, centres))
                if not bounds_min[1] < 0.0 < bounds_max[1]:
                    raise ValueError(
                        "{} flyer must straddle runtime Y=0".format(recipe.name))
            else:
                if abs(bounds_min[1]) > 1.0e-5:
                    raise ValueError("{} runtime base is Y={}, expected zero".format(
                        recipe.name, bounds_min[1]))
                runtime_height = spans[1]
                if abs(runtime_height - recipe.height) > 2.0e-5:
                    raise ValueError(
                        "{} runtime height {} differs from authored {}".format(
                            recipe.name, runtime_height, recipe.height))
            if "indices" in primitive:
                glb_triangles += int(
                    document["accessors"][primitive["indices"]]["count"]) // 3
            else:
                glb_triangles += int(position["count"]) // 3
    if primitive_count != 1:
        raise ValueError("{} exported as {} primitives; expected one".format(
            recipe.name, primitive_count))
    if glb_triangles != expected_triangles:
        raise ValueError("{} source has {} triangles but GLB has {}".format(
            recipe.name, expected_triangles, glb_triangles))
    minimum, maximum = recipe.triangle_budget
    if not minimum <= glb_triangles <= maximum:
        raise ValueError("{} has {} triangles, budget is {}..{}".format(
            recipe.name, glb_triangles, minimum, maximum))
    return {
        "triangle_count": glb_triangles,
        "glb_vertex_count": glb_vertices,
        "primitive_count": primitive_count,
    }


def _look_at(obj: bpy.types.Object, location: Vector, target: Vector) -> None:
    obj.location = location
    obj.rotation_euler = (target - location).to_track_quat("-Z", "Y").to_euler()


def _preview_material(name: str, colour: RGBA, roughness: float
                      ) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    principled = material.node_tree.nodes["Principled BSDF"]
    principled.inputs["Base Color"].default_value = colour
    principled.inputs["Roughness"].default_value = roughness
    return material


def _add_preview_light(
    name: str,
    location: Vector,
    target: Vector,
    energy: float,
    size: float,
) -> None:
    data = bpy.data.lights.new(name, type="AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    light = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(light)
    _look_at(light, location, target)


def _render_preview(
    obj: bpy.types.Object,
    recipe: AssetRecipe,
    path: str,
) -> None:
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if hasattr(scene, "eevee"):
        scene.eevee.taa_render_samples = PREVIEW_SAMPLES
    scene.render.resolution_x = PREVIEW_SIZE
    scene.render.resolution_y = PREVIEW_SIZE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.filepath = path
    for look in ("AgX - Medium High Contrast", "Medium High Contrast", "None"):
        try:
            scene.view_settings.look = look
            break
        except TypeError:
            continue

    world = bpy.data.worlds.new("BiomePreviewWorld")
    world.use_nodes = True
    background = world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.030, 0.038, 0.045, 1.0)
    background.inputs["Strength"].default_value = 0.65
    scene.world = world

    if recipe.category != "flyer":
        mesh = bpy.data.meshes.new("BiomePreviewGroundMesh")
        extent = max(recipe.height * 1.35, 1.2)
        mesh.from_pydata(
            [(-extent, -extent, 0.0), (extent, -extent, 0.0),
             (extent, extent, 0.0), (-extent, extent, 0.0)],
            [], [(0, 1, 2, 3)],
        )
        mesh.materials.append(_preview_material(
            "BiomePreviewGroundMaterial", (0.075, 0.082, 0.085, 1.0), 0.88))
        ground = bpy.data.objects.new("BiomePreviewGround", mesh)
        bpy.context.scene.collection.objects.link(ground)

    low, high = _bounds(obj.data.vertices)
    width = max(high.x - low.x, high.y - low.y)
    if recipe.category == "flyer":
        spans = high - low
        framing = max(spans) * 1.42
        focus = Vector((0.0, 0.0, 0.0))
        camera_location = Vector((
            framing * 0.88, -framing * 1.42, framing * 0.72))
    else:
        framing = max(recipe.height * 1.18, width * 1.42)
        focus = Vector((0.0, 0.0, recipe.height * 0.48))
        camera_location = Vector((
            framing * 0.95, -framing * 1.25, recipe.height * 0.82))
    camera_data = bpy.data.cameras.new("BiomePreviewCamera")
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = framing
    camera = bpy.data.objects.new("BiomePreviewCamera", camera_data)
    bpy.context.scene.collection.objects.link(camera)
    scene.camera = camera
    _look_at(
        camera,
        camera_location,
        focus,
    )

    distance = max(
        recipe.height, width, 0.18 if recipe.category == "flyer" else 0.75)
    energy_scale = distance * distance
    _add_preview_light(
        "BiomeKey", focus + Vector((1.7, -1.8, 2.2)) * distance,
        focus, 250.0 * energy_scale, 2.1 * distance)
    _add_preview_light(
        "BiomeFill", focus + Vector((-2.0, -0.5, 1.0)) * distance,
        focus, 80.0 * energy_scale, 2.8 * distance)
    _add_preview_light(
        "BiomeRim", focus + Vector((-0.8, 2.0, 1.8)) * distance,
        focus, 170.0 * energy_scale, 1.8 * distance)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise ValueError("preview render did not produce {}".format(path))


def _reset_scene() -> None:
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in list(bpy.data.meshes):
        bpy.data.meshes.remove(mesh)
    for material in list(bpy.data.materials):
        bpy.data.materials.remove(material)
    for light in list(bpy.data.lights):
        bpy.data.lights.remove(light)
    for camera in list(bpy.data.cameras):
        bpy.data.cameras.remove(camera)
    for world in list(bpy.data.worlds):
        bpy.data.worlds.remove(world)
    for image in list(bpy.data.images):
        bpy.data.images.remove(image)


def _build_one(recipe: AssetRecipe, output_dir: str) -> dict[str, object]:
    print("\n=== {} ===".format(recipe.name))
    _reset_scene()
    bm = bmesh.new()
    # Adding a BMesh custom-data layer can invalidate existing BMFace Python
    # handles in Blender 5.x, so create the palette layer before any builder
    # returns faces for tagging.
    bm.faces.layers.int.new(PALETTE_ATTRIBUTE)
    BUILDERS[recipe.archetype](recipe, bm)
    obj = _finish_object(recipe, bm)

    if obj.type != "MESH" or obj.data.shape_keys is not None:
        raise ValueError("{} is not a plain static mesh".format(recipe.name))
    if obj.parent is not None or obj.animation_data is not None:
        raise ValueError("{} has unexpected hierarchy or animation data".format(
            recipe.name))
    source_triangles = build_vat.triangle_count(obj.data)
    minimum, maximum = recipe.triangle_budget
    if not minimum <= source_triangles <= maximum:
        raise ValueError("{} generated {} triangles, budget is {}..{}".format(
            recipe.name, source_triangles, minimum, maximum))
    low, high = _bounds(obj.data.vertices)
    measured_height = high.z - low.z
    if recipe.category == "flyer":
        spans = high - low
        longest_dimension = max(spans)
        centre = (low + high) * 0.5
        if abs(longest_dimension - recipe.height) > 1.0e-5:
            raise ValueError(
                "{} longest dimension {} differs from authored {}".format(
                    recipe.name, longest_dimension, recipe.height))
        if max(abs(value) for value in centre) > 1.0e-6:
            raise ValueError("{} source flyer is off-centre: {}".format(
                recipe.name, tuple(centre)))
        if not low.z < 0.0 < high.z:
            raise ValueError("{} source flyer must straddle Blender Z=0".format(
                recipe.name))
    else:
        longest_dimension = max(high - low)
        if abs(low.z) > 1.0e-7:
            raise ValueError("{} base is at Z={}, expected zero".format(
                recipe.name, low.z))
        if abs(measured_height - recipe.height) > 1.0e-5:
            raise ValueError("{} measured height {} differs from authored {}".format(
                recipe.name, measured_height, recipe.height))

    glb_path = os.path.join(output_dir, recipe.name + ".glb")
    _export_glb(obj, glb_path)
    validation = _validate_glb(glb_path, recipe, source_triangles)

    paint_relative = "{}/{}_paint.png".format(PAINT_FOLDER, recipe.name)
    paint_path = os.path.join(PAINT_DIR, recipe.name + "_paint.png")
    paint_image = _write_paint_texture(recipe, paint_path)
    _preview_with_paint(obj.data.materials[0], paint_image)
    preview_relative = "{}/{}.png".format(PREVIEW_FOLDER, recipe.name)
    preview_path = os.path.join(PREVIEW_DIR, recipe.name + ".png")
    _render_preview(obj, recipe, preview_path)
    file_size = os.path.getsize(glb_path)
    paint_size = os.path.getsize(paint_path)
    preview_size = os.path.getsize(preview_path)
    print(
        "  wrote {}: {} triangles, {} GLB vertices, {:.1f} KB; "
        "paint {:.1f} KB; preview {:.1f} KB".format(
            os.path.basename(glb_path),
            validation["triangle_count"],
            validation["glb_vertex_count"],
            file_size / 1024.0,
            paint_size / 1024.0,
            preview_size / 1024.0,
        )
    )
    entry = {
        "name": recipe.name,
        "category": recipe.category,
        "glb": "assets/runtime/biomes/models/{}.glb".format(recipe.name),
        "color_paint": paint_relative,
        "preview": preview_relative,
        "authored_height": round(measured_height, 6),
        "triangle_count": validation["triangle_count"],
        "glb_vertex_count": validation["glb_vertex_count"],
        "triangle_budget": {
            "minimum": recipe.triangle_budget[0],
            "maximum": recipe.triangle_budget[1],
        },
        "collision_hint": recipe.collision_hint,
        "suggested_vertex_colour_style": recipe.vertex_colour_style,
        "color_paint_style": _paint_style(recipe),
        "suggested_emission_style": recipe.emission_style,
        "emission_strength": recipe.emission_strength,
        "material": {
            "roughness": recipe.roughness,
            "vertex_colour_attribute": "COLOR_0",
            "color_paint_uv": "TEXCOORD_0",
            "color_paint_size": [PAINT_SIZE, PAINT_SIZE],
        },
        "runtime_contract": {
            "mesh_node": recipe.name,
            "mesh_count": 1,
            "primitive_count": validation["primitive_count"],
            "paint_texture": paint_relative,
            "skins": 0,
            "animations": 0,
            "ground_axis": "Godot/glTF +Y",
        },
        "file_size_bytes": file_size,
        "paint_size_bytes": paint_size,
        "preview_size_bytes": preview_size,
    }
    if recipe.form.startswith("crystal") or recipe.form in {
            "rune_monolith", "rune_boulder"}:
        entry["material"]["color_paint_alpha"] = (
            "broad mip-safe emission mask; never used as transparency")
        entry["runtime_contract"]["emission_mask"] = (
            paint_relative + " alpha")
    if recipe.category == "flyer":
        entry["authored_longest_dimension"] = round(longest_dimension, 6)
        entry["forward_axis"] = (
            "local -Z is body-forward; local +Y is dorsal/up")
        entry["runtime_contract"]["placement"] = "airborne_centred"
        entry["runtime_contract"]["grounding"] = (
            "bounds centred near origin and straddling local Y=0")
    return entry


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        default=DEFAULT_OUTPUT_DIR,
        help="Runtime biome-model destination (default: assets/runtime/biomes/models)",
    )
    parser.add_argument(
        "--only",
        nargs="+",
        metavar="NAME",
        help="Build only named recipes; comma-separated names are also accepted",
    )
    blender_arguments = (
        sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    )
    return parser.parse_args(blender_arguments)


def _selected_recipes(only: Sequence[str] | None) -> list[AssetRecipe]:
    if not only:
        return list(RECIPES)
    requested: list[str] = []
    for value in only:
        requested.extend(name.strip() for name in value.split(",") if name.strip())
    unknown = sorted(set(requested) - set(RECIPE_BY_NAME))
    if unknown:
        raise ValueError(
            "unknown --only recipe(s): {}; available: {}".format(
                ", ".join(unknown), ", ".join(RECIPE_BY_NAME)))
    requested_set = set(requested)
    return [recipe for recipe in RECIPES if recipe.name in requested_set]


def _manifest_base() -> dict[str, object]:
    return {
        "schema": "procedural_biome_asset_manifest",
        "version": MANIFEST_VERSION,
        "generator": "assets/source/blender/build_biome_assets.py",
        "coordinate_system": {
            "authoring": "Blender Z-up, metres",
            "runtime": "glTF/Godot Y-up, metres",
            "axis_conversion": "Blender (x, y, z) -> glTF/Godot (x, z, -y)",
            "ground_plane": "runtime Y=0",
        },
        "library_contract": {
            "multi_mesh_ready": True,
            "one_mesh_per_glb": True,
            "one_primitive_per_mesh": True,
            "vertex_colour": "COLOR_0",
            "color_paint_uv": "TEXCOORD_0",
            "external_color_paint": "one PNG per asset under {}".format(
                PAINT_FOLDER),
            "skins": 0,
            "animations": 0,
        },
        "assets": {},
    }


def _write_manifest(
    output_dir: str,
    entries: Sequence[dict[str, object]],
    *,
    partial: bool,
) -> str:
    path = os.path.join(MANIFEST_DIR, "biome_assets.json")
    manifest = _manifest_base()
    if partial and os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as stream:
            existing = json.load(stream)
        if (
            existing.get("schema") == manifest["schema"]
            and existing.get("version") == manifest["version"]
        ):
            manifest["assets"].update(existing.get("assets", {}))
    for entry in entries:
        manifest["assets"][entry["name"]] = entry
    # Recipe order keeps diffs stable; any legacy/unknown entries follow sorted.
    ordered = {}
    assets = manifest["assets"]
    for recipe in RECIPES:
        if recipe.name in assets:
            ordered[recipe.name] = assets[recipe.name]
    for name in sorted(set(assets) - set(ordered)):
        ordered[name] = assets[name]
    manifest["assets"] = ordered
    manifest["asset_count"] = len(ordered)
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(manifest, stream, indent=2, sort_keys=False)
        stream.write("\n")
    return path


def main() -> None:
    arguments = _arguments()
    output_dir = os.path.abspath(arguments.output_dir)
    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(PAINT_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    os.makedirs(MANIFEST_DIR, exist_ok=True)
    selected = _selected_recipes(arguments.only)
    if not selected:
        raise ValueError("no biome recipes selected")

    entries = []
    total_triangles = 0
    total_bytes = 0
    for recipe in selected:
        entry = _build_one(recipe, output_dir)
        entries.append(entry)
        total_triangles += int(entry["triangle_count"])
        total_bytes += int(entry["file_size_bytes"])
    manifest_path = _write_manifest(
        output_dir, entries, partial=arguments.only is not None)

    summary = {
        "output_dir": output_dir,
        "manifest": manifest_path,
        "asset_count": len(entries),
        "total_triangles": total_triangles,
        "total_glb_bytes": total_bytes,
        "assets": {
            entry["name"]: {
                "triangles": entry["triangle_count"],
                "glb_kib": round(int(entry["file_size_bytes"]) / 1024.0, 1),
                "paint_kib": round(int(entry["paint_size_bytes"]) / 1024.0, 1),
                "preview_kib": round(int(entry["preview_size_bytes"]) / 1024.0, 1),
            }
            for entry in entries
        },
    }
    print("\nBIOME_BUILD_SUMMARY")
    print(json.dumps(summary, indent=2, sort_keys=True))
    print("biome asset build complete")


if __name__ == "__main__":
    main()
