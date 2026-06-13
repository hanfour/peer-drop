#!/usr/bin/env python3
"""Unit tests for Scripts/gen_pixellab_zip.py.

Uses a hand-written fake PixelLab client (no API calls, no network)
to validate the orchestrator's contract:
  - Right number of API calls per direction
  - Output zip has the expected PixelLab-shape
  - Skipping a direction degrades gracefully (rest still render)
  - Empty-skeleton response surfaces in the report

Run from repo root:
    python3 -m unittest Scripts.test_gen_pixellab_zip
"""

import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from PIL import Image


def _png(seed: int, size: int = 68) -> bytes:
    """A real decodable PNG — generate() now resizes source rotations via
    Pillow before the API calls, so fixtures must be real images, not tags."""
    buf = io.BytesIO()
    Image.new("RGBA", (size, size), (seed % 255, (seed * 7) % 255, 0, 255)).save(buf, "PNG")
    return buf.getvalue()

sys.path.insert(0, str(Path(__file__).parent))

from gen_pixellab_zip import (  # noqa: E402
    ACTIONS,
    DIRECTIONS,
    GenReport,
    build_raw_zip,
    extract_rotations,
    generate,
    render_direction,
)
from pixellab_client import Keypoint as ClientKeypoint  # noqa: E402


# ─── Fake client ───────────────────────────────────────────────────────


class FakeClient:
    """Mimics `PixelLabClient` over an in-memory contract.

    estimate_skeleton: returns a fixed 4-keypoint skeleton.
    animate_with_skeleton: returns PNG-shaped bytes with a debug label.

    `direction_skeletons` lets a test override the estimator return for
    a specific direction (e.g. simulate empty skeleton → skip).
    """
    def __init__(
        self,
        *,
        empty_skeleton_for: tuple[str, ...] = (),
    ):
        self.empty_skeleton_for = set(empty_skeleton_for)
        self.estimate_calls: list[tuple[bytes, tuple[int, int]]] = []
        self.animate_calls: list[dict] = []

    def estimate_skeleton(self, *, image_bytes, image_size):
        self.estimate_calls.append((image_bytes, image_size))
        # The fake doesn't know which direction it's serving — use a
        # heuristic: if any "empty_for" direction tag is encoded in the
        # PNG bytes, return empty. Tests pass tagged bytes for this.
        for direction in self.empty_skeleton_for:
            if direction.encode() in image_bytes:
                return []
        # Default: simple quadruped-ish 4-keypoint skeleton.
        return [
            ClientKeypoint(x=34, y=20, label="head"),
            ClientKeypoint(x=34, y=32, label="torso"),
            ClientKeypoint(x=30, y=44, label="left_front_paw"),
            ClientKeypoint(x=38, y=44, label="right_front_paw"),
        ]

    def animate_with_skeleton(
        self,
        *,
        reference_image_bytes,
        image_size,
        skeleton_frames,
        view="side",
        direction="east",
        guidance_scale=4.0,
        seed=None,
    ) -> list[bytes]:
        self.animate_calls.append({
            "direction": direction,
            "frame_count": len(skeleton_frames),
            "kp_count": len(skeleton_frames[0]) if skeleton_frames else 0,
            "ref_len": len(reference_image_bytes),
        })
        # Return one PNG per frame with distinct bytes so the assembled
        # zip can verify ordering.
        return [
            b"\x89PNG\r\n\x1a\n" + f"frame:{direction}:{seed}:{i}:{len(frame)}".encode()
            for i, frame in enumerate(skeleton_frames)
        ]


# ─── Helpers ───────────────────────────────────────────────────────────


def make_source_zip(tmp: Path, name: str, dir_pngs: dict[str, bytes]) -> Path:
    """Build a v4-shape source zip with the supplied rotation PNGs +
    a minimal metadata.json. Used in place of the real bundled zips so
    tests don't depend on the production assets."""
    src = tmp / f"{name}.zip"
    meta = {
        "character": {"id": "test", "size": {"width": 68, "height": 68}, "directions": 8},
        "frames": {"rotations": {d: f"rotations/{d}.png" for d in dir_pngs}},
        "export_version": "2.0",
    }
    with zipfile.ZipFile(src, "w") as zf:
        zf.writestr("metadata.json", json.dumps(meta))
        for d, png in dir_pngs.items():
            zf.writestr(f"rotations/{d}.png", png)
    return src


# ─── extract_rotations ─────────────────────────────────────────────────


class ExtractRotationsTests(unittest.TestCase):

    def test_returns_only_present_directions(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src = make_source_zip(tmp, "x", {
                "south": b"south-bytes",
                "east": b"east-bytes",
            })
            result = extract_rotations(src)
            self.assertEqual(set(result.keys()), {"south", "east"})
            self.assertEqual(result["south"], b"south-bytes")

    def test_returns_all_8_when_present(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src = make_source_zip(tmp, "x", {d: d.encode() for d in DIRECTIONS})
            result = extract_rotations(src)
            self.assertEqual(set(result.keys()), set(DIRECTIONS))


# ─── render_direction ──────────────────────────────────────────────────


class RenderDirectionTests(unittest.TestCase):

    def test_emits_walk_and_idle_batches(self):
        report = GenReport(species_stage="test", output_path=Path("/tmp/x"))
        client = FakeClient()
        result = render_direction(
            client=client, direction="south",
            rotation_png=b"south-bytes", image_size=(68, 68), report=report,
        )
        # /animate-with-skeleton renders EXACTLY 3 poses per call, so the
        # 8-frame walk / 5-frame idle cycles are chained over ceil(N/3)
        # batches (3+3+2 walk, 3+2 idle) with the padded extras trimmed.
        self.assertEqual(len(result["walk"]), 8)
        self.assertEqual(len(result["idle"]), 5)
        # 1 estimate + 3 walk batches + 2 idle batches = 6 API calls
        self.assertEqual(report.api_calls, 6)
        self.assertEqual(report.frames_written, 13)

    def test_empty_skeleton_skips_direction(self):
        report = GenReport(species_stage="test", output_path=Path("/tmp/x"))
        client = FakeClient(empty_skeleton_for=("south",))
        # The fake matches on bytes containing the direction string.
        result = render_direction(
            client=client, direction="south",
            rotation_png=b"south-tagged", image_size=(68, 68), report=report,
        )
        self.assertEqual(result, {})
        self.assertEqual(report.api_calls, 1)  # estimate only
        self.assertIn("south", report.skipped_directions)
        self.assertTrue(any("south" in e for e in report.errors))


# ─── build_raw_zip ─────────────────────────────────────────────────────


class BuildRawZipTests(unittest.TestCase):

    def test_zip_has_metadata_and_rotation_files(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            out = tmp / "out.zip"
            rotations = {d: d.encode() for d in DIRECTIONS}
            rendered = {
                d: {
                    "walk": [(i, f"w-{d}-{i}".encode()) for i in range(3)],
                    "idle": [(i, f"i-{d}-{i}".encode()) for i in range(3)],
                }
                for d in DIRECTIONS
            }
            build_raw_zip(out, rotations, rendered, image_size=(68, 68))

            with zipfile.ZipFile(out, "r") as zf:
                names = set(zf.namelist())
                self.assertIn("metadata.json", names)
                for d in DIRECTIONS:
                    self.assertIn(f"rotations/{d}.png", names)

                meta = json.loads(zf.read("metadata.json").decode("utf-8"))
                self.assertEqual(meta["character"]["size"], {"width": 68, "height": 68})
                self.assertEqual(meta["export_version"], "2.0")

                # 8 rotations + 8 dirs × (3 walk + 3 idle) = 8 + 48 = 56 PNGs
                png_count = sum(1 for n in names if n.endswith(".png"))
                self.assertEqual(png_count, 56)

                # Raw v2.0 schema: animation slots are UUID-keyed
                # (animation-xxxx); normalize renames them to walk/idle later.
                # Each slot carries an `_action` marker (added so normalize
                # classifies walk vs idle deterministically instead of guessing
                # by frame count — commit bff863b) plus all 8 directions.
                anims = meta["frames"]["animations"]
                self.assertEqual(len(anims), 2)  # walk + idle
                actions_seen = set()
                for slot in anims.values():
                    self.assertIn(slot.get("_action"), {"walk", "idle"})
                    actions_seen.add(slot["_action"])
                    self.assertEqual(set(slot.keys()) - {"_action"}, set(DIRECTIONS))
                self.assertEqual(actions_seen, {"walk", "idle"})


# ─── generate (top-level) ──────────────────────────────────────────────


class GenerateTests(unittest.TestCase):

    def test_full_flow_with_all_8_directions(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            # Make a synthetic source zip in a temp Pets dir.
            src = make_source_zip(tmp, "test-species-stage",
                                   {d: _png(i) for i, d in enumerate(DIRECTIONS)})
            client = FakeClient()
            out = tmp / "out.zip"

            # Point source_zip_path at our temp file by monkeypatching
            # the PETS_DIR module global for the duration of this test.
            import gen_pixellab_zip as gpz
            original_dir = gpz.PETS_DIR
            gpz.PETS_DIR = tmp
            try:
                report = generate(
                    "test-species-stage",
                    client=client,
                    output_path=out,
                )
            finally:
                gpz.PETS_DIR = original_dir

            self.assertEqual(report.errors, [])
            self.assertTrue(out.is_file())
            # 8 dirs × 6 calls each (1 estimate + 3 walk batches + 2 idle batches) = 48
            self.assertEqual(report.api_calls, 8 * 6)
            # 8 dirs × (8 walk + 5 idle frames) = 104
            self.assertEqual(report.frames_written, 8 * 13)

    def test_resizes_source_to_image_size_before_api(self):
        # Regression: source rotations are 68×68 but PixelLab's endpoints only
        # accept power-of-2 canvases (128/64/32/16) and 422 on 68×68. generate()
        # must resize each rotation to image_size before any API call.
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src = make_source_zip(tmp, "x-adult", {d: _png(i, size=68) for i, d in enumerate(DIRECTIONS)})
            client = FakeClient()
            import gen_pixellab_zip as gpz
            original = gpz.PETS_DIR
            gpz.PETS_DIR = tmp
            try:
                report = generate("x-adult", client=client, output_path=tmp / "out.zip", image_size=(64, 64))
            finally:
                gpz.PETS_DIR = original
            self.assertEqual(report.errors, [])
            self.assertTrue(client.estimate_calls, "expected estimate_skeleton to be called")
            # Every image the API saw must be the requested 64×64, never the 68×68 source.
            for image_bytes, image_size in client.estimate_calls:
                self.assertEqual(Image.open(io.BytesIO(image_bytes)).size, (64, 64))
                self.assertEqual(image_size, (64, 64))

    def test_missing_source_zip_returns_error_report(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            client = FakeClient()
            import gen_pixellab_zip as gpz
            original = gpz.PETS_DIR
            gpz.PETS_DIR = tmp
            try:
                report = generate(
                    "missing-species",
                    client=client,
                    output_path=tmp / "out.zip",
                )
            finally:
                gpz.PETS_DIR = original
            self.assertTrue(report.errors)
            self.assertIn("source zip not found", report.errors[0])
            self.assertEqual(report.api_calls, 0)


if __name__ == "__main__":
    unittest.main()
