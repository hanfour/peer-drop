#!/usr/bin/env python3
"""Monthly mass-gen batch runner.

Reads the current bundle state via `coverage_report`'s scan logic,
picks the next N species×stages that fit in the Apprentice tier's
remaining monthly quota, runs `gen_pixellab_zip.generate()` for each,
and emits a punch list of follow-up commands for the operator (one
`Scripts/drop_v5_zip.sh` invocation per generated zip, plus the
`expectedV5Coverage` whitelist edit).

The script never touches the bundle directly — it writes outputs to a
staging directory the operator inspects + drops manually. This is
deliberate: a bad batch shouldn't auto-corrupt the production zips,
and the operator should eyeball at least one species's animation
output before piping the rest in.

Usage:
    PIXELLAB_API_KEY=pl-... python3 Scripts/run_monthly_batch.py \\
        --quota 2000                                              \\
        --staging /tmp/mass-gen-2026-05

    # Dry-run (plan only, no API calls):
    python3 Scripts/run_monthly_batch.py --quota 2000 --plan-only
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from coverage_report import inspect_zip
from gen_pixellab_zip import generate, GenReport


REPO_ROOT = Path(__file__).resolve().parent.parent
PETS_DIR = REPO_ROOT / "PeerDrop" / "Resources" / "Pets"
WHITELIST_FILE = REPO_ROOT / "PeerDropTests" / "Pet" / "MainBundleAssetCoverageTests.swift"

CALLS_PER_SPECIES = 112   # 8 estimate-skeleton + 64 walk + 40 idle
QUOTA_SAFETY_BUFFER = 50  # leave room for retries / a stuck species


@dataclass
class BatchPlan:
    candidates: list[str]
    fit_in_quota: int
    calls_planned: int
    quota: int

    @property
    def calls_remaining(self) -> int:
        return self.quota - self.calls_planned


def collect_v2_species(pets_dir: Path = PETS_DIR) -> list[str]:
    """Return all bundled v2.0 zips, ordered for the next-batch priority
    (mirrors coverage_report's heuristic: sibling-of-shipped first →
    adult stage → family size descending → alphabetical tiebreak)."""
    infos = [inspect_zip(p) for p in sorted(pets_dir.glob("*.zip"))]
    v5_families = {i.family for i in infos if i.export_version == "3.0"}
    v2 = [i for i in infos if i.export_version == "2.0"]

    family_size: dict[str, int] = {}
    for info in infos:
        family_size[info.family] = family_size.get(info.family, 0) + 1

    stage_score = {"adult": 0, "baby": 1, "elder": 2}

    def rank(i):
        return (
            0 if i.family in v5_families else 1,
            stage_score.get(i.stage or "", 99),
            -family_size.get(i.family, 0),
            i.name,
        )
    return [i.name for i in sorted(v2, key=rank)]


def plan_batch(
    quota: int,
    *,
    overrides: list[str] | None = None,
    calls_per_species: int = CALLS_PER_SPECIES,
    safety_buffer: int = QUOTA_SAFETY_BUFFER,
) -> BatchPlan:
    """Pick how many candidates fit under (quota - safety_buffer). If
    `overrides` is supplied (operator wants a specific list), use that
    instead of the priority heuristic."""
    candidates = overrides if overrides else collect_v2_species()
    usable = max(0, quota - safety_buffer)
    fit = min(len(candidates), usable // calls_per_species)
    return BatchPlan(
        candidates=candidates,
        fit_in_quota=fit,
        calls_planned=fit * calls_per_species,
        quota=quota,
    )


def print_plan(plan: BatchPlan) -> None:
    print("=== Monthly batch plan ===")
    print(f"  Total v2 zips remaining:   {len(plan.candidates)}")
    print(f"  Quota:                     {plan.quota:,} calls")
    print(f"  Safety buffer:             {QUOTA_SAFETY_BUFFER} calls")
    print(f"  Calls per species:         {CALLS_PER_SPECIES}")
    print(f"  Species this batch:        {plan.fit_in_quota}")
    print(f"  Calls planned:             {plan.calls_planned:,}")
    print(f"  Quota remaining after:     {plan.calls_remaining:,}")
    print(f"")
    print("Planned species (top of priority queue):")
    for name in plan.candidates[:plan.fit_in_quota]:
        print(f"  - {name}")
    if plan.fit_in_quota < len(plan.candidates):
        print(f"  ... {len(plan.candidates) - plan.fit_in_quota} more deferred to next month")


def run_batch(
    plan: BatchPlan,
    staging_dir: Path,
    client,
) -> list[GenReport]:
    """Generate each planned species → staging_dir. Returns the list of
    reports (one per species, in plan order)."""
    staging_dir.mkdir(parents=True, exist_ok=True)
    reports: list[GenReport] = []
    for name in plan.candidates[:plan.fit_in_quota]:
        out = staging_dir / f"{name}-raw.zip"
        print(f"  → generating {name} ...", flush=True)
        report = generate(name, client=client, output_path=out)
        reports.append(report)
        marker = "✓" if not report.errors and report.output_path and report.output_path.is_file() else "✗"
        print(f"     {marker} {report.api_calls} API calls; {report.frames_written} frames",
              flush=True)
        if report.errors:
            for e in report.errors:
                print(f"       ! {e}", file=sys.stderr)
    return reports


def print_followup(reports: list[GenReport], staging_dir: Path) -> None:
    """Operator post-batch checklist + commands to copy/paste."""
    ok = [r for r in reports if not r.errors and r.output_path and r.output_path.is_file()]
    bad = [r for r in reports if r.errors]
    total_api = sum(r.api_calls for r in reports)
    print(f"")
    print(f"=== Batch summary ===")
    print(f"  Generated:                 {len(ok)}/{len(reports)}")
    print(f"  Total API calls used:      {total_api}")
    if bad:
        print(f"  Failed species:            {[r.species_stage for r in bad]}")
    print(f"")
    if ok:
        print(f"=== Next steps ===")
        print(f"Inspect at least one zip visually (open frame PNGs) before bulk-")
        print(f"committing. Then per generated zip:")
        print(f"")
        for r in ok:
            print(f"  Scripts/drop_v5_zip.sh {r.output_path} {r.species_stage}")
        print(f"")
        print(f"After all drop_v5_zip.sh complete, add to the whitelist:")
        print(f"  {WHITELIST_FILE.relative_to(REPO_ROOT)}")
        print(f"")
        for r in ok:
            print(f'      "{r.species_stage}",')
        print(f"")
        print(f"Then test + commit:")
        print(f"  xcodebuild test -only-testing:PeerDropTests/Pet/MainBundleAssetCoverageTests")
        print(f"  git add PeerDrop/Resources/Pets/*.zip "
              f"PeerDropTests/Pet/MainBundleAssetCoverageTests.swift "
              f"docs/pet-design/ai-brief/COVERAGE.md")
        print(f"  python3 Scripts/coverage_report.py --write")
        print(f'  git commit -m "asset(v5): mass-gen batch — {len(ok)} species via API"')


def main() -> int:
    parser = argparse.ArgumentParser(description="Plan + run a monthly mass-gen batch via the PixelLab API.")
    parser.add_argument("--quota", type=int, default=2000,
                        help="Apprentice tier monthly quota. Default: 2000.")
    parser.add_argument("--staging", type=Path, default=Path("/tmp/mass-gen-staging"),
                        help="Directory for generated raw zips (NOT the production bundle).")
    parser.add_argument("--plan-only", action="store_true",
                        help="Show the plan without making API calls.")
    parser.add_argument("--species", nargs="+", default=None,
                        help="Override the priority queue with explicit species×stage names.")
    args = parser.parse_args()

    plan = plan_batch(quota=args.quota, overrides=args.species)
    print_plan(plan)

    if args.plan_only:
        print("")
        print("(--plan-only specified, exiting before API calls)")
        return 0

    if plan.fit_in_quota == 0:
        print("nothing to run (quota too small for one species).", file=sys.stderr)
        return 0

    # Lazy import — `--help` and `--plan-only` work without an API key.
    from pixellab_client import PixelLabClient, PixelLabError
    try:
        client = PixelLabClient()
    except PixelLabError as e:
        print(f"error: {e}", file=sys.stderr)
        print("set PIXELLAB_API_KEY in your environment.", file=sys.stderr)
        return 1

    reports = run_batch(plan, args.staging, client)
    print_followup(reports, args.staging)
    return 0 if all(not r.errors for r in reports) else 2


if __name__ == "__main__":
    raise SystemExit(main())
