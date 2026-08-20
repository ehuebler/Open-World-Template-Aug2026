"""Read a boss manifest's asset and animation contract for Blender recipes.

This module deliberately uses only Python's standard library so Blender can
load it directly with the same sibling-module helper as the asset recipes.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
MANIFEST_DIR = ROOT / "assets" / "runtime" / "bosses" / "manifests"
ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")


class BossManifestError(ValueError):
    """Raised when a Blender recipe disagrees with its authored manifest."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise BossManifestError("duplicate JSON key: {!r}".format(key))
        result[key] = value
    return result


def _read_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_object,
        )
    except FileNotFoundError as exc:
        raise BossManifestError(
            "boss manifest is missing: " + path.as_posix()) from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise BossManifestError(
            "cannot read boss manifest {}: {}".format(
                path.as_posix(), exc)) from exc
    if not isinstance(value, dict):
        raise BossManifestError("boss manifest root must be an object")
    return value


def _resource_path(
    path: str | os.PathLike[str],
    label: str,
) -> str:
    candidate = Path(path).resolve()
    try:
        relative = candidate.relative_to(ROOT)
    except ValueError as exc:
        raise BossManifestError(
            "{} must be inside the project: {}".format(
                label, candidate)) from exc
    return "res://" + relative.as_posix()


def _required_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BossManifestError(label + " must be a non-empty string")
    return value


def _asset_contract(
    data: dict[str, Any],
    *,
    boss_id: str,
    recipe_path: str | os.PathLike[str],
    source_path: str | os.PathLike[str],
    runtime_path: str | os.PathLike[str],
) -> None:
    asset = data.get("asset")
    if not isinstance(asset, dict):
        raise BossManifestError(boss_id + ".asset must be an object")
    expected = {
        "builder": _resource_path(recipe_path, "recipe path"),
        "source": _resource_path(source_path, "source path"),
        "runtime_glb": _resource_path(runtime_path, "runtime path"),
    }
    for field, expected_path in expected.items():
        authored = _required_string(
            asset.get(field), "{}.asset.{}".format(boss_id, field))
        if authored != expected_path:
            raise BossManifestError(
                "{}.asset.{} is {!r}; recipe uses {!r}".format(
                    boss_id, field, authored, expected_path))


def _animation_contract(data: dict[str, Any], boss_id: str) -> tuple[str, ...]:
    animations = data.get("animations")
    if not isinstance(animations, dict) or not animations:
        raise BossManifestError(
            boss_id + ".animations must be a non-empty object")
    clips: list[str] = []
    seen: set[str] = set()
    for role, mapping in animations.items():
        label = "{}.animations.{}".format(boss_id, role)
        if isinstance(mapping, str):
            values = [(label, mapping)]
        elif isinstance(mapping, dict) and mapping:
            values = [
                ("{}.{}".format(label, subrole), clip)
                for subrole, clip in mapping.items()
            ]
        else:
            raise BossManifestError(
                label + " must be a clip or non-empty stage object")
        for clip_label, value in values:
            clip = _required_string(value, clip_label)
            if clip not in seen:
                seen.add(clip)
                clips.append(clip)
    return tuple(clips)


def _validate_move_clips(
    data: dict[str, Any],
    boss_id: str,
    required: tuple[str, ...],
) -> None:
    moves = data.get("moves")
    if not isinstance(moves, list):
        raise BossManifestError(boss_id + ".moves must be an array")
    known = set(required)
    for move_index, move in enumerate(moves):
        move_label = "{}.moves[{}]".format(boss_id, move_index)
        if not isinstance(move, dict):
            raise BossManifestError(move_label + " must be an object")
        move_id = _required_string(move.get("id"), move_label + ".id")
        animations = move.get("animations")
        if not isinstance(animations, dict) or not animations:
            raise BossManifestError(
                move_label + ".animations must be a non-empty object")
        for stage, value in animations.items():
            clip = _required_string(
                value, "{}.animations.{}".format(move_label, stage))
            if clip not in known:
                raise BossManifestError(
                    "{} move {!r} uses animation {!r} outside the contract"
                    .format(boss_id, move_id, clip))


def required_clips(
    boss_id: str,
    *,
    recipe_path: str | os.PathLike[str],
    source_path: str | os.PathLike[str],
    runtime_path: str | os.PathLike[str],
) -> tuple[str, ...]:
    """Return unique authored clips in manifest order for one asset recipe."""
    if not isinstance(boss_id, str) or not ID_RE.fullmatch(boss_id):
        raise BossManifestError("invalid boss id: {!r}".format(boss_id))
    path = MANIFEST_DIR / (boss_id + ".json")
    data = _read_manifest(path)
    version = data.get("version")
    if isinstance(version, bool) or version != 1:
        raise BossManifestError(
            "{}: version must be 1".format(path.as_posix()))
    authored_id = data.get("id")
    if authored_id != boss_id:
        raise BossManifestError(
            "{}: id {!r} does not match {!r}".format(
                path.as_posix(), authored_id, boss_id))
    _asset_contract(
        data,
        boss_id=boss_id,
        recipe_path=recipe_path,
        source_path=source_path,
        runtime_path=runtime_path,
    )
    clips = _animation_contract(data, boss_id)
    _validate_move_clips(data, boss_id, clips)
    return clips
