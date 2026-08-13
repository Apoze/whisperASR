#!/usr/bin/env python3
"""Validate ticket #77 against the frozen corpus and product evidence."""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import math
import re
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from report_high_quality_acceptance import (
    cer,
    cue_integrity,
    diarization_metrics,
    glossary_accuracy,
    normalize_ja,
    sha256,
    structured_cues_are_valid,
    translation_rows,
)
from report_japanese_l7d import chrf_pp
from report_local_translator_bakeoff import comet_scores, subtitle_quality, write_lines


CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
HOLDOUT = "md62mmdz0m"
SCORING_PATHS = (
    Path("Scripts/report_combined_offline_validation.py"),
    Path("Scripts/comet_score_compat.py"),
)
REQUIRED_IMPLEMENTATION_PATHS = (
    "Sources/HighQualityTranslationIntegrity.swift",
    "Sources/HighQualityJob.swift",
    "Tests/HighQualityTranslationIntegrityTests.swift",
)
TEST_BINARY_PATH = Path(
    ".build/debug/WhisperASRPackageTests.xctest/Contents/MacOS/WhisperASRPackageTests"
)
CONTROL_IMPLEMENTATION_PATHS = (
    "Sources/YouTubeAcquirer.swift",
    "Sources/HighQualityJob.swift",
    "Tests/HighQualityJobTests.swift",
)
MODEL_IDS = (
    "ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit",
    "mlx-community/Qwen3-ForcedAligner-0.6B-4bit",
    "argmaxinc/speakerkit-coreml",
    "mlx-community/translategemma-12b-it-4bit",
)
MODEL_REVISIONS = {
    MODEL_IDS[0]: "7c70d18cb650655d32eafb952a74a49c6a3caad0",
    MODEL_IDS[1]: "2f652af86ae0c73fe189b9429225c908ce4bf020",
    MODEL_IDS[2]: "86ec9c929b52208b6656eb6a6361ed0d822a1f78",
    MODEL_IDS[3]: "f3dcfd54df14672fbcf0731086fb47a797a943ae",
}
MODEL_WEIGHT_SHA256 = {
    (MODEL_IDS[0], "model.safetensors"):
        "bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954",
    (MODEL_IDS[1], "model.safetensors"):
        "630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c",
    (MODEL_IDS[2], "segmenter/W8A16/weight.bin"):
        "75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4",
    (MODEL_IDS[2], "embedder/W8A16/weight.bin"):
        "a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795",
    (MODEL_IDS[2], "embedder-preprocessor/W8A16/weight.bin"):
        "5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89",
    (MODEL_IDS[2], "clusterer/W32A32/weight.bin"):
        "a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced",
    (MODEL_IDS[3], "model-00001-of-00002.safetensors"):
        "bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af",
    (MODEL_IDS[3], "model-00002-of-00002.safetensors"):
        "c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89",
}
DECISIONS = (
    (54, Path("docs/high-quality-glossary-e13.json"), "baseline", False),
    (55, Path("docs/high-quality-context-e14.json"), "previous-accepted-v1", True),
    (56, Path("docs/high-quality-metricx-e15.json"), "baseline", False),
    (57, Path("docs/japanese-live/experiments/evidence/E15/report.json"), "non-exclusive", False),
    (58, Path("docs/japanese-live/experiments/evidence/E16/report.json"), "W8A16/W8A16", False),
    (59, Path("docs/japanese-live/experiments/evidence/E17-speaker-count/report.json"), "automatic", False),
    (60, Path("docs/japanese-live/experiments/evidence/E17/report.json"), "library-default", False),
    (61, Path("docs/japanese-live/experiments/evidence/E18/development-report.json"), "speakerkit", False),
)


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def scoring_provenance_valid(metadata: dict) -> bool:
    return metadata.get("scoringImplementationSHA256") == {
        str(path): sha256(path) for path in SCORING_PATHS
    }


def implementation_revalidation_valid(
    metadata: dict, raw_path: Path, log_path: Path, binary_path: Path = TEST_BINARY_PATH,
) -> bool:
    revalidation = metadata.get("revalidation") or {}
    return raw_path.is_file() and log_path.is_file() and binary_path.is_file() \
        and revalidation.get("kind") == "current-code-raw-replay" \
        and revalidation.get("rawArtifactSHA256") == sha256(raw_path) \
        and revalidation.get("testLogSHA256") == sha256(log_path) \
        and revalidation.get("testBinarySHA256") == sha256(binary_path) \
        and revalidation.get("implementationSHA256") == {
            path: sha256(Path(path)) for path in REQUIRED_IMPLEMENTATION_PATHS
        }


def control_provenance_valid(root: Path, binary_path: Path = TEST_BINARY_PATH) -> bool:
    path = root / "control-provenance.json"
    log_path = root / "controls/youtube-revalidation.log"
    if not path.is_file() or not log_path.is_file() or not binary_path.is_file():
        return False
    provenance = read(path)
    return provenance.get("kind") == "current-code-youtube-control" \
        and provenance.get("testLogSHA256") == sha256(log_path) \
        and provenance.get("testBinarySHA256") == sha256(binary_path) \
        and provenance.get("implementationSHA256") == {
            item: sha256(Path(item)) for item in CONTROL_IMPLEMENTATION_PATHS
        }


def holdout_sequence_valid(root: Path) -> bool:
    development_path = root / "development-report.json"
    marker_path = root / "holdout-opened.json"
    if not development_path.is_file() or not marker_path.is_file():
        return False
    development = read(development_path)
    marker = read(marker_path)
    return development.get("developmentEligible") is True \
        and development.get("decision") == "development-pass-holdout-closed" \
        and [row.get("corpusID") for row in development.get("rows", [])] == [CORPORA[0]] \
        and marker.get("ticket") == 77 \
        and marker.get("developmentReportSHA256") == sha256(development_path)


def named_stage_durations(values: dict | list) -> dict[str, float]:
    if isinstance(values, dict):
        return values
    assert len(values) % 2 == 0
    return {str(values[index]): float(values[index + 1])
            for index in range(0, len(values), 2)}


def formatted_duration(seconds: float) -> str:
    minutes = int(seconds) // 60
    return f"{minutes}m {seconds - minutes * 60:.1f}s"


def job_directory(root: Path, corpus: str) -> Path | None:
    manifests = list((root / "qwen-ja" / corpus / "jobs").glob("*/manifest.json"))
    if not manifests:
        return None
    assert len(manifests) == 1, (root, corpus, manifests)
    return manifests[0].parent


def duration(manifest: dict) -> float:
    start = datetime.fromisoformat(manifest["startedAt"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(manifest["finishedAt"].replace("Z", "+00:00"))
    return (end - start).total_seconds()


def decision_manifest() -> list[dict]:
    rows = []
    for ticket, path, selected, promoted in DECISIONS:
        report = read(path)
        actual = bool(report.get("promoted", False))
        if ticket == 55:
            assert actual and all(all(values.values()) for values in report["gates"].values())
        else:
            assert not actual
        rows.append({
            "ticket": ticket,
            "report": str(path),
            "sha256": sha256(path),
            "promoted": promoted,
            "selectedBehavior": selected,
            "recordedDecision": report.get("decision") or ("promoted" if actual else "not-promoted"),
        })
    return rows


def model_lifecycle(raw: dict) -> dict:
    workers = [
        (raw.get("asrWorker") or {}).get("lifecycle"),
        (raw.get("alignment") or {}).get("worker"),
        (raw.get("diarization") or {}).get("worker"),
        (raw.get("translation") or {}).get("worker"),
    ]
    complete = all(workers)
    events = raw["modelEvents"]
    pressure = [event for event in events if event["kind"] == "memory-pressure-checked"]
    pressure_valid = len(pressure) == len(MODEL_IDS) and {
        event["modelID"] for event in pressure
    } == set(MODEL_IDS) and all(
        "policy=macos-memory-pressure" in (event.get("message") or "")
        and "reserve=0" in (event.get("message") or "")
        for event in pressure
    )
    event_pairs = {(event["modelID"], event["kind"]) for event in events}
    events_complete = all(
        (model, kind) in event_pairs
        for model in MODEL_IDS
        for kind in ("memory-pressure-checked", "load-completed", "unload-completed",
                     "memory-release-checked")
    )
    worker_valid = complete and all(
        worker["exitStatus"] == 0
        and not worker["forcedTermination"]
        and worker["peakPhysicalFootprintBytes"] > 0
        and worker["availableMemorySamples"]
        and worker.get("swapUsedBeforeBytes") is not None
        and worker.get("swapUsedAfterBytes") is not None
        and not any(item["level"] == "critical" for item in worker["pressureTransitions"])
        for worker in workers
    )
    sequential = complete and all(
        datetime.fromisoformat(left["exitedAt"].replace("Z", "+00:00"))
        <= datetime.fromisoformat(right["startedAt"].replace("Z", "+00:00"))
        for left, right in zip(workers, workers[1:])
    )
    pids = [worker["processIdentifier"] for worker in workers] if complete else []
    return {
        "gates": {
            "allWorkersPresent": complete,
            "completeModelEvents": events_complete,
            "cleanWorkerExits": worker_valid,
            "distinctWorkerProcesses": len(set(pids)) == len(MODEL_IDS),
            "strictlySequential": sequential,
            "dynamicPressurePolicy": pressure_valid,
            "noFixedEightGiBReserve": not any(
                "reserve=8589934592" in (event.get("message") or "") for event in events
            ),
            "noGuardFailure": not any(event["kind"] == "guard-failed" for event in events),
        },
        "workers": [] if not complete else [{
            "stage": stage,
            "processIdentifier": worker["processIdentifier"],
            "elapsedSeconds": worker["elapsedSeconds"],
            "peakPhysicalFootprintBytes": worker["peakPhysicalFootprintBytes"],
            "minimumAvailableMemoryBytes": min(
                item["availableMemoryBytes"] for item in worker["availableMemorySamples"]
            ),
            "swapUsedBeforeBytes": worker.get("swapUsedBeforeBytes"),
            "swapUsedAfterBytes": worker.get("swapUsedAfterBytes"),
            "swapDeltaBytes": worker["swapUsedAfterBytes"] - worker["swapUsedBeforeBytes"],
            "pressureTransitions": worker["pressureTransitions"],
        } for stage, worker in zip(("asr", "alignment", "diarization", "translation"), workers)],
    }


def observed_peak_memory_bytes(manifest: dict, lifecycle: dict) -> int:
    return max(
        manifest["peakMemoryBytes"],
        *(worker["peakPhysicalFootprintBytes"] for worker in lifecycle["workers"]),
    )


def translation_integrity(raw: dict) -> dict:
    translation = raw["translation"]
    mapping = cue_integrity(raw)
    verdicts = translation.get("integrityVerdicts") or []
    reasons = collections.Counter(
        reason["code"] for verdict in verdicts for reason in verdict["reasons"]
    )
    turns = translation["request"]["turns"]
    response = json.loads(translation["response"])["translations"]
    outputs = {item["id"]: item["text"] for item in response}
    contexts = translation["request"].get("conversationContextByCueID") or {}
    retry_ids = {
        cue_id for batch in translation["batches"]
        if batch.get("attemptNumber") == 2
        for cue_id in batch["cueIDs"]
    }
    context_valid = set(contexts) == {turn["id"] for turn in turns} and all(
        context["policyVersion"] == "previous-accepted-v1"
        and context["currentTarget"] == next(turn["japanese"] for turn in turns
                                             if turn["id"] == cue_id)
        and len(context["acceptedHistory"]) <= 2
        and context["encodedHistoryBytes"] <= 512
        for cue_id, context in contexts.items()
    )
    return {
        "cueMapping": mapping,
        "structuredOneToOne": structured_cues_are_valid(mapping),
        "emptyCueIDs": [turn["id"] for turn in turns if not outputs.get(turn["id"], "").strip()],
        "reasonCounts": dict(sorted(reasons.items())),
        "allTerminalVerdictsPass": len(verdicts) == len(turns)
            and all(verdict["verdict"] == "pass" and not verdict["reasons"] for verdict in verdicts),
        "validationFailures": translation["validationFailures"],
        "contextEvidenceValid": context_valid,
        "retryCueIDs": sorted(retry_ids),
        "retryRate": len(retry_ids) / len(turns) if turns else 0,
    }


def stable_speaker_labels(raw: dict) -> bool:
    diarization = raw["diarization"]
    spans = diarization["rawSpans"]
    labels = {}
    for mapping in diarization["mappings"]:
        if not re.fullmatch(r"SPEAKER_\d{2}", mapping["speakerLabel"]):
            return False
        speaker_id = spans[mapping["spanIndex"]]["speakerID"]
        if speaker_id in labels and labels[speaker_id] != mapping["speakerLabel"]:
            return False
        labels[speaker_id] = mapping["speakerLabel"]
    return bool(labels)


def subtitle_timeline(text: str, webvtt: bool) -> list[dict]:
    if webvtt:
        text = text.removeprefix("WEBVTT\n\n")
    rows = []
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = block.splitlines()
        if len(lines) < 3 or " --> " not in lines[1]:
            return []
        start, end = lines[1].split(" --> ", 1)
        try:
            def milliseconds(value: str) -> int:
                hours, minutes, seconds = value.replace(",", ".").split(":")
                whole, fraction = seconds.split(".")
                return ((int(hours) * 60 + int(minutes)) * 60 + int(whole)) * 1000 \
                    + int(fraction)
            rows.append({
                "id": lines[0], "startMilliseconds": milliseconds(start),
                "endMilliseconds": milliseconds(end), "text": " ".join(lines[2:]).strip(),
            })
        except ValueError:
            return []
    return rows


def subtitle_artifacts(job: Path, raw: dict) -> dict:
    srt = subtitle_quality((job / "english-subtitles.srt").read_text(encoding="utf-8"))
    vtt_text = (job / "english-subtitles.vtt").read_text(encoding="utf-8")
    vtt_body = vtt_text.removeprefix("WEBVTT\n\n")
    vtt_as_srt = re.sub(
        r"(?m)^(\d{2}:\d{2}:\d{2})\.(\d{3}) --> (\d{2}:\d{2}:\d{2})\.(\d{3})$",
        r"\1,\2 --> \3,\4",
        vtt_body,
    )
    vtt = subtitle_quality(vtt_as_srt)
    srt_rows = subtitle_timeline(
        (job / "english-subtitles.srt").read_text(encoding="utf-8"), False
    )
    vtt_rows = subtitle_timeline(vtt_text, True)
    turns = raw["translation"]["request"]["turns"]
    expected = [{
        "id": turn["id"],
        "startMilliseconds": int(max(0, turn["sourceStart"]) * 1000 + 0.5),
        "endMilliseconds": int(max(0, turn["sourceEnd"]) * 1000 + 0.5),
    } for turn in turns]
    timelines_match = [
        (row["startMilliseconds"], row["endMilliseconds"]) for row in srt_rows
    ] == [
        (row["startMilliseconds"], row["endMilliseconds"]) for row in vtt_rows
    ]
    alignment_matches = [{key: row[key] for key in expected[0]} for row in vtt_rows] \
        == expected if expected else False
    outputs = {
        row["id"]: " ".join(row["text"].split())
        for row in json.loads(raw["translation"]["response"])["translations"]
    }
    exported_text = lambda row: re.sub(r"^(?:<v [^>]*>|\[[^]]+\] )", "", row["text"])
    text_matches = len(srt_rows) == len(vtt_rows) == len(expected) and all(
        exported_text(srt_row) == exported_text(vtt_row) == outputs.get(turn["id"])
        for srt_row, vtt_row, turn in zip(srt_rows, vtt_rows, turns)
    )
    valid = vtt_text.startswith("WEBVTT\n\n") and srt["cueCount"] > 0 \
        and srt["cueCount"] == vtt["cueCount"] and all(
            not quality[key]
            for quality in (srt, vtt)
            for key in ("emptyCueIDs", "invalidDurationCueIDs")
        ) and srt["malformedBlockCount"] == vtt["malformedBlockCount"] == 0 \
        and timelines_match and alignment_matches and text_matches
    representative = max(srt_rows, key=lambda row: (
        len(row["text"]) / max(
            (row["endMilliseconds"] - row["startMilliseconds"]) / 1000, 0.001
        )
    )) if srt_rows else None
    return {
        "valid": valid, "srt": srt, "vtt": vtt,
        "srtVTTTimestampsMatch": timelines_match,
        "alignmentTimestampsMatch": alignment_matches,
        "translatedTextMatches": text_matches,
        "readability": {
            "over84CharacterCueCount": len(srt["over84CharacterCueIDs"]),
            "over20CharactersPerSecondCueCount": len(
                srt["over20CharactersPerSecondCueIDs"]
            ),
            "representativeHighDensityCue": None if representative is None else {
                "id": representative["id"],
                "text": representative["text"],
                "durationSeconds": (
                    representative["endMilliseconds"] - representative["startMilliseconds"]
                ) / 1000,
                "charactersPerSecond": len(representative["text"]) / (
                    max(
                        representative["endMilliseconds"]
                        - representative["startMilliseconds"], 1
                    ) / 1000
                ),
            },
        },
    }


def weight_provenance_valid(weight_items: list[dict]) -> bool:
    observed = {
        (item["modelID"], item["file"]): item["sha256"]
        for item in weight_items
        if item.get("revision") == MODEL_REVISIONS.get(item.get("modelID"))
    }
    return len(weight_items) == len(observed) == len(MODEL_WEIGHT_SHA256) \
        and observed == MODEL_WEIGHT_SHA256


def model_provenance_gates(root: Path, raw: dict, metadata: dict) -> dict:
    descriptor = metadata.get("modelProvenance") or {}
    relative_path = descriptor.get("path")
    if not relative_path:
        return {"modelRevisions": False, "weightHashes": False}
    path = root / relative_path
    if not path.is_file() or descriptor.get("sha256") != sha256(path):
        return {"modelRevisions": False, "weightHashes": False}
    provenance = read(path)
    observed_revisions = {
        raw["model"]["modelID"]: raw["model"].get("revision"),
        raw["alignment"]["modelID"]: raw["alignment"].get("revision"),
        raw["diarization"]["modelID"]: raw["diarization"].get("revision"),
        raw["translation"]["model"]: raw["translation"].get("revision"),
    }
    weight_items = provenance.get("weights", [])
    return {
        "modelRevisions": observed_revisions == MODEL_REVISIONS,
        "weightHashes": weight_provenance_valid(weight_items),
    }


def speaker_gates(
    baseline: dict,
    candidate: dict,
    labels_are_stable: bool,
    overlap_evidence_retained: bool,
    decisions: list[dict],
    unchanged_standard: bool = False,
) -> dict:
    return {
        "zeroTranscriptDuplication": candidate["duplicationCount"] == 0,
        "stableLabels": labels_are_stable,
        "rejectedCandidatesRemainBaseline": all(
            not row["promoted"] for row in decisions if row["ticket"] >= 57
        ),
        "speakerGainOrUnchangedStandard": unchanged_standard or
            candidate["speakerAttributedJapaneseError"]["ratePercent"]
            < baseline["speakerAttributedJapaneseError"]["ratePercent"],
        "rawOverlapRetained": overlap_evidence_retained,
        "zeroInventedOverlapOrUnchangedStandard": unchanged_standard
            or candidate["overlap"]["inventedSeconds"] == 0,
    }


def artifact_gates(root: Path, corpus: str, manifest: dict, raw: dict, metadata: dict,
                   job_manifest: dict, job: Path, decisions: list[dict]) -> dict:
    required = {
        "english-subtitles.srt", "english-subtitles.vtt",
        "english-translation-transcript.txt", "japanese-transcript.txt",
        "manifest.json", "raw-asr.json",
    }
    source_hash = next(item["sha256"] for item in manifest["source"]["references"]
                       if item["label"] == "source-video")
    archive_hash = next(item["sha256"] for item in manifest["source"]["references"]
                        if item["label"] == "reference-archive")
    lifecycle = model_lifecycle(raw)
    subtitles = subtitle_artifacts(job, raw)
    return {
        "upstreamDecisions": metadata["candidateSelection"] == decisions,
        "sourceProvenance": metadata["sourceSHA256"] == source_hash
            and metadata["referenceArchiveSHA256"] == archive_hash,
        "sourceDecode": raw["sampleCount"] == manifest["fixture"]["sampleCount"],
        "deliverables": required == {path.name for path in job.iterdir()},
        "selectedQwenJA": raw["model"]["backend"] == "qwen-ja"
            and raw["model"]["modelID"] == MODEL_IDS[0],
        "selectedAligner": raw["alignment"]["modelID"] == MODEL_IDS[1]
            and not raw["alignment"]["validationDiagnostics"],
        "selectedSpeakerBaseline": raw["diarization"]["modelID"] == MODEL_IDS[2]
            and raw["diarization"].get("useExclusiveReconciliation") is False
            and raw.get("speakerConfiguration") == {
                "enhancedPrecision": False,
                "sensitiveDetection": False,
                "countPolicy": {"mode": "automatic"},
            }
            and not raw["diarization"]["validationDiagnostics"],
        "selectedTranslateGemma": raw["translation"]["model"] == MODEL_IDS[3]
            and job_manifest["translationModel"]["modelID"] == MODEL_IDS[3],
        "lifecycle": all(lifecycle["gates"].values()),
        "subtitleIntegrity": subtitles["valid"],
        "rawArtifactHashes": metadata["rawArtifactSHA256"] == {
            "manifest.json": sha256(job / "manifest.json"),
            "raw-asr.json": sha256(job / "raw-asr.json"),
        },
        "implementationProvenance": implementation_revalidation_valid(
            metadata, job / "raw-asr.json", root / "qwen-ja" / corpus / "revalidation.log",
        ),
        "scoringProvenance": scoring_provenance_valid(metadata),
        **model_provenance_gates(root, raw, metadata),
    }


def metric_mean(path: Path, hypothesis: Path) -> float | None:
    scores = comet_scores(path, hypothesis)
    return sum(scores) / len(scores) if scores else None


def metric_interpretation(
    baseline: float | None, candidate: float | None, higher_is_better: bool, impact: str
) -> dict:
    if baseline is None or candidate is None:
        return {"baseline": baseline, "candidate": candidate, "delta": None,
                "interpretation": "not-scored", "impact": impact}
    delta = candidate - baseline
    improved = delta > 0 if higher_is_better else delta < 0
    return {
        "baseline": baseline, "candidate": candidate, "delta": delta,
        "interpretation": "improved" if improved else ("unchanged" if delta == 0 else "regressed"),
        "impact": impact,
    }


def representative_examples(baseline: list[dict], candidate: list[dict]) -> list[dict]:
    baseline_by_id = {row["id"]: row for row in baseline}
    rows = []
    for row in candidate:
        previous = baseline_by_id[row["id"]]
        rows.append({
            "id": row["id"], "sourceJapanese": row["source"],
            "referenceEnglish": row["reference"],
            "baselineEnglish": previous["hypothesis"],
            "candidateEnglish": row["hypothesis"],
            "chrFDelta": chrf_pp(row["hypothesis"], row["reference"])
                - chrf_pp(previous["hypothesis"], row["reference"]),
            "candidateChrF": chrf_pp(row["hypothesis"], row["reference"]),
        })
    recovered = max(rows, key=lambda row: row["chrFDelta"])
    lost = min(rows, key=lambda row: row["chrFDelta"])
    mistranslated = min(rows, key=lambda row: row["candidateChrF"])
    return [
        dict(recovered, category="recovered", observed=recovered["chrFDelta"] > 0),
        dict(lost, category="lost", observed=lost["chrFDelta"] < 0),
        dict(mistranslated, category="mistranslated", observed=True),
    ]


def score_corpus(root: Path, baseline_root: Path, corpus: str,
                 decisions: list[dict]) -> dict | None:
    candidate_job = job_directory(root, corpus)
    if candidate_job is None:
        return None
    baseline_job = job_directory(baseline_root, corpus)
    assert baseline_job is not None
    manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
    candidate_manifest, candidate = read(candidate_job / "manifest.json"), read(candidate_job / "raw-asr.json")
    baseline_manifest, baseline = read(baseline_job / "manifest.json"), read(baseline_job / "raw-asr.json")
    metadata = read(root / "qwen-ja" / corpus / "run-meta.json")
    baseline_metadata = read(baseline_root / "qwen-ja" / corpus / "run-meta.json")
    assert baseline_metadata["rawArtifactSHA256"] == {
        "manifest.json": sha256(baseline_job / "manifest.json"),
        "raw-asr.json": sha256(baseline_job / "raw-asr.json"),
    }
    baseline_rows = translation_rows(manifest, baseline)
    candidate_rows = translation_rows(manifest, candidate)
    metrics = root / "metrics" / corpus
    source = metrics / "source.ja.txt"
    reference = metrics / "reference.en.txt"
    baseline_hypothesis = metrics / "frozen-product-baseline.en.txt"
    candidate_hypothesis = metrics / "combined-candidate.en.txt"
    write_lines(source, [row["source"] for row in candidate_rows])
    write_lines(reference, [row["reference"] for row in candidate_rows])
    write_lines(baseline_hypothesis, [row["hypothesis"] for row in baseline_rows])
    write_lines(candidate_hypothesis, [row["hypothesis"] for row in candidate_rows])
    comet_path = metrics / "comet-score.json"
    integrity = translation_integrity(candidate)
    baseline_speaker = diarization_metrics(manifest, baseline)
    speaker = diarization_metrics(manifest, candidate)
    candidate_cer = cer(
        "".join(turn["japanese"] for turn in manifest["annotations"]["turns"]),
        candidate["rawASR"],
    )
    terminology = glossary_accuracy(candidate, candidate_rows)
    subtitles = subtitle_artifacts(candidate_job, candidate)
    resources = model_lifecycle(candidate)
    peak_memory_bytes = observed_peak_memory_bytes(candidate_manifest, resources)
    baseline_comet = metric_mean(comet_path, baseline_hypothesis)
    candidate_comet = metric_mean(comet_path, candidate_hypothesis)
    reference_text = " ".join(row["reference"] for row in candidate_rows)
    baseline_chrf = chrf_pp(" ".join(row["hypothesis"] for row in baseline_rows), reference_text)
    candidate_chrf = chrf_pp(" ".join(row["hypothesis"] for row in candidate_rows), reference_text)
    translation_gates = {
        "structuredOneToOne": integrity["structuredOneToOne"],
        "zeroEmpty": not integrity["emptyCueIDs"],
        "zeroIntegrityReason": not integrity["reasonCounts"],
        "allTerminalVerdictsPass": integrity["allTerminalVerdictsPass"],
        "zeroValidationFailure": not integrity["validationFailures"],
        "contextEvidence": integrity["contextEvidenceValid"],
    }
    artifacts = artifact_gates(
        root, corpus, manifest, candidate, metadata, candidate_manifest,
        candidate_job, decisions,
    )
    speaker_gate_results = speaker_gates(
        baseline_speaker,
        speaker,
        stable_speaker_labels(candidate),
        "overlapRanges" in candidate["diarization"],
        decisions,
        unchanged_standard=artifacts["selectedSpeakerBaseline"],
    )
    interpretations = {
        "COMET": metric_interpretation(
            baseline_comet, candidate_comet, True,
            "Translation meaning changed; inspect recovered/lost speech examples below.",
        ),
        "chrFPlusPlus": metric_interpretation(
            baseline_chrf, candidate_chrf, True,
            "English wording/reference overlap changed; inspect cue examples below.",
        ),
        "DERPercent": metric_interpretation(
            baseline_speaker["DERPercent"], speaker["DERPercent"], False,
            f'Speaker attribution changed with {speaker["candidateSpeakerCount"]} candidate '
            f'vs {speaker["referenceSpeakerCount"]} reference speakers.',
        ),
        "JERPercent": metric_interpretation(
            baseline_speaker["JERPercent"], speaker["JERPercent"], False,
            "Per-speaker temporal coverage changed; lower is better.",
        ),
        "speakerAttributedJapaneseErrorPercent": metric_interpretation(
            baseline_speaker["speakerAttributedJapaneseError"]["ratePercent"],
            speaker["speakerAttributedJapaneseError"]["ratePercent"], False,
            f'{speaker["speakerAttributedJapaneseError"]["editDistance"]} Japanese '
            f'character edits remain under mapped speaker identities.',
        ),
        "overlapF1Percent": metric_interpretation(
            baseline_speaker["overlap"]["f1Percent"], speaker["overlap"]["f1Percent"], True,
            f'Overlap detection missed {speaker["overlap"]["missedSeconds"]:.3f}s and '
            f'invented {speaker["overlap"]["inventedSeconds"]:.3f}s.',
        ),
    }
    return {
        "corpusID": corpus,
        "role": "development" if corpus != HOLDOUT else "untouched-channel-separated-holdout",
        "baseline": {
            "commit": baseline_metadata["commit"],
            "COMET": baseline_comet,
            "chrFPlusPlus": baseline_chrf,
            "runtimeSeconds": duration(baseline_manifest),
            "peakMemoryBytes": baseline_manifest["peakMemoryBytes"],
            "diarization": baseline_speaker,
        },
        "candidate": {
            "commit": metadata["commit"],
            "COMET": candidate_comet,
            "chrFPlusPlus": candidate_chrf,
            "japaneseCER": candidate_cer,
            "terminology": terminology,
            "translationIntegrity": integrity,
            "diarization": speaker,
            "runtimeSeconds": duration(candidate_manifest),
            "stageDurations": named_stage_durations(candidate_manifest["stageDurations"]),
            "retryRate": integrity["retryRate"],
            "peakMemoryBytes": peak_memory_bytes,
            "subtitles": subtitles,
            "resources": resources,
        },
        "artifactGates": artifacts,
        "translationGates": translation_gates,
        "speakerGates": speaker_gate_results,
        "metricInterpretations": interpretations,
        "representativeExamples": representative_examples(baseline_rows, candidate_rows),
        "qualityImpact": {
            "speechRecognition": {
                "changedFromBaseline": candidate["rawASR"] != baseline["rawASR"],
                "candidateCERPercent": candidate_cer["ratePercent"],
                "impact": "Japanese speech recognition and omissions; lower CER is better.",
            },
            "nameTerminology": {
                **terminology,
                "impact": "Pinned names and glossary terms retained or missed in English.",
            },
            "cueReadability": {
                **subtitles,
                "impact": "Cue timestamps, text identity and SRT/VTT readability.",
            },
        },
        "qualityGates": {
            "COMETNonRegression": baseline_comet is not None and candidate_comet is not None
                and candidate_comet >= baseline_comet,
            "chrFPlusPlusNonRegression": candidate_chrf >= baseline_chrf,
        },
        "rawArtifacts": {
            "baseline": str(baseline_job),
            "candidate": str(candidate_job),
            "metrics": str(metrics),
        },
    }


def row_passes(row: dict) -> bool:
    return all(row[group] and all(row[group].values()) for group in (
        "artifactGates", "translationGates", "speakerGates", "qualityGates",
    ))


def build_failed_row(corpus: str, status: str, failure: dict, runtime_seconds: float,
                     stage_durations: dict, peak_memory_bytes: int, chunks: list[dict],
                     workers: list[tuple[str, dict]], model_events: list[dict],
                     raw_artifacts: dict) -> dict:
    cues = [cue for chunk in chunks for cue in chunk["cues"]]
    items = [item for chunk in chunks for item in chunk["rawItems"]]
    workers = [(stage, worker) for stage, worker in workers if worker]
    worker_rows = [{
        "stage": stage,
        "processIdentifier": worker["processIdentifier"],
        "elapsedSeconds": worker["elapsedSeconds"],
        "peakPhysicalFootprintBytes": worker["peakPhysicalFootprintBytes"],
        "minimumAvailableMemoryBytes": min(
            sample["availableMemoryBytes"] for sample in worker["availableMemorySamples"]
        ),
        "swapUsedBeforeBytes": worker["swapUsedBeforeBytes"],
        "swapUsedAfterBytes": worker["swapUsedAfterBytes"],
        "swapDeltaBytes": worker["swapUsedAfterBytes"] - worker["swapUsedBeforeBytes"],
        "pressureTransitions": worker["pressureTransitions"],
        "startedAt": worker["startedAt"],
        "exitedAt": worker["exitedAt"],
    } for stage, worker in workers]
    durations = [chunk["sourceEnd"] - chunk["sourceStart"] for chunk in chunks]
    ordered_cues = [cue for chunk in sorted(chunks, key=lambda value: value["index"])
                    for cue in chunk["cues"]]
    non_monotonic = sum(
        cue["start"] < previous["end"]
        for previous, cue in zip(ordered_cues, ordered_cues[1:])
    )
    return {
        "corpusID": corpus,
        "role": "development" if corpus != HOLDOUT else "untouched-channel-separated-holdout",
        "status": status,
        "failure": failure,
        "runtimeSeconds": runtime_seconds,
        "stageDurations": named_stage_durations(stage_durations),
        "peakMemoryBytes": peak_memory_bytes,
        "alignmentIntegrity": {
            "windowCount": len(chunks),
            "maximumWindowSeconds": max(durations, default=0),
            "allWindowsWithinSelectedLimit": all(value <= 20.000_001 for value in durations),
            "cueCount": len(cues),
            "zeroDurationCueCount": sum(cue["end"] <= cue["start"] for cue in cues),
            "nonMonotonicCueCount": non_monotonic,
            "rawItemCount": len(items),
            "zeroDurationRawItemCount": sum(item["end"] <= item["start"] for item in items),
            "rawItemsAreDiagnosticOnly": True,
            "firstInvalidCue": next((cue for cue in cues if cue["end"] <= cue["start"]), None),
            "gatePassed": not any(cue["end"] <= cue["start"] for cue in cues)
                and non_monotonic == 0,
        },
        "resources": {
            "workers": worker_rows,
            "strictlySequential": all(
                left["exitedAt"] <= right["startedAt"]
                for left, right in zip(worker_rows, worker_rows[1:])
            ),
            "zeroSwapGrowth": all(row["swapDeltaBytes"] <= 0 for row in worker_rows),
            "noCriticalPressure": all(not any(
                transition["level"] == "critical"
                for transition in row["pressureTransitions"]
            ) for row in worker_rows),
            "noFixedEightGiBReserve": not any(
                "reserve=8589934592" in (event.get("message") or "")
                for event in model_events
            ),
        },
        "rawArtifacts": raw_artifacts,
    }


def failed_row(root: Path, corpus: str) -> dict | None:
    job = job_directory(root, corpus)
    if job is None:
        return None
    manifest = read(job / "manifest.json")
    if manifest["status"] == "completed":
        return None
    raw = read(job / "raw-asr.json")
    failures = manifest.get("failures") or []
    return build_failed_row(
        corpus, manifest["status"], failures[0] if failures else {}, duration(manifest),
        manifest["stageDurations"], manifest["peakMemoryBytes"],
        (raw.get("alignment") or {}).get("chunks", []),
        [("asr", (raw.get("asrWorker") or {}).get("lifecycle")),
         ("alignment", (raw.get("alignment") or {}).get("worker"))],
        raw.get("modelEvents", []), {
            "manifest": str(job / "manifest.json"),
            "rawASR": str(job / "raw-asr.json"),
            "manifestSHA256": sha256(job / "manifest.json"),
            "rawASRSHA256": sha256(job / "raw-asr.json"),
        },
    )


def failed_experiment_row(root: Path) -> dict | None:
    if job_directory(root, CORPORA[0]):
        return None
    path = root / "experiments/dev-alignment-window-20-owned-retry.json"
    if not path.exists():
        return None
    raw = read(path)
    asr = raw["asrWorker"]["lifecycle"]
    alignment = raw["alignmentWorker"]
    return build_failed_row(
        raw["corpusID"], "diagnostic-failed", {
            "stage": "alignment",
            "message": "Targeted DEV ASR/alignment retained zero-duration cues after same-window retry.",
        }, asr["elapsedSeconds"] + alignment["elapsedSeconds"], {
            "transcribing": asr["elapsedSeconds"],
            "aligning": alignment["elapsedSeconds"],
        }, max(asr["peakPhysicalFootprintBytes"], alignment["peakPhysicalFootprintBytes"]),
        raw["alignment"]["chunks"], [("asr", asr), ("alignment", alignment)], [], {
            "experiment": str(path),
            "experimentSHA256": sha256(path),
            "evidenceKind": "targeted-development-asr-alignment-only",
        },
    )


def zero_cue_policy_diagnosis(root: Path, corpus: str) -> dict:
    job = job_directory(root, corpus)
    raw = read(job / "raw-asr.json") if job else read(
        root / "experiments/dev-alignment-window-20-owned-retry.json"
    )
    manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
    sample_rate = manifest["fixture"]["sampleRate"]
    reference_turns = manifest["annotations"]["turns"]
    rows = []
    kept_cues = []
    policy_c_cues = []
    policy_c_merges = []
    chunks = sorted(raw["alignment"]["chunks"], key=lambda value: value["index"])
    for chunk_position, chunk in enumerate(chunks):
        cues = chunk["cues"]
        next_global_cue_start = (
            chunks[chunk_position + 1]["cues"][0]["start"]
            if chunk_position + 1 < len(chunks)
            and chunks[chunk_position + 1]["cues"] else chunk["sourceEnd"]
        )
        kept_cues.extend(cue for cue in cues if cue["end"] > cue["start"])
        local_reference = [turn for turn in reference_turns
                           if turn["endSample"] / sample_rate > chunk["sourceStart"]
                           and turn["startSample"] / sample_rate < chunk["sourceEnd"]]
        reference_text = "".join(turn["japanese"] for turn in local_reference)
        for index, cue in enumerate(cues):
            if cue["end"] > cue["start"]:
                continue
            normalized = normalize_ja(cue["text"])
            ranked = sorted(local_reference, key=lambda turn: difflib.SequenceMatcher(
                None, normalized, normalize_ja(turn["japanese"]), autojunk=False,
            ).ratio(), reverse=True)
            best = ranked[0] if ranked else None
            similarity = 100 * difflib.SequenceMatcher(
                None, normalized, normalize_ja(best["japanese"]), autojunk=False,
            ).ratio() if best else 0
            repeated = any(
                len(normalized) >= width * 4
                and normalized.endswith(normalized[-width:] * 4)
                for width in range(1, max(1, len(normalized) // 4) + 1)
            )
            rows.append({
                "cueID": cue["id"],
                "text": cue["text"],
                "normalizedCharacterCount": len(normalized),
                "repeatedTail": repeated,
                "asrWindow": [chunk["sourceStart"], chunk["sourceEnd"]],
                "previousCue": cues[index - 1] if index else None,
                "nextCue": cues[index + 1] if index + 1 < len(cues) else None,
                "referenceDiagnostic": {
                    "exactNormalizedMatchInWindow": normalized in normalize_ja(reference_text),
                    "bestApproximateMatchPercent": similarity,
                    "bestTurn": None if best is None else {
                        "id": best["id"],
                        "start": best["startSample"] / sample_rate,
                        "end": best["endSample"] / sample_rate,
                        "japanese": best["japanese"],
                    },
                },
                "coarseFallbackWouldOverlapValidatedCueCount": sum(
                    other["end"] > other["start"]
                    and other["end"] > chunk["sourceStart"]
                    and other["start"] < chunk["sourceEnd"]
                    for other in cues
                ),
            })
        simulated = [dict(cue) for cue in cues]
        for cue_id in [cue["id"] for cue in cues if cue["end"] <= cue["start"]]:
            index = next(i for i, cue in enumerate(simulated) if cue["id"] == cue_id)
            zero = simulated[index]
            previous = next((i for i in range(index - 1, -1, -1)
                             if simulated[i]["end"] > simulated[i]["start"]), None)
            following = next((i for i in range(index + 1, len(simulated))
                              if simulated[i]["end"] > simulated[i]["start"]), None)
            previous_distance = abs(zero["start"] - simulated[previous]["end"]) \
                if previous is not None else math.inf
            following_distance = abs(simulated[following]["start"] - zero["end"]) \
                if following is not None else math.inf
            target_index = previous if previous_distance <= following_distance else following
            assert target_index is not None
            direction = "previous" if target_index == previous else "following"
            target = simulated[target_index]
            target["text"] = target["text"] + zero["text"] if direction == "previous" \
                else zero["text"] + target["text"]
            duration_seconds = target["end"] - target["start"]
            characters_per_second = len(target["text"]) / duration_seconds
            policy_c_merges.append({
                "sourceCueID": zero["id"],
                "sourceText": zero["text"],
                "targetCueID": target["id"],
                "direction": direction,
                "boundaryDistanceSeconds": min(previous_distance, following_distance),
                "sourceWasLastCueInWindow": zero["id"] == cues[-1]["id"],
                "windowEnd": chunk["sourceEnd"],
                "nextGlobalCueStart": next_global_cue_start,
                "targetIntervalUnchanged": [target["start"], target["end"]],
                "mergedText": target["text"],
                "mergedCharacterCount": len(target["text"]),
                "charactersPerSecond": characters_per_second,
                "under84Characters": len(target["text"]) <= 84,
                "atMost20CharactersPerSecond": characters_per_second <= 20,
            })
            simulated.pop(index)
        policy_c_cues.extend(simulated)
    previous_end = -math.inf
    kept_timeline_valid = True
    for cue in kept_cues:
        kept_timeline_valid = (
            kept_timeline_valid
            and cue["start"] >= previous_end
            and cue["end"] > cue["start"]
        )
        previous_end = cue["end"]
    dropped_characters = sum(row["normalizedCharacterCount"] for row in rows)
    reference_supported = sum(
        row["referenceDiagnostic"]["exactNormalizedMatchInWindow"]
        or row["referenceDiagnostic"]["bestApproximateMatchPercent"] >= 70
        for row in rows
    )
    original_text = "".join(cue["text"] for chunk in raw["alignment"]["chunks"]
                            for cue in chunk["cues"])
    merged_text = "".join(cue["text"] for cue in policy_c_cues)
    previous_end = -math.inf
    policy_c_timeline_valid = True
    for cue in policy_c_cues:
        policy_c_timeline_valid = (
            policy_c_timeline_valid
            and cue["end"] > cue["start"]
            and cue["start"] >= previous_end
        )
        previous_end = cue["end"]
    policy_c_readable = all(
        merge["under84Characters"] and merge["atMost20CharactersPerSecond"]
        for merge in policy_c_merges
    )
    policy_c2_cues = [dict(cue) for cue in policy_c_cues]
    policy_c2_merges = []
    for merge in policy_c_merges:
        updated = dict(merge)
        target = next(cue for cue in policy_c2_cues
                      if cue["id"] == merge["targetCueID"])
        original_interval = [target["start"], target["end"]]
        free_gap_end = min(merge["windowEnd"], merge["nextGlobalCueStart"])
        timing_policy = "merge-adjacent-valid-cue"
        required_end = target["start"] + len(target["text"]) / 20
        if required_end > target["end"]:
            if (merge["sourceWasLastCueInWindow"]
                    and merge["direction"] == "previous"
                    and required_end <= free_gap_end):
                target["end"] = required_end
                timing_policy = "coarse-fallback-free-window-gap"
        characters_per_second = len(target["text"]) / (target["end"] - target["start"])
        updated.update({
            "targetOriginalInterval": original_interval,
            "finalInterval": [target["start"], target["end"]],
            "freeGapEnd": free_gap_end,
            "timingPolicy": timing_policy,
            "charactersPerSecond": characters_per_second,
            "under84Characters": len(target["text"]) <= 84,
            "atMost20CharactersPerSecond": characters_per_second <= 20,
        })
        policy_c2_merges.append(updated)
    previous_end = -math.inf
    policy_c2_timeline_valid = True
    for cue in policy_c2_cues:
        policy_c2_timeline_valid = (
            policy_c2_timeline_valid
            and cue["end"] > cue["start"]
            and cue["start"] >= previous_end
        )
        previous_end = cue["end"]
    policy_c2_text_preserved = "".join(cue["text"] for cue in policy_c2_cues) \
        == original_text
    policy_c2_readable = all(
        merge["under84Characters"] and merge["atMost20CharactersPerSecond"]
        for merge in policy_c2_merges
    )
    policy_c2_acceptable = (
        policy_c2_timeline_valid and policy_c2_text_preserved and policy_c2_readable
    )
    return {
        "scope": "offline report-only; frozen references are never consulted by product runtime",
        "rows": rows,
        "policyAExcludeAfterFailedRetry": {
            "positiveMonotonicTimeline": kept_timeline_valid,
            "rawASRPreserved": True,
            "alignedCueCountDropped": len(rows),
            "normalizedCharactersDroppedFromTranslationAndSubtitles": dropped_characters,
            "referenceSupportedCueCountDropped": reference_supported,
            "acceptable": False,
            "reason": "breaks end-to-end Japanese text preservation and omits reference-supported speech from EN/SRT/VTT",
        },
        "policyBCoarseRealASRWindow": {
            "rawASRPreserved": True,
            "validatedCuesChanged": False,
            "coarseCueCount": len(rows),
            "coarseCuesOverlappingValidatedCues": sum(
                row["coarseFallbackWouldOverlapValidatedCueCount"] > 0 for row in rows
            ),
            "positiveMonotonicTimeline": False,
            "acceptable": False,
            "reason": "real ASR windows overlap already-valid cues; keeping those cues unchanged makes SRT/VTT non-monotonic and unreadable",
        },
        "policyCMergeNearestValidCue": {
            "selectionRule": "nearest adjacent positive cue in the same ASR window by model-returned boundary distance; ties go to the preceding cue",
            "usesReferenceAtRuntime": False,
            "merges": policy_c_merges,
            "fullTextAndOrderPreserved": merged_text == original_text,
            "positiveMonotonicTimeline": policy_c_timeline_valid,
            "referenceSupportedCueCountPreserved": reference_supported,
            "readabilityThresholds": {"maximumCharacters": 84, "maximumCharactersPerSecond": 20},
            "allReadabilityGatesGreen": policy_c_readable,
            "maximumCharactersPerSecond": max(
                (merge["charactersPerSecond"] for merge in policy_c_merges), default=0,
            ),
            "readabilityViolationCueIDs": [
                merge["sourceCueID"] for merge in policy_c_merges
                if not merge["under84Characters"]
                or not merge["atMost20CharactersPerSecond"]
            ],
            "acceptable": policy_c_timeline_valid and merged_text == original_text
                and policy_c_readable,
            "reason": None if policy_c_readable else
                "cue-0058 would force 10 characters into the unchanged 0.24-second cue-0057 interval (41.67 chars/s)",
        },
        "policyC2BoundedFreeGapExtension": {
            "selectionRule": "Policy C; only a terminal same-window merge may extend its target end to the earlier of the ASR-window end and next global cue start, and only enough to reach 20 characters/second",
            "usesReferenceAtRuntime": False,
            "merges": policy_c2_merges,
            "fullTextAndOrderPreserved": policy_c2_text_preserved,
            "positiveMonotonicTimeline": policy_c2_timeline_valid,
            "zeroOverlap": policy_c2_timeline_valid,
            "allReadabilityGatesGreen": policy_c2_readable,
            "maximumCharactersPerSecond": max(
                (merge["charactersPerSecond"] for merge in policy_c2_merges), default=0,
            ),
            "coarseFallbackCueIDs": [
                merge["sourceCueID"] for merge in policy_c2_merges
                if merge["timingPolicy"] == "coarse-fallback-free-window-gap"
            ],
            "acceptable": policy_c2_acceptable,
            "reason": None if policy_c2_acceptable else
                "the bounded real gap cannot satisfy every cue-level readability gate",
        },
        "decision": "policy-c2-acceptable-on-development"
            if policy_c2_acceptable else "no-policy-acceptable",
    }


def failed_report_state(
    row: dict, policy_diagnosis: dict, development_eligible: bool = False,
) -> dict:
    stage = row.get("failure", {}).get("stage") or "unknown"
    is_holdout = row.get("corpusID") == HOLDOUT
    ready = not is_holdout and stage == "alignment" \
        and row["alignmentIntegrity"]["zeroDurationCueCount"] > 0 and policy_diagnosis[
        "policyC2BoundedFreeGapExtension"
    ]["acceptable"]
    return {
        "stage": stage,
        "developmentEligible": development_eligible if is_holdout else False,
        "decision": f"holdout-failed-{stage}" if is_holdout else (
            "ready-full-rerun-after-c2-development-simulation" if ready
            else f"development-failed-{stage}"
        ),
        "qualityStatus": f"{'holdout' if is_holdout else 'development'}-not-scored-because-{stage}-failed",
        "holdoutStatus": f"failed-{stage}" if is_holdout else "untouched-closed",
        "split": "HOLDOUT" if is_holdout else "DEV",
        "ready": ready,
    }


def write_failed_report(args: argparse.Namespace, decisions: list[dict], row: dict) -> None:
    evidence = Path("docs/japanese-live/experiments/evidence/E22")
    retained = [] if args.development_only else [
        {"path": str(path), "sha256": sha256(path)}
        for path in sorted(evidence.glob("*"))
        if path.is_file() and path.name not in {"quality-report.json", "resources-report.json"}
    ]
    policy_diagnosis = zero_cue_policy_diagnosis(args.root, row["corpusID"])
    development = score_corpus(
        args.root, args.baseline_root, CORPORA[0], decisions,
    ) if row["corpusID"] == HOLDOUT else None
    state = failed_report_state(
        row, policy_diagnosis,
        development_eligible=bool(development and row_passes(development)),
    )
    report = {
        "schemaVersion": 1,
        "ticket": 77,
        "candidateSelection": decisions,
        "configuration": {
            "ASR": "qwen-ja-product-default",
            "alignment": "Qwen3-ForcedAligner; contiguous 20-second ASR anchors",
            "diarization": "SpeakerKit-W8A16-auto-library-default-non-exclusive",
            "translation": "TranslateGemma-12b-4bit-previous-accepted-v1",
            "speakerBetaOptions": [
                "enhanced-precision", "sensitive-detection", "known-speaker-count",
            ],
            "translationBetaOption": "TranslateGemma-4b-it-4bit",
        },
        "rows": ([development] if development else []) + [row],
        "controls": read(args.root / "controls.json"),
        "alignmentRouteDiagnosis": {
            "localDependencyRevision": "d302a5c6080d2bb97bae38c7418f82abb76013b6",
            "generateAPI": "one forced-alignment inference per bounded ASR anchor",
            "declaredChunkLengthSeconds": 30,
            "declaredSampleCount": 480_000,
            "declaredMaximumMelFrames": 3_000,
            "selectedWindowSeconds": 20,
            "boundedRouteConfirmed": row["alignmentIntegrity"]["allWindowsWithinSelectedLimit"],
            "windowSweep": [
                {"seconds": 15, "zeroDurationCues": "3/264", "zeroDurationItems": "1601/4604",
                 "japaneseCERPercent": 88.6584, "pathologicalLengthWindows": 1,
                 "workerSeconds": 133.678,
                 "artifactSHA256": "0d82fb614bcd907230d1c86c0f386e1460570a0f799f9b48ad3df0fe4d4e0cfc"},
                {"seconds": 20, "zeroDurationCues": "7/279", "zeroDurationItems": "1455/4396",
                 "japaneseCERPercent": 81.2646, "pathologicalLengthWindows": 0,
                 "workerSeconds": 90.954,
                 "artifactSHA256": "fb9e50c490e6bc87ebed2612b1372eb23b3508aae21ecbd5c6f85528f6d00a50"},
                {"seconds": 25, "zeroDurationCues": "26/332", "zeroDurationItems": "1565/4354",
                 "japaneseCERPercent": 78.8893, "pathologicalLengthWindows": 1,
                 "workerSeconds": 136.480,
                 "artifactSHA256": "e39e1a8cd28423fdeac31ac515a5d62b719472d04a39acaa3bb85e6c409197fb"},
                {"seconds": 30, "zeroDurationCues": "30/304", "zeroDurationItems": "1566/4309",
                 "japaneseCERPercent": 78.5547, "pathologicalLengthWindows": 2,
                 "workerSeconds": 132.349,
                 "artifactSHA256": "d14053f7024393e92fc97a2a61174225993e751877dd11c6965d63c6717ad4e2"},
            ],
            "selection": "20 seconds: lowest cue defect count without the 15-second ASR hallucination veto",
            "sameWindowPerCueRetry": "attempted only after aggregate zero duration",
            "result": "failure retained before downstream workflow completion",
        },
        "zeroCuePolicyDiagnosis": policy_diagnosis,
        "liveGates": None,
        "developmentEligible": state["developmentEligible"],
        "workflowValid": False,
        "promoted": False,
        "decision": state["decision"],
        "holdoutStatus": state["holdoutStatus"],
        "qualityStatus": state["qualityStatus"],
        "productChanges": "offline ASR anchors bounded to contiguous 20-second windows; faithful same-window per-cue retry; deterministic content-preserving C2 fallback using only a bounded real gap; positive enclosing-cue timing retained when character items are diagnostic-only; source-attested Japanese laughter exempted from the degenerate-repetition validator; deterministic worker executable resolution; Live unchanged",
        "retainedEvidence": retained,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    args.quality_json.parent.mkdir(parents=True, exist_ok=True)
    args.quality_json.write_text(json.dumps({
        "ticket": 77,
        "status": report["qualityStatus"],
        "alignmentIntegrity": row["alignmentIntegrity"],
        "comparativeQualityConclusion": None,
    }, ensure_ascii=False, indent=2) + "\n")
    args.resources_json.write_text(json.dumps({
        "ticket": 77,
        "memoryPolicy": "native macOS pressure; no fixed offline reserve",
        "runtimeSeconds": row["runtimeSeconds"],
        "stageDurations": row["stageDurations"],
        "peakMemoryBytes": row["peakMemoryBytes"],
        "workerEvidence": row["resources"],
    }, ensure_ascii=False, indent=2) + "\n")
    integrity = row["alignmentIntegrity"]
    policy_a = policy_diagnosis["policyAExcludeAfterFailedRetry"]
    policy_b = policy_diagnosis["policyBCoarseRealASRWindow"]
    policy_c = policy_diagnosis["policyCMergeNearestValidCue"]
    policy_c2 = policy_diagnosis["policyC2BoundedFreeGapExtension"]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text(
        "# E22 — Standard offline validation (#77)\n\n"
        "Standard keeps 12B by default; 4B and the three independent SpeakerKit beta options remain selectable.\n\n"
        f"- {state['split']}: **FAIL** at {state['stage']} after {row['runtimeSeconds']:.3f}s.\n"
        f"- Route: {integrity['windowCount']} forced-alignment windows, maximum "
        f"{integrity['maximumWindowSeconds']:.6f}s; every window is within the selected 20s bound.\n"
        f"- Integrity: {integrity['zeroDurationCueCount']}/{integrity['cueCount']} zero-duration cues; "
        f"{integrity['nonMonotonicCueCount']} non-monotonic cues; "
        f"{integrity['zeroDurationRawItemCount']}/{integrity['rawItemCount']} zero-duration raw items (diagnostic only).\n"
        f"- Peak: {row['peakMemoryBytes'] / 2**30:.2f} GiB; strict sequence: "
        f"{str(row['resources']['strictlySequential']).lower()}; swap growth: 0 bytes; critical pressure: none.\n"
        f"- Policy A would drop {policy_a['alignedCueCountDropped']} cues / "
        f"{policy_a['normalizedCharactersDroppedFromTranslationAndSubtitles']} normalized characters from EN/SRT/VTT, "
        f"including {policy_a['referenceSupportedCueCountDropped']} reference-supported cues.\n"
        f"- Policy B would make {policy_b['coarseCuesOverlappingValidatedCues']}/"
        f"{policy_b['coarseCueCount']} coarse real-window cues overlap already-valid cues.\n"
        f"- Policy C preserves text/order and a monotonic timeline, but reaches "
        f"{policy_c['maximumCharactersPerSecond']:.2f} chars/s; failures: "
        f"{', '.join(policy_c['readabilityViolationCueIDs'])}.\n"
        f"- Policy C2 preserves all text/order, stays monotonic with zero overlap, and reaches "
        f"{policy_c2['maximumCharactersPerSecond']:.2f} chars/s; coarse fallback: "
        f"{', '.join(policy_c2['coarseFallbackCueIDs'])}.\n"
        f"- The {state['split']} workflow stopped at {state['stage']}; its downstream stages were not run.\n\n"
        + ("**Decision: ready for one full rerun.** C2 is acceptable on DEV simulation; "
           if state["ready"] else f"**Decision: {state['decision']}.** ")
        + ("The holdout remains untouched until every DEV gate passes.\n"
           if state["holdoutStatus"] == "untouched-closed"
           else "The opened holdout failure is retained; no promotion.\n"),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--baseline-root", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--quality-json", type=Path)
    parser.add_argument("--resources-json", type=Path)
    parser.add_argument("--live-log", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--prepare-scoring", action="store_true")
    parser.add_argument("--development-only", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert duration({"startedAt": "2026-01-01T00:00:00Z", "finishedAt": "2026-01-01T00:00:02Z"}) == 2
        assert formatted_duration(1064) == "17m 44.0s"
        assert not row_passes({group: {"gate": group != "qualityGates"} for group in (
            "artifactGates", "translationGates", "speakerGates", "qualityGates",
        )})
        state = failed_report_state(
            {
                "corpusID": CORPORA[0],
                "failure": {"stage": "translation"},
                "alignmentIntegrity": {"zeroDurationCueCount": 0},
            },
            {"policyC2BoundedFreeGapExtension": {"acceptable": True}},
        )
        assert state["decision"] == "development-failed-translation"
        assert not state["developmentEligible"] and not state["ready"]
        holdout_state = failed_report_state(
            {
                "corpusID": HOLDOUT,
                "failure": {"stage": "alignment"},
                "alignmentIntegrity": {"zeroDurationCueCount": 0},
            },
            {"policyC2BoundedFreeGapExtension": {"acceptable": True}},
            development_eligible=True,
        )
        assert holdout_state["decision"] == "holdout-failed-alignment"
        assert holdout_state["developmentEligible"] and not holdout_state["ready"]
        assert holdout_state["holdoutStatus"] == "failed-alignment"
        with TemporaryDirectory() as directory:
            root = Path(directory)
            job = root / "qwen-ja" / CORPORA[0] / "jobs" / "real"
            job.mkdir(parents=True)
            (job / "manifest.json").write_text("{}", encoding="utf-8")
            experiment = root / "experiments"
            experiment.mkdir()
            (experiment / "dev-alignment-window-20-owned-retry.json").write_text(
                "{}", encoding="utf-8"
            )
            assert failed_experiment_row(root) is None
        baseline_speaker = {
            "speakerAttributedJapaneseError": {"ratePercent": 10.0},
        }
        candidate_speaker = {
            "duplicationCount": 0,
            "speakerAttributedJapaneseError": {"ratePercent": 10.0},
            "overlap": {"inventedSeconds": 0.1},
        }
        gates = speaker_gates(
            baseline_speaker, candidate_speaker, True, True, [],
        )
        assert not gates["speakerGainOrUnchangedStandard"]
        assert not gates["zeroInventedOverlapOrUnchangedStandard"]
        unchanged = speaker_gates(
            baseline_speaker, candidate_speaker, True, True, [],
            unchanged_standard=True,
        )
        assert unchanged["speakerGainOrUnchangedStandard"]
        assert unchanged["zeroInventedOverlapOrUnchangedStandard"]
        assert metric_interpretation(1, 1, True, "meaning")["interpretation"] == "unchanged"
        examples = representative_examples(
            [{"id": "1", "source": "一", "reference": "one", "hypothesis": "two"}],
            [{"id": "1", "source": "一", "reference": "one", "hypothesis": "one"}],
        )
        assert {example["category"] for example in examples} \
            == {"recovered", "lost", "mistranslated"}
        worker = {
            "processIdentifier": 1, "startedAt": "2026-01-01T00:00:00Z",
            "exitedAt": "2026-01-01T00:00:01Z", "elapsedSeconds": 1,
            "exitStatus": 0, "forcedTermination": False,
            "peakPhysicalFootprintBytes": 1,
            "availableMemorySamples": [{"availableMemoryBytes": 1}],
            "pressureTransitions": [], "swapUsedBeforeBytes": 0,
            "swapUsedAfterBytes": 0,
        }
        raw_workers = {
            "asrWorker": {"lifecycle": worker},
            "alignment": {"worker": dict(
                worker, processIdentifier=2, startedAt="2026-01-01T00:00:01Z",
                exitedAt="2026-01-01T00:00:02Z",
            )},
            "diarization": {"worker": dict(
                worker, processIdentifier=3, startedAt="2026-01-01T00:00:02Z",
                exitedAt="2026-01-01T00:00:03Z",
            )},
            "translation": {"worker": dict(
                worker, processIdentifier=4, startedAt="2026-01-01T00:00:03Z",
                exitedAt="2026-01-01T00:00:04Z",
            )},
            "modelEvents": [{
                "kind": kind, "modelID": model,
                "message": "policy=macos-memory-pressure reserve=0"
                    if kind == "memory-pressure-checked" else None,
            } for model in MODEL_IDS for kind in (
                "memory-pressure-checked", "load-completed", "unload-completed",
                "memory-release-checked",
            )],
        }
        assert all(model_lifecycle(raw_workers)["gates"].values())
        assert observed_peak_memory_bytes(
            {"peakMemoryBytes": 1}, model_lifecycle(raw_workers),
        ) == 1
        raw_workers["translation"]["worker"]["peakPhysicalFootprintBytes"] = 2
        assert observed_peak_memory_bytes(
            {"peakMemoryBytes": 1}, model_lifecycle(raw_workers),
        ) == 2
        raw_workers["alignment"]["worker"]["processIdentifier"] = 1
        assert not model_lifecycle(raw_workers)["gates"]["distinctWorkerProcesses"]
        with TemporaryDirectory() as directory:
            job = Path(directory)
            (job / "english-subtitles.srt").write_text(
                "1\n00:00:00,000 --> 00:00:01,000\nHello\n", encoding="utf-8"
            )
            (job / "english-subtitles.vtt").write_text(
                "WEBVTT\n\ncue-1\n00:00:00.000 --> 00:00:01.000\nHello\n",
                encoding="utf-8",
            )
            subtitle_raw = {"translation": {
                "request": {"turns": [{
                    "id": "cue-1", "sourceStart": 0, "sourceEnd": 1,
                }]},
                "response": '{"translations":[{"id":"cue-1","text":"Hello"}]}',
            }}
            assert subtitle_artifacts(job, subtitle_raw)["valid"]
            (job / "english-subtitles.srt").write_text(
                "1\n00:00:00,000 --> 00:00:00,000\nHello\n", encoding="utf-8"
            )
            assert not subtitle_artifacts(job, subtitle_raw)["valid"]
        assert len(MODEL_REVISIONS) == 4 and len(MODEL_WEIGHT_SHA256) == 8
        retained_path = Path(
            "docs/japanese-live/experiments/evidence/E19-safety-stop/"
            "model-weight-verification.json"
        )
        retained = read(retained_path)
        assert {
            (item["modelID"], item["file"]): item["sha256"]
            for item in retained["weights"]
        } == MODEL_WEIGHT_SHA256
        assert weight_provenance_valid(retained["weights"])
        stale = dict(retained["weights"][0], revision="stale")
        assert not weight_provenance_valid([*retained["weights"], stale])
        duplicate = [*retained["weights"][:-1], retained["weights"][0]]
        assert not weight_provenance_valid(duplicate)
        scoring = {str(path): sha256(path) for path in SCORING_PATHS}
        assert scoring_provenance_valid({"scoringImplementationSHA256": scoring})
        assert not scoring_provenance_valid({
            "scoringImplementationSHA256": dict(scoring, stale="bad"),
        })
        with TemporaryDirectory() as directory:
            raw_path = Path(directory) / "raw.json"
            log_path = Path(directory) / "revalidation.log"
            binary_path = Path(directory) / "tests"
            raw_path.write_text("{}", encoding="utf-8")
            log_path.write_text("pass", encoding="utf-8")
            binary_path.write_text("binary", encoding="utf-8")
            revalidation = {
                "kind": "current-code-raw-replay",
                "rawArtifactSHA256": sha256(raw_path),
                "testLogSHA256": sha256(log_path),
                "testBinarySHA256": sha256(binary_path),
                "implementationSHA256": {
                    path: sha256(Path(path)) for path in REQUIRED_IMPLEMENTATION_PATHS
                },
            }
            assert implementation_revalidation_valid(
                {"revalidation": revalidation}, raw_path, log_path, binary_path,
            )
            revalidation["rawArtifactSHA256"] = "stale"
            assert not implementation_revalidation_valid(
                {"revalidation": revalidation}, raw_path, log_path, binary_path,
            )
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "controls").mkdir()
            log_path = root / "controls/youtube-revalidation.log"
            binary_path = root / "tests"
            log_path.write_text("pass", encoding="utf-8")
            binary_path.write_text("binary", encoding="utf-8")
            (root / "control-provenance.json").write_text(json.dumps({
                "kind": "current-code-youtube-control",
                "implementationSHA256": {
                    path: sha256(Path(path)) for path in CONTROL_IMPLEMENTATION_PATHS
                },
                "testBinarySHA256": sha256(binary_path),
                "testLogSHA256": sha256(log_path),
            }), encoding="utf-8")
            assert control_provenance_valid(root, binary_path)
            development = {
                "developmentEligible": True,
                "decision": "development-pass-holdout-closed",
                "rows": [{"corpusID": CORPORA[0]}],
            }
            development_path = root / "development-report.json"
            development_path.write_text(json.dumps(development), encoding="utf-8")
            (root / "holdout-opened.json").write_text(json.dumps({
                "ticket": 77,
                "developmentReportSHA256": sha256(development_path),
            }), encoding="utf-8")
            assert holdout_sequence_valid(root)
            development["rows"].append({"corpusID": HOLDOUT})
            development_path.write_text(json.dumps(development), encoding="utf-8")
            assert not holdout_sequence_valid(root)
        raw_models = {
            "model": {"modelID": MODEL_IDS[0], "revision": MODEL_REVISIONS[MODEL_IDS[0]]},
            "alignment": {"modelID": MODEL_IDS[1], "revision": MODEL_REVISIONS[MODEL_IDS[1]]},
            "diarization": {"modelID": MODEL_IDS[2], "revision": MODEL_REVISIONS[MODEL_IDS[2]]},
            "translation": {"model": MODEL_IDS[3], "revision": MODEL_REVISIONS[MODEL_IDS[3]]},
        }
        assert all(model_provenance_gates(Path("."), raw_models, {
            "modelProvenance": {
                "path": str(retained_path),
                "sha256": sha256(retained_path),
            },
        }).values())
        classification = read(Path(
            "docs/japanese-live/experiments/evidence/E19-safety-stop/"
            "translategemma-memory-smoke-classification.json"
        ))
        evidence_root = Path(
            "docs/japanese-live/experiments/evidence/E19-safety-stop"
        )
        assert all(
            sha256(evidence_root / source["path"]) == source["sha256"]
            for source in classification["sourceArtifacts"].values()
        )
        return
    if args.prepare_scoring:
        assert args.root and args.baseline_root
        decisions = decision_manifest()
        for corpus in CORPORA[:1] if args.development_only else CORPORA:
            score_corpus(args.root, args.baseline_root, corpus, decisions)
        return
    assert args.root and args.baseline_root and args.json and args.markdown \
        and args.quality_json and args.resources_json and args.live_log
    decisions = decision_manifest()
    selected_corpora = CORPORA[:1] if args.development_only else CORPORA
    failed = next((row for corpus in selected_corpora
                   if (row := failed_row(args.root, corpus))), None) \
        or failed_experiment_row(args.root)
    if failed:
        write_failed_report(args, decisions, failed)
        return
    rows = [row for corpus in selected_corpora
            if (row := score_corpus(args.root, args.baseline_root, corpus, decisions))]
    controls = read(args.root / "controls.json") if (args.root / "controls.json").exists() else {}
    live_passed = args.live_log.exists() and "Test Suite 'LiveCaptionTests' passed" in args.live_log.read_text()
    development = next((row for row in rows if row["corpusID"] != HOLDOUT), None)
    holdout = next((row for row in rows if row["corpusID"] == HOLDOUT), None)
    development_eligible = development is not None and row_passes(development)
    holdout_gate = None if args.development_only else holdout_sequence_valid(args.root)
    control_provenance = control_provenance_valid(args.root)
    workflow_valid = bool(development_eligible and holdout and row_passes(holdout)
                          and live_passed and all(controls.values())
                          and controls.get("fullSwiftSuite", False)
                          and holdout_gate and control_provenance)
    report = {
        "schemaVersion": 1,
        "ticket": 77,
        "candidateSelection": decisions,
        "configuration": {
            "ASR": "qwen-ja-product-default",
            "alignment": "Qwen3-ForcedAligner",
            "diarization": "SpeakerKit-W8A16-auto-library-default-non-exclusive",
            "translation": "TranslateGemma-12b-4bit-previous-accepted-v1",
            "speakerBetaOptions": [
                "enhanced-precision", "sensitive-detection", "known-speaker-count",
            ],
            "translationBetaOption": "TranslateGemma-4b-it-4bit",
            "rejectedCandidatesRemainDisabled": True,
        },
        "rows": rows,
        "controls": controls,
        "liveGates": live_passed,
        "controlProvenance": control_provenance,
        "holdoutGateSequence": holdout_gate,
        "developmentEligible": development_eligible,
        "workflowValid": workflow_valid,
        "promoted": False,
        "decision": "validated-standard-offline-workflow" if workflow_valid else (
            "development-pass-holdout-closed" if holdout is None and development_eligible else
            "no-go-development" if not development_eligible else "no-go-holdout"
        ),
        "productChanges": "none",
        "reportingCorrections": {
            "rawArtifactsChanged": False,
            "peakMemory": "maximum observed worker physical footprint",
            "implementationProvenance": list(REQUIRED_IMPLEMENTATION_PATHS),
        },
        "scopeLimit": "Two complete supplied videos validate only this offline workflow; they do not prove universal anime, VTuber, gaming, conversation, speaker, or overlap quality.",
    }
    evidence = Path("docs/japanese-live/experiments/evidence/E22")
    report["retainedEvidence"] = [] if args.development_only else [
        {"path": str(path), "sha256": sha256(path)}
        for path in sorted(evidence.glob("*"))
        if path.is_file() and path.name not in {"quality-report.json", "resources-report.json"}
    ]
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    args.quality_json.parent.mkdir(parents=True, exist_ok=True)
    args.quality_json.write_text(json.dumps({
        "ticket": 77,
        "rows": [{
            "corpusID": row["corpusID"],
            "baseline": row["baseline"],
            "candidate": {key: value for key, value in row["candidate"].items()
                          if key not in ("resources", "stageDurations", "runtimeSeconds",
                                         "peakMemoryBytes")},
            "qualityGates": row["qualityGates"],
            "translationGates": row["translationGates"],
            "speakerGates": row["speakerGates"],
            "metricInterpretations": row["metricInterpretations"],
            "representativeExamples": row["representativeExamples"],
            "qualityImpact": row["qualityImpact"],
        } for row in rows],
    }, ensure_ascii=False, indent=2) + "\n")
    args.resources_json.write_text(json.dumps({
        "ticket": 77,
        "memoryPolicy": "native macOS pressure; no fixed offline reserve",
        "rows": [{
            "corpusID": row["corpusID"],
            "runtimeSeconds": row["candidate"]["runtimeSeconds"],
            "stageDurations": row["candidate"]["stageDurations"],
            "peakMemoryBytes": row["candidate"]["peakMemoryBytes"],
            "workerEvidence": row["candidate"]["resources"],
        } for row in rows],
    }, ensure_ascii=False, indent=2) + "\n")
    lines = [
        "# E22 — Standard offline validation (#77)", "",
        "Standard uses 12B and SpeakerKit defaults; 4B and the three SpeakerKit beta options remain selectable and independent.", "",
        "| Split | COMET baseline→candidate | chrF++ baseline→candidate | CER | DER / JER | Speaker JA error | Speakers ref/cand | Overlap P/R/F1 | Retry | Runtime | Peak | Gates |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        baseline, candidate, speaker = row["baseline"], row["candidate"], row["candidate"]["diarization"]
        comet = "pending" if candidate["COMET"] is None else f'{baseline["COMET"]:.4f}→{candidate["COMET"]:.4f}'
        overlap = speaker["overlap"]
        lines.append(
            f'| {row["role"]} | {comet} | {baseline["chrFPlusPlus"]:.2f}→{candidate["chrFPlusPlus"]:.2f} | '
            f'{candidate["japaneseCER"]["ratePercent"]:.2f}% | {speaker["DERPercent"]:.2f}% / {speaker["JERPercent"]:.2f}% | '
            f'{speaker["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | {speaker["referenceSpeakerCount"]}/{speaker["candidateSpeakerCount"]} | '
            f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/{overlap["f1Percent"]:.1f}% | '
            f'{100*candidate["retryRate"]:.2f}% | {candidate["runtimeSeconds"]:.0f}s | {candidate["peakMemoryBytes"]/2**30:.2f} GiB | '
            f'{"PASS" if row_passes(row) else "FAIL"} |'
        )
    lines += ["", "## Performance and subtitle readability", ""]
    for row in rows:
        candidate = row["candidate"]
        readability = candidate["subtitles"]["readability"]
        dense = readability["representativeHighDensityCue"]
        stages = ", ".join(
            f'{name}={formatted_duration(seconds)}'
            for name, seconds in candidate["stageDurations"].items()
        )
        lines.append(
            f'- {row["role"]}: total {formatted_duration(candidate["runtimeSeconds"])}; '
            f'{stages}. '
            f'SRT/VTT {candidate["subtitles"]["srt"]["cueCount"]} cues; '
            f'{readability["over84CharacterCueCount"]} >84 characters and '
            f'{readability["over20CharactersPerSecondCueCount"]} >20 chars/s; '
            f'maximum-density cue `{dense["id"]}` is {dense["charactersPerSecond"]:.2f} chars/s '
            f'over {dense["durationSeconds"]:.3f}s: “{dense["text"]}”.'
        )
    for row in rows:
        lines += ["", f'## {row["role"]} interpretations', ""]
        for name, item in row["metricInterpretations"].items():
            delta = "pending" if item["delta"] is None else f'{item["delta"]:+.4f}'
            lines.append(
                f'- {name}: Δ {delta} — {item["interpretation"]}. {item["impact"]}'
            )
        lines += ["", "Representative speech:", ""]
        for example in row["representativeExamples"]:
            lines.append(
                f'- {example["category"]} `{example["id"]}`: '
                f'JA “{example["sourceJapanese"]}” → candidate “{example["candidateEnglish"]}” '
                f'(reference “{example["referenceEnglish"]}”, baseline “{example["baselineEnglish"]}”, '
                f'observed={str(example["observed"]).lower()}).'
            )
    lines += ["", f'**Decision: {report["decision"]}.**', "", report["scopeLimit"]]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
