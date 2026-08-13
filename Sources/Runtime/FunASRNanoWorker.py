#!/usr/bin/env python3
"""Pinned Fun-ASR-Nano int8 adapter for the existing High-quality ASR worker."""

from array import array
import gc
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import signal
import sys
import time


BACKEND = "funasr-nano-int8"
RUNTIME_VERSION = "1.13.5"
RUNTIME_COMMIT = "3dc7c569f31ca2cd4a20ed6f7db780327e6714c5"
ARCHIVE_SHA256 = "eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b"
MODEL_ID = "k2-fsa/sherpa-onnx-funasr-nano-int8-2025-12-30"
EXPECTED_SHA256 = {
    "embedding.int8.onnx": "a05d2816e284fcca29a5dccb2c14b9edeb638fd983a84cd4a447248889b6a408",
    "encoder_adaptor.int8.onnx": "d0246c823f2c34133ae0efee395d8a189c8f92643e3432f866939ee34d34492c",
    "llm.int8.onnx": "7f0c5a508b41474b1b1ec1cdbdefafd2cf8b3642c6915a0a425265b7b7d2c960",
    "Qwen3-0.6B/merges.txt": "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
    "Qwen3-0.6B/tokenizer.json": "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
    "Qwen3-0.6B/vocab.json": "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
}
FILES = tuple(EXPECTED_SHA256)
stopping = False


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def fail(message: str) -> dict:
    return {"error": message, "criticalMemoryPressure": False}


def validate_install(model: Path) -> dict[str, str]:
    if platform.machine() != "arm64":
        raise RuntimeError("sherpa-onnx runtime must execute as macOS arm64")
    for package in ("sherpa-onnx", "sherpa-onnx-core"):
        actual = importlib.metadata.version(package)
        if actual != RUNTIME_VERSION:
            raise RuntimeError(f"{package} must be exactly {RUNTIME_VERSION}, got {actual}")
    provenance = json.loads((model / "provenance.json").read_text(encoding="utf-8"))
    if provenance.get("archiveSHA256") != ARCHIVE_SHA256:
        raise RuntimeError("Fun-ASR archive provenance does not match the pinned release")
    missing = [relative for relative in FILES if not (model / relative).is_file()]
    if missing:
        raise RuntimeError(f"Fun-ASR model is incomplete: {', '.join(missing)}")
    hashes = {relative: sha256(model / relative) for relative in FILES}
    mismatched = [relative for relative in FILES
                  if hashes[relative] != EXPECTED_SHA256[relative]]
    if mismatched:
        raise RuntimeError(f"Fun-ASR weight hash mismatch: {', '.join(mismatched)}")
    return hashes


def load_samples(request: dict, directory: Path) -> array:
    name = request.get("audioFile")
    count = request.get("sampleCount")
    if (
        not isinstance(name, str)
        or Path(name).name != name
        or ".." in name
        or not isinstance(count, int)
        or count < 0
    ):
        raise RuntimeError("invalid audio request")
    path = directory / name
    if path.stat().st_size != count * 4:
        raise RuntimeError("invalid PCM length")
    samples = array("f")
    with path.open("rb") as handle:
        samples.fromfile(handle, count)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def create_recognizer(model: Path):
    import sherpa_onnx

    return sherpa_onnx.OfflineRecognizer.from_funasr_nano(
        encoder_adaptor=str(model / "encoder_adaptor.int8.onnx"),
        llm=str(model / "llm.int8.onnx"),
        embedding=str(model / "embedding.int8.onnx"),
        tokenizer=str(model / "Qwen3-0.6B"),
        num_threads=2,
        provider="cpu",
        language="日文",
        itn=False,
        hotwords="",
    )


def decode(recognizer, samples: array, sequence: int) -> tuple[dict, float]:
    started = time.monotonic()
    stream = recognizer.create_stream()
    stream.accept_waveform(16_000, samples)
    recognizer.decode_stream(stream)
    elapsed = time.monotonic() - started
    result = stream.result
    tokens = list(result.tokens or [])
    timestamps = [float(value) for value in (result.timestamps or [])]
    if len(tokens) != len(timestamps) or any(
        not math.isfinite(value) or value < 0 for value in timestamps
    ) or timestamps != sorted(timestamps):
        raise RuntimeError("sherpa-onnx returned invalid interpolated token timestamps")
    raw = {
        "sequence": sequence,
        "text": result.text.strip(),
        "tokens": tokens,
        "timestamps": timestamps,
        "timestampSemantics": "uniform-token-interpolation-not-acoustic-alignment",
        "elapsedSeconds": elapsed,
    }
    print(json.dumps({"sherpaRawResult": raw}, ensure_ascii=False), flush=True)
    return {
        "exchange": {"rawTranscript": raw["text"], "chunks": []},
        "sherpaRawResult": raw,
    }, elapsed


def stop(_signal, _frame) -> None:
    global stopping
    stopping = True


def warn(_signal, _frame) -> None:
    gc.collect()
    print(json.dumps({"memoryWarning": True}), flush=True)


def self_test() -> None:
    assert ARCHIVE_SHA256 == "eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b"
    assert FILES[:3] == (
        "embedding.int8.onnx",
        "encoder_adaptor.int8.onnx",
        "llm.int8.onnx",
    )
    assert all(len(value) == 64 for value in EXPECTED_SHA256.values())
    assert fail("x")["error"] == "x"


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(sys.argv) != 4 or sys.argv[1] != "--high-quality-asr-worker" or sys.argv[2] != BACKEND:
        print(f"usage: {sys.argv[0]} --high-quality-asr-worker {BACKEND} DIRECTORY", file=sys.stderr)
        return 64
    directory = Path(sys.argv[3])
    model = Path(os.environ.get(
        "WHISPERASR_FUNASR_MODEL_DIR",
        Path.cwd() / ".build/models/sherpa-onnx-funasr-nano-int8-2025-12-30",
    ))
    ready = directory / "ready.json"
    parent = os.getppid()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGUSR1, warn)
    try:
        hashes = validate_install(model)
        recognizer = create_recognizer(model)
        write_json(ready, {
            "ready": True,
            "model": {
                "backend": BACKEND,
                "modelID": MODEL_ID,
                "revision": ARCHIVE_SHA256,
                "runtimeVersion": f"sherpa-onnx {RUNTIME_VERSION} ({RUNTIME_COMMIT})",
                "weightSHA256": hashes,
            },
        })
    except Exception as error:
        write_json(ready, fail(str(error)))
        return 1

    sequence = 1
    total_decode = 0.0
    budget = float(os.environ.get("WHISPERASR_FUNASR_DECODE_BUDGET_SECONDS", "inf"))
    while not stopping and os.getppid() == parent and not (directory / "shutdown").exists():
        request_path = directory / f"request-{sequence}.json"
        if not request_path.exists():
            time.sleep(0.02)
            continue
        response_path = directory / f"response-{sequence}.json"
        try:
            if total_decode >= budget:
                raise RuntimeError(f"cost stop: cumulative ASR exceeded {budget:.1f}s")
            request = json.loads(request_path.read_text(encoding="utf-8"))
            if request.get("anchored") is not False:
                raise RuntimeError("Fun-ASR worker accepts only frozen external chunks")
            response, elapsed = decode(recognizer, load_samples(request, directory), sequence)
            total_decode += elapsed
            response["cumulativeDecodeSeconds"] = total_decode
            write_json(response_path, response)
        except Exception as error:
            write_json(response_path, fail(str(error)))
        sequence += 1
    return 75 if stopping else 0


if __name__ == "__main__":
    raise SystemExit(main())
