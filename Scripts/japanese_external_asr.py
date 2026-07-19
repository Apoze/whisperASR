#!/usr/bin/env python3
"""Run the two Python-only L5 ASR candidates on pinned PCM ranges."""

from __future__ import annotations

import json
import importlib.metadata
import resource
import sys
import time
import wave
import zlib
from pathlib import Path

import numpy as np


def load_pcm(path: str) -> np.ndarray:
    with wave.open(path, "rb") as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, 16_000):
            raise ValueError(f"Expected mono PCM16 at 16 kHz: {path}")
        return np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype(np.float32) / 32768.0


def resident_bytes() -> int:
    # macOS reports ru_maxrss in bytes (Linux reports KiB).
    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    process_peak = value if sys.platform == "darwin" else value * 1024
    try:
        import mlx.core as mx

        mlx_current = int(mx.get_active_memory() + mx.get_cache_memory())
        mlx_peak = int(mx.get_peak_memory())
        return max(process_peak, mlx_current, mlx_peak)
    except (ImportError, RuntimeError):
        return process_peak


def seed_inference(corpus_id: str, turn_id: int) -> None:
    seed = zlib.crc32(f"{corpus_id}:{turn_id}".encode("utf-8"))
    np.random.seed(seed)
    import mlx.core as mx

    mx.random.seed(seed)


def direct_mlx(model_path: str):
    if importlib.metadata.version("mlx-whisper") != "0.4.3":
        raise RuntimeError("mlx-whisper must be exactly 0.4.3")
    import mlx_whisper

    def transcribe(audio: np.ndarray) -> tuple[str, int]:
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model_path,
            language="ja",
            task="transcribe",
            word_timestamps=False,
            verbose=None,
        )
        return result.get("text", "").strip(), int(audio.size)

    return transcribe


def whispermlx(model_path: str, silero_path: str):
    if importlib.metadata.version("whispermlx") != "3.12.2":
        raise RuntimeError("whispermlx must be exactly 3.12.2")
    if importlib.metadata.version("mlx-whisper") != "0.4.3":
        raise RuntimeError("whispermlx must use mlx-whisper 0.4.3")
    import torch

    original_load = torch.hub.load

    def pinned_load(repo_or_dir, *args, **kwargs):
        if repo_or_dir == "snakers4/silero-vad":
            repo_or_dir = silero_path
            kwargs["source"] = "local"
            kwargs.pop("trust_repo", None)
        return original_load(repo_or_dir, *args, **kwargs)

    torch.hub.load = pinned_load
    import whispermlx as whispermlx_module

    pipeline = whispermlx_module.load_model(
        model_path,
        device="cpu",
        language="ja",
        task="transcribe",
        vad_method="silero",
        local_files_only=True,
    )

    import mlx_whisper

    def transcribe(audio: np.ndarray) -> tuple[str, int]:
        original_transcribe = mlx_whisper.transcribe
        fed_samples = 0

        def measured_transcribe(chunk, *args, **kwargs):
            nonlocal fed_samples
            fed_samples += int(np.asarray(chunk).size)
            return original_transcribe(chunk, *args, **kwargs)

        mlx_whisper.transcribe = measured_transcribe
        try:
            result = pipeline.transcribe(
                audio,
                language="ja",
                task="transcribe",
                chunk_size=30,
                print_progress=False,
                verbose=False,
            )
        finally:
            mlx_whisper.transcribe = original_transcribe
        text = " ".join(
            segment.get("text", "").strip() for segment in result["segments"]
        ).strip()
        return text, fed_samples

    return transcribe


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: japanese_external_asr.py REQUEST.json RESPONSE.json", file=sys.stderr)
        return 2
    request_path, response_path = map(Path, sys.argv[1:])
    request = json.loads(request_path.read_text(encoding="utf-8"))
    response: dict = {"setupError": None, "turns": []}

    try:
        backend = request["backend"]
        if backend == "mlx-whisper":
            transcribe = direct_mlx(request["modelPath"])
        elif backend == "whispermlx":
            transcribe = whispermlx(request["modelPath"], request["sileroPath"])
        else:
            raise ValueError(f"Unknown backend: {backend}")

        corpora = [(corpus, load_pcm(corpus["audioPath"])) for corpus in request["corpora"]]
        first_corpus, first_pcm = corpora[0]
        first_turn = first_corpus["turns"][0]
        seed_inference(first_corpus["corpusID"], first_turn["turnID"])
        transcribe(first_pcm[first_turn["startSample"] : first_turn["endSample"]])

        for corpus, pcm in corpora:
            for turn in corpus["turns"]:
                audio = pcm[turn["startSample"] : turn["endSample"]]
                seed_inference(corpus["corpusID"], turn["turnID"])
                started = time.perf_counter_ns()
                error = None
                text = ""
                fed_sample_count = 0
                try:
                    text, fed_sample_count = transcribe(audio)
                except Exception as exc:  # Keep later turns observable.
                    error = f"{type(exc).__name__}: {exc}"
                elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
                response["turns"].append(
                    {
                        "corpusID": corpus["corpusID"],
                        "turnID": turn["turnID"],
                        "hypothesisJapanese": text,
                        "inputSampleCount": int(audio.size),
                        "fedSampleCount": fed_sample_count,
                        "asrMilliseconds": elapsed_ms,
                        "residentBytes": resident_bytes(),
                        "error": error,
                    }
                )
    except Exception as exc:
        response["setupError"] = f"{type(exc).__name__}: {exc}"

    response_path.parent.mkdir(parents=True, exist_ok=True)
    response_path.write_text(json.dumps(response, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if response["setupError"] is None else 1


if __name__ == "__main__":
    raise SystemExit(main())
