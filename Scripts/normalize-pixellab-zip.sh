#!/usr/bin/env bash
#
# normalize-pixellab-zip.sh — bridge raw PixelLab character export to v3.0
# normalized schema that PeerDrop's SpriteMetadata Swift parser consumes.
#
# Phase 0.5 of v5 multi-frame implementation. See:
#   docs/plans/2026-05-08-v5-multi-frame-sprite-design.md §2 "Normalize step"
#
# This is a thin shim around `Scripts/normalize_pixellab.py`. The Python
# module owns all rename/dedup/schema logic and has unit-test coverage at
# Scripts/test_normalize_pixellab.py — run via:
#     python3 -m unittest Scripts.test_normalize_pixellab
#
# Defaults (mirrors AssetSpec.swift; see Scripts/normalize_pixellab.py):
#   walk → fps=6, loops=true (heuristic: ≥6 frames per direction)
#   idle → fps=2, loops=true (heuristic: <6 frames per direction)
#
# Tiebreaker on duplicate same-action slots: newest mtime wins, then
# total frame count, then key (deterministic). Cross-slot direction
# merge enabled by default.

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

# Resolve output to absolute path
OUT_DIR="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)" || {
    echo "Error: output directory does not exist: $(dirname "$OUT")" >&2
    exit 1
}
OUT_ABS="$OUT_DIR/$(basename "$OUT")"

# Run via the Python module — keeps this shell shim minimal and lets
# the actual logic stay testable.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/normalize_pixellab.py" "$RAW" "$OUT_ABS"
