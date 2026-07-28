#!/usr/bin/env python3
"""Compare the real-time Voxtral session-rotation runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


def last_annotated_end(root: Path, corpus: str, turn_id: int) -> int:
    manifest = load(root / "docs/japanese-live/corpora" / corpus / "manifest.json")
    turn = next(
        item for item in manifest["annotations"]["turns"]
        if item["id"] == turn_id
    )
    return int(turn["endSample"])


def final_source_latencies(session: dict) -> list[float]:
    boundaries = {
        int(item["endSample"]): item
        for item in (session.get("voxtralEvidence") or {}).get("boundaries", [])
    }
    result = []
    for event in session["finalTranslationEvents"]:
        boundary = boundaries.get(int(event["sourceEndSample"]))
        if event.get("error") is not None or boundary is None:
            continue
        result.append(
            float(event["endpointToAcceptedMilliseconds"])
            + max(
                0,
                int(boundary["detectedAtSample"]) - int(boundary["endSample"]),
            ) / 16
        )
    return result


def longest_seam_overlap(left: str, right: str) -> int:
    for length in range(min(len(left), len(right)), 0, -1):
        if left[-length:] == right[:length]:
            return length
    return 0


def session_row(
    root: Path,
    run_id: str,
    source_tree_sha256: str,
    session: dict,
    baseline_cer: dict[str, float],
) -> dict:
    corpus = session["corpusID"]
    evidence = session["voxtralEvidence"]
    rotations = evidence["sessions"]
    final_latencies = final_source_latencies(session)
    preview = session["previewFirstLatencyMilliseconds"]
    final_count = len(session["fragments"])
    final_p95 = percentile(final_latencies, 0.95)
    annotated_end = last_annotated_end(
        root,
        corpus,
        int(session["lastSpeech"]["turnID"]),
    )
    contiguous = (
        rotations[0]["startSample"] == session["windowStartSample"]
        and rotations[-1]["endSample"] == session["windowEndSample"]
        and all(
            left["endSample"] == right["startSample"]
            for left, right in zip(rotations, rotations[1:])
        )
    )
    seam_overlaps = [
        longest_seam_overlap(
            str(left.get("transcriptSuffix") or ""),
            str(right.get("transcriptPrefix") or ""),
        )
        for left, right in zip(rotations, rotations[1:])
        if "transcriptSuffix" in left and "transcriptPrefix" in right
    ]
    per_session_proof = all(
        "normalizedTranscriptSHA256" in item
        and (
            not item.get("speechObserved")
            or int(item["normalizedTranscriptCharacterCount"]) > 0
        )
        for item in rotations
    )
    technical_screening = (
        not session["errors"]
        and session["lastSpeech"]["heuristicPresent"]
        and session["expectedSampleCount"] == session["asrFedSampleCount"]
        and session["expectedSampleCount"] == session["pcmAnalyzedThrough"]
        and session["expectedSampleCount"] == session["asrFinalizedThrough"]
        and session["unaccountedSampleCount"] == 0
        and session["endingBacklogMilliseconds"] == 0
        and session["confirmedPrefixRewriteCount"] == 0
        and session["finalTranslationsAppendOnly"]
        and session["englishValidatedThrough"] >= annotated_end
        and session["continuousCER"]["overall"]["rate"]
            <= baseline_cer[corpus] + 0.02
        and not session["criticalTerms"]["missing"]
        and session["maximumResidentBytes"] < 10 * 1024**3
        and contiguous
        and len({item["helperProcessIdentifier"] for item in rotations}) == 1
        and all(
            item["acknowledgedThroughSample"] == item["endSample"]
            and (
                item.get("deferralSamples") is None
                or 0 <= item["deferralSamples"] <= 60 * 16_000
            )
            and item["captureEnded"] == (index == len(rotations) - 1)
            for index, item in enumerate(rotations)
        )
        and final_p95 is not None
        and final_p95 <= 1_500
    )
    coverage = (
        100 * len(session["previewSourceFirstLatencyMilliseconds"]) / final_count
        if final_count else 0
    )
    preview_p50 = percentile(preview, 0.50)
    preview_p95 = percentile(preview, 0.95)
    preview_worst = max(preview, default=None)
    return {
        "runID": run_id,
        "sourceTreeSHA256": source_tree_sha256,
        "corpusID": corpus,
        "replay": session["replay"],
        "cer": session["continuousCER"]["overall"]["rate"],
        "baselineCER": baseline_cer[corpus],
        "lastSpeechPresent": session["lastSpeech"]["heuristicPresent"],
        "annotatedTailCoveredSamples":
            session["englishValidatedThrough"] - annotated_end,
        "unclassifiedVADTailSamples": max(
            0,
            int(evidence["lastVADSpeechEndSample"])
                - int(session["englishValidatedThrough"]),
        ),
        "previewCoveragePercent": coverage,
        "previewP50Milliseconds": preview_p50,
        "previewP95Milliseconds": preview_p95,
        "previewWorstMilliseconds": preview_worst,
        "finalP95Milliseconds": final_p95,
        "finalWorstMilliseconds": max(final_latencies, default=None),
        "maximumResidentBytes": session["maximumResidentBytes"],
        "maximumBacklogMilliseconds": session["maximumBacklogMilliseconds"],
        "endingBacklogMilliseconds": session["endingBacklogMilliseconds"],
        "rotationEnds": [item["endSample"] for item in rotations],
        "rotationFlushMilliseconds": [
            item["flushMilliseconds"] for item in rotations
        ],
        "perSessionProofComplete": per_session_proof,
        "perSessionTranscriptSHA256": [
            item.get("normalizedTranscriptSHA256") for item in rotations
        ],
        "maximumSeamOverlapCharacters": max(seam_overlaps, default=0),
        "normalizedFinalSHA256": session["normalizedFinalSHA256"],
        "technicalScreeningPassed": technical_screening,
        "instrumentedSeamProofPassed": (
            per_session_proof
            and all(overlap < 5 for overlap in seam_overlaps)
        ),
        "previewGatePassed": (
            coverage >= 95
            and preview_p50 is not None
            and preview_p50 <= 1_000
            and preview_p95 is not None
            and preview_p95 <= 1_800
            and preview_worst is not None
            and preview_worst <= 3_000
        ),
    }


def build(root: Path, baseline_path: Path, candidate_paths: list[Path]) -> dict:
    baseline = load(baseline_path)
    baseline_cer = {
        item["corpusID"]: item["continuousCER"]["overall"]["rate"]
        for item in baseline["sessions"]
        if item["recipeID"] == "voxtral-q4-continuous-960ms"
    }
    by_target: dict[int, list[tuple[dict, dict]]] = defaultdict(list)
    provenance = []
    seen_sessions = set()
    expected_corpora = None
    expected_runtime = None
    expected_recipes = None
    expected_models = None
    for path in candidate_paths:
        report = load(path)
        if not report["networkDenied"]:
            raise ValueError(f"Network was not denied for {path}.")
        if expected_runtime is None:
            expected_runtime = report["runtimeSHA256"]
            expected_recipes = report["modelRecipesSHA256"]
        elif (
            report["runtimeSHA256"] != expected_runtime
            or report["modelRecipesSHA256"] != expected_recipes
        ):
            raise ValueError(f"Runtime or recipe provenance differs for {path}.")
        corpus_signature = {
            (
                item["corpusID"],
                item["audioSHA256"],
                item["manifestSHA256"],
            )
            for item in report["corpora"]
        }
        model_signature = {
            (item["modelID"], item["artifactSHA256"])
            for item in report["models"]
        }
        if expected_corpora is None:
            expected_corpora = corpus_signature
            expected_models = model_signature
        elif corpus_signature != expected_corpora:
            raise ValueError(f"Corpus provenance differs for {path}.")
        elif model_signature != expected_models:
            raise ValueError(f"Model provenance differs for {path}.")
        provenance.append({
            "path": str(path),
            "sha256": sha256(path),
            "gitCommit": report["gitCommit"],
            "sourceTreeSHA256": report["sourceTreeSHA256"],
            "runtimeSHA256": report["runtimeSHA256"],
        })
        for session in report["sessions"]:
            match = re.fullmatch(
                r"voxtral-q4-continuous-960ms-rotation-(\d+)s",
                session["recipeID"],
            )
            if match:
                identity = (
                    report["runID"],
                    session["corpusID"],
                    int(session["replay"]),
                    session["recipeID"],
                )
                if identity in seen_sessions:
                    continue
                seen_sessions.add(identity)
                by_target[int(match.group(1))].append(
                    (
                        session,
                        session_row(
                            root,
                            report["runID"],
                            report["sourceTreeSHA256"],
                            session,
                            baseline_cer,
                        ),
                    )
                )
    if set(by_target) != {240, 480, 720}:
        raise ValueError("L8B2 requires the 240, 480 and 720-second candidates.")
    expected_corpus_ids = set(baseline_cer)
    for target, pairs in by_target.items():
        if {session["corpusID"] for session, _ in pairs} != expected_corpus_ids:
            raise ValueError(f"Candidate {target}s does not cover every corpus.")

    candidates = []
    for target, pairs in sorted(by_target.items()):
        sessions = [item[0] for item in pairs]
        rows = [item[1] for item in pairs]
        overall = [item["continuousCER"]["overall"] for item in sessions]
        weighted_cer = sum(item["editDistance"] for item in overall) / sum(
            item["referenceCharacterCount"] for item in overall
        )
        candidates.append({
            "targetSeconds": target,
            "weightedCER": weighted_cer,
            "technicalScreeningPassed": all(
                item["technicalScreeningPassed"] for item in rows
            ),
            "previewGatePassed": all(item["previewGatePassed"] for item in rows),
            "corpora": rows,
        })

    eligible = [
        item for item in candidates if item["technicalScreeningPassed"]
    ]
    if not eligible:
        winner = None
    else:
        best_cer = min(item["weightedCER"] for item in eligible)
        winner = max(
            (
                item for item in eligible
                if item["weightedCER"] <= best_cer + 0.01
            ),
            key=lambda item: item["targetSeconds"],
        )

    confirmation_passed = False
    if winner:
        rows = winner["corpora"]
        grouped = defaultdict(list)
        for row in rows:
            grouped[row["corpusID"]].append(row)
        confirmation_passed = (
            all(len(items) >= 3 for items in grouped.values())
            and all(
                len({item["normalizedFinalSHA256"] for item in items}) == 1
                and len({tuple(item["rotationEnds"]) for item in items}) == 1
                and len({
                    tuple(item["perSessionTranscriptSHA256"])
                    for item in items if item["perSessionProofComplete"]
                }) == 1
                and len({
                    item["sourceTreeSHA256"]
                    for item in items if item["perSessionProofComplete"]
                }) == 1
                and sum(item["perSessionProofComplete"] for item in items) >= 2
                and all(
                    item["instrumentedSeamProofPassed"]
                    for item in items if item["perSessionProofComplete"]
                )
                for items in grouped.values()
            )
        )

    return {
        "schemaVersion": 1,
        "lot": "L8B2",
        "baselineReportSHA256": sha256(baseline_path),
        "reportGeneratorSHA256": sha256(Path(__file__)),
        "provenance": provenance,
        "candidates": candidates,
        "provisionalWinnerSeconds":
            winner["targetSeconds"] if winner else None,
        "confirmationPassed": confirmation_passed,
        "qualityPromotionBlockedByHumanReview": True,
        "note": (
            "L8B2 selects session rotation only. Preview remains a separate "
            "failing gate and must be corrected before product promotion."
        ),
    }


def report_fr(result: dict) -> str:
    def maximum(rows: list[dict], key: str) -> float | None:
        return max(
            (row[key] for row in rows if row[key] is not None),
            default=None,
        )

    def milliseconds(value: float | None) -> str:
        return f"{value:.0f} ms" if value is not None else "n/a"

    lines = [
        "# L8B2 — rotation Voxtral",
        "",
        "| Rotation | CER pondéré | Dernière parole | Preview p95 | Final p95 | RSS max | Screening technique |",
        "|---:|---:|---|---:|---:|---:|---|",
    ]
    for candidate in result["candidates"]:
        rows = candidate["corpora"]
        lines.append(
            f"| {candidate['targetSeconds']} s | "
            f"{100 * candidate['weightedCER']:.2f} % | "
            f"{sum(row['lastSpeechPresent'] for row in rows)}/{len(rows)} | "
            f"{milliseconds(maximum(rows, 'previewP95Milliseconds'))} | "
            f"{milliseconds(maximum(rows, 'finalP95Milliseconds'))} | "
            f"{max(row['maximumResidentBytes'] for row in rows) / 2**30:.2f} Gio | "
            f"{'passé' if candidate['technicalScreeningPassed'] else 'échoué'} |"
        )
    winner = result["provisionalWinnerSeconds"]
    lines += [
        "",
        f"Gagnant provisoire : **{winner} s**." if winner else "Aucun gagnant.",
        "Confirmation (1 screening + 2 replays instrumentés) : "
        f"**{'passée' if result['confirmationPassed'] else 'en attente'}**.",
        "",
        "La preview reste hors SLO et n'est pas masquée par cette décision. "
        "La queue VAD non annotée reste diagnostique tant que les références "
        "sont `pending-human-review`.",
    ]
    return "\n".join(lines) + "\n"


def self_test() -> None:
    assert longest_seam_overlap("abcdef", "defghi") == 3
    assert longest_seam_overlap("abc", "xyz") == 0
    assert percentile([], 0.95) is None
    assert percentile([1, 2, 3, 4, 5], 0.95) == 5


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--candidate", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.baseline or not args.candidate or not args.output:
        parser.error("--baseline, --candidate and --output are required")
    result = build(args.root, args.baseline, args.candidate)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "comparison.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (args.output / "report-fr.md").write_text(
        report_fr(result),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
