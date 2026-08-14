"""Generate runtime FaunaSpecies resources and the population scene.

This file is the editable catalogue. The Blender recipe owns geometry, UVs,
COLOR_0, paint PNGs, previews, and the asset manifest; this catalogue owns
habitat, appearance tuning, health, disposition, locomotion, moves, combat, and
streaming density.
"""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FAUNA_DIR = ROOT / "game" / "fauna"
SPECIES_DIR = FAUNA_DIR / "species"
MATERIAL_DIR = FAUNA_DIR / "materials"
SCENE_PATH = FAUNA_DIR / "fauna_populations.tscn"


SPECIES = (
    {
        "id": "lumaquill_porcupine",
        "display_name": "Lumaquill Porcupine",
        "model": "lumaquill_porcupine",
        "enabled": True,
        "disposition": 1,  # PASSIVE
        "move_set": 7,  # WALK | RUN | ATTACK (contact quills)
        "locomotion": 0,  # WALKER
        "attack_style": 1,  # CONTACT
        "paint_style": (
            "Broad turquoise flank bands, magenta quill chevrons, large yellow "
            "eyespots, and mip-safe cyan/magenta night marks"
        ),
        "height": 0.72,
        "height_variation": 0.10,
        "variant_tint_a": (0.84, 1.0, 1.0, 1.0),
        "variant_tint_b": (1.0, 0.76, 0.94, 1.0),
        "saturation": 1.38,
        "brightness": 1.10,
        "biome_tint_strength": 0.13,
        "night_emission_color": (0.15, 0.94, 1.0, 1.0),
        "night_emission_energy": 2.15,
        "night_emission_albedo": 0.62,
        "night_pulse_amount": 0.16,
        "night_pulse_speed": 0.34,
        "local_light_color": (0.12, 0.82, 1.0, 1.0),
        "local_light_energy": 1.45,
        "local_light_range": 7.5,
        "local_light_height_share": 0.58,
        "collision_radius_share": 0.42,
        "collision_height_share": 0.78,
        "combat_radius_share": 0.47,
        "ground_layer": 1,  # GRASS
        "minimum_ground_claim": 0.05,
        "above_water": 4.0,
        "below": 380.0,
        "minimum_arid": 0.0,
        "maximum_arid": 0.78,
        "minimum_frost": 0.0,
        "maximum_frost": 0.82,
        "max_slope": 27.0,
        "steady_over": 1.6,
        "steady_within": 0.82,
        "global_population": True,
        "cell_size": 82.0,
        "spawn_chance": 0.22,
        "pack_min": 2,
        "pack_max": 4,
        "pack_radius": 5.5,
        "maximum_instances": 10,
        "spawn_within": 210.0,
        "despawn_beyond": 278.0,
        "random_seed": 20268131,
        "colony_count": 4,
        "colony_near": 30.0,
        "colony_far": 62.0,
        "health": 62.0,
        "health_per_metre": 12.0,
        "toughness": 0,  # SOFT
        "respawn_delay": 16.0,
        "walk_speed": 1.65,
        "run_speed": 4.7,
        "move_acceleration": 18.0,
        "turn_speed": 8.0,
        "wander_radius": 17.0,
        "wander_pause": 2.5,
        "notice_range": 12.0,
        "flee_range": 7.5,
        "physics_within": 45.0,
        "quadruped_gait": True,
        "leg_mask_color": (0.09, 0.14, 0.23, 1.0),
        "leg_mask_tolerance": 0.16,
        "gait_stride_share": 0.88,
        "gait_swing_share": 0.14,
        "gait_lift_share": 0.06,
        "gait_leg_top_share": 0.43,
        "body_rock_degrees": 7.5,
        "body_bob_share": 0.032,
        "attack_damage": 9.0,
        "attack_range": 0.08,
        "attack_radius": 0.52,
        "attack_windup": 0.0,
        "attack_cooldown": 0.85,
        "attack_knockback": 4.0,
        "roughness": 0.55,
        "specular": 0.32,
        "texture_relief": 1.25,
        "detail_scale": 10.0,
        "detail_amount": 0.12,
        "bump_scale": 15.0,
        "bump_strength": 0.13,
        "macro_scale": 1.1,
        "macro_amount": 0.10,
        "camera_rim_color": (0.12, 0.94, 1.0, 1.0),
        "camera_rim_energy": 0.34,
    },
    {
        "id": "prism_coil_slinky",
        "display_name": "Prism-Coil Slinky",
        "model": "prism_coil_slinky",
        "enabled": False,
        "disposition": 2,  # HOSTILE
        "move_set": 7,  # WALK | RUN | ATTACK
        "locomotion": 2,  # END_OVER_END
        "attack_style": 2,  # BODY_SLAP
        "paint_style": (
            "Wide violet/teal coil bands, looping lime helix marks, pink slap "
            "pads, and a mip-safe luminous stripe mask"
        ),
        "height": 1.70,
        "height_variation": 0.08,
        "variant_tint_a": (0.90, 0.78, 1.0, 1.0),
        "variant_tint_b": (0.76, 1.0, 0.92, 1.0),
        "saturation": 1.48,
        "brightness": 1.11,
        "biome_tint_strength": 0.10,
        "night_emission_color": (0.30, 1.0, 0.78, 1.0),
        "night_emission_energy": 2.45,
        "night_emission_albedo": 0.56,
        "night_pulse_amount": 0.22,
        "night_pulse_speed": 0.25,
        "local_light_color": (0.34, 1.0, 0.72, 1.0),
        "local_light_energy": 1.8,
        "local_light_range": 10.5,
        "local_light_height_share": 0.52,
        "collision_radius_share": 0.43,
        "collision_height_share": 0.96,
        "combat_radius_share": 0.49,
        "ground_layer": 0,  # ANYWHERE
        "minimum_ground_claim": 0.0,
        "above_water": 5.0,
        "below": 460.0,
        "minimum_arid": 0.0,
        "maximum_arid": 1.0,
        "minimum_frost": 0.0,
        "maximum_frost": 0.94,
        "max_slope": 22.0,
        "steady_over": 2.6,
        "steady_within": 1.05,
        "global_population": True,
        "cell_size": 86.0,
        "spawn_chance": 0.15,
        "pack_min": 1,
        "pack_max": 2,
        "pack_radius": 7.0,
        "maximum_instances": 9,
        "spawn_within": 235.0,
        "despawn_beyond": 305.0,
        "random_seed": 20268132,
        "colony_count": 2,
        "colony_near": 54.0,
        "colony_far": 86.0,
        "health": 170.0,
        "health_per_metre": 28.0,
        "toughness": 1,  # WOODY
        "respawn_delay": 20.0,
        "walk_speed": 2.2,
        "run_speed": 7.2,
        "move_acceleration": 22.0,
        "turn_speed": 6.0,
        "wander_radius": 23.0,
        "wander_pause": 1.7,
        "notice_range": 21.0,
        "flee_range": 0.0,
        "physics_within": 55.0,
        "attack_damage": 22.0,
        "attack_range": 2.35,
        "attack_radius": 1.1,
        "attack_windup": 0.42,
        "attack_cooldown": 2.25,
        "attack_knockback": 10.5,
        "roughness": 0.40,
        "specular": 0.50,
        "texture_relief": 1.05,
        "detail_scale": 7.0,
        "detail_amount": 0.09,
        "bump_scale": 11.0,
        "bump_strength": 0.10,
        "macro_scale": 0.72,
        "macro_amount": 0.08,
        "camera_rim_color": (0.64, 0.32, 1.0, 1.0),
        "camera_rim_energy": 0.42,
    },
    {
        "id": "aurora_fleece_alpaca",
        "display_name": "Aurora-Fleece Alpaca",
        "model": "aurora_fleece_alpaca",
        "enabled": True,
        "disposition": 0,  # FRIENDLY
        # Attack is in the move set, but it is only ever reached by hurting one:
        # a friendly animal has no attack behaviour until it is provoked.
        "move_set": 7,  # WALK | RUN | ATTACK
        "locomotion": 0,  # WALKER
        "attack_style": 3,  # SPIT
        "paint_style": (
            "Pale lilac fleece streaks, a broad aurora-blue saddle, cream face "
            "and throat, indigo socks, magenta tail plume, and mip-safe "
            "luminous flank rosettes"
        ),
        "height": 1.30,
        "height_variation": 0.09,
        "variant_tint_a": (1.0, 0.94, 1.0, 1.0),
        "variant_tint_b": (0.88, 0.97, 1.0, 1.0),
        # Wool is pale by nature, and a pale palette under a bright sun washes
        # out to a white toy. The chroma is pushed and the brightness pulled back
        # so the saddle, socks, and plume still read at gameplay distance.
        "saturation": 1.45,
        "brightness": 0.99,
        "biome_tint_strength": 0.10,
        "night_emission_color": (0.46, 1.0, 0.92, 1.0),
        "night_emission_energy": 1.85,
        "night_emission_albedo": 0.50,
        "night_pulse_amount": 0.13,
        "night_pulse_speed": 0.22,
        "local_light_color": (0.44, 1.0, 0.90, 1.0),
        "local_light_energy": 1.25,
        "local_light_range": 8.5,
        "local_light_height_share": 0.62,
        "collision_radius_share": 0.31,
        "collision_height_share": 0.80,
        "combat_radius_share": 0.44,
        "ground_layer": 1,  # GRASS
        "minimum_ground_claim": 0.05,
        "above_water": 4.0,
        "below": 360.0,
        "minimum_arid": 0.0,
        "maximum_arid": 0.72,
        "minimum_frost": 0.0,
        "maximum_frost": 0.78,
        "max_slope": 24.0,
        "steady_over": 2.2,
        "steady_within": 1.0,
        # A colony-site herd only, for now: this one is being watched before it
        # is turned loose on every grassland on the planet.
        "global_population": False,
        "cell_size": 90.0,
        "spawn_chance": 0.18,
        "pack_min": 2,
        "pack_max": 4,
        "pack_radius": 7.5,
        "maximum_instances": 8,
        "spawn_within": 200.0,
        "despawn_beyond": 268.0,
        "random_seed": 20268133,
        "colony_count": 5,
        "colony_near": 20.0,
        "colony_far": 54.0,
        "health": 120.0,
        "health_per_metre": 20.0,
        "toughness": 0,  # SOFT
        "respawn_delay": 22.0,
        "walk_speed": 1.55,
        "run_speed": 6.2,
        "move_acceleration": 20.0,
        "turn_speed": 7.5,
        "wander_radius": 20.0,
        "wander_pause": 2.8,
        "notice_range": 16.0,
        "flee_range": 8.5,
        "physics_within": 50.0,
        "graze": True,
        "graze_chance": 0.62,
        "graze_seconds": 5.5,
        "bound_when_fleeing": True,
        "provoked_seconds": 9.0,
        "strafe_radius": 7.5,
        "strafe_speed": 4.6,
        "skeletal_clips": True,
        "clip_speed_scale": 1.15,
        "clip_blend": 0.18,
        "attack_damage": 7.0,
        # Reach is the spit's, not a bite's: it opens fire from across the ring
        # it is holding, and the windup matches the throw in the Spit clip.
        "attack_range": 14.0,
        "attack_radius": 0.62,
        "attack_windup": 0.45,
        "attack_cooldown": 1.9,
        "attack_knockback": 3.2,
        "attack_parryable": True,
        "spit_from_height_share": 0.82,
        "spit_from_forward_share": 0.60,
        "spit_speed": 18.0,
        "spit_gravity": 8.5,
        "spit_ball_radius": 0.13,
        "spit_hit_radius": 0.62,
        "spit_color": (0.60, 0.94, 1.0, 1.0),
        "spit_glow": 1.9,
        "roughness": 0.68,
        "specular": 0.24,
        "texture_relief": 1.45,
        "detail_scale": 13.0,
        "detail_amount": 0.16,
        "bump_scale": 19.0,
        "bump_strength": 0.17,
        "macro_scale": 1.3,
        "macro_amount": 0.12,
        "camera_rim_color": (0.52, 1.0, 0.94, 1.0),
        "camera_rim_energy": 0.30,
    },
)


MATERIAL_KEYS = (
    "roughness",
    "specular",
    "texture_relief",
    "detail_scale",
    "detail_amount",
    "bump_scale",
    "bump_strength",
    "macro_scale",
    "macro_amount",
    "camera_rim_energy",
)


def godot_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        text = f"{value:.6f}".rstrip("0").rstrip(".")
        return text + ".0" if "." not in text else text
    if isinstance(value, tuple) and len(value) == 4:
        return "Color({})".format(", ".join(
            godot_value(float(component)) for component in value))
    if isinstance(value, str):
        return '"{}"'.format(
            value.replace("\\", "\\\\").replace('"', '\\"'))
    raise TypeError(f"unsupported Godot value: {value!r}")


def write_material(definition: dict[str, object]) -> None:
    material = [
        "[gd_resource type=\"ShaderMaterial\" load_steps=2 format=3]",
        "",
        (
            "[ext_resource type=\"Shader\" "
            "path=\"res://shaders/vivid/vivid_surface.gdshader\" "
            "id=\"1_shader\"]"
        ),
        "",
        "[resource]",
        f"resource_name = {godot_value(definition['display_name'] + ' Surface')}",
        "shader = ExtResource(\"1_shader\")",
        "shader_parameter/base_color = Color(1.0, 1.0, 1.0, 1.0)",
        "shader_parameter/use_vertex_color = true",
        f"shader_parameter/saturation = {godot_value(definition['saturation'])}",
        f"shader_parameter/brightness = {godot_value(definition['brightness'])}",
        "shader_parameter/metallic = 0.0",
        "shader_parameter/roughness_variation = 0.18",
        "shader_parameter/relief_width = 2.0",
        "shader_parameter/region_albedo = 0.0",
        "shader_parameter/region_sheen = 0.28",
        "shader_parameter/region_rim = 0.42",
        "shader_parameter/detail_near = 10.0",
        "shader_parameter/detail_far = 52.0",
        (
            "shader_parameter/camera_rim_color = "
            + godot_value(definition["camera_rim_color"])
        ),
        (
            "shader_parameter/night_emission_color = "
            + godot_value(definition["night_emission_color"])
        ),
        (
            "shader_parameter/night_emission_energy = "
            + godot_value(definition["night_emission_energy"])
        ),
        "shader_parameter/night_emission_from_texture_alpha = true",
    ]
    for key in MATERIAL_KEYS:
        material.append(
            f"shader_parameter/{key} = {godot_value(definition[key])}")
    material.append("")
    path = MATERIAL_DIR / f"{definition['id']}.tres"
    path.write_text("\n".join(material), encoding="utf-8", newline="\n")


def write_species(definition: dict[str, object]) -> None:
    species = [
        (
            "[gd_resource type=\"Resource\" script_class=\"FaunaSpecies\" "
            "load_steps=5 format=3]"
        ),
        "",
        (
            "[ext_resource type=\"Script\" "
            "path=\"res://game/fauna/fauna_species.gd\" id=\"1_species\"]"
        ),
        (
            "[ext_resource type=\"PackedScene\" "
            f"path=\"res://assets/runtime/fauna/models/{definition['model']}.glb\" "
            "id=\"2_model\"]"
        ),
        (
            "[ext_resource type=\"ShaderMaterial\" "
            f"path=\"res://game/fauna/materials/{definition['id']}.tres\" "
            "id=\"3_material\"]"
        ),
        (
            "[ext_resource type=\"Texture2D\" "
            f"path=\"res://assets/runtime/biomes/paint/{definition['model']}_paint.png\" "
            "id=\"4_paint\"]"
        ),
        "",
        "[resource]",
        "script = ExtResource(\"1_species\")",
        "model = ExtResource(\"2_model\")",
        "material = ExtResource(\"3_material\")",
        "paint_texture = ExtResource(\"4_paint\")",
    ]
    skip = {
        "id",
        "model",
        "roughness",
        "specular",
        "texture_relief",
        "detail_scale",
        "detail_amount",
        "bump_scale",
        "bump_strength",
        "macro_scale",
        "macro_amount",
        "camera_rim_color",
        "camera_rim_energy",
    }
    aliases = {"id": "species_id"}
    species.append(f"species_id = {godot_value(definition['id'])}")
    for key, value in definition.items():
        if key in skip or key == "id":
            continue
        property_name = aliases.get(key, key)
        species.append(f"{property_name} = {godot_value(value)}")
    species.append("")
    path = SPECIES_DIR / f"{definition['id']}.tres"
    path.write_text("\n".join(species), encoding="utf-8", newline="\n")


def write_scene() -> None:
    scene = [
        "[gd_scene load_steps=5 format=3]",
        "",
        (
            "[ext_resource type=\"Script\" "
            "path=\"res://game/fauna/fauna_spawner.gd\" id=\"1_spawner\"]"
        ),
        (
            "[ext_resource type=\"Script\" "
            "path=\"res://game/fauna/fauna_species.gd\" "
            "id=\"2_species_script\"]"
        ),
    ]
    for index, definition in enumerate(SPECIES, start=3):
        scene.append(
            "[ext_resource type=\"Resource\" "
            f"path=\"res://game/fauna/species/{definition['id']}.tres\" "
            f"id=\"{index}_species\"]"
        )
    scene.extend([
        "",
        (
            "[node name=\"FaunaPopulations\" type=\"Node3D\"]"
        ),
        "script = ExtResource(\"1_spawner\")",
        (
            "species = Array[ExtResource(\"2_species_script\")](["
            + ", ".join(
                f"ExtResource(\"{index}_species\")"
                for index in range(3, len(SPECIES) + 3))
            + "])"
        ),
        # FaunaSpawner discovers its parent Planet and conventional
        # GlobalGrass/ColonyShip siblings. PackedScene NodePaths cannot retain
        # references outside this scene root; exports remain available for a
        # custom hierarchy.
        "survey_interval = 1.25",
        "initial_survey_delay = 1.5",
        "max_spawns_per_survey = 2",
        "candidate_limit_per_species = 128",
        "light_limit = 7",
        "lights_within = 95.0",
        "light_follow_speed = 9.0",
        "light_fade_speed = 5.0",
        "",
    ])
    SCENE_PATH.write_text("\n".join(scene), encoding="utf-8", newline="\n")


def main() -> None:
    SPECIES_DIR.mkdir(parents=True, exist_ok=True)
    MATERIAL_DIR.mkdir(parents=True, exist_ok=True)
    for definition in SPECIES:
        write_material(definition)
        write_species(definition)
    write_scene()
    print(
        f"Wrote {len(SPECIES)} fauna species, materials, and {SCENE_PATH}")


if __name__ == "__main__":
    main()
