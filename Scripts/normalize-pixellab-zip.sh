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

def first_dir_count(anim_dict):
    for _, frame_list in anim_dict.items():
        return len(frame_list)
    return 0

def total_frames(anim_dict):
    return sum(len(v) for v in anim_dict.values())

def heuristic_for(key):
    return "walk" if first_dir_count(animations[key]) >= 6 else "idle"

# Bucket keys by heuristic-detected action. Operators sometimes accidentally
# create duplicate animation slots in PixelLab (e.g. clicking through "Add
# Animation" again on a partial walk). When that happens, pick the slot most
# likely to represent the operator's actual intent and drop the rest with a
# loud warning. Mass-gen sprint will hit this regularly so erroring out is
# too strict.
#
# Tiebreaker — newest first (operator's last action wins), with frame count
# as a stable secondary key. Earlier versions used "most frames wins" alone,
# but that picks wrong when an operator partially re-generates: original
# 8-frame walk is wrong, partial 4-frame regen is correct. mtime captures
# the "latest intent" signal that frame count alone misses.
def dir_mtime(key):
    """Return latest mtime of any file under animations/{key}/. Returns 0
    if the directory is missing on disk (shouldn't happen for a valid
    export, but defensive)."""
    d = os.path.join(tmp, "animations", key)
    if not os.path.isdir(d):
        return 0
    latest = 0
    for root, _, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            try:
                mt = os.path.getmtime(p)
                if mt > latest:
                    latest = mt
            except OSError:
                pass
    return latest

walk_candidates = [k for k in uuid_keys if heuristic_for(k) == "walk"]
idle_candidates = [k for k in uuid_keys if heuristic_for(k) == "idle"]

def pick_winner(candidates, label):
    if not candidates:
        return None, []
    if len(candidates) == 1:
        return candidates[0], []
    # Sort newest-first by mtime; ties (rare in practice — within-second
    # generation) broken by total frame count, then by key for determinism.
    sorted_keys = sorted(
        candidates,
        key=lambda k: (dir_mtime(k), total_frames(animations[k]), k),
        reverse=True,
    )
    keep = sorted_keys[0]
    drop = sorted_keys[1:]
    keep_frames = total_frames(animations[keep])
    keep_age = dir_mtime(keep)
    print(
        f"Warning: {len(candidates)} {label} slots found, keeping the newest:",
        file=sys.stderr,
    )
    for k in candidates:
        marker = "KEEP" if k == keep else "DROP"
        f = total_frames(animations[k])
        age = dir_mtime(k)
        rel = age - keep_age  # negative = older than kept
        print(
            f"  {marker} '{k[:18]}'  frames={f:3d}  mtime_offset={rel:+.1f}s",
            file=sys.stderr,
        )
    return keep, drop

walk_key, walk_drops = pick_winner(walk_candidates, "walk")
idle_key, idle_drops = pick_winner(idle_candidates, "idle")
dropped_keys = set(walk_drops) | set(idle_drops)

assignments = []
if walk_key:
    assignments.append((walk_key, "walk"))
if idle_key:
    assignments.append((idle_key, "idle"))

if not assignments:
    print("Error: no animations after filtering", file=sys.stderr)
    sys.exit(1)

DEFAULTS = {
    "walk": {"fps": 6, "loops": True},
    "idle": {"fps": 2, "loops": True},
}

# Clean up dropped orphan directories on disk (they'll bloat the zip
# unnecessarily otherwise).
for k in dropped_keys:
    orphan_dir = os.path.join(tmp, "animations", k)
    if os.path.isdir(orphan_dir):
        shutil.rmtree(orphan_dir)

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
