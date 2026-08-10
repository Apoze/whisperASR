#!/usr/bin/env python3
"""Run MetricX-24 QE in an isolated process and retain memory evidence."""

from __future__ import annotations

import argparse
import gc
import hashlib
import importlib.metadata
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path


MODEL_ID = "google/metricx-24-hybrid-large-v2p6-bfloat16"
MODEL_REVISION = "febb720e29a059df2e8af3ffd71dcdc9e0a24910"
TOKENIZER_ID = "google/mt5-xl"
TOKENIZER_REVISION = "63fc6450d80515b48e026b69ef2fbbd426433e84"
SOURCE_REVISION = "fc4978eb064670f7cc33e93ea4f52d38396b8ae6"
WEIGHT_SHA256 = "b1f2c03ab5ec5318a55b90b42eefa22431daa7b1a8e28a97a6aef23d18a24278"
RESERVE_BYTES = 8 * 1_024**3
DECLARED_PEAK_BYTES = 8 * 1_024**3


def read_rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def validate_rows(rows: list[dict]) -> None:
    required = {"candidateID", "pairID", "source", "hypothesis", "suspectReasonCodes"}
    if not rows:
        raise ValueError("MetricX input is empty")
    for row in rows:
        if not required <= row.keys() or "reference" in row:
            raise ValueError("MetricX QE rows require source/hypothesis and forbid references")
        if not row["suspectReasonCodes"]:
            raise ValueError("MetricX may score only suspect units")
    ids = [row["candidateID"] for row in rows]
    if len(ids) != len(set(ids)):
        raise ValueError("MetricX candidate IDs must be unique")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1_024**2), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rss_bytes(pid: int) -> int:
    result = subprocess.run(
        ["/bin/ps", "-o", "rss=", "-p", str(pid)],
        text=True,
        capture_output=True,
        check=False,
    )
    value = result.stdout.strip()
    return int(value) * 1_024 if value else 0


def physical_memory() -> int:
    return int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], text=True))


def translate_gemma_processes() -> list[dict]:
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    result = []
    for line in output.splitlines():
        pid_text, _, command = line.strip().partition(" ")
        if int(pid_text) != os.getpid() and "translategemma" in command.casefold():
            result.append({"pid": int(pid_text), "command": command})
    return result


def git_revision(path: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
    ).strip()


def worker(args: argparse.Namespace) -> None:
    rows = read_rows(args.input)
    validate_rows(rows)
    if git_revision(args.source_root) != SOURCE_REVISION:
        raise SystemExit("MetricX source checkout does not match the frozen revision")
    sys.path.insert(0, str(args.source_root))
    import torch
    import transformers
    from metricx24.models import MT5ForRegression
    from transformers.utils.hub import cached_file

    started = time.monotonic()
    tokenizer = transformers.AutoTokenizer.from_pretrained(
        TOKENIZER_ID, revision=TOKENIZER_REVISION
    )
    weight_path = Path(cached_file(MODEL_ID, "pytorch_model.bin", revision=MODEL_REVISION))
    observed_weight_sha = file_sha256(weight_path)
    if observed_weight_sha != WEIGHT_SHA256:
        raise SystemExit(
            f"MetricX weight SHA-256 mismatch: {observed_weight_sha} != {WEIGHT_SHA256}"
        )
    load_started = time.monotonic()
    model = MT5ForRegression.from_pretrained(
        MODEL_ID, revision=MODEL_REVISION, torch_dtype="auto"
    )
    if args.device != "cpu":
        raise SystemExit("The frozen Apple Silicon experiment uses the official CPU path only")
    model.to(torch.device("cpu"))
    model.eval()
    load_seconds = time.monotonic() - load_started
    metadata = {
        "python": sys.version,
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "torch": torch.__version__,
        "transformers": transformers.__version__,
        "sentencepiece": importlib.metadata.version("sentencepiece"),
        "protobuf": importlib.metadata.version("protobuf"),
        "huggingfaceHub": importlib.metadata.version("huggingface-hub"),
        "device": args.device,
        "modelID": MODEL_ID,
        "modelRevision": MODEL_REVISION,
        "tokenizerID": TOKENIZER_ID,
        "tokenizerRevision": TOKENIZER_REVISION,
        "sourceRevision": SOURCE_REVISION,
        "weightPath": str(weight_path),
        "weightSHA256": observed_weight_sha,
        "modelDtype": str(next(model.parameters()).dtype),
        "modelLoadSeconds": load_seconds,
    }
    write_json(args.worker_metadata, metadata)
    scored = []
    with torch.inference_mode():
        for row in rows:
            scoring_started = time.monotonic()
            encoded = tokenizer(
                f'source: {row["source"]} candidate: {row["hypothesis"]}',
                max_length=1536,
                truncation=True,
                padding=False,
                return_tensors="pt",
            )
            encoded["input_ids"] = encoded["input_ids"][:, :-1]
            encoded["attention_mask"] = encoded["attention_mask"][:, :-1]
            prediction = float(model(**encoded).predictions.item())
            scored.append({
                **row,
                "prediction": prediction,
                "scoringSeconds": time.monotonic() - scoring_started,
            })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in scored)
    )
    metadata["workerSeconds"] = time.monotonic() - started
    metadata["scoringSeconds"] = sum(row["scoringSeconds"] for row in scored)
    metadata["scoredCandidates"] = len(scored)
    write_json(args.worker_metadata, metadata)
    del model
    gc.collect()


def controller(args: argparse.Namespace) -> None:
    rows = read_rows(args.input)
    validate_rows(rows)
    if not args.producer_artifact.is_file():
        raise SystemExit("Frozen TranslateGemma producer artifact is missing")
    if git_revision(args.source_root) != SOURCE_REVISION:
        raise SystemExit("MetricX source checkout does not match the frozen revision")
    existing = translate_gemma_processes()
    total = physical_memory()
    baseline = rss_bytes(os.getpid())
    preflight_capacity = baseline + DECLARED_PEAK_BYTES <= total - RESERVE_BYTES
    args.output.unlink(missing_ok=True)
    args.worker_metadata.unlink(missing_ok=True)
    started = time.monotonic()
    runtime = {
        "schemaVersion": 1,
        "outcome": "preflight-failure" if existing or not preflight_capacity else "running",
        "modelID": MODEL_ID,
        "modelRevision": MODEL_REVISION,
        "producerArtifact": str(args.producer_artifact),
        "producerArtifactSHA256": file_sha256(args.producer_artifact),
        "physicalMemoryBytes": total,
        "systemReserveBytes": RESERVE_BYTES,
        "declaredPeakBytes": DECLARED_PEAK_BYTES,
        "controllerBaselineRSSBytes": baseline,
        "preflightCapacity": preflight_capacity,
        "handoff": {
            "frozenProducerProcessExited": True,
            "translateGemmaProcessesBeforeLoad": existing,
            "workerExitedAfterScoring": False,
        },
    }
    if existing or not preflight_capacity:
        write_json(args.runtime, runtime)
        raise SystemExit("Heavyweight preflight failed before MetricX load")
    command = [
        sys.executable, str(Path(__file__).resolve()), "--worker",
        "--input", str(args.input), "--output", str(args.output),
        "--runtime", str(args.runtime), "--worker-metadata", str(args.worker_metadata),
        "--producer-artifact", str(args.producer_artifact),
        "--source-root", str(args.source_root), "--device", args.device,
    ]
    process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    peak = 0
    while process.poll() is None:
        peak = max(peak, rss_bytes(process.pid))
        time.sleep(0.05)
    stdout, stderr = process.communicate()
    peak = max(peak, rss_bytes(process.pid))
    worker_after_exit = rss_bytes(process.pid)
    runtime.update({
        "runtimeSeconds": time.monotonic() - started,
        "peakWorkerRSSBytes": peak,
        "workerRSSAfterExitBytes": worker_after_exit,
        "memoryReserveIntact": peak <= total - RESERVE_BYTES,
        "workerReturnCode": process.returncode,
        "workerStdout": stdout,
        "workerStderr": stderr,
        "workerRuntime": read(args.worker_metadata) if args.worker_metadata.exists() else None,
    })
    runtime["handoff"]["workerExitedAfterScoring"] = process.returncode == 0 \
        and worker_after_exit == 0
    runtime["outcome"] = "pass" if process.returncode == 0 \
        and runtime["memoryReserveIntact"] and runtime["handoff"]["workerExitedAfterScoring"] \
        else "runtime-failure"
    write_json(args.runtime, runtime)
    if runtime["outcome"] != "pass":
        if stderr:
            print(stderr, file=sys.stderr)
        raise SystemExit("MetricX worker failed; inspect the retained runtime artifact")
    scored = read_rows(args.output)
    validate_rows(scored)
    if len(scored) != len(rows) or any("prediction" not in row for row in scored):
        raise SystemExit("MetricX output does not match the frozen input")


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def self_test() -> None:
    validate_rows([{
        "candidateID": "candidate-a", "pairID": "pair-a", "source": "日本語",
        "hypothesis": "English", "suspectReasonCodes": ["injected-undertranslation"],
    }])
    try:
        validate_rows([{
            "candidateID": "candidate-a", "pairID": "pair-a", "source": "日本語",
            "hypothesis": "English", "reference": "forbidden",
            "suspectReasonCodes": ["suspect"],
        }])
    except ValueError:
        pass
    else:
        raise AssertionError("human references must be rejected")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--worker-metadata", type=Path)
    parser.add_argument("--producer-artifact", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    required = (args.input, args.output, args.runtime, args.worker_metadata,
                args.producer_artifact, args.source_root)
    if any(value is None for value in required):
        parser.error("input, output, runtime, worker metadata, producer artifact and source root are required")
    worker(args) if args.worker else controller(args)


if __name__ == "__main__":
    main()
