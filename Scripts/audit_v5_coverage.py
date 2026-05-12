#!/usr/bin/env python3
"""
Audit current v5 vs v4 coverage of bundled pet zips.

Usage:
    python3 Scripts/audit_v5_coverage.py             # summary + first 30 priority rows
    python3 Scripts/audit_v5_coverage.py --full      # full priority list
    python3 Scripts/audit_v5_coverage.py --csv > out.csv

Reads each zip's metadata.json and classifies as v5 multi-frame (has
non-empty `frames.animations.walk` with >1 frame) vs v4 static. Cross-
references with the genome distribution from BodyGene.from() and stage
weighting to rank by user-visible impact.

Source of truth for what's done: the `expectedV5Coverage` set in
PeerDropTests/Pet/MainBundleAssetCoverageTests.swift — but this script
reads the actual zip metadata, so it catches drift (a zip dropped in the
bundle but not added to the whitelist, or vice versa).
"""
from __future__ import annotations

import argparse
import json
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PETS_DIR = REPO_ROOT / "PeerDrop" / "Resources" / "Pets"

# v5.0.1 genome distribution from PetGenome.BodyGene.from(personalityGene:)
# Keep in sync with the switch in PetGenome.swift.
DIST = {
    "cat":     0.50,
    "dog":     0.10,
    "rabbit":  0.08,
    "bird":    0.08,
    "frog":    0.06,
    "bear":    0.06,
    "dragon":  0.04,
    "octopus": 0.04,
    "slime":   0.04,
}

# Heuristic: typical engaged user's pet spends ~10% of its lifetime as a baby
# (8 days), ~70% as adult (8 → 90), ~20% as elder (90+). Adjust if needed.
STAGE_WEIGHT = {"baby": 0.10, "adult": 0.70, "elder": 0.20}

# Sub-varieties per family. Mirrors SpeciesCatalog in
# PeerDrop/Pet/Sprites/SpeciesCatalog.swift. None = single-variety family.
VARIANTS = {
    "cat":     ["tabby", "bengal", "calico", "persian", "siamese"],
    "dog":     ["shiba", "collie", "dachshund", "husky", "labrador"],
    "rabbit":  ["dutch", "angora", "lionhead", "lop"],
    "bear":    ["brown", "black", "panda", "polar"],
    "dragon":  ["western", "eastern", "fire", "ice"],
    "slime":   ["green", "clear", "fire", "metal", "water"],
    "bird":    [None],
    "frog":    [None],
    "octopus": [None],
}

# Single-variety families with partial stage coverage. bird/frog ship only
# the elder zip; octopus ships baby + elder.
PARTIAL_COVERAGE_STAGES = {
    "bird":    ["elder"],
    "frog":    ["elder"],
    "octopus": ["baby", "elder"],
}


def read_metadata(stem: str) -> dict | None:
    p = PETS_DIR / f"{stem}.zip"
    if not p.exists():
        return None
    try:
        with zipfile.ZipFile(p) as z:
            with z.open("metadata.json") as f:
                return json.load(f)
    except (KeyError, json.JSONDecodeError, zipfile.BadZipFile):
        return None


def classify(meta: dict | None) -> tuple[bool | None, tuple[int | None, int | None], str]:
    """(is_v5, (width, height), character_id). is_v5 is None if not bundled."""
    if meta is None:
        return None, (None, None), "?"
    size = meta.get("character", {}).get("size", {})
    w, h = size.get("width"), size.get("height")
    cid = meta.get("character", {}).get("id", "?")
    walk = meta.get("frames", {}).get("animations", {}).get("walk", {})
    is_v5 = walk.get("frame_count", 0) > 1
    return is_v5, (w, h), cid


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="show every entry, not just top 30")
    ap.add_argument("--csv", action="store_true", help="emit CSV to stdout (overrides --full)")
    args = ap.parse_args()

    rows = []
    for fam, fam_prob in DIST.items():
        variants = VARIANTS[fam]
        stages = PARTIAL_COVERAGE_STAGES.get(fam, ["baby", "adult", "elder"])
        for variant in variants:
            for stage in stages:
                if variant is None:
                    stem = f"{fam}-{stage}" if len(stages) > 1 else fam
                else:
                    stem = f"{fam}-{variant}-{stage}"
                prob = (
                    fam_prob
                    * (1.0 / len(variants))
                    * STAGE_WEIGHT.get(stage, 0.33)
                )
                is_v5, size, cid = classify(read_metadata(stem))
                rows.append((prob, stem, is_v5, size, cid))

    rows.sort(key=lambda r: (-r[0], r[1]))

    if args.csv:
        print("user_pct,stem,v5,width,height,character_id")
        for prob, stem, v5, size, cid in rows:
            v5_str = "yes" if v5 else ("no" if v5 is False else "missing")
            print(f"{prob*100:.4f},{stem},{v5_str},{size[0] or ''},{size[1] or ''},{cid}")
        return 0

    total = len(rows)
    v5_count = sum(1 for _, _, v5, _, _ in rows if v5)
    print(f"Total tracked species×stage entries: {total}")
    print(f"At v5 schema: {v5_count}")
    print(f"At v4 / missing: {total - v5_count}")
    print()
    print(f"{'%user':>6}  {'stem':32s}  {'v5':>4}  {'size':>7}  char")
    print("-" * 80)
    limit = total if args.full else 30
    for prob, stem, v5, size, cid in rows[:limit]:
        v5_mark = "✓" if v5 else ("·" if v5 is False else "?")
        sz = f"{size[0]}×{size[1]}" if size[0] else "?"
        print(f"{prob*100:5.2f}%  {stem:32s}  {v5_mark:>4}  {sz:>7}  {cid[:8]}")
    if not args.full and total > 30:
        print(f"\n... {total - 30} more entries. Re-run with --full to see all.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
