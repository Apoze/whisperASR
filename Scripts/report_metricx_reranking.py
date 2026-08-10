#!/usr/bin/env python3
"""Prepare and report the frozen MetricX-24 QE reranking experiment."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
from collections import Counter
from pathlib import Path

from report_high_quality_acceptance import translation_rows
from report_japanese_l7d import chrf_pp


CORPORA = {"development": "qudu2fx3ncc", "holdout": "md62mmdz0m"}
HARD_REASONS = {
    "empty-output",
    "residual-japanese",
    "control-scaffolding",
    "critical-glossary-violation",
    "truncated-output",
    "degenerate-repetition",
}
MARGINS = [0.0, 0.1, 0.25, 0.5, 1.0, 2.0]
INJECTED_PER_TYPE = 4


def read(path: Path) -> dict:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as stream:
        return json.load(stream)


def write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def response_map(evidence: dict) -> dict[str, str]:
    return {row["id"]: row["text"] for row in json.loads(evidence["response"])["translations"]}


def real_pairs(split: str, artifact: dict) -> list[dict]:
    evidence = artifact["evidence"]
    turns = {turn["id"]: turn for turn in evidence["request"]["turns"]}
    result = []
    for cue_id in artifact["retryCueIDs"]:
        batches = sorted(
            (batch for batch in evidence["batches"] if batch.get("cueIDs") == [cue_id]),
            key=lambda batch: batch["attemptNumber"],
        )
        if len(batches) != 2 or not any(batch.get("selected") for batch in batches):
            raise SystemExit(f"{split}:{cue_id} must retain exactly two frozen candidates and one selection")
        candidates = []
        for batch in batches:
            reasons = batch.get("validationReasonCodes") or []
            candidate_id = f'{split}:{cue_id}:attempt-{batch["attemptNumber"]}'
            candidates.append({
                "candidateID": candidate_id,
                "attemptNumber": batch["attemptNumber"],
                "text": batch["sanitizedOutput"],
                "eligible": not bool(HARD_REASONS.intersection(reasons)),
                "reasonCodes": reasons,
            })
        rejected_reasons = sorted({
            reason for candidate in candidates for reason in candidate["reasonCodes"]
        })
        result.append({
            "pairID": f"{split}:{cue_id}",
            "kind": "real-suspect",
            "cueID": cue_id,
            "source": turns[cue_id]["japanese"],
            "baselineCandidateID": next(
                f'{split}:{cue_id}:attempt-{batch["attemptNumber"]}'
                for batch in batches if batch.get("selected")
            ),
            "suspectReasonCodes": rejected_reasons,
            "candidates": candidates,
        })
    return result


def corrupt(text: str, source: str, unrelated: str, kind: str) -> str:
    words = text.split()
    if kind == "undertranslation":
        return " ".join(words[: max(1, len(words) // 2)])
    if kind == "overtranslation":
        return f"{text} {text}"
    if kind == "unrelated":
        return unrelated
    if kind == "source-copy":
        return source
    raise ValueError(kind)


def injected_pairs(artifact: dict) -> list[dict]:
    evidence = artifact["evidence"]
    outputs = response_map(evidence)
    turns = [turn for turn in evidence["request"]["turns"] if len(outputs[turn["id"]].split()) >= 6]
    needed = INJECTED_PER_TYPE * 4
    if len(turns) < needed + 1:
        raise SystemExit("Not enough accepted development outputs for corruption calibration")
    kinds = ["undertranslation", "overtranslation", "unrelated", "source-copy"]
    result = []
    for index in range(needed):
        turn = turns[index]
        clean = outputs[turn["id"]]
        kind = kinds[index // INJECTED_PER_TYPE]
        bad = corrupt(clean, turn["japanese"], outputs[turns[index + 1]["id"]], kind)
        clean_id = f"development:injected-{index:03d}:clean"
        bad_id = f"development:injected-{index:03d}:corrupt"
        control_candidate_id = clean_id if index % 2 == 0 else bad_id
        result.append({
            "pairID": f"development:injected-{index:03d}",
            "kind": "injected-corruption",
            "corruption": kind,
            "source": turn["japanese"],
            "baselineCandidateID": control_candidate_id,
            "baselinePolicy": "counterbalanced-original-vs-corrupt-control",
            "controlAssignment": "original" if control_candidate_id == clean_id else "corrupt",
            "expectedCandidateID": clean_id,
            "suspectReasonCodes": [f"injected-{kind}"],
            "candidates": [
                {"candidateID": clean_id, "text": clean, "eligible": True, "reasonCodes": []},
                {"candidateID": bad_id, "text": bad, "eligible": True,
                 "reasonCodes": [f"injected-{kind}"]},
            ],
        })
    return result


def score_rows(pairs: list[dict]) -> list[dict]:
    rows = []
    for pair in pairs:
        if not pair["suspectReasonCodes"]:
            raise SystemExit(f'{pair["pairID"]} is not a suspect unit')
        for candidate in pair["candidates"]:
            rows.append({
                "rowID": candidate["candidateID"],
                "pairID": pair["pairID"],
                "candidateID": candidate["candidateID"],
                "kind": pair["kind"],
                "source": pair["source"],
                "hypothesis": candidate["text"],
                "suspectReasonCodes": pair["suspectReasonCodes"],
            })
    assert all("reference" not in row for row in rows)
    return rows


def prepare(split: str, artifact_path: Path, output: Path) -> None:
    artifact = read(artifact_path)
    pairs = real_pairs(split, artifact)
    if split == "development":
        pairs += injected_pairs(artifact)
    output.mkdir(parents=True, exist_ok=True)
    write(output / "pairs.json", {
        "schemaVersion": 1,
        "split": split,
        "sourceArtifact": str(artifact_path),
        "sourceArtifactSHA256": sha256(artifact_path),
        "referencesIncluded": False,
        "pairs": pairs,
    })
    with (output / "metricx-input.jsonl").open("w", encoding="utf-8") as stream:
        for row in score_rows(pairs):
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")


def scores(path: Path) -> tuple[dict[str, float], list[dict]]:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows or any("reference" in row for row in rows):
        raise SystemExit("MetricX scores must be non-empty and reference-free")
    result = {row["candidateID"]: float(row["prediction"]) for row in rows}
    if len(result) != len(rows) or any(not 0 <= value <= 25 for value in result.values()):
        raise SystemExit("MetricX scores must be unique and inside [0, 25]")
    return result, rows


def select_candidate(pair: dict, values: dict[str, float], margin: float) -> str:
    candidates = [candidate for candidate in pair["candidates"] if candidate["eligible"]]
    if not candidates:
        raise ValueError(f'{pair["pairID"]} has no integrity-eligible candidate')
    baseline = pair["baselineCandidateID"]
    eligible_ids = {candidate["candidateID"] for candidate in candidates}
    if baseline not in eligible_ids:
        return min(eligible_ids, key=lambda candidate_id: (values[candidate_id], candidate_id))
    best = min(eligible_ids, key=lambda candidate_id: (values[candidate_id], candidate_id))
    return best if best != baseline and values[best] + margin < values[baseline] else baseline


def calibration_row(pairs: list[dict], values: dict[str, float], margin: float) -> dict:
    injected = [pair for pair in pairs if pair["kind"] == "injected-corruption"]
    real = [pair for pair in pairs if pair["kind"] == "real-suspect"]
    correct = sum(select_candidate(pair, values, margin) == pair["expectedCandidateID"]
                  for pair in injected)
    real_overrides = sum(select_candidate(pair, values, margin) != pair["baselineCandidateID"]
                         for pair in real)
    return {
        "margin": margin,
        "correctInjectedChoices": correct,
        "injectedChoices": len(injected),
        "injectedAccuracy": correct / len(injected),
        "realDevelopmentOverrides": real_overrides,
        "realDevelopmentPairs": len(real),
    }


def calibrate_margin(
    pairs: list[dict], values: dict[str, float], margins: list[float]
) -> dict:
    grid = [calibration_row(pairs, values, margin) for margin in margins]
    selected = max(
        grid,
        key=lambda row: (
            row["injectedAccuracy"],
            -row["realDevelopmentOverrides"],
            row["margin"],
        ),
    )
    return {
        "selectedMargin": selected["margin"],
        "accuracy": selected["injectedAccuracy"],
        "realDevelopmentOverrides": selected["realDevelopmentOverrides"],
        "grid": grid,
    }


def calibrate(development: Path, provenance_path: Path, policy_path: Path) -> None:
    pair_artifact = read(development / "pairs.json")
    values, _ = scores(development / "metricx-scores.jsonl")
    pairs = pair_artifact["pairs"]
    required = {candidate["candidateID"] for pair in pairs for candidate in pair["candidates"]}
    if required != set(values):
        raise SystemExit("Development scoring rows do not exactly match the frozen candidates")
    calibration = calibrate_margin(pairs, values, MARGINS)
    injected = [pair for pair in pairs if pair["kind"] == "injected-corruption"]
    control_correct = sum(pair["baselineCandidateID"] == pair["expectedCandidateID"]
                          for pair in injected)
    provenance = read(provenance_path)
    write(policy_path, {
        "schemaVersion": 1,
        "ticket": 56,
        "modelID": provenance["model"]["id"],
        "modelRevision": provenance["model"]["revision"],
        "provenanceSHA256": sha256(provenance_path),
        "mode": "reference-free-qe",
        "scoreDirection": "lower-is-better",
        "candidatePolicy": "hard-veto-then-margin-over-baseline",
        "hardFailureReasons": sorted(HARD_REASONS),
        "margin": calibration["selectedMargin"],
        "calibration": {
            **calibration,
            "counterbalancedControlAccuracy": control_correct / len(injected),
            "counterbalancedControlDesign": "Equal original/corrupt assignments provide a frozen selection control; this is not the product baseline policy.",
            "humanEnglishReferencesUsed": False,
        },
        "promotionGates": {
            "minimumInjectedChoiceAccuracy": 0.9,
            "minimumHoldoutCOMETGain": 0.005,
            "minimumHoldoutChrFPlusPlusGain": 0.0,
            "maximumAddedRuntimeFraction": 0.1,
            "systemReserveBytes": 8 * 1_024**3,
        },
        "developmentSourceArtifactSHA256": pair_artifact["sourceArtifactSHA256"],
        "frozenBeforeHoldout": True,
    })


def unit_reference(turn: dict, manifest: dict) -> str:
    return " ".join(
        reference.get("english") or ""
        for reference in manifest["annotations"]["turns"]
        if turn.get("sourceStart") is not None and turn.get("sourceEnd") is not None
        and turn["sourceStart"] < reference["endSample"] / manifest["fixture"]["sampleRate"]
        and reference["startSample"] / manifest["fixture"]["sampleRate"] < turn["sourceEnd"]
    ).strip()


def write_lines(path: Path, rows: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(row.replace("\n", " ") for row in rows) + "\n")


def apply_selection(
    split: str, artifact_path: Path, manifest_path: Path, directory: Path, policy_path: Path
) -> None:
    artifact = read(artifact_path)
    manifest = read(manifest_path)
    pair_artifact = read(directory / "pairs.json")
    values, _ = scores(directory / "metricx-scores.jsonl")
    policy = read(policy_path)
    evidence = artifact["evidence"]
    selected_evidence = copy.deepcopy(evidence)
    outputs = response_map(evidence)
    turns = {turn["id"]: turn for turn in evidence["request"]["turns"]}
    choices = []
    external = []
    baseline_reasons = Counter()
    selected_reasons = Counter()
    for pair in pair_artifact["pairs"]:
        selected_id = select_candidate(pair, values, policy["margin"])
        selected = next(candidate for candidate in pair["candidates"]
                        if candidate["candidateID"] == selected_id)
        baseline = next(candidate for candidate in pair["candidates"]
                        if candidate["candidateID"] == pair["baselineCandidateID"])
        if pair["kind"] == "real-suspect":
            outputs[pair["cueID"]] = selected["text"]
            baseline_reasons.update(baseline["reasonCodes"])
            selected_reasons.update(selected["reasonCodes"])
            reference = unit_reference(turns[pair["cueID"]], manifest)
            external.append({
                "pairID": pair["pairID"],
                "cueID": pair["cueID"],
                "reference": reference,
                "candidateChrFPlusPlus": {
                    candidate["candidateID"]: chrf_pp(candidate["text"], reference)
                    for candidate in pair["candidates"]
                },
            })
        choices.append({
            "pairID": pair["pairID"],
            "kind": pair["kind"],
            **({"cueID": pair["cueID"]} if "cueID" in pair else {}),
            "baselineCandidateID": pair["baselineCandidateID"],
            "selectedCandidateID": selected_id,
            "overridden": selected_id != pair["baselineCandidateID"],
            "scores": {candidate["candidateID"]: values[candidate["candidateID"]]
                       for candidate in pair["candidates"]},
            "baselineReasonCodes": baseline["reasonCodes"],
            "selectedReasonCodes": selected["reasonCodes"],
        })
    ordered = [
        {"id": turn["id"], "text": outputs[turn["id"]]}
        for turn in evidence["request"]["turns"]
    ]
    selected_evidence["response"] = json.dumps({"translations": ordered}, ensure_ascii=False)
    baseline_rows = translation_rows(manifest, {"translation": evidence})
    candidate_rows = translation_rows(manifest, {"translation": selected_evidence})
    metrics = directory / "metrics"
    write_lines(metrics / "source.ja.txt", [row["source"] for row in baseline_rows])
    write_lines(metrics / "reference.en.txt", [row["reference"] for row in baseline_rows])
    write_lines(metrics / "baseline.en.txt", [row["hypothesis"] for row in baseline_rows])
    write_lines(metrics / "metricx.en.txt", [row["hypothesis"] for row in candidate_rows])
    write(directory / "selection.json", {
        "schemaVersion": 1,
        "split": split,
        "policySHA256": sha256(policy_path),
        "humanEnglishReferencesIncluded": False,
        "choices": choices,
        "baselineIntegrityReasonCounts": dict(sorted(baseline_reasons.items())),
        "metricxIntegrityReasonCounts": dict(sorted(selected_reasons.items())),
    })
    write(directory / "external-evaluation.json", {
        "schemaVersion": 1,
        "split": split,
        "humanEnglishReferencesUsedOnlyHere": True,
        "realSuspectPairs": external,
    })
    write(directory / "selected-translation.json", selected_evidence)


def comet(path: Path, name: str) -> float | None:
    if not path.exists():
        return None
    rows = next((rows for key, rows in read(path).items() if Path(key).name == name), None)
    return sum(float(row["COMET"]) for row in rows) / len(rows) if rows else None


def report(root: Path, provenance_path: Path, policy_path: Path, json_path: Path,
           markdown_path: Path, live_log: Path) -> None:
    provenance = read(provenance_path)
    policy = read(policy_path)
    context = read(Path("docs/high-quality-context-e14.json"))
    context_rows = {row["split"]: row for row in context["rows"]}
    rows = []
    gates = {}
    for split in ("development", "holdout"):
        directory = root / split
        if not (directory / "selection.json").exists():
            continue
        selection = read(directory / "selection.json")
        runtime = read(directory / "metricx-runtime.json")
        score_values, score_data = scores(directory / "metricx-scores.jsonl")
        pair_data = read(directory / "pairs.json")["pairs"]
        expected_ids = {candidate["candidateID"] for pair in pair_data
                        for candidate in pair["candidates"]}
        baseline_lines = (directory / "metrics/baseline.en.txt").read_text().splitlines()
        candidate_lines = (directory / "metrics/metricx.en.txt").read_text().splitlines()
        references = (directory / "metrics/reference.en.txt").read_text().splitlines()
        baseline_chrf = chrf_pp(" ".join(baseline_lines), " ".join(references))
        candidate_chrf = chrf_pp(" ".join(candidate_lines), " ".join(references))
        baseline_comet = comet(directory / "metrics/comet-score.json", "baseline.en.txt")
        candidate_comet = comet(directory / "metrics/comet-score.json", "metricx.en.txt")
        real_choices = [choice for choice in selection["choices"]
                        if choice["kind"] == "real-suspect"]
        baseline_hard_selected = sum(
            bool(HARD_REASONS.intersection(choice["baselineReasonCodes"]))
            for choice in real_choices
        )
        metricx_hard_selected = sum(
            bool(HARD_REASONS.intersection(choice["selectedReasonCodes"]))
            for choice in real_choices
        )
        row = {
            "split": split,
            "corpusID": CORPORA[split],
            "suspectUnits": len(real_choices),
            "scoredCandidates": len(score_data),
            "overrides": sum(choice["overridden"] for choice in real_choices),
            "baseline": {"COMET": baseline_comet, "chrFPlusPlus": baseline_chrf},
            "metricx": {"COMET": candidate_comet, "chrFPlusPlus": candidate_chrf},
            "integrityReasonCounts": {
                "baseline": selection["baselineIntegrityReasonCounts"],
                "metricx": selection["metricxIntegrityReasonCounts"],
            },
            "hardFailedSelections": {
                "baseline": baseline_hard_selected,
                "metricx": metricx_hard_selected,
            },
            "runtimeSeconds": runtime["runtimeSeconds"],
            "runtime": runtime["workerRuntime"],
            "peakMemoryBytes": runtime["peakWorkerRSSBytes"],
            "minimumSystemAvailableBytes": runtime["systemMemory"]["minimumAvailableBytes"],
            "systemReserveBytes": runtime["systemReserveBytes"],
            "weightBytes": provenance["model"]["weight"]["bytes"],
            "rawScores": {candidate_id: score_values[candidate_id]
                          for candidate_id in sorted(score_values)},
        }
        rows.append(row)
        common = {
            "referenceFreeIsolation": all("reference" not in item for item in score_data),
            "scoresOnlySuspectUnits": set(score_values) == expected_ids
                and all(item["suspectReasonCodes"] for item in score_data),
            "noHardFailedSelection": metricx_hard_selected == 0,
            "sequentialModelHandoff": runtime["handoff"]["frozenProducerProcessExited"]
                and runtime["handoff"]["producerArtifactFrozenBeforeLoad"]
                and runtime["handoff"]["producerMemoryReleasedBeforeLoad"]
                and not runtime["handoff"]["translateGemmaProcessesBeforeLoad"]
                and runtime["handoff"]["workerExitedAfterScoring"],
            "memoryReserve": runtime["memoryReserveIntact"],
        }
        if split == "development":
            calibration = policy["calibration"]
            gates[split] = {
                **common,
                "injectedChoiceAccuracy": calibration["accuracy"]
                    >= policy["promotionGates"]["minimumInjectedChoiceAccuracy"],
                "beatsCounterbalancedControl": calibration["accuracy"]
                    > calibration["counterbalancedControlAccuracy"],
                "developmentCOMETNonRegression": candidate_comet is not None
                    and baseline_comet is not None and candidate_comet >= baseline_comet,
            }
        else:
            baseline_runtime = context_rows[split]["candidate"]["runtimeSeconds"]
            gates[split] = {
                **common,
                "holdoutCOMETGain": candidate_comet is not None and baseline_comet is not None
                    and candidate_comet - baseline_comet
                    >= policy["promotionGates"]["minimumHoldoutCOMETGain"],
                "holdoutChrFPlusPlusNonRegression": candidate_chrf - baseline_chrf
                    >= policy["promotionGates"]["minimumHoldoutChrFPlusPlusGain"],
                "runtimeCost": runtime["runtimeSeconds"]
                    <= baseline_runtime * policy["promotionGates"]["maximumAddedRuntimeFraction"],
            }
    ready_for_holdout = "development" in gates and all(gates["development"].values())
    live_passed = live_log.exists() and "Test Suite 'LiveCaptionTests' passed" in live_log.read_text()
    promoted = ready_for_holdout and "holdout" in gates and all(gates["holdout"].values()) \
        and live_passed
    if not ready_for_holdout:
        decision = "no-go-development"
    elif "holdout" not in gates:
        decision = "development-pass-holdout-pending"
    else:
        decision = "promote" if promoted else "no-go"
    evidence_root = Path("docs/japanese-live/experiments/evidence/E15")
    raw_artifacts = [
        {"path": str(path), "sha256": sha256(path)}
        for path in sorted(evidence_root.glob("*")) if path.is_file()
    ]
    result = {
        "schemaVersion": 1,
        "ticket": 56,
        "model": provenance["model"],
        "runtimeSource": provenance["runtimeSource"],
        "policy": policy,
        "rows": rows,
        "gates": gates,
        "readyForHoldout": ready_for_holdout,
        "liveGatesUnchanged": live_passed,
        "promoted": promoted,
        "decision": decision,
        "rawArtifacts": raw_artifacts,
        "evidenceLimitation": "Two complete reference videos and few real suspect units do not establish universal QE quality.",
    }
    write(json_path, result)
    lines = [
        "# E15 — MetricX reranking of suspect translations", "",
        "Ticket #56 changes only selection between frozen candidates. MetricX runs reference-free after the TranslateGemma producer process has exited; it never rewrites text.", "",
        f'Checkpoint `{provenance["model"]["id"]}` @ `{provenance["model"]["revision"]}` '
        f'({provenance["model"]["license"]}, {provenance["model"]["weight"]["bytes"] / 1_073_741_824:.2f} GiB).', "",
        f'Frozen margin: `{policy["margin"]}`; counterbalanced control→MetricX '
        f'injected choice accuracy: {policy["calibration"]["counterbalancedControlAccuracy"]:.1%}'
        f'→{policy["calibration"]["accuracy"]:.1%}.', "",
        "| Split | Suspect units | Overrides | COMET baseline→MetricX | chrF++ baseline→MetricX | Runtime | Peak RSS | Min system available |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        baseline, candidate = row["baseline"], row["metricx"]
        baseline_comet = "pending" if baseline["COMET"] is None else f'{baseline["COMET"]:.4f}'
        candidate_comet = "pending" if candidate["COMET"] is None else f'{candidate["COMET"]:.4f}'
        lines.append(
            f'| {row["split"]} | {row["suspectUnits"]} | {row["overrides"]} | '
            f'{baseline_comet}→{candidate_comet} | {baseline["chrFPlusPlus"]:.2f}→'
            f'{candidate["chrFPlusPlus"]:.2f} | {row["runtimeSeconds"]:.1f} s | '
            f'{row["peakMemoryBytes"] / 1_073_741_824:.2f} GiB | '
            f'{row["minimumSystemAvailableBytes"] / 1_073_741_824:.2f} GiB |'
        )
    lines += ["", f"Decision: **{decision}**.", "",
              "Two videos and the small number of real suspect units limit this conclusion."]
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.write_text("\n".join(lines) + "\n")


def self_test() -> None:
    pairs = [
        {
            "pairID": "baseline-clean", "kind": "injected-corruption",
            "baselineCandidateID": "clean-a", "expectedCandidateID": "clean-a",
            "candidates": [
                {"candidateID": "clean-a", "eligible": True},
                {"candidateID": "bad-a", "eligible": True},
            ],
        },
        {
            "pairID": "baseline-corrupt", "kind": "injected-corruption",
            "baselineCandidateID": "bad-b", "expectedCandidateID": "clean-b",
            "candidates": [
                {"candidateID": "bad-b", "eligible": True},
                {"candidateID": "clean-b", "eligible": True},
            ],
        },
    ]
    values = {"clean-a": 0.5, "bad-a": 4.0, "bad-b": 4.5, "clean-b": 0.4}
    calibration = calibrate_margin(pairs, values, [0.0, 0.5, 1.0])
    assert calibration["selectedMargin"] == 1.0
    assert calibration["accuracy"] == 1.0
    assert select_candidate(pairs[1], values, 1.0) == "clean-b"
    hard_veto = {
        "pairID": "hard-veto", "baselineCandidateID": "accepted",
        "candidates": [
            {"candidateID": "accepted", "eligible": True},
            {"candidateID": "hard-failure", "eligible": False},
        ],
    }
    assert select_candidate(hard_veto, {"accepted": 2.0, "hard-failure": 0.0}, 0.0) \
        == "accepted"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    subparsers = parser.add_subparsers(dest="command")
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("split", choices=CORPORA)
    prepare_parser.add_argument("artifact", type=Path)
    prepare_parser.add_argument("output", type=Path)
    calibrate_parser = subparsers.add_parser("calibrate")
    calibrate_parser.add_argument("development", type=Path)
    calibrate_parser.add_argument("provenance", type=Path)
    calibrate_parser.add_argument("policy", type=Path)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("split", choices=CORPORA)
    apply_parser.add_argument("artifact", type=Path)
    apply_parser.add_argument("manifest", type=Path)
    apply_parser.add_argument("directory", type=Path)
    apply_parser.add_argument("policy", type=Path)
    report_parser = subparsers.add_parser("report")
    report_parser.add_argument("root", type=Path)
    report_parser.add_argument("provenance", type=Path)
    report_parser.add_argument("policy", type=Path)
    report_parser.add_argument("json", type=Path)
    report_parser.add_argument("markdown", type=Path)
    report_parser.add_argument("live_log", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.command == "prepare":
        prepare(args.split, args.artifact, args.output)
    elif args.command == "calibrate":
        calibrate(args.development, args.provenance, args.policy)
    elif args.command == "apply":
        apply_selection(args.split, args.artifact, args.manifest, args.directory, args.policy)
    elif args.command == "report":
        report(args.root, args.provenance, args.policy, args.json, args.markdown, args.live_log)
    else:
        parser.error("a command is required")


if __name__ == "__main__":
    main()
