#!/usr/bin/env python3
"""High-quality worker protocol for the pinned ReazonSpeech K2 v2 int8 recipe."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import signal
import sys
import time
from pathlib import Path

MODEL_ID = "reazon-research/reazonspeech-k2-v2"
MODEL_REVISION = "291488c8151be24d7da4bf7af26e533fad96e407"
RUNTIME_VERSION = "1.13.4"
FILES = {
    "encoder-epoch-99-avg-1.int8.onnx":
        "2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d",
    "decoder-epoch-99-avg-1.onnx":
        "58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124",
    "joiner-epoch-99-avg-1.int8.onnx":
        "49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de",
    "tokens.txt":
        "2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def model_evidence() -> tuple[dict, Path]:
    root = Path(os.environ["WHISPERASR_REAZON_MODEL_ROOT"]).resolve()
    observed = {name: sha256(root / name) for name in FILES}
    if observed != FILES:
        raise RuntimeError(f"ReazonSpeech asset hashes differ: {observed}")
    return ({
        "backend": "reazonspeech-k2-v2-int8",
        "modelID": MODEL_ID,
        "revision": MODEL_REVISION,
        "runtimeVersion": f"sherpa-onnx {RUNTIME_VERSION}",
        "weightSHA256": observed,
    }, root)


def character_timestamps(result, duration: float) -> list[dict]:
    text = result.text.strip()
    tokens = list(result.tokens)
    starts = list(result.timestamps)
    if "".join(tokens) != text or len(tokens) != len(starts):
        raise RuntimeError("ReazonSpeech did not return one timestamp per output character")
    if any(len(token) != 1 for token in tokens):
        raise RuntimeError("ReazonSpeech returned a token that is not one Unicode character")
    if any(left > right for left, right in zip(starts, starts[1:])):
        raise RuntimeError("ReazonSpeech timestamps are not monotonic")
    ends = starts[1:] + [duration]
    if any(start < 0 or end < start or end > duration for start, end in zip(starts, ends)):
        raise RuntimeError("ReazonSpeech timestamps exceed the input audio")
    return [{
        "chunkIndex": 0,
        "text": token,
        "sourceStart": start,
        "sourceEnd": end,
    } for token, start, end in zip(tokens, starts, ends)]


def self_test() -> None:
    class Result:
        text = "日本"
        tokens = ["日", "本"]
        timestamps = [0.1, 0.4]

    assert character_timestamps(Result(), 0.8) == [
        {"chunkIndex": 0, "text": "日", "sourceStart": 0.1, "sourceEnd": 0.4},
        {"chunkIndex": 0, "text": "本", "sourceStart": 0.4, "sourceEnd": 0.8},
    ]
    Result.text, Result.tokens, Result.timestamps = "日本", ["日本"], [0.1]
    try:
        character_timestamps(Result(), 0.8)
    except RuntimeError:
        pass
    else:
        raise AssertionError("multi-character tokens must fail the auditable timestamp gate")


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if len(sys.argv) != 3 or sys.argv[1] != "reazonspeech-k2-v2-int8":
        return 64
    directory = Path(sys.argv[2])
    stopped = False

    def stop(*_args) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    try:
        if importlib.metadata.version("sherpa-onnx") != RUNTIME_VERSION:
            raise RuntimeError(f"sherpa-onnx must be exactly {RUNTIME_VERSION}")
        import numpy as np
        import sherpa_onnx

        model, root = model_evidence()
        recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(root / "encoder-epoch-99-avg-1.int8.onnx"),
            decoder=str(root / "decoder-epoch-99-avg-1.onnx"),
            joiner=str(root / "joiner-epoch-99-avg-1.int8.onnx"),
            tokens=str(root / "tokens.txt"),
            num_threads=1,
            decoding_method="greedy_search",
            provider="cpu",
        )
        write(directory / "ready.json", {"ready": True, "model": model})
    except Exception as error:
        write(directory / "ready.json", {"error": f"{type(error).__name__}: {error}"})
        return 1

    sequence = 1
    while not stopped:
        if (directory / "shutdown").exists():
            break
        request_path = directory / f"request-{sequence}.json"
        if not request_path.exists():
            time.sleep(0.02)
            continue
        response_path = directory / f"response-{sequence}.json"
        try:
            request = json.loads(request_path.read_text(encoding="utf-8"))
            if request.get("anchored") is not False:
                raise RuntimeError("anchoring belongs to the shared High-quality worker client")
            audio_name = request["audioFile"]
            if Path(audio_name).name != audio_name or ".." in audio_name:
                raise RuntimeError("invalid audio request")
            samples = np.fromfile(directory / audio_name, dtype="<f4")
            if samples.size != request["sampleCount"]:
                raise RuntimeError("invalid PCM length")
            stream = recognizer.create_stream()
            stream.accept_waveform(16_000, samples)
            recognizer.decode_stream(stream)
            result = stream.result
            duration = samples.size / 16_000
            characters = character_timestamps(result, duration)
            transcript = "".join(item["text"] for item in characters)
            write(response_path, {"exchange": {
                "rawTranscript": transcript,
                "chunks": [],
                "characters": characters,
            }})
        except Exception as error:
            write(response_path, {"error": f"{type(error).__name__}: {error}"})
        sequence += 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
