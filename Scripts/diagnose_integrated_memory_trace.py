#!/usr/bin/env python3
"""Diagnose #106 memory pressure from frozen native traces; never loads a model."""

from __future__ import annotations

import argparse
import gzip
import json
import math
from pathlib import Path


DEFAULT_RUNS = (
    Path("docs/japanese-live/experiments/evidence/E31-12b-pressure-attempt"),
    Path("docs/japanese-live/experiments/evidence/E31-4b-pressure-attempt"),
)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def read_samples(path: Path) -> list[dict]:
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if '"phase":"running"' in line]


def nearest(samples: list[dict], elapsed: int) -> dict:
    return min(samples, key=lambda sample: abs(sample["elapsedSeconds"] - elapsed))


def correlation(left: list[float], right: list[float]) -> float:
    left_mean, right_mean = sum(left) / len(left), sum(right) / len(right)
    numerator = sum((x - left_mean) * (y - right_mean) for x, y in zip(left, right))
    denominator = math.sqrt(
        sum((x - left_mean) ** 2 for x in left)
        * sum((y - right_mean) ** 2 for y in right)
    )
    return numerator / denominator if denominator else 0


def sampled(event: dict, samples: list[dict]) -> dict:
    sample = nearest(samples, event["elapsedSeconds"])
    return {
        **event,
        "sampleAt": sample["at"],
        "residentBytes": sample["residentBytes"],
        "physicalFootprintBytes": sample["physicalFootprintBytes"],
        "freeMemoryPercent": sample["freeMemoryPercent"],
        "nativePressureRaw": sample["nativePressureRaw"],
        "swapDeltaBytes": sample["swapUsedDeltaBytes"],
        "pageoutDelta": sample["pageoutDelta"],
    }


def diagnose(root: Path) -> dict:
    timeline, safety = read_json(root / "timeline.json"), read_json(root / "safety.json")
    samples = read_samples(root / "safety.samples.jsonl.gz")
    events = [sampled(event, samples) for event in timeline["events"]]
    for event in events:
        if event["kind"] != "translation-batch":
            continue
        response = read_json(root / "translation" / f'response-{event["index"]}.json')
        payload = response.get("exchange") or response.get("error") or {}
        event["workerReportedPeakBytes"] = payload.get("peakMemoryBytes")
    ready = next(event for event in events if event["kind"] == "translategemma-ready")
    upstream = next(event for event in events if event["kind"] == "speakerkit-complete")
    batches = [event for event in events
               if event["kind"] == "translation-batch" and event["status"] == "completed"]
    terminal = events[-1]
    batch_correlation = correlation(
        [event["index"] for event in batches],
        [event["physicalFootprintBytes"] for event in batches],
    )
    correlated_growth = (
        safety["stopReason"].startswith("native-pressure-")
        and batch_correlation >= 0.9
        and terminal["physicalFootprintBytes"] > ready["physicalFootprintBytes"]
    )
    physical_memory = (
        safety["catastrophicGuard"]["limitBytes"] * 100
        // safety["catastrophicGuard"]["limitPercent"]
    )
    footprint_growth = terminal["physicalFootprintBytes"] - ready["physicalFootprintBytes"]
    free_delta = terminal["freeMemoryPercent"] - ready["freeMemoryPercent"]
    footprint_explained_free_delta = -100 * footprint_growth / physical_memory
    failures = []
    if not timeline["upstreamWorkerExitAndCacheReleaseEventsPresent"]:
        failures.append("UPSTREAM_UNLOAD_RELEASE_UNPROVEN")
    if correlated_growth:
        failures.append("BATCH_CORRELATED_FOOTPRINT_GROWTH_TO_NATIVE_WARNING")
    if timeline["measurementPolicy"]["externalProcesses"] == "not sampled":
        failures.append("EXTERNAL_PROCESS_ATTRIBUTION_UNAVAILABLE")
    return {
        "run": timeline["run"],
        "verdict": "RED" if failures else "GREEN",
        "failures": failures,
        "measurementPolicy": timeline["measurementPolicy"],
        "upstreamHandoff": {
            "shutdownMarkersPresent": timeline["upstreamShutdownMarkersPresent"],
            "workerExitAndCacheReleaseEventsPresent": timeline[
                "upstreamWorkerExitAndCacheReleaseEventsPresent"
            ],
            "speakerKitComplete": upstream,
            "translateGemmaReady": ready,
        },
        "postReady": {
            "completedBatches": len(batches),
            "batchFootprintCorrelation": batch_correlation,
            "footprintGrowthBytes": footprint_growth,
            "residentGrowthBytes": terminal["residentBytes"] - ready["residentBytes"],
            "terminalWorkerReportedPeakBytes": terminal.get("workerReportedPeakBytes"),
            "terminalFootprintMinusWorkerReportedPeakBytes": (
                terminal["physicalFootprintBytes"]
                - (terminal.get("workerReportedPeakBytes") or 0)
            ),
            "freeMemoryDeltaPoints": free_delta,
            "freeDeltaExplainedByFootprintPoints": footprint_explained_free_delta,
            "unexplainedFreeDeltaPoints": free_delta - footprint_explained_free_delta,
            "swapDeltaBytes": terminal["swapDeltaBytes"] - ready["swapDeltaBytes"],
            "pageoutDelta": terminal["pageoutDelta"] - ready["pageoutDelta"],
            "terminalPressureRaw": terminal["nativePressureRaw"],
        },
        "events": events,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runs", nargs="*", type=Path, default=DEFAULT_RUNS)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert correlation([1, 2, 3], [10, 20, 30]) == 1
        assert nearest([{"elapsedSeconds": 1}, {"elapsedSeconds": 4}], 3)[
            "elapsedSeconds"
        ] == 4
        return 0
    report = {
        "schemaVersion": 1,
        "ticket": 106,
        "modelLoaded": False,
        "runs": [diagnose(root) for root in args.runs],
    }
    report["verdict"] = "RED" if any(run["failures"] for run in report["runs"]) else "GREEN"
    output = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    print(output, end="")
    return report["verdict"] == "RED"


if __name__ == "__main__":
    raise SystemExit(main())
