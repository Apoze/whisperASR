#!/usr/bin/env python3
"""Compare SpeakerKit automatic inference with a known expected count."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
import math
import re
from pathlib import Path

from report_exclusive_reconciliation import (
    current_implementation_matches,
    execution_implementation_matches,
    metrics,
)
from report_high_quality_acceptance import read, sha256

CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
EXPECTED_FILES = {
    "english-subtitles.srt",
    "english-subtitles.vtt",
    "english-translation-transcript.txt",
    "japanese-transcript.txt",
    "manifest.json",
    "raw-asr.json",
}
MAX_MEMORY_BYTES = 16 * 1_024 * 1_024 * 1_024
SCORING_PATHS = {
    "Scripts/report_speaker_count.py",
    "Scripts/report_exclusive_reconciliation.py",
}
REQUIRED_UNCHANGED_PATHS = {
    "Sources/AppleLiveServices.swift",
    "Sources/HighQualityJobView.swift",
    "Sources/QwenPseudoLiveCoordinator.swift",
    "Sources/TranslationService.swift",
    "Sources/AppState.swift",
    "Sources/LiveRecoveryStore.swift",
    "Sources/LocalCaptionPipeline.swift",
    "Sources/LocalDiarizationShadow.swift",
    "Sources/RecordingView.swift",
}
VERSIONED_EVIDENCE_ROOT = Path("docs/japanese-live/experiments/evidence/E17")


def read_gzip(path: Path) -> dict:
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def one_variable(meta: dict) -> bool:
    baseline = copy.deepcopy(meta["settings"]["baseline"])
    candidate = copy.deepcopy(meta["settings"]["candidate"])
    before = (baseline.pop("speakerCountPolicy"), baseline.pop("numberOfSpeakers"))
    after = (candidate.pop("speakerCountPolicy"), candidate.pop("numberOfSpeakers"))
    return before == ("automatic", None) and after == (
        "expected", meta["expectedSpeakerCount"]
    ) and baseline == candidate


def model_lifecycle(raw: dict) -> bool:
    events = [
        event["kind"] for event in raw["modelEvents"]
        if event["modelID"] == "argmaxinc/speakerkit-coreml"
    ]
    return all(kind in events for kind in (
        "load-started", "load-completed", "unload-completed", "memory-release-checked"
    )) and "guard-failed" not in events


def complete(raw: dict) -> bool:
    diarization = raw.get("diarization") or {}
    mappings = diarization.get("mappings", [])
    return (
        bool(diarization.get("rawSpans"))
        and bool(mappings)
        and not diarization.get("validationDiagnostics")
        and len(mappings) == len({item["alignmentItemIndex"] for item in mappings})
    )


def valid_deliverables(manifest: dict) -> bool:
    return manifest.get("status") == "completed" and not manifest.get("failures") and {
        item["path"] for item in manifest.get("generatedFiles", [])
    } == EXPECTED_FILES


def artifact_hashes_match(meta: dict, key: str, job: Path) -> bool:
    expected = meta.get("artifactSHA256", {}).get(key, {})
    return set(expected) == EXPECTED_FILES and all(
        (job / name).is_file() and sha256(job / name) == digest
        for name, digest in expected.items()
    )


def gzip_content_sha256(path: Path) -> str | None:
    digest = hashlib.sha256()
    try:
        with gzip.open(path, "rb") as handle:
            while chunk := handle.read(1_024 * 1_024):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def versioned_artifacts_match(meta: dict, key: str, split: str, mode: str) -> bool:
    expected = meta.get("artifactSHA256", {}).get(key, {})
    if set(expected) != EXPECTED_FILES:
        return False
    for name, digest in expected.items():
        snapshot = VERSIONED_EVIDENCE_ROOT / f"{split}-{mode}-{name}"
        if name == "raw-asr.json":
            snapshot = snapshot.with_suffix(snapshot.suffix + ".gz")
            if gzip_content_sha256(snapshot) != digest:
                return False
        elif not snapshot.is_file() or sha256(snapshot) != digest:
            return False
    return True


def implementation_hashes_match(hashes: dict) -> bool:
    return bool(hashes) and all(
        Path(path).is_file() and sha256(Path(path)) == digest
        for path, digest in hashes.items()
    )


def unchanged_implementations_match(meta: dict) -> bool:
    implementations = meta.get("unchangedImplementations", {})
    return REQUIRED_UNCHANGED_PATHS <= set(implementations) and all(
        item.get("baseSHA256") == item.get("candidateSHA256")
        and Path(path).is_file()
        and sha256(Path(path)) == item.get("candidateSHA256")
        for path, item in implementations.items()
    )


def scoring_hashes(meta: dict) -> dict:
    explicit = meta.get("scoringImplementationSHA256")
    if explicit:
        return explicit
    reviewed = meta.get("reviewedImplementationSHA256", {})
    return {path: reviewed[path] for path in SCORING_PATHS if path in reviewed}


def policy(raw: dict) -> dict:
    return raw.get("speakerCountPolicy") or {}


def translations_match(left: dict, right: dict) -> bool:
    left = copy.deepcopy(left)
    right = copy.deepcopy(right)
    try:
        left["response"] = json.loads(left["response"])
        right["response"] = json.loads(right["response"])
    except (KeyError, TypeError, json.JSONDecodeError):
        return False
    return left == right


def delivered_japanese(text: str) -> str:
    return re.sub(r"(?m)^SPEAKER_[0-9]+:[ \t]?", "", text)


def spoken_content_preserved(auto_job: Path, expected_job: Path) -> bool:
    name = "japanese-transcript.txt"
    try:
        automatic = (auto_job / name).read_text(encoding="utf-8")
        expected = (expected_job / name).read_text(encoding="utf-8")
    except OSError:
        return False
    return delivered_japanese(automatic) == delivered_japanese(expected)


def auto_matches_prior(auto: dict, prior: dict) -> bool:
    keys = ("modelID", "revision", "rawSpans", "mappings", "overlapRanges",
            "useExclusiveReconciliation")
    return all(auto["diarization"].get(key) == prior["diarization"].get(key) for key in keys)


def corpus_report(root: Path, corpus: str) -> dict:
    directory = root / corpus
    meta = read(directory / "run-meta.json")
    manifest_path = Path(meta["corpusManifestPath"])
    source_path = Path(meta["sourcePath"])
    upstream_path = Path(meta["frozenUpstreamEvidencePath"])
    prior_path = Path(meta["priorAutoEvidencePath"])
    auto_job = directory / "jobs" / meta["jobs"]["baseline"]
    expected_job = directory / "jobs" / meta["jobs"]["candidate"]
    auto = read(auto_job / "raw-asr.json")
    expected = read(expected_job / "raw-asr.json")
    prior = read_gzip(prior_path)
    manifest = read(manifest_path)
    auto_metrics = metrics(manifest, auto, corpus)
    expected_metrics = metrics(manifest, expected, corpus)
    controls = read(root / "controls.json")
    count = meta["expectedSpeakerCount"]
    split = "development" if meta["corpusRole"] == "development" else "holdout"
    gates = {
        "provenance": (
            sha256(source_path) == meta["sourceSHA256"]
            and sha256(manifest_path) == meta["corpusManifestSHA256"]
            and sha256(upstream_path) == meta["frozenUpstreamEvidenceSHA256"]
            and sha256(prior_path) == meta["priorAutoEvidenceSHA256"]
            and artifact_hashes_match(meta, "baseline", auto_job)
            and artifact_hashes_match(meta, "candidate", expected_job)
            and execution_implementation_matches(meta)
            and current_implementation_matches(meta)
            and set(scoring_hashes(meta)) == SCORING_PATHS
            and implementation_hashes_match(scoring_hashes(meta))
        ),
        "oneVariable": one_variable(meta),
        "frozenASRAlignment": (
            auto["rawASR"] == expected["rawASR"]
            and auto["alignment"]["chunks"] == expected["alignment"]["chunks"]
            and auto["alignment"]["mergedCues"] == expected["alignment"]["mergedCues"]
            and auto["sampleCount"] == expected["sampleCount"]
        ),
        "policiesRetained": (
            policy(auto) == {"mode": "automatic"}
            and policy(expected) == {"mode": "expected", "expectedCount": count}
            and auto["diarization"].get("speakerCountPolicy") == policy(auto)
            and expected["diarization"].get("speakerCountPolicy") == policy(expected)
        ),
        "autoUnchanged": auto_matches_prior(auto, prior),
        "sameSpeakerKit": (
            auto["diarization"]["modelID"] == expected["diarization"]["modelID"]
            and auto["diarization"]["revision"] == expected["diarization"]["revision"]
        ),
        "completeEvidence": complete(auto) and complete(expected),
        "validDeliverables": valid_deliverables(read(auto_job / "manifest.json"))
        and valid_deliverables(read(expected_job / "manifest.json")),
        "versionedArtifacts": versioned_artifacts_match(
            meta, "baseline", split, "automatic"
        ) and versioned_artifacts_match(meta, "candidate", split, "expected"),
        "unchangedProductAndLive": unchanged_implementations_match(meta),
        "translationUnchanged": translations_match(
            auto["translation"], expected["translation"]
        ),
        "lifecycleAndMemoryRelease": model_lifecycle(auto) and model_lifecycle(expected),
        "runtimeAndMemoryMeasured": all(
            isinstance(value, (int, float)) and math.isfinite(value) and value > 0
            for value in (
                auto_metrics["runtimeSeconds"], expected_metrics["runtimeSeconds"],
                auto_metrics["peakMemoryBytes"], expected_metrics["peakMemoryBytes"],
            )
        ) and expected_metrics["peakMemoryBytes"] <= MAX_MEMORY_BYTES,
        "zeroDuplication": auto_metrics["duplicationCount"] == 0
        and expected_metrics["duplicationCount"] == 0,
        "noSpokenContentLoss": spoken_content_preserved(auto_job, expected_job),
        "speakerCountGain": expected_metrics["speakerCountAbsoluteError"]
        < auto_metrics["speakerCountAbsoluteError"],
        "speakerQualityGain": expected_metrics["speakerAttributedJapaneseError"]["ratePercent"]
        < auto_metrics["speakerAttributedJapaneseError"]["ratePercent"]
        and expected_metrics["DERPercent"] <= auto_metrics["DERPercent"]
        and expected_metrics["JERPercent"] <= auto_metrics["JERPercent"],
        "deterministicControls": all(value is True for value in controls.values()),
    }
    return {
        "corpusID": corpus,
        "role": meta["corpusRole"],
        "expectedSpeakerCount": count,
        "automatic": auto_metrics,
        "expected": expected_metrics,
        "diagnostics": {
            "unattributedJapaneseCharactersDelta": expected_metrics[
                "speakerAttributedJapaneseError"
            ]["unattributedCharacterCount"] - auto_metrics[
                "speakerAttributedJapaneseError"
            ]["unattributedCharacterCount"],
        },
        "gates": gates,
        "eligible": all(gates.values()),
    }


def markdown(report: dict) -> str:
    lines = [
        "# E17 — Known Speaker count versus Auto",
        "",
        "Only `numberOfSpeakers` changes. Auto stays the product default; the explicit "
        "count is derived from the authoritative acoustic-Speaker annotations.",
        "",
        "| Corpus | Mode | DER | JER | Speaker JA error | Unlabelled JA | Count error | Runtime | Peak memory |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in report["rows"]:
        for label, key in (("Auto", "automatic"), (f'Expected {row["expectedSpeakerCount"]}', "expected")):
            value = row[key]
            lines.append(
                f'| {row["corpusID"]} ({row["role"]}) | {label} | '
                f'{value["DERPercent"]:.2f}% | {value["JERPercent"]:.2f}% | '
                f'{value["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | '
                f'{value["speakerAttributedJapaneseError"]["unattributedCharacterCount"]} | '
                f'{value["speakerCountAbsoluteError"]} | {value["runtimeSeconds"]:.2f}s | '
                f'{value["peakMemoryBytes"] / 1_048_576:.0f} MiB |'
            )
    lines += [
        "",
        "Unlabelled JA is a separate attribution-coverage diagnostic. The spoken-content "
        "gate compares delivered Japanese after removing only `SPEAKER_NN:` prefixes.",
    ]
    if not report["holdoutRun"]:
        lines += ["", "Untouched holdout: not run."]
    lines += ["", f'**Decision:** {report["decision"]}.', ""]
    return "\n".join(lines)


def self_test() -> None:
    script = Path(__file__)
    assert implementation_hashes_match({str(script): sha256(script)})
    assert not implementation_hashes_match({str(script): "invalid"})
    assert not unchanged_implementations_match({})
    assert scoring_hashes({
        "reviewedImplementationSHA256": {
            "Sources/HighQualityJob.swift": "product",
            "Scripts/report_speaker_count.py": "report",
            "Scripts/report_exclusive_reconciliation.py": "metrics",
        },
    }) == {
        "Scripts/report_speaker_count.py": "report",
        "Scripts/report_exclusive_reconciliation.py": "metrics",
    }
    assert translations_match(
        {"response": '{"translations":[{"id":"unit-1","text":"English"}]}',
         "validationFailures": []},
        {"response": '{"translations":[{"text":"English","id":"unit-1"}]}',
         "validationFailures": []},
    )
    assert delivered_japanese("SPEAKER_01: 日本語\n未帰属\n") == "日本語\n未帰属\n"
    assert one_variable({
        "expectedSpeakerCount": 3,
        "settings": {
            "baseline": {"speakerCountPolicy": "automatic", "numberOfSpeakers": None, "x": 1},
            "candidate": {"speakerCountPolicy": "expected", "numberOfSpeakers": 3, "x": 1},
        },
    })
    assert not one_variable({
        "expectedSpeakerCount": 3,
        "settings": {
            "baseline": {"speakerCountPolicy": "automatic", "numberOfSpeakers": None},
            "candidate": {"speakerCountPolicy": "expected", "numberOfSpeakers": 2},
        },
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    assert args.root and args.json and args.markdown
    rows = [corpus_report(args.root, corpus) for corpus in CORPORA
            if (args.root / corpus / "run-meta.json").exists()]
    development = next(row for row in rows if row["role"] == "development")
    holdout = next((row for row in rows if row["role"] == "untouched-holdout"), None)
    if not development["eligible"]:
        decision = "do not ship explicit count; development gates failed"
    elif holdout is None:
        decision = "development passed; holdout remains untouched"
    elif holdout["eligible"]:
        decision = "ship optional expected count; keep Auto as default"
    else:
        decision = "do not ship explicit count; holdout did not confirm the gain"
    report = {
        "schemaVersion": 1,
        "experiment": "E17-speaker-count",
        "developmentPromotionEligible": development["eligible"],
        "holdoutRun": holdout is not None,
        "promote": holdout is not None and holdout["eligible"],
        "decision": decision,
        "rows": rows,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    args.markdown.write_text(markdown(report), encoding="utf-8")


if __name__ == "__main__":
    main()
