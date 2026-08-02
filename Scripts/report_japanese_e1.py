#!/usr/bin/env python3
"""Summarize the public E1 qwenApple benchmark artifacts."""

import argparse
import json
import math
from pathlib import Path


def distribution(values: list[float]) -> dict:
    values = sorted(values)
    if not values:
        return {"count": 0, "p50": None, "p95": None, "worst": None}

    def percentile(percent: float) -> float:
        return values[max(0, math.ceil(len(values) * percent) - 1)]

    return {
        "count": len(values),
        "p50": percentile(0.50),
        "p95": percentile(0.95),
        "worst": values[-1],
    }


def erased_characters(publications: list[dict]) -> int:
    erased = 0
    previous = ""
    for publication in sorted(publications, key=lambda item: item["renderedUptimeNanoseconds"]):
        current = publication.get("englishText", "").strip()
        common = 0
        for left, right in zip(previous, current):
            if left != right:
                break
            common += 1
        erased += len(previous) - common
        previous = current
    return erased


def summarize_session(metrics: list[dict], session: dict) -> dict:
    finals = sorted(
        (item for item in metrics if item.get("kind") == "final"),
        key=lambda item: item["finalSegmentIndex"],
    )
    previews: dict[int, list[dict]] = {}
    for item in metrics:
        if item.get("kind") == "preview" and item.get("previewGeneration") is not None:
            previews.setdefault(item["previewGeneration"], []).append(item)

    endpoint = [(item["endpointDetectedAt"] - item["speechEnd"]) / 16 for item in finals]
    queue = [item["queueMilliseconds"] for item in finals]
    asr = [item["asrMilliseconds"] for item in finals]
    translation = [item["translationMilliseconds"] for item in finals]
    total = [item["speechEndToRenderedMilliseconds"] for item in finals]
    render = [max(0, total[i] - endpoint[i] - queue[i] - asr[i] - translation[i]) for i in range(len(finals))]
    first_text = [
        min(items, key=lambda item: item["renderedUptimeNanoseconds"])["previewLatencyMilliseconds"]
        for items in previews.values()
    ]
    audio_age = [
        item["speechEndToRenderedMilliseconds"]
        for items in previews.values()
        for item in items
    ]
    erased = sum(erased_characters(items) for items in previews.values())
    emitted = sum(
        len(item.get("englishText", "").strip())
        for items in previews.values()
        for item in items
    )
    resources = session.get("resourceSamples", [])
    energies = [item.get("processEnergyNanojoules") for item in resources]
    energies = [value for value in energies if value is not None]
    summary = session.get("summary", {})
    missing_finals = summary.get("endingTranslationQueueCount", 0)
    phrase_count = len(finals) + missing_finals
    timing = summary.get("captureTiming") or {}
    final_indices = [item["finalSegmentIndex"] for item in finals]
    integrity = {
        "appendOnlyFinalIndices": final_indices == list(range(len(final_indices))),
        "pcmComplete": summary.get("pcmComplete") is True,
        "droppedSamples": summary.get("m4aDroppedSampleCount", 0),
        "committedMatchesSource": summary.get("committedSampleCount")
        == summary.get("sourceFinalizedThrough"),
        "endingEndpointFIFOCount": summary.get("endingEndpointFIFOCount", 0),
        "endingTranslationQueueCount": summary.get("endingTranslationQueueCount", 0),
        "captureDiscontinuities": sum(
            timing.get(key, 0)
            for key in ("gapCount", "overlapCount", "restartCount", "invalidPresentationTimestampCount")
        ),
        "pipelineFailure": summary.get("sourcePipelineFailure") or summary.get("completionFailure"),
    }
    integrity["pass"] = (
        integrity["appendOnlyFinalIndices"]
        and integrity["pcmComplete"]
        and integrity["droppedSamples"] == 0
        and integrity["committedMatchesSource"]
        and integrity["endingEndpointFIFOCount"] == 0
        and integrity["endingTranslationQueueCount"] == 0
        and integrity["captureDiscontinuities"] == 0
        and integrity["pipelineFailure"] is None
    )
    thermal_rank = {"nominal": 0, "fair": 1, "serious": 2, "critical": 3, "unknown": 4}
    thermal = [item.get("thermalState", "unknown") for item in resources]
    return {
        "phraseCount": phrase_count,
        "missingFinalPhraseCount": missing_finals,
        "previewCoveredPhraseCount": len(set(previews).intersection(final_indices)),
        "previewCoveragePercent": 100 * len(set(previews).intersection(range(phrase_count))) / phrase_count if phrase_count else 0,
        "firstTextMilliseconds": distribution(first_text),
        "previewAudioAgeMilliseconds": distribution(audio_age),
        "revisionCount": sum(max(0, len(items) - 1) for items in previews.values()),
        "erasedCharacters": erased,
        "normalizedErasurePercent": 100 * erased / emitted if emitted else 0,
        "finalEndpointMilliseconds": distribution(endpoint),
        "finalQueueMilliseconds": distribution(queue),
        "finalASRMilliseconds": distribution(asr),
        "finalTranslationMilliseconds": distribution(translation),
        "finalRenderMilliseconds": distribution(render),
        "finalTotalMilliseconds": distribution(total),
        "integrity": integrity,
        "maximumResidentBytes": session.get("maximumCombinedResidentBytes", 0),
        "maximumHelperBacklogSamples": session.get("maximumHelperBacklogSamples", 0),
        "maximumEndpointFIFOCount": session.get("maximumEndpointFIFOCount", 0),
        "energyJoules": (max(energies) - min(energies)) / 1_000_000_000 if len(energies) >= 2 else None,
        "maximumThermalState": max(thermal, key=lambda value: thermal_rank[value]) if thermal else None,
    }


def summarize_index(index_path: Path) -> dict:
    index = json.loads(index_path.read_text())
    runs = []
    for run in index["runs"]:
        session_path = (index_path.parent / run["session"]).resolve()
        session = json.loads(session_path.read_text())
        metrics = json.loads((session_path.parent / session["metricsFile"]).read_text())
        result = {key: run[key] for key in ("corpus", "regime", "repetition")}
        result["session"] = str(session_path)
        result["metrics"] = summarize_session(metrics, session)
        if run.get("evaluation"):
            evaluation = json.loads((index_path.parent / run["evaluation"]).resolve().read_text())
            result["evaluation"] = {
                "status": evaluation.get("status"),
                "highConfidenceCER": evaluation.get("productionJapaneseCER", {}).get("highConfidence"),
                "lastSpeech": evaluation.get("lastSpeech"),
                "runtimeSLO": evaluation.get("runtime", {}).get("slo"),
            }
        runs.append(result)
    return {"schemaVersion": 1, "pipeline": "qwenApple", "runs": runs}


def self_test() -> None:
    metrics = [
        {"kind": "final", "finalSegmentIndex": 0, "speechEnd": 1_000, "endpointDetectedAt": 1_160, "speechEndToRenderedMilliseconds": 100, "queueMilliseconds": 10, "asrMilliseconds": 20, "translationMilliseconds": 30},
        {"kind": "final", "finalSegmentIndex": 1, "speechEnd": 2_000, "endpointDetectedAt": 2_160, "speechEndToRenderedMilliseconds": 120, "queueMilliseconds": 10, "asrMilliseconds": 20, "translationMilliseconds": 30},
        {"kind": "preview", "previewGeneration": 0, "renderedUptimeNanoseconds": 1, "previewLatencyMilliseconds": 80, "speechEndToRenderedMilliseconds": 15, "englishText": "hello"},
        {"kind": "preview", "previewGeneration": 0, "renderedUptimeNanoseconds": 2, "previewLatencyMilliseconds": 90, "speechEndToRenderedMilliseconds": 10, "englishText": "help"},
    ]
    session = {"maximumCombinedResidentBytes": 4_000, "resourceSamples": [
        {"processEnergyNanojoules": 1_000_000_000, "thermalState": "nominal"},
        {"processEnergyNanojoules": 3_000_000_000, "thermalState": "fair"},
    ], "summary": {}}
    summary = summarize_session(metrics, session)
    assert summary["previewCoveragePercent"] == 50
    assert summary["erasedCharacters"] == 2
    assert summary["energyJoules"] == 2
    assert summary["finalEndpointMilliseconds"]["p50"] == 10


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--index", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.index:
        parser.error("--index is required")
    report = summarize_index(args.index)
    encoded = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
