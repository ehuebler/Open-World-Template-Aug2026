"""Shared render scaffold for the prop previews.

Imported by the render_*.py scripts. Blender runs scripts with `--python`, which
does not put the script's folder on sys.path, so importers need:

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

A `Preview` owns the engine settings, world, camera and light rig for one scene,
so a render script is just a list of framings.
"""

import os

import bpy
from mathutils import Vector

BACKGROUND = (0.055, 0.058, 0.066, 1.0)


def _look_at(obj, location, target):
    obj.location = location
    obj.rotation_euler = (Vector(target) - Vector(location)).to_track_quat(
        "-Z", "Y").to_euler()


class Preview:
    """Engine, world, camera and a three-point rig, pointed wherever asked."""

    def __init__(self, output_dir, samples=96, background=BACKGROUND):
        self.output_dir = output_dir
        self._set_engine(samples)
        self._set_world(background)
        self.camera = self._add_camera()

    @staticmethod
    def _set_engine(samples):
        scene = bpy.context.scene
        for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
            try:
                scene.render.engine = engine
                break
            except TypeError:
                continue
        if hasattr(scene, "eevee"):
            scene.eevee.taa_render_samples = samples
        for transform in ("Khronos PBR Neutral", "AgX", "Filmic", "Standard"):
            try:
                scene.view_settings.view_transform = transform
                break
            except TypeError:
                continue

    @staticmethod
    def _set_world(background):
        world = (bpy.data.worlds.get("PreviewWorld")
                 or bpy.data.worlds.new("PreviewWorld"))
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs["Color"].default_value = background
        bpy.context.scene.world = world

    @staticmethod
    def _add_camera():
        data = bpy.data.cameras.new("PreviewCamera")
        camera = bpy.data.objects.new("PreviewCamera", data)
        bpy.context.scene.collection.objects.link(camera)
        bpy.context.scene.camera = camera
        return camera

    @staticmethod
    def _add_area_light(name, location, target, energy, size):
        data = bpy.data.lights.new(name, type="AREA")
        data.energy = energy
        data.size = size
        light = bpy.data.objects.new(name, data)
        bpy.context.scene.collection.objects.link(light)
        _look_at(light, location, target)

    def lights(self, focus, spread=1.0, gain=1.0):
        """Three-point rig scaled around `focus`, replacing any previous rig.

        Energy goes with spread squared, so the exposure at `focus` holds as the rig
        scales. Without that, pulling it in for a prop-sized subject raises the
        irradiance by the inverse square and the view transform clips every albedo
        to white - which is what made dark leather render as pale pink. Use `gain`
        to lift a subject that is genuinely dark rather than badly lit.
        """
        for light in [obj for obj in bpy.data.objects if obj.type == "LIGHT"]:
            bpy.data.objects.remove(light, do_unlink=True)
        focus = Vector(focus)
        falloff = spread ** 2 * gain
        self._add_area_light("Key", focus + Vector((1.6, -1.2, 1.9)) * spread,
                             focus, 50.0 * falloff, 2.4 * spread)
        self._add_area_light("Fill", focus + Vector((-2.0, -1.0, 0.5)) * spread,
                             focus, 14.0 * falloff, 3.0 * spread)
        self._add_area_light("Rim", focus + Vector((-0.4, 2.2, 1.4)) * spread,
                             focus, 28.0 * falloff, 1.8 * spread)

    @staticmethod
    def ground(level=0.0, size=14.0, colour=(0.105, 0.110, 0.120, 1.0)):
        """A floor for props that stand on one.

        Furniture reads as floating without it, and more to the point there is no
        contact shadow, which is the only cue that tells you whether the legs
        actually reach the ground.
        """
        existing = bpy.data.objects.get("PreviewGround")
        if existing is not None:
            bpy.data.objects.remove(existing, do_unlink=True)
        mesh = bpy.data.meshes.new("PreviewGroundMesh")
        mesh.from_pydata([(-size, -size, level), (size, -size, level),
                          (size, size, level), (-size, size, level)],
                         [], [(0, 1, 2, 3)])
        mesh.update()
        material = (bpy.data.materials.get("PreviewGroundMaterial")
                    or bpy.data.materials.new("PreviewGroundMaterial"))
        material.use_nodes = True
        bsdf = material.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = colour
        bsdf.inputs["Roughness"].default_value = 0.85
        mesh.materials.append(material)
        ground = bpy.data.objects.new("PreviewGround", mesh)
        bpy.context.scene.collection.objects.link(ground)
        return ground

    def ortho(self, location, target, scale):
        self.camera.data.type = "ORTHO"
        self.camera.data.ortho_scale = scale
        _look_at(self.camera, location, target)

    def hero(self, location, target, lens=62.0):
        self.camera.data.type = "PERSP"
        self.camera.data.lens = lens
        _look_at(self.camera, location, target)

    def shot(self, name, resolution):
        scene = bpy.context.scene
        scene.render.resolution_x, scene.render.resolution_y = resolution
        os.makedirs(self.output_dir, exist_ok=True)
        scene.render.filepath = os.path.join(self.output_dir, name + ".png")
        bpy.ops.render.render(write_still=True)
