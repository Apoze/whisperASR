#!/usr/bin/env python3

import os
import sys
import unittest
from unittest import mock
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
import mossformer2_oracle as moss


class MossFormer2OracleTests(unittest.TestCase):
    def test_runtime_and_weight_pins_are_immutable(self):
        self.assertEqual(moss.TICKET, 102)
        self.assertEqual(moss.CLEARVOICE_REVISION, "6b3774dc79c46ae8bed2a4fa5f706f0ac8c75c61")
        self.assertEqual(moss.MODEL_REVISION, "407cb030cd66340918ebb6c8cc63b18f8592cdbe")
        self.assertEqual(moss.MODEL_SIZE, 670_353_271)
        self.assertEqual(
            moss.SHARED_SCORER_SHA256,
            "ad497825c03b59154fedf4c2012d9ef89180140743238c7a4b301f632d114541",
        )
        self.assertEqual(
            moss.MODEL_SHA256,
            "00a3a48bda492db1e829b85dd443f8f43a43039a3e90f1a24962ea9caf14a11a",
        )

    def test_separation_requires_the_explicit_heavy_slot(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "BENCHMARK_SLOT_GRANTED=102"):
                moss.separate(None)

    def test_source_matrix_allows_exactly_two_trimmed_outputs(self):
        outputs = np.arange(16, dtype=np.float32).reshape(2, 1, 8)

        matrix = moss._source_matrix(outputs, 6)

        self.assertEqual(matrix.shape, (2, 6))
        with self.assertRaisesRegex(ValueError, "exactly two"):
            moss._source_matrix(np.zeros((3, 1, 8)), 6)
        with self.assertRaisesRegex(ValueError, "shorter"):
            moss._source_matrix(np.zeros((2, 1, 5)), 6)
        with self.assertRaisesRegex(ValueError, "non-finite"):
            moss._source_matrix(np.full((2, 1, 8), np.nan), 6)

    def test_diagnostics_do_not_invent_terms_or_meaning(self):
        plan = {"windows": [{"referenceTurns": [{
            "id": 1, "criticalTerms": [], "japanese": "1000円です",
        }]}]}
        report = {
            "calibration": {"selectedDevelopmentThreshold": 0.85},
            "windows": [{
                "recovered": [{"turnID": 1, "reference": "1000円です"}],
                "lost": [],
                "thresholds": {"0.85": {"accepted": True}},
            }],
        }

        diagnostics = moss.content_diagnostics(plan, report)

        self.assertEqual(diagnostics["numbers"]["recovered"], 1)
        self.assertEqual(
            diagnostics["terms"]["status"],
            "not-evaluable-no-annotated-critical-terms",
        )
        self.assertEqual(
            diagnostics["meaning"]["status"],
            "not-evaluable-no-frozen-semantic-anchors",
        )

    def test_separator_selection_is_smoke_bounded_and_dev_quality_gated(self):
        failed = {"recoveredTurns": 4, "lostTurns": 12, "netRecoveredTurns": -8}
        passed = {"recoveredTurns": 6, "lostTurns": 2, "netRecoveredTurns": 4}

        self.assertEqual(
            moss.select_separator("smoke", failed, passed),
            {"status": "SMOKE_PASSED_READY_FOR_DEVELOPMENT", "selected": None},
        )
        self.assertEqual(
            moss.select_separator("development", failed, failed)["status"],
            "NO_ADMISSIBLE_DEV_SEPARATOR",
        )
        self.assertEqual(
            moss.select_separator("development", failed, passed)["selected"],
            "mossFormer2",
        )


if __name__ == "__main__":
    unittest.main()
