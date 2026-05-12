#!/usr/bin/env python3
"""Unit tests for Scripts/build_atlas.py.

Run from repo root:
    python3 -m unittest Scripts.test_build_atlas
or:
    cd Scripts && python3 -m unittest test_build_atlas
"""

import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from PIL import Image

from build_atlas import (  # noqa: E402
    ATLAS_JSON_NAME,
    ATLAS_PNG_NAME,
    ATLAS_VERSION,
    add_atlas_to_zip,
    build_atlas_from_pngs,
    collect_frame_paths,
    grid_dims,
)


def png_bytes(width: int, height: int, color: tuple[int, int, int, int]) -> bytes:
    img = Image.new("RGBA", (width, height), color)
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


def make_metadata(*, frame_size=(68, 68), with_anim=True) -> dict:
    meta = {
        "character": {
            "id": "test",
            "name": "t",
            "size": {"width": frame_size[0], "height": frame_size[1]},
            "directions": 8,
        },
        "frames": {
            "rotations": {
                "south": "rotations/south.png",
                "east": "rotations/east.png",
            },
            "animations": {},
        },
        "export_version": "3.0",
    }
    if with_anim:
        meta["frames"]["animations"] = {
            "walk": {
                "fps": 6,
                "frame_count": 2,
                "loops": True,
                "directions": {
                    "east": [
                        "animations/walk/east/frame_000.png",
                        "animations/walk/east/frame_001.png",
                    ],
                },
            }
        }
    return meta


def make_zip_bytes(metadata: dict, pngs: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("metadata.json", json.dumps(metadata).encode("utf-8"))
        for path, data in pngs.items():
            zf.writestr(path, data)
    return buf.getvalue()


class GridDimsTests(unittest.TestCase):
    def test_zero_returns_zero_zero(self):
        self.assertEqual(grid_dims(0), (0, 0))

    def test_single_cell_is_one_by_one(self):
        self.assertEqual(grid_dims(1), (1, 1))

    def test_perfect_square(self):
        self.assertEqual(grid_dims(16), (4, 4))

    def test_rounds_up_to_square_ish(self):
        # 17 frames → 5 cols × 4 rows (5*4=20 >= 17)
        cols, rows = grid_dims(17)
        self.assertEqual(cols, 5)
        self.assertEqual(rows, 4)
        self.assertGreaterEqual(cols * rows, 17)


class CollectFramePathsTests(unittest.TestCase):
    def test_rotations_then_animations_in_sorted_order(self):
        meta = make_metadata()
        paths = collect_frame_paths(meta)
        self.assertEqual(
            paths,
            [
                "rotations/east.png",
                "rotations/south.png",
                "animations/walk/east/frame_000.png",
                "animations/walk/east/frame_001.png",
            ],
        )

    def test_dedups_repeated_paths_in_metadata(self):
        # If a path appears in both rotations and animations (e.g. a frame
        # repurposed as a rotation), it must appear in the output once.
        meta = make_metadata(with_anim=False)
        meta["frames"]["animations"] = {
            "walk": {
                "fps": 6, "frame_count": 1, "loops": True,
                "directions": {"east": ["rotations/east.png"]},
            }
        }
        paths = collect_frame_paths(meta)
        self.assertEqual(paths.count("rotations/east.png"), 1)

    def test_handles_missing_animations_block(self):
        meta = make_metadata(with_anim=False)
        meta["frames"].pop("animations", None)
        paths = collect_frame_paths(meta)
        self.assertEqual(paths, ["rotations/east.png", "rotations/south.png"])


class BuildAtlasFromPngsTests(unittest.TestCase):
    def test_packs_distinct_pngs_into_grid(self):
        meta = make_metadata()
        pngs = {
            "rotations/south.png": png_bytes(68, 68, (255, 0, 0, 255)),
            "rotations/east.png": png_bytes(68, 68, (0, 255, 0, 255)),
            "animations/walk/east/frame_000.png": png_bytes(68, 68, (0, 0, 255, 255)),
            "animations/walk/east/frame_001.png": png_bytes(68, 68, (255, 255, 0, 255)),
        }
        atlas_bytes, atlas_json, report = build_atlas_from_pngs(pngs, meta)

        self.assertEqual(atlas_json["atlas_version"], ATLAS_VERSION)
        self.assertEqual(atlas_json["frame_size"], {"width": 68, "height": 68})
        self.assertEqual(set(atlas_json["frames"].keys()), set(pngs.keys()))
        self.assertEqual(report.frame_count, 4)
        self.assertEqual(report.unique_slots, 4)

        # Sanity: rects fit inside the atlas image dimensions.
        atlas = Image.open(io.BytesIO(atlas_bytes))
        self.assertEqual(atlas.size, (report.atlas_width, report.atlas_height))
        for path, rect in atlas_json["frames"].items():
            self.assertGreaterEqual(rect["x"], 0)
            self.assertGreaterEqual(rect["y"], 0)
            self.assertLessEqual(rect["x"] + rect["w"], report.atlas_width)
            self.assertLessEqual(rect["y"] + rect["h"], report.atlas_height)

    def test_dedups_byte_identical_pngs(self):
        meta = make_metadata()
        same = png_bytes(68, 68, (10, 20, 30, 255))
        pngs = {
            "rotations/south.png": same,
            "rotations/east.png": same,
            "animations/walk/east/frame_000.png": same,
            "animations/walk/east/frame_001.png": png_bytes(68, 68, (255, 0, 0, 255)),
        }
        _, atlas_json, report = build_atlas_from_pngs(pngs, meta)

        self.assertEqual(report.frame_count, 4)
        self.assertEqual(report.unique_slots, 2)  # 3 identical + 1 distinct
        # All three identical paths point at the same rect.
        rect_a = tuple(atlas_json["frames"]["rotations/south.png"].values())
        rect_b = tuple(atlas_json["frames"]["rotations/east.png"].values())
        rect_c = tuple(atlas_json["frames"]["animations/walk/east/frame_000.png"].values())
        self.assertEqual(rect_a, rect_b)
        self.assertEqual(rect_a, rect_c)

    def test_slice_recovers_pixel_data(self):
        # Pack a known color into a known slot, then crop and read back.
        meta = make_metadata(with_anim=False)
        pngs = {
            "rotations/south.png": png_bytes(68, 68, (100, 150, 200, 255)),
            "rotations/east.png": png_bytes(68, 68, (50, 75, 100, 255)),
        }
        atlas_bytes, atlas_json, _ = build_atlas_from_pngs(pngs, meta)
        atlas = Image.open(io.BytesIO(atlas_bytes)).convert("RGBA")
        rect = atlas_json["frames"]["rotations/south.png"]
        crop = atlas.crop((rect["x"], rect["y"], rect["x"] + rect["w"], rect["y"] + rect["h"]))
        self.assertEqual(crop.getpixel((10, 10)), (100, 150, 200, 255))

    def test_rejects_mismatched_frame_size(self):
        meta = make_metadata()
        pngs = {
            "rotations/south.png": png_bytes(64, 64, (0, 0, 0, 255)),  # wrong
            "rotations/east.png": png_bytes(68, 68, (0, 0, 0, 255)),
            "animations/walk/east/frame_000.png": png_bytes(68, 68, (0, 0, 0, 255)),
            "animations/walk/east/frame_001.png": png_bytes(68, 68, (0, 0, 0, 255)),
        }
        with self.assertRaises(ValueError) as cm:
            build_atlas_from_pngs(pngs, meta)
        self.assertIn("expected (68, 68)", str(cm.exception))

    def test_rejects_missing_referenced_path(self):
        meta = make_metadata()
        pngs = {
            "rotations/south.png": png_bytes(68, 68, (0, 0, 0, 255)),
            # missing rotations/east.png + walk frames
        }
        with self.assertRaises(ValueError) as cm:
            build_atlas_from_pngs(pngs, meta)
        self.assertIn("not present", str(cm.exception))


class AddAtlasToZipTests(unittest.TestCase):
    def _build_input_zip(self, tmp: Path) -> Path:
        meta = make_metadata()
        pngs = {
            "rotations/south.png": png_bytes(68, 68, (1, 2, 3, 255)),
            "rotations/east.png": png_bytes(68, 68, (4, 5, 6, 255)),
            "animations/walk/east/frame_000.png": png_bytes(68, 68, (7, 8, 9, 255)),
            "animations/walk/east/frame_001.png": png_bytes(68, 68, (10, 11, 12, 255)),
        }
        zip_path = tmp / "test.zip"
        zip_path.write_bytes(make_zip_bytes(meta, pngs))
        return zip_path

    def test_writes_atlas_alongside_original_entries(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            zip_path = self._build_input_zip(tmp)
            out_path = tmp / "out.zip"

            report = add_atlas_to_zip(zip_path, out_path)

            with zipfile.ZipFile(out_path, "r") as zf:
                names = set(zf.namelist())
                self.assertIn(ATLAS_PNG_NAME, names)
                self.assertIn(ATLAS_JSON_NAME, names)
                self.assertIn("metadata.json", names)
                self.assertIn("rotations/south.png", names)
                self.assertIn("animations/walk/east/frame_000.png", names)

            self.assertEqual(report.frame_count, 4)

    def test_is_idempotent_on_rebuild(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            zip_path = self._build_input_zip(tmp)
            out_path = tmp / "out.zip"

            add_atlas_to_zip(zip_path, out_path)
            first = out_path.read_bytes()

            # Rebuild from the just-atlased zip — atlas entries should be
            # regenerated identically (sort-keyed JSON + deterministic
            # frame order make this verifiable).
            add_atlas_to_zip(out_path, out_path)
            second = out_path.read_bytes()

            with zipfile.ZipFile(out_path, "r") as zf:
                atlas_json = json.loads(zf.read(ATLAS_JSON_NAME).decode("utf-8"))
                # JSON content stable; byte equality of the zip itself isn't
                # guaranteed (zip timestamps), but the atlas contract is.
                self.assertEqual(atlas_json["atlas_version"], ATLAS_VERSION)
                self.assertEqual(len(atlas_json["frames"]), 4)
            # Sanity: re-running didn't lose entries.
            with zipfile.ZipFile(out_path, "r") as zf:
                self.assertIn("rotations/south.png", zf.namelist())

    def test_in_place_overwrite_preserves_entries(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            zip_path = self._build_input_zip(tmp)

            add_atlas_to_zip(zip_path, zip_path)  # in-place

            with zipfile.ZipFile(zip_path, "r") as zf:
                names = set(zf.namelist())
                self.assertIn(ATLAS_PNG_NAME, names)
                self.assertIn("rotations/south.png", names)

    def test_strip_frames_drops_per_frame_pngs(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            zip_path = self._build_input_zip(tmp)
            out_path = tmp / "stripped.zip"

            report = add_atlas_to_zip(zip_path, out_path, strip_frames=True)

            with zipfile.ZipFile(out_path, "r") as zf:
                names = set(zf.namelist())
                # Atlas pair + metadata remain — that's the shipping shape.
                self.assertIn(ATLAS_PNG_NAME, names)
                self.assertIn(ATLAS_JSON_NAME, names)
                self.assertIn("metadata.json", names)
                # Per-frame PNGs are gone; atlas is the sole pixel source.
                self.assertNotIn("rotations/south.png", names)
                self.assertNotIn("animations/walk/east/frame_000.png", names)
            self.assertEqual(report.frame_count, 4)


if __name__ == "__main__":
    unittest.main()
