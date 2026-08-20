#!/usr/bin/env python3
"""Frozen incremental Qwen→Parakeet→WhisperKit scorer for issue #118."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

from adaptive_asr_117 import (
    MARGINS,
    MAXIMUM_SAMPLES,
    MEMORY_BUDGET_BYTES,
    TIE_TOLERANCE,
    calibrated,
    classification_terms,
    duplicate_count,
    edit_count,
    parse_date,
    read_json,
    reference_by_segment,
    retains_critical,
    sha256,
    stage_seconds,
    worker_seconds,
    write_json,
)
from report_high_quality_acceptance import translation_rows
from report_japanese_l7d import chrf_pp
from report_qwen_error_diagnostic import classify_unit, normalize


MINIMUM_INCREMENTAL_GAIN_PERCENT = 1.0
TARGET_RATE_LIMIT = 0.25


def is_target(window: dict) -> bool:
    launch = window.get("whisperKitLaunch") or {}
    return launch.get("reason") == "unresolved-material-disagreement"


def validate_run(plan: dict, run: dict, plan_path: Path, base_run: Path,
                 parakeet_calibration: Path) -> None:
    windows, workers = run.get("windows", []), run.get("workers", [])
    launch_calibration = read_json(parakeet_calibration)
    if (plan.get("ticket") != 117 or run.get("ticket") != 118
            or run.get("status") != "completed"
            or run.get("sourceSHA256") != plan.get("audioSHA256")
            or run.get("planSHA256") != sha256(plan_path)
            or run.get("baseRunSHA256") != sha256(base_run)
            or run.get("parakeetCalibrationSHA256") != sha256(parakeet_calibration)
            or len(windows) != len(plan.get("segments", []))
            or [row.get("segment") for row in windows] != plan.get("segments")
            or [worker.get("backend") for worker in workers]
            != ["qwen-ja", "parakeet-ja", "whisperkit"]
            or not run.get("strictlySequential")):
        raise RuntimeError("issue #118 raw run/provenance is incomplete")
    if not (launch_calibration.get("stableAcrossBlocks")
            and launch_calibration.get("qwen", {}).get("stable")
            and launch_calibration.get("parakeet", {}).get("stable")
            and launch_calibration.get("whisperKit", {}).get("stable")):
        raise RuntimeError("WhisperKit launch calibration is not product-stable")
    for left, right in zip(workers, workers[1:]):
        if parse_date(left["lifecycle"]["exitedAt"]) > parse_date(
                right["lifecycle"]["startedAt"]):
            raise RuntimeError("ASR workers overlapped")
    for worker in workers:
        lifecycle = worker.get("lifecycle", {})
        if (lifecycle.get("exitStatus") != 0 or lifecycle.get("forcedTermination")
                or lifecycle.get("peakPhysicalFootprintBytes", 0) <= 0
                or not lifecycle.get("availableMemorySamples")
                or not worker.get("model", {}).get("weightSHA256")):
            raise RuntimeError("ASR worker lifecycle/provenance is incomplete")
    for window in windows:
        launch = window.get("whisperKitLaunch")
        if not isinstance(launch, dict) or not launch.get("reason"):
            raise RuntimeError("WhisperKit non-launch reason is missing from the audit")
        executed = bool(window.get("whisperKit") or window.get("whisperKitError"))
        if executed != is_target(window):
            raise RuntimeError("WhisperKit execution differs from the frozen trigger")
        if executed and window["segment"]["endSample"] - window["segment"][
                "startSample"] > MAXIMUM_SAMPLES:
            raise RuntimeError("WhisperKit received a long window")


def scales(rows: list[dict]):
    qwen = [row["qwenRaw"] for row in rows]
    whisper = [row["whisperKitRaw"] for row in rows]
    if (not qwen or not whisper or max(qwen) <= min(qwen)
            or max(whisper) <= min(whisper)):
        return None
    return (min(qwen), max(qwen)), (min(whisper), max(whisper))


def choose(row: dict, scale, margin: float) -> str:
    if row["vetoes"] or row.get("error") or row.get("whisperKit") is None:
        return "qwen-ja"
    difference = calibrated(row["whisperKitRaw"], scale[1]) - calibrated(
        row["qwenRaw"], scale[0]
    )
    return "whisperkit" if difference > TIE_TOLERANCE and difference > margin \
        else "qwen-ja"


def loses_critical(row: dict) -> bool:
    return not retains_critical(row["qwenClassification"], row["whisperKitClassification"])


def selection_summary(rows: list[dict], scale, margin: float) -> dict:
    selected = [row for row in rows if choose(row, scale, margin) == "whisperkit"]
    gains = [row["qwenEdits"] - row["whisperKitEdits"] for row in selected]
    return {
        "margin": margin,
        "replacements": len(selected),
        "good": sum(value > 0 for value in gains),
        "bad": sum(value < 0 for value in gains),
        "netEditGain": sum(gains),
        "criticalLoss": any(loses_critical(row) for row in selected),
    }


def best_margin(rows: list[dict], scale):
    candidates = [selection_summary(rows, scale, margin) for margin in MARGINS]
    admissible = [row for row in candidates if row["netEditGain"] > 0
                  and row["good"] > row["bad"] and not row["criticalLoss"]]
    if not admissible:
        return None, candidates
    selected = max(admissible, key=lambda row: (
        row["netEditGain"], -row["bad"], -row["replacements"], row["margin"]
    ))
    return selected["margin"], candidates


def calibration_rows(plan: dict, run: dict, references: list[str], terms, meanings):
    rows = []
    count = len(run["windows"])
    for index, (window, reference) in enumerate(zip(run["windows"], references)):
        if not is_target(window):
            continue
        exchange = window.get("whisperKit")
        assessment = window.get("whisperKitAssessment")
        average_log_probability = (exchange or {}).get("averageLogProbability")
        if exchange is None or assessment is None or average_log_probability is None:
            continue
        qwen = window["qwen"]["rawTranscript"]
        whisper = exchange["rawTranscript"]
        qwen_classification = classify_unit(reference, qwen, terms, meanings)
        whisper_classification = classify_unit(reference, whisper, terms, meanings)
        rows.append({
            "id": window["segment"]["id"],
            "block": min(4, index * 5 // count),
            "qwen": qwen,
            "whisperKit": whisper,
            "qwenRaw": window["qwenAssessment"]["rawDefectScore"],
            "whisperKitRaw": assessment["rawDefectScore"] - average_log_probability,
            "vetoes": window.get("whisperKitVetoes", []),
            "error": window.get("whisperKitError"),
            "qwenClassification": qwen_classification,
            "whisperKitClassification": whisper_classification,
            "qwenEdits": edit_count(qwen_classification),
            "whisperKitEdits": edit_count(whisper_classification),
        })
    return rows


def projected_windows(run: dict, rows: list[dict], scale, margin: float, stable: bool):
    by_id = {row["id"]: row for row in rows}
    projected = []
    for window in run["windows"]:
        row = by_id.get(window["segment"]["id"])
        backend = choose(row, scale, margin) if stable and row else "qwen-ja"
        selected = window["whisperKit"]["rawTranscript"] \
            if backend == "whisperkit" else window["qwen"]["rawTranscript"]
        projected.append({
            "id": window["segment"]["id"],
            "selectedBackend": backend,
            "selectedText": selected.strip(),
        })
    return projected


def calibrate_development(args: argparse.Namespace) -> None:
    plan, run = read_json(args.plan), read_json(args.run)
    base_run, p_calibration = read_json(args.base_run), read_json(args.parakeet_calibration)
    manifest, e23 = read_json(args.manifest), read_json(args.e23)
    baseline_manifest = read_json(args.baseline_manifest)
    if plan.get("corpusRole") != "development" or plan.get("holdoutOpened"):
        raise RuntimeError("calibration input is not frozen DEV")
    validate_run(plan, run, args.plan, args.base_run, args.parakeet_calibration)
    if (base_run.get("ticket") != 117 or p_calibration.get("stableAcrossBlocks")
            or p_calibration.get("parakeet", {}).get("stable")):
        raise RuntimeError("Qwen→Parakeet control is not the frozen unresolved #117 policy")
    references, mapping = reference_by_segment(args.character_alignment, plan["segments"])
    terms, meanings = classification_terms(manifest, e23)
    rows = calibration_rows(plan, run, references, terms, meanings)
    folds, fold_margins = [], []
    for block in range(5):
        training = [row for row in rows if row["block"] != block]
        heldout = [row for row in rows if row["block"] == block]
        scale = scales(training)
        margin, candidates = best_margin(training, scale) if scale else (None, [])
        heldout_summary = selection_summary(heldout, scale, margin) \
            if heldout and scale and margin is not None else None
        fold_margins.append(margin)
        folds.append({
            "heldoutBlock": block,
            "margin": margin,
            "candidates": candidates,
            "heldout": heldout_summary,
        })
    global_scale = scales(rows)
    stable = (global_scale is not None and fold_margins[0] is not None
              and len(set(fold_margins)) == 1
              and all(fold["heldout"] and fold["heldout"]["netEditGain"] >= 0
                      and not fold["heldout"]["criticalLoss"] for fold in folds))
    margin = fold_margins[0] if stable else 0.2
    qwen_scale = global_scale[0] if global_scale else (0.0, 1.0)
    whisper_scale = global_scale[1] if global_scale else (0.0, 1.0)
    p_qwen = p_calibration["qwen"]
    parakeet = p_calibration["parakeet"]
    calibration = {
        "version": "adaptive-qwen-parakeet-whisperkit-118-dev-v1",
        "qwen": {
            "backend": "qwen-ja",
            "bestObservedDefect": qwen_scale[0],
            "worstObservedDefect": qwen_scale[1],
            "developmentSamples": len(rows),
            "validationBlocks": 5,
            "stable": stable,
        },
        "parakeet": {
            **parakeet,
            "stable": False,
        },
        "whisperKit": {
            "backend": "whisperkit",
            "bestObservedDefect": whisper_scale[0],
            "worstObservedDefect": whisper_scale[1],
            "developmentSamples": len(rows),
            "validationBlocks": 5,
            "stable": stable,
        },
        "minimumMargin": margin,
        "tieTolerance": TIE_TOLERANCE,
        "stableAcrossBlocks": stable,
    }
    selected = projected_windows(run, rows, (qwen_scale, whisper_scale), margin, stable)
    qwen_windows = [window["qwen"]["rawTranscript"].strip() for window in run["windows"]]
    selected_windows = [row["selectedText"] for row in selected]
    reference = "".join(references)
    qwen_classification = classify_unit(reference, "".join(qwen_windows), terms, meanings)
    selected_classification = classify_unit(reference, "".join(selected_windows), terms, meanings)
    qwen_edits, selected_edits = edit_count(qwen_classification), edit_count(selected_classification)
    gain = 100 * (qwen_edits - selected_edits) / qwen_edits if qwen_edits else 0
    target_count = sum(is_target(window) for window in run["windows"])
    selection_count = sum(row["selectedBackend"] == "whisperkit" for row in selected)
    seconds = worker_seconds(run)
    standard_qwen_seconds = stage_seconds(baseline_manifest, "transcribing")
    gates = {
        "runtimeOnlyTrigger": True,
        "shortWindowsOnly": max(row["endSample"] - row["startSample"]
                                for row in plan["segments"]) <= MAXIMUM_SAMPLES,
        "qwenFirstParakeetSecondWhisperKitThird": run["strictlySequential"],
        "whisperKitOnlyAfterMaterialUnresolvedDisagreement": all(
            bool(window.get("whisperKit") or window.get("whisperKitError")) == is_target(window)
            for window in run["windows"]
        ),
        "targetedNotSystematic": 0 < target_count / len(run["windows"]) < TARGET_RATE_LIMIT,
        "candidateFailuresFallbackSafely": all(
            error.get("route") == "candidate"
            and error.get("stage") == "whisperkit-transcription"
            for error in run["errors"]
        ),
        "completeHypothesesOnly": all(row["selectedText"] in (
            source["qwen"]["rawTranscript"].strip(),
            (source.get("whisperKit") or {}).get("rawTranscript", "").strip(),
        ) for row, source in zip(selected, run["windows"])),
        "separateStableCalibration": stable,
        "oneFrozenMargin": stable,
        "noAddedEmptyTurns": sum(not normalize(value) for value in selected_windows)
            <= sum(not normalize(value) for value in qwen_windows),
        "noAddedDuplicateTurns": duplicate_count(selected_windows)
            <= duplicate_count(qwen_windows),
        "noNumberTermMeaningLoss": retains_critical(qwen_classification, selected_classification),
        "usefulIncrementalRecovery": selection_count > 0 and selected_edits < qwen_edits,
        "incrementalGainAtLeast1Percent": gain >= MINIMUM_INCREMENTAL_GAIN_PERCENT,
        "boundedASRCost": sum(seconds.values()) <= 5 * standard_qwen_seconds,
        "peakASRMemoryWithin14GiB": max(worker["lifecycle"]["peakPhysicalFootprintBytes"]
                                          for worker in run["workers"])
            <= MEMORY_BUDGET_BYTES,
        "holdoutClosed": True,
    }
    report = {
        "schemaVersion": 1,
        "ticket": 118,
        "split": "development",
        "decision": "DEV-JA-PASS" if all(gates.values())
            else "NO-GO-STOP-BEFORE-DOWNSTREAM",
        "referenceMapping": mapping,
        "folds": folds,
        "quality": {
            "qwenParakeetControlEdits": qwen_edits,
            "withWhisperKitEdits": selected_edits,
            "incrementalGainPercent": gain,
            "whisperKitTargets": target_count,
            "whisperKitSelections": selection_count,
            "whisperKitExecutionRate": target_count / len(run["windows"]),
            "whisperKitCandidateFailures": len(run["errors"]),
        },
        "runtime": {
            "workerSeconds": seconds,
            "standardQwenASRSeconds": standard_qwen_seconds,
            "whisperKitIncrementalSeconds": seconds.get("whisperkit", 0),
            "peakPhysicalFootprintBytes": {
                worker["backend"]: worker["lifecycle"]["peakPhysicalFootprintBytes"]
                for worker in run["workers"]
            },
        },
        "control": {
            "baseRunSHA256": sha256(args.base_run),
            "parakeetCalibrationSHA256": sha256(args.parakeet_calibration),
            "parakeetCalibrationQwenSamples": p_qwen["developmentSamples"],
        },
        "selectedTranscriptSHA256": hashlib.sha256(
            "".join(selected_windows).encode()
        ).hexdigest(),
        "gates": gates,
    }
    write_json(args.calibration, calibration)
    write_json(args.report, report)


def score(args: argparse.Namespace) -> None:
    plan, run = read_json(args.plan), read_json(args.run)
    calibration, candidate = read_json(args.calibration), read_json(args.candidate_raw)
    candidate_manifest = read_json(args.candidate_manifest)
    baseline, manifest = read_json(args.baseline_raw), read_json(args.manifest)
    e23 = read_json(args.e23)
    validate_run(plan, run, args.plan, args.base_run, args.parakeet_calibration)
    references, mapping = reference_by_segment(args.character_alignment, plan["segments"])
    terms, meanings = classification_terms(manifest, e23)
    audit = candidate.get("adaptiveASR") or {}
    decisions = audit.get("decisions", [])
    if (candidate_manifest.get("status") != "completed"
            or audit.get("calibration") != calibration
            or len(decisions) != len(plan["segments"])):
        raise RuntimeError("downstream candidate audit is incomplete")
    selected_windows = [row["selectedText"] for row in decisions]
    selected_text = "".join(value.strip() for value in selected_windows)
    if candidate.get("rawASR") != selected_text:
        raise RuntimeError("downstream transcript differs from its audited decisions")
    qwen_windows = [window["qwen"]["rawTranscript"] for window in run["windows"]]
    reference = "".join(references)
    qwen_classification = classify_unit(reference, "".join(qwen_windows), terms, meanings)
    candidate_classification = classify_unit(reference, selected_text, terms, meanings)
    qwen_edits, candidate_edits = edit_count(qwen_classification), edit_count(candidate_classification)
    gain = 100 * (qwen_edits - candidate_edits) / qwen_edits if qwen_edits else 0
    baseline_rows = translation_rows(manifest, baseline)
    candidate_rows = translation_rows(manifest, candidate)
    reference_english = " ".join(row["reference"] for row in candidate_rows)
    baseline_chrf = chrf_pp(" ".join(row["hypothesis"] for row in baseline_rows), reference_english)
    candidate_chrf = chrf_pp(" ".join(row["hypothesis"] for row in candidate_rows), reference_english)
    translation_model = candidate["translation"]["model"]
    translator_loads = sum(event.get("kind") == "load-started"
                           and event.get("modelID") == translation_model
                           for event in candidate["modelEvents"])
    gates = {
        "auditIntact": all(row.get("whisperKitLaunch") is not None
                           and row.get("whisperKitDisposition") is not None
                           for row in decisions),
        "completeHypothesesOnly": all(row["selectedText"] in (
            row["qwen"]["rawTranscript"],
            (row.get("whisperKit") or {}).get("rawTranscript"),
        ) for row in decisions),
        "noAddedEmptyTurns": sum(not normalize(value) for value in selected_windows)
            <= sum(not normalize(value) for value in qwen_windows),
        "noAddedDuplicateTurns": duplicate_count(selected_windows)
            <= duplicate_count(qwen_windows),
        "noNumberTermMeaningLoss": retains_critical(qwen_classification, candidate_classification),
        "usefulIncrementalRecovery": candidate_edits < qwen_edits,
        "incrementalJapaneseGate": gain >= (
            MINIMUM_INCREMENTAL_GAIN_PERCENT if args.split == "development" else 0
        ),
        "englishNotWorse": candidate_chrf + 1e-9 >= baseline_chrf,
        "oneTranslation": translator_loads == 1 and candidate.get("translation") is not None,
        "peakWorkflowMemoryWithin18GiB": candidate["peakMemoryBytes"] <= 18 * 1024**3,
    }
    write_json(args.output, {
        "schemaVersion": 1,
        "ticket": 118,
        "split": args.split,
        "decision": "PASS" if all(gates.values()) else "NO-GO",
        "quality": {
            "qwenParakeetControlEdits": qwen_edits,
            "withWhisperKitEdits": candidate_edits,
            "incrementalGainPercent": gain,
            "baselineEnglishChrFPlusPlus": baseline_chrf,
            "withWhisperKitEnglishChrFPlusPlus": candidate_chrf,
            "englishDelta": candidate_chrf - baseline_chrf,
        },
        "referenceMapping": mapping,
        "rawArtifacts": {str(path): sha256(path) for path in (
            args.plan, args.run, args.base_run, args.parakeet_calibration,
            args.calibration, args.candidate_raw, args.candidate_manifest,
            args.baseline_raw, args.character_alignment,
        )},
        "gates": gates,
    })


def final_report(args: argparse.Namespace) -> None:
    development, holdout = read_json(args.development), read_json(args.holdout)
    gates = {
        "developmentPassed": development["decision"] == "PASS"
            and all(development["gates"].values()),
        "holdoutPassed": holdout["decision"] == "PASS"
            and all(holdout["gates"].values()),
        "englishNonRegressionBoth": development["gates"]["englishNotWorse"]
            and holdout["gates"]["englishNotWorse"],
        "usefulRecoveriesBoth": development["gates"]["usefulIncrementalRecovery"]
            and holdout["gates"]["usefulIncrementalRecovery"],
    }
    write_json(args.output, {
        "schemaVersion": 1,
        "ticket": 118,
        "decision": "KEEP-TARGETED-WHISPERKIT" if all(gates.values()) else "RETAIN-HIDDEN",
        "gates": gates,
        "development": development,
        "holdout": holdout,
    })


def self_test() -> None:
    dimensions = {key: {"recovered": []} for key in ("terms", "numbers", "meaning")}
    rows = []
    for block in range(5):
        rows += [{
            "id": f"good-{block}", "block": block, "qwenRaw": 4.0,
            "whisperKitRaw": 0.0, "qwenEdits": 4, "whisperKitEdits": 0,
            "qwenClassification": dimensions, "whisperKitClassification": dimensions,
            "vetoes": [], "error": None, "whisperKit": "better",
        }, {
            "id": f"bad-{block}", "block": block, "qwenRaw": 1.0,
            "whisperKitRaw": 1.0, "qwenEdits": 0, "whisperKitEdits": 1,
            "qwenClassification": dimensions, "whisperKitClassification": dimensions,
            "vetoes": [], "error": None, "whisperKit": "worse",
        }]
    scale = scales(rows)
    margin, _ = best_margin(rows, scale)
    assert margin == 0.4
    assert choose(rows[0], scale, margin) == "whisperkit"
    assert choose({**rows[0], "vetoes": ["lost-number"]}, scale, margin) == "qwen-ja"
    print("adaptive_asr_118 self-test: PASS")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    calibrate = sub.add_parser("calibrate")
    for name in ("plan", "run", "base-run", "parakeet-calibration", "manifest",
                 "character-alignment", "e23", "baseline-manifest",
                 "calibration", "report"):
        calibrate.add_argument(f"--{name}", type=Path, required=True)
    score_parser = sub.add_parser("score")
    score_parser.add_argument("--split", choices=("development", "holdout"), required=True)
    for name in ("plan", "run", "base-run", "parakeet-calibration", "manifest",
                 "character-alignment", "e23", "baseline-raw", "calibration",
                 "candidate-raw", "candidate-manifest", "output"):
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
    elif args.command == "calibrate":
        calibrate_development(args)
    elif args.command == "score":
        score(args)
    else:
        final_report(args)


if __name__ == "__main__":
    main()
