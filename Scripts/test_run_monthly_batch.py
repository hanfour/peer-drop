#!/usr/bin/env python3
"""Unit tests for Scripts/run_monthly_batch.py.

Pinpoints the batch-planning math + post-batch summary text. The
actual generate() invocation is exercised in test_gen_pixellab_zip.py
— here we just verify the planner picks the right N species and the
follow-up text mentions the right paths.

Run from repo root:
    python3 -m unittest Scripts.test_run_monthly_batch
"""

import io
import sys
import unittest
from contextlib import redirect_stdout
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))

from run_monthly_batch import (  # noqa: E402
    BatchPlan,
    CALLS_PER_SPECIES,
    QUOTA_SAFETY_BUFFER,
    plan_batch,
    print_plan,
    print_followup,
)
from gen_pixellab_zip import GenReport  # noqa: E402


class PlanBatchTests(unittest.TestCase):

    def test_quota_2000_fits_17_species(self):
        # 2000 - 50 buffer = 1950 usable / 112 calls = 17.4 → 17 species
        plan = plan_batch(
            quota=2000,
            overrides=["species-" + str(i) for i in range(50)],
        )
        self.assertEqual(plan.fit_in_quota, 17)
        self.assertEqual(plan.calls_planned, 17 * CALLS_PER_SPECIES)
        # Remaining = 2000 - 1904 = 96 (within the 50-buffer + extra change)
        self.assertEqual(plan.calls_remaining, 2000 - 17 * CALLS_PER_SPECIES)

    def test_quota_zero_fits_no_species(self):
        plan = plan_batch(quota=0, overrides=["a", "b"])
        self.assertEqual(plan.fit_in_quota, 0)
        self.assertEqual(plan.calls_planned, 0)

    def test_smaller_candidate_set_caps_fit(self):
        # 3 candidates, quota for 17 → fit = 3.
        plan = plan_batch(quota=2000, overrides=["a", "b", "c"])
        self.assertEqual(plan.fit_in_quota, 3)

    def test_safety_buffer_respected(self):
        # 2000 quota: 17 species × 112 = 1904, leaving 96 free.
        # With buffer 50, we have 1950 usable, but 18 species would
        # need 18×112 = 2016, exceeds usable, so 17 is the cap.
        plan = plan_batch(quota=2000, overrides=[f"x{i}" for i in range(30)])
        self.assertLessEqual(plan.calls_planned, 2000 - QUOTA_SAFETY_BUFFER)

    def test_override_preserves_input_order(self):
        custom = ["zz-last", "aa-first", "mm-middle"]
        plan = plan_batch(quota=2000, overrides=custom)
        self.assertEqual(plan.candidates[:plan.fit_in_quota], custom[:plan.fit_in_quota])


class PrintPlanTests(unittest.TestCase):

    def test_print_plan_mentions_key_numbers(self):
        plan = plan_batch(quota=2000, overrides=["a", "b", "c"])
        buf = io.StringIO()
        with redirect_stdout(buf):
            print_plan(plan)
        out = buf.getvalue()
        self.assertIn("Species this batch:        3", out)
        self.assertIn("Quota:                     2,000", out)
        self.assertIn("- a", out)
        self.assertIn("- b", out)


class PrintFollowupTests(unittest.TestCase):

    def test_followup_lists_drop_v5_zip_per_success(self):
        ok_report = GenReport(
            species_stage="cat-tabby-baby",
            api_calls=112,
            frames_written=104,
            output_path=Path("/tmp/stg/cat-tabby-baby-raw.zip"),
        )
        # Make the output_path appear to exist for the followup check.
        with patch.object(Path, "is_file", return_value=True):
            buf = io.StringIO()
            with redirect_stdout(buf):
                print_followup([ok_report], Path("/tmp/stg"))
            out = buf.getvalue()
        self.assertIn("Scripts/drop_v5_zip.sh /tmp/stg/cat-tabby-baby-raw.zip cat-tabby-baby", out)
        self.assertIn('"cat-tabby-baby",', out)
        self.assertIn("MainBundleAssetCoverageTests", out)

    def test_followup_surfaces_failed_species(self):
        bad_report = GenReport(
            species_stage="bad-species",
            api_calls=1,
            frames_written=0,
            errors=["source zip not found: /tmp/missing.zip"],
        )
        buf = io.StringIO()
        with redirect_stdout(buf):
            print_followup([bad_report], Path("/tmp/stg"))
        out = buf.getvalue()
        self.assertIn("bad-species", out)
        self.assertIn("Failed species:", out)


if __name__ == "__main__":
    unittest.main()
