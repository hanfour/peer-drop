#!/usr/bin/env python3
"""PixelLab API mass-gen cost calculator.

Surfaces the API-cost vs Apprentice-subscription-cost tradeoff so the
operator can make an informed decision before committing to API-driven
mass-gen. Pulls live coverage from `Scripts/coverage_report.py`'s
underlying logic.

Defaults assume:
  - 104 generations per species (8 walk dirs × 8 frames + 8 idle dirs × 5 frames)
  - $0.008 per generation at 68×68 (the 2026-05-14 WebFetched rate;
    verify against your actual usage invoice)
  - 30% retry rate (matches v4 batch experience)
  - 3 seconds per call sequential round-trip

Usage:
    python3 Scripts/pixellab_cost.py
        # default: report on the remaining v2 zips in the current bundle

    python3 Scripts/pixellab_cost.py --species 33 --price 0.008
        # custom: 33 species at $0.008/call

    python3 Scripts/pixellab_cost.py --no-retries
        # skip the 30% retry premium (best case)
"""

import argparse
import json
import sys
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
PETS_DIR = REPO_ROOT / "PeerDrop" / "Resources" / "Pets"

DEFAULT_PRICE_PER_CALL = 0.008
DEFAULT_FRAMES_PER_SPECIES = 104  # 8×8 walk + 8×5 idle
DEFAULT_RETRY_MULTIPLIER = 1.30
APPRENTICE_MONTHLY_COST = 12.00
APPRENTICE_MONTHLY_QUOTA = 2000


def count_remaining_v2() -> int:
    """Walk the bundle and count zips that are still at export_version
    2.0 — the ones still to be upgraded by Phase 3."""
    if not PETS_DIR.is_dir():
        return 0
    remaining = 0
    for path in PETS_DIR.glob("*.zip"):
        try:
            with zipfile.ZipFile(path, "r") as zf:
                if "metadata.json" not in zf.namelist():
                    continue
                meta = json.loads(zf.read("metadata.json").decode("utf-8"))
                if str(meta.get("export_version", "")) == "2.0":
                    remaining += 1
        except (zipfile.BadZipFile, json.JSONDecodeError, UnicodeDecodeError):
            continue
    return remaining


def format_dollars(amount: float) -> str:
    return f"${amount:,.2f}"


def format_hours(seconds: float) -> str:
    if seconds < 3600:
        return f"{seconds / 60:.0f} min"
    return f"{seconds / 3600:.1f} hr"


def main() -> int:
    parser = argparse.ArgumentParser(description="PixelLab API mass-gen cost calculator.")
    parser.add_argument("--species", type=int, default=None,
                        help="Number of species×stages to convert. Default: detect from bundle.")
    parser.add_argument("--price", type=float, default=DEFAULT_PRICE_PER_CALL,
                        help=f"USD per API call at 68×68. Default: {DEFAULT_PRICE_PER_CALL}")
    parser.add_argument("--frames", type=int, default=DEFAULT_FRAMES_PER_SPECIES,
                        help=f"Generations per species. Default: {DEFAULT_FRAMES_PER_SPECIES} (8×8 walk + 8×5 idle).")
    parser.add_argument("--no-retries", action="store_true",
                        help="Skip the 30%% retry premium (optimistic projection).")
    parser.add_argument("--call-seconds", type=float, default=3.0,
                        help="Seconds per API call (sequential round-trip). Default: 3.")
    parser.add_argument("--parallel", type=int, default=4,
                        help="Concurrent requests for time estimate. Default: 4.")
    args = parser.parse_args()

    species = args.species if args.species is not None else count_remaining_v2()
    if species <= 0:
        print("Nothing to do — 0 species remaining.", file=sys.stderr)
        return 0

    base_calls = species * args.frames
    retry_mult = 1.0 if args.no_retries else DEFAULT_RETRY_MULTIPLIER
    total_calls = int(base_calls * retry_mult)
    api_cost = total_calls * args.price

    # Time: sequential vs parallel
    seq_seconds = total_calls * args.call_seconds
    par_seconds = seq_seconds / max(1, args.parallel)

    # Apprentice tier alternative: $12/mo for 2000 quota; 5 months avg
    # at 1-2 species/day operator pace per STATUS.md §0.2.
    appr_months = max(1.0, total_calls / APPRENTICE_MONTHLY_QUOTA)
    appr_cost = appr_months * APPRENTICE_MONTHLY_COST

    print(f"=== PixelLab mass-gen cost projection ===")
    print(f"  Species remaining:        {species}")
    print(f"  Generations per species:  {args.frames}")
    print(f"  Retry premium:            {'+30%' if not args.no_retries else 'none (optimistic)'}")
    print(f"  Total API calls:          {total_calls:,}")
    print(f"")
    print(f"--- Option A: PixelLab API (this script's domain) ---")
    print(f"  USD per call:             {format_dollars(args.price)}")
    print(f"  Total API cost:           {format_dollars(api_cost)}")
    print(f"  Wall time @ {args.call_seconds:g}s/call:    {format_hours(seq_seconds)} sequential / "
          f"{format_hours(par_seconds)} at {args.parallel}× parallel")
    print(f"")
    print(f"--- Option B: Apprentice subscription + UI clicks ---")
    print(f"  Months @ {APPRENTICE_MONTHLY_QUOTA}/mo:     {appr_months:.1f}")
    print(f"  Subscription cost:        {format_dollars(appr_cost)}")
    print(f"  Wall time:                ~{appr_months:.1f} months calendar (operator's PixelLab UI time)")
    print(f"")
    print(f"--- Delta ---")
    print(f"  Cost difference:          API costs {format_dollars(api_cost - appr_cost)} more")
    print(f"  Time saved:               {appr_months * 30 - par_seconds / 86400:.0f} days "
          f"({appr_months:.1f} months → {par_seconds / 3600:.1f} hours)")
    print(f"")
    print(f"--- Caveats ---")
    print(f"  1. API requires building skeleton_keypoints per frame manually —")
    print(f"     see docs/plans/2026-05-14-pixellab-api-automation.md §Skeleton.")
    print(f"     The UI flow has skeletons baked in; the API does not.")
    print(f"  2. Retry rate is a v4-batch heuristic; first API runs may vary.")
    print(f"  3. Prices verify against your actual usage invoice; PixelLab's")
    print(f"     'pricing varies with GPU time' clause applies.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
