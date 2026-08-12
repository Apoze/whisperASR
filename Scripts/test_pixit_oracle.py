#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "pixit_oracle", ROOT / "Scripts" / "pixit_oracle.py"
)
pixit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pixit)


class PixITOracleTests(unittest.TestCase):
    def test_oracle_uses_distinct_speakers_on_development_only(self):
        manifest = json.loads(
            (ROOT / "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json").read_text()
        )

        windows = pixit.oracle_windows(manifest)

        self.assertEqual(len(windows), 10)
        self.assertAlmostEqual(sum(w["oracleSeconds"] for w in windows), 25.5)
        self.assertEqual((windows[0]["startSample"], windows[0]["endSample"]), (3672000, 3736000))
        self.assertTrue(all(len(w["speakers"]) > 1 for w in windows))

    def test_duplicate_policy_rejects_empty_pairs_and_mixture_copies(self):
        self.assertEqual(
            pixit.classify_sources("混合音声", ["", "別の声"], 0.8)["reasons"],
            ["empty-source"],
        )
        self.assertEqual(
            pixit.classify_sources("混合音声", ["同じ発話", "同じ発話"], 0.8)["reasons"],
            ["near-identical-sources"],
        )
        self.assertEqual(
            pixit.classify_sources("混合音声", ["混合音声", "混合音声"], 0.8)["reasons"],
            ["near-identical-sources", "mixture-equivalent-source"],
        )
        self.assertEqual(
            pixit.classify_sources("実況です", ["実況です", "別の歓声"], 0.8)["reasons"],
            ["mixture-equivalent-source"],
        )

    def test_artifact_hashes_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.wav"
            path.write_bytes(b"audio")
            record = {"path": str(path), "sha256": pixit.sha256(path)}
            pixit.verify_artifact(record)
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                pixit.verify_artifact(record)

    def test_qwen_must_transcribe_every_separator_audio_once(self):
        separator = {"files": [
            {"windowID": "window-01", "kind": "mixture", "sourceIndex": None, "sha256": "a" * 64},
            {"windowID": "window-01", "kind": "source", "sourceIndex": 1, "sha256": "b" * 64},
        ]}
        complete = {"items": [
            {"windowID": "window-01", "kind": "mixture", "sourceIndex": None, "audioSHA256": "a" * 64},
            {"windowID": "window-01", "kind": "source", "sourceIndex": 1, "audioSHA256": "b" * 64},
        ]}
        pixit.verify_qwen_parity(separator, complete)
        with self.assertRaisesRegex(ValueError, "Qwen input parity"):
            pixit.verify_qwen_parity(separator, {"items": complete["items"][:-1]})

    def test_separator_must_reference_the_exact_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory) / "plan.json"
            plan.write_text("{}")
            separator = {"plan": {"path": str(plan), "sha256": pixit.sha256(plan)}}
            pixit.verify_separator_plan(separator, plan)
            other = Path(directory) / "other.json"
            other.write_text("{}")
            with self.assertRaisesRegex(ValueError, "plan provenance"):
                pixit.verify_separator_plan(separator, other)


if __name__ == "__main__":
    unittest.main()
