#!/usr/bin/env python3
"""Generate a PixelLab-shaped raw zip for one species×stage via the API.

Reads the existing v4 rotation-only zip in `PeerDrop/Resources/Pets/`,
estimates a per-direction skeleton, then renders walk (8 frames) +
idle (5 frames) for each of 8 directions by perturbing the skeleton
through `skeleton_animator.perturb` and calling
`/animate-with-skeleton` once per frame. Final output mimics what the
PixelLab UI emits, so the existing `Scripts/normalize-pixellab-zip.sh`
+ `Scripts/drop_v5_zip.sh` cadence picks up from here without
modification.

Per-species API call count: **112 calls**
  - 8 directions × 1 estimate-skeleton  = 8
  - 8 directions × 8 walk frames        = 64
  - 8 directions × 5 idle frames        = 40

That's ~17 species/month if you cap at the 2000/mo Apprentice quota
(see `Scripts/pixellab_cost.py` for the full budget table).

Usage:
    PIXELLAB_API_KEY=pl-... python3 Scripts/gen_pixellab_zip.py \\
        cat-bengal-adult                    \\
        --out /tmp/cat-bengal-adult-raw.zip

The output zip is the RAW PixelLab shape (v2.0 schema, UUID-keyed
animation slots, no fps/loops). Run `Scripts/drop_v5_zip.sh` on it
next; that handles normalize → atlas → bundle drop.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

# Add the script dir so sibling modules import cleanly.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from skeleton_animator import (
    Keypoint as AnimatorKeypoint,
    frames_for_action,
    fps_for_action,
    perturb,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
PETS_DIR = REPO_ROOT / "PeerDrop" / "Resources" / "Pets"

DIRECTIONS = (
    "south", "south-east", "east", "north-east",
    "north", "north-west", "west", "south-west",
)
ACTIONS = ("walk", "idle")
DEFAULT_IMAGE_SIZE = (68, 68)


@dataclass
class GenReport:
    species_stage: str
    api_calls: int = 0
    frames_written: int = 0
    output_path: Optional[Path] = None
    skipped_directions: list[str] = None
    errors: list[str] = None

    def __post_init__(self) -> None:
        if self.skipped_directions is None:
            self.skipped_directions = []
        if self.errors is None:
            self.errors = []


# =====================================================================
# Source loading
# =====================================================================


def source_zip_path(species_stage: str) -> Path:
    """Locate the existing v4 zip for this species×stage."""
    return PETS_DIR / f"{species_stage}.zip"


def extract_rotations(zip_path: Path) -> dict[str, bytes]:
    """Pull the 8 rotation PNGs out of the source zip. Returns a
    {direction: png_bytes} map; missing directions are simply absent
    from the map (caller decides whether to skip or fall back)."""
    out: dict[str, bytes] = {}
    with zipfile.ZipFile(zip_path, "r") as zf:
        for d in DIRECTIONS:
            path = f"rotations/{d}.png"
            try:
                out[d] = zf.read(path)
            except KeyError:
                pass
    return out


# =====================================================================
# API client adapter
# =====================================================================
#
# Decoupled here so tests can inject a mock without dragging the real
# `pixellab_client` into the unit-test deps. The animator module's
# `Keypoint` is structurally identical to the client's — we convert
# at the boundary via duck-typing.


class ClientProtocol:
    """Minimal interface gen_pixellab_zip.py needs from a PixelLab client.
    `pixellab_client.PixelLabClient` satisfies this; tests inject fakes."""

    def estimate_skeleton(self, *, image_bytes: bytes, image_size: tuple[int, int]):
        ...

    def animate_with_skeleton(
        self,
        *,
        reference_image_bytes: bytes,
        image_size: tuple[int, int],
        skeleton_keypoints: list,
        view: str = "side",
        direction: str = "east",
        guidance_scale: float = 4.0,
        seed: Optional[int] = None,
    ) -> bytes:
        ...


def _to_animator_keypoint(client_kp) -> AnimatorKeypoint:
    """Bridge from `pixellab_client.Keypoint` to the animator's local
    dataclass. Both are frozen + structurally identical, but the
    animator module avoids importing the client so its tests don't
    require an API key."""
    return AnimatorKeypoint(
        x=client_kp.x, y=client_kp.y, label=client_kp.label, z_index=client_kp.z_index,
    )


def _to_client_keypoint_dict(animator_kp: AnimatorKeypoint) -> dict:
    """Serialize an animator keypoint to the dict shape the client
    layer marshals to JSON. Use this instead of importing the client's
    Keypoint class to keep the test surface narrow."""
    return {
        "x": animator_kp.x,
        "y": animator_kp.y,
        "label": animator_kp.label,
        "z_index": animator_kp.z_index,
    }


# =====================================================================
# Per-direction rendering
# =====================================================================


def render_direction(
    client: ClientProtocol,
    direction: str,
    rotation_png: bytes,
    image_size: tuple[int, int],
    report: GenReport,
) -> dict[str, list[tuple[int, bytes]]]:
    """Render all walk + idle frames for one direction. Returns
    `{action: [(frame_index, png_bytes), …]}`. Logs API call count
    into the shared report."""
    # 1. Estimate base skeleton from the reference rotation.
    raw_skeleton = client.estimate_skeleton(image_bytes=rotation_png, image_size=image_size)
    report.api_calls += 1
    base = [_to_animator_keypoint(kp) for kp in raw_skeleton]
    if not base:
        report.skipped_directions.append(direction)
        report.errors.append(
            f"{direction}: /estimate-skeleton returned 0 keypoints; "
            "this direction will be omitted from the output zip."
        )
        return {}

    out: dict[str, list[tuple[int, bytes]]] = {a: [] for a in ACTIONS}
    for action in ACTIONS:
        n_frames = frames_for_action(action)
        for frame_idx in range(n_frames):
            perturbed_kps = perturb(base, action, frame_idx)
            # The client's Keypoint shape is structurally identical to
            # the animator's, so we forward the dict directly (the
            # client's `as_payload` would do the same conversion).
            from pixellab_client import Keypoint as ClientKeypoint
            client_kps = [
                ClientKeypoint(x=kp.x, y=kp.y, label=kp.label, z_index=kp.z_index)
                for kp in perturbed_kps
            ]
            png = client.animate_with_skeleton(
                reference_image_bytes=rotation_png,
                image_size=image_size,
                skeleton_keypoints=client_kps,
                direction=direction,
            )
            out[action].append((frame_idx, png))
            report.api_calls += 1
            report.frames_written += 1
    return out


# =====================================================================
# Zip assembly
# =====================================================================


def build_raw_zip(
    output_path: Path,
    rotations: dict[str, bytes],
    rendered: dict[str, dict[str, list[tuple[int, bytes]]]],
    image_size: tuple[int, int],
) -> None:
    """Write the PixelLab-shaped raw zip:
      - rotations/<direction>.png        (8 files from the source v4 zip)
      - animations/<uuid>/<direction>/frame_NNN.png
      - metadata.json with v2.0 schema + UUID-keyed animation slots

    `rendered[direction][action]` is the list of frames for that
    direction/action.
    """
    # Assign one UUID per action — the normalizer (heuristic_action +
    # mtime tiebreaker) will identify them as walk/idle by frame count.
    action_uuids = {action: f"animation-{uuid.uuid4().hex[:8]}" for action in ACTIONS}

    meta = {
        "character": {
            "id": uuid.uuid4().hex,
            "size": {"width": image_size[0], "height": image_size[1]},
            "directions": 8,
        },
        "frames": {
            "rotations": {d: f"rotations/{d}.png" for d in rotations},
            "animations": {},
        },
        "export_version": "2.0",
        "_generated_by": "Scripts/gen_pixellab_zip.py",
    }

    for action, uuid_key in action_uuids.items():
        slot: dict[str, list[str]] = {}
        for direction, action_frames in rendered.items():
            action_list = action_frames.get(action, [])
            if not action_list:
                continue
            slot[direction] = [
                f"animations/{uuid_key}/{direction}/frame_{frame_idx:03d}.png"
                for frame_idx, _ in action_list
            ]
        if slot:
            meta["frames"]["animations"][uuid_key] = slot

    with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("metadata.json", json.dumps(meta, indent=2))
        for direction, png in rotations.items():
            zf.writestr(f"rotations/{direction}.png", png)
        for action, uuid_key in action_uuids.items():
            for direction, action_frames in rendered.items():
                for frame_idx, png in action_frames.get(action, []):
                    zf.writestr(
                        f"animations/{uuid_key}/{direction}/frame_{frame_idx:03d}.png",
                        png,
                    )


# =====================================================================
# Top-level orchestrator
# =====================================================================


def generate(
    species_stage: str,
    *,
    client: ClientProtocol,
    output_path: Path,
    image_size: tuple[int, int] = DEFAULT_IMAGE_SIZE,
) -> GenReport:
    """Generate one species×stage zip via the API. Returns a `GenReport`
    suitable for printing or aggregating across a batch run."""
    report = GenReport(species_stage=species_stage, output_path=output_path)
    src = source_zip_path(species_stage)
    if not src.is_file():
        report.errors.append(f"source zip not found: {src}")
        return report
    rotations = extract_rotations(src)
    if not rotations:
        report.errors.append(f"no rotations in source zip: {src}")
        return report

    rendered: dict[str, dict[str, list[tuple[int, bytes]]]] = {}
    for direction, png in rotations.items():
        rendered[direction] = render_direction(
            client=client,
            direction=direction,
            rotation_png=png,
            image_size=image_size,
            report=report,
        )

    if not any(rendered.values()):
        report.errors.append(
            "no frames rendered — every direction was skipped or errored. "
            "Check the /estimate-skeleton responses logged above."
        )
        return report

    build_raw_zip(output_path, rotations, rendered, image_size)
    return report


# =====================================================================
# CLI
# =====================================================================


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a PixelLab-shaped raw zip for one species×stage via the API."
    )
    parser.add_argument("species_stage", help="e.g. cat-bengal-adult")
    parser.add_argument("--out", type=Path, required=True,
                        help="Output path for the raw zip.")
    parser.add_argument("--size", type=int, default=DEFAULT_IMAGE_SIZE[0],
                        help=f"Frame size (square). Default: {DEFAULT_IMAGE_SIZE[0]}")
    args = parser.parse_args()

    # Lazy import — only needed when actually hitting the API. Keeps
    # `--help` working when PIXELLAB_API_KEY is unset.
    from pixellab_client import PixelLabClient, PixelLabError
    try:
        client = PixelLabClient()
    except PixelLabError as e:
        print(f"error: {e}", file=sys.stderr)
        print("set PIXELLAB_API_KEY in your environment.", file=sys.stderr)
        return 1

    report = generate(
        args.species_stage,
        client=client,
        output_path=args.out,
        image_size=(args.size, args.size),
    )

    print(f"species_stage: {report.species_stage}")
    print(f"  API calls used:   {report.api_calls}")
    print(f"  frames rendered:  {report.frames_written}")
    if report.output_path and report.output_path.is_file():
        print(f"  output:           {report.output_path}")
    if report.skipped_directions:
        print(f"  skipped dirs:     {report.skipped_directions}")
    if report.errors:
        print("ERRORS:", file=sys.stderr)
        for e in report.errors:
            print(f"  - {e}", file=sys.stderr)
        return 2 if not report.output_path or not report.output_path.is_file() else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
