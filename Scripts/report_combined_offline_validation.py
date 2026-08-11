#!/usr/bin/env python3
"""Validate ticket #77 against the frozen corpus and product evidence."""

from __future__ import annotations

import argparse
import collections
import json
import re
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from report_high_quality_acceptance import (
    cer,
    cue_integrity,
    diarization_metrics,
    glossary_accuracy,
    sha256,
    structured_cues_are_valid,
    translation_rows,
)
from report_japanese_l7d import chrf_pp
from report_local_translator_bakeoff import comet_scores, subtitle_quality, write_lines


CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
HOLDOUT = "md62mmdz0m"
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
    return {
        "valid": valid, "srt": srt, "vtt": vtt,
        "srtVTTTimestampsMatch": timelines_match,
        "alignmentTimestampsMatch": alignment_matches,
        "translatedTextMatches": text_matches,
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
) -> dict:
    return {
        "zeroTranscriptDuplication": candidate["duplicationCount"] == 0,
        "stableLabels": labels_are_stable,
        "rejectedCandidatesRemainBaseline": all(
            not row["promoted"] for row in decisions if row["ticket"] >= 57
        ),
        "speakerAttributedJapaneseErrorNonRegression":
            candidate["speakerAttributedJapaneseError"]["ratePercent"]
            <= baseline["speakerAttributedJapaneseError"]["ratePercent"],
        "rawOverlapRetained": overlap_evidence_retained,
        "zeroInventedOverlap": candidate["overlap"]["inventedSeconds"] == 0,
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
    speaker_gate_results = speaker_gates(
        baseline_speaker,
        speaker,
        stable_speaker_labels(candidate),
        "overlapRanges" in candidate["diarization"],
        decisions,
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
            "stageDurations": candidate_manifest["stageDurations"],
            "retryRate": integrity["retryRate"],
            "peakMemoryBytes": candidate_manifest["peakMemoryBytes"],
            "subtitles": subtitles,
            "resources": resources,
        },
        "artifactGates": artifact_gates(
            root, corpus, manifest, candidate, metadata, candidate_manifest,
            candidate_job, decisions,
        ),
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
    args = parser.parse_args()
    if args.self_test:
        assert duration({"startedAt": "2026-01-01T00:00:00Z", "finishedAt": "2026-01-01T00:00:02Z"}) == 2
        assert not row_passes({group: {"gate": group != "qualityGates"} for group in (
            "artifactGates", "translationGates", "speakerGates", "qualityGates",
        )})
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
        assert gates["speakerAttributedJapaneseErrorNonRegression"]
        assert not gates["zeroInventedOverlap"]
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
        for corpus in CORPORA:
            score_corpus(args.root, args.baseline_root, corpus, decisions)
        return
    assert args.root and args.baseline_root and args.json and args.markdown \
        and args.quality_json and args.resources_json and args.live_log
    decisions = decision_manifest()
    rows = [row for corpus in CORPORA
            if (row := score_corpus(args.root, args.baseline_root, corpus, decisions))]
    controls = read(args.root / "controls.json") if (args.root / "controls.json").exists() else {}
    live_passed = args.live_log.exists() and "Test Suite 'LiveCaptionTests' passed" in args.live_log.read_text()
    development = next((row for row in rows if row["corpusID"] != HOLDOUT), None)
    holdout = next((row for row in rows if row["corpusID"] == HOLDOUT), None)
    development_eligible = development is not None and row_passes(development)
    workflow_valid = bool(development_eligible and holdout and row_passes(holdout)
                          and live_passed and all(controls.values())
                          and controls.get("fullSwiftSuite", False))
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
        "developmentEligible": development_eligible,
        "workflowValid": workflow_valid,
        "promoted": False,
        "decision": "validated-standard-offline-workflow" if workflow_valid else (
            "development-pass-holdout-closed" if holdout is None and development_eligible else
            "no-go-development" if not development_eligible else "no-go-holdout"
        ),
        "productChanges": "none",
        "scopeLimit": "Two complete supplied videos validate only this offline workflow; they do not prove universal anime, VTuber, gaming, conversation, speaker, or overlap quality.",
    }
    evidence = Path("docs/japanese-live/experiments/evidence/E22")
    report["retainedEvidence"] = [
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
