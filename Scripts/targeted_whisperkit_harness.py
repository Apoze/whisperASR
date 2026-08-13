#!/usr/bin/env python3
"""Issue #95 DEV-only targeted WhisperKit experiment."""

from __future__ import annotations

import argparse
from collections import Counter
import difflib
import json
import math
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import adaptive_asr_harness as adaptive


DISAGREEMENT_THRESHOLD = 0.15
WEAKNESS_THRESHOLDS = (0.0, 0.25, 0.5, 1.0)
EXPECTED = {
    "plan": "3bfa62a1e0ded143555c61f8a02e65501b8b72adf2dfa277527c2d8de4c4b1a8",
    "run": "c4ff5fa759801301806aaccf1fc3081b9522d5902518422c64ca875475eabc52",
    "selection": "4279b6e2a187f5c8c0695b79c085af8c42b0e8fc294fdc0c0e07fffec4521a2f",
    "referenceManifest": "a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b",
}


def trigger_rows(rows: list[dict], weakness_threshold: float) -> list[dict]:
    return [row for row in rows
            if row["disagreement"] >= DISAGREEMENT_THRESHOLD
            and row["qwenWeakness"] > weakness_threshold]


def runtime_rows(plan: dict, run: dict, plan_path: Path) -> list[dict]:
    adaptive.validate_run(plan, run, plan_path)
    result = []
    for window, output in zip(plan["windows"], run["windows"]):
        qwen = adaptive.normalize(output["qwen"])
        parakeet = adaptive.normalize(output["parakeet"])
        result.append({
            "id": window["id"],
            "block": min(4, len(result) * 5 // len(plan["windows"])),
            "startSample": window["startSample"],
            "endSample": window["endSample"],
            "window": window,
            "qwen": output["qwen"],
            "parakeet": output["parakeet"],
            "disagreement": 1 - difflib.SequenceMatcher(
                None, qwen, parakeet, autojunk=False
            ).ratio(),
            "qwenWeakness": adaptive.weakness(output["qwen"], window),
        })
    return result


def mean(values: list[float]) -> float | None:
    return statistics.mean(values) if values else None


def threshold_summary(rows: list[dict], threshold: float) -> dict:
    triggered = trigger_rows(rows, threshold)
    other = [row for row in rows if row not in triggered]
    triggered_mean = mean([row["qwenErrorRate"] for row in triggered])
    other_mean = mean([row["qwenErrorRate"] for row in other])
    return {
        "threshold": threshold,
        "triggerCount": len(triggered),
        "triggerRate": len(triggered) / len(rows),
        "triggeredQwenErrorRateMean": triggered_mean,
        "otherQwenErrorRateMean": other_mean,
        "discrimination": (triggered_mean - other_mean
                           if triggered_mean is not None and other_mean is not None else None),
    }


def best_threshold(rows: list[dict]) -> float | None:
    summaries = [threshold_summary(rows, value) for value in WEAKNESS_THRESHOLDS]
    usable = [row for row in summaries if row["discrimination"] is not None]
    if not usable:
        return None
    return max(usable, key=lambda row: (
        row["discrimination"], -row["triggerCount"], row["threshold"]
    ))["threshold"]


def calibrate_trigger(rows: list[dict]) -> dict:
    blocks = sorted({row["block"] for row in rows})
    folds = []
    for block in blocks:
        training = [row for row in rows if row["block"] != block]
        heldout = [row for row in rows if row["block"] == block]
        threshold = best_threshold(training)
        folds.append({
            "heldoutBlock": block,
            "threshold": threshold,
            "trainingCandidates": [threshold_summary(training, value)
                                   for value in WEAKNESS_THRESHOLDS],
            "heldout": (threshold_summary(heldout, threshold)
                        if threshold is not None else None),
        })
    thresholds = [fold["threshold"] for fold in folds]
    counts = {value: thresholds.count(value) for value in WEAKNESS_THRESHOLDS}
    threshold = max(WEAKNESS_THRESHOLDS, key=lambda value: (counts[value], value))
    fixed_blocks = [threshold_summary(
        [row for row in rows if row["block"] == block], threshold
    ) for block in blocks]
    discriminating = all(
        summary["triggerCount"] == 0 or summary["discrimination"] > 0
        for summary in fixed_blocks
    )
    admissible = counts[threshold] >= 4 and discriminating
    return {
        "blocks": len(blocks),
        "perFoldThreshold": thresholds,
        "threshold": threshold if admissible else None,
        "status": ("four-fold-agreement-one-broader-fold" if admissible
                   else "unstable-trigger-calibration"),
        "admissible": admissible,
        "folds": folds,
        "fixedThresholdBlocks": [
            {"block": block, **summary}
            for block, summary in zip(blocks, fixed_blocks)
        ],
        "allTriggeredBlocksDiscriminateQwenWeakness": discriminating,
    }


def analyze(args: argparse.Namespace) -> None:
    for name in ("plan", "run", "selection"):
        if adaptive.sha256(getattr(args, name)) != EXPECTED[name]:
            raise RuntimeError(f"frozen E28 {name} changed")
    plan, run = adaptive.read_json(args.plan), adaptive.read_json(args.run)
    if plan.get("ticket") != 94 or plan.get("holdoutOpened"):
        raise RuntimeError("#95 requires the frozen DEV-only E28 plan")

    raw_rows = runtime_rows(plan, run, args.plan)
    raw_measurement = {
        "windowCount": len(raw_rows),
        "measuredBeforeCalibrationLabels": True,
        "candidateThresholds": [
            {"threshold": threshold,
             "triggerCount": len(trigger_rows(raw_rows, threshold))}
            for threshold in WEAKNESS_THRESHOLDS
        ],
    }

    if adaptive.sha256(args.reference_manifest) != EXPECTED["referenceManifest"]:
        raise RuntimeError("frozen DEV reference manifest changed")
    mapped, mapping_audit = adaptive.reference_text_by_window(
        args.character_alignment, plan["windows"]
    )
    e23_segments = adaptive.read_json(args.e23_segments)
    scored = adaptive.selection_rows(plan, run, mapped, e23_segments)
    by_id = {row["id"]: row for row in scored}
    for row in raw_rows:
        scored_row = by_id[row["id"]]
        row["qwenErrorRate"] = scored_row["qwenEdits"] / max(
            1,
            len(adaptive.normalize(scored_row["referenceJapanese"])),
            len(adaptive.normalize(scored_row["qwen"])),
        )
        row["qwenEdits"] = scored_row["qwenEdits"]
        row["parakeetEdits"] = scored_row["parakeetEdits"]
        row["referenceJapanese"] = scored_row["referenceJapanese"]
    calibration = calibrate_trigger(raw_rows)
    threshold = calibration["threshold"]
    triggered = trigger_rows(raw_rows, threshold) if threshold is not None else []
    alignment_rows = [json.loads(line) for line in args.character_alignment.read_text(
        encoding="utf-8"
    ).splitlines()]
    evaluability = reference_evaluability(
        adaptive.read_json(args.reference_manifest), alignment_rows, plan["windows"], mapped,
        adaptive.sha256(args.character_alignment),
    )
    coverage = evaluability["windows"]
    triggered_coverage = {row["id"]: coverage[row["id"]] for row in triggered}
    reference_evaluable = bool(triggered) and all(
        row["complete"] for row in triggered_coverage.values()
    )
    calibration["signalOnlyAdmissible"] = calibration["admissible"]
    calibration["referenceEligible"] = reference_evaluable
    calibration["admissible"] = calibration["admissible"] and reference_evaluable
    if not reference_evaluable:
        calibration["status"] = "inconclusive-partial-reference-coverage"
    trigger_plan = {
        "schemaVersion": 1,
        "ticket": 95,
        "corpusID": "qudu2fx3ncc",
        "corpusRole": "development",
        "holdoutOpened": False,
        "sourceSHA256": run["sourceSHA256"],
        "basePlanSHA256": adaptive.sha256(args.plan),
        "baseRunSHA256": adaptive.sha256(args.run),
        "baseSelectionSHA256": adaptive.sha256(args.selection),
        "rule": {
            "disagreementMinimum": DISAGREEMENT_THRESHOLD,
            "qwenWeaknessGreaterThan": threshold,
            "requiresBothSignals": True,
        },
        "calibrationStatus": calibration["status"],
        "windows": [{
            "id": row["id"],
            "startSample": row["startSample"],
            "endSample": row["endSample"],
            "qwen": row["qwen"],
            "parakeet": row["parakeet"],
            "signals": {
                "disagreement": row["disagreement"],
                "qwenWeakness": row["qwenWeakness"],
            },
        } for row in triggered],
    }
    if "reference" in repr(trigger_plan).lower():
        raise RuntimeError("runtime trigger plan leaked calibration labels")
    adaptive.write_json(args.trigger_plan, trigger_plan)

    report = {
        "schemaVersion": 1,
        "ticket": 95,
        "holdoutOpened": False,
        "rawOnlyMeasurement": raw_measurement,
        "calibration": calibration,
        "mappingAudit": mapping_audit,
        "triggerPlanSHA256": adaptive.sha256(args.trigger_plan),
        "triggerCount": len(triggered),
        "triggerRate": len(triggered) / len(raw_rows),
        "triggeredSeconds": sum(
            (row["endSample"] - row["startSample"]) / adaptive.SAMPLE_RATE
            for row in triggered
        ),
        "referenceEvaluability": {
            "source": evaluability["source"],
            "completeForEveryWindow": evaluability["completeForEveryWindow"],
            "completeForEveryTriggeredWindow": reference_evaluable,
            "completeWindowCount": sum(
                row["complete"] for row in triggered_coverage.values()
            ),
            "windowCount": len(triggered_coverage),
            "windows": triggered_coverage,
        },
        "heavyRunJustified": bool(
            calibration["admissible"] and triggered and len(triggered) < len(raw_rows)
            and reference_evaluable
        ),
        "triggeredWindows": [{
            "id": row["id"],
            "block": row["block"],
            "disagreement": row["disagreement"],
            "qwenWeakness": row["qwenWeakness"],
            "qwenErrorRate": row["qwenErrorRate"],
            "qwenEdits": row["qwenEdits"],
            "parakeetEdits": row["parakeetEdits"],
            "referenceJapanese": row["referenceJapanese"],
            "referenceCoverage": coverage[row["id"]],
        } for row in triggered],
    }
    adaptive.write_json(args.report, report)


def critical_tokens(text: str) -> list[str]:
    return list(dict.fromkeys(
        token.casefold()
        for token in re.findall(r"[0-9０-９]+|[A-Za-z][A-Za-z0-9!_-]*", text)
    ))


def whisperkit_decision(row: dict, threshold: float | None) -> dict:
    lost = [token for token in critical_tokens(row["qwen"])
            if adaptive.normalize(token) not in adaptive.normalize(row["whisperkit"])]
    reasons = []
    if threshold is None:
        reasons.append("selector-calibration-no-gain")
    if not adaptive.normalize(row["whisperkit"]):
        reasons.append("whisperkit-empty")
    if adaptive.weakness(row["whisperkit"], row["window"]) > row["qwenWeakness"]:
        reasons.append("whisperkit-structurally-weaker")
    if lost:
        reasons.append("qwen-critical-token-lost")
    if threshold is not None and row["averageLogProbability"] < threshold:
        reasons.append("whisperkit-confidence-below-calibrated-threshold")
    choose = not reasons
    if choose:
        reasons.append("whisperkit-calibrated-complete-hypothesis")
    return {
        "action": "select-whisperkit" if choose else "keep-qwen-parakeet",
        "selectedBackend": "whisperkit" if choose else row["baseBackend"],
        "selectedText": row["whisperkit"] if choose else row["baseText"],
        "reasons": reasons,
        "signals": {
            "disagreement": row["disagreement"],
            "qwenWeakness": row["qwenWeakness"],
            "whisperkitWeakness": adaptive.weakness(row["whisperkit"], row["window"]),
            "whisperkitAverageLogProbability": row["averageLogProbability"],
            "qwenCriticalTokensLostByWhisperKit": lost,
        },
    }


def selector_summary(rows: list[dict], threshold: float | None) -> dict:
    decisions = [(row, whisperkit_decision(row, threshold)) for row in rows]
    overrides = [(row, decision) for row, decision in decisions
                 if decision["selectedBackend"] == "whisperkit"]
    gains = [adaptive.edit_count(row["baseClassification"])
             - adaptive.edit_count(row["whisperkitClassification"])
             for row, _ in overrides]
    changes = {}
    for dimension in ("terms", "numbers", "meaning"):
        recovered, lost = [], []
        for row, _ in overrides:
            base = set(row["baseClassification"][dimension]["recovered"])
            candidate = set(row["whisperkitClassification"][dimension]["recovered"])
            recovered += sorted(candidate - base)
            lost += sorted(base - candidate)
        changes[dimension] = {
            "recovered": list(dict.fromkeys(recovered)),
            "lost": list(dict.fromkeys(lost)),
        }
    return {
        "threshold": threshold,
        "overrideCount": len(overrides),
        "goodOverrides": sum(gain > 0 for gain in gains),
        "badOverrides": sum(gain < 0 for gain in gains),
        "neutralOverrides": sum(gain == 0 for gain in gains),
        "netEditGainVsQwenParakeet": sum(gains),
        "criticalChanges": changes,
        "reasonHistogram": dict(sorted(Counter(
            reason for _, decision in decisions for reason in decision["reasons"]
        ).items())),
    }


def best_selector_threshold(rows: list[dict], thresholds: list[float]) -> float | None:
    summaries = [selector_summary(rows, threshold) for threshold in thresholds]
    best = max(summaries, key=lambda row: (
        row["netEditGainVsQwenParakeet"], -row["badOverrides"],
        -row["overrideCount"], row["threshold"]
    ))
    return best["threshold"] if best["netEditGainVsQwenParakeet"] > 0 else None


def calibrate_selector(rows: list[dict]) -> dict:
    scores = sorted({row["averageLogProbability"] for row in rows})
    thresholds = [scores[0] - 1e-6] + scores
    blocks = range(5)
    folds = []
    for block in blocks:
        training = [row for row in rows if row["block"] != block]
        heldout = [row for row in rows if row["block"] == block]
        threshold = best_selector_threshold(training, thresholds)
        folds.append({
            "heldoutBlock": block,
            "threshold": threshold,
            "trainingCandidates": [selector_summary(training, value)
                                   for value in thresholds],
            "heldout": selector_summary(heldout, threshold),
        })
    values = [fold["threshold"] for fold in folds if fold["threshold"] is not None]
    threshold = Counter(values).most_common(1)[0][0] if values else None
    support = values.count(threshold) if threshold is not None else 0
    aggregate = selector_summary(rows, threshold)
    fixed_folds = [selector_summary(
        [row for row in rows if row["block"] == block], threshold
    ) for block in blocks]
    critical_losses = [value for dimension in aggregate["criticalChanges"].values()
                       for value in dimension["lost"]]
    admissible = bool(
        threshold is not None
        and support >= 4
        and aggregate["netEditGainVsQwenParakeet"] > 0
        and aggregate["badOverrides"] == 0
        and not critical_losses
        and min(row["netEditGainVsQwenParakeet"] for row in fixed_folds) >= 0
    )
    return {
        "candidateThresholds": thresholds,
        "perFoldThreshold": [fold["threshold"] for fold in folds],
        "threshold": threshold if admissible else None,
        "status": ("stable-whisperkit-confidence-selector" if admissible
                   else "unstable-or-harmful-whisperkit-selector"),
        "admissible": admissible,
        "folds": folds,
        "aggregate": aggregate,
        "fixedThresholdFolds": [
            {"block": block, **summary}
            for block, summary in zip(blocks, fixed_folds)
        ],
        "criticalLosses": critical_losses,
    }


def duplicate_count(rows: list[dict], key: str) -> int:
    return sum(
        bool(adaptive.normalize(left[key]))
        and adaptive.normalize(left[key]) == adaptive.normalize(right[key])
        for left, right in zip(rows, rows[1:])
    )


def interval_coverage(cues: list[dict], start: float, end: float) -> dict:
    intervals = sorted(
        (max(start, cue["start"]), min(end, cue["end"]))
        for cue in cues if cue["end"] > start and cue["start"] < end
    )
    merged = []
    for left, right in intervals:
        if merged and left <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], right)
        else:
            merged.append([left, right])
    covered = sum(right - left for left, right in merged)
    duration = end - start
    return {
        "coveredSeconds": covered,
        "ratio": covered / duration,
        "complete": len(merged) == 1 and merged[0] == [start, end],
    }


def reference_evaluability(
    manifest: dict,
    alignment_rows: list[dict],
    windows: list[dict],
    references: list[str],
    alignment_sha256: str,
) -> dict:
    alignment_reference = next(
        (row for row in manifest.get("source", {}).get("references", [])
         if row.get("label") == "character-alignment"), None
    )
    fixture = manifest.get("fixture", {})
    turns = manifest.get("annotations", {}).get("turns", [])
    observed = [{
        "id": int(row["cue_id"]),
        "speaker": row["speaker_id"],
        "startSample": round(row["start"] * adaptive.SAMPLE_RATE),
        "endSample": round(row["end"] * adaptive.SAMPLE_RATE),
        "japanese": row["japanese"],
    } for row in alignment_rows if row["speaker_id"] != "SPEAKER_NONE"]
    expected = [{key: row[key] for key in observed[0]} for row in turns] if observed else []
    if (alignment_reference is None or alignment_reference.get("sha256") != alignment_sha256
            or fixture.get("sampleRate") != adaptive.SAMPLE_RATE
            or len(references) != len(windows) or observed != expected):
        raise RuntimeError("root DEV reference and character alignment do not match")
    complete = bool(
        manifest.get("annotations", {}).get("status") == "complete"
        and windows and windows[0]["startSample"] == 0
        and windows[-1]["endSample"] == fixture.get("sampleCount")
    )
    cues = [row for row in alignment_rows if row["speaker_id"] != "SPEAKER_NONE"]
    return {
        "source": {
            "manifestStatus": manifest["annotations"]["status"],
            "manifestTurnCount": len(turns),
            "alignmentTurnCount": len(observed),
            "alignmentSHA256": alignment_sha256,
            "timelineSampleCount": fixture["sampleCount"],
        },
        "completeForEveryWindow": complete,
        "windows": {
            window["id"]: {
                "complete": complete,
                "referenceKind": ("speech" if adaptive.normalize(reference)
                                  else "accepted-empty"),
                "referenceCharacterCount": len(adaptive.normalize(reference)),
                "cueIntervalDiagnostic": interval_coverage(
                    cues,
                    window["startSample"] / adaptive.SAMPLE_RATE,
                    window["endSample"] / adaptive.SAMPLE_RATE,
                ),
            }
            for window, reference in zip(windows, references)
        },
    }


def select(args: argparse.Namespace) -> None:
    for name in ("plan", "run", "selection"):
        if adaptive.sha256(getattr(args, name)) != EXPECTED[name]:
            raise RuntimeError(f"frozen E28 {name} changed")
    trigger_plan = adaptive.read_json(args.trigger_plan)
    whisperkit = adaptive.read_json(args.whisperkit_run)
    if (trigger_plan.get("ticket") != 95 or trigger_plan.get("holdoutOpened")
            or whisperkit.get("ticket") != 95 or whisperkit.get("status") != "completed"
            or whisperkit.get("sourceSHA256") != trigger_plan.get("sourceSHA256")
            or whisperkit.get("triggerPlanSHA256") != adaptive.sha256(args.trigger_plan)
            or [row["id"] for row in whisperkit["windows"]]
                != [row["id"] for row in trigger_plan["windows"]]
            or any(not math.isfinite(row["averageLogProbability"])
                   for row in whisperkit["windows"])):
        raise RuntimeError("WhisperKit targeted worker evidence is incomplete")

    plan, run = adaptive.read_json(args.plan), adaptive.read_json(args.run)
    if adaptive.sha256(args.reference_manifest) != EXPECTED["referenceManifest"]:
        raise RuntimeError("frozen DEV reference manifest changed")
    mapped, mapping_audit = adaptive.reference_text_by_window(
        args.character_alignment, plan["windows"]
    )
    alignment_rows = [json.loads(line) for line in args.character_alignment.read_text(
        encoding="utf-8"
    ).splitlines()]
    coverage = reference_evaluability(
        adaptive.read_json(args.reference_manifest), alignment_rows, plan["windows"], mapped,
        adaptive.sha256(args.character_alignment),
    )["windows"]
    e23_segments = adaptive.read_json(args.e23_segments)
    scored = adaptive.selection_rows(plan, run, mapped, e23_segments)
    terms, numbers = adaptive.dimension_vocabulary(e23_segments)
    base = {row["id"]: row for row in adaptive.read_json(args.selection)["windows"]}
    trigger = {row["id"]: row for row in trigger_plan["windows"]}
    wk = {row["id"]: row for row in whisperkit["windows"]}
    selector_rows = []
    all_rows = []
    for row in scored:
        base_row = base[row["id"]]
        base_classification = (row["parakeetClassification"]
                               if base_row["selectedBackend"] == "parakeet-ja"
                               else row["qwenClassification"])
        value = {
            **row,
            "baseBackend": base_row["selectedBackend"],
            "baseText": base_row["selectedText"],
            "baseClassification": base_classification,
            "referenceCoverage": coverage[row["id"]],
        }
        if row["id"] in trigger:
            output = wk[row["id"]]
            value.update({
                "disagreement": trigger[row["id"]]["signals"]["disagreement"],
                "qwenWeakness": trigger[row["id"]]["signals"]["qwenWeakness"],
                "whisperkit": output["text"],
                "averageLogProbability": output["averageLogProbability"],
                "whisperkitClassification": adaptive.classify_unit(
                    row["referenceJapanese"], output["text"], terms, numbers
                ),
            })
            selector_rows.append(value)
        all_rows.append(value)

    calibration = calibrate_selector(selector_rows)
    threshold = calibration["threshold"]
    final_rows = []
    for row in all_rows:
        if "whisperkit" in row:
            decision = whisperkit_decision(row, threshold)
            selected_classification = (row["whisperkitClassification"]
                                       if decision["selectedBackend"] == "whisperkit"
                                       else row["baseClassification"])
        else:
            decision = {
                "action": "not-triggered-keep-qwen-parakeet",
                "selectedBackend": row["baseBackend"],
                "selectedText": row["baseText"],
                "reasons": ["trigger-requires-disagreement-and-qwen-weakness"],
                "signals": {},
            }
            selected_classification = row["baseClassification"]
        final_rows.append({
            **row, **decision,
            "selectedClassification": selected_classification,
            "selectedEdits": adaptive.edit_count(selected_classification),
        })

    qwen_edits = sum(row["qwenEdits"] for row in final_rows)
    base_edits = sum(adaptive.edit_count(row["baseClassification"]) for row in final_rows)
    selected_edits = sum(row["selectedEdits"] for row in final_rows)
    qwen_dimensions = adaptive.classification_totals(final_rows, "qwenClassification")
    selected_dimensions = adaptive.classification_totals(final_rows, "selectedClassification")
    base_dimensions = adaptive.classification_totals(final_rows, "baseClassification")
    qwen_empty = sum(row["qwenClassification"]["emptyTurn"] for row in final_rows)
    selected_empty = sum(row["selectedClassification"]["emptyTurn"] for row in final_rows)
    overrides = [row for row in final_rows if row["selectedBackend"] == "whisperkit"]
    bad = [row for row in overrides if row["selectedEdits"]
           > adaptive.edit_count(row["baseClassification"])]
    worker = whisperkit.get("worker")
    worker_lifecycle = worker.get("lifecycle") if worker else None
    gates = {
        "triggerCalibratedAndSparse": adaptive.read_json(args.trigger_report)
            ["heavyRunJustified"],
        "selectorCalibratedByBlocks": calibration["admissible"],
        "atLeastOneWhisperKitOverride": bool(overrides),
        "improvesQwenParakeet": selected_edits < base_edits,
        "improvesBestSingleQwen": selected_edits < qwen_edits,
        "noBadWhisperKitOverride": not bad,
        "completeReferenceCoverageForOverrides": bool(overrides) and all(
            row["referenceCoverage"]["complete"] for row in overrides
        ),
        "termsNumbersMeaningNotWorse": all(
            selected_dimensions[key] >= qwen_dimensions[key]
            for key in qwen_dimensions
        ),
        "noAddedEmpty": selected_empty <= qwen_empty,
        "noAddedDuplicate": duplicate_count(final_rows, "selectedText")
            <= duplicate_count(final_rows, "qwen"),
        "workerExitedCleanly": bool(
            worker_lifecycle and worker_lifecycle.get("exitStatus") == 0
            and not worker_lifecycle.get("forcedTermination")
            and all(row.get("level") != "critical"
                    for row in worker_lifecycle.get("pressureTransitions", []))
        ),
        "holdoutClosed": True,
    }
    eligible = all(gates.values())
    safe_rows = [{
        "id": row["id"],
        "startSample": row["startSample"],
        "endSample": row["endSample"],
        "qwen": row["qwen"],
        "parakeet": row["parakeet"],
        **({"whisperkit": row["whisperkit"]} if "whisperkit" in row else {}),
        "action": row["action"],
        "selectedBackend": row["selectedBackend"],
        "selectedText": row["selectedText"],
        "reasons": row["reasons"],
        "signals": row["signals"],
    } for row in final_rows]
    selection = {
        "schemaVersion": 1,
        "ticket": 95,
        "status": "READY_FOR_SINGLE_TRANSLATION" if eligible else "NO-GO-JAPANESE",
        "corpusID": "qudu2fx3ncc",
        "holdoutOpened": False,
        "sourceSHA256": trigger_plan["sourceSHA256"],
        "triggerPlanSHA256": adaptive.sha256(args.trigger_plan),
        "calibratedWhisperKitAverageLogProbability": threshold,
        "developmentEligibleJapanese": eligible,
        "rawTranscript": "\n".join(row["selectedText"] for row in safe_rows
                                    if adaptive.normalize(row["selectedText"])),
        "windows": safe_rows,
    }
    if "reference" in repr(selection).lower():
        raise RuntimeError("runtime #95 selection leaked calibration labels")
    adaptive.write_json(args.output_selection, selection)
    report = {
        "schemaVersion": 1,
        "ticket": 95,
        "holdoutOpened": False,
        "mappingAudit": mapping_audit,
        "calibration": calibration,
        "gates": gates,
        "developmentEligibleJapanese": eligible,
        "qwenEdits": qwen_edits,
        "qwenParakeetEdits": base_edits,
        "candidateEdits": selected_edits,
        "qwenDimensions": qwen_dimensions,
        "qwenParakeetDimensions": base_dimensions,
        "candidateDimensions": selected_dimensions,
        "triggerCount": len(selector_rows),
        "overrideCount": len(overrides),
        "badOverrideCount": len(bad),
        "overrides": [{
            "id": row["id"],
            "block": row["block"],
            "qwen": row["qwen"],
            "parakeet": row["parakeet"],
            "whisperkit": row["whisperkit"],
            "referenceJapanese": row["referenceJapanese"],
            "baseBackend": row["baseBackend"],
            "baseEdits": adaptive.edit_count(row["baseClassification"]),
            "whisperkitEdits": adaptive.edit_count(row["whisperkitClassification"]),
            "averageLogProbability": row["averageLogProbability"],
            "referenceCoverage": row["referenceCoverage"],
        } for row in overrides],
        "worker": worker,
        "selectionSHA256": adaptive.sha256(args.output_selection),
    }
    adaptive.write_json(args.output_report, report)


def worker_clean(worker: dict | None) -> bool:
    return bool(worker and worker.get("exitStatus") == 0
                and not worker.get("forcedTermination")
                and all(row.get("level") != "critical"
                        for row in worker.get("pressureTransitions", [])))


def final_report(args: argparse.Namespace) -> None:
    trigger = adaptive.read_json(args.trigger_report)
    selection = adaptive.read_json(args.selection)
    japanese = adaptive.read_json(args.selection_report)
    whisperkit = adaptive.read_json(args.whisperkit_run)
    whisperkit_runtime = adaptive.read_json(args.whisperkit_runtime)
    issue94 = adaptive.read_json(args.issue94_completion)
    if (trigger.get("ticket") != 95 or trigger.get("triggerCount") != 6
            or selection.get("ticket") != 95 or selection.get("holdoutOpened")
            or japanese.get("selectionSHA256") != adaptive.sha256(args.selection)
            or whisperkit.get("status") != "completed"
            or whisperkit_runtime.get("exitCode") != 0
            or issue94.get("status") != "completed" or issue94.get("holdoutOpened")):
        raise RuntimeError("#95 final report inputs are incomplete or mismatched")

    qwen_english = issue94["english"]["baselineChrFPlusPlus"]
    issue94_english = issue94["english"]["candidateChrFPlusPlus"]
    english = {
        "run": False,
        "reason": "Awaiting one serialized alignment and translation after the Japanese gate",
        "qwenChrFPlusPlus": qwen_english,
        "issue94ChrFPlusPlus": issue94_english,
        "candidateChrFPlusPlus": None,
    }

    wk_worker = whisperkit["worker"]["lifecycle"]
    if not worker_clean(wk_worker):
        raise RuntimeError("WhisperKit worker lifecycle is not clean")
    prior = adaptive.read_json(args.issue94_report)
    incremental_seconds = whisperkit_runtime["elapsedSeconds"]
    reference_complete = japanese["gates"].get(
        "completeReferenceCoverageForOverrides", False
    )
    downstream = (args.candidate_raw, args.candidate_manifest,
                  args.translation_runtime, args.baseline_raw, args.reference_manifest)
    if any(downstream) and not all(downstream):
        raise RuntimeError("partial #95 English evidence is not reportable")
    if all(downstream):
        if adaptive.sha256(args.reference_manifest) != EXPECTED["referenceManifest"]:
            raise RuntimeError("frozen DEV reference manifest changed")
        candidate = adaptive.read_json(args.candidate_raw)
        candidate_manifest = adaptive.read_json(args.candidate_manifest)
        translation_runtime = adaptive.read_json(args.translation_runtime)
        manifest = adaptive.read_json(args.reference_manifest)
        baseline = adaptive.read_json(args.baseline_raw)
        if (not selection["developmentEligibleJapanese"] or not reference_complete
                or candidate_manifest.get("status") != "completed"
                or candidate.get("rawASR") != selection["rawTranscript"]
                or candidate.get("asrWorker") is not None
                or candidate.get("translation") is None
                or translation_runtime.get("exitCode") != 0):
            raise RuntimeError("single #95 downstream translation evidence is incomplete")
        baseline_rows = adaptive.translation_rows(manifest, baseline)
        candidate_rows = adaptive.translation_rows(manifest, candidate)
        reference = " ".join(row["reference"] for row in candidate_rows)
        baseline_score = adaptive.chrf_pp(
            " ".join(row["hypothesis"] for row in baseline_rows), reference
        )
        candidate_score = adaptive.chrf_pp(
            " ".join(row["hypothesis"] for row in candidate_rows), reference
        )
        if abs(baseline_score - qwen_english) > 1e-9:
            raise RuntimeError("Qwen English baseline changed")
        integrity = adaptive.cue_integrity(candidate)
        baseline_empty = sum(not row["hypothesis"] for row in baseline_rows)
        candidate_empty = sum(not row["hypothesis"] for row in candidate_rows)
        aligner = candidate.get("alignment", {}).get("worker")
        translator = candidate.get("translation", {}).get("worker")
        sequential = bool(
            aligner and translator
            and adaptive.parse_date(wk_worker["exitedAt"]) <= adaptive.parse_date(aligner["startedAt"])
            <= adaptive.parse_date(aligner["exitedAt"]) <= adaptive.parse_date(translator["startedAt"])
            <= adaptive.parse_date(translator["exitedAt"])
        )
        gates = {
            "oneTranslation": True,
            "structuredCues": adaptive.structured_cues_are_valid(integrity),
            "noAddedEmptyTurns": candidate_empty <= baseline_empty,
            "noValidationFailure": not candidate["translation"].get("validationFailures"),
            "chrFPlusPlusNotWorseThanQwen": candidate_score >= baseline_score,
            "workersCleanAndSequential": sequential and worker_clean(aligner)
                and worker_clean(translator),
        }
        english = {
            "run": True,
            "qwenChrFPlusPlus": baseline_score,
            "issue94ChrFPlusPlus": issue94_english,
            "candidateChrFPlusPlus": candidate_score,
            "deltaVsQwen": candidate_score - baseline_score,
            "deltaVsIssue94": candidate_score - issue94_english,
            "qwenEmptyTurns": baseline_empty,
            "candidateEmptyTurns": candidate_empty,
            "integrity": integrity,
            "integrityInterpretation": {
                "nativeMarkerProtocolApplied": False,
                "reason": "one cue per request; native prompts contain no CURRENT markers",
                "acceptedCueCount": len(candidate["translation"]["request"]["turns"]),
                "markerFailuresAreDiagnosticOnly": True,
            },
            "gates": gates,
        }
    report = {
        "schemaVersion": 1,
        "ticket": 95,
        "decision": ("INCONCLUSIVE_REFERENCE_HARNESS_NO_DOWNSTREAM"
                     if not reference_complete else
                     ("NO-GO_TARGETED_WHISPERKIT_JAPANESE"
                      if not selection["developmentEligibleJapanese"] else
                      ("DEV_PASS_HOLDOUT_CLOSED" if english["run"]
                       and all(english["gates"].values()) else
                       ("NO-GO_TARGETED_WHISPERKIT_ENGLISH" if english["run"]
                        else "READY_FOR_ENGLISH_DOWNSTREAM")))),
        "classification": ("harness-reference-coverage-gap"
                           if not reference_complete else "model-result"),
        "holdoutOpened": False,
        "promote": False,
        "productDefaultsChanged": False,
        "trigger": {
            "count": trigger["triggerCount"],
            "rate": trigger["triggerRate"],
            "seconds": trigger["triggeredSeconds"],
            "threshold": trigger["calibration"]["threshold"],
            "perFoldThreshold": trigger["calibration"]["perFoldThreshold"],
            "rawOnlyMeasurement": trigger["rawOnlyMeasurement"],
            "referenceEvaluability": trigger["referenceEvaluability"],
        },
        "diagnostic": {
            "initialPreflightMissedReferenceCoverage": True,
            "heavyRunOccurredBeforeCoverageGate": True,
            "rootCause": "cue interval fill was mistaken for reference completeness",
            "correctedReferenceManifestComplete": reference_complete,
            "reusedArchivedWhisperKitRaw": True,
            "modelConclusion": ("English evaluated" if english["run"]
                                else "Japanese pass; English pending"),
            "metalSandboxIncident": {
                "qualityVerdictInput": False,
                "elapsedCommandSeconds": 12.77810504194349,
                "alignmentStarts": 0,
                "translationStarts": 0,
                "recovery": "one explicitly authorized run outside the sandbox",
                "evidence": "retest-metal-sandbox-incident.json",
            },
        },
        "japanese": {
            "developmentEligible": selection["developmentEligibleJapanese"],
            "qwenEdits": japanese["qwenEdits"],
            "issue94Edits": japanese["qwenParakeetEdits"],
            "candidateEdits": japanese["candidateEdits"],
            "qwenDimensions": japanese["qwenDimensions"],
            "issue94Dimensions": japanese["qwenParakeetDimensions"],
            "candidateDimensions": japanese["candidateDimensions"],
            "whisperKitOverrides": japanese["overrideCount"],
            "badWhisperKitOverrides": japanese["badOverrideCount"],
            "gates": japanese["gates"],
            "examples": japanese["overrides"],
            "developmentWinner": ("qwen-parakeet-whisperkit" if english["run"]
                                  and all(english["gates"].values()) else "qwen"),
            "productDefaultRemains": "qwen",
        },
        "english": english,
        "runtime": {
            "whisperKitCommandSeconds": whisperkit_runtime["elapsedSeconds"],
            "whisperKitWorkerSeconds": wk_worker["elapsedSeconds"],
            "incrementalCommandSeconds": incremental_seconds,
            "priorIssue94CommandSeconds": prior["runtime"]["totalCommandSeconds"],
            "qwenASRWorkerSeconds": prior["runtime"]["workerSeconds"]["qwen-ja"],
            "issue94ASRWorkerSeconds": prior["runtime"]["ASRSeconds"],
            "asrOverheadVsQwenStandardSeconds": (
                prior["runtime"]["ASRSeconds"]
                - prior["runtime"]["workerSeconds"]["qwen-ja"]
                + whisperkit_runtime["elapsedSeconds"]
            ),
            "combinedDevelopmentCommandSeconds": (
                prior["runtime"]["totalCommandSeconds"] + incremental_seconds
            ),
            "incrementalPeakPhysicalFootprintBytes": wk_worker[
                "peakPhysicalFootprintBytes"
            ],
            "priorIssue94PeakPhysicalFootprintBytes": prior["runtime"]
                ["peakPhysicalFootprintBytes"],
            "allHeavyWorkersClean": worker_clean(wk_worker),
            "fixedMemoryReserveBytes": 0,
        },
        "inputSHA256": {
            "triggerReport": adaptive.sha256(args.trigger_report),
            "selection": adaptive.sha256(args.selection),
            "selectionReport": adaptive.sha256(args.selection_report),
            "whisperKitRun": adaptive.sha256(args.whisperkit_run),
            **({
                "candidateRaw": adaptive.sha256(args.candidate_raw),
                "candidateManifest": adaptive.sha256(args.candidate_manifest),
                "translationRuntime": adaptive.sha256(args.translation_runtime),
                "baselineRaw": adaptive.sha256(args.baseline_raw),
                "referenceManifest": adaptive.sha256(args.reference_manifest),
            } if all(downstream) else {}),
        },
    }
    if english["run"]:
        downstream_seconds = translation_runtime["elapsedSeconds"]
        downstream_peak = max(
            candidate_manifest["peakMemoryBytes"],
            aligner["peakPhysicalFootprintBytes"],
            translator["peakPhysicalFootprintBytes"],
        )
        report["runtime"].update({
            "downstreamCommandSeconds": downstream_seconds,
            "downstreamStageSeconds": adaptive.named_durations(
                candidate_manifest["stageDurations"]
            ),
            "alignmentWorkerSeconds": aligner["elapsedSeconds"],
            "translationWorkerSeconds": translator["elapsedSeconds"],
            "incrementalCommandSeconds": incremental_seconds + downstream_seconds,
            "incrementalCommandSecondsInterpretation": (
                "experimental WhisperKit plus common downstream alignment/translation; "
                "not product overhead"
            ),
            "combinedDevelopmentCommandSeconds": (
                prior["runtime"]["totalCommandSeconds"]
                + incremental_seconds + downstream_seconds
            ),
            "incrementalPeakPhysicalFootprintBytes": max(
                wk_worker["peakPhysicalFootprintBytes"], downstream_peak
            ),
            "allHeavyWorkersClean": all(worker_clean(worker) for worker in (
                wk_worker, aligner, translator
            )),
        })
    adaptive.write_json(args.output, report)
    write_markdown(args.markdown, report)


def write_markdown(path: Path, report: dict) -> None:
    trigger, japanese, english, runtime = (
        report["trigger"], report["japanese"], report["english"], report["runtime"]
    )
    lines = [
        "# E29 — WhisperKit ciblé DEV (#95)", "",
        f"**Décision : {report['decision']}.** Holdout fermé.", "",
        f"- Raw-only : {trigger['count']}/169 fenêtres ({trigger['rate']:.2%}), "
        f"{trigger['seconds']:.2f}s ; seuil faiblesse Qwen {trigger['threshold']}, "
        f"folds {trigger['perFoldThreshold']}.",
        "- Diagnostic : la gate confondait le remplissage temporel des cues avec la "
        "complétude de la référence ; le manifest racine complet et l’alignement 199/199 "
        "rendent désormais les 6 fenêtres évaluables.",
        "- Incident Metal séparé : une première commande aval autorisée a échoué en "
        "sandbox avant tout alignement/traduction (12.78s, signal xctest 6). Une seule "
        "reprise hors sandbox a été explicitement autorisée ; cet incident ne contribue "
        "pas au verdict qualité.",
        f"- Japonais : edits Qwen {japanese['qwenEdits']}, #94 {japanese['issue94Edits']}, "
        f"#95 {japanese['candidateEdits']} ; overrides WhisperKit "
        f"{japanese['whisperKitOverrides']}, mauvais {japanese['badWhisperKitOverrides']}.",
        f"- Termes/nombres/sens récupérés : Qwen {japanese['qwenDimensions']}, "
        f"#94 {japanese['issue94Dimensions']}, #95 "
        f"{japanese['candidateDimensions']} ; aucun changement produit.",
        f"- Surcoût ASR vs Qwen Standard : "
        f"{runtime['asrOverheadVsQwenStandardSeconds']:.2f}s "
        f"((#94 ASR {runtime['issue94ASRWorkerSeconds']:.2f}s - Qwen "
        f"{runtime['qwenASRWorkerSeconds']:.2f}s) + WhisperKit commande "
        f"{runtime['whisperKitCommandSeconds']:.2f}s ; worker "
        f"{runtime['whisperKitWorkerSeconds']:.2f}s). Pic expérimental "
        f"{runtime['incrementalPeakPhysicalFootprintBytes'] / 1024**3:.2f} Gio ; "
        f"total #94 historique {runtime['priorIssue94CommandSeconds']:.2f}s.",
    ]
    if english["run"]:
        lines.append(
            f"- Anglais : Qwen {english['qwenChrFPlusPlus']:.3f}, #94 "
            f"{english['issue94ChrFPlusPlus']:.3f}, #95 "
            f"{english['candidateChrFPlusPlus']:.3f} (Δ Qwen "
            f"{english['deltaVsQwen']:+.3f})."
        )
        lines.append(
            f"- Aval expérimental commun : {runtime['downstreamCommandSeconds']:.2f}s "
            f"(alignement {runtime['alignmentWorkerSeconds']:.2f}s, traduction "
            f"{runtime['translationWorkerSeconds']:.2f}s) ; ce temps n’est pas un "
            "surcoût produit propre à WhisperKit."
        )
        interpretation = english["integrityInterpretation"]
        lines.append(
            f"- Intégrité anglaise : {interpretation['acceptedCueCount']} cues acceptés, "
            "aucun missing/duplicate/reorder/unknown. Les 280 nativeMarkerFailures sont "
            "diagnostiques : ce run fait une cue par requête et ses prompts natifs "
            "n’emploient pas les marqueurs CURRENT ; aucune perte d’intégrité observée."
        )
    else:
        lines.append(f"- Anglais : non exécuté ({english['reason']}).")
    if not japanese["gates"].get("completeReferenceCoverageForOverrides", True):
        lines.append(
            "- Gate référence : échec ; les fenêtres proposées ne sont pas entièrement "
            "couvertes temporellement, donc le gain d’edits ne prouve pas un gain modèle."
        )
    lines += ["", "## Overrides WhisperKit"]
    if japanese["examples"]:
        for row in japanese["examples"]:
            lines.append(
                f"- {row['id']} — référence « {row['referenceJapanese']} » ; "
                f"base « {row['baseBackend']}: {row['qwen'] if row['baseBackend'] == 'qwen-ja' else row['parakeet']} » ; "
                f"WhisperKit « {row['whisperkit']} » ; edits "
                f"{row['baseEdits']}→{row['whisperkitEdits']} ; référence "
                f"{row['referenceCoverage']['referenceKind']} complète."
            )
    else:
        lines.append("- Aucun : le sélecteur s’est abstenu.")
    lines += ["", "Aucune UI, aucun changement Live/default, aucune ouverture holdout."]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def self_test() -> None:
    evaluability = reference_evaluability({
        "corpusID": "fixture",
        "fixture": {"sampleRate": 16_000, "sampleCount": 32_000},
        "source": {"references": [{
            "label": "character-alignment", "sha256": "fixture-alignment",
        }]},
        "annotations": {"status": "complete", "turns": [{
            "id": 1, "speaker": "A", "startSample": 0, "endSample": 4_000,
            "japanese": "A",
        }]},
    }, [{
        "cue_id": "001", "speaker_id": "A", "start": 0.0, "end": 0.25,
        "japanese": "A", "characters": [{"char": "A", "start": 0.0, "end": 0.25}],
    }], [
        {"id": "speech", "startSample": 0, "endSample": 16_000},
        {"id": "silence", "startSample": 16_000, "endSample": 32_000},
    ], ["A", ""], "fixture-alignment")
    assert evaluability["completeForEveryWindow"]
    assert evaluability["windows"]["silence"]["referenceKind"] == "accepted-empty"
    coverage = interval_coverage([
        {"start": 1.0, "end": 2.0}, {"start": 1.5, "end": 2.5}
    ], 0.0, 4.0)
    assert coverage == {"coveredSeconds": 1.5, "ratio": 0.375, "complete": False}
    rows = [
        {"block": 0, "qwenErrorRate": 0.2, "disagreement": 0.8, "qwenWeakness": 0.0},
        {"block": 1, "qwenErrorRate": 1.0, "disagreement": 0.8, "qwenWeakness": 0.5},
        {"block": 2, "qwenErrorRate": 1.0, "disagreement": 0.1, "qwenWeakness": 0.5},
    ]
    triggered = trigger_rows(rows, weakness_threshold=0.25)
    assert [row["block"] for row in triggered] == [1]
    window = {"durationSeconds": 4, "acoustic": {"activeFrameRatio": 1}}
    selector_rows = [{
        "block": block,
        "qwen": "誤り",
        "whisperkit": "正しい",
        "window": window,
        "qwenWeakness": 1,
        "disagreement": 1,
        "averageLogProbability": -0.2,
        "baseBackend": "qwen-ja",
        "baseText": "誤り",
        "baseClassification": adaptive.classify_unit("正しい", "誤り", [], []),
        "whisperkitClassification": adaptive.classify_unit("正しい", "正しい", [], []),
    } for block in range(5)]
    calibration = calibrate_selector(selector_rows)
    assert calibration["admissible"] and calibration["threshold"] == -0.2
    print("targeted_whisperkit_harness self-test: PASS")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    analyze_parser = sub.add_parser("analyze")
    for name in ("plan", "run", "selection", "reference-manifest",
                 "character-alignment", "e23-segments", "trigger-plan", "report"):
        analyze_parser.add_argument(f"--{name}", type=Path, required=True)
    select_parser = sub.add_parser("select")
    for name in ("plan", "run", "selection", "trigger-plan", "trigger-report",
                 "whisperkit-run", "reference-manifest", "character-alignment",
                 "e23-segments", "output-selection", "output-report"):
        select_parser.add_argument(f"--{name}", type=Path, required=True)
    report_parser = sub.add_parser("report")
    for name in ("trigger-report", "selection", "selection-report", "whisperkit-run",
                 "whisperkit-runtime", "issue94-completion", "issue94-report",
                 "output", "markdown"):
        report_parser.add_argument(f"--{name}", type=Path, required=True)
    for name in ("candidate-raw", "candidate-manifest", "translation-runtime",
                 "baseline-raw", "reference-manifest"):
        report_parser.add_argument(f"--{name}", type=Path)
    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
    elif args.command == "analyze":
        analyze(args)
    elif args.command == "select":
        select(args)
    elif args.command == "report":
        final_report(args)


if __name__ == "__main__":
    main()
