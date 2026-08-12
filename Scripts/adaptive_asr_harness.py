#!/usr/bin/env python3
"""Issue #94 DEV-only adaptive Qwen/Parakeet experiment."""

from __future__ import annotations

import math
import difflib
import re
import argparse
import gzip
import hashlib
import inspect
import json
import statistics
from collections import Counter
from datetime import datetime
from pathlib import Path

from report_combined_offline_validation import representative_examples
from report_high_quality_acceptance import cue_integrity, structured_cues_are_valid, translation_rows
from report_japanese_l7d import chrf_pp
from report_qwen_error_diagnostic import classify_unit, normalize, read_audio


SAMPLE_RATE = 16_000
FRAME_SAMPLES = SAMPLE_RATE // 50
MINIMUM_SAMPLES = 3 * SAMPLE_RATE
MAXIMUM_SAMPLES = 8 * SAMPLE_RATE
THRESHOLDS = (0.0, 0.25, 0.5, 1.0)
EXPECTED = {
    "source": "b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1",
    "audio": "494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2",
    "qwenRaw": "b7281fdd3226930a4dc59758eb5e192642747ad6f9d18d942b850288ad42a394",
    "qwenManifest": "3f31b861f8a59ab5fbed35561d58c8921ce2d4c7a46f5a222a6ad4548109275a",
    "parakeetRaw": "2ab8678481b4ad22a08c015a2332c25e85309e0e327158e127a3bd3351611c6d",
    "parakeetManifest": "13d517d82f1fe704196bce102817282e0a929ec5b7c0eb93e635774c8232d7fa",
    "baselineRaw": "1f5edc2fcb929c9abc2cb85256f326bbf2891a200ef66d1c1cb9a66a9c711ce8",
    "characterAlignment": "abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7",
    "e23Segments": "e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                         encoding="utf-8")
    temporary.replace(path)


def dbfs(samples: list[int]) -> float:
    square_sum = sum(value * value for value in samples)
    return (-120.0 if not square_sum else
            20 * math.log10(math.sqrt(square_sum / len(samples)) / 32768))


def build_acoustic_plan(samples: list[int], audio_sha256: str) -> dict:
    windows = []
    start = 0
    while start < len(samples):
        remaining = len(samples) - start
        if remaining <= MAXIMUM_SAMPLES:
            end = len(samples)
        else:
            latest = min(start + MAXIMUM_SAMPLES, len(samples) - MINIMUM_SAMPLES)
            candidates = range(start + MINIMUM_SAMPLES, latest + 1, FRAME_SAMPLES)
            end = min(candidates, key=lambda index: (
                sum(value * value for value in samples[index - FRAME_SAMPLES:index]),
                -index,
            ))
        values = samples[start:end]
        frames = [values[index:index + FRAME_SAMPLES]
                  for index in range(0, len(values), FRAME_SAMPLES)]
        windows.append({
            "id": f"segment-{len(windows) + 1:04d}",
            "startSample": start,
            "endSample": end,
            "durationSeconds": (end - start) / SAMPLE_RATE,
            "acoustic": {
                "rmsDBFS": dbfs(values),
                "activeFrameRatio": sum(dbfs(frame) >= -42 for frame in frames) / len(frames),
            },
        })
        start = end
    if (not windows or windows[0]["startSample"] != 0
            or windows[-1]["endSample"] != len(samples)
            or any(left["endSample"] != right["startSample"]
                   for left, right in zip(windows, windows[1:]))
            or any(row["endSample"] - row["startSample"] > MAXIMUM_SAMPLES
                   for row in windows)):
        raise RuntimeError("acoustic segmentation failed timeline invariants")
    return {
        "schemaVersion": 1,
        "ticket": 94,
        "corpusID": "qudu2fx3ncc",
        "corpusRole": "development",
        "holdoutOpened": False,
        "audioSHA256": audio_sha256,
        "sampleRate": SAMPLE_RATE,
        "sampleCount": len(samples),
        "algorithm": {
            "frameMilliseconds": 20,
            "minimumSeconds": 3,
            "maximumSeconds": 8,
            "boundary": "lowest-energy-frame-latest-tie",
            "activeFrameDBFS": -42,
        },
        "windows": windows,
    }


def repetition_ratio(text: str) -> float:
    characters = normalize(text)
    grams = [characters[index:index + 3] for index in range(max(0, len(characters) - 2))]
    return 0.0 if not grams else 1 - len(set(grams)) / len(grams)


def weakness(text: str, window: dict) -> float:
    normalized = normalize(text)
    duration = window["durationSeconds"]
    rate = len(normalized) / duration
    active = window["acoustic"]["activeFrameRatio"]
    return (4.0 * (not normalized and active >= 0.2)
            + max(0.0, 1.0 - rate)
            + max(0.0, rate - 12.0) / 6.0
            + 4.0 * max(0.0, repetition_ratio(text) - 0.25))


def runtime_decision(qwen: str, parakeet: str, window: dict, threshold: float) -> dict:
    qwen_normalized, parakeet_normalized = normalize(qwen), normalize(parakeet)
    disagreement = 1 - difflib.SequenceMatcher(
        None, qwen_normalized, parakeet_normalized, autojunk=False
    ).ratio()
    qwen_weakness, parakeet_weakness = weakness(qwen, window), weakness(parakeet, window)
    margin = qwen_weakness - parakeet_weakness
    critical = list(dict.fromkeys(
        token.casefold() for token in re.findall(r"[0-9０-９]+|[A-Za-z][A-Za-z0-9!_-]*", qwen)
    ))
    lost = [token for token in critical if normalize(token) not in parakeet_normalized]
    reasons = []
    if not parakeet_normalized:
        reasons.append("parakeet-empty")
    if disagreement < 0.15:
        reasons.append("insufficient-disagreement")
    if lost:
        reasons.append("qwen-critical-token-lost")
    choose = bool(parakeet_normalized and disagreement >= 0.15 and not lost
                  and margin > threshold)
    if choose:
        reasons.append("calibrated-margin-passed")
    elif not reasons:
        reasons.append("insufficient-calibrated-margin")
    return {
        "action": "select-parakeet" if choose else "abstain-qwen",
        "selectedBackend": "parakeet-ja" if choose else "qwen-ja",
        "selectedText": parakeet if choose else qwen,
        "reasons": reasons,
        "signals": {
            "disagreement": disagreement,
            "qwenWeakness": qwen_weakness,
            "parakeetWeakness": parakeet_weakness,
            "weaknessMargin": margin,
            "qwenCriticalTokens": critical,
            "qwenCriticalTokensLostByParakeet": lost,
        },
    }


def threshold_score(rows: list[dict], threshold: float) -> tuple[int, int]:
    gain = replacements = 0
    for row in rows:
        decision = runtime_decision(row["qwen"], row["parakeet"], row["window"], threshold)
        if decision["selectedBackend"] == "parakeet-ja":
            gain += row["qwenEdits"] - row["parakeetEdits"]
            replacements += 1
    return gain, replacements


def override_summary(rows: list[dict], threshold: float | None) -> dict:
    decisions = [] if threshold is None else [
        (row, runtime_decision(row["qwen"], row["parakeet"], row["window"], threshold))
        for row in rows
    ]
    replacements = [(row, decision) for row, decision in decisions
                    if decision["selectedBackend"] == "parakeet-ja"]
    gains = [row["qwenEdits"] - row["parakeetEdits"] for row, _ in replacements]
    reasons = Counter(reason for _, decision in decisions for reason in decision["reasons"])
    critical = {}
    for dimension in ("terms", "numbers", "meaning"):
        recovered, lost = [], []
        for row, _ in replacements:
            if "qwenClassification" not in row:
                continue
            qwen = set(row["qwenClassification"][dimension]["recovered"])
            parakeet = set(row["parakeetClassification"][dimension]["recovered"])
            recovered += sorted(parakeet - qwen)
            lost += sorted(qwen - parakeet)
        critical[dimension] = {
            "recovered": list(dict.fromkeys(recovered)),
            "lost": list(dict.fromkeys(lost)),
        }
    net_gain = sum(gains)
    return {
        "threshold": threshold,
        "rule": ("fallback Qwen: no positive DEV training gain" if threshold is None else
                 f"select complete Parakeet hypothesis when deterministic vetoes pass "
                 f"and weaknessMargin > {threshold}"),
        "proposedOverrides": len(replacements),
        "goodOverrides": sum(gain > 0 for gain in gains),
        "badOverrides": sum(gain < 0 for gain in gains),
        "neutralOverrides": sum(gain == 0 for gain in gains),
        "qwenEdits": sum(row["qwenEdits"] for row in rows),
        "adaptiveEdits": sum(row["qwenEdits"] for row in rows) - net_gain,
        "netEditGain": net_gain,
        "criticalChanges": critical,
        "reasonHistogram": dict(sorted(reasons.items())),
    }


def best_threshold(rows: list[dict]) -> float | None:
    scored = [(threshold_score(rows, threshold), threshold) for threshold in THRESHOLDS]
    (gain, _), threshold = max(scored, key=lambda item: (
        item[0][0], -item[0][1], item[1]
    ))
    return threshold if gain > 0 else None


def calibrate(rows: list[dict]) -> dict:
    blocks = sorted({row["block"] for row in rows})
    if len(blocks) < 3:
        raise RuntimeError("calibration requires at least three contiguous blocks")
    fold_thresholds = []
    folds = []
    heldout = []
    for block in blocks:
        training = [row for row in rows if row["block"] != block]
        threshold = best_threshold(training)
        fold_thresholds.append(threshold)
        training_replacements = [] if threshold is None else [
            row for row in training
            if runtime_decision(row["qwen"], row["parakeet"], row["window"], threshold)
            ["selectedBackend"] == "parakeet-ja"
        ]
        predicted_win = ((1 + sum(row["parakeetEdits"] < row["qwenEdits"]
                                  for row in training_replacements))
                         / (2 + len(training_replacements)))
        heldout_rows = [item for item in rows if item["block"] == block]
        fold_heldout = []
        for row in heldout_rows:
            decision = (runtime_decision(row["qwen"], row["parakeet"], row["window"], threshold)
                        if threshold is not None else {
                            "action": "abstain-qwen", "selectedBackend": "qwen-ja",
                            "selectedText": row["qwen"], "reasons": ["calibration-no-gain"],
                        })
            result = {**row, **decision,
                      "predictedParakeetWinProbability": predicted_win}
            heldout.append(result)
            fold_heldout.append(result)
        folds.append({
            "heldoutBlock": block,
            "trainingBlocks": [item for item in blocks if item != block],
            "thresholdCandidates": [override_summary(training, value)
                                    for value in THRESHOLDS],
            "learned": override_summary(training, threshold),
            "heldout": override_summary(heldout_rows, threshold),
        })
    numeric_thresholds = [value for value in fold_thresholds if value is not None]
    exact_agreement = (fold_thresholds[0] is not None and len(set(fold_thresholds)) == 1)
    fixed_rule_folds = [override_summary(
        [row for row in rows if row["block"] == block], 0.5
    ) for block in blocks]
    fixed_rule = override_summary(rows, 0.5)
    critical_losses = [value for dimension in fixed_rule["criticalChanges"].values()
                       for value in dimension["lost"]]
    material_threshold_variation = len(set(numeric_thresholds)) > 1
    fixed_rule_admissible = (
        not material_threshold_variation
        and numeric_thresholds.count(0.5) >= 4
        and fixed_rule["netEditGain"] > 0
        and fixed_rule["goodOverrides"] > fixed_rule["badOverrides"]
        and fixed_rule["badOverrides"] == 0
        and min(fold["netEditGain"] for fold in fixed_rule_folds) >= 0
        and not critical_losses
    )
    admissible = exact_agreement or fixed_rule_admissible
    threshold = fold_thresholds[0] if exact_agreement else (0.5 if admissible else None)
    decisions = []
    for row in rows:
        decision = (runtime_decision(row["qwen"], row["parakeet"], row["window"], threshold)
                    if threshold is not None else {
                        "action": "abstain-qwen", "selectedBackend": "qwen-ja",
                        "selectedText": row["qwen"], "reasons": ["calibration-unstable"],
                    })
        decisions.append({**row, **decision})
    return {
        "blocks": len(blocks),
        "perFoldThreshold": fold_thresholds,
        "stable": exact_agreement,
        "admissible": admissible,
        "thresholdStatus": ("exact-fold-agreement" if exact_agreement else
                            "four-identical-thresholds-one-no-gain" if admissible else
                            "materially-unstable"),
        "materialThresholdVariation": material_threshold_variation,
        "threshold": threshold,
        "folds": folds,
        "fixedRuleCrossValidation": {
            "threshold": 0.5,
            "aggregate": fixed_rule,
            "folds": [{"block": block, **summary}
                      for block, summary in zip(blocks, fixed_rule_folds)],
            "worstBlockNetEditGain": min(
                fold["netEditGain"] for fold in fixed_rule_folds
            ),
            "criticalLosses": critical_losses,
        },
        "variance": {
            "noGainFoldCount": sum(value is None for value in fold_thresholds),
            "numericThresholdMean": (statistics.mean(
                value for value in fold_thresholds if value is not None
            ) if any(value is not None for value in fold_thresholds) else None),
            "numericThresholdPopulationVariance": (statistics.pvariance(
                value for value in fold_thresholds if value is not None
            ) if sum(value is not None for value in fold_thresholds) > 1 else 0),
            "heldoutNetEditGainMean": statistics.mean(
                fold["heldout"]["netEditGain"] for fold in folds
            ),
            "heldoutNetEditGainPopulationVariance": statistics.pvariance(
                fold["heldout"]["netEditGain"] for fold in folds
            ),
        },
        "heldoutDecisions": heldout,
        "decisions": decisions,
    }


def timing_diagnostic(raw: dict) -> dict:
    chunks = raw.get("alignment", {}).get("chunks", [])
    items = [item for chunk in chunks for item in chunk.get("rawItems", [])]
    durations = [chunk["sourceEnd"] - chunk["sourceStart"] for chunk in chunks]
    zero = sum(item["end"] <= item["start"] for item in items)
    regressing = sum(left["start"] > right["start"] for left, right in zip(items, items[1:]))
    return {
        "chunkCount": len(chunks),
        "minimumChunkSeconds": min(durations) if durations else None,
        "maximumChunkSeconds": max(durations) if durations else None,
        "rawItemCount": len(items),
        "zeroDurationRawItemCount": zero,
        "zeroDurationRawItemPercent": 100 * zero / len(items) if items else None,
        "regressingRawItemCount": regressing,
        "shortDecisionWindows": bool(durations and max(durations) <= 8),
        "stableCharacterMapping": bool(items and zero / len(items) < 0.08 and not regressing),
    }


def diagnose_reuse(args: argparse.Namespace) -> dict:
    paths = {
        "qwenRaw": args.qwen_raw,
        "qwenManifest": args.qwen_manifest,
        "parakeetRaw": args.parakeet_raw,
        "parakeetManifest": args.parakeet_manifest,
    }
    observed = {name: sha256(path) for name, path in paths.items()}
    if any(observed[name] != EXPECTED[name] for name in paths):
        raise RuntimeError(f"reusable artifact hash mismatch: {observed}")
    qwen, parakeet = read_json(args.qwen_raw), read_json(args.parakeet_raw)
    qwen_timing, parakeet_timing = timing_diagnostic(qwen), timing_diagnostic(parakeet)
    result = {
        "schemaVersion": 1,
        "ticket": 94,
        "sourceSHA256": EXPECTED["source"],
        "artifacts": {
            name: {"path": str(path), "sha256": observed[name], "bytes": path.stat().st_size}
            for name, path in paths.items()
        },
        "qwen": {"model": qwen["model"], "timing": qwen_timing,
                 "transcribingSeconds": dict(zip(qwen["stageDurations"][::2],
                                                   qwen["stageDurations"][1::2]))["transcribing"]},
        "parakeet": {"model": parakeet["model"], "timing": parakeet_timing,
                      "transcribingSeconds": dict(zip(parakeet["stageDurations"][::2],
                                                        parakeet["stageDurations"][1::2]))["transcribing"]},
        "decisionReusable": False,
        "reusedFor": ["pinned input/model provenance", "baseline quality", "cost budget"],
        "mustRecalculate": [
            "Qwen hypotheses on common acoustic windows <=8s",
            "Parakeet hypotheses on the same common acoustic windows <=8s",
        ],
        "reasons": [
            "archived ASR chunks are 58-65s, not short decision windows",
            "archived Parakeet character timing is not stable enough to remap text",
        ],
        "holdoutOpened": False,
    }
    if qwen_timing["shortDecisionWindows"] or parakeet_timing["shortDecisionWindows"]:
        raise RuntimeError("archived artifact diagnosis unexpectedly changed")
    write_json(args.output, result)
    return result


def parse_date(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate_run(plan: dict, run: dict, plan_path: Path) -> None:
    expected_windows = plan["windows"]
    observed_windows = run.get("windows", [])
    workers = run.get("workers", [])
    if (run.get("ticket") != 94 or run.get("status") != "completed"
            or run.get("sourceSHA256") != EXPECTED["audio"]
            or run.get("planSHA256") != sha256(plan_path)
            or len(observed_windows) != len(expected_windows)
            or [row["id"] for row in observed_windows]
                != [row["id"] for row in expected_windows]
            or any((observed["startSample"], observed["endSample"])
                   != (expected["startSample"], expected["endSample"])
                   for observed, expected in zip(observed_windows, expected_windows))
            or any(not isinstance(row.get("qwen"), str)
                   or not isinstance(row.get("parakeet"), str) for row in observed_windows)
            or [worker.get("backend") for worker in workers] != ["qwen-ja", "parakeet-ja"]):
        raise RuntimeError("runner output is incomplete or differs from the acoustic plan")
    for worker in workers:
        lifecycle = worker.get("lifecycle", {})
        model = worker.get("model", {})
        if (lifecycle.get("exitStatus") != 0 or lifecycle.get("forcedTermination")
                or lifecycle.get("peakPhysicalFootprintBytes", 0) <= 0
                or not lifecycle.get("availableMemorySamples")
                or not model.get("weightSHA256")):
            raise RuntimeError(f"worker lifecycle/provenance is incomplete: {worker.get('backend')}")
    if (not run.get("strictlySequential")
            or parse_date(workers[0]["lifecycle"]["exitedAt"])
                > parse_date(workers[1]["lifecycle"]["startedAt"])):
        raise RuntimeError("Qwen and Parakeet lifecycle overlapped")


def map_reference_rows(rows: list[dict], windows: list[dict]) -> tuple[list[str], dict]:
    fragments = [[] for _ in windows]
    unassigned = []
    cue_conservation = []
    for row in (item for item in rows if item["speaker_id"] != "SPEAKER_NONE"):
        by_window = [[] for _ in windows]
        index = 0
        for character in row["characters"]:
            midpoint = (character["start"] + character["end"]) / 2 * SAMPLE_RATE
            while index + 1 < len(windows) and midpoint >= windows[index]["endSample"]:
                index += 1
            if windows[index]["startSample"] <= midpoint < windows[index]["endSample"]:
                by_window[index].append(character["char"])
            else:
                unassigned.append({"cueID": row["cue_id"], **character})
        reconstructed = "".join(character for window in by_window for character in window)
        cue_conservation.append(reconstructed == row["japanese"])
        for index, fragment in enumerate(by_window):
            if fragment:
                # Cue order is stable inside a window; overlapping speakers are never interleaved.
                fragments[index].append("".join(fragment))
    if unassigned or not all(cue_conservation):
        raise RuntimeError("reference mapping failed cue conservation")
    reference_text = "".join(row["japanese"] for row in rows
                             if row["speaker_id"] != "SPEAKER_NONE")
    return ["".join(window) for window in fragments], {
        "method": "character-midpoint-to-acoustic-window; stable-cue-order-within-window",
        "characterAlignmentSHA256": EXPECTED["characterAlignment"],
        "cueCount": len(cue_conservation),
        "characterCount": len(reference_text),
        "assignedCharacterCount": len(reference_text),
        "unassignedCharacterCount": 0,
        "everyCueTextConserved": all(cue_conservation),
        "overlappingCuesInterleaved": False,
    }


def reference_text_by_window(path: Path, windows: list[dict]) -> tuple[list[str], dict]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    return map_reference_rows(rows, windows)


def dimension_vocabulary(e23: dict) -> tuple[list[str], list[str]]:
    terms, meanings = [], []
    for unit in e23["units"]:
        classification = unit["classification"]
        terms += classification["terms"]["recovered"] + classification["terms"]["lost"]
        meanings += classification["meaning"]["recovered"] + classification["meaning"]["lost"]
    return list(dict.fromkeys(terms)), list(dict.fromkeys(meanings))


def edit_count(classification: dict) -> int:
    speech = classification["speech"]
    return speech["lostCharacters"] + speech["insertedOrSubstitutedCharacters"]


def selection_rows(plan: dict, run: dict, references: list[str], e23: dict) -> list[dict]:
    terms, meanings = dimension_vocabulary(e23)
    rows = []
    count = len(plan["windows"])
    for index, (window, output, reference) in enumerate(zip(
        plan["windows"], run["windows"], references
    )):
        qwen_score = classify_unit(reference, output["qwen"], terms, meanings)
        parakeet_score = classify_unit(reference, output["parakeet"], terms, meanings)
        rows.append({
            "id": window["id"],
            "block": min(4, index * 5 // count),
            "startSample": window["startSample"],
            "endSample": window["endSample"],
            "window": window,
            "qwen": output["qwen"],
            "parakeet": output["parakeet"],
            "referenceJapanese": reference,
            "qwenClassification": qwen_score,
            "parakeetClassification": parakeet_score,
            "qwenEdits": edit_count(qwen_score),
            "parakeetEdits": edit_count(parakeet_score),
        })
    return rows


def classification_totals(rows: list[dict], key: str) -> dict:
    return {
        dimension: sum(len(row[key][dimension]["recovered"]) for row in rows)
        for dimension in ("terms", "numbers", "meaning")
    }


def dimension_changes(rows: list[dict]) -> dict:
    result = {}
    for dimension in ("terms", "numbers", "meaning"):
        recovered, lost = [], []
        for row in rows:
            qwen = set(row["qwenClassification"][dimension]["recovered"])
            parakeet = set(row["parakeetClassification"][dimension]["recovered"])
            recovered += sorted(parakeet - qwen)
            lost += sorted(qwen - parakeet)
        result[dimension] = {
            "recoveredByParakeetNotQwen": list(dict.fromkeys(recovered)),
            "lostByParakeetVsQwen": list(dict.fromkeys(lost)),
        }
    return result


def calibration_metrics(calibration: dict) -> dict:
    replacements = [row for row in calibration["heldoutDecisions"]
                    if row["selectedBackend"] == "parakeet-ja"]
    if not replacements:
        return {"replacementCount": 0, "brier": None, "ECE": None}
    outcomes = [row["parakeetEdits"] < row["qwenEdits"] for row in replacements]
    probabilities = [row["predictedParakeetWinProbability"] for row in replacements]
    probability = sum(probabilities) / len(probabilities)
    observed = sum(outcomes) / len(outcomes)
    # ponytail: one-bin ECE is enough for this tiny DEV selector; add bins with more data.
    return {
        "replacementCount": len(replacements),
        "predictedWinProbability": probability,
        "observedWinRate": observed,
        "brier": sum((prediction - outcome) ** 2
                     for prediction, outcome in zip(probabilities, outcomes)) / len(outcomes),
        "ECE": abs(probability - observed),
    }


def build_selection(args: argparse.Namespace) -> tuple[dict, dict]:
    if (sha256(args.character_alignment) != EXPECTED["characterAlignment"]
            or sha256(args.e23_segments) != EXPECTED["e23Segments"]):
        raise RuntimeError("DEV calibration inputs changed")
    plan, run, e23 = read_json(args.plan), read_json(args.run), read_json(args.e23_segments)
    if (plan.get("ticket") != 94 or plan.get("holdoutOpened")
            or plan.get("audioSHA256") != EXPECTED["audio"]
            or max(row["durationSeconds"] for row in plan["windows"]) > 8
            or "reference" in repr(plan).lower()):
        raise RuntimeError("decision plan is not short, acoustic-only DEV evidence")
    validate_run(plan, run, args.plan)
    references, mapping_audit = reference_text_by_window(
        args.character_alignment, plan["windows"]
    )
    rows = selection_rows(plan, run, references, e23)
    calibration = calibrate(rows)
    final_rows = []
    for row, decision in zip(rows, calibration["decisions"]):
        selected_classification = (row["parakeetClassification"]
                                   if decision["selectedBackend"] == "parakeet-ja"
                                   else row["qwenClassification"])
        final_rows.append({**row, **decision,
                           "selectedClassification": selected_classification,
                           "selectedEdits": edit_count(selected_classification)})
    qwen_edits = sum(row["qwenEdits"] for row in final_rows)
    parakeet_edits = sum(row["parakeetEdits"] for row in final_rows)
    oracle_edits = sum(min(row["qwenEdits"], row["parakeetEdits"])
                       for row in final_rows)
    selected_edits = sum(row["selectedEdits"] for row in final_rows)
    gain = qwen_edits - selected_edits
    qwen_dimensions = classification_totals(final_rows, "qwenClassification")
    parakeet_dimensions = classification_totals(final_rows, "parakeetClassification")
    selected_dimensions = classification_totals(final_rows, "selectedClassification")
    qwen_empty = sum(row["qwenClassification"]["emptyTurn"] for row in final_rows)
    parakeet_empty = sum(row["parakeetClassification"]["emptyTurn"] for row in final_rows)
    selected_empty = sum(row["selectedClassification"]["emptyTurn"] for row in final_rows)
    qwen_duplicates = sum(normalize(left["qwen"]) == normalize(right["qwen"])
                          and bool(normalize(left["qwen"]))
                          for left, right in zip(final_rows, final_rows[1:]))
    selected_duplicates = sum(normalize(left["selectedText"]) == normalize(right["selectedText"])
                              and bool(normalize(left["selectedText"]))
                              for left, right in zip(final_rows, final_rows[1:]))
    blocks = [{
        "block": block,
        "qwenEdits": sum(row["qwenEdits"] for row in final_rows if row["block"] == block),
        "parakeetEdits": sum(row["parakeetEdits"] for row in final_rows
                              if row["block"] == block),
        "oracleEdits": sum(min(row["qwenEdits"], row["parakeetEdits"])
                           for row in final_rows if row["block"] == block),
        "selectedEdits": sum(row["selectedEdits"] for row in final_rows
                             if row["block"] == block),
    } for block in range(5)]
    worker_seconds = {worker["backend"]: worker["lifecycle"]["elapsedSeconds"]
                      for worker in run["workers"]}
    worker_memory = {worker["backend"]: {
        "peakPhysicalFootprintBytes": worker["lifecycle"]["peakPhysicalFootprintBytes"],
        "minimumAvailableMemoryBytes": min(
            sample["availableMemoryBytes"]
            for sample in worker["lifecycle"]["availableMemorySamples"]
        ),
    } for worker in run["workers"]}
    relative_gain = 100 * gain / qwen_edits if qwen_edits else 0.0
    gates = {
        "shortCommonAcousticWindows": max(row["window"]["durationSeconds"]
                                           for row in final_rows) <= 8,
        "timelineCompleteWithoutGapOrDuplication": all(
            left["endSample"] == right["startSample"]
            for left, right in zip(final_rows, final_rows[1:])),
        "strictlySequentialWorkers": run["strictlySequential"],
        "calibrationAdmissible": calibration["admissible"],
        "noMaterialThresholdVariation": not calibration["materialThresholdVariation"],
        "fixedRuleWorstBlockNonRegressing": calibration["fixedRuleCrossValidation"]
            ["worstBlockNetEditGain"] >= 0,
        "runtimeSignalsPredictSafeGain": (
            calibration["fixedRuleCrossValidation"]["aggregate"]["netEditGain"] > 0
            and calibration["fixedRuleCrossValidation"]["aggregate"]["goodOverrides"]
                > calibration["fixedRuleCrossValidation"]["aggregate"]["badOverrides"]
            and not calibration["fixedRuleCrossValidation"]["criticalLosses"]
        ),
        "completeHypothesesOnly": all(row["selectedText"] in (row["qwen"], row["parakeet"])
                                      for row in final_rows),
        "everyChoiceLogged": all(row["reasons"] for row in final_rows),
        "noAddedEmptySpeech": selected_empty <= qwen_empty,
        "noAddedDuplicate": selected_duplicates <= qwen_duplicates,
        "termsNumbersMeaningNotWorse": all(
            selected_dimensions[key] >= qwen_dimensions[key]
            for key in qwen_dimensions),
        "costNotRunaway": sum(worker_seconds.values()) <= 5 * worker_seconds["qwen-ja"],
        "holdoutClosed": True,
    }
    eligible = all(gates.values())
    safe_rows = [{
        "id": row["id"],
        "startSample": row["startSample"],
        "endSample": row["endSample"],
        "qwen": row["qwen"],
        "parakeet": row["parakeet"],
        "action": row["action"],
        "selectedBackend": row["selectedBackend"],
        "selectedText": row["selectedText"],
        "reasons": row["reasons"],
        "signals": row.get("signals", {}),
    } for row in final_rows]
    selection = {
        "schemaVersion": 1,
        "ticket": 94,
        "status": "READY_FOR_SINGLE_TRANSLATION" if eligible else "NO-GO-JAPANESE",
        "corpusID": "qudu2fx3ncc",
        "holdoutOpened": False,
        "sourceSHA256": EXPECTED["audio"],
        "planSHA256": sha256(args.plan),
        "calibratedWeaknessMargin": calibration["threshold"],
        "developmentEligibleJapanese": eligible,
        "rawTranscript": "\n".join(row["selectedText"] for row in safe_rows
                                    if normalize(row["selectedText"])),
        "windows": safe_rows,
    }
    if "reference" in repr(selection).lower():
        raise RuntimeError("runtime selection leaked calibration labels")
    changes = sorted(final_rows, key=lambda row: row["qwenEdits"] - row["parakeetEdits"])
    abstention_reasons = dict(sorted(Counter(
        reason for row in final_rows if row["selectedBackend"] == "qwen-ja"
        for reason in row["reasons"]
    ).items()))
    abstention_combinations = dict(sorted(Counter(
        "+".join(sorted(row["reasons"]))
        for row in final_rows if row["selectedBackend"] == "qwen-ja"
    ).items()))
    choice_reasons = dict(sorted(Counter(
        reason for row in final_rows if row["selectedBackend"] == "parakeet-ja"
        for reason in row["reasons"]
    ).items()))
    numeric_thresholds = [value for value in calibration["perFoldThreshold"]
                          if value is not None]
    modal_threshold = Counter(numeric_thresholds).most_common(1)[0][0] \
        if numeric_thresholds else None
    replay = calibrate(rows)
    report = {
        "schemaVersion": 1,
        "ticket": 94,
        "decision": "development-ja-pass" if eligible else "NO-GO-stop-before-translation",
        "holdoutOpened": False,
        "developmentEligibleJapanese": eligible,
        "selectionSHA256": None,
        "calibration": {
            "kind": "leave-one-contiguous-block-out",
            "blocks": calibration["blocks"],
            "perFoldThreshold": calibration["perFoldThreshold"],
            "folds": calibration["folds"],
            "variance": calibration["variance"],
            "stable": calibration["stable"],
            "admissible": calibration["admissible"],
            "thresholdStatus": calibration["thresholdStatus"],
            "materialThresholdVariation": calibration["materialThresholdVariation"],
            "threshold": calibration["threshold"],
            "fixedRuleCrossValidation": calibration["fixedRuleCrossValidation"],
            "metrics": calibration_metrics(calibration),
            "audit": {
                "fiveContiguousBlocksCoverAllWindows": all(
                    [row["block"] for row in rows].count(block) for block in range(5)
                ),
                "leaveOneBlockOutTrainingDisjoint": all(
                    fold["heldoutBlock"] not in fold["trainingBlocks"]
                    for fold in calibration["folds"]
                ),
                "deterministicReplay": replay["perFoldThreshold"]
                    == calibration["perFoldThreshold"],
            },
        },
        "referenceMappingAudit": mapping_audit,
        "calibrationDecisionAttribution": {
            "referenceHashMismatch": False,
            "mappingFailure": False,
            "calibrationReplayMismatch": False,
            "cause": calibration["thresholdStatus"],
        },
        "japanese": {
            "windowCount": len(final_rows),
            "maximumWindowSeconds": max(row["window"]["durationSeconds"] for row in final_rows),
            "qwenEdits": qwen_edits,
            "parakeetEdits": parakeet_edits,
            "oracleCompleteHypothesisEdits": oracle_edits,
            "parakeetRelativeGainVsQwenPercent": (
                100 * (qwen_edits - parakeet_edits) / qwen_edits if qwen_edits else 0
            ),
            "oracleRelativeGainVsQwenPercent": (
                100 * (qwen_edits - oracle_edits) / qwen_edits if qwen_edits else 0
            ),
            "parakeetBetterEqualWorseWindows": {
                "better": sum(row["parakeetEdits"] < row["qwenEdits"]
                              for row in final_rows),
                "equal": sum(row["parakeetEdits"] == row["qwenEdits"]
                             for row in final_rows),
                "worse": sum(row["parakeetEdits"] > row["qwenEdits"]
                             for row in final_rows),
            },
            "selectedEdits": selected_edits,
            "relativeGainPercent": relative_gain,
            "parakeetSelections": sum(row["selectedBackend"] == "parakeet-ja"
                                      for row in final_rows),
            "qwenAbstentions": sum(row["selectedBackend"] == "qwen-ja"
                                   for row in final_rows),
            "qwenDimensions": qwen_dimensions,
            "parakeetDimensions": parakeet_dimensions,
            "selectedDimensions": selected_dimensions,
            "dimensionChanges": dimension_changes(final_rows),
            "qwenEmpty": qwen_empty,
            "parakeetEmpty": parakeet_empty,
            "selectedEmpty": selected_empty,
            "qwenDuplicates": qwen_duplicates,
            "selectedDuplicates": selected_duplicates,
            "blocks": blocks,
            "abstentionExplanation": {
                "abstentionReasonHistogram": abstention_reasons,
                "exclusiveReasonCombinations": abstention_combinations,
                "parakeetChoiceReasonHistogram": choice_reasons,
                "globalFailClosed": not calibration["admissible"],
                "modalFoldThresholdDiagnosticOnly": override_summary(
                    final_rows, modal_threshold
                ),
                "mappingCausedAbstentions": False,
            },
            "examples": [
                {key: row[key] for key in (
                    "id", "startSample", "endSample", "referenceJapanese", "qwen",
                    "parakeet", "selectedBackend", "selectedText", "qwenEdits",
                    "parakeetEdits", "selectedEdits"
                )} for row in ([changes[-1], changes[0]] if changes else [])
            ],
        },
        "runtime": {
            "workerSeconds": worker_seconds,
            "workerMemory": worker_memory,
            "ASRSeconds": sum(worker_seconds.values()),
            "peakPhysicalFootprintBytes": max(
                worker["lifecycle"]["peakPhysicalFootprintBytes"] for worker in run["workers"]),
            "workers": run["workers"],
        },
        "gates": gates,
        "english": None,
    }
    write_json(args.selection, selection)
    report["selectionSHA256"] = sha256(args.selection)
    write_json(args.report, report)
    return selection, report


def named_durations(value: dict | list) -> dict[str, float]:
    if isinstance(value, dict):
        return value
    if len(value) % 2:
        raise RuntimeError("invalid stage duration evidence")
    return dict(zip(value[::2], value[1::2]))


def failed_downstream_diagnostic(
    candidate: dict, candidate_manifest: dict, translation_runtime: dict,
    selection: dict, run: dict,
) -> dict:
    failures = candidate_manifest.get("failures", [])
    alignment = candidate.get("alignment") or {}
    worker = alignment.get("worker") or {}
    zero_cues = [
        {"chunkIndex": chunk["index"], **cue}
        for chunk in alignment.get("chunks", [])
        for cue in chunk.get("cues", []) if cue["end"] <= cue["start"]
    ]
    reconstructed = "\n".join(
        row["selectedText"] for row in selection["windows"]
        if normalize(row["selectedText"])
    )
    chunks = alignment.get("chunks", [])
    boundaries_match = len(chunks) == len(selection["windows"]) and all(
        chunk["index"] == index
        and math.isclose(chunk["sourceStart"], row["startSample"] / SAMPLE_RATE)
        and math.isclose(chunk["sourceEnd"], row["endSample"] / SAMPLE_RATE)
        for index, (chunk, row) in enumerate(zip(chunks, selection["windows"]))
    )
    override_indices = [
        index for index, row in enumerate(selection["windows"])
        if row["selectedBackend"] == "parakeet-ja"
    ]
    event_models = {event.get("modelID") for event in candidate.get("modelEvents", [])}
    allowed_models = {candidate.get("model", {}).get("modelID"), alignment.get("modelID")}
    translation_events = sorted(model for model in event_models - allowed_models if model)
    if (candidate_manifest.get("status") != "failed" or len(failures) != 1
            or failures[0].get("stage") != "alignment" or len(zero_cues) != 1
            or zero_cues[0]["id"] not in failures[0].get("message", "")
            or candidate.get("translation") is not None or candidate.get("asrWorker") is not None
            or worker.get("exitStatus") != 0 or worker.get("forcedTermination")
            or translation_runtime.get("exitCode") == 0 or translation_runtime.get("timedOut")
            or candidate.get("rawASR") != selection["rawTranscript"]
            or reconstructed != selection["rawTranscript"] or not boundaries_match
            or translation_events):
        raise RuntimeError("failed downstream evidence is incomplete or mismatched")
    failed = zero_cues[0]
    failed_window = selection["windows"][failed["chunkIndex"]]
    return {
        "classification": "candidate-pipeline-failure-at-forced-alignment-gate",
        "failure": failures[0],
        "zeroDurationCue": failed,
        "forcedAlignerExitedCleanly": True,
        "safeSerializedReplayAvailable": False,
        "safeReplayReason": (
            "The serialized aligner result already contains a zero-duration cue; "
            "continuing would require inventing timing or rerunning the aligner."
        ),
        "translationModelLoaded": False,
        "translationModelEventIDs": translation_events,
        "translationEvidencePresent": False,
        "selectionInputAudit": {
            "rawTranscriptMatches": True,
            "rawTranscriptSHA256": hashlib.sha256(
                selection["rawTranscript"].encode("utf-8")
            ).hexdigest(),
            "windowCount": len(selection["windows"]),
            "allWindowsNonempty": all(normalize(row["selectedText"])
                                       for row in selection["windows"]),
            "orderAndBoundariesMatchAlignment": True,
            "firstSample": selection["windows"][0]["startSample"],
            "lastSample": selection["windows"][-1]["endSample"],
            "sourceDurationSeconds": alignment["sourceDuration"],
            "sourceSHA256": selection["sourceSHA256"],
            "sourcePath": candidate["source"]["path"],
        },
        "adaptiveOverrideCausality": {
            "overrideWindowIndices": override_indices,
            "failedWindowIndex": failed["chunkIndex"],
            "failedWindowBackend": failed_window["selectedBackend"],
            "failedWindowQwenEqualsParakeet": failed_window["qwen"] == failed_window["parakeet"],
            "causedByOverrides": failed["chunkIndex"] in override_indices,
            "conclusion": "generic downstream forced-aligner failure",
        },
        "issue93Comparison": {
            "sameFailureClass": True,
            "issue93Failure": "Alignment cue cue-0159 has invalid or non-monotonic timing.",
            "issue93ZeroDurationCue": {
                "id": "cue-0159", "text": "気を取っちゃう。",
                "start": 551.62, "end": 551.62,
            },
            "evidence": "docs/japanese-live/experiments/evidence/E27/corrected-resume-diagnostic.json",
        },
        "worker": worker,
        "stageSeconds": named_durations(candidate_manifest["stageDurations"]),
        "jobPeakMemoryBytes": candidate_manifest["peakMemoryBytes"],
        "alignmentModelPeakMemoryBytes": alignment["peakMemoryBytes"],
        "commandRuntime": translation_runtime,
        "strictlyAfterASR": (
            parse_date(run["workers"][-1]["lifecycle"]["exitedAt"])
            <= parse_date(worker["startedAt"])
        ),
    }


def diagnose_translation_failure(args: argparse.Namespace) -> None:
    candidate = read_json(args.candidate_raw)
    candidate_manifest = read_json(args.candidate_manifest)
    baseline = read_json(args.baseline_raw)
    manifest = read_json(args.manifest)
    selection = read_json(args.selection)
    runtime = read_json(args.translation_runtime)
    translation = candidate.get("translation") or {}
    turns = translation.get("request", {}).get("turns", [])
    turn_by_id = {turn["id"]: turn for turn in turns}
    hard = [item for item in translation.get("integrityVerdicts", [])
            if item.get("verdict") == "hard-failure"]
    failed_batches = [batch for batch in translation.get("batches", [])
                      if batch.get("cueIDs") == ["unit-0054"]]
    alignment = candidate.get("alignment") or {}
    if (candidate_manifest.get("status") != "failed"
            or candidate_manifest.get("failures") != [{
                "stage": "translation",
                "message": ("English translation failed validation twice for unit-0054. "
                            "No invalid Deliverable was published."),
            }]
            or candidate.get("asrWorker") is not None
            or candidate.get("rawASR") != selection.get("rawTranscript")
            or runtime.get("exitCode") != 1 or runtime.get("timedOut")
            or any(cue["end"] <= cue["start"] for chunk in alignment.get("chunks", [])
                   for cue in chunk.get("cues", []))
            or alignment.get("configuration", {}).get("coarseTimingCueIDs") != "cue-0295"
            or len(hard) != 1 or hard[0].get("cueID") != "unit-0054"
            or [reason.get("code") for reason in hard[0].get("reasons", [])]
               != ["degenerate-repetition"]
            or len(failed_batches) != 2
            or [batch.get("attemptNumber") for batch in failed_batches] != [1, 2]
            or len({batch.get("sanitizedOutput") for batch in failed_batches}) != 1
            or translation.get("worker", {}).get("exitStatus") != 0
            or translation.get("worker", {}).get("forcedTermination")):
        raise RuntimeError("fixed translation failure evidence is incomplete or mismatched")

    failed_turn = turn_by_id["unit-0054"]
    failed_output = failed_batches[-1]["sanitizedOutput"]
    if ("そう" * 4 not in failed_turn["japanese"]
            or len(re.findall(r"\bright\b", failed_output.lower())) < 4):
        raise RuntimeError("unit-0054 is not the source-attested repetition false positive")

    outputs = {
        batch["cueIDs"][0]: batch["sanitizedOutput"]
        for batch in translation["batches"]
        if batch.get("selected") and len(batch.get("cueIDs", [])) == 1
    }
    accepted_count = len(outputs)
    turn_ids = [turn["id"] for turn in turns]
    failed_index = turn_ids.index("unit-0054")
    accepted_before = sum(item in outputs for item in turn_ids[:failed_index])
    accepted_after = sum(item in outputs for item in turn_ids[failed_index + 1:])
    outputs["unit-0054"] = failed_output
    if len(outputs) != len(turns) or set(outputs) != set(turn_by_id):
        raise RuntimeError("raw translation outputs do not cover every semantic unit")
    reconstructed = json.loads(json.dumps(candidate))
    reconstructed["translation"]["response"] = json.dumps({
        "translations": [{"id": turn["id"], "text": outputs[turn["id"]]}
                         for turn in turns]
    }, ensure_ascii=False)
    baseline_rows = translation_rows(manifest, baseline)
    candidate_rows = translation_rows(manifest, reconstructed)
    reference = " ".join(row["reference"] for row in candidate_rows)
    baseline_score = chrf_pp(" ".join(row["hypothesis"] for row in baseline_rows), reference)
    candidate_score = chrf_pp(" ".join(row["hypothesis"] for row in candidate_rows), reference)
    baseline_by_id = {row["id"]: row for row in baseline_rows}
    candidate_by_id = {row["id"]: row for row in candidate_rows}

    baseline_translation = baseline["translation"]
    baseline_outputs = {item["id"]: item["text"] for item in
                        json.loads(baseline_translation["response"])["translations"]}
    baseline_turns = baseline_translation["request"]["turns"]

    def passage(turns_value: list[dict], output: dict[str, str], start: float,
                end: float) -> dict:
        matching = [turn for turn in turns_value
                    if turn.get("sourceStart") is not None
                    and turn["sourceStart"] < end and start < turn["sourceEnd"]]
        return {
            "turnIDs": [turn["id"] for turn in matching],
            "japanese": " ".join(turn["japanese"] for turn in matching),
            "english": " ".join(output.get(turn["id"], "") for turn in matching),
        }

    override_rows = []
    failed_window_index = next(index for index, row in enumerate(selection["windows"])
                               if row["startSample"] / SAMPLE_RATE < failed_turn["sourceEnd"]
                               and failed_turn["sourceStart"] < row["endSample"] / SAMPLE_RATE)
    for index, window in enumerate(selection["windows"]):
        if window["selectedBackend"] != "parakeet-ja":
            continue
        start = window["startSample"] / SAMPLE_RATE
        end = window["endSample"] / SAMPLE_RATE
        references = [item for item in manifest["annotations"]["turns"]
                      if item["startSample"] / SAMPLE_RATE < end
                      and start < item["endSample"] / SAMPLE_RATE]
        ids = [str(item["id"]) for item in references]
        baseline_english = " ".join(baseline_by_id[item]["hypothesis"] for item in ids)
        candidate_english = " ".join(candidate_by_id[item]["hypothesis"] for item in ids)
        reference_english = " ".join(item.get("english") or "" for item in references)
        override_rows.append({
            "index": index, "id": window["id"], "start": start, "end": end,
            "qwen": window["qwen"], "parakeet": window["parakeet"],
            "selectedJapanese": window["selectedText"],
            "distanceFromFailureWindows": index - failed_window_index,
            "distanceFromFailureSeconds": start - failed_turn["sourceEnd"],
            "baseline": passage(baseline_turns, baseline_outputs, start, end),
            "candidate": passage(turns, outputs, start, end),
            "referenceEnglish": reference_english or None,
            "baselineChrFPlusPlus": (chrf_pp(baseline_english, reference_english)
                                     if reference_english else None),
            "candidateChrFPlusPlus": (chrf_pp(candidate_english, reference_english)
                                      if reference_english else None),
        })

    worker = translation["worker"]
    diagnostic = {
        "schemaVersion": 1, "ticket": 94,
        "classification": "validator-false-positive-source-attested-repetition",
        "holdoutOpened": False, "benchmarkSlotReleased": True,
        "preflight": {"build": "passed", "input": "passed", "reference": "passed",
                      "checkpointAndHashes": "passed", "runtimeTimedOut": False},
        "failedUnit": {
            "id": "unit-0054", "japanese": failed_turn["japanese"],
            "sourceStart": failed_turn["sourceStart"], "sourceEnd": failed_turn["sourceEnd"],
            "precedingJapanese": failed_turn.get("precedingJapanese", []),
            "followingJapanese": failed_turn.get("followingJapanese", []),
            "sourceWindow": {"index": failed_window_index,
                             **selection["windows"][failed_window_index]},
            "attempts": [{key: batch.get(key) for key in (
                "attemptNumber", "nativePrompt", "sanitizedPrompt", "nativeOutput",
                "sanitizedOutput", "validationReasonCodes", "finishReason",
                "inputTokens", "outputTokens", "duration", "terminalOutcome")}
                for batch in failed_batches],
            "integrityVerdict": hard[0],
        },
        "baselineSamePassage": passage(
            baseline_turns, baseline_outputs, failed_turn["sourceStart"], failed_turn["sourceEnd"]),
        "candidateSamePassage": passage(
            turns, outputs, failed_turn["sourceStart"], failed_turn["sourceEnd"]),
        "acceptedUnitsBeforeGate": accepted_count,
        "generatedUnits": len(turns),
        "completionPlan": {
            "totalUnits": len(turns),
            "retainedAcceptedUnits": accepted_count,
            "acceptedBeforeTarget": accepted_before,
            "acceptedAfterTarget": accepted_after,
            "neverGeneratedUnits": len(turns) - accepted_count - 1,
            "translateUnitIDs": ["unit-0054"],
            "mergeAfterRetry": "281 retained outputs + unit-0054 retry",
        },
        "counterfactualDiagnosticOnly": {
            "invalidDeliverablePublished": False,
            "reconstructedFromRetainedRaw": True,
            "baselineChrFPlusPlus": baseline_score,
            "candidateChrFPlusPlus": candidate_score,
            "delta": candidate_score - baseline_score,
        },
        "overrides": override_rows,
        "runtime": {
            "commandSeconds": runtime["elapsedSeconds"],
            "stages": named_durations(candidate_manifest["stageDurations"]),
            "jobPeakMemoryBytes": candidate_manifest["peakMemoryBytes"],
            "alignmentWorkerPeakBytes": alignment["worker"]["peakPhysicalFootprintBytes"],
            "translationWorkerPeakBytes": worker["peakPhysicalFootprintBytes"],
            "translationWorkerSeconds": worker["elapsedSeconds"],
            "pressureTransitions": worker["pressureTransitions"],
            "minimumAvailableMemoryBytes": min(item["availableMemoryBytes"]
                                                for item in worker["availableMemorySamples"]),
            "swapDeltaBytes": worker["swapUsedAfterBytes"] - worker["swapUsedBeforeBytes"],
            "forcedTermination": worker["forcedTermination"],
        },
        "issue95": "not-decided: Japanese value of #94 remains independently measurable",
    }
    write_json(args.output, diagnostic)
    write_json(args.retry_baseline, translation)
    write_json(args.retry_verdicts, {
        "schemaVersion": 1, "corpus": "development",
        "sourceArtifact": str(args.candidate_raw),
        "thresholds": {"version": "translation-integrity-dev-v1",
                       "minimumLengthRatio": 0.5, "maximumLengthRatio": 6,
                       "copiedOutputSimilarity": 0.8, "correspondingSourceSimilarity": 0.2,
                       "minimumCopiedOutputWords": 3, "repetitionCount": 4},
        "verdicts": hard,
    })


def finalize_targeted_translation(args: argparse.Namespace) -> None:
    candidate = read_json(args.candidate_raw)
    retry = read_json(args.retry)
    baseline = read_json(args.baseline_raw)
    manifest = read_json(args.manifest)
    ready = read_json(args.ready)
    diagnostic = read_json(args.diagnostic)
    runtime = read_json(args.runtime)
    translation = candidate["translation"]
    turns = translation["request"]["turns"]
    turn_ids = [turn["id"] for turn in turns]
    selected = [batch for batch in translation["batches"] if batch.get("selected")]
    outputs = {batch["cueIDs"][0]: batch["sanitizedOutput"] for batch in selected
               if len(batch.get("cueIDs", [])) == 1}
    retry_translation = retry.get("retry") or {}
    retry_rows = json.loads(retry_translation.get("response", "{}")) \
        .get("translations", [])
    retry_verdicts = retry.get("retryVerdicts", [])
    target_turn = turns[turn_ids.index("unit-0054")]
    retry_worker = retry_translation.get("worker") or {}
    if (ready.get("status") != "READY_FOR_TARGETED_TRANSLATION_RETRY"
            or retry.get("rejectedCueIDs") != ["unit-0054"]
            or [row.get("id") for row in retry_rows] != ["unit-0054"]
            or len(retry_verdicts) != 1
            or {key: retry_verdicts[0].get(key) for key in (
                "cueID", "testedSource", "generatedOutput", "verdict", "reasons"
            )} != {"cueID": "unit-0054", "testedSource": target_turn["japanese"],
                   "generatedOutput": retry_rows[0].get("text") if retry_rows else None,
                   "verdict": "pass", "reasons": []}
            or retry_worker.get("exitStatus") != 0 or retry_worker.get("forcedTermination")
            or len(turns) != 282 or len(outputs) != 281
            or "unit-0054" in outputs
            or turn_ids.index("unit-0054") != 53
            or set(outputs) != set(turn_ids) - {"unit-0054"}
            or runtime.get("exitCode") != 0 or runtime.get("timedOut")
            or diagnostic.get("completionPlan", {}).get("acceptedAfterTarget") != 228):
        raise RuntimeError("targeted retry cannot be merged into the retained translation")
    outputs["unit-0054"] = retry_rows[0]["text"]
    merged_rows = [{"id": turn["id"], "text": outputs[turn["id"]]} for turn in turns]
    reconstructed = json.loads(json.dumps(candidate))
    reconstructed["translation"]["response"] = json.dumps(
        {"translations": merged_rows}, ensure_ascii=False)
    baseline_rows = translation_rows(manifest, baseline)
    candidate_rows = translation_rows(manifest, reconstructed)
    reference = " ".join(row["reference"] for row in candidate_rows)
    write_json(args.output, {
        "schemaVersion": 1, "ticket": 94, "status": "completed",
        "holdoutOpened": False, "invalidDeliverablePublished": False,
        "completeness": {
            "totalUnits": 282, "reusedAcceptedUnits": 281,
            "retriedUnitIDs": ["unit-0054"], "acceptedBeforeTarget": 53,
            "acceptedAfterTarget": 228, "neverGeneratedUnits": 0,
        },
        "translations": merged_rows,
        "english": {
            "baselineChrFPlusPlus": chrf_pp(
                " ".join(row["hypothesis"] for row in baseline_rows), reference),
            "candidateChrFPlusPlus": chrf_pp(
                " ".join(row["hypothesis"] for row in candidate_rows), reference),
        },
        "targetedRetry": retry,
        "runtime": runtime,
        "inputSHA256": {
            "candidateRaw": sha256(args.candidate_raw), "retry": sha256(args.retry),
            "ready": sha256(args.ready), "diagnostic": sha256(args.diagnostic),
        },
    })


def final_report(args: argparse.Namespace) -> dict:
    report = read_json(args.selection_report)
    selection = read_json(args.selection)
    run = read_json(args.run)
    reuse = read_json(args.reuse_diagnostic)
    asr_runtime = read_json(args.asr_runtime)
    if (report.get("ticket") != 94 or report.get("selectionSHA256") != sha256(args.selection)
            or selection.get("planSHA256") != run.get("planSHA256")
            or reuse.get("decisionReusable") is not False
            or asr_runtime.get("exitCode") != 0):
        raise RuntimeError("final report inputs are incomplete or mismatched")
    report["reuseDiagnostic"] = reuse
    report["runtime"]["ASRCommand"] = asr_runtime
    if not selection["developmentEligibleJapanese"]:
        if args.candidate_raw or args.candidate_manifest or args.translation_runtime:
            raise RuntimeError("translation evidence exists after a Japanese NO-GO")
        report["decision"] = "NO-GO-stop-before-translation"
        report["english"] = {"run": False, "reason": "Japanese gates failed"}
    else:
        downstream = (args.candidate_raw, args.candidate_manifest, args.translation_runtime)
        if not any(downstream):
            report["decision"] = "READY_FOR_DOWNSTREAM_RESUME"
            report["english"] = {
                "run": False,
                "reason": "Awaiting a new serialized slot for alignment and one translation",
            }
            report["downstreamResumeCommand"] = (
                "BENCHMARK_SLOT_GRANTED=94 bash "
                "Scripts/run_adaptive_asr_experiment.sh resume"
            )
            report["holdoutOpened"] = False
            report["promote"] = False
            write_json(args.output, report)
            write_markdown(args.markdown, report)
            return report
        if not all(downstream):
            raise RuntimeError("partial downstream evidence is not reportable")
        if (sha256(args.baseline_raw) != EXPECTED["baselineRaw"]
                or sha256(args.manifest) != "a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b"):
            raise RuntimeError("baseline/reference manifest changed")
        candidate = read_json(args.candidate_raw)
        candidate_manifest = read_json(args.candidate_manifest)
        baseline = read_json(args.baseline_raw)
        manifest = read_json(args.manifest)
        translation_runtime = read_json(args.translation_runtime)
        if candidate_manifest.get("status") == "failed":
            failure = failed_downstream_diagnostic(
                candidate, candidate_manifest, translation_runtime, selection, run
            )
            report["downstreamFailure"] = failure
            report["english"] = {
                "run": False,
                "reason": "Forced alignment gate failed before TranslateGemma loading",
                "japaneseEditGainImpactMeasurable": False,
                "chrFPlusPlus": None,
                "COMET": None,
            }
            report["runtime"].update({
                "translationCommand": translation_runtime,
                "downstreamStageSeconds": failure["stageSeconds"],
                "alignmentWorker": failure["worker"],
                "translationWorker": None,
                "allHeavyModelsSequential": failure["strictlyAfterASR"],
                "downstreamIncrementalCommandSeconds": translation_runtime["elapsedSeconds"],
                "totalCommandSeconds": (
                    asr_runtime["elapsedSeconds"] + translation_runtime["elapsedSeconds"]
                ),
                "totalModelWorkerSeconds": (
                    report["runtime"]["ASRSeconds"] + failure["worker"]["elapsedSeconds"]
                ),
                "downstreamIncrementalPeakPhysicalFootprintBytes": (
                    failure["worker"]["peakPhysicalFootprintBytes"]
                ),
                "peakPhysicalFootprintBytes": max(
                    report["runtime"]["peakPhysicalFootprintBytes"],
                    failure["worker"]["peakPhysicalFootprintBytes"],
                    failure["jobPeakMemoryBytes"],
                ),
            })
            report["gates"]["englishNotWorse"] = False
            report["decision"] = "NO-GO-downstream-forced-alignment-gate"
            report["issue95"] = "no-run: #94 has no eligible English candidate"
            report["benchmarkSlotReleased"] = True
            report["holdoutOpened"] = False
            report["promote"] = False
            write_json(args.output, report)
            write_markdown(args.markdown, report)
            return report
        if (candidate_manifest.get("status") != "completed"
                or candidate.get("rawASR") != selection["rawTranscript"]
                or candidate.get("translation") is None
                or candidate.get("asrWorker") is not None
                or translation_runtime.get("exitCode") != 0):
            raise RuntimeError("single downstream translation evidence is incomplete")
        baseline_rows = translation_rows(manifest, baseline)
        candidate_rows = translation_rows(manifest, candidate)
        baseline_text = " ".join(row["hypothesis"] for row in baseline_rows)
        candidate_text = " ".join(row["hypothesis"] for row in candidate_rows)
        english_reference = " ".join(row["reference"] for row in candidate_rows)
        integrity = cue_integrity(candidate)
        baseline_empty = sum(not row["hypothesis"] for row in baseline_rows)
        candidate_empty = sum(not row["hypothesis"] for row in candidate_rows)
        baseline_chrf = chrf_pp(baseline_text, english_reference)
        candidate_chrf = chrf_pp(candidate_text, english_reference)
        english_gates = {
            "oneTranslation": True,
            "structuredCues": structured_cues_are_valid(integrity),
            "noAddedEmptyTurns": candidate_empty <= baseline_empty,
            "noValidationFailure": not candidate["translation"].get("validationFailures"),
            "chrFPlusPlusNotWorse": candidate_chrf >= baseline_chrf,
        }
        examples = representative_examples(baseline_rows, candidate_rows)
        alignment_worker = candidate.get("alignment", {}).get("worker")
        translation_worker = candidate.get("translation", {}).get("worker")
        if not alignment_worker or not translation_worker:
            raise RuntimeError("alignment/translation worker lifecycle missing")
        parakeet_exit = parse_date(run["workers"][1]["lifecycle"]["exitedAt"])
        sequential = (parakeet_exit <= parse_date(alignment_worker["startedAt"])
                      <= parse_date(alignment_worker["exitedAt"])
                      <= parse_date(translation_worker["startedAt"])
                      <= parse_date(translation_worker["exitedAt"]))
        if not sequential:
            raise RuntimeError("heavy model lifecycle overlapped after ASR selection")
        report["english"] = {
            "run": True,
            "baselineChrFPlusPlus": baseline_chrf,
            "candidateChrFPlusPlus": candidate_chrf,
            "delta": candidate_chrf - baseline_chrf,
            "baselineEmptyTurns": baseline_empty,
            "candidateEmptyTurns": candidate_empty,
            "integrity": integrity,
            "examples": examples,
            "gates": english_gates,
        }
        report["runtime"].update({
            "translationCommand": translation_runtime,
            "translationStageSeconds": named_durations(candidate_manifest["stageDurations"]),
            "alignmentWorker": alignment_worker,
            "translationWorker": translation_worker,
            "allHeavyModelsSequential": sequential,
            "peakPhysicalFootprintBytes": max(
                report["runtime"]["peakPhysicalFootprintBytes"],
                alignment_worker["peakPhysicalFootprintBytes"],
                translation_worker["peakPhysicalFootprintBytes"],
                candidate_manifest["peakMemoryBytes"],
            ),
        })
        report["gates"]["englishNotWorse"] = all(english_gates.values())
        report["decision"] = ("development-pass-holdout-remains-closed"
                              if all(report["gates"].values())
                              else "NO-GO-stop-before-holdout")
    report["holdoutOpened"] = False
    report["promote"] = False
    write_json(args.output, report)
    write_markdown(args.markdown, report)
    return report


def seconds(value: float) -> str:
    return f"{value:.1f}s"


def write_markdown(path: Path, report: dict) -> None:
    japanese = report["japanese"]
    runtime = report["runtime"]
    english = report["english"]
    dimensions = ", ".join(
        f"{key} {japanese['qwenDimensions'][key]} Qwen / "
        f"{japanese['parakeetDimensions'][key]} Parakeet"
        for key in ("terms", "numbers", "meaning")
    )
    memory = runtime["workerMemory"]
    comparison = japanese["parakeetBetterEqualWorseWindows"]
    lines = [
        "# E28 — Adaptive ASR Qwen + Parakeet DEV (#94)",
        "",
        f"**Decision: {report['decision']}.** Holdout fermé.",
        "",
        f"- Fenêtres acoustiques communes : {japanese['windowCount']}, max "
        f"{japanese['maximumWindowSeconds']:.2f}s ; aucune référence dans le plan ou le sélecteur.",
        f"- Choix : Parakeet {japanese['parakeetSelections']}, abstentions Qwen "
        f"{japanese['qwenAbstentions']} ; calibration exacte stable="
        f"{str(report['calibration']['stable']).lower()}, admissible="
        f"{str(report['calibration']['admissible']).lower()} "
        f"({report['calibration']['thresholdStatus']}).",
        f"- Japonais : edits Qwen {japanese['qwenEdits']}, Parakeet "
        f"{japanese['parakeetEdits']}, oracle hypothèse complète "
        f"{japanese['oracleCompleteHypothesisEdits']} ; Parakeet meilleur/égal/pire "
        f"{comparison['better']}/{comparison['equal']}/{comparison['worse']} fenêtres.",
        f"- Dimensions : {dimensions}.",
        f"- Vides {japanese['qwenEmpty']}→{japanese['selectedEmpty']} ; doublons "
        f"{japanese['qwenDuplicates']}→{japanese['selectedDuplicates']}.",
        f"- ASR : Qwen {seconds(runtime['workerSeconds']['qwen-ja'])}, Parakeet "
        f"{seconds(runtime['workerSeconds']['parakeet-ja'])}, total worker "
        f"{seconds(runtime['ASRSeconds'])}, commande {seconds(runtime['ASRCommand']['elapsedSeconds'])}; "
        f"pics Qwen {memory['qwen-ja']['peakPhysicalFootprintBytes'] / 1024**3:.2f} Gio, "
        f"Parakeet {memory['parakeet-ja']['peakPhysicalFootprintBytes'] / 1024**3:.2f} Gio.",
        f"- Abstentions : "
        f"causes exclusives "
        f"{japanese['abstentionExplanation']['exclusiveReasonCombinations']} ; "
        f"signaux chevauchants "
        f"{japanese['abstentionExplanation']['abstentionReasonHistogram']} ; "
        "signaux runtime individuels, aucun veto global ni mapping.",
        f"- Mapping référence DEV : {report['referenceMappingAudit']['assignedCharacterCount']}/"
        f"{report['referenceMappingAudit']['characterCount']} caractères, "
        f"{report['referenceMappingAudit']['cueCount']} cues conservées, "
        "0 non assigné, aucun entrelacement des locuteurs.",
    ]
    lines += ["", "## Calibration par fold"]
    for fold in report["calibration"]["folds"]:
        learned, heldout = fold["learned"], fold["heldout"]
        lines.append(
            f"- Holdout bloc {fold['heldoutBlock']} — seuil {learned['threshold']}; "
            f"train overrides {learned['proposedOverrides']} "
            f"({learned['goodOverrides']} bons/{learned['badOverrides']} mauvais/"
            f"{learned['neutralOverrides']} neutres, gain {learned['netEditGain']}); "
            f"fold overrides {heldout['proposedOverrides']} "
            f"({heldout['goodOverrides']} bons/{heldout['badOverrides']} mauvais/"
            f"{heldout['neutralOverrides']} neutres, gain {heldout['netEditGain']})."
        )
    lines.append(f"- Variance : {report['calibration']['variance']}.")
    lines += ["", "## Contrôle règle fixe 0,5"]
    for fold in report["calibration"]["fixedRuleCrossValidation"]["folds"]:
        lines.append(
            f"- Bloc {fold['block']} — edits {fold['qwenEdits']}→"
            f"{fold['adaptiveEdits']}, overrides {fold['proposedOverrides']} "
            f"({fold['goodOverrides']} bons/{fold['badOverrides']} mauvais/"
            f"{fold['neutralOverrides']} neutres), gain {fold['netEditGain']}, "
            f"critique {fold['criticalChanges']}."
        )
    if english and english["run"]:
        lines.append(
            f"- Anglais : chrF++ {english['baselineChrFPlusPlus']:.2f}→"
            f"{english['candidateChrFPlusPlus']:.2f} ({english['delta']:+.2f}) ; "
            f"vides {english['baselineEmptyTurns']}→{english['candidateEmptyTurns']}."
        )
    elif report.get("downstreamFailure"):
        failure = report["downstreamFailure"]
        cue = failure["zeroDurationCue"]
        worker = failure["worker"]
        lines += [
            f"- Downstream : échec {failure['failure']['stage']} — "
            f"{failure['failure']['message']}",
            f"- Cue nul : {cue['id']} « {cue['text']} » "
            f"{cue['start']:.2f}–{cue['end']:.2f}s, fenêtre {cue['chunkIndex']} Qwen inchangée ; "
            "les deux overrides ne sont pas causaux.",
            f"- ForcedAligner : worker {seconds(worker['elapsedSeconds'])}, "
            f"pic {worker['peakPhysicalFootprintBytes'] / 1024**3:.2f} Gio, sortie 0 puis gate rouge ; "
            "TranslateGemma non chargé.",
            f"- Commande downstream : {seconds(failure['commandRuntime']['elapsedSeconds'])}; "
            f"pics job {failure['jobPeakMemoryBytes'] / 1024**3:.2f} Gio, "
            f"modèle aligner {failure['alignmentModelPeakMemoryBytes'] / 1024**3:.2f} Gio.",
            f"- Total DEV commandes : {seconds(runtime['totalCommandSeconds'])}; "
            f"workers modèles {seconds(runtime['totalModelWorkerSeconds'])}; "
            f"pic global {runtime['peakPhysicalFootprintBytes'] / 1024**3:.2f} Gio, "
            f"incrément downstream {runtime['downstreamIncrementalPeakPhysicalFootprintBytes'] / 1024**3:.2f} Gio.",
            "- Même classe que #93 (cue forced-aligner de durée nulle). "
            "Aucun replay sûr depuis ce raw : il faudrait inventer un timing ou recharger l’aligneur.",
            "- Anglais : non exécuté ; impact des 44 edits japonais, chrF++ et COMET indisponibles.",
            f"- #95 : {report['issue95']}.",
        ]
    else:
        lines.append(f"- Anglais : non exécuté ({english['reason']}).")
    lines += ["", "## Exemples japonais"]
    for label, row in zip(("Parakeet meilleur", "Parakeet pire"), japanese["examples"]):
        lines.append(
            f"- {label}, {row['startSample'] / SAMPLE_RATE:.2f}–"
            f"{row['endSample'] / SAMPLE_RATE:.2f}s — "
            f"référence « {row['referenceJapanese']} » ; Qwen « {row['qwen']} » ; "
            f"Parakeet « {row['parakeet']} » ; edits {row['qwenEdits']}→"
            f"{row['parakeetEdits']} ; runtime final {row['selectedBackend']}."
        )
    if english and english["run"]:
        lines += ["", "## Exemples anglais"]
        for row in english["examples"]:
            lines.append(
                f"- {row['category']} {row['id']} — référence « {row['referenceEnglish']} » ; "
                f"baseline « {row['baselineEnglish']} » ; candidat « {row['candidateEnglish']} »."
            )
    lines += ["", "Aucune UI, aucun changement Live/default, aucune ouverture holdout."]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def self_test() -> None:
    plan = build_acoustic_plan([0] * 160_000, "fixture")
    assert plan["windows"]
    assert max(row["endSample"] - row["startSample"] for row in plan["windows"]) <= 128_000
    assert all(left["endSample"] == right["startSample"]
               for left, right in zip(plan["windows"], plan["windows"][1:]))
    assert "reference" not in repr(plan).lower()
    assert "reference" not in inspect.getsource(runtime_decision).lower()

    mapped, audit = map_reference_rows([
        {"cue_id": "1", "speaker_id": "A", "japanese": "AB", "characters": [
            {"char": "A", "start": 0, "end": 0.2},
            {"char": "B", "start": 1.2, "end": 1.4},
        ]},
        {"cue_id": "2", "speaker_id": "B", "japanese": "xy", "characters": [
            {"char": "x", "start": 0.1, "end": 0.3},
            {"char": "y", "start": 1.1, "end": 1.3},
        ]},
    ], [
        {"startSample": 0, "endSample": 16_000},
        {"startSample": 16_000, "endSample": 32_000},
    ])
    assert mapped == ["Ax", "By"] and audit["everyCueTextConserved"]

    active = {"durationSeconds": 4, "acoustic": {"activeFrameRatio": 1}}
    choice = runtime_decision("", "日本語です", active, 1.0)
    assert choice["selectedBackend"] == "parakeet-ja"
    assert choice["selectedText"] == "日本語です"
    veto = runtime_decision("HP9000", "体力", active, 0)
    assert veto["selectedBackend"] == "qwen-ja"
    assert "qwen-critical-token-lost" in veto["reasons"]

    rows = []
    for block in range(5):
        rows += [
            {"id": f"weak-{block}", "block": block, "window": active,
             "qwen": "", "parakeet": "日本語です", "qwenEdits": 5, "parakeetEdits": 0},
            {"id": f"safe-{block}", "block": block, "window": active,
             "qwen": "正しい", "parakeet": "誤り", "qwenEdits": 0, "parakeetEdits": 2},
        ]
    calibration = calibrate(rows)
    assert calibration["stable"]
    assert calibration["threshold"] == 1.0
    metrics = calibration_metrics(calibration)
    assert metrics["predictedWinProbability"] < metrics["observedWinRate"]
    assert metrics["brier"] > 0 and metrics["ECE"] > 0
    assert all(item["selectedText"] in {item["qwen"], item["parakeet"]}
               for item in calibration["decisions"])
    try:
        validate_run({"windows": []}, {}, Path("unused"))
        raise AssertionError("incomplete runner output was accepted")
    except RuntimeError:
        pass
    print("adaptive_asr_harness self-test: PASS")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    plan = sub.add_parser("plan")
    plan.add_argument("--audio", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    diagnose = sub.add_parser("diagnose-reuse")
    for name in ("qwen-raw", "qwen-manifest", "parakeet-raw", "parakeet-manifest", "output"):
        diagnose.add_argument(f"--{name}", type=Path, required=True)
    select = sub.add_parser("select")
    for name in ("plan", "run", "character-alignment", "e23-segments", "selection", "report"):
        select.add_argument(f"--{name}", type=Path, required=True)
    report = sub.add_parser("report")
    for name in ("selection-report", "selection", "run", "reuse-diagnostic", "asr-runtime",
                 "baseline-raw", "manifest", "output", "markdown"):
        report.add_argument(f"--{name}", type=Path, required=True)
    for name in ("candidate-raw", "candidate-manifest", "translation-runtime"):
        report.add_argument(f"--{name}", type=Path)
    failure = sub.add_parser("diagnose-translation-failure")
    for name in ("candidate-raw", "candidate-manifest", "baseline-raw", "manifest",
                 "selection", "translation-runtime", "output", "retry-baseline",
                 "retry-verdicts"):
        failure.add_argument(f"--{name}", type=Path, required=True)
    finalize = sub.add_parser("finalize-targeted-translation")
    for name in ("candidate-raw", "retry", "baseline-raw", "manifest", "ready",
                 "diagnostic", "runtime", "output"):
        finalize.add_argument(f"--{name}", type=Path, required=True)
    return result


def main() -> None:
    args = parser().parse_args()
    if args.command == "self-test":
        self_test()
    elif args.command == "plan":
        if sha256(args.audio) != EXPECTED["audio"]:
            raise RuntimeError("frozen DEV PCM changed")
        samples = read_audio(args.audio, SAMPLE_RATE)
        write_json(args.output, build_acoustic_plan(samples, EXPECTED["audio"]))
    elif args.command == "diagnose-reuse":
        diagnose_reuse(args)
    elif args.command == "select":
        build_selection(args)
    elif args.command == "report":
        final_report(args)
    elif args.command == "diagnose-translation-failure":
        diagnose_translation_failure(args)
    elif args.command == "finalize-targeted-translation":
        finalize_targeted_translation(args)


if __name__ == "__main__":
    main()
