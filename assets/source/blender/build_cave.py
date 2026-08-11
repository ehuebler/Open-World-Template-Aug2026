"""Builds the cave entry room and exports assets/runtime/environment/cave_room.glb.

Run headless from the project root; it needs no input .blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup --python assets/source/blender/build_cave.py

The room is a chamber about 10 m in radius and 9 m tall with a tunnel mouth
breaking through one wall, lit by purple and green crystal clusters. Its origin is
the centre of the floor. The tunnel is built along Blender's `+X`, which the `+Y`-up
export leaves as `+X` in Godot.

Three things are worth knowing before editing it:

- The shell is authored as a **solid volume** and turned inside out at the end.
  Carving a room out of nothing is far more awkward than building the rock it
  displaces, and it lets the tunnel be a plain boolean union.
- Displacement is a function of **position, not surface normal**. Two coincident
  vertices either side of the boolean seam carry different normals, so displacing
  along normals tears the shell open there.
- The tunnel's faces keep their own near-black material through the boolean, which
  is what makes the hole read as dark rather than as a lit alcove.
"""

import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector, noise

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

from propkit import (add_cone, add_loft, add_path_loft, catmull_rom, circle_profile,
                     ensure_materials, evaluated_polys, export_selected, new_object,
                     reset_scene, ring, squircle_profile)

PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
ASSET_DIR = os.path.join(PROJECT_DIR, "assets", "runtime", "environment")
BLEND_PATH = os.path.join(SOURCE_DIR, "cave_room.blend")
GLB_PATH = os.path.join(ASSET_DIR, "cave_room.glb")

ROCK_MATERIALS = {
    "CaveRock": {"colour": (0.118, 0.110, 0.122, 1.0), "roughness": 0.92},
    "CaveTunnel": {"colour": (0.026, 0.024, 0.030, 1.0), "roughness": 0.95},
}
CRYSTAL_MATERIALS = {
    "CrystalPurple": {"colour": (0.28, 0.09, 0.50, 1.0), "roughness": 0.20,
                      "emission": ((0.52, 0.16, 0.96, 1.0), 2.6)},
    "CrystalGreen": {"colour": (0.09, 0.34, 0.17, 1.0), "roughness": 0.20,
                     "emission": ((0.20, 0.98, 0.44, 1.0), 2.2)},
}
ROCK, TUNNEL = 0, 1
PURPLE, GREEN = 0, 1

# (radius, height) from the centre of the floor round to the apex of the ceiling.
# Widest a little above head height so the walls overhang and the room feels
# enclosed rather than like a bowl.
ROOM_PROFILE = [
    (0.00, 0.00),
    (2.20, -0.12),
    (4.40, -0.06),
    (6.60, 0.10),
    (8.40, 0.34),
    (9.60, 0.90),
    (10.30, 1.95),
    (10.55, 3.10),
    (10.35, 4.40),
    (9.70, 5.60),
    (8.60, 6.70),
    (6.90, 7.60),
    (4.80, 8.25),
    (2.50, 8.70),
    (0.00, 8.90),
]
ROOM_SEGMENTS = 132
ROOM_RINGS = 44

# Starts inside the room so the union has something to cut through, then bends away
# and drops, so nothing of the far end is visible from the chamber.
TUNNEL_PATH = [
    (6.5, 0.0, 3.10),
    (10.0, 0.0, 3.10),
    (13.5, 0.8, 2.95),
    (17.0, 2.6, 2.60),
    (20.0, 5.4, 2.15),
    (22.5, 9.0, 1.60),
]
TUNNEL_SECTIONS = [(2.55, 2.35), (2.50, 2.30), (2.30, 2.12),
                   (2.05, 1.92), (1.82, 1.72), (1.60, 1.55)]
TUNNEL_SAMPLES = 30
TUNNEL_SEGMENTS = 32

# mathutils.noise has a feature size of about one unit, so these are "one noise
# feature per 1/frequency metres". The coarse field wants features of a few metres,
# a fraction of the room; set it far lower and the whole chamber sits inside a
# single feature and the noise flattens into a uniform offset.
COARSE_FREQUENCY = 0.20
COARSE_AMPLITUDE = 1.25
FINE_FREQUENCY = 0.90
FINE_AMPLITUDE = 0.34

# Low enough that the rock facets. Smoothing the shell across its lumps turns metres
# of displacement into soft gradients that read as fog rather than stone.
SMOOTH_ANGLE = 24.0
FORMATION_SMOOTH_ANGLE = 30.0

# mathutils.noise seeds itself from the clock, and its vector variants read that
# seed, so an unseeded build produces a different cave every time - which also moves
# every stalagmite and crystal, since those are placed by raycasting at the rock.
NOISE_SEED = 2718

# (material, cast from, cast towards, cluster size, crystal count, seed)
CLUSTERS = [
    (PURPLE, (0.0, 0.0, 2.40), (-0.62, 0.79, -0.10), 2.30, 11, 11),
    (PURPLE, (-2.60, 3.60, 4.00), (0.0, 0.0, 1.0), 1.30, 8, 12),
    (PURPLE, (-1.80, 2.20, 3.00), (-0.30, 0.38, -1.0), 0.95, 7, 13),
    (GREEN, (-2.60, -5.90, 3.00), (-0.28, -0.62, -1.0), 2.00, 10, 21),
    (GREEN, (0.0, 0.0, 1.90), (0.50, -0.86, -0.12), 1.40, 8, 22),
    (GREEN, (3.20, -3.60, 2.60), (0.42, -0.48, -1.0), 0.85, 6, 23),
    # Flanking the tunnel mouth. Without these the wall around the opening is as
    # unlit as the opening itself, and a dark hole in dark rock is not a hole at
    # all - it needs lit rock around it to read against. They sit to either side so
    # the light grazes the wall rather than reaching down the passage.
    (PURPLE, (0.0, 0.0, 2.20), (0.766, 0.643, -0.10), 1.05, 7, 31),
    (GREEN, (0.0, 0.0, 2.20), (0.766, -0.643, -0.10), 0.95, 6, 32),
]

# (cluster index, name, colour, energy in W, soft size). A point light falls off as
# the inverse square, so lighting a 20 m chamber from 5 m away takes a few hundred
# watts, not the few thousand that reads as reasonable for a lamp in a small room.
LIGHTS = [
    (0, "GlowPurple", (0.58, 0.22, 1.0), 340.0, 0.7),
    (3, "GlowGreen", (0.26, 1.0, 0.44), 280.0, 0.6),
    (1, "GlowPurpleCeiling", (0.55, 0.25, 1.0), 115.0, 0.4),
    (5, "GlowGreenFloor", (0.28, 1.0, 0.48), 55.0, 0.35),
    (6, "GlowPurpleMouth", (0.56, 0.24, 1.0), 185.0, 0.45),
    (7, "GlowGreenMouth", (0.28, 1.0, 0.46), 150.0, 0.40),
]

# Stalagmites off the floor and stalactites off the ceiling. Surface noise alone
# does not read as a cave; the dripstone is what says one.
FLOOR_SPIKES = 16
CEILING_SPIKES = 22
SPIKE_SEED = 404
SPIKE_REACH = 8.6      # keep them clear of the walls and the tunnel mouth


def smoothstep(value, low, high):
    t = min(1.0, max(0.0, (value - low) / (high - low)))
    return t * t * (3.0 - 2.0 * t)


def calm(point):
    """How much of the displacement to keep at `point`, in 0..1.

    Full-strength noise everywhere would leave a floor nobody can walk over and a
    tunnel that pinches shut, so it is damped low down and along the tunnel. This
    depends only on position, so it cannot tear the shell.
    """
    factor = 0.26 + 0.74 * smoothstep(point.z, 0.0, 1.60)
    reach = math.hypot(point.x, point.y)
    return factor * (1.0 - 0.68 * smoothstep(reach, 9.0, 13.0))


def rock_offset(point):
    """Position-based displacement that turns a lathed dome into rock."""
    damp = calm(point)
    coarse = noise.turbulence_vector(point * COARSE_FREQUENCY, 3, False)
    fine = noise.turbulence_vector(point * FINE_FREQUENCY, 2, False)
    return (coarse * (COARSE_AMPLITUDE * damp)
            + fine * (FINE_AMPLITUDE * (0.40 + 0.60 * damp)))


def interpolate_sections(sections, count):
    """Resample (half_wide, half_thick) pairs to match a resampled path."""
    spans = len(sections) - 1
    resampled = []
    for i in range(count):
        position = i / (count - 1) * spans
        span = min(int(position), spans - 1)
        blend = position - span
        low, high = sections[span], sections[span + 1]
        resampled.append((low[0] + (high[0] - low[0]) * blend,
                          low[1] + (high[1] - low[1]) * blend))
    return resampled


def room_bmesh():
    """The chamber, as a solid of revolution with a pole at each end."""
    bm = bmesh.new()
    sampled = catmull_rom([Vector((r, z, 0.0)) for r, z in ROOM_PROFILE], ROOM_RINGS)
    shape = circle_profile(ROOM_SEGMENTS)
    rings = []
    for point in sampled:
        radius = max(0.0, point.x)
        rings.append(ring((0.0, 0.0, point.y),
                          (radius, 0.0, 0.0), (0.0, radius, 0.0), shape))
    add_loft(bm, rings, ROCK, cap_start=False, cap_end=False)
    # The end rings collapse to a point, which leaves a fan of coincident vertices;
    # welding them turns those degenerate quads into the triangles a pole needs.
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    return bm


def tunnel_bmesh():
    bm = bmesh.new()
    path = catmull_rom([Vector(point) for point in TUNNEL_PATH], TUNNEL_SAMPLES)
    add_path_loft(bm, path, interpolate_sections(TUNNEL_SECTIONS, TUNNEL_SAMPLES),
                  TUNNEL, wide_hint=(0.0, 1.0, 0.0),
                  profile=squircle_profile(TUNNEL_SEGMENTS, 2.5))
    return bm


def union(slots):
    """Merge the chamber and the tunnel into one shell.

    Both are clean lathed volumes at this point. Displacing them first and then
    booleaning gives the exact solver two noisy surfaces to intersect and it starts
    producing slivers, so the noise goes on afterwards.
    """
    room = new_object("RoomSolid", room_bmesh(), slots)
    tunnel = new_object("TunnelSolid", tunnel_bmesh(), slots)

    boolean = room.modifiers.new("Tunnel", "BOOLEAN")
    boolean.operation = "UNION"
    boolean.object = tunnel
    boolean.solver = "EXACT"
    bpy.context.view_layer.update()

    evaluated = room.evaluated_get(bpy.context.evaluated_depsgraph_get())
    merged = evaluated.to_mesh()
    bm = bmesh.new()
    bm.from_mesh(merged)
    evaluated.to_mesh_clear()

    bpy.data.objects.remove(room, do_unlink=True)
    bpy.data.objects.remove(tunnel, do_unlink=True)
    return bm


def build_shell(slots):
    bm = union(slots)
    for vert in bm.verts:
        vert.co = vert.co + rock_offset(vert.co.copy())
    return new_object("CaveRoom", bm, slots, smooth_angle=SMOOTH_ANGLE,
                      flip_normals=True)


def surface_hit(cave, origin, direction):
    """Where a ray leaving `origin` meets the rock, and the inward normal there.

    Normals point into the room, so a hit normal is already the direction a crystal
    should grow, whether it landed on the floor, a wall or the ceiling.
    """
    inverse = cave.matrix_world.inverted()
    found, location, normal, _ = cave.ray_cast(
        inverse @ Vector(origin),
        (inverse.to_3x3() @ Vector(direction)).normalized())
    if not found:
        return None
    return ((cave.matrix_world @ location),
            (cave.matrix_world.to_3x3() @ normal).normalized())


def open_edges(obj):
    """Edges not shared by exactly two faces.

    A room has to be closed. Any hole is somewhere the player can see out of the
    level, and it is also the first symptom of the boolean having gone wrong.
    """
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    count = sum(1 for edge in bm.edges if len(edge.link_faces) != 2)
    bm.free()
    return count


def facing_inward(cave, samples=48, height=2.5):
    """Fraction of rays cast out of the room that hit a face looking back at them.

    Checking the winding by eye is impossible from inside, and getting it backwards
    means the room renders as nothing at all once backface culling is on.
    """
    hits, inward = 0, 0
    for i in range(samples):
        angle = math.tau * i / samples
        direction = (math.cos(angle), math.sin(angle), -0.25 + 0.5 * (i % 3))
        hit = surface_hit(cave, (0.0, 0.0, height), direction)
        if hit is None:
            continue
        hits += 1
        if hit[1].dot(Vector(direction).normalized()) < 0.0:
            inward += 1
    return inward, hits


def dripstone(bm, anchor, up, length, radius, slot, rng, samples=9):
    """A tapered, slightly bent spike: stalagmite growing up, stalactite hanging down.

    The bend matters more than it sounds. A straight cone reads as a traffic cone;
    a couple of degrees of lean is what makes it look deposited.
    """
    up = Vector(up).normalized()
    drift = Vector((rng.uniform(-1.0, 1.0), rng.uniform(-1.0, 1.0), 0.0))
    if drift.length < 1e-4:
        drift = Vector((1.0, 0.0, 0.0))
    drift = drift.normalized() * length * rng.uniform(0.05, 0.18)

    path = catmull_rom([anchor - up * radius * 0.7,
                        anchor + up * length * 0.35 + drift * 0.35,
                        anchor + up * length * 0.75 + drift * 0.80,
                        anchor + up * length + drift], samples)
    sections = []
    for i in range(samples):
        t = i / (samples - 1.0)
        thickness = radius * ((1.0 - t) ** 1.25) + radius * 0.05
        sections.append((thickness, thickness))
    add_path_loft(bm, path, sections, slot, segments=7)


def build_formations(cave, slots, seed=SPIKE_SEED):
    """Scatter dripstone over the floor and ceiling, standing it on the real rock.

    Positions come from rays cast at the finished shell, so every spike meets the
    displaced surface instead of hovering over or sinking into where a smooth dome
    would have been.
    """
    rng = random.Random(seed)
    bm = bmesh.new()
    placed = {"floor": 0, "ceiling": 0}

    def scatter(count, cast_from, direction, length_range, slenderness, key):
        attempts = 0
        while placed[key] < count and attempts < count * 30:
            attempts += 1
            angle = rng.uniform(0.0, math.tau)
            reach = SPIKE_REACH * math.sqrt(rng.random())
            x, y = reach * math.cos(angle), reach * math.sin(angle)
            # The tunnel mouth is on +X; leave its approach clear.
            if x > 6.0 and abs(y) < 4.0:
                continue
            hit = surface_hit(cave, (x, y, cast_from), direction)
            if hit is None:
                continue
            anchor, normal = hit
            # Reject overhangs: a spike on a steep face slides off the silhouette.
            if normal.dot(Vector(direction)) > -0.72:
                continue
            length = rng.uniform(*length_range)
            dripstone(bm, anchor, normal, length, length * slenderness, ROCK, rng)
            placed[key] += 1

    # Stalagmites are stubbier than stalactites: they build up from what drips down.
    scatter(FLOOR_SPIKES, 7.5, (0.0, 0.0, -1.0), (0.50, 2.00), 0.30, "floor")
    scatter(CEILING_SPIKES, 1.5, (0.0, 0.0, 1.0), (0.50, 2.60), 0.18, "ceiling")

    obj = new_object("CaveFormations", bm, slots,
                     smooth_angle=FORMATION_SMOOTH_ANGLE)
    return obj, placed


def crystal_cluster(bm, anchor, up, slot, size, count, seed):
    """A splay of tapered hexagonal prisms growing out of the rock along `up`."""
    rng = random.Random(seed)
    up = Vector(up).normalized()
    side = up.cross(Vector((0.0, 0.0, 1.0)))
    if side.length < 1e-4:
        side = up.cross(Vector((1.0, 0.0, 0.0)))
    side.normalize()
    other = up.cross(side).normalized()

    for _ in range(count):
        angle = rng.uniform(0.0, math.tau)
        outward = side * math.cos(angle) + other * math.sin(angle)
        # sqrt keeps the bases evenly spread over the disc instead of crowding
        # the centre, so a cluster does not read as one lump.
        offset = outward * size * 0.85 * math.sqrt(rng.random())
        direction = (up + outward * rng.uniform(0.12, 0.55)).normalized()
        length = size * rng.uniform(0.42, 1.0)
        radius = length * rng.uniform(0.11, 0.19)
        base = anchor + offset - up * size * 0.20
        add_cone(bm, base, base + direction * length, radius, radius * 0.16,
                 slot, segments=6)


def build_crystals(cave, slots):
    bm = bmesh.new()
    anchors = []
    for slot, origin, direction, size, count, seed in CLUSTERS:
        hit = surface_hit(cave, origin, direction)
        if hit is None:
            raise RuntimeError("cluster ray from {0} missed the rock".format(origin))
        anchor, normal = hit
        crystal_cluster(bm, anchor, normal, slot, size, count, seed)
        anchors.append((anchor, normal, size))
    return new_object("CaveCrystals", bm, slots, smooth_angle=18.0), anchors


def add_lights(anchors):
    """Point lights standing just off each glowing cluster.

    The crystals are emissive, but nothing here runs ray-traced GI, so emission
    alone lights nothing. These carry the room and export as real light nodes.
    """
    lights = []
    for index, name, colour, energy, soft in LIGHTS:
        anchor, normal, size = anchors[index]
        data = bpy.data.lights.new(name, type="POINT")
        data.color = colour
        data.energy = energy
        data.shadow_soft_size = soft
        light = bpy.data.objects.new(name, data)
        bpy.context.scene.collection.objects.link(light)
        light.location = anchor + normal * size * 0.75
        lights.append(light)
    return lights


def main():
    reset_scene()
    noise.seed_set(NOISE_SEED)
    rock_slots = ensure_materials(ROCK_MATERIALS)
    crystal_slots = ensure_materials(CRYSTAL_MATERIALS)

    cave = build_shell(rock_slots)
    formations, placed = build_formations(cave, rock_slots)
    crystals, anchors = build_crystals(cave, crystal_slots)
    lights = add_lights(anchors)

    points = [vert.co for vert in cave.data.vertices]
    print("cave spans x {0:.1f}..{1:.1f}  y {2:.1f}..{3:.1f}  z {4:.1f}..{5:.1f}".format(
        min(p.x for p in points), max(p.x for p in points),
        min(p.y for p in points), max(p.y for p in points),
        min(p.z for p in points), max(p.z for p in points)))
    # Measure the chamber away from the tunnel, which leaves on +X.
    chamber = [p for p in points if p.x < 7.0]
    print("chamber radius {0:.1f} m, ceiling {1:.1f} m, floor {2:+.2f} m".format(
        max(math.hypot(p.x, p.y) for p in chamber), max(p.z for p in chamber),
        min(p.z for p in chamber)))
    print("polys: shell={0} formations={1} crystals={2}".format(
        evaluated_polys(cave), evaluated_polys(formations), evaluated_polys(crystals)))
    print("dripstone: {0} off the floor, {1} off the ceiling".format(
        placed["floor"], placed["ceiling"]))
    inward, hits = facing_inward(cave)
    print("shell: {0} open edges, {1}/{2} sampled faces look inward".format(
        open_edges(cave), inward, hits))
    for anchor, _, size in anchors:
        print("  cluster size {0:.2f} at ({1:+.1f}, {2:+.1f}, {3:.1f})".format(
            size, anchor.x, anchor.y, anchor.z))

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export_selected([cave, formations, crystals] + lights, GLB_PATH,
                    include_lights=True)


if __name__ == "__main__":
    main()
