#!/usr/bin/env bash
#
# normalize-pixellab-zip.sh — bridge raw PixelLab character export to v3.0
# normalized schema that PeerDrop's SpriteMetadata Swift parser consumes.
#
# Phase 0.5 of v5 multi-frame implementation. See:
#   docs/plans/2026-05-08-v5-multi-frame-sprite-design.md §2 "Normalize step"
#
# Behavior:
#   - Iterates frames.animations.{uuid} keys (insertion order).
#   - Counts frames per direction (samples first dir's array length).
#   - Heuristic: >=6 = walk, <6 = idle.
#   - Tiebreaker on 2-animation zips: insertion order — 1st = walk, 2nd = idle.
#     Operator MUST generate walk first in PixelLab for this to work.
#   - Errors out if heuristic and insertion order disagree.
#   - Renames each animations/animation-{uuid}/ → animations/{action}/.
#   - Rewrites metadata.json: wraps action entries with {fps, frame_count,
#     loops, directions}; updates frame paths; bumps export_version to "3.0";
#     adds v5_compatible: true.
#
# Defaults (per design doc §3 Resilience):
#   walk → fps=6, loops=true
#   idle → fps=2, loops=true

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <raw-pixellab-export.zip> <output-normalized.zip>" >&2
    exit 2
fi

RAW="$1"
OUT="$2"

if [[ ! -f "$RAW" ]]; then
    echo "Error: raw zip not found: $RAW" >&2
    exit 1
fi

# Resolve output to absolute path before we cd around
OUT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)" || {
    echo "Error: output directory does not exist: $(dirname "$OUT")" >&2
    exit 1
}
OUT_ABS="$OUT_DIR/$(basename "$OUT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unzip -q "$RAW" -d "$TMP"

if [[ ! -f "$TMP/metadata.json" ]]; then
    echo "Error: no metadata.json in raw zip" >&2
    exit 1
fi

python3 - "$TMP" <<'PYEOF'
import json
import os
import shutil
import sys

tmp = sys.argv[1]
meta_path = os.path.join(tmp, "metadata.json")

with open(meta_path) as f:
    meta = json.load(f)

frames = meta.get("frames", {})
animations = frames.get("animations", {})
if not animations:
    print("Error: no frames.animations in metadata", file=sys.stderr)
    sys.exit(1)

uuid_keys = list(animations.keys())
if len(uuid_keys) > 2:
    print(f"Error: expected <=2 animations, found {len(uuid_keys)}: {uuid_keys}",
          file=sys.stderr)
    sys.exit(1)

def first_dir_count(anim_dict):
    for _, frame_list in anim_dict.items():
        return len(frame_list)
    return 0

DEFAULTS = {
    "walk": {"fps": 6, "loops": True},
    "idle": {"fps": 2, "loops": True},
}

assignments = []
for idx, key in enumerate(uuid_keys):
    fcount = first_dir_count(animations[key])
    heuristic = "walk" if fcount >= 6 else "idle"

    if len(uuid_keys) == 2:
        order = "walk" if idx == 0 else "idle"
        if heuristic != order:
            print(
                f"Error: heuristic ({heuristic}, frames={fcount}) and insertion "
                f"order ({order}) disagree for key '{key}'. Operator must "
                f"regenerate with walk first.",
                file=sys.stderr,
            )
            sys.exit(1)
        assignments.append((key, order))
    else:
        assignments.append((key, heuristic))

actions_seen = [a for _, a in assignments]
if len(set(actions_seen)) != len(actions_seen):
    print(f"Error: duplicate action assignments: {assignments}", file=sys.stderr)
    sys.exit(1)

new_animations = {}
for key, action in assignments:
    old_dir = os.path.join(tmp, "animations", key)
    new_dir = os.path.join(tmp, "animations", action)

    if os.path.isdir(old_dir):
        if os.path.exists(new_dir):
            print(f"Error: target dir already exists: {new_dir}", file=sys.stderr)
            sys.exit(1)
        shutil.move(old_dir, new_dir)
    else:
        print(f"Warning: expected dir missing on disk: {old_dir}", file=sys.stderr)

    new_directions = {}
    for direction, paths in animations[key].items():
        new_paths = [
            p.replace(f"animations/{key}/", f"animations/{action}/")
            for p in paths
        ]
        new_directions[direction] = new_paths

    fc = first_dir_count(animations[key])
    new_animations[action] = {
        "fps": DEFAULTS[action]["fps"],
        "frame_count": fc,
        "loops": DEFAULTS[action]["loops"],
        "directions": new_directions,
    }

frames["animations"] = new_animations
meta["frames"] = frames
meta["export_version"] = "3.0"
meta["v5_compatible"] = True

with open(meta_path, "w") as f:
    json.dump(meta, f, indent=2)

summary = ", ".join(f"{k[:18]}->{v}" for k, v in assignments)
print(f"Normalized: {summary}")
PYEOF

rm -f "$OUT_ABS"
(cd "$TMP" && zip -qr "$OUT_ABS" .)

echo "Wrote: $OUT_ABS"
