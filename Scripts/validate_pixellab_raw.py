#!/usr/bin/env python3
"""Pre-flight validator for raw PixelLab character export zips.

Catches the classes of issue that bite Phase 3 mass-gen
(`docs/pet-design/ai-brief/STATUS.md` §0.3) BEFORE the operator runs
`normalize-pixellab-zip.sh` + commits. Each issue prints a short
diagnosis + an actionable next step.

Usage:
    python3 Scripts/validate_pixellab_raw.py <raw-export.zip>

Exits 0 if the zip looks normalizable. Exits 1 if any FAIL-level issue
fires. Exits 2 on script-level errors (file not found, bad zip).

The same shape `normalize_pixellab.py` consumes, so the validator
shares the heuristic constants — keep `HEURISTIC_WALK_MIN_FRAMES`
synced if it ever changes there.
"""

import argparse
import json
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# Must mirror Scripts/normalize_pixellab.py.
HEURISTIC_WALK_MIN_FRAMES = 6
EXPECTED_FRAME_WIDTH = 68
EXPECTED_FRAME_HEIGHT = 68
EXPECTED_ROTATION_DIRECTIONS = {
    "south", "south-east", "east", "north-east",
    "north", "north-west", "west", "south-west",
}


@dataclass
class Finding:
    severity: str           # "OK" | "WARN" | "FAIL"
    code: str               # short identifier ("frame-size", "duplicate-walk")
    detail: str             # one-line human description
    suggestion: str = ""    # actionable next step, if any


@dataclass
class ValidationReport:
    findings: list[Finding] = field(default_factory=list)

    def add(self, severity: str, code: str, detail: str, suggestion: str = "") -> None:
        self.findings.append(Finding(severity, code, detail, suggestion))

    @property
    def has_failure(self) -> bool:
        return any(f.severity == "FAIL" for f in self.findings)


def validate(zip_path: Path) -> ValidationReport:
    report = ValidationReport()

    # ─── Open zip ────────────────────────────────────────────────────────
    try:
        zf = zipfile.ZipFile(zip_path, "r")
    except zipfile.BadZipFile as e:
        report.add("FAIL", "bad-zip", f"Cannot open as zip: {e}")
        return report

    with zf:
        names = set(zf.namelist())

        # ─── metadata.json ───────────────────────────────────────────────
        if "metadata.json" not in names:
            report.add("FAIL", "no-metadata",
                       "metadata.json is missing from the zip root.",
                       "Re-export from PixelLab; the export ZIP must contain metadata.json.")
            return report

        try:
            meta = json.loads(zf.read("metadata.json").decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            report.add("FAIL", "bad-metadata",
                       f"metadata.json is not valid JSON: {e}")
            return report

        # ─── Frame size ──────────────────────────────────────────────────
        char = meta.get("character", {})
        size = char.get("size", {})
        w, h = size.get("width"), size.get("height")
        if w == EXPECTED_FRAME_WIDTH and h == EXPECTED_FRAME_HEIGHT:
            report.add("OK", "frame-size", f"Frame size {w}×{h}.")
        elif w == 48 and h == 48:
            report.add("FAIL", "frame-size-48",
                       f"Frame size is 48×48 (PixelLab default for NEW characters).",
                       "Open the original 68×68 v4-era character ID instead. "
                       "Re-generating from a 'HAPPY EXPRESSION' variant creates a "
                       "48×48 character that breaks MainBundleAssetCoverageTests "
                       "(see STATUS.md §0.3).")
        else:
            report.add("FAIL", "frame-size-other",
                       f"Frame size {w}×{h} — expected {EXPECTED_FRAME_WIDTH}×{EXPECTED_FRAME_HEIGHT}.",
                       "Verify the character was opened from a v4-era 68×68 reference.")

        # ─── Rotations ───────────────────────────────────────────────────
        rotations = meta.get("frames", {}).get("rotations", {})
        present_dirs = set(rotations.keys())
        missing_dirs = EXPECTED_ROTATION_DIRECTIONS - present_dirs
        if missing_dirs:
            report.add("FAIL", "missing-rotations",
                       f"metadata declares only {len(present_dirs)}/8 rotation directions. "
                       f"Missing: {sorted(missing_dirs)}",
                       "Re-export — PixelLab should produce all 8 directions for a v4-era character.")
        else:
            # Verify the PNG files actually exist on disk.
            missing_files = [path for direction, path in rotations.items() if path not in names]
            if missing_files:
                report.add("FAIL", "missing-rotation-files",
                           f"metadata references {len(missing_files)} rotation PNG(s) not in the zip.",
                           "Re-export — the zip was created before all rotations rendered.")
            else:
                report.add("OK", "rotations", "All 8 rotation PNGs present.")

        # ─── Animations ──────────────────────────────────────────────────
        animations = meta.get("frames", {}).get("animations", {}) or {}
        if not animations:
            report.add("WARN", "no-animations",
                       "No animation slots — this zip will normalize as rotation-only (v3.0 with empty animations).",
                       "If you intended to add walk/idle, click 'Add Animation' in PixelLab first.")
        else:
            walk_slots: list[str] = []
            idle_slots: list[str] = []
            for slot_key, slot in animations.items():
                if not isinstance(slot, dict):
                    report.add("WARN", "bad-slot-shape",
                               f"Animation slot '{slot_key}' is not a directions map; normalize may fail.")
                    continue
                frame_counts = [len(v) for v in slot.values() if isinstance(v, list)]
                if not frame_counts:
                    report.add("WARN", "empty-slot",
                               f"Slot '{slot_key}' has no frames — will be dropped during normalize.")
                    continue
                first_count = frame_counts[0]
                if first_count >= HEURISTIC_WALK_MIN_FRAMES:
                    walk_slots.append(slot_key)
                else:
                    idle_slots.append(slot_key)
                # Per-slot direction sanity
                slot_dirs = set(slot.keys())
                missing_slot_dirs = EXPECTED_ROTATION_DIRECTIONS - slot_dirs
                if missing_slot_dirs:
                    report.add("WARN", "slot-missing-dirs",
                               f"Slot '{slot_key}' ({first_count} fps) only covers "
                               f"{len(slot_dirs)}/8 directions. Missing: {sorted(missing_slot_dirs)}",
                               "Acceptable — SpriteService falls back to the rotation PNG for missing directions (commit dd1a7ba's C1 fix).")

            if len(walk_slots) > 1:
                report.add("WARN", "duplicate-walk",
                           f"Detected {len(walk_slots)} walk-shaped slots: {walk_slots}. "
                           "normalize_pixellab.py will keep the newest mtime + most frames; "
                           "the rest are dropped.",
                           "Confirm the kept slot is the one you intended.")
            if len(idle_slots) > 1:
                report.add("WARN", "duplicate-idle",
                           f"Detected {len(idle_slots)} idle-shaped slots: {idle_slots}. "
                           "Same dedup rules as walk apply.")
            if walk_slots and idle_slots:
                report.add("OK", "walk-idle-pair",
                           f"Found 1+ walk slot + 1+ idle slot — full v3 animation coverage after normalize.")
            elif walk_slots:
                report.add("WARN", "walk-only",
                           "Found walk but no idle slot — final zip will animate walk only.",
                           "Add an Idle animation in PixelLab before re-exporting if you want both.")
            elif idle_slots:
                report.add("WARN", "idle-only",
                           "Found idle but no walk slot — final zip will animate idle only.")

            # Verify per-frame PNG files exist on disk for each slot's directions.
            for slot_key, slot in animations.items():
                if not isinstance(slot, dict):
                    continue
                missing_frames = 0
                for paths in slot.values():
                    if isinstance(paths, list):
                        missing_frames += sum(1 for p in paths if p not in names)
                if missing_frames:
                    report.add("FAIL", "missing-frame-files",
                               f"Slot '{slot_key}' references {missing_frames} frame PNG(s) not in the zip.",
                               "Re-export — some frames didn't render before the export.")

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a raw PixelLab export zip before normalize.")
    parser.add_argument("zip_path", type=Path, help="Path to the raw PixelLab export zip.")
    args = parser.parse_args()

    if not args.zip_path.is_file():
        print(f"error: {args.zip_path} does not exist", file=sys.stderr)
        return 2

    report = validate(args.zip_path)

    # Sort findings so FAIL > WARN > OK on output for at-a-glance scanning.
    severity_rank = {"FAIL": 0, "WARN": 1, "OK": 2}
    for f in sorted(report.findings, key=lambda x: (severity_rank[x.severity], x.code)):
        prefix = {"FAIL": "❌", "WARN": "⚠️ ", "OK": "✅"}[f.severity]
        print(f"{prefix} [{f.severity:4}] {f.code}: {f.detail}")
        if f.suggestion:
            print(f"      → {f.suggestion}")

    if report.has_failure:
        print()
        print("This zip is NOT ready for normalize-pixellab-zip.sh. Fix the FAIL items first.", file=sys.stderr)
        return 1
    print()
    print("This zip looks ready for normalize-pixellab-zip.sh.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
