#!/usr/bin/env python3
"""Unit tests for Scripts/validate_pixellab_raw.py.

Run from repo root:
    python3 -m unittest Scripts.test_validate_pixellab_raw
"""

import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from validate_pixellab_raw import (  # noqa: E402
    EXPECTED_FRAME_HEIGHT,
    EXPECTED_FRAME_WIDTH,
    EXPECTED_ROTATION_DIRECTIONS,
    validate,
)


def make_raw_zip(
    *,
    frame_size: tuple[int, int] = (EXPECTED_FRAME_WIDTH, EXPECTED_FRAME_HEIGHT),
    rotations: dict[str, str] | None = None,
    animations: dict[str, dict[str, list[str]]] | None = None,
    include_rotation_files: bool = True,
    include_animation_files: bool = True,
    skip_metadata: bool = False,
    bad_metadata_json: bool = False,
) -> Path:
    """Build a synthetic raw PixelLab-shaped zip for tests. Returns a
    temp file path the caller is responsible for cleaning up."""
    if rotations is None:
        rotations = {d: f"rotations/{d}.png" for d in EXPECTED_ROTATION_DIRECTIONS}

    meta = {
        "character": {
            "id": "test-id",
            "size": {"width": frame_size[0], "height": frame_size[1]},
            "directions": 8,
        },
        "frames": {
            "rotations": rotations,
            "animations": animations or {},
        },
        "export_version": "2.0",
    }

    f = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
    f.close()
    with zipfile.ZipFile(f.name, "w") as zf:
        if not skip_metadata:
            payload = "{not json" if bad_metadata_json else json.dumps(meta)
            zf.writestr("metadata.json", payload)
        if include_rotation_files:
            for path in rotations.values():
                zf.writestr(path, b"PNG-stub")
        if include_animation_files and animations:
            for slot in animations.values():
                if not isinstance(slot, dict):
                    continue
                for paths in slot.values():
                    if isinstance(paths, list):
                        for p in paths:
                            zf.writestr(p, b"PNG-stub")
    return Path(f.name)


def make_animation_slot(name: str, dirs: list[str], frame_count: int) -> tuple[str, dict[str, list[str]]]:
    """Helper: produce an `animation-<name>` slot keyed by directions →
    frame paths under animations/<name>/<dir>/frame_NNN.png."""
    key = f"animation-{name}"
    payload: dict[str, list[str]] = {}
    for d in dirs:
        payload[d] = [f"animations/{key}/{d}/frame_{i:03d}.png" for i in range(frame_count)]
    return key, payload


def codes(report) -> list[str]:
    return [f.code for f in report.findings]


def severities(report) -> dict[str, str]:
    return {f.code: f.severity for f in report.findings}


class ValidationHappyPathTests(unittest.TestCase):

    def test_full_v3_shape_passes_with_no_failures(self):
        walk_key, walk_slot = make_animation_slot(
            "walk-uuid",
            list(EXPECTED_ROTATION_DIRECTIONS),
            frame_count=8,
        )
        idle_key, idle_slot = make_animation_slot(
            "idle-uuid",
            list(EXPECTED_ROTATION_DIRECTIONS),
            frame_count=5,
        )
        path = make_raw_zip(animations={walk_key: walk_slot, idle_key: idle_slot})
        self.addCleanup(path.unlink, missing_ok=True)

        report = validate(path)
        self.assertFalse(report.has_failure, f"unexpected failures: {report.findings}")
        sevs = severities(report)
        self.assertEqual(sevs.get("frame-size"), "OK")
        self.assertEqual(sevs.get("rotations"), "OK")
        self.assertEqual(sevs.get("walk-idle-pair"), "OK")


class ValidationFrameSizeTests(unittest.TestCase):

    def test_48x48_fails_with_specific_suggestion(self):
        path = make_raw_zip(frame_size=(48, 48))
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        sevs = severities(report)
        self.assertEqual(sevs.get("frame-size-48"), "FAIL")
        # Suggestion mentions the 'HAPPY EXPRESSION' regen pitfall —
        # that's the most common cause per STATUS.md §0.3.
        finding = next(f for f in report.findings if f.code == "frame-size-48")
        self.assertIn("HAPPY EXPRESSION", finding.suggestion)

    def test_64x64_fails_as_generic_size_mismatch(self):
        path = make_raw_zip(frame_size=(64, 64))
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("frame-size-other"), "FAIL")


class ValidationRotationTests(unittest.TestCase):

    def test_missing_rotation_directions_fails(self):
        partial = {d: f"rotations/{d}.png" for d in ["south", "east"]}
        path = make_raw_zip(rotations=partial)
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("missing-rotations"), "FAIL")

    def test_metadata_references_missing_rotation_files(self):
        path = make_raw_zip(include_rotation_files=False)
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("missing-rotation-files"), "FAIL")


class ValidationAnimationTests(unittest.TestCase):

    def test_no_animations_warns_only(self):
        path = make_raw_zip(animations={})
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertFalse(report.has_failure)
        self.assertEqual(severities(report).get("no-animations"), "WARN")

    def test_duplicate_walk_slots_warn(self):
        k1, s1 = make_animation_slot("walk-a", list(EXPECTED_ROTATION_DIRECTIONS), 8)
        k2, s2 = make_animation_slot("walk-b", list(EXPECTED_ROTATION_DIRECTIONS), 8)
        path = make_raw_zip(animations={k1: s1, k2: s2})
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        sevs = severities(report)
        self.assertEqual(sevs.get("duplicate-walk"), "WARN")
        # And no FAIL — duplicates are operator-recoverable.
        self.assertFalse(report.has_failure)

    def test_walk_only_warns_about_missing_idle(self):
        k, s = make_animation_slot("walk-only", list(EXPECTED_ROTATION_DIRECTIONS), 8)
        path = make_raw_zip(animations={k: s})
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertFalse(report.has_failure)
        self.assertEqual(severities(report).get("walk-only"), "WARN")

    def test_idle_only_warns_about_missing_walk(self):
        k, s = make_animation_slot("idle-only", list(EXPECTED_ROTATION_DIRECTIONS), 4)
        path = make_raw_zip(animations={k: s})
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertFalse(report.has_failure)
        self.assertEqual(severities(report).get("idle-only"), "WARN")

    def test_animation_slot_partial_dirs_warns_but_doesnt_fail(self):
        # Per dd1a7ba C1 fix the runtime falls back to rotation PNG for
        # missing directions, so partial coverage is acceptable. Validator
        # surfaces it as a hint, not a blocker.
        k, s = make_animation_slot("walk-partial", ["south"], 8)
        path = make_raw_zip(animations={k: s})
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertFalse(report.has_failure)
        self.assertEqual(severities(report).get("slot-missing-dirs"), "WARN")

    def test_missing_frame_files_fails(self):
        k, s = make_animation_slot("walk", list(EXPECTED_ROTATION_DIRECTIONS), 8)
        path = make_raw_zip(animations={k: s}, include_animation_files=False)
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("missing-frame-files"), "FAIL")


class ValidationCorruptInputTests(unittest.TestCase):

    def test_missing_metadata_fails(self):
        path = make_raw_zip(skip_metadata=True)
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("no-metadata"), "FAIL")

    def test_bad_metadata_json_fails(self):
        path = make_raw_zip(bad_metadata_json=True)
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("bad-metadata"), "FAIL")

    def test_not_a_zip_fails(self):
        f = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
        f.write(b"this is plain text, not a zip")
        f.close()
        path = Path(f.name)
        self.addCleanup(path.unlink, missing_ok=True)
        report = validate(path)
        self.assertTrue(report.has_failure)
        self.assertEqual(severities(report).get("bad-zip"), "FAIL")


if __name__ == "__main__":
    unittest.main()
