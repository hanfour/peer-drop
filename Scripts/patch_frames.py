#!/usr/bin/env python3
"""Repair degenerate frames in a landed v5 atlas zip, in place.

PixelLab occasionally emits an outline-only frame (body fill transparent) —
in game that reads as a one-frame ghost flicker. Regenerating costs a full
species' quota, so instead each bad frame is overwritten with the nearest
clean frame from the same animation+direction. The cycle holds a pose for
one extra tick rather than flashing.

    python3 patch_frames.py <species> [<species> ...]
"""
import json
import shutil
import sys
import zipfile
from io import BytesIO
from pathlib import Path
from statistics import median

from PIL import Image

PETS = (Path(__file__).resolve().parent.parent
        / "PeerDropKit/Sources/PeerDropPet/Resources/Pets")
FLOOR_RATIO = 0.35  # keep in sync with qc_frames.py


def coverage(atlas: Image.Image, box: dict) -> float:
    tile = atlas.crop((box["x"], box["y"], box["x"] + box["w"], box["y"] + box["h"]))
    alpha = tile.getchannel("A")
    return sum(c for v, c in enumerate(alpha.histogram()) if v > 16) / (box["w"] * box["h"])


def patch(species: str) -> int:
    zip_path = PETS / f"{species}.zip"
    with zipfile.ZipFile(zip_path) as z:
        members = {n: z.read(n) for n in z.namelist()}
    meta = json.loads(members["atlas.json"])
    atlas = Image.open(BytesIO(members["atlas.png"])).convert("RGBA")

    cov = {n: coverage(atlas, b) for n, b in meta["frames"].items()}
    med = median(cov.values())
    bad = {n for n, c in cov.items() if c < med * FLOOR_RATIO}
    if not bad:
        print(f"✓ {species}: nothing to patch")
        return 0

    fixed = 0
    for name in sorted(bad):
        group = name.rsplit("/", 1)[0]
        # Nearest clean sibling in the same animation+direction, by frame index.
        idx = int(name.rsplit("_", 1)[1].split(".")[0])
        siblings = sorted(
            (n for n in meta["frames"]
             if n.rsplit("/", 1)[0] == group and n not in bad),
            key=lambda n: abs(int(n.rsplit("_", 1)[1].split(".")[0]) - idx),
        )
        if not siblings:
            print(f"  ✗ {name}: every frame in {group} is degenerate — left as-is")
            continue
        src, dst = meta["frames"][siblings[0]], meta["frames"][name]
        tile = atlas.crop((src["x"], src["y"], src["x"] + src["w"], src["y"] + src["h"]))
        # Clear the slot first: paste replaces RGBA wholesale, no alpha blending.
        atlas.paste((0, 0, 0, 0), (dst["x"], dst["y"], dst["x"] + dst["w"], dst["y"] + dst["h"]))
        atlas.paste(tile, (dst["x"], dst["y"]))
        print(f"  ↻ {name} ← {siblings[0]}")
        fixed += 1

    buf = BytesIO()
    atlas.save(buf, format="PNG", optimize=True)
    members["atlas.png"] = buf.getvalue()

    shutil.copy2(zip_path, zip_path.with_suffix(".zip.bak"))
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in members.items():
            z.writestr(name, data)
    print(f"✓ {species}: patched {fixed} frame(s)")
    return fixed


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    total = sum(patch(s) for s in sys.argv[1:])
    print(f"\n=== patched {total} frame(s) ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
