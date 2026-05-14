#!/usr/bin/env python3
"""Unit tests for Scripts/skeleton_animator.py.

Pure-math tests — no API calls, no fixtures, no I/O. Validates the
walk + idle perturbation contracts against hand-crafted skeletons.

Run from repo root:
    python3 -m unittest Scripts.test_skeleton_animator
"""

import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from skeleton_animator import (  # noqa: E402
    IDLE_BODY_BOB_PX,
    IDLE_FRAMES,
    IDLE_FPS,
    Keypoint,
    WALK_BODY_BOB_PX,
    WALK_FRAMES,
    WALK_FPS,
    WALK_PAW_LIFT_PX,
    WALK_PAW_SWING_PX,
    fps_for_action,
    frames_for_action,
    idle_phase,
    is_head,
    is_hip,
    is_paw,
    is_torso,
    perturb,
    perturb_idle,
    perturb_walk,
    walk_phase,
)


# ─── Synthetic skeletons ───────────────────────────────────────────────


def quadruped_skeleton() -> list[Keypoint]:
    """Cat-shape: head, torso, 4 hips + 4 knees + 4 paws."""
    return [
        Keypoint(34, 20, "head"),
        Keypoint(34, 32, "torso"),
        Keypoint(28, 36, "left_front_hip"),
        Keypoint(28, 44, "left_front_knee"),
        Keypoint(28, 52, "left_front_paw"),
        Keypoint(40, 36, "right_front_hip"),
        Keypoint(40, 44, "right_front_knee"),
        Keypoint(40, 52, "right_front_paw"),
        Keypoint(28, 36, "left_back_hip"),
        Keypoint(28, 44, "left_back_knee"),
        Keypoint(28, 52, "left_back_paw"),
        Keypoint(40, 36, "right_back_hip"),
        Keypoint(40, 44, "right_back_knee"),
        Keypoint(40, 52, "right_back_paw"),
        Keypoint(48, 32, "tail_base"),
    ]


def biped_skeleton() -> list[Keypoint]:
    """Penguin-shape: head, torso, 2 hips + 2 knees + 2 paws."""
    return [
        Keypoint(34, 20, "head"),
        Keypoint(34, 36, "torso"),
        Keypoint(30, 44, "left_hip"),
        Keypoint(30, 52, "left_knee"),
        Keypoint(30, 60, "left_paw"),
        Keypoint(38, 44, "right_hip"),
        Keypoint(38, 52, "right_knee"),
        Keypoint(38, 60, "right_paw"),
    ]


def blob_skeleton() -> list[Keypoint]:
    """Slime / octopus — no limbs to swing, just body + head."""
    return [
        Keypoint(34, 24, "head"),
        Keypoint(34, 40, "body"),
    ]


# ─── Label classifier ──────────────────────────────────────────────────


class LabelClassifierTests(unittest.TestCase):

    def test_is_paw_matches_paw_foot_ankle(self):
        self.assertTrue(is_paw(Keypoint(0, 0, "left_front_paw")))
        self.assertTrue(is_paw(Keypoint(0, 0, "RIGHT_FOOT")))
        self.assertTrue(is_paw(Keypoint(0, 0, "ankle")))
        self.assertFalse(is_paw(Keypoint(0, 0, "torso")))

    def test_is_torso_matches_synonyms(self):
        for label in ("torso", "body", "spine", "chest"):
            self.assertTrue(is_torso(Keypoint(0, 0, label)), label)
        self.assertFalse(is_torso(Keypoint(0, 0, "head")))

    def test_empty_label_matches_nothing(self):
        kp = Keypoint(0, 0, "")
        self.assertFalse(is_paw(kp))
        self.assertFalse(is_torso(kp))
        self.assertFalse(is_head(kp))
        self.assertFalse(is_hip(kp))


# ─── Walk cycle ────────────────────────────────────────────────────────


class WalkCycleTests(unittest.TestCase):

    def test_walk_phase_spans_full_circle_across_8_frames(self):
        phases = [walk_phase(i) for i in range(WALK_FRAMES)]
        self.assertAlmostEqual(phases[0], 0.0)
        self.assertAlmostEqual(phases[WALK_FRAMES // 2], math.pi)
        # Last frame doesn't reach 2π exactly (modulo), but the next
        # frame would.
        self.assertAlmostEqual(walk_phase(WALK_FRAMES), 0.0)

    def test_frame_0_returns_unmoved_skeleton(self):
        base = quadruped_skeleton()
        out = perturb_walk(base, 0)
        for orig, perturbed in zip(base, out):
            # At phase 0, sin = 0 → no swing, no bob.
            self.assertAlmostEqual(orig.x, perturbed.x, places=5,
                                   msg=f"x drift at frame 0 for {orig.label}")
            self.assertAlmostEqual(orig.y, perturbed.y, places=5,
                                   msg=f"y drift at frame 0 for {orig.label}")

    def test_diagonal_couplet_pairs_swing_in_phase(self):
        # FL+RR same phase, FR+RL opposite. Pick mid-cycle frame 2 (phase = π/2)
        # where sin = 1 — peak swing.
        base = quadruped_skeleton()
        out = perturb_walk(base, 2)
        out_map = {kp.label: kp for kp in out}
        fl = out_map["left_front_paw"]
        rr = out_map["right_back_paw"]
        fr = out_map["right_front_paw"]
        rl = out_map["left_back_paw"]
        base_map = {kp.label: kp for kp in base}
        fl_dx = fl.x - base_map["left_front_paw"].x
        rr_dx = rr.x - base_map["right_back_paw"].x
        fr_dx = fr.x - base_map["right_front_paw"].x
        rl_dx = rl.x - base_map["left_back_paw"].x
        # FL & RR move the same direction; FR & RL the opposite.
        self.assertAlmostEqual(fl_dx, rr_dx, places=4,
                               msg="FL and RR should share phase")
        self.assertAlmostEqual(fr_dx, rl_dx, places=4,
                               msg="FR and RL should share phase")
        self.assertAlmostEqual(fl_dx, -fr_dx, places=4,
                               msg="diagonals should be opposite phase")

    def test_paw_swing_amplitude_capped(self):
        # At any frame, no paw should swing further than the configured amplitude.
        base = quadruped_skeleton()
        for f in range(WALK_FRAMES):
            for kp in perturb_walk(base, f):
                if is_paw(kp):
                    orig = next(k for k in base if k.label == kp.label)
                    self.assertLessEqual(abs(kp.x - orig.x), WALK_PAW_SWING_PX + 0.001)
                    self.assertLessEqual(abs(kp.y - orig.y), WALK_PAW_LIFT_PX + 0.001)

    def test_body_bob_oscillates_around_origin(self):
        base = quadruped_skeleton()
        torso_ys = []
        for f in range(WALK_FRAMES):
            out = perturb_walk(base, f)
            torso = next(kp for kp in out if is_torso(kp))
            torso_ys.append(torso.y)
        # Should average back to the original y across a full cycle.
        avg = sum(torso_ys) / len(torso_ys)
        orig_y = next(kp.y for kp in base if is_torso(kp))
        self.assertAlmostEqual(avg, orig_y, places=3)
        # And the max excursion should match the configured amplitude.
        max_dev = max(abs(y - orig_y) for y in torso_ys)
        self.assertLessEqual(max_dev, WALK_BODY_BOB_PX + 0.001)

    def test_biped_left_right_swing_opposite(self):
        base = biped_skeleton()
        out = perturb_walk(base, 2)
        out_map = {kp.label: kp for kp in out}
        base_map = {kp.label: kp for kp in base}
        lf_dx = out_map["left_paw"].x - base_map["left_paw"].x
        rf_dx = out_map["right_paw"].x - base_map["right_paw"].x
        self.assertAlmostEqual(lf_dx, -rf_dx, places=4)

    def test_blob_with_no_limbs_only_bobs(self):
        # Slime / octopus shape has no paws — only body + head should
        # perturb, and nothing else should crash.
        base = blob_skeleton()
        for f in range(WALK_FRAMES):
            out = perturb_walk(base, f)
            self.assertEqual(len(out), len(base))
            # head perturbs, body perturbs, that's it.
            self.assertEqual(
                {kp.label for kp in out},
                {kp.label for kp in base},
            )


# ─── Idle cycle ────────────────────────────────────────────────────────


class IdleCycleTests(unittest.TestCase):

    def test_frame_0_returns_unmoved_skeleton(self):
        base = quadruped_skeleton()
        out = perturb_idle(base, 0)
        for orig, perturbed in zip(base, out):
            self.assertAlmostEqual(orig.x, perturbed.x, places=5)
            self.assertAlmostEqual(orig.y, perturbed.y, places=5)

    def test_paws_do_not_move_in_idle(self):
        # Defining trait of "idle" vs "walk" — feet planted.
        base = quadruped_skeleton()
        out = perturb_idle(base, 1)
        for kp_base, kp_out in zip(base, out):
            if is_paw(kp_base):
                self.assertAlmostEqual(kp_base.x, kp_out.x, places=5)
                self.assertAlmostEqual(kp_base.y, kp_out.y, places=5)

    def test_body_oscillates_within_idle_amplitude(self):
        base = quadruped_skeleton()
        for f in range(IDLE_FRAMES):
            out = perturb_idle(base, f)
            torso = next(kp for kp in out if is_torso(kp))
            orig_y = next(kp.y for kp in base if is_torso(kp))
            self.assertLessEqual(abs(torso.y - orig_y), IDLE_BODY_BOB_PX + 0.001)


# ─── Public dispatcher ─────────────────────────────────────────────────


class DispatchTests(unittest.TestCase):

    def test_perturb_routes_to_walk(self):
        base = quadruped_skeleton()
        direct = perturb_walk(base, 3)
        dispatch = perturb(base, "walk", 3)
        for d, p in zip(direct, dispatch):
            self.assertEqual((d.x, d.y, d.label), (p.x, p.y, p.label))

    def test_perturb_routes_to_idle(self):
        base = quadruped_skeleton()
        direct = perturb_idle(base, 2)
        dispatch = perturb(base, "idle", 2)
        for d, p in zip(direct, dispatch):
            self.assertEqual((d.x, d.y, d.label), (p.x, p.y, p.label))

    def test_perturb_unknown_action_raises(self):
        with self.assertRaises(ValueError) as cm:
            perturb(quadruped_skeleton(), "jump", 0)
        self.assertIn("jump", str(cm.exception))

    def test_frame_counts_match_pipeline_constants(self):
        # The values bake into normalize_pixellab.py + AssetSpec.swift.
        # Pin them so a refactor here doesn't silently change everything.
        self.assertEqual(frames_for_action("walk"), 8)
        self.assertEqual(frames_for_action("idle"), 5)
        self.assertEqual(fps_for_action("walk"), 6)
        self.assertEqual(fps_for_action("idle"), 2)


# ─── Pure-function guarantees ──────────────────────────────────────────


class PurityTests(unittest.TestCase):

    def test_perturb_does_not_mutate_input(self):
        base = quadruped_skeleton()
        snapshot = [(kp.x, kp.y, kp.label) for kp in base]
        _ = perturb_walk(base, 3)
        _ = perturb_idle(base, 1)
        for after, snap in zip(base, snapshot):
            self.assertEqual((after.x, after.y, after.label), snap)


if __name__ == "__main__":
    unittest.main()
