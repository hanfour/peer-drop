#!/usr/bin/env python3
"""Generate the v5 multi-frame coverage report from the bundled assets.

Walks `PeerDrop/Resources/Pets/`, classifies every zip by its
`export_version` + atlas presence, groups by species family, and emits
a Markdown report. Complements `compute_v5_coverage.sh` (which is a
single-line shields.io badge JSON) by providing the detailed
breakdown an operator uses to plan the next PixelLab batch.

Usage:
    python3 Scripts/coverage_report.py
        # prints to stdout

    python3 Scripts/coverage_report.py --write
        # writes to docs/pet-design/ai-brief/COVERAGE.md
"""

import argparse
import json
import sys
import zipfile
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parent.parent
PETS_DIR = REPO_ROOT / "PeerDrop" / "Resources" / "Pets"
COVERAGE_MD = REPO_ROOT / "docs" / "pet-design" / "ai-brief" / "COVERAGE.md"


@dataclass
class ZipInfo:
    """Per-zip facts extracted from the bundled .zip — single pass, no I/O on revisit."""
    name: str              # filename minus .zip (e.g. "cat-tabby-adult")
    family: str            # "cat"
    variety: Optional[str] # "tabby" or None for family-only zips
    stage: Optional[str]   # "adult" / "baby" / "elder" / None
    export_version: str    # "2.0" or "3.0" — empty if metadata.json missing
    has_atlas: bool        # true iff atlas.json + atlas.png both present
    size_bytes: int        # on-disk file size (post-atlas-strip, if applied)


def parse_zip_name(filename: str) -> tuple[str, Optional[str], Optional[str]]:
    """Split `cat-tabby-adult` into (family, variety, stage). Handles two
    real shapes:
      - `<family>-<variety>-<stage>`  →  ("cat", "tabby", "adult")
      - `<family>-<stage>`            →  ("cat", None, "adult")
        (the legacy "single-asset family" shape; rare in practice)
    """
    name = filename.removesuffix(".zip")
    parts = name.split("-")
    stages = {"adult", "baby", "elder"}
    if len(parts) >= 3 and parts[-1] in stages:
        return ("-".join(parts[:-2]) if len(parts) > 3 else parts[0],
                parts[-2],
                parts[-1])
    if len(parts) == 2 and parts[-1] in stages:
        return (parts[0], None, parts[-1])
    # Fallback for anything else: treat the whole thing as the family.
    return (name, None, None)


def inspect_zip(path: Path) -> ZipInfo:
    """Single-pass zip inspection. Skips per-frame extraction — only reads
    metadata.json + checks for the atlas pair."""
    family, variety, stage = parse_zip_name(path.name)
    export_version = ""
    has_atlas = False
    try:
        with zipfile.ZipFile(path, "r") as zf:
            names = set(zf.namelist())
            has_atlas = "atlas.json" in names and "atlas.png" in names
            if "metadata.json" in names:
                try:
                    raw = zf.read("metadata.json").decode("utf-8")
                    obj = json.loads(raw)
                    export_version = str(obj.get("export_version", ""))
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass
    except zipfile.BadZipFile:
        pass

    return ZipInfo(
        name=path.stem,
        family=family,
        variety=variety,
        stage=stage,
        export_version=export_version,
        has_atlas=has_atlas,
        size_bytes=path.stat().st_size,
    )


def build_report(infos: list[ZipInfo]) -> str:
    """Render the Markdown report. Stays plain text so the file is friendly
    in a terminal grep + works as a GitHub-rendered page."""
    total = len(infos)
    v5 = [i for i in infos if i.export_version == "3.0"]
    v2 = [i for i in infos if i.export_version == "2.0"]
    other = [i for i in infos if i.export_version not in {"2.0", "3.0"}]
    atlased = [i for i in infos if i.has_atlas]

    pct = lambda n, d: (100 * n / d) if d else 0.0

    lines: list[str] = []
    lines.append("# v5 Multi-Frame Coverage Report")
    lines.append("")
    lines.append(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    lines.append("Source: `PeerDrop/Resources/Pets/`")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- **Total zips:** {total}")
    lines.append(f"- **At v5 (multi-frame walk + idle):** {len(v5)} ({pct(len(v5), total):.1f}%)")
    lines.append(f"- **At v2 (rotation-only, awaiting mass-gen):** {len(v2)} ({pct(len(v2), total):.1f}%)")
    if other:
        lines.append(f"- **Other / unparseable:** {len(other)}")
    lines.append(f"- **Atlas-converted (size-optimized):** {len(atlased)} of {len(v5)} v5 zips ({pct(len(atlased), len(v5)):.1f}%)")
    total_bytes = sum(i.size_bytes for i in infos)
    lines.append(f"- **Total bundled bytes:** {total_bytes:,} ({total_bytes / 1024:.1f} KiB)")
    lines.append("")

    lines.append("## Per-family breakdown")
    lines.append("")
    lines.append("| Family | Total | v5 | v2 | % v5 | Atlas |")
    lines.append("|---|---:|---:|---:|---:|---:|")

    by_family: dict[str, list[ZipInfo]] = defaultdict(list)
    for info in infos:
        by_family[info.family].append(info)

    for family in sorted(by_family):
        bucket = by_family[family]
        f_total = len(bucket)
        f_v5 = sum(1 for i in bucket if i.export_version == "3.0")
        f_v2 = sum(1 for i in bucket if i.export_version == "2.0")
        f_atlas = sum(1 for i in bucket if i.has_atlas)
        lines.append(
            f"| `{family}` | {f_total} | {f_v5} | {f_v2} | "
            f"{pct(f_v5, f_total):.0f}% | {f_atlas} |"
        )
    lines.append("")

    if v5:
        lines.append("## v5-ready zips")
        lines.append("")
        for info in sorted(v5, key=lambda i: i.name):
            atlas_mark = " (atlas)" if info.has_atlas else ""
            lines.append(f"- `{info.name}`{atlas_mark} — {info.size_bytes:,} bytes")
        lines.append("")

    # Next-batch priorities: families with a v5-shipped variety already
    # benefit most from siblings (users who saw the shipped one expect
    # their other pets to match). Then by family size descending so a
    # popular family gets full coverage sooner.
    if len(v5) < total:
        lines.append("## Suggested next batch")
        lines.append("")
        lines.append("Heuristic ranks species×stages by:")
        lines.append("  1. Family already has a v5-shipped zip (sibling parity beats first-of-kind).")
        lines.append("  2. Stage = adult (the most-time-spent stage in playthroughs).")
        lines.append("  3. Family size descending (popular family → broader impact).")
        lines.append("")
        v5_families = {i.family for i in v5}
        stage_score = {"adult": 0, "baby": 1, "elder": 2}
        family_size = {f: len(bs) for f, bs in by_family.items()}
        ranked = sorted(
            [i for i in v2 if i.stage],
            key=lambda i: (
                0 if i.family in v5_families else 1,
                stage_score.get(i.stage or "", 99),
                -family_size.get(i.family, 0),
                i.name,
            ),
        )
        for info in ranked[:12]:
            tag = "🎯" if info.family in v5_families else "  "
            lines.append(f"- {tag} `{info.name}`")
        if len(ranked) > 12:
            lines.append(f"- … and {len(ranked) - 12} more")
        lines.append("")
        lines.append("🎯 = family already has a v5 sibling")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Report v5 coverage of bundled pet assets.")
    parser.add_argument(
        "--write",
        action="store_true",
        help=f"Write to {COVERAGE_MD.relative_to(REPO_ROOT)} instead of stdout.",
    )
    args = parser.parse_args()

    if not PETS_DIR.is_dir():
        print(f"error: pets dir not found: {PETS_DIR}", file=sys.stderr)
        return 2

    zips = sorted(PETS_DIR.glob("*.zip"))
    if not zips:
        print(f"error: no zips found under {PETS_DIR}", file=sys.stderr)
        return 2

    infos = [inspect_zip(p) for p in zips]
    report = build_report(infos)

    if args.write:
        COVERAGE_MD.parent.mkdir(parents=True, exist_ok=True)
        COVERAGE_MD.write_text(report + "\n")
        print(f"wrote {len(report.splitlines())} lines to {COVERAGE_MD}")
    else:
        print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
