#!/usr/bin/env python3
"""Compare quantized and full-precision SpeakerKit runs."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import tempfile
from pathlib import Path

from report_exclusive_reconciliation import (
    current_implementation_matches,
    execution_implementation_matches,
    gzip_content_sha256,
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
MAX_PRODUCT_MEMORY_BYTES = 16 * 1_024 * 1_024 * 1_024
SCORER_PATH = "Scripts/report_speakerkit_precision.py"
LOG_FILES = {"baseline": "quantized.log", "candidate": "full.log"}
EVIDENCE_ROOT = Path("docs/japanese-live/experiments/evidence/E16")
CONTROL_FLAGS = {
    "buildAndJobTests", "cancellationTests", "memoryGateTests",
    "translationTests", "liveTests", "artifactReporterSelfTest",
}
CONTROL_LOGS = {"buildRoute", "lightTests", "mlxMetallib"}


def inventory_model_cache(root: Path) -> dict:
    files = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
        files.append({
            "path": str(path.relative_to(root)),
            "size": path.stat().st_size,
            "sha256": digest.hexdigest(),
        })
    try:
        retained_root = root.resolve().relative_to(Path.cwd().resolve())
    except ValueError:
        retained_root = root
    return {"schemaVersion": 1, "root": str(retained_root), "files": files}


def one_variable(meta: dict) -> bool:
    baseline = copy.deepcopy(meta["settings"]["baseline"])
    candidate = copy.deepcopy(meta["settings"]["candidate"])
    before = tuple(baseline.pop(key, None) for key in (
        "precision", "segmenterVariant", "embedderVariant",
    ))
    after = tuple(candidate.pop(key, None) for key in (
        "precision", "segmenterVariant", "embedderVariant",
    ))
    return (
        before == ("quantized", "W8A16", "W8A16")
        and after == ("full", "W32A32", "W16A16")
        and baseline == candidate
    )


def model_lifecycle(raw: dict) -> bool:
    events = [
        event["kind"] for event in raw["modelEvents"]
        if event["modelID"] == "argmaxinc/speakerkit-coreml"
    ]
    return (
        "load-started" in events
        and "load-completed" in events
        and "unload-completed" in events
        and "memory-release-checked" in events
        and "guard-failed" not in events
    )


def complete_evidence(raw: dict) -> bool:
    diarization = raw.get("diarization") or {}
    mappings = diarization.get("mappings", [])
    return (
        bool(diarization.get("rawSpans"))
        and bool(mappings)
        and not diarization.get("validationDiagnostics")
        and len(mappings)
        == len({item["alignmentItemIndex"] for item in mappings})
        and diarization.get("useExclusiveReconciliation") is False
    )


def valid_deliverables(manifest: dict) -> bool:
    return (
        manifest.get("status") == "completed"
        and not manifest.get("failures")
        and {item["path"] for item in manifest.get("generatedFiles", [])}
        == EXPECTED_FILES
    )


def translation_unchanged(baseline: dict, candidate: dict) -> bool:
    baseline = copy.deepcopy(baseline)
    candidate = copy.deepcopy(candidate)
    try:
        baseline_response = json.loads(baseline.pop("response"))
        candidate_response = json.loads(candidate.pop("response"))
    except (KeyError, TypeError, json.JSONDecodeError):
        return False
    return baseline == candidate and baseline_response == candidate_response


def artifact_hashes_match(meta: dict, key: str, job: Path) -> bool:
    expected = meta.get("artifactSHA256", {}).get(key, {})
    return set(expected) == EXPECTED_FILES and all(
        (job / name).is_file() and sha256(job / name) == digest
        for name, digest in expected.items()
    )


def execution_provenance_matches(meta: dict) -> bool:
    execution = copy.deepcopy(meta)
    hashes = execution.get("executionImplementationSHA256", {})
    snapshots = meta.get("executionSourceSnapshots", {})
    if not isinstance(snapshots, dict):
        return False
    for source, snapshot_path in snapshots.items():
        expected = hashes.pop(source, None)
        snapshot = Path(snapshot_path)
        if expected is None or not snapshot.is_file() or sha256(snapshot) != expected:
            return False
    if not snapshots and "executionScorerSnapshotPath" in meta:
        expected = hashes.pop(SCORER_PATH, None)
        snapshot = Path(meta["executionScorerSnapshotPath"])
        if expected != meta.get("executionScorerSHA256"):
            return False
        if not snapshot.is_file() or sha256(snapshot) != expected:
            return False
    return execution_implementation_matches(execution)


def controls_are_valid(controls: dict) -> bool:
    if not isinstance(controls, dict):
        return False
    if set(controls) != CONTROL_FLAGS | {"rawLogs"}:
        return False
    if not all(controls.get(flag) is True for flag in CONTROL_FLAGS):
        return False
    logs = controls.get("rawLogs")
    if not isinstance(logs, dict) or set(logs) != CONTROL_LOGS:
        return False
    for value in logs.values():
        if not isinstance(value, dict) or set(value) != {"path", "sha256"}:
            return False
        if not isinstance(value["path"], str) or not isinstance(value["sha256"], str):
            return False
        path = Path(value["path"])
        if not path.is_file() or sha256(path) != value["sha256"]:
            return False
    return True


def retained_artifacts_match(
    meta: dict, split: str, key: str, precision: str
) -> bool:
    expected = meta.get("artifactSHA256", {}).get(key, {})
    log_hash = meta.get("runLogSHA256", {}).get(key)
    if set(expected) != EXPECTED_FILES or not isinstance(log_hash, str):
        return False
    raw = EVIDENCE_ROOT / f"{split}-{precision}-raw-asr.json.gz"
    manifest = EVIDENCE_ROOT / f"{split}-{precision}-manifest.json"
    log = EVIDENCE_ROOT / f"{split}-{precision}.log"
    return (
        gzip_content_sha256(raw) == expected["raw-asr.json"]
        and manifest.is_file()
        and sha256(manifest) == expected["manifest.json"]
        and log.is_file()
        and sha256(log) == log_hash
    )


def corpus_report(root: Path, corpus: str) -> dict:
    directory = root / corpus
    meta = read(directory / "run-meta.json")
    split = "development" if meta["corpusRole"] == "development" else "holdout"
    manifest_path = Path(meta["corpusManifestPath"])
    source_path = Path(meta["sourcePath"])
    upstream_path = Path(meta["frozenUpstreamEvidencePath"])
    baseline_job = directory / "jobs" / meta["jobs"]["baseline"]
    candidate_job = directory / "jobs" / meta["jobs"]["candidate"]
    baseline = read(baseline_job / "raw-asr.json")
    candidate = read(candidate_job / "raw-asr.json")
    baseline_manifest = read(baseline_job / "manifest.json")
    candidate_manifest = read(candidate_job / "manifest.json")
    manifest = read(manifest_path)
    baseline_metrics = metrics(manifest, baseline, corpus)
    candidate_metrics = metrics(manifest, candidate, corpus)
    controls_path = Path(meta["controlEvidencePath"])
    controls = read(controls_path)
    inventory_path = Path(meta["modelInventoryPath"])
    inventory = read(inventory_path)
    inventory_paths = {item["path"] for item in inventory["files"]}
    baseline_error = baseline_metrics["speakerAttributedJapaneseError"]
    candidate_error = candidate_metrics["speakerAttributedJapaneseError"]
    implementation = meta.get("unchangedImplementations", {})
    logs = {
        key: (EVIDENCE_ROOT / f"{split}-{filename}").read_text(errors="replace")
        for key, filename in LOG_FILES.items()
    }
    expected_progress = {
        "baseline": ("W8A16", "W8A16"),
        "candidate": ("W32A32", "W16A16"),
    }
    progress_retained = all(
        f"Downloading SpeakerKit segmenter {variants[0]} and embedder {variants[1]}"
        in logs[key]
        and f"SpeakerKit ready: segmenter {variants[0]}, embedder {variants[1]}"
        in logs[key]
        for key, variants in expected_progress.items()
    )
    gates = {
        "provenance": (
            sha256(source_path) == meta["sourceSHA256"]
            and sha256(manifest_path) == meta["corpusManifestSHA256"]
            and sha256(upstream_path) == meta["frozenUpstreamEvidenceSHA256"]
            and sha256(root / "controls.json") == meta["controlEvidenceSHA256"]
            and sha256(controls_path) == meta["controlEvidenceSHA256"]
            and artifact_hashes_match(meta, "baseline", baseline_job)
            and artifact_hashes_match(meta, "candidate", candidate_job)
            and retained_artifacts_match(meta, split, "baseline", "quantized")
            and retained_artifacts_match(meta, split, "candidate", "full")
            and execution_provenance_matches(meta)
            and current_implementation_matches(meta)
        ),
        "oneVariable": one_variable(meta),
        "frozenASRAlignment": (
            baseline["rawASR"] == candidate["rawASR"]
            and baseline["alignment"]["chunks"] == candidate["alignment"]["chunks"]
            and baseline["alignment"]["mergedCues"]
            == candidate["alignment"]["mergedCues"]
            and baseline["sampleCount"] == candidate["sampleCount"]
            and baseline["sampleRate"] == candidate["sampleRate"]
        ),
        "sameSpeakerKitRevision": (
            baseline["diarization"]["modelID"]
            == candidate["diarization"]["modelID"]
            == meta["speakerKit"]["modelID"]
            and baseline["diarization"]["revision"]
            == candidate["diarization"]["revision"]
            == meta["speakerKit"]["revision"]
        ),
        "downloadAndProgressEvidence": (
            meta["speakerKit"]["downloadPatterns"] == {
                "baseline": [
                    "speaker_segmenter/pyannote-v3/W8A16/*",
                    "speaker_embedder/pyannote-v3/W8A16/*",
                    "speaker_clusterer/pyannote-v4/W32A32/*",
                ],
                "candidate": [
                    "speaker_segmenter/pyannote-v3/W32A32/*",
                    "speaker_embedder/pyannote-v3/W16A16/*",
                    "speaker_clusterer/pyannote-v4/W32A32/*",
                ],
            }
            and progress_retained
            and sha256(inventory_path) == meta["modelInventorySHA256"]
            and all(
                any(fragment in path for path in inventory_paths)
                for fragment in (
                    "speaker_segmenter/pyannote-v3/W8A16/",
                    "speaker_embedder/pyannote-v3/W8A16/",
                    "speaker_segmenter/pyannote-v3/W32A32/",
                    "speaker_embedder/pyannote-v3/W16A16/",
                    "speaker_clusterer/pyannote-v4/W32A32/",
                )
            )
        ),
        "completeDiarizationEvidence": (
            complete_evidence(baseline) and complete_evidence(candidate)
        ),
        "validDeliverables": (
            valid_deliverables(baseline_manifest)
            and valid_deliverables(candidate_manifest)
        ),
        "translationUnchanged": translation_unchanged(
            baseline["translation"], candidate["translation"]
        ),
        "lifecycleAndMemoryRelease": (
            model_lifecycle(baseline) and model_lifecycle(candidate)
        ),
        "runtimeAndMemoryMeasured": all(
            isinstance(value, (int, float)) and math.isfinite(value) and value > 0
            for value in (
                baseline_metrics["runtimeSeconds"],
                candidate_metrics["runtimeSeconds"],
                baseline_metrics["peakMemoryBytes"],
                candidate_metrics["peakMemoryBytes"],
            )
        ) and candidate_metrics["peakMemoryBytes"] <= MAX_PRODUCT_MEMORY_BYTES,
        "zeroDuplication": (
            baseline_metrics["duplicationCount"] == 0
            and candidate_metrics["duplicationCount"] == 0
        ),
        "speakerAttributedJapaneseGain": (
            candidate_error["ratePercent"] < baseline_error["ratePercent"]
        ),
        "noSpokenContentLoss": (
            candidate_error["unattributedCharacterCount"]
            <= baseline_error["unattributedCharacterCount"]
        ),
        "declaredSpeakerMetricsDoNotRegress": (
            candidate_metrics["DERPercent"] <= baseline_metrics["DERPercent"]
            and candidate_metrics["JERPercent"] <= baseline_metrics["JERPercent"]
            and candidate_metrics["speakerCountAbsoluteError"]
            <= baseline_metrics["speakerCountAbsoluteError"]
        ),
        "translationAndLiveUnchanged": (
            controls["translationTests"]
            and controls["liveTests"]
            and all(
                item["baseSHA256"] == item["candidateSHA256"]
                for item in implementation.values()
            )
        ),
        "deterministicControls": controls_are_valid(controls),
    }
    return {
        "corpusID": corpus,
        "role": meta["corpusRole"],
        "baseline": baseline_metrics,
        "candidate": candidate_metrics,
        "gates": gates,
        "eligible": all(gates.values()),
        "rawArtifacts": {
            "baseline": {
                "rawASR": str(EVIDENCE_ROOT / f"{split}-quantized-raw-asr.json.gz"),
                "manifest": str(EVIDENCE_ROOT / f"{split}-quantized-manifest.json"),
                "log": str(EVIDENCE_ROOT / f"{split}-quantized.log"),
            },
            "candidate": {
                "rawASR": str(EVIDENCE_ROOT / f"{split}-full-raw-asr.json.gz"),
                "manifest": str(EVIDENCE_ROOT / f"{split}-full-manifest.json"),
                "log": str(EVIDENCE_ROOT / f"{split}-full.log"),
            },
            "runMetadata": str(EVIDENCE_ROOT / f"{split}-run-meta.json"),
            "modelInventory": str(EVIDENCE_ROOT / "model-cache-manifest.json"),
            "controls": str(controls_path),
        },
    }


def markdown(report: dict) -> str:
    lines = [
        "# E16 — SpeakerKit full-precision variants",
        "",
        "Only SpeakerKit model precision changes: segmenter/embedder "
        "`W8A16/W8A16` becomes `W32A32/W16A16`. ASR, alignment, selected "
        "non-exclusive reconciliation, principal attribution, automatic speaker count, "
        "clustering defaults, full redundancy and translation stay fixed.",
        "",
        "| Corpus | Precision | DER | JER | Speaker JA error | Count error | "
        "Overlap P/R/F1 | Runtime | Preparation | Peak memory |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in report["rows"]:
        for label, key in (("W8A16/W8A16", "baseline"), ("W32A32/W16A16", "candidate")):
            value = row[key]
            overlap = value["overlap"]
            lines.append(
                f'| {row["corpusID"]} ({row["role"]}) | {label} | '
                f'{value["DERPercent"]:.2f}% | {value["JERPercent"]:.2f}% | '
                f'{value["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | '
                f'{value["speakerCountAbsoluteError"]} | '
                f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/'
                f'{overlap["f1Percent"]:.1f}% | {value["runtimeSeconds"]:.2f}s | '
                f'{value["preparationSeconds"]:.2f}s | '
                f'{value["peakMemoryBytes"] / 1_048_576:.0f} MiB |'
            )
    if not report["holdoutRun"]:
        lines += ["", "Untouched holdout: not run."]
    lines += [
        "",
        f'**Decision:** {report["decision"]}.',
        "",
        "Raw runs, manifests, logs, model variants, revisions and hashes are retained "
        "under `docs/japanese-live/experiments/evidence/E16/`.",
        "",
    ]
    return "\n".join(lines)


def self_test() -> None:
    assert LOG_FILES == {
        "baseline": "quantized.log", "candidate": "full.log",
    }
    meta = {"settings": {
        "baseline": {"precision": "quantized", "segmenterVariant": "W8A16",
                     "embedderVariant": "W8A16", "threshold": None},
        "candidate": {"precision": "full", "segmenterVariant": "W32A32",
                      "embedderVariant": "W16A16", "threshold": None},
    }}
    assert one_variable(meta)
    raw = {"modelEvents": [
        {"kind": kind, "modelID": "argmaxinc/speakerkit-coreml"}
        for kind in ("load-started", "load-completed", "unload-completed",
                     "memory-release-checked")
    ]}
    assert model_lifecycle(raw)
    assert valid_deliverables({
        "status": "completed", "failures": [],
        "generatedFiles": [{"path": path} for path in EXPECTED_FILES],
    })
    assert translation_unchanged(
        {"response": '{"id":"one","text":"English"}', "attempts": []},
        {"response": '{"text":"English","id":"one"}', "attempts": []},
    )
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        path = temporary_root / "model.bin"
        path.write_bytes(b"model")
        assert inventory_model_cache(temporary_root)["files"] == [{
            "path": "model.bin", "size": 5,
            "sha256": hashlib.sha256(b"model").hexdigest(),
        }]
        job = temporary_root / "job"
        job.mkdir()
        artifact_meta = {"artifactSHA256": {"baseline": {}}}
        for name in EXPECTED_FILES:
            artifact = job / name
            artifact.write_text(name)
            artifact_meta["artifactSHA256"]["baseline"][name] = sha256(artifact)
        assert artifact_hashes_match(artifact_meta, "baseline", job)
        artifact_meta["artifactSHA256"]["baseline"].pop("manifest.json")
        assert not artifact_hashes_match(artifact_meta, "baseline", job)

        raw_logs = {}
        for key in CONTROL_LOGS:
            log = temporary_root / f"{key}.log"
            log.write_text(key)
            raw_logs[key] = {"path": str(log), "sha256": sha256(log)}
        controls = {flag: True for flag in CONTROL_FLAGS}
        controls["rawLogs"] = raw_logs
        assert controls_are_valid(controls)
        controls["rawLogs"].pop("mlxMetallib")
        assert not controls_are_valid(controls)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--inventory-cache", type=Path)
    parser.add_argument("--inventory-output", type=Path)
    args = parser.parse_args()
    if args.inventory_cache or args.inventory_output:
        assert args.inventory_cache and args.inventory_output
        result = inventory_model_cache(args.inventory_cache)
        args.inventory_output.parent.mkdir(parents=True, exist_ok=True)
        args.inventory_output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n"
        )
        return
    if args.self_test:
        self_test()
        return
    assert args.root and args.json and args.markdown
    rows = [
        corpus_report(args.root, corpus)
        for corpus in CORPORA if (args.root / corpus / "run-meta.json").exists()
    ]
    development = next(row for row in rows if row["role"] == "development")
    holdout = next((row for row in rows if row["role"] == "untouched-holdout"), None)
    if not development["eligible"]:
        decision = "do not promote; development quality or veto gates failed"
    elif holdout is None:
        decision = "development candidate eligible; holdout remains untouched"
    elif holdout["eligible"]:
        decision = "promote full-precision SpeakerKit"
    else:
        decision = "do not promote; untouched holdout did not confirm every gate"
    report = {
        "schemaVersion": 1,
        "experiment": "E16-speakerkit-precision",
        "primaryMetric": "speaker-attributed Japanese error rate",
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
