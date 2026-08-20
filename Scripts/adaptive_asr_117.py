#!/usr/bin/env python3
"""Frozen DEV→holdout scorer for issue #117."""

from __future__ import annotations

import argparse
from bisect import bisect_right
import csv
import gzip
import hashlib
import json
import math
from collections import Counter
from datetime import datetime
from pathlib import Path

from adaptive_asr_harness import dimension_vocabulary
from report_high_quality_acceptance import translation_rows
from report_japanese_l7d import chrf_pp
from report_qwen_error_diagnostic import classify_unit, normalize, read_audio


SAMPLE_RATE = 16_000
FRAME_SAMPLES = SAMPLE_RATE // 50
MINIMUM_SAMPLES = 3 * SAMPLE_RATE
MAXIMUM_SAMPLES = 8 * SAMPLE_RATE
MARGINS = (0.05, 0.1, 0.2, 0.3, 0.4)
TIE_TOLERANCE = 0.01
MEMORY_BUDGET_BYTES = 14 * 1024 * 1024 * 1024


def read_json(path: Path) -> dict:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def dbfs(values: list[int]) -> float:
    square_sum = sum(value * value for value in values)
    return -120 if not square_sum else 10 * math.log10(
        square_sum / len(values) / (32768 * 32768)
    )


def build_plan(audio: Path, manifest_path: Path, role: str) -> dict:
    manifest = read_json(manifest_path)
    fixture = manifest["fixture"]
    observed = sha256(audio)
    if observed != fixture["sha256"]:
        raise RuntimeError("frozen PCM hash mismatch")
    samples = read_audio(audio, SAMPLE_RATE)
    if len(samples) != fixture["sampleCount"]:
        raise RuntimeError("frozen PCM sample count mismatch")
    segments = []
    start = 0
    while start < len(samples):
        remaining = len(samples) - start
        if remaining <= MAXIMUM_SAMPLES:
            end = len(samples)
        else:
            latest = min(start + MAXIMUM_SAMPLES, len(samples) - MINIMUM_SAMPLES)
            end = min(
                range(start + MINIMUM_SAMPLES, latest + 1, FRAME_SAMPLES),
                key=lambda index: (
                    sum(value * value for value in samples[index - FRAME_SAMPLES:index]),
                    -index,
                ),
            )
        values = samples[start:end]
        frames = [values[index:index + FRAME_SAMPLES]
                  for index in range(0, len(values), FRAME_SAMPLES)]
        segments.append({
            "id": f"segment-{len(segments) + 1:04d}",
            "startSample": start,
            "endSample": end,
            "rmsDBFS": dbfs(values),
            "activeFrameRatio": sum(dbfs(frame) >= -42 for frame in frames) / len(frames),
        })
        start = end
    if (not segments or segments[0]["startSample"] != 0
            or segments[-1]["endSample"] != len(samples)
            or any(left["endSample"] != right["startSample"]
                   for left, right in zip(segments, segments[1:]))
            or any(row["endSample"] - row["startSample"] > MAXIMUM_SAMPLES
                   for row in segments)):
        raise RuntimeError("acoustic plan is incomplete")
    return {
        "schemaVersion": 1,
        "ticket": 117,
        "corpusID": manifest["corpusID"],
        "corpusRole": role,
        "holdoutOpened": role == "untouched-holdout",
        "audioSHA256": observed,
        "sampleRate": SAMPLE_RATE,
        "sampleCount": len(samples),
        "algorithm": {
            "frameMilliseconds": 20,
            "minimumSeconds": 3,
            "maximumSeconds": 8,
            "boundary": "lowest-energy-frame-latest-tie",
            "activeFrameDBFS": -42,
            "usesReference": False,
        },
        "segments": segments,
    }


def parse_time(value: str) -> float:
    hours, minutes, seconds = value.split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(seconds)


def reference_by_segment(path: Path, segments: list[dict]) -> tuple[list[str], dict]:
    fragments = [[] for _ in segments]
    assigned = 0
    segment_ends = [row["endSample"] for row in segments]
    if path.suffix == ".tsv":
        with path.open(encoding="utf-8", newline="") as handle:
            characters = [{
                "text": row["character"],
                "start": parse_time(row["char_start"]),
                "end": parse_time(row["char_end"]),
                "speaker": row["speaker_id"],
            } for row in csv.DictReader(handle, delimiter="\t")]
    else:
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        characters = [{
            "text": character["char"],
            "start": character["start"],
            "end": character["end"],
            "speaker": row["speaker_id"],
        } for row in rows for character in row["characters"]]
    for character in characters:
        if character["speaker"] == "SPEAKER_NONE":
            continue
        midpoint = (character["start"] + character["end"]) / 2 * SAMPLE_RATE
        index = bisect_right(segment_ends, midpoint)
        if index == len(segments):
            raise RuntimeError("reference character falls outside the acoustic plan")
        if segments[index]["startSample"] <= midpoint < segments[index]["endSample"]:
            fragments[index].append(character["text"])
            assigned += 1
        else:
            raise RuntimeError("reference character falls outside the acoustic plan")
    return ["".join(value) for value in fragments], {
        "method": "character-midpoint-to-acoustic-segment",
        "characterAlignmentSHA256": sha256(path),
        "assignedCharacters": assigned,
        "unassignedCharacters": 0,
    }


def worker_seconds(run: dict) -> dict[str, float]:
    return {
        worker["backend"]: worker["lifecycle"]["elapsedSeconds"]
        for worker in run["workers"]
    }


def stage_seconds(manifest: dict, stage: str) -> float:
    durations = manifest["stageDurations"]
    if isinstance(durations, list):
        durations = dict(zip(durations[::2], durations[1::2]))
    return float(durations[stage])


def parse_date(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate_run(plan: dict, run: dict, plan_path: Path) -> None:
    segments, windows, workers = plan["segments"], run.get("windows", []), run.get("workers", [])
    if (run.get("ticket") != 117 or run.get("status") != "completed"
            or run.get("sourceSHA256") != plan["audioSHA256"]
            or run.get("planSHA256") != sha256(plan_path)
            or len(windows) != len(segments)
            or [row["segment"] for row in windows] != segments
            or not workers or workers[0].get("backend") != "qwen-ja"
            or any(bool(row.get("parakeet") or row.get("error"))
                   != bool(row["qwenAssessment"]["signals"]) for row in windows)
            or not run.get("strictlySequential")):
        raise RuntimeError("ASR run differs from its acoustic/runtime-only plan")
    for worker in workers:
        lifecycle, model = worker["lifecycle"], worker["model"]
        if (lifecycle.get("exitStatus") != 0 or lifecycle.get("forcedTermination")
                or lifecycle.get("peakPhysicalFootprintBytes", 0) <= 0
                or not lifecycle.get("availableMemorySamples") or not model.get("weightSHA256")):
            raise RuntimeError("worker lifecycle/provenance is incomplete")
    if len(workers) == 2 and parse_date(workers[0]["lifecycle"]["exitedAt"]) > parse_date(
        workers[1]["lifecycle"]["startedAt"]
    ):
        raise RuntimeError("Qwen and Parakeet overlapped")


def scales(rows: list[dict]) -> tuple[tuple[float, float], tuple[float, float]] | None:
    qwen = [row["qwenRaw"] for row in rows]
    parakeet = [row["parakeetRaw"] for row in rows if row["parakeetRaw"] is not None]
    if not qwen or not parakeet or max(qwen) <= min(qwen) or max(parakeet) <= min(parakeet):
        return None
    return (min(qwen), max(qwen)), (min(parakeet), max(parakeet))


def calibrated(raw: float, scale: tuple[float, float]) -> float:
    best, worst = scale
    value = min(max(raw, best), worst)
    return 1 - (value - best) / (worst - best)


def choose(row: dict, scale: tuple[tuple[float, float], tuple[float, float]], margin: float) -> str:
    if (not row["suspect"] or row["parakeetRaw"] is None or row["vetoes"]
            or row.get("error")):
        return "qwen-ja"
    difference = calibrated(row["parakeetRaw"], scale[1]) - calibrated(
        row["qwenRaw"], scale[0]
    )
    return "parakeet-ja" if difference > TIE_TOLERANCE and difference > margin else "qwen-ja"


def edit_count(classification: dict) -> int:
    speech = classification["speech"]
    return speech["lostCharacters"] + speech["insertedOrSubstitutedCharacters"]


def critical_loss(row: dict) -> bool:
    for dimension in ("terms", "numbers", "meaning"):
        qwen = set(row["qwenClassification"][dimension]["recovered"])
        parakeet = set(row["parakeetClassification"][dimension]["recovered"])
        if qwen - parakeet:
            return True
    return False


def retains_critical(baseline: dict, candidate: dict) -> bool:
    return all(
        set(baseline[key]["recovered"]) <= set(candidate[key]["recovered"])
        for key in ("terms", "numbers", "meaning")
    )


def summary(rows: list[dict], scale, margin: float) -> dict:
    selected = [(row, choose(row, scale, margin)) for row in rows]
    replacements = [(row, backend) for row, backend in selected if backend == "parakeet-ja"]
    gains = [row["qwenEdits"] - row["parakeetEdits"] for row, _ in replacements]
    return {
        "margin": margin,
        "replacements": len(replacements),
        "good": sum(value > 0 for value in gains),
        "bad": sum(value < 0 for value in gains),
        "netEditGain": sum(gains),
        "criticalLoss": any(critical_loss(row) for row, _ in replacements),
    }


def best_margin(rows: list[dict], scale) -> tuple[float | None, list[dict]]:
    candidates = [summary(rows, scale, margin) for margin in MARGINS]
    admissible = [row for row in candidates if row["netEditGain"] > 0
                  and row["good"] > row["bad"] and not row["criticalLoss"]]
    if not admissible:
        return None, candidates
    selected = max(admissible, key=lambda row: (
        row["netEditGain"], -row["bad"], -row["replacements"], row["margin"]
    ))
    return selected["margin"], candidates


def classification_terms(manifest: dict, e23: dict) -> tuple[list[str], list[str]]:
    terms, meanings = dimension_vocabulary(e23)
    terms += [term for turn in manifest["annotations"]["turns"]
              for term in turn.get("criticalTerms", [])]
    return list(dict.fromkeys(terms)), meanings


def calibration_rows(plan: dict, run: dict, references: list[str], terms, meanings) -> list[dict]:
    rows = []
    count = len(run["windows"])
    for index, (window, reference) in enumerate(zip(run["windows"], references)):
        qwen = window["qwen"]["rawTranscript"]
        parakeet_exchange = window.get("parakeet")
        parakeet = parakeet_exchange["rawTranscript"] if parakeet_exchange else None
        confidence = parakeet_exchange.get("confidence") if parakeet_exchange else None
        qwen_classification = classify_unit(reference, qwen, terms, meanings)
        parakeet_classification = (
            classify_unit(reference, parakeet, terms, meanings) if parakeet is not None else None
        )
        rows.append({
            "id": window["segment"]["id"],
            "block": min(4, index * 5 // count),
            "suspect": bool(window["qwenAssessment"]["signals"]),
            "qwen": qwen,
            "parakeet": parakeet,
            "qwenRaw": window["qwenAssessment"]["rawDefectScore"],
            "parakeetRaw": (
                window["parakeetAssessment"]["rawDefectScore"] + 1 - confidence
                if confidence is not None and window.get("parakeetAssessment") else None
            ),
            "vetoes": window.get("vetoes", []),
            "error": window.get("error"),
            "reference": reference,
            "qwenClassification": qwen_classification,
            "parakeetClassification": parakeet_classification,
            "qwenEdits": edit_count(qwen_classification),
            "parakeetEdits": (
                edit_count(parakeet_classification) if parakeet_classification else None
            ),
        })
    return rows


def project(rows: list[dict], scale, margin: float, stable: bool) -> list[dict]:
    result = []
    for row in rows:
        backend = choose(row, scale, margin) if stable else "qwen-ja"
        text = row["parakeet"] if backend == "parakeet-ja" else row["qwen"]
        result.append({
            "id": row["id"],
            "selectedBackend": backend,
            "selectedText": text.strip(),
            "fallback": backend == "qwen-ja",
            "vetoes": row["vetoes"],
        })
    return result


def calibrate_development(args: argparse.Namespace) -> None:
    plan, run = read_json(args.plan), read_json(args.run)
    manifest, e23 = read_json(args.manifest), read_json(args.e23)
    baseline_manifest = read_json(args.baseline_manifest)
    if plan.get("corpusRole") != "development" or plan.get("holdoutOpened"):
        raise RuntimeError("calibration input is not frozen DEV")
    validate_run(plan, run, args.plan)
    references, mapping = reference_by_segment(args.character_alignment, plan["segments"])
    terms, meanings = classification_terms(manifest, e23)
    rows = calibration_rows(plan, run, references, terms, meanings)
    folds = []
    fold_margins = []
    for block in range(5):
        training = [row for row in rows if row["block"] != block]
        heldout = [row for row in rows if row["block"] == block]
        scale = scales(training)
        margin, candidates = (best_margin(training, scale) if scale else (None, []))
        fold_margins.append(margin)
        folds.append({
            "heldoutBlock": block,
            "trainingBlocks": [value for value in range(5) if value != block],
            "margin": margin,
            "candidates": candidates,
            "heldout": summary(heldout, scale, margin) if scale and margin is not None else None,
        })
    global_scale = scales(rows)
    stable = (global_scale is not None and fold_margins[0] is not None
              and len(set(fold_margins)) == 1
              and all(fold["heldout"] and fold["heldout"]["netEditGain"] >= 0
                      and not fold["heldout"]["criticalLoss"] for fold in folds))
    margin = fold_margins[0] if stable else 0.2
    qwen_scale = global_scale[0] if global_scale else (0.0, 1.0)
    parakeet_scale = global_scale[1] if global_scale else (0.0, 1.0)
    calibration = {
        "version": "adaptive-qwen-parakeet-117-dev-v1",
        "qwen": {
            "backend": "qwen-ja",
            "bestObservedDefect": qwen_scale[0],
            "worstObservedDefect": qwen_scale[1],
            "developmentSamples": len(rows),
            "validationBlocks": 5,
            "stable": stable,
        },
        "parakeet": {
            "backend": "parakeet-ja",
            "bestObservedDefect": parakeet_scale[0],
            "worstObservedDefect": parakeet_scale[1],
            "developmentSamples": sum(row["parakeetRaw"] is not None for row in rows),
            "validationBlocks": 5,
            "stable": stable,
        },
        "minimumMargin": margin,
        "tieTolerance": TIE_TOLERANCE,
        "stableAcrossBlocks": stable,
    }
    selected = project(rows, (qwen_scale, parakeet_scale), margin, stable)
    selected_text = "".join(row["selectedText"] for row in selected)
    reference = "".join(references)
    baseline = read_json(args.baseline_raw)["rawASR"]
    baseline_classification = classify_unit(reference, baseline, terms, meanings)
    selected_classification = classify_unit(reference, selected_text, terms, meanings)
    baseline_edits = edit_count(baseline_classification)
    selected_edits = edit_count(selected_classification)
    relative_gain = 100 * (baseline_edits - selected_edits) / baseline_edits \
        if baseline_edits else 0
    seconds = worker_seconds(run)
    standard_qwen_seconds = stage_seconds(baseline_manifest, "transcribing")
    selections = [row for row in selected if row["selectedBackend"] == "parakeet-ja"]
    critical_dimensions = {
        key: {
            "standardRecovered": baseline_classification[key]["recovered"],
            "adaptiveRecovered": selected_classification[key]["recovered"],
            "lost": sorted(
                set(baseline_classification[key]["recovered"])
                - set(selected_classification[key]["recovered"])
            ),
        } for key in ("terms", "numbers", "meaning")
    }
    gates = {
        "runtimeOnlyDetector": True,
        "shortCompleteAcousticTimeline": max(
            row["endSample"] - row["startSample"] for row in plan["segments"]
        ) <= MAXIMUM_SAMPLES,
        "qwenFirstEverySegment": len(rows) == len(plan["segments"]),
        "parakeetOnlySuspects": all(
            bool(window.get("parakeet") or window.get("error"))
            == bool(window["qwenAssessment"]["signals"]) for window in run["windows"]
        ),
        "strictlySequentialWorkers": run["strictlySequential"],
        "separateStableCalibration": stable,
        "singleFrozenVariable": stable,
        "noCandidateErrors": not run["errors"],
        "completeHypothesesOnly": all(
            row["selectedText"] in (source["qwen"].strip(), (source["parakeet"] or "").strip())
            for row, source in zip(selected, rows)
        ),
        "usefulRecoveries": bool(selections) and selected_edits < baseline_edits,
        "japaneseRelativeGainAtLeast2Percent": relative_gain >= 2,
        "noCriticalLoss": retains_critical(
            baseline_classification, selected_classification
        ),
        "boundedASRCost": sum(seconds.values()) <= 5 * standard_qwen_seconds,
        "peakMemoryWithinBudget": max(
            worker["lifecycle"]["peakPhysicalFootprintBytes"] for worker in run["workers"]
        ) <= MEMORY_BUDGET_BYTES,
        "holdoutClosed": True,
    }
    report = {
        "schemaVersion": 1,
        "ticket": 117,
        "split": "development",
        "decision": "DEV-JA-PASS" if all(gates.values()) else "NO-GO-STOP-BEFORE-DOWNSTREAM",
        "referenceMapping": mapping,
        "calibration": calibration,
        "folds": folds,
        "quality": {
            "standardQwenEdits": baseline_edits,
            "adaptiveEdits": selected_edits,
            "relativeGainPercent": relative_gain,
            "parakeetEscalations": sum(
                bool(window.get("parakeet") or window.get("error"))
                for window in run["windows"]
            ),
            "parakeetSelections": len(selections),
            "vetoedSegments": sum(bool(row["vetoes"]) for row in rows),
            "criticalDimensions": critical_dimensions,
        },
        "runtime": {
            "workerSeconds": seconds,
            "standardQwenASRSeconds": standard_qwen_seconds,
            "incrementalSeconds": {
                "qwenSegmentedVsStandard": seconds["qwen-ja"] - standard_qwen_seconds,
                "parakeet": seconds.get("parakeet-ja", 0),
                "total": sum(seconds.values()) - standard_qwen_seconds,
            },
            "peakPhysicalFootprintBytes": {
                worker["backend"]: worker["lifecycle"]["peakPhysicalFootprintBytes"]
                for worker in run["workers"]
            },
            "workers": run["workers"],
        },
        "selectedTranscriptSHA256": hashlib.sha256(selected_text.encode()).hexdigest(),
        "gates": gates,
    }
    write_json(args.calibration, calibration)
    write_json(args.report, report)


def duplicate_count(values: list[str]) -> int:
    normalized = [normalize(value) for value in values]
    return sum(bool(left) and left == right for left, right in zip(normalized, normalized[1:]))


def score(args: argparse.Namespace) -> None:
    plan, run = read_json(args.plan), read_json(args.run)
    manifest = read_json(args.manifest)
    candidate, candidate_manifest = read_json(args.candidate_raw), read_json(args.candidate_manifest)
    baseline = read_json(args.baseline_raw)
    baseline_manifest = read_json(args.baseline_manifest)
    calibration = read_json(args.calibration)
    e23 = read_json(args.e23)
    validate_run(plan, run, args.plan)
    references, mapping = reference_by_segment(args.character_alignment, plan["segments"])
    terms, meanings = classification_terms(manifest, e23)
    audit = candidate.get("adaptiveASR") or {}
    decisions = audit.get("decisions", [])
    if (candidate_manifest.get("status") != "completed"
            or candidate_manifest.get("selectedASRMode") != "adaptive-qwen-parakeet"
            or audit.get("calibration") != calibration or len(decisions) != len(plan["segments"])):
        raise RuntimeError("candidate audit/manifest is incomplete")
    selected_text = "".join(row["selectedText"].strip() for row in decisions)
    if candidate.get("rawASR") != selected_text:
        raise RuntimeError("candidate transcript differs from its decisions")
    reference = "".join(references)
    baseline_classification = classify_unit(reference, baseline["rawASR"], terms, meanings)
    candidate_classification = classify_unit(reference, selected_text, terms, meanings)
    baseline_edits = edit_count(baseline_classification)
    candidate_edits = edit_count(candidate_classification)
    gain = 100 * (baseline_edits - candidate_edits) / baseline_edits if baseline_edits else 0
    baseline_rows = translation_rows(manifest, baseline)
    candidate_rows = translation_rows(manifest, candidate)
    reference_english = " ".join(row["reference"] for row in candidate_rows)
    baseline_chrf = chrf_pp(" ".join(row["hypothesis"] for row in baseline_rows), reference_english)
    candidate_chrf = chrf_pp(" ".join(row["hypothesis"] for row in candidate_rows), reference_english)
    qwen_windows = [row["qwen"]["rawTranscript"] for row in decisions]
    selected_windows = [row["selectedText"] for row in decisions]
    seconds = worker_seconds(run)
    standard_qwen_seconds = stage_seconds(baseline_manifest, "transcribing")
    selected_count = sum(row["selectedBackend"] == "parakeet-ja" for row in decisions)
    translation_model = candidate["translation"]["model"]
    translator_loads = sum(event.get("kind") == "load-started"
                           and event.get("modelID") == translation_model
                           for event in candidate["modelEvents"])
    gates = {
        "auditIntact": all(row.get("signals") is not None and row.get("executedBackends")
                            and row.get("selectedText") is not None for row in decisions),
        "completeHypothesesOnly": all(
            row["selectedText"] in (
                row["qwen"]["rawTranscript"],
                (row.get("parakeet") or {}).get("rawTranscript"),
            ) for row in decisions
        ),
        "noAddedEmpty": sum(not normalize(value) for value in selected_windows)
            <= sum(not normalize(value) for value in qwen_windows),
        "noAddedDuplicate": duplicate_count(selected_windows) <= duplicate_count(qwen_windows),
        "noCriticalLoss": retains_critical(
            baseline_classification, candidate_classification
        ),
        "usefulJapaneseRecovery": candidate_edits < baseline_edits,
        "japaneseGate": gain >= (2 if args.split == "development" else 0),
        "englishNotWorse": candidate_chrf + 1e-9 >= baseline_chrf,
        "oneTranslation": translator_loads == 1 and candidate.get("translation") is not None,
        "boundedASRCost": sum(seconds.values()) <= 5 * standard_qwen_seconds,
        "peakMemoryWithinBudget": candidate["peakMemoryBytes"] <= MEMORY_BUDGET_BYTES,
        "parakeetWasTargeted": selected_count <= sum(
            bool(row["qwenAssessment"]["signals"]) for row in run["windows"]
        ),
    }
    report = {
        "schemaVersion": 1,
        "ticket": 117,
        "split": args.split,
        "decision": "PASS" if all(gates.values()) else "NO-GO",
        "quality": {
            "standardQwenEdits": baseline_edits,
            "adaptiveEdits": candidate_edits,
            "relativeGainPercent": gain,
            "standardEnglishChrFPlusPlus": baseline_chrf,
            "adaptiveEnglishChrFPlusPlus": candidate_chrf,
            "englishDelta": candidate_chrf - baseline_chrf,
            "parakeetSelections": selected_count,
        },
        "runtime": {
            "workerSeconds": seconds,
            "standardQwenASRSeconds": standard_qwen_seconds,
            "ASRSeconds": sum(seconds.values()),
            "peakPhysicalFootprintBytes": max(
                worker["lifecycle"]["peakPhysicalFootprintBytes"] for worker in run["workers"]
            ),
            "jobPeakMemoryBytes": candidate["peakMemoryBytes"],
        },
        "referenceMapping": mapping,
        "rawArtifacts": {
            str(path): sha256(path) for path in (
                args.plan, args.run, args.calibration, args.candidate_raw,
                args.candidate_manifest, args.baseline_raw, args.baseline_manifest,
                args.character_alignment,
            )
        },
        "gates": gates,
    }
    write_json(args.output, report)


def final_report(args: argparse.Namespace) -> None:
    development, holdout = read_json(args.development), read_json(args.holdout)
    gates = {
        "developmentPassed": development["decision"] == "PASS"
            and all(development["gates"].values()),
        "holdoutPassed": holdout["decision"] == "PASS" and all(holdout["gates"].values()),
        "englishNonRegressionBoth": development["gates"]["englishNotWorse"]
            and holdout["gates"]["englishNotWorse"],
        "usefulRecoveriesBoth": development["gates"]["usefulJapaneseRecovery"]
            and holdout["gates"]["usefulJapaneseRecovery"],
    }
    write_json(args.output, {
        "schemaVersion": 1,
        "ticket": 117,
        "exposeAdaptiveBeta": all(gates.values()),
        "decision": "EXPOSE-BETA" if all(gates.values()) else "RETAIN-HIDDEN",
        "development": development,
        "holdout": holdout,
        "gates": gates,
    })


def self_test() -> None:
    scale = ((0.0, 4.0), (0.0, 1.0))
    row = {
        "suspect": True, "qwenRaw": 4.0, "parakeetRaw": 0.0,
        "vetoes": [], "error": None,
    }
    assert choose(row, scale, 0.2) == "parakeet-ja"
    assert choose({**row, "vetoes": ["lost-number"]}, scale, 0.2) == "qwen-ja"
    assert project([{**row, "id": "one", "qwen": "q", "parakeet": "p"}], scale, 0.2, False)[0][
        "selectedBackend"
    ] == "qwen-ja"
    assert calibrated(2, (0, 4)) == 0.5
    dimensions = {
        key: {"recovered": [], "lost": []} for key in ("terms", "numbers", "meaning")
    }
    rows = []
    for block in range(5):
        rows += [{
            **row,
            "block": block,
            "qwenRaw": 4.0,
            "parakeetRaw": 0.0,
            "qwenEdits": 4,
            "parakeetEdits": 0,
            "qwenClassification": dimensions,
            "parakeetClassification": dimensions,
        }, {
            **row,
            "block": block,
            "qwenRaw": 1.0,
            "parakeetRaw": 1.0,
            "qwenEdits": 0,
            "parakeetEdits": 1,
            "qwenClassification": dimensions,
            "parakeetClassification": dimensions,
        }]
    learned, _ = best_margin(rows, scales(rows))
    assert learned == 0.4
    assert stage_seconds({"stageDurations": ["transcribing", 12.5]}, "transcribing") == 12.5
    assert [bisect_right([10, 20], value) for value in (15, 5)] == [1, 0]
    baseline = {key: {"recovered": []} for key in ("terms", "numbers", "meaning")}
    baseline["numbers"]["recovered"] = ["1000"]
    replacement = {key: {"recovered": []} for key in ("terms", "numbers", "meaning")}
    replacement["numbers"]["recovered"] = ["9000"]
    assert not retains_critical(baseline, replacement)
    replacement["numbers"]["recovered"].append("1000")
    assert retains_critical(baseline, replacement)
    print("adaptive_asr_117 self-test: PASS")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    plan = sub.add_parser("plan")
    plan.add_argument("--audio", type=Path, required=True)
    plan.add_argument("--manifest", type=Path, required=True)
    plan.add_argument("--role", choices=("development", "untouched-holdout"), required=True)
    plan.add_argument("--output", type=Path, required=True)
    calibrate = sub.add_parser("calibrate")
    for name in ("plan", "run", "manifest", "character-alignment", "e23",
                 "baseline-raw", "baseline-manifest", "calibration", "report"):
        calibrate.add_argument(f"--{name}", type=Path, required=True)
    score_parser = sub.add_parser("score")
    score_parser.add_argument("--split", choices=("development", "holdout"), required=True)
    for name in ("plan", "run", "manifest", "character-alignment", "e23",
                 "baseline-raw", "baseline-manifest", "calibration", "candidate-raw", "candidate-manifest",
                 "output"):
        score_parser.add_argument(f"--{name}", type=Path, required=True)
    final = sub.add_parser("final")
    final.add_argument("--development", type=Path, required=True)
    final.add_argument("--holdout", type=Path, required=True)
    final.add_argument("--output", type=Path, required=True)
    return result


def main() -> None:
    args = parser().parse_args()
    if args.command == "self-test":
        self_test()
    elif args.command == "plan":
        write_json(args.output, build_plan(args.audio, args.manifest, args.role))
    elif args.command == "calibrate":
        calibrate_development(args)
    elif args.command == "score":
        score(args)
    else:
        final_report(args)


if __name__ == "__main__":
    main()
