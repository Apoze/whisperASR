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
        self.assertEqual(
            [w["expectedSimultaneousVoiceCount"] for w in windows],
            [2, 2, 2, 2, 2, 2, 2, 2, 3, 2],
        )
        self.assertTrue(all(w["withinPixITCapacity"] for w in windows))

    def test_global_identities_exclude_the_reference_pseudo_group(self):
        manifest = {"annotations": {"status": "complete", "turns": [
            {"speaker": "SPEAKER_01"}, {"speaker": "SPEAKER_02"},
            {"speaker": "SPEAKER_13"},
        ]}}
        scope = pixit.reference_speaker_scope(manifest, {
            "SPEAKER_01": "Commentator",
            "SPEAKER_02": "Guest",
            "SPEAKER_13": "Overlapping or group reaction",
        })

        self.assertEqual(scope["measurementStatus"], "complete")
        self.assertEqual(scope["globalIdentityCount"], 2)
        self.assertEqual(scope["excludedPseudoGroupLabels"], ["SPEAKER_13"])

    def test_speaker_analysis_keeps_unevaluated_windows_unknown(self):
        manifest = json.loads(
            (ROOT / "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json").read_text()
        )
        plan = {
            "referenceSpeakerScope": {"globalIdentityCount": 12},
            "pixitLimitations": {
                "maximumSimultaneousVoices": 3,
                "resolvesGlobalSpeakerIdentity": False,
            },
            "windows": pixit.oracle_windows(manifest),
        }
        evaluated = [{
            "windowID": "window-02",
            "sourceTranscripts": ["うん", "うん"],
            "recovered": [{"turnID": "turn-1"}],
            "lost": [{"turnID": "turn-2"}],
            "thresholds": {"0.8": {"accepted": True}},
        }]

        analysis = pixit.speaker_analysis(plan, evaluated, 0.8)

        self.assertEqual(len(analysis["oracleWindows"]), 10)
        self.assertEqual(analysis["oracleWindows"][0]["evaluationStatus"], "not-evaluated")
        self.assertIsNone(analysis["oracleWindows"][0]["acceptedPixITTrackCount"])
        smoke = analysis["oracleWindows"][1]
        self.assertEqual(smoke["expectedSimultaneousVoiceCount"], 2)
        self.assertEqual(smoke["acceptedPixITTrackCount"], 2)
        self.assertEqual(smoke["distinctAcceptedTranscriptCount"], 1)
        self.assertEqual(smoke["distinctRecoveredReferenceUtteranceCount"], 1)
        self.assertEqual(smoke["distinctLostReferenceUtteranceCount"], 1)

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

    def test_pinned_config_uses_local_loadable_model_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            segmentation = root / "segmentation"
            segmentation.mkdir()
            segmentation.joinpath("pytorch_model.bin").touch()
            embedding = root / "embedding"
            embedding.mkdir()
            wavlm = root / "wavlm"
            wavlm.mkdir()
            repositories = {
                "pyannote/separation-ami-1.0": segmentation,
                "speechbrain/spkrec-ecapa-voxceleb": embedding,
                "microsoft/wavlm-large": wavlm,
            }

            self.assertEqual(
                pixit._local_model_reference("pyannote/separation-ami-1.0", repositories),
                str(segmentation / "pytorch_model.bin"),
            )
            self.assertEqual(
                pixit._local_model_reference(
                    "speechbrain/spkrec-ecapa-voxceleb@upstream-revision", repositories
                ),
                str(embedding),
            )
            self.assertEqual(
                pixit._local_model_reference("microsoft/wavlm-large", repositories),
                str(wavlm),
            )

    def test_separated_sources_are_trimmed_to_the_mixture_samples(self):
        self.assertEqual(pixit._source_sample_bounds(80_001, 48_000), (0, 48_000))
        with self.assertRaisesRegex(ValueError, "too short"):
            pixit._source_sample_bounds(47_999, 48_000)


if __name__ == "__main__":
    unittest.main()
