#!/usr/bin/env python3
"""Normalize a raw PixelLab character export into the v3.0 schema PeerDrop's
SpriteMetadata Swift parser consumes.

Used by Scripts/normalize-pixellab-zip.sh as the import target. Importable
from tests for unit-test coverage of the rename + dedup + schema-bump logic.

See docs/plans/2026-05-08-v5-multi-frame-sprite-design.md §2 for the full
design context. Mirror constants live in AssetSpec.swift (Swift side) —
the heuristic threshold (>=6 frames = walk) MUST match between the two.
"""

import json
import os
import shutil
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# Mirror of AssetSpec.swift values. Update both together.
WALK_FPS = 6
WALK_LOOPS = True
IDLE_FPS = 2
IDLE_LOOPS = True
HEURISTIC_WALK_MIN_FRAMES = 6  # >= = walk; < = idle
NORMALIZED_SCHEMA_VERSION = "3.0"


@dataclass
class NormalizationReport:
    """Outcome of a normalization pass — useful for tests + operator log."""
    walk_kept: Optional[str] = None
    walk_dropped: list[str] = field(default_factory=list)
    idle_kept: Optional[str] = None
    idle_dropped: list[str] = field(default_factory=list)
    final_actions: list[str] = field(default_factory=list)


def first_dir_count(anim_dict: dict) -> int:
    """Frames per direction (sample first direction's array length)."""
    for _, frame_list in anim_dict.items():
        return len(frame_list)
    return 0


def total_frames(anim_dict: dict) -> int:
    return sum(len(v) for v in anim_dict.values())


def heuristic_action(anim_dict: dict) -> str:
    """Map an animation slot to "walk" or "idle" based on per-direction frame
    count. >=6 → walk; <6 → idle. Tuned for PixelLab presets:
        Walk (4/6/8): 6 + 8 → walk; 4 → idle
        Idle, Breathing Idle, Sad Idle: 4-5 → idle
    """
    return "walk" if first_dir_count(anim_dict) >= HEURISTIC_WALK_MIN_FRAMES else "idle"


def dir_mtime(extracted_root: Path, key: str) -> float:
    """Latest mtime of any file under animations/{key}/.

    Returns 0 if the directory doesn't exist on disk (defensive — shouldn't
    happen for a valid PixelLab export but tests use synthetic fixtures
    without on-disk content). Used as the primary tiebreaker when an
    operator accidentally creates duplicate slots: latest mtime wins
    (= operator's most recent intent).
    """
    d = extracted_root / "animations" / key
    if not d.is_dir():
        return 0.0
    latest = 0.0
    for path in d.rglob("*"):
        if path.is_file():
            try:
                mt = path.stat().st_mtime
                if mt > latest:
                    latest = mt
            except OSError:
                pass
    return latest


def pick_winner(
    candidates: list[str],
    animations: dict,
    extracted_root: Path,
) -> tuple[Optional[str], list[str]]:
    """Among same-action slots, pick the one most likely to be the operator's
    intent. Sort by (mtime DESC, total_frames DESC, key DESC) — newest mtime
    wins; ties broken by frame count, then alphabetically for determinism.
    """
    if not candidates:
        return None, []
    if len(candidates) == 1:
        return candidates[0], []
    sorted_keys = sorted(
        candidates,
        key=lambda k: (dir_mtime(extracted_root, k), total_frames(animations[k]), k),
        reverse=True,
    )
    return sorted_keys[0], sorted_keys[1:]


def merge_same_action_directions(
    keep: str,
    drop_keys: list[str],
    animations: dict,
    extracted_root: Path,
) -> None:
    """When multiple slots map to the same action, merge non-conflicting
    directions from the dropped slots into the kept one. Conflicts (same
    direction in both) keep the kept slot's frames.

    Mutates `animations` in place; mutates the on-disk extracted tree.
    """
    for drop in drop_keys:
        for direction, paths in animations.get(drop, {}).items():
            if direction in animations[keep]:
                continue  # conflict — kept slot wins
            old_dir = extracted_root / "animations" / drop / direction
            new_dir = extracted_root / "animations" / keep / direction
            if old_dir.is_dir():
                new_dir.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(old_dir), str(new_dir))
            new_paths = [p.replace(f"animations/{drop}/", f"animations/{keep}/")
                         for p in paths]
            animations[keep][direction] = new_paths


def normalize_metadata(
    extracted_root: Path,
    *,
    merge_dirs_across_slots: bool = False,
) -> NormalizationReport:
    """Mutate metadata.json + on-disk animation directories in place.

    The extracted_root should contain `metadata.json` and an `animations/`
    subdirectory (typical PixelLab export shape). After this function:
      - frames.animations keys are normalized to "walk" / "idle"
      - Each entry has fps / frame_count / loops / directions wrapping
      - export_version bumped to NORMALIZED_SCHEMA_VERSION
      - v5_compatible: true added
      - Orphan duplicate slots renamed/cleaned on disk
      - With merge_dirs_across_slots=True, non-conflicting directions
        from same-action duplicate slots are merged into the kept slot.
    """
    meta_path = extracted_root / "metadata.json"
    with meta_path.open() as f:
        meta = json.load(f)

    frames = meta.get("frames", {})
    animations = frames.get("animations", {})
    if not animations:
        raise ValueError("no frames.animations in metadata")

    uuid_keys = list(animations.keys())
    walk_candidates = [k for k in uuid_keys if heuristic_action(animations[k]) == "walk"]
    idle_candidates = [k for k in uuid_keys if heuristic_action(animations[k]) == "idle"]

    walk_keep, walk_drops = pick_winner(walk_candidates, animations, extracted_root)
    idle_keep, idle_drops = pick_winner(idle_candidates, animations, extracted_root)

    report = NormalizationReport(
        walk_kept=walk_keep,
        walk_dropped=walk_drops,
        idle_kept=idle_keep,
        idle_dropped=idle_drops,
    )

    if merge_dirs_across_slots:
        if walk_keep:
            merge_same_action_directions(walk_keep, walk_drops, animations, extracted_root)
        if idle_keep:
            merge_same_action_directions(idle_keep, idle_drops, animations, extracted_root)

    assignments = []
    if walk_keep:
        assignments.append((walk_keep, "walk"))
    if idle_keep:
        assignments.append((idle_keep, "idle"))
    if not assignments:
        raise ValueError("no animations after filtering")

    # Defaults per action (mirrors AssetSpec.swift)
    defaults = {
        "walk": {"fps": WALK_FPS, "loops": WALK_LOOPS},
        "idle": {"fps": IDLE_FPS, "loops": IDLE_LOOPS},
    }

    # Drop dropped-orphan directories on disk
    dropped_keys = set(walk_drops) | set(idle_drops)
    for k in dropped_keys:
        orphan_dir = extracted_root / "animations" / k
        if orphan_dir.is_dir():
            shutil.rmtree(orphan_dir)

    # Build new normalized animations block + rename on-disk dirs
    new_animations = {}
    for key, action in assignments:
        old_dir = extracted_root / "animations" / key
        new_dir = extracted_root / "animations" / action
        if old_dir.is_dir():
            if new_dir.exists():
                raise ValueError(f"target dir already exists: {new_dir}")
            shutil.move(str(old_dir), str(new_dir))

        new_directions = {}
        for direction, paths in animations[key].items():
            new_paths = [p.replace(f"animations/{key}/", f"animations/{action}/")
                         for p in paths]
            new_directions[direction] = new_paths

        fc = first_dir_count(animations[key])
        new_animations[action] = {
            "fps": defaults[action]["fps"],
            "frame_count": fc,
            "loops": defaults[action]["loops"],
            "directions": new_directions,
        }

    frames["animations"] = new_animations
    meta["frames"] = frames
    meta["export_version"] = NORMALIZED_SCHEMA_VERSION
    meta["v5_compatible"] = True

    with meta_path.open("w") as f:
        json.dump(meta, f, indent=2)

    report.final_actions = [a for _, a in assignments]
    return report


def normalize_zip(
    raw_zip_path: Path,
    output_zip_path: Path,
    *,
    merge_dirs_across_slots: bool = False,
) -> NormalizationReport:
    """High-level entry: unzip → normalize → re-zip → return report."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        with zipfile.ZipFile(raw_zip_path) as zf:
            zf.extractall(tmp_path)
        report = normalize_metadata(tmp_path, merge_dirs_across_slots=merge_dirs_across_slots)

        if output_zip_path.exists():
            output_zip_path.unlink()
        with zipfile.ZipFile(output_zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for path in tmp_path.rglob("*"):
                if path.is_file():
                    zf.write(path, arcname=path.relative_to(tmp_path))
        return report


def main(argv: list[str]) -> int:
    """CLI entry. Compatible with Scripts/normalize-pixellab-zip.sh wrapper."""
    if len(argv) != 3:
        print(f"Usage: {argv[0]} <raw-export.zip> <output-normalized.zip>",
              file=__import__("sys").stderr)
        return 2

    raw = Path(argv[1])
    out = Path(argv[2])
    if not raw.is_file():
        print(f"Error: raw zip not found: {raw}", file=__import__("sys").stderr)
        return 1

    try:
        report = normalize_zip(raw, out, merge_dirs_across_slots=True)
    except ValueError as e:
        print(f"Error: {e}", file=__import__("sys").stderr)
        return 1

    summary = []
    if report.walk_kept:
        summary.append(f"{report.walk_kept[:18]}->walk")
    if report.idle_kept:
        summary.append(f"{report.idle_kept[:18]}->idle")
    print(f"Normalized: {', '.join(summary)}")

    # Loud report when slots were dropped (operator visibility)
    import sys
    for label, kept, drops in [
        ("walk", report.walk_kept, report.walk_dropped),
        ("idle", report.idle_kept, report.idle_dropped),
    ]:
        if drops:
            print(f"Warning: {len(drops) + 1} {label} slots found, kept '{kept[:18]}', "
                  f"dropped {[k[:18] for k in drops]}",
                  file=sys.stderr)

    print(f"Wrote: {out}")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv))
