#!/usr/bin/env python3
"""Validate and summarize the complete L7B replay matrix."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

from source_tree_provenance import snapshot

NATIVE_CANDIDATES = {
    "whisper-large-v3-turbo",
    "mlx-whisper-large-v3-turbo",
    "voxtral-q4-continuous-960ms",
    "nemotron-multilingual-coreml-1120ms",
    "nemotron-multilingual-coreml-560ms",
    "kotoba-whisper-v2.0-q5",
    "qwen3-asr-1.7b",
    "whispermlx-v3.12.2-turbo",
}
WINDOWS = {"qudu-fast-1", "qudu-fast-2", "md62-dialogue-1", "md62-dialogue-2"}


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exact_keys(actual: list[tuple], expected: set[tuple]) -> bool:
    return len(actual) == len(expected) and len(set(actual)) == len(actual) and set(actual) == expected


def corpus_signature(report: dict) -> tuple[tuple[str | None, ...], ...]:
    return tuple(sorted(
        (
            corpus.get("corpusID"),
            corpus.get("manifestSHA256"),
            corpus.get("audioSHA256"),
            corpus.get("annotationStatus"),
        )
        for corpus in report.get("corpora", [])
    ))


def wlk_configuration_matches(report: dict, policy: str) -> bool:
    expected = {
        "backendPolicy": policy,
        "backend": "mlx-whisper",
        "model": "large-v3-turbo",
        "language": "ja",
        "mode": "diff",
        "retentionSeconds": "300",
        "transportBlockSamples": "1600",
        "minChunkSeconds": "0.1",
        "pcmInput": "s16le-16k-mono",
    }
    configuration = report.get("whisperLiveKitConfiguration", {})
    return all(configuration.get(key) == value for key, value in expected.items())


def self_test() -> None:
    expected = {("a", 1), ("b", 1)}
    assert exact_keys([("a", 1), ("b", 1)], expected)
    assert not exact_keys([("a", 1)], expected)
    assert not exact_keys([("a", 1), ("a", 1)], expected)
    assert not exact_keys([("a", 1), ("b", 2)], expected)
    assert complete_percentile([0.1, 0.2], 2, 0.5) == 0.1
    assert complete_percentile([0.1], 2, 0.5) is None


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def complete_percentile(
    values: list[float], expected_count: int, fraction: float
) -> float | None:
    return percentile(values, fraction) if len(values) == expected_count else None


def milliseconds(value: float | None) -> str:
    return "—" if value is None else f"{value:.0f} ms"


def percent(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.1f} %"


def native_rows(report: dict) -> list[dict]:
    groups: dict[str, list[dict]] = defaultdict(list)
    for session in report["sessions"]:
        groups[session["recipeID"]].append(session)
    rows = []
    for candidate, sessions in groups.items():
        high_lower = [
            session["continuousCER"]["highConfidence"]["rateLowerBound"]
            for session in sessions
            if session.get("continuousCER")
        ]
        high_upper = [
            session["continuousCER"]["highConfidence"]["rateUpperBound"]
            for session in sessions
            if session.get("continuousCER")
        ]
        diagnostic = [
            session["continuousCER"]["diagnostic"].get("rateUpperBound")
            for session in sessions
            if session.get("continuousCER")
            and session["continuousCER"]["diagnostic"].get("rateUpperBound") is not None
        ]
        cer_session_count = min(len(high_lower), len(high_upper))
        finals = [
            value
            for session in sessions
            for value in session.get("finalLatencyMilliseconds", [])
        ]
        errors = sum(bool(session.get("errors")) for session in sessions)
        complete = sum(
            not session.get("errors")
            and bool(session.get("japaneseFinal"))
            and session.get("asrFinalizedThrough") == session.get("windowEndSample")
            for session in sessions
        )
        rows.append({
            "candidate": candidate,
            "sessions": len(sessions),
            "completeSessions": complete,
            "errorSessions": errors,
            "cerSessionCount": cer_session_count,
            "diagnosticCERSessionCount": len(diagnostic),
            "highCERMedianLower": complete_percentile(high_lower, len(sessions), 0.5),
            "highCERMedianUpper": complete_percentile(high_upper, len(sessions), 0.5),
            "diagnosticCERMedian": percentile(diagnostic, 0.5),
            "finalLatencyP95Milliseconds": percentile(finals, 0.95),
            "finalLatencyScope": ", ".join(sorted({
                session.get("finalLatencyScope", "unknown") for session in sessions
            })),
            "maximumResidentBytes": max(
                (session.get("maximumResidentBytes") or 0 for session in sessions),
                default=0,
            ),
        })
    return rows


def wlk_row(report: dict) -> dict:
    sessions = report["sessions"]
    policy = report["whisperLiveKitConfiguration"]["backendPolicy"]
    high_lower = [
        session["highConfidenceCERLowerBound"]
        for session in sessions
        if session.get("highConfidenceCERLowerBound") is not None
    ]
    high_upper = [
        session["highConfidenceCERUpperBound"]
        for session in sessions
        if session.get("highConfidenceCERUpperBound") is not None
    ]
    diagnostic = [session["japaneseCER"] for session in sessions if session.get("japaneseCER") is not None]
    cer_session_count = min(len(high_lower), len(high_upper))
    finals = [
        value
        for session in sessions
        for value in session.get("finalEndpointLatencyMilliseconds", [])
    ]
    errors = sum(bool(session.get("errors")) for session in sessions)
    complete = sum(
        not session.get("errors")
        and bool(session.get("japaneseFinal"))
        and session.get("sentSampleCount") == session.get("expectedSampleCount")
        and session.get("readyToStopReceived") is True
        for session in sessions
    )
    return {
        "candidate": f"whisperlivekit-{policy}",
        "sessions": len(sessions),
        "completeSessions": complete,
        "errorSessions": errors,
        "cerSessionCount": cer_session_count,
        "diagnosticCERSessionCount": len(diagnostic),
        "highCERMedianLower": complete_percentile(high_lower, len(sessions), 0.5),
        "highCERMedianUpper": complete_percentile(high_upper, len(sessions), 0.5),
        "diagnosticCERMedian": percentile(diagnostic, 0.5),
        "finalLatencyP95Milliseconds": percentile(finals, 0.95),
        "finalLatencyScope": "capture-eos-final-after-window-end",
        "maximumResidentBytes": max(
            (session.get("maximumObservedResidentBytes") or 0 for session in sessions),
            default=0,
        ),
    }


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--simulstreaming", type=Path, required=True)
    parser.add_argument("--localagreement", type=Path, required=True)
    parser.add_argument("--recipes", type=Path, required=True)
    parser.add_argument("--source-provenance", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--runtime-provenance", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    native = load(args.native)
    simul = load(args.simulstreaming)
    local = load(args.localagreement)
    reports = [native, simul, local]
    provenance = load(args.source_provenance)
    runtime_provenance = load(args.runtime_provenance)
    current_tree_sha = snapshot(args.source_root.resolve())["treeSHA256"]
    expected_sha = hashlib.sha256(args.recipes.read_bytes()).hexdigest()
    recipe_shas = {report.get("modelRecipesSHA256") for report in reports}
    commits = {report.get("gitCommit") for report in reports}
    source_tree_shas = {report.get("sourceTreeSHA256") for report in reports}
    runtime_shas = {report.get("runtimeSHA256") for report in reports}
    worktree_states = {report.get("worktreeDirty") for report in reports}
    offline_validated = (
        native.get("networkDenied") is True
        and simul.get("remoteNetworkDeniedForXCTest") is True
        and local.get("remoteNetworkDeniedForXCTest") is True
    )
    corpora_consistent = len({corpus_signature(report) for report in reports}) == 1
    native_keys = [
        (session.get("recipeID"), session.get("windowID"), session.get("replay"))
        for session in native.get("sessions", [])
    ]
    expected_native_keys = {
        (candidate, window, replay)
        for candidate in NATIVE_CANDIDATES
        for window in WINDOWS
        for replay in range(1, 4)
    }

    def live_keys(report: dict) -> list[tuple[str | None, int | None]]:
        return [
            (session.get("windowID"), session.get("replay"))
            for session in report.get("sessions", [])
        ]

    expected_live_keys = {(window, replay) for window in WINDOWS for replay in range(1, 4)}
    simul_keys = live_keys(simul)
    local_keys = live_keys(local)
    attempted = (
        native.get("matrixAttempted") is True
        and simul.get("matrixAttempted") is True
        and local.get("matrixAttempted") is True
        and len(native.get("sessions", [])) == 96
        and len(simul.get("sessions", [])) == 12
        and len(local.get("sessions", [])) == 12
        and exact_keys(native_keys, expected_native_keys)
        and exact_keys(simul_keys, expected_live_keys)
        and exact_keys(local_keys, expected_live_keys)
        and recipe_shas == {expected_sha}
        and source_tree_shas == {provenance.get("treeSHA256")}
        and runtime_shas == {runtime_provenance.get("runtimeSHA256")}
        and runtime_provenance.get("valid") is True
        and current_tree_sha == provenance.get("treeSHA256")
        and len(commits) == 1
        and worktree_states == {False}
        and offline_validated
        and corpora_consistent
        and wlk_configuration_matches(simul, "simulstreaming")
        and wlk_configuration_matches(local, "localagreement")
    )
    rows = sorted(native_rows(native) + [wlk_row(simul), wlk_row(local)], key=lambda row: row["candidate"])
    all_cer_scored = all(row["cerSessionCount"] == row["sessions"] for row in rows)
    aggregate = {
        "schemaVersion": 2,
        "lot": "L7B",
        "gitCommit": next(iter(commits)) if len(commits) == 1 else None,
        "modelRecipesSHA256": expected_sha,
        "sourceTreeSHA256": provenance.get("treeSHA256"),
        "sourceProvenanceSHA256": sha256(args.source_provenance),
        "runtimeSHA256": runtime_provenance.get("runtimeSHA256"),
        "runtimeProvenanceSHA256": sha256(args.runtime_provenance),
        "worktreeClean": worktree_states == {False},
        "offlineValidated": offline_validated,
        "corporaConsistent": corpora_consistent,
        "allCERScored": all_cer_scored,
        "matrixAttempted": attempted,
        "matrixComplete": attempted
        and all_cer_scored
        and all(report.get("matrixComplete") is True for report in reports),
        "sessionCount": sum(len(report.get("sessions", [])) for report in reports),
        "expectedSessionCount": 120,
        "reports": [
            {"path": str(path), "sha256": sha256(path)}
            for path in (args.native, args.simulstreaming, args.localagreement)
        ],
        "candidates": rows,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "comparison.json").write_text(
        json.dumps(aggregate, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# L7B — replays corrigés",
        "",
        f"Matrice tentée : **{'oui' if attempted else 'non'}** — {aggregate['sessionCount']}/120 sessions.",
        f"Matrice sans erreur : **{'oui' if aggregate['matrixComplete'] else 'non'}**.",
        "",
        "| Candidat | Sessions valides | CER scorés | CER high médian | CER diagnostic médian (n) | Final p95 (scope) | RSS max |",
        "| --- | ---: | ---: | ---: | ---: | --- | ---: |",
    ]
    for row in rows:
        rss = row["maximumResidentBytes"] / (1024 ** 3)
        cer_range = "—" if row["highCERMedianLower"] is None else (
            f"{percent(row['highCERMedianLower'])}–{percent(row['highCERMedianUpper'])}"
        )
        lines.append(
            f"| {row['candidate']} | {row['completeSessions']}/{row['sessions']} | "
            f"{row['cerSessionCount']}/{row['sessions']} | "
            f"{cer_range} | "
            f"{percent(row['diagnosticCERMedian'])} ({row['diagnosticCERSessionCount']}) | "
            f"{milliseconds(row['finalLatencyP95Milliseconds'])} ({row['finalLatencyScope']}) | "
            f"{rss:.2f} Gio |"
        )
    (args.output / "report-fr.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if not attempted:
        raise SystemExit("L7B matrix was not fully attempted or provenance did not match")


if __name__ == "__main__":
    main()
