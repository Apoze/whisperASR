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


def public_segments(segments: list[dict]) -> list[dict]:
    return [
        {
            "id": int(segment.get("id", index)),
            "start": float(segment.get("start", 0)),
            "end": float(segment.get("end", 0)),
            "text": str(segment.get("text", "")).strip(),
        }
        for index, segment in enumerate(segments)
    ]


def emit_event(enabled: bool, payload: dict) -> None:
    if enabled:
        print(json.dumps(payload, ensure_ascii=False), flush=True)


def direct_mlx(model_path: str, decoder: str):
    if importlib.metadata.version("mlx-whisper") != "0.4.3":
        raise RuntimeError("mlx-whisper must be exactly 0.4.3")
    import mlx_whisper

    if decoder not in {"greedy", "beam5"}:
        raise ValueError(f"Unsupported mlx-whisper decoder: {decoder}")

    def transcribe(audio: np.ndarray) -> tuple[str, int, list[dict]]:
        decode_options = {"without_timestamps": True}
        if decoder == "beam5":
            decode_options["beam_size"] = 5
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model_path,
            language="ja",
            task="transcribe",
            temperature=0.0,
            condition_on_previous_text=False,
            word_timestamps=False,
            verbose=None,
            **decode_options,
        )
        return (
            result.get("text", "").strip(),
            int(audio.size),
            public_segments(result.get("segments", [])),
        )

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

    def transcribe(audio: np.ndarray) -> tuple[str, int, list[dict]]:
        original_transcribe = mlx_whisper.transcribe
        fed_samples = 0

        def measured_transcribe(chunk, *args, **kwargs):
            nonlocal fed_samples
            fed_samples += int(np.asarray(chunk).size)
            kwargs["temperature"] = 0.0
            kwargs["condition_on_previous_text"] = False
            kwargs["word_timestamps"] = False
            kwargs["without_timestamps"] = True
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
        return text, fed_samples, public_segments(result["segments"])

    return transcribe


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: japanese_external_asr.py REQUEST.json RESPONSE.json", file=sys.stderr)
        return 2
    request_path, response_path = map(Path, sys.argv[1:])
    request = json.loads(request_path.read_text(encoding="utf-8"))
    response: dict = {"setupError": None, "turns": [], "windows": []}
    emit_events = bool(request.get("emitEvents", False))
    wait_for_session_ack = request.get("waitForSessionAck", False)

    try:
        if not isinstance(wait_for_session_ack, bool):
            raise ValueError("waitForSessionAck must be a boolean")
        if wait_for_session_ack and not emit_events:
            raise ValueError("waitForSessionAck requires emitEvents=true")
        setup_started = time.perf_counter_ns()
        backend = request["backend"]
        if backend == "mlx-whisper":
            transcribe = direct_mlx(request["modelPath"], request.get("decoder", "greedy"))
        elif backend == "whispermlx":
            transcribe = whispermlx(request["modelPath"], request["sileroPath"])
        else:
            raise ValueError(f"Unknown backend: {backend}")
        response["setupMilliseconds"] = (
            time.perf_counter_ns() - setup_started
        ) / 1_000_000

        corpora = {
            corpus["corpusID"]: (corpus, load_pcm(corpus["audioPath"]))
            for corpus in request["corpora"]
        }
        if request.get("windows"):
            first_item = request["windows"][0]
            first_corpus, first_pcm = corpora[first_item["corpusID"]]
            first_range = first_item.get("ranges", [first_item])[0]
        else:
            first_corpus, first_pcm = next(iter(corpora.values()))
            first_range = first_corpus["turns"][0]
        seed_inference(first_corpus["corpusID"], first_range.get("turnID", 0))
        warmup_started = time.perf_counter_ns()
        transcribe(first_pcm[first_range["startSample"] : first_range["endSample"]])
        response["warmupMilliseconds"] = (
            time.perf_counter_ns() - warmup_started
        ) / 1_000_000

        for corpus, pcm in corpora.values():
            for turn in corpus["turns"]:
                audio = pcm[turn["startSample"] : turn["endSample"]]
                seed_inference(corpus["corpusID"], turn["turnID"])
                started = time.perf_counter_ns()
                error = None
                text = ""
                fed_sample_count = 0
                try:
                    text, fed_sample_count, _ = transcribe(audio)
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

        windows = request.get("windows", [])
        for window_index, window in enumerate(windows):
            _, pcm = corpora[window["corpusID"]]
            window_audio = pcm[window["startSample"] : window["endSample"]]
            seed_inference(window["corpusID"], window["seed"])
            started = time.perf_counter_ns()
            compute_ms = 0.0
            fed_sample_count = 0
            texts: list[str] = []
            segments: list[dict] = []
            range_results: list[dict] = []
            error = None
            emit_event(emit_events, {
                "type": "session-start",
                "sessionID": window["sessionID"],
                "corpusID": window["corpusID"],
                "windowID": window["windowID"],
                "replay": window["replay"],
            })
            try:
                ranges = window.get("ranges")
                mode = request.get(
                    "mode",
                    "long-form" if backend == "whispermlx" else "vad-finals",
                )
                if mode not in {"long-form", "vad-finals"}:
                    raise ValueError(f"Unsupported execution mode: {mode}")
                if backend == "whispermlx" and mode == "long-form":
                    ranges = [{
                        "startSample": window["startSample"],
                        "endSample": window["endSample"],
                    }]
                for range_index, item_range in enumerate(ranges):
                    if window.get("realtime"):
                        deadline = (
                            item_range["endSample"] - window["startSample"]
                        ) / 16_000
                        elapsed = (time.perf_counter_ns() - started) / 1_000_000_000
                        time.sleep(max(0.0, deadline - elapsed))
                    audio = pcm[item_range["startSample"] : item_range["endSample"]]
                    decode_started = time.perf_counter_ns()
                    text, fed, item_segments = transcribe(audio)
                    elapsed_ms = (time.perf_counter_ns() - decode_started) / 1_000_000
                    compute_ms += elapsed_ms
                    fed_sample_count += fed
                    texts.append(text)
                    segment_offset = (
                        item_range["startSample"] - window["startSample"]
                    ) / 16_000
                    for segment in item_segments:
                        segment = dict(segment)
                        segment["start"] += segment_offset
                        segment["end"] += segment_offset
                        segments.append(segment)
                    range_result = {
                        "startSample": item_range["startSample"],
                        "endSample": item_range["endSample"],
                        "hypothesisJapanese": text,
                        "asrMilliseconds": elapsed_ms,
                        "fedSampleCount": fed,
                        "completedMilliseconds": (
                            time.perf_counter_ns() - started
                        ) / 1_000_000,
                        "backlogMilliseconds": max(
                            0.0,
                            (time.perf_counter_ns() - started) / 1_000_000
                            - (
                                item_range["endSample"] - window["startSample"]
                            ) / 16,
                        ),
                    }
                    range_results.append(range_result)
                    if mode == "long-form" and item_segments:
                        for segment_index, segment in enumerate(item_segments):
                            emit_event(emit_events, {
                                "type": "final",
                                "sessionID": window["sessionID"],
                                "rangeIndex": segment_index,
                                "startSample": window["startSample"]
                                + int(round(segment["start"] * 16_000)),
                                "endSample": window["startSample"]
                                + int(round(segment["end"] * 16_000)),
                                "hypothesisJapanese": segment["text"],
                                "asrMilliseconds": elapsed_ms,
                                "completedMilliseconds": range_result[
                                    "completedMilliseconds"
                                ],
                                "backlogMilliseconds": None,
                            })
                    else:
                        emit_event(emit_events, {
                            "type": "final",
                            "sessionID": window["sessionID"],
                            "rangeIndex": range_index,
                            **range_result,
                        })
                if window.get("realtime"):
                    deadline = (
                        window["endSample"] - window["startSample"]
                    ) / 16_000
                    elapsed = (time.perf_counter_ns() - started) / 1_000_000_000
                    time.sleep(max(0.0, deadline - elapsed))
            except Exception as exc:  # Keep later windows observable.
                error = f"{type(exc).__name__}: {exc}"
            window_result = {
                "sessionID": window["sessionID"],
                "corpusID": window["corpusID"],
                "windowID": window["windowID"],
                "replay": window["replay"],
                "hypothesisJapanese": " ".join(filter(None, texts)).strip(),
                "inputSampleCount": int(window_audio.size),
                "fedSampleCount": fed_sample_count,
                "asrMilliseconds": compute_ms,
                "wallMilliseconds": (time.perf_counter_ns() - started) / 1_000_000,
                "residentBytes": resident_bytes(),
                "ranges": range_results,
                "segments": segments,
                "error": error,
            }
            response["windows"].append(window_result)
            emit_event(emit_events, {
                "type": "session-end",
                **window_result,
            })
            if wait_for_session_ack and window_index + 1 < len(windows):
                if sys.stdin.readline() == "":
                    raise EOFError("Missing session acknowledgement")
    except Exception as exc:
        response["setupError"] = f"{type(exc).__name__}: {exc}"

    response_path.parent.mkdir(parents=True, exist_ok=True)
    response_path.write_text(json.dumps(response, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if response["setupError"] is None else 1


if __name__ == "__main__":
    raise SystemExit(main())
