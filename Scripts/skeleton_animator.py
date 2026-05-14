"""Walk / idle perturbation math for PixelLab `/animate-with-skeleton`.

Pure functions, no I/O, no API calls. Takes a base skeleton (estimated
once per direction via `/estimate-skeleton`) and returns the perturbed
keypoint list for one specific frame of a walk or idle cycle.

Design intent: the math is the same animation any 2D platformer uses —
limb rotation + body bob — applied to whatever joint labels PixelLab's
estimator returns. Generic enough to handle chibi quadrupeds, bipeds,
and the no-legged-blob species (slime, octopus) by gracefully skipping
keypoints whose label patterns aren't present.

Frame counts mirror the rest of the v5 pipeline:
  - walk:  8 frames @ 6 fps  (one full cycle)
  - idle:  5 frames @ 2 fps  (subtle loop)
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace
from typing import Callable, Iterable, Sequence


# Re-import the Keypoint dataclass from the API client so both modules
# share the same type. Tests don't import the client (we don't want
# them to hit the network on test machines without an API key) so the
# definition is duplicated here as a stand-alone dataclass and the
# orchestrator just passes objects through.

@dataclass(frozen=True)
class Keypoint:
    """One joint. Matches `pixellab_client.Keypoint` field-for-field;
    they're API-compatible via duck typing. Frozen so perturbation has
    to go through `replace()` and never mutates the caller's input."""
    x: float
    y: float
    label: str
    z_index: int = 0


# =====================================================================
# Frame counts + fps (must match normalize_pixellab.py + AssetSpec.swift)
# =====================================================================

WALK_FRAMES = 8
WALK_FPS = 6
IDLE_FRAMES = 5
IDLE_FPS = 2


# =====================================================================
# Label classifier — generic enough to handle whatever vocabulary
# PixelLab's estimator returns.
# =====================================================================

# Patterns we look for. Listed in order of specificity so a label like
# "left_front_paw" matches "paw" but also rejects matching just "left".
PAW_PATTERNS = ("paw", "foot", "ankle")
KNEE_PATTERNS = ("knee", "shin")
HIP_PATTERNS = ("hip", "thigh")
TORSO_PATTERNS = ("torso", "body", "spine", "chest")
HEAD_PATTERNS = ("head", "skull", "nose")
TAIL_PATTERNS = ("tail",)


def _label_matches(label: str, patterns: Sequence[str]) -> bool:
    """Case-insensitive substring match. Empty label never matches."""
    if not label:
        return False
    lower = label.lower()
    return any(p in lower for p in patterns)


def is_paw(kp: Keypoint) -> bool:
    return _label_matches(kp.label, PAW_PATTERNS)


def is_knee(kp: Keypoint) -> bool:
    return _label_matches(kp.label, KNEE_PATTERNS)


def is_hip(kp: Keypoint) -> bool:
    return _label_matches(kp.label, HIP_PATTERNS)


def is_torso(kp: Keypoint) -> bool:
    return _label_matches(kp.label, TORSO_PATTERNS)


def is_head(kp: Keypoint) -> bool:
    return _label_matches(kp.label, HEAD_PATTERNS)


def is_tail(kp: Keypoint) -> bool:
    return _label_matches(kp.label, TAIL_PATTERNS)


def _is_left(kp: Keypoint) -> bool:
    """Best-effort side detection. Falls back to x-coordinate
    comparison only if the label is silent on side."""
    lower = kp.label.lower()
    if "left" in lower:
        return True
    if "right" in lower:
        return False
    # No side hint — undefined. Walk phase pairs need explicit sides;
    # silent-side keypoints get no phase shift (treated as centerline).
    return False


def _is_right(kp: Keypoint) -> bool:
    lower = kp.label.lower()
    if "right" in lower:
        return True
    if "left" in lower:
        return False
    return False


def _is_front(kp: Keypoint) -> bool:
    lower = kp.label.lower()
    return "front" in lower or "fore" in lower


def _is_back(kp: Keypoint) -> bool:
    lower = kp.label.lower()
    return "back" in lower or "rear" in lower or "hind" in lower


# =====================================================================
# Walk cycle
# =====================================================================
#
# For a quadruped: opposite-phase limb pairs. The classic "diagonal
# couplets" gait used in most platformer animations:
#   - Front-Left + Rear-Right in phase A
#   - Front-Right + Rear-Left in phase B (offset by π)
# Each phase swings the paw forward/back via a sine wave on the
# horizontal axis, with a half-amplitude vertical lift at peak swing.
#
# Bipeds (parrot, penguin, owl) get the same math degenerate — they
# only have two legs but the front-vs-back split is missing, so the
# left-right pair swings opposite.
#
# Blobs (slime, octopus) typically lack paw labels entirely; the math
# below gracefully no-ops on them, leaving the body bob as the only
# visible motion. Acceptable degenerate case.

# Pixel amplitudes tuned for 68×68 chibi sprites. Tweak per archetype
# if a species reads "too floppy" or "too stiff" in visual review.
WALK_PAW_SWING_PX = 2.0       # horizontal swing
WALK_PAW_LIFT_PX = 1.5        # vertical lift at peak
WALK_BODY_BOB_PX = 0.5        # body sine bob
WALK_HEAD_BOB_PX = 0.8


def walk_phase(frame_index: int, total_frames: int = WALK_FRAMES) -> float:
    """Convert frame index 0..N-1 to a phase angle 0..2π."""
    return 2.0 * math.pi * (frame_index % total_frames) / total_frames


def perturb_walk(base: Iterable[Keypoint], frame_index: int) -> list[Keypoint]:
    """Return the keypoints for one walk-cycle frame. Pure function —
    `base` is not modified."""
    phase = walk_phase(frame_index)
    body_offset_y = -WALK_BODY_BOB_PX * math.sin(2 * phase)  # 2 bobs per cycle
    head_offset_y = -WALK_HEAD_BOB_PX * math.sin(2 * phase)

    out: list[Keypoint] = []
    for kp in base:
        if is_paw(kp) or is_knee(kp):
            out.append(_swing_limb(kp, phase))
        elif is_torso(kp) or is_hip(kp):
            out.append(replace(kp, y=kp.y + body_offset_y))
        elif is_head(kp):
            out.append(replace(kp, y=kp.y + head_offset_y))
        elif is_tail(kp):
            # Tail traces a small horizontal wag at body cadence. Uses
            # sin (not cos) so frame 0 starts at the neutral pose —
            # callers rely on `perturb_walk(base, 0) == base` so the
            # "first frame matches the base rotation PNG" invariant
            # holds for assembling output zips.
            out.append(replace(kp, x=kp.x + 0.6 * math.sin(phase)))
        else:
            out.append(replace(kp))
    return out


def _swing_limb(kp: Keypoint, phase: float) -> Keypoint:
    """Phase-shift the paw/knee per its side+position. Centerline
    keypoints (no side info) don't swing."""
    side_phase: float
    if _is_front(kp) and _is_left(kp):
        side_phase = phase
    elif _is_back(kp) and _is_right(kp):
        side_phase = phase
    elif _is_front(kp) and _is_right(kp):
        side_phase = phase + math.pi
    elif _is_back(kp) and _is_left(kp):
        side_phase = phase + math.pi
    elif _is_left(kp):
        # Biped left = phase A
        side_phase = phase
    elif _is_right(kp):
        # Biped right = phase B
        side_phase = phase + math.pi
    else:
        # No side info; treat as centerline, no swing.
        return replace(kp)
    swing_x = WALK_PAW_SWING_PX * math.sin(side_phase)
    # The lift is maximal when the paw is mid-swing forward (sin ≈ 1)
    # and zero at the foot-plant extremes — model as |sin(side_phase)|.
    lift_y = -WALK_PAW_LIFT_PX * max(0.0, math.sin(side_phase))
    # Knees move at half amplitude — they follow the paw but stay
    # anchored to the body.
    if is_knee(kp):
        swing_x *= 0.5
        lift_y *= 0.5
    return replace(kp, x=kp.x + swing_x, y=kp.y + lift_y)


# =====================================================================
# Idle cycle
# =====================================================================
#
# Subtle breathing-style up-down on the body + a slight head sway.
# 5 frames @ 2 fps = 2.5-second cycle, slow enough to read as "alive
# but not moving".

IDLE_BODY_BOB_PX = 0.7
IDLE_HEAD_SWAY_PX = 0.4


def idle_phase(frame_index: int, total_frames: int = IDLE_FRAMES) -> float:
    return 2.0 * math.pi * (frame_index % total_frames) / total_frames


def perturb_idle(base: Iterable[Keypoint], frame_index: int) -> list[Keypoint]:
    """Return the keypoints for one idle-cycle frame."""
    phase = idle_phase(frame_index)
    body_y = -IDLE_BODY_BOB_PX * math.sin(phase)
    head_x = IDLE_HEAD_SWAY_PX * math.sin(phase)

    out: list[Keypoint] = []
    for kp in base:
        if is_torso(kp) or is_hip(kp):
            out.append(replace(kp, y=kp.y + body_y))
        elif is_head(kp):
            out.append(replace(kp, x=kp.x + head_x, y=kp.y + body_y * 0.7))
        else:
            out.append(replace(kp))
    return out


# =====================================================================
# Public dispatcher
# =====================================================================

# Action → (perturb function, frame count, fps).
_ACTIONS: dict[str, tuple[Callable[[Iterable[Keypoint], int], list[Keypoint]], int, int]] = {
    "walk": (perturb_walk, WALK_FRAMES, WALK_FPS),
    "idle": (perturb_idle, IDLE_FRAMES, IDLE_FPS),
}


def frames_for_action(action: str) -> int:
    return _ACTIONS[action][1]


def fps_for_action(action: str) -> int:
    return _ACTIONS[action][2]


def perturb(
    base: Sequence[Keypoint],
    action: str,
    frame_index: int,
) -> list[Keypoint]:
    """Public entry. Dispatches to walk/idle perturbation."""
    if action not in _ACTIONS:
        raise ValueError(f"unknown action: {action!r} (expected one of {list(_ACTIONS)})")
    fn, _, _ = _ACTIONS[action]
    return fn(base, frame_index)
