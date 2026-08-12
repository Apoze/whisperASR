#!/usr/bin/env python3
"""Run and audit the ticket #101 PixIT DEV-only oracle experiment."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import re
import resource
import subprocess
import sys
import threading
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path


TICKET = 101
CORPUS = "qudu2fx3ncc"
SAMPLE_RATE = 16_000
PADDING_SAMPLES = SAMPLE_RATE // 2
STARTING_SIMILARITY = 0.80
SIMILARITY_CANDIDATES = (0.70, 0.75, 0.80, 0.85, 0.90, 0.95)
PIXIT_MAX_SIMULTANEOUS_VOICES = 3
MODEL_REVISIONS = {
    "pyannote/speech-separation-ami-1.0": "9486b106945ae0cc0784041a08bfcdba5edadfb9",
    "pyannote/separation-ami-1.0": "4d38e95cfd067c894b8b60b00761831fb01e4a8c",
    "speechbrain/spkrec-ecapa-voxceleb": "0f99f2d0ebe89ac095bcc5903c4dd8f72b367286",
    "microsoft/wavlm-large": "c1423ed94bb01d80a3f5ce5bc39f6026a0f4828c",
    "pyannote/wespeaker-voxceleb-resnet34-LM": "837717ddb9ff5507820346191109dc79c958d614",
}
MODEL_LICENSES = {
    "pyannote/speech-separation-ami-1.0": "MIT",
    "pyannote/separation-ami-1.0": "MIT",
    "speechbrain/spkrec-ecapa-voxceleb": "Apache-2.0",
    "microsoft/wavlm-large": "CC-BY-SA-3.0",
    "pyannote/wespeaker-voxceleb-resnet34-LM": "CC-BY-4.0",
}
RUNTIME_VERSIONS = {
    "huggingface-hub": "0.24.7",
    "lightning": "2.3.3",
    "numpy": "1.26.4",
    "pyannote.audio": "3.3.2",
    "scipy": "1.13.1",
    "speechbrain": "1.0.0",
    "torch": "2.3.1",
    "torchaudio": "2.3.1",
    "transformers": "4.48.3",
}
RUNTIME_LICENSES = {
    "huggingface-hub": "Apache-2.0",
    "lightning": "Apache-2.0",
    "numpy": "BSD-3-Clause",
    "pyannote.audio": "MIT",
    "scipy": "BSD-3-Clause",
    "speechbrain": "Apache-2.0",
    "torch": "BSD-3-Clause",
    "torchaudio": "BSD-2-Clause",
    "transformers": "Apache-2.0",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact(path: Path) -> dict:
    return {"path": str(path.resolve()), "sizeBytes": path.stat().st_size, "sha256": sha256(path)}


def verify_artifact(record: dict) -> Path:
    path = Path(record.get("path", ""))
    if not path.is_file():
        raise ValueError(f"missing artifact: {path}")
    observed = sha256(path)
    if observed != record.get("sha256"):
        raise ValueError(f"artifact hash mismatch: {path}")
    return path


def verify_qwen_parity(separator: dict, qwen: dict) -> None:
    key = lambda item, hash_key: (
        item["windowID"], item["kind"], item.get("sourceIndex"), item[hash_key]
    )
    expected = sorted(key(item, "sha256") for item in separator["files"])
    observed = sorted(key(item, "audioSHA256") for item in qwen["items"])
    if expected != observed:
        raise ValueError("Qwen input parity mismatch")


def verify_separator_plan(separator: dict, plan_path: Path) -> None:
    separator_plan = verify_artifact(separator.get("plan", {}))
    if (separator_plan.resolve() != plan_path.resolve()
            or separator["plan"]["sha256"] != sha256(plan_path)):
        raise ValueError("separator plan provenance mismatch")


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(character for character in text if character.isalnum())


def edit_distance(left: str, right: str) -> int:
    left, right = normalize(left), normalize(right)
    if len(left) < len(right):
        left, right = right, left
    row = list(range(len(right) + 1))
    for left_index, left_character in enumerate(left, 1):
        next_row = [left_index]
        for right_index, right_character in enumerate(right, 1):
            next_row.append(min(
                next_row[-1] + 1,
                row[right_index] + 1,
                row[right_index - 1] + (left_character != right_character),
            ))
        row = next_row
    return row[-1]


def similarity(left: str, right: str) -> float:
    left, right = normalize(left), normalize(right)
    length = max(len(left), len(right))
    return 1.0 if length == 0 else 1.0 - edit_distance(left, right) / length


def classify_sources(mixture: str, sources: list[str], threshold: float) -> dict:
    normalized = [normalize(source) for source in sources]
    nonempty = [index for index, source in enumerate(normalized) if source]
    pair_similarities = [
        {"left": left, "right": right, "similarity": similarity(sources[left], sources[right])}
        for left, right in itertools.combinations(nonempty, 2)
    ]
    mixture_similarities = [similarity(mixture, source) if normalized[index] else 0.0
                            for index, source in enumerate(sources)]
    reasons = []
    if len(nonempty) != len(sources):
        reasons.append("empty-source")
    if any(item["similarity"] >= threshold for item in pair_similarities):
        reasons.append("near-identical-sources")
    if any(mixture_similarities[index] >= threshold for index in nonempty):
        reasons.append("mixture-equivalent-source")
    return {
        "accepted": not reasons,
        "reasons": reasons,
        "pairSimilarities": pair_similarities,
        "mixtureSimilarities": mixture_similarities,
    }


def _merge_spans(spans: list[tuple[int, int]]) -> list[list[int]]:
    merged: list[list[int]] = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def reference_speaker_scope(manifest: dict, speaker_map: dict[str, str]) -> dict:
    reference_labels = sorted({turn["speaker"] for turn in manifest["annotations"]["turns"]})
    missing = sorted(set(reference_labels) - set(speaker_map))
    pseudo_groups = sorted(
        label for label in reference_labels
        if speaker_map.get(label) == "Overlapping or group reaction"
    )
    identities = sorted(set(reference_labels) - set(pseudo_groups) - set(missing))
    complete = manifest["annotations"].get("status") == "complete" and not missing
    return {
        "measurementStatus": "complete" if complete else "incomplete",
        "globalIdentityCount": len(identities) if complete else None,
        "globalIdentityLabels": identities,
        "excludedPseudoGroupLabels": pseudo_groups,
        "unclassifiedReferenceLabels": missing,
    }


def _maximum_simultaneous_voices(turns: list[dict], start: int, end: int) -> int | None:
    boundaries = sorted({start, end} | {
        turn[point] for turn in turns for point in ("startSample", "endSample")
        if start < turn[point] < end
    })
    counts = [len({turn["speaker"] for turn in turns
                   if turn["startSample"] < right and left < turn["endSample"]})
              for left, right in zip(boundaries, boundaries[1:])]
    return max(counts, default=None)


def oracle_windows(manifest: dict) -> list[dict]:
    if manifest.get("corpusID") != CORPUS:
        raise ValueError("ticket #101 is restricted to the development corpus")
    fixture = manifest.get("fixture", {})
    if fixture.get("sampleRate") != SAMPLE_RATE:
        raise ValueError("the authoritative fixture must be mono 16 kHz")
    by_speaker: dict[str, list[tuple[int, int]]] = {}
    for turn in manifest["annotations"]["turns"]:
        by_speaker.setdefault(turn["speaker"], []).append(
            (turn["startSample"], turn["endSample"])
        )
    by_speaker = {speaker: _merge_spans(spans) for speaker, spans in by_speaker.items()}
    boundaries = sorted({point for spans in by_speaker.values() for span in spans for point in span})
    overlap = []
    for start, end in zip(boundaries, boundaries[1:]):
        speakers = sorted(speaker for speaker, spans in by_speaker.items()
                          if any(left < end and start < right for left, right in spans))
        if len(speakers) > 1:
            if overlap and start == overlap[-1][1]:
                overlap[-1][1] = end
                overlap[-1][2].update(speakers)
            else:
                overlap.append([start, end, set(speakers)])
    windows = []
    for index, (oracle_start, oracle_end, speakers) in enumerate(overlap, 1):
        start = max(0, oracle_start - PADDING_SAMPLES)
        end = min(fixture["sampleCount"], oracle_end + PADDING_SAMPLES)
        turns = [turn for turn in manifest["annotations"]["turns"]
                 if turn["speaker"] in speakers
                 and turn["startSample"] < oracle_end and oracle_start < turn["endSample"]]
        simultaneous = _maximum_simultaneous_voices(
            manifest["annotations"]["turns"], oracle_start, oracle_end
        )
        windows.append({
            "id": f"window-{index:02d}",
            "startSample": start,
            "endSample": end,
            "oracleStartSample": oracle_start,
            "oracleEndSample": oracle_end,
            "oracleSeconds": (oracle_end - oracle_start) / SAMPLE_RATE,
            "speakers": sorted(speakers),
            "expectedSimultaneousVoiceCount": simultaneous,
            "simultaneousVoiceMeasurementStatus": (
                "complete" if simultaneous is not None else "incomplete"
            ),
            "withinPixITCapacity": (
                simultaneous <= PIXIT_MAX_SIMULTANEOUS_VOICES
                if simultaneous is not None else None
            ),
            "referenceTurns": turns,
        })
    return windows


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def iso8601(date: datetime) -> str:
    return date.isoformat(timespec="seconds").replace("+00:00", "Z")


def make_plan(args: argparse.Namespace) -> None:
    manifest_path = Path(args.manifest).resolve()
    audio_path = Path(args.audio).resolve()
    speaker_map_path = Path(args.speaker_map).resolve()
    manifest = json.loads(manifest_path.read_text())
    if manifest["annotations"].get("status") != "complete" or not manifest["annotations"].get("reviewedBy"):
        raise ValueError("development annotations are not authoritative")
    if sha256(audio_path) != manifest["fixture"]["sha256"]:
        raise ValueError("development mixture hash mismatch")
    speaker_reference = next(
        reference for reference in manifest["source"]["references"]
        if reference["label"] == "speaker-map"
    )
    if sha256(speaker_map_path) != speaker_reference["sha256"]:
        raise ValueError("development speaker map hash mismatch")
    speaker_scope = reference_speaker_scope(
        manifest, json.loads(speaker_map_path.read_text())
    )
    speaker_scope["provenance"] = artifact(speaker_map_path)
    windows = oracle_windows(manifest)
    if abs(sum(window["oracleSeconds"] for window in windows) - 25.5) > 1e-9:
        raise ValueError("authoritative DEV overlap duration changed")
    write_json(Path(args.output), {
        "schemaVersion": 1,
        "ticket": TICKET,
        "scope": "development-oracle-only",
        "corpusID": CORPUS,
        "manifest": artifact(manifest_path),
        "mixture": artifact(audio_path),
        "referenceSpeakerScope": speaker_scope,
        "pixitLimitations": {
            "maximumSimultaneousVoices": PIXIT_MAX_SIMULTANEOUS_VOICES,
            "resolvesGlobalSpeakerIdentity": False,
        },
        "similarityCalibration": {
            "startingPoint": STARTING_SIMILARITY,
            "developmentCandidates": SIMILARITY_CANDIDATES,
            "productConstant": False,
        },
        "modelPins": MODEL_REVISIONS,
        "windows": windows,
    })


def _local_model_reference(value: str, repositories: dict[str, Path]) -> str:
    model_id = value.split("@", 1)[0]
    if model_id not in repositories:
        return value
    path = repositories[model_id]
    if model_id == "pyannote/separation-ami-1.0":
        path /= "pytorch_model.bin"
    if not path.exists():
        raise ValueError(f"missing pinned model path: {model_id}")
    return str(path)


def _patched_config(separator_directory: Path, repositories: dict[str, Path], output: Path) -> Path:
    import yaml

    config = yaml.safe_load((separator_directory / "config.yaml").read_text())

    def replace(value):
        if isinstance(value, dict):
            return {key: replace(item) for key, item in value.items()}
        if isinstance(value, list):
            return [replace(item) for item in value]
        if isinstance(value, str):
            return _local_model_reference(value, repositories)
        return value

    patched = replace(config)
    unresolved = {value for value in _strings(patched)
                  if re.fullmatch(r"[\w.-]+/[\w.-]+(?:@[\w.-]+)?", value)}
    if unresolved:
        raise ValueError(f"unpinned model references: {sorted(unresolved)}")
    path = output / "pinned-config.yaml"
    path.write_text(yaml.safe_dump(patched, sort_keys=True))
    return path


def _strings(value):
    if isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)
    elif isinstance(value, str):
        yield value


def _inventory(paths: dict[str, Path]) -> list[dict]:
    files = []
    for model_id, root in sorted(paths.items()):
        for path in sorted(root.rglob("*")):
            if path.is_file():
                files.append({"modelID": model_id, "relativePath": str(path.relative_to(root)), **artifact(path)})
    return files


def _source_sample_bounds(actual: int, expected: int) -> tuple[int, int]:
    if actual < expected:
        raise ValueError(f"separated source is too short: {actual} < {expected}")
    return 0, expected


def _monitor_native_memory(path: Path, stop: threading.Event) -> None:
    with path.open("w") as handle:
        while True:
            record = {"at": iso8601(datetime.now(timezone.utc))}
            for key, command in (
                ("memoryPressure", ["/usr/bin/memory_pressure", "-Q"]),
                ("swapUsage", ["/usr/sbin/sysctl", "vm.swapusage"]),
            ):
                result = subprocess.run(command, capture_output=True, text=True, timeout=5)
                record[key] = (result.stdout or result.stderr).strip()
                record[f"{key}ExitStatus"] = result.returncode
            handle.write(json.dumps(record, sort_keys=True) + "\n")
            handle.flush()
            if stop.wait(1):
                break


def separate(args: argparse.Namespace) -> None:
    if os.environ.get("BENCHMARK_SLOT_GRANTED") != str(TICKET):
        raise ValueError("refusing heavyweight run without BENCHMARK_SLOT_GRANTED=101")
    if sys.version_info[:2] != (3, 11):
        raise ValueError("PixIT runtime is pinned to Python 3.11")
    token = os.environ.get("HF_TOKEN")
    if not token:
        raise ValueError("HF_TOKEN is required after accepting both pyannote model conditions")

    from huggingface_hub import snapshot_download
    import numpy as np
    import scipy.io.wavfile
    import torch
    import torchaudio
    from importlib.metadata import version
    from pyannote.audio import Pipeline

    versions = {name: version(name) for name in RUNTIME_VERSIONS}
    if versions != RUNTIME_VERSIONS:
        raise ValueError(f"PixIT runtime version mismatch: {versions}")

    plan_path = Path(args.plan).resolve()
    plan = json.loads(plan_path.read_text())
    if plan.get("ticket") != TICKET or plan.get("scope") != "development-oracle-only":
        raise ValueError("invalid or non-DEV plan")
    mixture_path = verify_artifact(plan["mixture"])
    verify_artifact(plan["manifest"])
    windows = [window for window in plan["windows"] if not args.window_id or window["id"] == args.window_id]
    if args.stage == "smoke" and len(windows) != 1:
        raise ValueError("smoke must process exactly one oracle window")
    if args.stage == "development" and len(windows) != len(plan["windows"]):
        raise ValueError("development must process every oracle window")

    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    pressure_path = output / "native-memory-pressure.jsonl"
    pressure_stop = threading.Event()
    pressure_thread = threading.Thread(
        target=_monitor_native_memory, args=(pressure_path, pressure_stop), daemon=True
    )
    pressure_thread.start()
    cache = Path(args.cache).resolve()
    cache.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc)
    started_clock = time.monotonic()
    repositories = {}
    separator_id = "pyannote/speech-separation-ami-1.0"
    repositories[separator_id] = Path(snapshot_download(
        separator_id, revision=MODEL_REVISIONS[separator_id], token=token, cache_dir=cache
    ))
    if repositories[separator_id].name != MODEL_REVISIONS[separator_id]:
        raise ValueError("separator snapshot revision mismatch")
    # Download only transitive model IDs declared by the pinned separator configuration.
    import yaml
    raw_config = yaml.safe_load((repositories[separator_id] / "config.yaml").read_text())
    referenced = {value.split("@", 1)[0] for value in _strings(raw_config)
                  if value.split("@", 1)[0] in MODEL_REVISIONS}
    if "pyannote/separation-ami-1.0" in referenced:
        referenced.add("microsoft/wavlm-large")
    for model_id in sorted(referenced):
        repositories[model_id] = Path(snapshot_download(
            model_id, revision=MODEL_REVISIONS[model_id], token=token, cache_dir=cache
        ))
        if repositories[model_id].name != MODEL_REVISIONS[model_id]:
            raise ValueError(f"model snapshot revision mismatch: {model_id}")
    config_path = _patched_config(repositories[separator_id], repositories, output)
    os.environ.update({
        "HF_HUB_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "PYANNOTE_METRICS_ENABLED": "0",
    })
    from transformers import AutoModel
    original_from_pretrained = AutoModel.from_pretrained

    def pinned_from_pretrained(model_id, *arguments, **keywords):
        return original_from_pretrained(
            _local_model_reference(model_id, repositories), *arguments, **keywords
        )

    AutoModel.from_pretrained = pinned_from_pretrained
    try:
        separator = Pipeline.from_pretrained(
            str(config_path), use_auth_token=token, cache_dir=str(cache)
        )
    finally:
        AutoModel.from_pretrained = original_from_pretrained
    separator.to(torch.device("cpu"))
    waveform, sample_rate = torchaudio.load(str(mixture_path))
    if sample_rate != SAMPLE_RATE or waveform.shape[0] != 1:
        raise ValueError("mixture must decode as mono 16 kHz")
    expected_samples = json.loads(verify_artifact(plan["manifest"]).read_text())["fixture"]["sampleCount"]
    if waveform.shape[1] != expected_samples:
        raise ValueError("mixture sample count mismatch")

    files = []
    window_records = []
    for window in windows:
        window_started = time.monotonic()
        crop = waveform[:, window["startSample"]:window["endSample"]]
        mixture_file = output / f'{window["id"]}-mixture.wav'
        scipy.io.wavfile.write(mixture_file, SAMPLE_RATE, np.clip(
            crop.squeeze(0).numpy() * 32767, -32768, 32767
        ).astype(np.int16))
        diarization, sources = separator({"waveform": crop, "sample_rate": SAMPLE_RATE})
        rttm = output / f'{window["id"]}.rttm'
        with rttm.open("w") as handle:
            diarization.write_rttm(handle)
        entries = [{
            "windowID": window["id"], "kind": "mixture", "sourceIndex": None,
            "startSample": window["startSample"], "endSample": window["endSample"],
            **artifact(mixture_file),
        }]
        labels = list(diarization.labels())
        source_start, source_end = _source_sample_bounds(
            sources.data.shape[0], crop.shape[-1]
        )
        for index in range(sources.data.shape[1]):
            source_file = output / f'{window["id"]}-source-{index + 1:02d}.wav'
            scipy.io.wavfile.write(source_file, SAMPLE_RATE, np.clip(
                sources.data[source_start:source_end, index] * 32767, -32768, 32767
            ).astype(np.int16))
            if scipy.io.wavfile.read(source_file)[1].shape[0] != crop.shape[-1]:
                raise ValueError("separated source sample count mismatch")
            entries.append({
                "windowID": window["id"], "kind": "source", "sourceIndex": index + 1,
                "speakerLabel": labels[index] if index < len(labels) else None,
                "startSample": window["startSample"], "endSample": window["endSample"],
                **artifact(source_file),
            })
        files.extend(entries)
        window_records.append({
            "windowID": window["id"], "elapsedSeconds": time.monotonic() - window_started,
            "diarization": artifact(rttm), "files": entries,
        })
    del separator
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
        "corpusID": CORPUS,
        "plan": artifact(plan_path),
        "runtime": {"python": sys.version, "packages": versions,
                    "packageLicenses": RUNTIME_LICENSES, "device": "cpu"},
        "models": [{"modelID": model_id, "revision": MODEL_REVISIONS[model_id],
                    "license": MODEL_LICENSES[model_id]}
                   for model_id in sorted(repositories)],
        "modelInventory": _inventory(repositories),
        "implementation": artifact(Path(__file__).resolve()),
        "nativeMemoryPressure": artifact(pressure_path),
        "worker": {
            "startedAt": iso8601(started), "exitedAt": iso8601(exited),
            "elapsedSeconds": time.monotonic() - started_clock,
            "peakResidentBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "exitStatus": 0,
        },
        "windows": window_records,
        "files": files,
    }
    write_json(output / "separator-evidence.json", evidence)


def _material_changes(window: dict, mixture: str, sources: list[str]) -> tuple[list[dict], list[dict]]:
    recovered, lost = [], []
    for turn in window["referenceTurns"]:
        reference = turn["japanese"]
        mixture_score = similarity(reference, mixture)
        source_score = max((similarity(reference, source) for source in sources), default=0.0)
        example = {
            "turnID": turn["id"], "speaker": turn["speaker"], "reference": reference,
            "mixture": mixture, "bestSource": max(sources, key=lambda source: similarity(reference, source), default=""),
            "mixtureSimilarity": mixture_score, "sourceSimilarity": source_score,
        }
        if source_score > mixture_score + 0.05:
            recovered.append(example)
        elif mixture_score > source_score + 0.05:
            lost.append(example)
    return recovered, lost


def speaker_analysis(plan: dict, window_reports: list[dict], threshold: float) -> dict:
    evaluated = {window["windowID"]: window for window in window_reports}
    windows = []
    for reference in plan["windows"]:
        result = evaluated.get(reference["id"])
        accepted = result and result["thresholds"][str(threshold)]["accepted"]
        transcripts = result["sourceTranscripts"] if result else []
        windows.append({
            "windowID": reference["id"],
            "simultaneousVoiceMeasurementStatus": reference["simultaneousVoiceMeasurementStatus"],
            "expectedSimultaneousVoiceCount": reference["expectedSimultaneousVoiceCount"],
            "referenceContributorLabels": reference["speakers"],
            "withinPixITCapacity": reference["withinPixITCapacity"],
            "evaluationStatus": "evaluated" if result else "not-evaluated",
            "producedPixITTrackCount": len(transcripts) if result else None,
            "acceptedPixITTrackCount": len(transcripts) if accepted else (0 if result else None),
            "distinctAcceptedTranscriptCount": (
                len({normalize(text) for text in transcripts if normalize(text)})
                if accepted else (0 if result else None)
            ),
            "distinctRecoveredReferenceUtteranceCount": (
                len({item["turnID"] for item in result["recovered"]}) if result else None
            ),
            "distinctLostReferenceUtteranceCount": (
                len({item["turnID"] for item in result["lost"]}) if result else None
            ),
        })
    return {
        "globalReference": plan["referenceSpeakerScope"],
        "pixitLimitations": plan["pixitLimitations"],
        "oracleWindows": windows,
    }


def report(args: argparse.Namespace) -> None:
    plan_path = Path(args.plan).resolve()
    plan = json.loads(plan_path.read_text())
    separator_path = Path(args.separator)
    qwen_path = Path(args.qwen)
    separator = json.loads(separator_path.read_text())
    qwen = json.loads(qwen_path.read_text())
    if separator.get("ticket") != TICKET or qwen.get("ticket") != TICKET:
        raise ValueError("wrong ticket evidence")
    if separator.get("stage") != args.stage or qwen.get("stage") != args.stage:
        raise ValueError("stage mismatch")
    verify_separator_plan(separator, plan_path)
    verify_artifact(separator["nativeMemoryPressure"])
    if not qwen.get("strictlySequential"):
        raise ValueError("PixIT and Qwen workers overlapped")
    for record in separator["files"]:
        verify_artifact(record)
    if qwen.get("inputSHA256") != sha256(separator_path):
        raise ValueError("Qwen did not consume this separator evidence")
    verify_qwen_parity(separator, qwen)
    by_window = {}
    for item in qwen["items"]:
        by_window.setdefault(item["windowID"], []).append(item)
    window_reports = []
    plan_by_id = {window["id"]: window for window in plan["windows"]}
    for window_id, items in sorted(by_window.items()):
        mixture = next(item["transcript"] for item in items if item["kind"] == "mixture")
        sources = [item["transcript"] for item in items if item["kind"] == "source"]
        recovered, lost = _material_changes(plan_by_id[window_id], mixture, sources)
        window_reports.append({
            "windowID": window_id,
            "mixtureTranscript": mixture,
            "sourceTranscripts": sources,
            "recovered": recovered,
            "lost": lost,
            "thresholds": {str(value): classify_sources(mixture, sources, value)
                           for value in SIMILARITY_CANDIDATES},
        })
    calibration = []
    for threshold in SIMILARITY_CANDIDATES:
        accepted = [window for window in window_reports
                    if window["thresholds"][str(threshold)]["accepted"]]
        recovered = sum(len(window["recovered"]) for window in accepted)
        lost = sum(len(window["lost"]) for window in accepted)
        calibration.append({
            "threshold": threshold, "acceptedWindows": len(accepted),
            "recoveredTurns": recovered, "lostTurns": lost,
            "netRecoveredTurns": recovered - lost,
        })
    selected = max(calibration, key=lambda item: (
        item["netRecoveredTurns"], item["recoveredTurns"],
        -abs(item["threshold"] - STARTING_SIMILARITY), item["threshold"],
    ))
    write_json(Path(args.output), {
        "schemaVersion": 1,
        "ticket": TICKET,
        "stage": args.stage,
        "scope": "development-oracle-only",
        "inputs": {"plan": artifact(Path(args.plan)), "separator": artifact(separator_path),
                   "qwen": artifact(qwen_path)},
        "calibration": {
            "startingPoint": STARTING_SIMILARITY,
            "selectedDevelopmentThreshold": selected["threshold"],
            "productConstant": False,
            "candidates": calibration,
        },
        "speakerAnalysis": speaker_analysis(plan, window_reports, selected["threshold"]),
        "windows": window_reports,
        "resources": {
            "pixit": {**separator["worker"],
                      "nativeMemoryPressure": separator["nativeMemoryPressure"]},
            "qwen": qwen["worker"],
        },
        "gates": {
            "rawArtifactsVerified": True,
            "workersSequential": True,
            "developmentOnly": True,
            "distinctRecovery": args.stage == "development" and selected["netRecoveredTurns"] > 0,
            "holdoutOpened": False,
        },
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    plan = subparsers.add_parser("plan")
    plan.add_argument("--manifest", required=True)
    plan.add_argument("--audio", required=True)
    plan.add_argument("--speaker-map", required=True)
    plan.add_argument("--output", required=True)
    plan.set_defaults(run=make_plan)
    run = subparsers.add_parser("separate")
    run.add_argument("--plan", required=True)
    run.add_argument("--output", required=True)
    run.add_argument("--cache", required=True)
    run.add_argument("--stage", choices=("smoke", "development"), required=True)
    run.add_argument("--window-id")
    run.set_defaults(run=separate)
    audit = subparsers.add_parser("report")
    audit.add_argument("--plan", required=True)
    audit.add_argument("--separator", required=True)
    audit.add_argument("--qwen", required=True)
    audit.add_argument("--stage", choices=("smoke", "development"), required=True)
    audit.add_argument("--output", required=True)
    audit.set_defaults(run=report)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
