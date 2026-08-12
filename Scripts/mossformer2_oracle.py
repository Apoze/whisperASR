#!/usr/bin/env python3
"""Run ticket #102 with MossFormer2 on the frozen ticket #101 oracle inputs."""

from __future__ import annotations

import argparse
import gc
import importlib.metadata
import json
import os
import re
import resource
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import pixit_oracle as shared


TICKET = 102
CLEARVOICE_REPOSITORY = "modelscope/ClearerVoice-Studio"
CLEARVOICE_REVISION = "6b3774dc79c46ae8bed2a4fa5f706f0ac8c75c61"
CLEARVOICE_LICENSE = "Apache-2.0"
MODEL_ID = "alibabasglab/MossFormer2_SS_16K"
MODEL_REVISION = "407cb030cd66340918ebb6c8cc63b18f8592cdbe"
MODEL_LICENSE = "Apache-2.0"
MODEL_FILE = "last_best_checkpoint.pt"
MODEL_SIZE = 670_353_271
MODEL_SHA256 = "00a3a48bda492db1e829b85dd443f8f43a43039a3e90f1a24962ea9caf14a11a"
CHECKPOINT_MARKER_SHA256 = "315744c841441f8831cb2f896e06102b4d864776bf272febaa30c639c903e1c0"
PLAN_SHA256 = "7c8db9dd527302aa7d610621ce255ff702e50da8d11f806ea073e24ca8f9147c"
SHARED_SCORER_SHA256 = "ad497825c03b59154fedf4c2012d9ef89180140743238c7a4b301f632d114541"
PIXIT_REPORT_SHA256 = {
    "smoke": "38f47e9eba4e0a9c6a36fa6dab248e6efaef8353c15d0848b374da96d9fdc24c",
    "development": "a8b204189c300b73ea26a157bd5ffeb0ced700c7095277309a8f92472c57b9b9",
}
PIXIT_SEPARATOR_SHA256 = {
    "smoke": "0b4ad0f5277936f28fa14c6d28abd488d915d39280f40208645897dec1a5ca5a",
    "development": "d34d404c85c74f7781ead048a70c9572810846e7f49964f1f1b4c3b9c23d5e35",
}
RUNTIME_REQUIREMENTS = Path(__file__).with_name("mossformer2-oracle-requirements.txt")


def _runtime_versions() -> dict[str, str]:
    pins = dict(line.split("==", 1) for line in RUNTIME_REQUIREMENTS.read_text().splitlines())
    return {"clearvoice": "0.1.2", **pins}


def _source_matrix(value, expected_samples: int):
    import numpy as np

    outputs = np.asarray(value)
    if outputs.ndim == 3 and outputs.shape[1] == 1:
        outputs = outputs[:, 0, :]
    if outputs.ndim != 2 or outputs.shape[0] != 2:
        raise ValueError("MossFormer2 must produce exactly two sources")
    if outputs.shape[1] < expected_samples:
        raise ValueError("MossFormer2 source is shorter than its mixture")
    if not np.isfinite(outputs).all():
        raise ValueError("MossFormer2 source contains non-finite samples")
    return outputs[:, :expected_samples]


def _git_head(path: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _verify_runtime(source: Path, model: Path) -> dict[str, str]:
    if _git_head(source) != CLEARVOICE_REVISION:
        raise ValueError("ClearVoice source revision mismatch")
    if subprocess.run(
        ["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout:
        raise ValueError("ClearVoice source has tracked changes")
    if model.stat().st_size != MODEL_SIZE or shared.sha256(model) != MODEL_SHA256:
        raise ValueError("MossFormer2 weight mismatch")
    marker = model.with_name("last_best_checkpoint")
    if shared.sha256(marker) != CHECKPOINT_MARKER_SHA256:
        raise ValueError("MossFormer2 checkpoint marker mismatch")
    expected_versions = _runtime_versions()
    versions = {name: importlib.metadata.version(name) for name in expected_versions}
    if versions != expected_versions:
        raise ValueError(f"runtime version mismatch: {versions}")
    return versions


def _float_audio(samples):
    import numpy as np

    if samples.ndim != 1:
        raise ValueError("MossFormer2 input must be mono")
    if np.issubdtype(samples.dtype, np.integer):
        return samples.astype(np.float32) / max(abs(np.iinfo(samples.dtype).min), np.iinfo(samples.dtype).max)
    return samples.astype(np.float32)


def separate(args: argparse.Namespace) -> None:
    if os.environ.get("BENCHMARK_SLOT_GRANTED") != str(TICKET):
        raise ValueError("refusing heavyweight run without BENCHMARK_SLOT_GRANTED=102")
    if sys.version_info[:2] != (3, 11):
        raise ValueError("MossFormer2 runtime is pinned to Python 3.11")

    import numpy as np
    import scipy.io.wavfile

    plan_path = Path(args.plan).resolve()
    pixit_separator_path = Path(args.pixit_separator).resolve()
    source = Path(args.clearvoice_source).resolve()
    runtime_root = Path(args.runtime_root).resolve()
    runtime_freeze = runtime_root.parent / "python-freeze.txt"
    model_path = Path(args.model).resolve()
    output = Path(args.output).resolve()
    plan = json.loads(plan_path.read_text())
    pixit_separator = json.loads(pixit_separator_path.read_text())
    if shared.sha256(plan_path) != PLAN_SHA256:
        raise ValueError("ticket #101 plan hash mismatch")
    if shared.sha256(pixit_separator_path) != PIXIT_SEPARATOR_SHA256[args.stage]:
        raise ValueError("ticket #101 separator hash mismatch")
    if pixit_separator.get("ticket") != 101 or pixit_separator.get("stage") != args.stage:
        raise ValueError("wrong ticket #101 separator evidence")
    shared.verify_separator_plan(pixit_separator, plan_path)
    versions = _verify_runtime(source, model_path)
    if not runtime_freeze.is_file():
        raise ValueError("missing pinned runtime freeze")
    windows = plan["windows"]
    if args.window_id:
        windows = [window for window in windows if window["id"] == args.window_id]
        if len(windows) != 1:
            raise ValueError("unknown smoke window")
    elif args.stage != "development":
        raise ValueError("smoke must name exactly one window")
    if output.joinpath("separator-evidence.json").exists():
        raise ValueError("separator evidence already exists")
    output.mkdir(parents=True, exist_ok=True)

    mixtures = {
        record["windowID"]: record for record in pixit_separator["files"]
        if record["kind"] == "mixture"
    }
    started = datetime.now(timezone.utc)
    started_clock = time.monotonic()
    pressure_path = output / "native-memory-pressure.jsonl"
    pressure_stop = threading.Event()
    pressure_thread = threading.Thread(
        target=shared._monitor_native_memory,
        args=(pressure_path, pressure_stop),
        daemon=True,
    )
    pressure_thread.start()
    separator = None
    try:
        os.environ["HF_HUB_OFFLINE"] = "1"
        sys.path.insert(0, str(source / "clearvoice"))
        previous_directory = Path.cwd()
        os.chdir(runtime_root)
        try:
            from clearvoice import ClearVoice

            separator = ClearVoice(
                task="speech_separation", model_names=["MossFormer2_SS_16K"]
            )
            files = []
            window_records = []
            for window in windows:
                window_started = time.monotonic()
                original = mixtures[window["id"]]
                mixture_source = shared.verify_artifact(original)
                mixture_file = output / f'{window["id"]}-mixture.wav'
                shutil.copyfile(mixture_source, mixture_file)
                sample_rate, samples = scipy.io.wavfile.read(mixture_file)
                expected_samples = window["endSample"] - window["startSample"]
                if sample_rate != shared.SAMPLE_RATE or samples.shape[0] != expected_samples:
                    raise ValueError("frozen mixture shape mismatch")
                outputs = _source_matrix(
                    separator(_float_audio(samples)[np.newaxis, :]), expected_samples
                )
                entries = [{
                    "windowID": window["id"], "kind": "mixture", "sourceIndex": None,
                    "startSample": window["startSample"], "endSample": window["endSample"],
                    **shared.artifact(mixture_file),
                }]
                if entries[0]["sha256"] != original["sha256"]:
                    raise ValueError("mixture parity with PixIT failed")
                for index, source_audio in enumerate(outputs, 1):
                    source_file = output / f'{window["id"]}-source-{index:02d}.wav'
                    scipy.io.wavfile.write(
                        source_file,
                        shared.SAMPLE_RATE,
                        np.clip(source_audio * 32767, -32768, 32767).astype(np.int16),
                    )
                    entries.append({
                        "windowID": window["id"], "kind": "source", "sourceIndex": index,
                        "speakerLabel": None,
                        "startSample": window["startSample"], "endSample": window["endSample"],
                        **shared.artifact(source_file),
                    })
                files.extend(entries)
                window_records.append({
                    "windowID": window["id"],
                    "elapsedSeconds": time.monotonic() - window_started,
                    "mixtureMatchesPixIT": True,
                    "files": entries,
                })
        finally:
            os.chdir(previous_directory)
    finally:
        del separator
        gc.collect()
        pressure_stop.set()
        pressure_thread.join()

    pressure_records = [json.loads(line) for line in pressure_path.read_text().splitlines()]
    if not pressure_records or any(
        record["memoryPressureExitStatus"] or record["swapUsageExitStatus"]
        for record in pressure_records
    ):
        raise ValueError("native memory pressure sampling failed")
    exited = datetime.now(timezone.utc)
    evidence = {
        "schemaVersion": 1,
        "ticket": TICKET,
        "stage": args.stage,
        "scope": "development-oracle-only",
        "corpusID": shared.CORPUS,
        "plan": shared.artifact(plan_path),
        "pixitSeparatorInput": shared.artifact(pixit_separator_path),
        "runtime": {
            "python": sys.version,
            "packages": versions,
            "source": {
                "repository": CLEARVOICE_REPOSITORY,
                "revision": CLEARVOICE_REVISION,
                "license": CLEARVOICE_LICENSE,
            },
            "device": "cpu",
            "deviceReason": "Pinned ClearVoice selects CPU when MPS is available.",
        },
        "models": [{
            "modelID": MODEL_ID,
            "revision": MODEL_REVISION,
            "license": MODEL_LICENSE,
            "file": MODEL_FILE,
            "sizeBytes": MODEL_SIZE,
            "sha256": MODEL_SHA256,
        }],
        "limitations": {
            "maximumSources": 2,
            "reason": "The pinned official configuration fixes num_spks=2; a three-speaker oracle window cannot be fully separated.",
            "stableIdentityAcrossWindows": False,
        },
        "implementation": shared.artifact(Path(__file__).resolve()),
        "sharedScorer": shared.artifact(Path(shared.__file__).resolve()),
        "runtimeRequirements": shared.artifact(RUNTIME_REQUIREMENTS),
        "runtimeFreeze": shared.artifact(runtime_freeze),
        "nativeMemoryPressure": shared.artifact(pressure_path),
        "worker": {
            "startedAt": shared.iso8601(started),
            "exitedAt": shared.iso8601(exited),
            "elapsedSeconds": time.monotonic() - started_clock,
            "peakResidentBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "exitStatus": 0,
        },
        "windows": window_records,
        "files": files,
    }
    shared.write_json(output / "separator-evidence.json", evidence)


def content_diagnostics(plan: dict, report: dict) -> dict:
    turns = {
        str(turn["id"]): turn
        for window in plan["windows"] for turn in window["referenceTurns"]
    }

    def selected(kind: str) -> list[dict]:
        threshold = str(report["calibration"]["selectedDevelopmentThreshold"])
        items = []
        for window in report["windows"]:
            if window["thresholds"][threshold]["accepted"]:
                items.extend(window[kind])
        return items

    def term_count(items: list[dict]) -> int:
        return sum(len(turns[str(item["turnID"])].get("criticalTerms") or []) for item in items)

    def number_count(items: list[dict]) -> int:
        return sum(len(re.findall(r"\d+", item["reference"])) for item in items)

    recovered, lost = selected("recovered"), selected("lost")
    annotated_terms = sum(len(turn.get("criticalTerms") or []) for turn in turns.values())
    return {
        "turns": {"recovered": len(recovered), "lost": len(lost)},
        "terms": {
            "status": "evaluated" if annotated_terms else "not-evaluable-no-annotated-critical-terms",
            "recovered": term_count(recovered),
            "lost": term_count(lost),
        },
        "numbers": {
            "status": "evaluated-reference-number-tokens",
            "recovered": number_count(recovered),
            "lost": number_count(lost),
        },
        "meaning": {
            "status": "not-evaluable-no-frozen-semantic-anchors",
            "recovered": None,
            "lost": None,
        },
    }


def report(args: argparse.Namespace) -> None:
    output = Path(args.output).resolve()
    if shared.sha256(Path(shared.__file__).resolve()) != SHARED_SCORER_SHA256:
        raise ValueError("ticket #101 shared scorer hash mismatch")
    shared_output = output.with_suffix(output.suffix + ".shared")
    previous_ticket = shared.TICKET
    try:
        shared.TICKET = TICKET
        shared.report(argparse.Namespace(
            plan=args.plan,
            separator=args.separator,
            qwen=args.qwen,
            stage=args.stage,
            output=str(shared_output),
        ))
    finally:
        shared.TICKET = previous_ticket
    value = json.loads(shared_output.read_text())
    shared_output.unlink()
    plan = json.loads(Path(args.plan).read_text())
    separator = json.loads(Path(args.separator).read_text())
    value["candidate"] = "MossFormer2_SS_16K"
    value["resources"]["mossFormer2"] = value["resources"].pop("pixit")
    value.pop("speakerAnalysis", None)
    evaluated = {window["windowID"] for window in value["windows"]}
    value["capacityAnalysis"] = {
        "maximumSources": 2,
        "reason": separator["limitations"]["reason"],
        "windows": [{
            "windowID": window["id"],
            "evaluationStatus": "evaluated" if window["id"] in evaluated else "not-evaluated",
            "expectedSimultaneousVoiceCount": window["expectedSimultaneousVoiceCount"],
            "withinCapacity": window["expectedSimultaneousVoiceCount"] <= 2,
        } for window in plan["windows"]],
    }
    value["contentDiagnostics"] = content_diagnostics(plan, value)
    source_counts = {}
    for record in separator["files"]:
        if record["kind"] == "source":
            source_counts[record["windowID"]] = source_counts.get(record["windowID"], 0) + 1
    value["gates"]["twoOutputMaximumVerified"] = (
        set(source_counts) == evaluated and all(count == 2 for count in source_counts.values())
    )
    value["gates"]["mixtureParityWithPixIT"] = all(
        window["mixtureMatchesPixIT"] for window in separator["windows"]
    )
    shared.write_json(output, value)


def _selected_metrics(report: dict) -> dict:
    threshold = report["calibration"]["selectedDevelopmentThreshold"]
    return next(
        item for item in report["calibration"]["candidates"]
        if item["threshold"] == threshold
    )


def select_separator(stage: str, pixit_metrics: dict, moss_metrics: dict) -> dict:
    if stage == "smoke":
        if moss_metrics["acceptedWindows"] == 0:
            return {"status": "SMOKE_REJECTED_NO_ACCEPTED_WINDOW", "selected": None}
        return {"status": "SMOKE_PASSED_READY_FOR_DEVELOPMENT", "selected": None}
    candidates = [
        ("pixit", pixit_metrics),
        ("mossFormer2", moss_metrics),
    ]
    eligible = [item for item in candidates if item[1]["netRecoveredTurns"] > 0]
    if not eligible:
        return {"status": "NO_ADMISSIBLE_DEV_SEPARATOR", "selected": None}
    selected = max(
        eligible,
        key=lambda item: (item[1]["netRecoveredTurns"], item[1]["recoveredTurns"]),
    )[0]
    return {"status": "DEV_SEPARATOR_SELECTED", "selected": selected}


def compare(args: argparse.Namespace) -> None:
    plan_path = Path(args.plan).resolve()
    pixit_path = Path(args.pixit_report).resolve()
    moss_path = Path(args.moss_report).resolve()
    pixit_report = json.loads(pixit_path.read_text())
    moss_report = json.loads(moss_path.read_text())
    plan = json.loads(plan_path.read_text())
    if shared.sha256(plan_path) != PLAN_SHA256:
        raise ValueError("shared plan hash mismatch")
    if shared.sha256(pixit_path) != PIXIT_REPORT_SHA256[args.stage]:
        raise ValueError("frozen PixIT report hash mismatch")
    if pixit_report.get("ticket") != 101 or moss_report.get("ticket") != TICKET:
        raise ValueError("comparison ticket mismatch")
    if pixit_report.get("stage") != args.stage or moss_report.get("stage") != args.stage:
        raise ValueError("comparison stage mismatch")
    if pixit_report["inputs"]["plan"]["sha256"] != moss_report["inputs"]["plan"]["sha256"]:
        raise ValueError("candidates did not use the same oracle plan")
    if ({window["windowID"] for window in pixit_report["windows"]}
            != {window["windowID"] for window in moss_report["windows"]}):
        raise ValueError("candidates did not evaluate the same oracle windows")
    pixit_qwen = pixit_report["resources"]["qwen"]
    moss_qwen = moss_report["resources"]["qwen"]
    if (pixit_qwen["backend"], pixit_qwen["model"]) != (
        moss_qwen["backend"], moss_qwen["model"]
    ):
        raise ValueError("candidates did not use the same pinned Qwen model")
    for safety_path in (args.moss_safety, args.qwen_safety):
        safety = json.loads(Path(safety_path).read_text())
        if safety.get("stopReason") != "completed" or safety.get("exitStatus") != 0:
            raise ValueError("heavy worker safety gate failed")
    required_gates = (
        moss_report["gates"]["rawArtifactsVerified"]
        and moss_report["gates"]["workersSequential"]
        and moss_report["gates"]["developmentOnly"]
        and moss_report["gates"]["twoOutputMaximumVerified"]
        and moss_report["gates"]["mixtureParityWithPixIT"]
        and not moss_report["gates"]["holdoutOpened"]
    )
    if not required_gates:
        raise ValueError("MossFormer2 safety or parity gate failed")
    pixit_metrics = _selected_metrics(pixit_report)
    moss_metrics = _selected_metrics(moss_report)
    decision = select_separator(args.stage, pixit_metrics, moss_metrics)
    shared.write_json(Path(args.output), {
        "schemaVersion": 1,
        "ticket": TICKET,
        "stage": args.stage,
        "scope": "development-oracle-only",
        "authorization": "user-authorized-independent-test-after-pixit-gate-failure",
        "inputs": {
            "plan": shared.artifact(plan_path),
            "pixitReport": shared.artifact(pixit_path),
            "mossFormer2Report": shared.artifact(moss_path),
            "mossFormer2Safety": shared.artifact(Path(args.moss_safety)),
            "qwenSafety": shared.artifact(Path(args.qwen_safety)),
        },
        "parity": {
            "sameOracleWindows": True,
            "sameMixtures": True,
            "sameQwen": True,
            "sameReferences": True,
            "sameScoringImplementation": shared.artifact(Path(shared.__file__).resolve()),
            "pixitRerun": False,
            "onlyVariable": "separator",
        },
        "quality": {
            "pixit": {**pixit_metrics, "diagnostics": content_diagnostics(plan, pixit_report)},
            "mossFormer2": {**moss_metrics, "diagnostics": moss_report["contentDiagnostics"]},
        },
        "resources": {
            "pixit": pixit_report["resources"],
            "mossFormer2": moss_report["resources"],
        },
        "decision": decision,
        "holdoutOpened": False,
        "uiChanged": False,
        "productChanged": False,
        "liveChanged": False,
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("separate")
    run.add_argument("--plan", required=True)
    run.add_argument("--pixit-separator", required=True)
    run.add_argument("--clearvoice-source", required=True)
    run.add_argument("--runtime-root", required=True)
    run.add_argument("--model", required=True)
    run.add_argument("--output", required=True)
    run.add_argument("--stage", choices=("smoke", "development"), required=True)
    run.add_argument("--window-id")
    run.set_defaults(run=separate)
    audit = commands.add_parser("report")
    audit.add_argument("--plan", required=True)
    audit.add_argument("--separator", required=True)
    audit.add_argument("--qwen", required=True)
    audit.add_argument("--stage", choices=("smoke", "development"), required=True)
    audit.add_argument("--output", required=True)
    audit.set_defaults(run=report)
    comparison = commands.add_parser("compare")
    comparison.add_argument("--plan", required=True)
    comparison.add_argument("--pixit-report", required=True)
    comparison.add_argument("--moss-report", required=True)
    comparison.add_argument("--moss-safety", required=True)
    comparison.add_argument("--qwen-safety", required=True)
    comparison.add_argument("--stage", choices=("smoke", "development"), required=True)
    comparison.add_argument("--output", required=True)
    comparison.set_defaults(run=compare)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
