#!/usr/bin/env python3
"""Unit tests for Scripts/normalize_pixellab.py.

Run from repo root:
    python3 -m unittest Scripts.test_normalize_pixellab
or:
    cd Scripts && python3 -m unittest test_normalize_pixellab

Mass-gen sprint hits the normalize logic 100s of times across many
operator workflows. These tests pin the behavior so schema-shift bugs
get caught at dev time, not 30 zips into a tired Saturday.
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

# Add Scripts to path for direct import (Scripts isn't a package)
sys.path.insert(0, str(Path(__file__).parent))

from normalize_pixellab import (  # noqa: E402
    NormalizationReport,
    HEURISTIC_WALK_MIN_FRAMES,
    NORMALIZED_SCHEMA_VERSION,
    WALK_FPS,
    IDLE_FPS,
    first_dir_count,
    heuristic_action,
    normalize_metadata,
    pick_winner,
)


def make_metadata(
    *,
    animations: dict,
    rotations: dict | None = None,
    size: tuple[int, int] = (68, 68),
) -> dict:
    """Helper: build a v2.0 PixelLab-shape metadata.json structure."""
    return {
        "character": {
            "id": "test-id",
            "name": "test character",
            "size": {"width": size[0], "height": size[1]},
            "directions": 8,
            "view": "side",
        },
        "frames": {
            "rotations": rotations or {"south": "rotations/south.png"},
            "animations": animations,
        },
        "export_version": "2.0",
        "export_date": "2026-05-09T00:00:00",
    }


def write_metadata(root: Path, meta: dict) -> None:
    (root / "metadata.json").write_text(json.dumps(meta))


def touch_file(path: Path, mtime: float | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


class HeuristicTests(unittest.TestCase):
    def test_8_frames_classifies_as_walk(self):
        anim = {"south": ["a"] * 8}
        self.assertEqual(heuristic_action(anim), "walk")

    def test_5_frames_classifies_as_idle(self):
        anim = {"south": ["a"] * 5}
        self.assertEqual(heuristic_action(anim), "idle")

    def test_threshold_boundary_6_frames_is_walk(self):
        # = HEURISTIC_WALK_MIN_FRAMES → walk (inclusive)
        anim = {"south": ["a"] * HEURISTIC_WALK_MIN_FRAMES}
        self.assertEqual(heuristic_action(anim), "walk")

    def test_threshold_boundary_5_frames_is_idle(self):
        anim = {"south": ["a"] * (HEURISTIC_WALK_MIN_FRAMES - 1)}
        self.assertEqual(heuristic_action(anim), "idle")


class FirstDirCountTests(unittest.TestCase):
    def test_returns_count_of_first_direction(self):
        anim = {"south": ["a", "b", "c"], "east": ["d", "e"]}
        # Implementation samples first direction (insertion-ordered dict)
        self.assertEqual(first_dir_count(anim), 3)

    def test_empty_anim_returns_zero(self):
        self.assertEqual(first_dir_count({}), 0)


class PickWinnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_single_candidate_returns_itself_no_drops(self):
        anims = {"a": {"south": ["1"] * 8}}
        keep, drops = pick_winner(["a"], anims, self.tmp)
        self.assertEqual(keep, "a")
        self.assertEqual(drops, [])

    def test_no_candidates_returns_none(self):
        keep, drops = pick_winner([], {}, self.tmp)
        self.assertIsNone(keep)
        self.assertEqual(drops, [])

    def test_newer_mtime_wins_over_more_frames(self):
        # Operator scenario: 8-frame walk generated first (older), then
        # partial 4-frame regen (newer). Newer mtime should win even with
        # fewer frames — captures "operator's latest intent".
        old_dir = self.tmp / "animations" / "old-uuid" / "south"
        new_dir = self.tmp / "animations" / "new-uuid" / "south"
        for i in range(8):
            touch_file(old_dir / f"frame_{i:03d}.png", mtime=1000.0)
        for i in range(4):
            touch_file(new_dir / f"frame_{i:03d}.png", mtime=2000.0)

        anims = {
            "old-uuid": {"south": [f"animations/old-uuid/south/frame_{i:03d}.png" for i in range(8)]},
            "new-uuid": {"south": [f"animations/new-uuid/south/frame_{i:03d}.png" for i in range(4)]},
        }
        keep, drops = pick_winner(["old-uuid", "new-uuid"], anims, self.tmp)
        self.assertEqual(keep, "new-uuid", "newer mtime should win")
        self.assertEqual(drops, ["old-uuid"])

    def test_same_mtime_more_frames_wins(self):
        for k, count in [("a", 8), ("b", 16)]:
            for i in range(count):
                touch_file(self.tmp / "animations" / k / "south" / f"f_{i}.png", mtime=1000.0)
        anims = {
            "a": {"south": [f"animations/a/south/f_{i}.png" for i in range(8)]},
            "b": {"south": [f"animations/b/south/f_{i}.png" for i in range(16)]},
        }
        keep, drops = pick_winner(["a", "b"], anims, self.tmp)
        self.assertEqual(keep, "b", "more frames wins on mtime tie")


class NormalizeMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _setup(self, meta: dict, animation_files: dict[str, list[str]] | None = None):
        """animation_files: {uuid: [direction names with N frames each]}.

        Creates synthetic frame files so dir_mtime works.
        """
        write_metadata(self.tmp, meta)
        for uuid, dirs in (animation_files or {}).items():
            for direction in dirs:
                anim = meta["frames"]["animations"].get(uuid, {})
                count = len(anim.get(direction, []))
                for i in range(count):
                    touch_file(self.tmp / "animations" / uuid / direction / f"frame_{i:03d}.png")

    def test_single_walk_slot_normalizes_correctly(self):
        meta = make_metadata(animations={
            "uuid-walk": {"south": [f"animations/uuid-walk/south/frame_{i:03d}.png" for i in range(8)]},
        })
        self._setup(meta, animation_files={"uuid-walk": ["south"]})

        report = normalize_metadata(self.tmp)

        self.assertEqual(report.final_actions, ["walk"])
        self.assertIsNone(report.idle_kept)

        with (self.tmp / "metadata.json").open() as f:
            updated = json.load(f)
        self.assertEqual(updated["export_version"], NORMALIZED_SCHEMA_VERSION)
        self.assertTrue(updated.get("v5_compatible"))
        self.assertEqual(updated["frames"]["animations"]["walk"]["fps"], WALK_FPS)
        self.assertEqual(updated["frames"]["animations"]["walk"]["frame_count"], 8)

    def test_walk_plus_idle_slots_normalize_correctly(self):
        meta = make_metadata(animations={
            "Walking-abc": {"south": [f"animations/Walking-abc/south/frame_{i:03d}.png" for i in range(8)]},
            "Breathing_Idle-def": {"south": [f"animations/Breathing_Idle-def/south/frame_{i:03d}.png" for i in range(4)]},
        })
        self._setup(meta, animation_files={
            "Walking-abc": ["south"],
            "Breathing_Idle-def": ["south"],
        })

        report = normalize_metadata(self.tmp)

        self.assertIn("walk", report.final_actions)
        self.assertIn("idle", report.final_actions)
        self.assertEqual(report.walk_kept, "Walking-abc")
        self.assertEqual(report.idle_kept, "Breathing_Idle-def")

        with (self.tmp / "metadata.json").open() as f:
            updated = json.load(f)
        self.assertEqual(updated["frames"]["animations"]["walk"]["frame_count"], 8)
        self.assertEqual(updated["frames"]["animations"]["idle"]["frame_count"], 4)
        self.assertEqual(updated["frames"]["animations"]["idle"]["fps"], IDLE_FPS)

    def test_capitalized_prefix_uuid_handled(self):
        # PixelLab Humanoid template uses "Walking-{uuid}" prefix, not just
        # "animation-{uuid}". Heuristic + rename must work for both.
        meta = make_metadata(animations={
            "Walking-95ac3e3b": {"south": [f"animations/Walking-95ac3e3b/south/frame_{i:03d}.png" for i in range(8)]},
        })
        self._setup(meta, animation_files={"Walking-95ac3e3b": ["south"]})

        report = normalize_metadata(self.tmp)

        self.assertEqual(report.walk_kept, "Walking-95ac3e3b")
        # Verify renamed dir actually exists on disk
        self.assertTrue((self.tmp / "animations" / "walk" / "south").is_dir())
        self.assertFalse((self.tmp / "animations" / "Walking-95ac3e3b").exists())

    def test_two_walk_slots_dedups_keeping_newer(self):
        # Operator scenario: existing walk slot with 16 frames (older), new
        # walk regen with 8 frames (newer). Newer wins via mtime.
        old_uuid = "old-walk-uuid"
        new_uuid = "new-walk-uuid"
        meta = make_metadata(animations={
            old_uuid: {"south": [f"animations/{old_uuid}/south/frame_{i:03d}.png" for i in range(8)],
                       "east": [f"animations/{old_uuid}/east/frame_{i:03d}.png" for i in range(8)]},
            new_uuid: {"south": [f"animations/{new_uuid}/south/frame_{i:03d}.png" for i in range(8)]},
        })
        # Touch old files at older mtime, new at newer mtime
        for direction in ["south", "east"]:
            for i in range(8):
                touch_file(self.tmp / "animations" / old_uuid / direction / f"frame_{i:03d}.png", mtime=1000.0)
        for i in range(8):
            touch_file(self.tmp / "animations" / new_uuid / "south" / f"frame_{i:03d}.png", mtime=2000.0)

        # Set up metadata file
        write_metadata(self.tmp, meta)

        report = normalize_metadata(self.tmp)

        self.assertEqual(report.walk_kept, new_uuid, "newer mtime wins")
        self.assertEqual(report.walk_dropped, [old_uuid])

    def test_orphan_drop_directory_removed_from_disk(self):
        keep_uuid = "keep-walk"
        drop_uuid = "drop-walk"
        meta = make_metadata(animations={
            keep_uuid: {"south": [f"animations/{keep_uuid}/south/frame_{i:03d}.png" for i in range(8)]},
            drop_uuid: {"south": [f"animations/{drop_uuid}/south/frame_{i:03d}.png" for i in range(8)]},
        })
        for i in range(8):
            touch_file(self.tmp / "animations" / keep_uuid / "south" / f"frame_{i:03d}.png", mtime=2000.0)
            touch_file(self.tmp / "animations" / drop_uuid / "south" / f"frame_{i:03d}.png", mtime=1000.0)
        write_metadata(self.tmp, meta)

        normalize_metadata(self.tmp)

        # Drop dir should be cleaned from disk; keep dir renamed to "walk"
        self.assertFalse((self.tmp / "animations" / drop_uuid).exists())
        self.assertTrue((self.tmp / "animations" / "walk" / "south").is_dir())

    def test_no_animations_raises(self):
        meta = make_metadata(animations={})
        write_metadata(self.tmp, meta)
        with self.assertRaises(ValueError):
            normalize_metadata(self.tmp)

    def test_merge_mode_combines_non_conflicting_directions(self):
        # Operator scenario: walk fragments across two slots — south in one,
        # east in another. With merge_dirs_across_slots=True, they merge
        # rather than dropping one slot's data.
        slot_a = "slot-a"
        slot_b = "slot-b"
        meta = make_metadata(animations={
            slot_a: {"south": [f"animations/{slot_a}/south/frame_{i:03d}.png" for i in range(8)]},
            slot_b: {"east": [f"animations/{slot_b}/east/frame_{i:03d}.png" for i in range(8)]},
        })
        for i in range(8):
            touch_file(self.tmp / "animations" / slot_a / "south" / f"frame_{i:03d}.png", mtime=2000.0)
            touch_file(self.tmp / "animations" / slot_b / "east" / f"frame_{i:03d}.png", mtime=1000.0)
        write_metadata(self.tmp, meta)

        report = normalize_metadata(self.tmp, merge_dirs_across_slots=True)

        self.assertEqual(report.walk_kept, slot_a)  # newer mtime
        # After merge, the kept slot should have BOTH directions
        with (self.tmp / "metadata.json").open() as f:
            updated = json.load(f)
        walk_dirs = updated["frames"]["animations"]["walk"]["directions"]
        self.assertIn("south", walk_dirs)
        self.assertIn("east", walk_dirs)


if __name__ == "__main__":
    unittest.main()
