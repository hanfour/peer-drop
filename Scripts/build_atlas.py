#!/usr/bin/env python3
"""Convert a v3.0 species×stage zip into a v3.1 zip that also carries a
single-image sprite atlas alongside the per-frame PNGs.

Why: the v3.0 layout stores every rotation / animation frame as its own
PNG entry inside the zip. Decoding 32+ PNGs per species×stage means 32
`CGImageSourceCreate` calls on the iOS side. An atlas collapses that into
one decode: every frame is sliced (zero-copy) from a single backing image.

Output schema (added to the zip; existing entries are preserved so v3.0
readers still work):

    atlas.png   — RGBA grid of every unique sprite frame
    atlas.json  — {
                    "atlas_version": 1,
                    "frame_size":    {"width": W, "height": H},
                    "frames": {
                        "<original-path>": {"x": X, "y": Y, "w": W, "h": H}
                    }
                  }

The frame_size mirrors `character.size` in metadata.json — every PixelLab
export within a single zip uses uniform frame dimensions.

Dedup: identical PNG files (same SHA-256) collapse to a single atlas
slot referenced by multiple paths. This is the common case for repeated
rotations across walk directions.

The script is idempotent: re-running on a zip that already contains
`atlas.png`/`atlas.json` rewrites them.

Usage:
    python3 Scripts/build_atlas.py <zip-path> [--in-place|--output=<path>]

In-place (default) mutates the source zip. `--output` writes to a fresh
file, leaving the input untouched (useful in tests).
"""

import argparse
import hashlib
import io
import json
import math
import shutil
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from PIL import Image


ATLAS_PNG_NAME = "atlas.png"
ATLAS_JSON_NAME = "atlas.json"
ATLAS_VERSION = 1


@dataclass
class AtlasBuildReport:
    """Outcome of an atlas build pass — useful for tests + operator log."""
    frame_count: int       # number of distinct path keys in atlas.json
    unique_slots: int      # number of physical atlas cells after dedup
    atlas_width: int
    atlas_height: int
    frame_width: int
    frame_height: int


def collect_frame_paths(metadata: dict) -> list[str]:
    """Walk metadata.json and return every unique frame path it references,
    in a stable order: rotations first (sorted by direction key), then
    animations sorted by (action, direction, frame_index).

    Stable order keeps the atlas binary-reproducible across runs, which
    means re-running build_atlas on an unchanged zip produces a byte-
    identical atlas.png and atlas.json — cheap to verify, no spurious
    diffs in commits.
    """
    paths: list[str] = []
    seen: set[str] = set()

    frames = metadata.get("frames", {})

    for direction in sorted(frames.get("rotations", {}).keys()):
        path = frames["rotations"][direction]
        if path not in seen:
            seen.add(path)
            paths.append(path)

    animations = frames.get("animations", {}) or {}
    for action in sorted(animations.keys()):
        anim = animations[action]
        directions = anim.get("directions", {}) or {}
        for direction in sorted(directions.keys()):
            for path in directions[direction]:
                if path not in seen:
                    seen.add(path)
                    paths.append(path)

    return paths


def grid_dims(slot_count: int) -> tuple[int, int]:
    """Compute (cols, rows) for laying `slot_count` cells out as close to
    square as possible. Square-ish keeps atlas dimensions GPU-friendly
    (texture upload prefers near-square shapes over long strips on
    older PowerVR / Apple GPUs).
    """
    if slot_count <= 0:
        return (0, 0)
    cols = max(1, int(math.ceil(math.sqrt(slot_count))))
    rows = max(1, int(math.ceil(slot_count / cols)))
    return (cols, rows)


def build_atlas_from_pngs(
    pngs: dict[str, bytes],
    metadata: dict,
) -> tuple[bytes, dict, AtlasBuildReport]:
    """Pack the supplied PNG byte blobs into a single atlas image.

    `pngs` is keyed by the original path inside the zip (e.g.
    "rotations/south.png", "animations/walk/east/frame_003.png").

    Returns (atlas_png_bytes, atlas_json_dict, report).
    """
    char = metadata.get("character", {})
    size = char.get("size", {})
    fw = int(size.get("width", 0))
    fh = int(size.get("height", 0))
    if fw <= 0 or fh <= 0:
        raise ValueError(
            f"metadata.character.size missing or invalid: {size!r}. "
            "Atlas requires uniform frame dimensions to compute grid."
        )

    ordered_paths = collect_frame_paths(metadata)
    missing = [p for p in ordered_paths if p not in pngs]
    if missing:
        raise ValueError(
            f"metadata references {len(missing)} frame path(s) not present "
            f"in the zip: {missing[:3]}{'...' if len(missing) > 3 else ''}"
        )

    # Dedup by SHA-256 of the PNG bytes. Two paths with byte-identical
    # PNG content share a single atlas slot. This is the common case for
    # rotation PNGs reused across walk-direction frame-0 entries.
    digest_to_slot: dict[str, int] = {}
    slot_images: list[Image.Image] = []
    path_to_slot: dict[str, int] = {}

    for path in ordered_paths:
        data = pngs[path]
        digest = hashlib.sha256(data).hexdigest()
        if digest not in digest_to_slot:
            img = Image.open(io.BytesIO(data))
            if img.size != (fw, fh):
                raise ValueError(
                    f"{path} is {img.size}, expected ({fw}, {fh}). "
                    "Atlas builder requires uniform frame size."
                )
            img = img.convert("RGBA")
            digest_to_slot[digest] = len(slot_images)
            slot_images.append(img)
        path_to_slot[path] = digest_to_slot[digest]

    cols, rows = grid_dims(len(slot_images))
    atlas_w = cols * fw
    atlas_h = rows * fh

    atlas = Image.new("RGBA", (atlas_w, atlas_h), (0, 0, 0, 0))
    slot_rects: list[tuple[int, int, int, int]] = []
    for index, img in enumerate(slot_images):
        col = index % cols
        row = index // cols
        x = col * fw
        y = row * fh
        atlas.paste(img, (x, y))
        slot_rects.append((x, y, fw, fh))

    frames_json: dict[str, dict[str, int]] = {}
    for path, slot in path_to_slot.items():
        x, y, w, h = slot_rects[slot]
        frames_json[path] = {"x": x, "y": y, "w": w, "h": h}

    atlas_json = {
        "atlas_version": ATLAS_VERSION,
        "frame_size": {"width": fw, "height": fh},
        "frames": frames_json,
    }

    out = io.BytesIO()
    # optimize=True shaves a few % at no quality cost — atlases live in
    # the bundle forever so the one-shot encode cost is irrelevant.
    atlas.save(out, format="PNG", optimize=True)

    return (
        out.getvalue(),
        atlas_json,
        AtlasBuildReport(
            frame_count=len(path_to_slot),
            unique_slots=len(slot_images),
            atlas_width=atlas_w,
            atlas_height=atlas_h,
            frame_width=fw,
            frame_height=fh,
        ),
    )


def add_atlas_to_zip(
    zip_path: Path,
    output_path: Path,
    *,
    strip_frames: bool = False,
) -> AtlasBuildReport:
    """Read `zip_path`, build the atlas, and write a new zip to
    `output_path` that contains every original entry plus atlas.png +
    atlas.json. Existing atlas entries in the source are dropped (so
    re-running is idempotent rather than accumulating stale data).

    When `strip_frames=True`, per-frame PNGs (rotations/* and animations/*)
    are omitted from the output — the atlas becomes the sole source of
    pixel data, shrinking the bundle. Use this once SpriteService can
    read atlases (the per-frame fallback code path will never fire for
    a stripped zip).

    `zip_path` and `output_path` may point at the same file; the function
    writes to a temp file and only swaps on success, so a partial run
    can't corrupt the input.
    """
    with zipfile.ZipFile(zip_path, "r") as zf:
        names = zf.namelist()
        if "metadata.json" not in names:
            raise ValueError(f"{zip_path}: missing metadata.json — not a v3.0 zip")
        metadata = json.loads(zf.read("metadata.json").decode("utf-8"))

        png_paths = [
            n for n in names
            if n.endswith(".png") and n not in (ATLAS_PNG_NAME,)
        ]
        pngs = {p: zf.read(p) for p in png_paths}

    atlas_bytes, atlas_json, report = build_atlas_from_pngs(pngs, metadata)

    # Paths to drop from the output, in addition to the existing atlas
    # entries we always rewrite. In strip mode this is every per-frame
    # PNG; the atlas becomes the sole pixel source.
    drop = {ATLAS_PNG_NAME, ATLAS_JSON_NAME}
    if strip_frames:
        drop.update(png_paths)

    # Write to a sibling tempfile, then rename — avoids leaving a half-
    # written zip if the script is interrupted mid-write.
    tmp_path = output_path.with_suffix(output_path.suffix + ".tmp")
    try:
        with zipfile.ZipFile(zip_path, "r") as src, \
                zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as dst:
            for info in src.infolist():
                if info.filename in drop:
                    continue
                # Empty directory entries (e.g. "animations/walk/east/")
                # become noise once their frames are stripped. Skip them
                # in strip mode so the zip listing stays clean.
                if strip_frames and info.is_dir():
                    continue
                dst.writestr(info, src.read(info.filename))
            dst.writestr(ATLAS_PNG_NAME, atlas_bytes)
            dst.writestr(
                ATLAS_JSON_NAME,
                json.dumps(atlas_json, sort_keys=True, indent=2).encode("utf-8"),
            )
        shutil.move(str(tmp_path), str(output_path))
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Build an atlas for a v3.0 sprite zip.")
    parser.add_argument("zip_path", type=Path, help="Path to the source zip.")
    parser.add_argument(
        "--output",
        type=Path,
        help="Write to this path instead of mutating the source in place.",
    )
    parser.add_argument(
        "--strip-frames",
        action="store_true",
        help="Drop per-frame PNGs from the output (atlas-only mode). "
             "Use once readers no longer fall back to the per-frame path.",
    )
    args = parser.parse_args()

    if not args.zip_path.is_file():
        print(f"error: {args.zip_path} does not exist", flush=True)
        return 2

    output_path: Path = args.output if args.output else args.zip_path
    report = add_atlas_to_zip(
        args.zip_path,
        output_path,
        strip_frames=args.strip_frames,
    )
    print(
        f"atlas written → {output_path}\n"
        f"  frame_size:    {report.frame_width}×{report.frame_height}\n"
        f"  frames mapped: {report.frame_count}\n"
        f"  unique slots:  {report.unique_slots} "
        f"(dedup saved {report.frame_count - report.unique_slots})\n"
        f"  atlas size:    {report.atlas_width}×{report.atlas_height}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
