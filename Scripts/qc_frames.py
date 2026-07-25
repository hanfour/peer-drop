#!/usr/bin/env python3
"""Flag degenerate frames in landed v5 atlas zips.

PixelLab occasionally emits a near-empty or near-solid frame — a visible
flicker mid-walk-cycle. Slices each atlas by atlas.json and reports frames
whose opaque-pixel coverage is a big outlier vs. that zip's median frame.

    python3 qc_frames.py <species> [<species> ...]     # or no args = all landed
"""
import json
import sys
import zipfile
from io import BytesIO
from pathlib import Path
from statistics import median

from PIL import Image

PETS = (Path(__file__).resolve().parent.parent
        / "PeerDropKit/Sources/PeerDropPet/Resources/Pets")

# A frame is suspect if its opaque coverage falls below this fraction of the
# zip's median frame — empirically, real animation variance stays well above.
FLOOR_RATIO = 0.35


def scan(zip_path: Path) -> list[tuple[str, float, float]]:
    with zipfile.ZipFile(zip_path) as z:
        meta = json.loads(z.read("atlas.json"))
        atlas = Image.open(BytesIO(z.read("atlas.png"))).convert("RGBA")

    cov: dict[str, float] = {}
    for name, box in meta["frames"].items():
        tile = atlas.crop((box["x"], box["y"], box["x"] + box["w"], box["y"] + box["h"]))
        alpha = tile.getchannel("A")
        opaque = sum(c for v, c in enumerate(alpha.histogram()) if v > 16)
        cov[name] = opaque / (box["w"] * box["h"])

    med = median(cov.values())
    return sorted(
        ((n, c, c / med if med else 0.0) for n, c in cov.items() if med and c < med * FLOOR_RATIO),
        key=lambda t: t[1],
    )


def main() -> int:
    names = sys.argv[1:] or [p.stem for p in sorted(PETS.glob("*.zip"))]
    total_bad = 0
    for name in names:
        p = PETS / f"{name}.zip"
        if not p.is_file():
            print(f"  ✗ missing: {name}")
            continue
        try:
            bad = scan(p)
        except KeyError:
            continue  # not an atlas zip (per-frame or v2 schema)
        if bad:
            total_bad += len(bad)
            print(f"⚠ {name}: {len(bad)} degenerate frame(s)")
            for frame, c, ratio in bad:
                print(f"    {frame}  coverage={c:.3%}  ({ratio:.0%} of median)")
        else:
            print(f"✓ {name}: clean")
    print(f"\n=== {total_bad} degenerate frame(s) across {len(names)} zip(s) ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
