#!/usr/bin/env python3
"""PixelLab mass-gen cost projector.

Plans the v5 mass-gen budget assuming the operator already has an
active PixelLab subscription. The Apprentice tier ($12/mo) unlocks
the API AND gives 2000 generations/month — calls within the quota are
free; calls over are billed per the per-call price.

Three scenarios:

  1. UI-grinding (status quo):  operator clicks each species in the
     web UI; throughput limited by the operator's attention span,
     usually well below the 2000/mo quota.

  2. API + stay-in-quota:        the API automates UI clicking so
     the operator hits the 2000/mo cap consistently. No overage,
     no extra cost beyond the existing subscription. Finishes
     calendar-faster than UI-grinding without spending more.

  3. API + accept overage:       same automation but break through
     the quota cap each month, finishing in 1-2 months by paying
     for the calls beyond 2000.

Usage:
    python3 Scripts/pixellab_cost.py
        # all three scenarios for the remaining v2 zips in the bundle

    python3 Scripts/pixellab_cost.py --species 33
        # what-if for an arbitrary species count

    python3 Scripts/pixellab_cost.py --price 0.01
        # adjust per-call price (defaults to $0.008 WebFetched 2026-05-14;
        # verify against your actual usage invoice)
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

    # Wall-time arithmetic for the API-driven scenarios.
    seq_seconds = total_calls * args.call_seconds
    par_seconds = seq_seconds / max(1, args.parallel)

    # ─── Scenario 1: UI grinding (status quo per STATUS.md §0.2) ─────
    # Apprentice quota is 2000/mo; operator UI pace is 1-2 species/day
    # = 100-200 zips/mo = 10k-20k calls/mo, WAY above quota. Effectively
    # bound by the quota cap. Realistic = quota-limited.
    ui_months = max(1.0, total_calls / APPRENTICE_MONTHLY_QUOTA)
    ui_sub_cost = ui_months * APPRENTICE_MONTHLY_COST
    ui_overage_cost = 0.0
    ui_total_cost = ui_sub_cost + ui_overage_cost

    # ─── Scenario 2: API + stay in quota ────────────────────────────
    # Same calendar pace (quota-bound), but the operator runs one
    # batch per month instead of daily UI sessions. Same cost as
    # status quo because the subscription covers the quota.
    api_quota_months = max(1.0, total_calls / APPRENTICE_MONTHLY_QUOTA)
    api_quota_sub_cost = api_quota_months * APPRENTICE_MONTHLY_COST
    api_quota_overage = 0.0
    api_quota_total = api_quota_sub_cost + api_quota_overage

    # ─── Scenario 3: API + accept overage ───────────────────────────
    # Cram into a single month. 2000 free, rest at the per-call rate.
    api_burst_overage_calls = max(0, total_calls - APPRENTICE_MONTHLY_QUOTA)
    api_burst_overage_cost = api_burst_overage_calls * args.price
    api_burst_sub_cost = APPRENTICE_MONTHLY_COST   # one month minimum
    api_burst_total = api_burst_sub_cost + api_burst_overage_cost

    print(f"=== PixelLab mass-gen budget projection ===")
    print(f"  Species×stages remaining: {species}")
    print(f"  Calls per species:        {args.frames}")
    print(f"  Retry premium:            {'+30%' if not args.no_retries else 'none (optimistic)'}")
    print(f"  Total API calls needed:   {total_calls:,}")
    print(f"  Apprentice plan:          ${APPRENTICE_MONTHLY_COST:.0f}/mo, {APPRENTICE_MONTHLY_QUOTA:,} calls/mo included")
    print(f"  Per-call overage rate:    {format_dollars(args.price)}")
    print(f"")
    print(f"━━━ ★ RECOMMENDED ━━━ Scenario 2: API + stay in quota ━━━")
    print(f"  Each month: one weekend batch fills the {APPRENTICE_MONTHLY_QUOTA:,}-call quota.")
    print(f"  Calendar time:            {api_quota_months:.1f} months")
    print(f"  Subscription cost:        {format_dollars(api_quota_sub_cost)} (you pay this anyway)")
    print(f"  Overage cost:             $0.00")
    print(f"  Extra dollars beyond     ")
    print(f"  existing subscription:    $0.00 ✓")
    print(f"")
    print(f"--- Scenario 1: UI grinding (status quo) ---")
    print(f"  Same quota cap as #2 but operator clicks each gen manually.")
    print(f"  Calendar time:            {ui_months:.1f} months (operator-attention-bound)")
    print(f"  Subscription cost:        {format_dollars(ui_sub_cost)}")
    print(f"  Overage cost:             $0.00")
    print(f"  Extra dollars:            $0.00 (same as #2)")
    print(f"  Why prefer #2:            One weekend/mo > clicking every day")
    print(f"")
    print(f"--- Scenario 3: API + accept overage (burst) ---")
    print(f"  Fits the whole backlog in a single calendar month.")
    print(f"  Free quota used:          {APPRENTICE_MONTHLY_QUOTA:,} calls")
    print(f"  Overage calls:            {api_burst_overage_calls:,} × {format_dollars(args.price)}")
    print(f"  Overage cost:             {format_dollars(api_burst_overage_cost)}")
    print(f"  Subscription cost:        {format_dollars(api_burst_sub_cost)} (1 month)")
    print(f"  Wall time:                {format_hours(par_seconds)} batch ({args.parallel}× parallel)")
    print(f"  Extra dollars beyond     ")
    print(f"  existing subscription:    {format_dollars(api_burst_overage_cost)}")
    print(f"")
    print(f"--- Caveats ---")
    print(f"  1. The API requires the caller to supply skeleton_keypoints —")
    print(f"     see docs/plans/2026-05-14-pixellab-api-automation.md §Skeleton.")
    print(f"     The UI flow has skeletons baked in; the API does not.")
    print(f"     That dev cost is the same across scenarios 2 + 3.")
    print(f"  2. Retry premium is a v4-batch heuristic; first API runs may vary.")
    print(f"  3. Apprentice 'API access requires active subscription' confirmed")
    print(f"     via pixellab.ai/docs/faq 2026-05-14. Pricing assumes quota")
    print(f"     covers API calls; verify against first batch's invoice.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
