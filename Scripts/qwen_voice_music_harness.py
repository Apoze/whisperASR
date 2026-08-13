#!/usr/bin/env python3
"""Issue #93: prepare and audit one DEV-only Spleeter vocals candidate."""

from __future__ import annotations

import argparse
import csv
import difflib
import gzip
import hashlib
import json
import os
import resource
import signal
import subprocess
import sys
import tempfile
import time
import wave
from array import array
from pathlib import Path

from report_qwen_error_diagnostic import classify_unit, normalize


SAMPLE_RATE = 16_000
SEGMENTS_SHA256 = "e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81"
AUDIO_SHA256 = "494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2"
SAMPLE_COUNT = 15_315_325
QWEN_MODEL = {
    "backend": "qwen-ja",
    "modelID": "ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit",
    "revision": "7c70d18cb650655d32eafb952a74a49c6a3caad0",
    "weightSHA256": {
        "model.safetensors": "bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954"
    },
}
PROTECTED = {
    "cue-0186": "soft-voice",
    "cue-0194-part-2": "laughter",
    "cue-0194-part-3": "scream",
}
CLEAN = {
    "cue-0001": "clean-speech",
    "cue-0078": "clean-laughter",
    "cue-0238": "clean-laughter-and-speech",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    if path.suffix == ".gz":
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            return json.load(handle)
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")


def read_pcm(path: Path) -> array:
    with wave.open(str(path), "rb") as handle:
        actual = (handle.getnchannels(), handle.getsampwidth(), handle.getframerate())
        if actual != (1, 2, SAMPLE_RATE):
            raise RuntimeError(f"expected mono PCM s16le/16k, got {actual}: {path}")
        payload = handle.readframes(handle.getnframes())
    values = array("h")
    values.frombytes(payload)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def write_pcm(path: Path, values: array, channels: int = 1) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = array("h", values)
    if sys.byteorder != "little":
        payload.byteswap()
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(payload.tobytes())


def build_plan(document: dict, sample_count: int) -> dict:
    if document.get("corpusRole") != "development" or document.get("holdoutOpened"):
        raise RuntimeError("E23 plan is not closed DEV evidence")
    units = document.get("units", [])
    targets = [unit for unit in units
               if unit.get("automaticSignals", {}).get("voiceMusicTrigger") is True]
    if not targets:
        raise RuntimeError("E23 contains no reference-free voice/music triggers")
    target_ids = {unit["id"] for unit in targets}
    if target_ids & CLEAN.keys() or not PROTECTED.keys() <= target_ids:
        raise RuntimeError("frozen target/control membership changed")

    frozen_targets = []
    for unit in targets:
        frozen_targets.append({
            "id": unit["id"],
            "chunkIndex": unit["chunkIndex"],
            "start": unit["start"],
            "end": unit["end"],
            "startSample": round(unit["start"] * SAMPLE_RATE),
            "endSample": round(unit["end"] * SAMPLE_RATE),
            "automaticSignals": unit["automaticSignals"],
        })
    montage_cursor = 0
    frozen_contexts = []
    for start_sample, end_sample in merged_ranges(frozen_targets):
        if not (0 <= start_sample < end_sample <= sample_count):
            raise RuntimeError("E23 target is outside frozen PCM")
        frozen_contexts.append({
            "sourceStartSample": start_sample,
            "sourceEndSample": end_sample,
            "montageStartSample": montage_cursor,
        })
        montage_cursor += end_sample - start_sample + SAMPLE_RATE

    by_id = {unit["id"]: unit for unit in units}
    frozen_by_id = {unit["id"]: unit for unit in frozen_targets}

    return {
        "schemaVersion": 1,
        "ticket": 93,
        "corpusID": "qudu2fx3ncc",
        "corpusRole": "development",
        "holdoutOpened": False,
        "selectionRule": "automaticSignals.voiceMusicTrigger == true",
        "selectionInputs": [
            "id", "chunkIndex", "start", "end",
            "automaticSignals.referenceFreeWeakness",
            "automaticSignals.voiceMusicAcoustic",
            "automaticSignals.voiceMusicTrigger",
        ],
        "forbiddenSelectionInputs": [
            "referenceJapanese", "referenceTurnIDs", "classification", "materialErrorScore"
        ],
        "targets": frozen_targets,
        "separatorContexts": frozen_contexts,
        "separatorInputSampleCount": montage_cursor,
        "targetDurationSeconds": sum(unit["end"] - unit["start"] for unit in targets),
        "protectedTargetControls": [
            {**frozen_by_id[unit_id], "kind": kind} for unit_id, kind in PROTECTED.items()
        ],
        "cleanControls": [
            {**{
                "id": by_id[unit_id]["id"],
                "chunkIndex": by_id[unit_id]["chunkIndex"],
                "start": by_id[unit_id]["start"],
                "end": by_id[unit_id]["end"],
                "startSample": round(by_id[unit_id]["start"] * SAMPLE_RATE),
                "endSample": round(by_id[unit_id]["end"] * SAMPLE_RATE),
                "automaticSignals": by_id[unit_id]["automaticSignals"],
            }, "kind": kind} for unit_id, kind in CLEAN.items()
        ],
    }


def command_plan(args: argparse.Namespace) -> None:
    if sha256(args.segments) != SEGMENTS_SHA256:
        raise RuntimeError("E23 segments hash changed")
    samples = read_pcm(args.audio)
    if len(samples) != SAMPLE_COUNT or sha256(args.audio) != AUDIO_SHA256:
        raise RuntimeError("frozen DEV PCM changed")
    write_json(args.output, build_plan(read_json(args.segments), len(samples)))


def command_prepare(args: argparse.Namespace) -> None:
    samples, plan = read_pcm(args.audio), read_json(args.plan)
    stereo = array("h")
    for context in plan["separatorContexts"]:
        part = samples[context["sourceStartSample"]:context["sourceEndSample"]]
        stereo.extend(value for sample in part for value in (sample, sample))
        stereo.extend([0] * (SAMPLE_RATE * 2))
    if len(stereo) // 2 != plan["separatorInputSampleCount"]:
        raise RuntimeError("separator montage sample count drifted")
    write_pcm(args.output, stereo, channels=2)


def command_separate(args: argparse.Namespace) -> None:
    command = [
        str(args.executable),
        f"--spleeter-vocals={args.vocals_model}",
        f"--spleeter-accompaniment={args.accompaniment_model}",
        "--num-threads=1",
        f"--input-wav={args.input}",
        f"--output-vocals-wav={args.output_vocals}",
        f"--output-accompaniment-wav={args.output_accompaniment}",
    ]
    started = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    with args.log.open("wb") as log:
        try:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                    check=False, timeout=1200)
            exit_code = result.returncode
        except subprocess.TimeoutExpired:
            exit_code = 124
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    runtime = {
        "command": command,
        "exitCode": exit_code,
        "elapsedSeconds": time.monotonic() - started,
        "peakChildRSSBytes": max(0, peak - before),
        "rawLog": str(args.log),
    }
    write_json(args.runtime, runtime)
    if exit_code or not args.output_vocals.is_file():
        raise RuntimeError("separator failed; raw log retained")


def command_run(args: argparse.Namespace) -> None:
    command = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
    if not command:
        raise RuntimeError("run-command requires a command after --")
    started = time.monotonic()
    timed_out = False
    with args.log.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            exit_code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            exit_code = 124
    write_json(args.runtime, {"command": command, "exitCode": exit_code,
                              "elapsedSeconds": time.monotonic() - started,
                              "timeoutSeconds": args.timeout, "timedOut": timed_out,
                              "rawLog": str(args.log)})
    if exit_code:
        raise RuntimeError("timed command failed; raw log retained")


def merged_ranges(targets: list[dict]) -> list[tuple[int, int]]:
    ranges = sorted((item["startSample"], item["endSample"]) for item in targets)
    merged: list[list[int]] = []
    for start, end in ranges:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(start, end) for start, end in merged]


def montage(samples: array, windows: list[dict]) -> array:
    result = array("h")
    for window in windows:
        result.extend(samples[window["startSample"]:window["endSample"]])
        result.extend([0] * (SAMPLE_RATE // 4))
    return result


def splice(base: array, processed: array, plan: dict) -> tuple[array, dict]:
    if len(processed) != plan["separatorInputSampleCount"]:
        raise RuntimeError("normalized vocals sample count differs from separator input")
    candidate = array("h", base)
    for target in plan["targets"]:
        context = next(item for item in plan["separatorContexts"]
                       if item["sourceStartSample"] <= target["startSample"]
                       and item["sourceEndSample"] >= target["endSample"])
        offset = context["montageStartSample"] - context["sourceStartSample"]
        start, end = target["startSample"], target["endSample"]
        candidate[start:end] = processed[start + offset:end + offset]

    ranges, changed_inside, changed_outside = merged_ranges(plan["targets"]), 0, 0
    range_index = 0
    for index, (left, right) in enumerate(zip(base, candidate)):
        while range_index < len(ranges) and index >= ranges[range_index][1]:
            range_index += 1
        inside = range_index < len(ranges) and ranges[range_index][0] <= index
        if left != right:
            if inside:
                changed_inside += 1
            else:
                changed_outside += 1
    if not changed_inside or changed_outside:
        raise RuntimeError("candidate did not change only frozen target samples")
    clean = [{"id": item["id"], "byteIdentical":
              base[item["startSample"]:item["endSample"]]
              == candidate[item["startSample"]:item["endSample"]]}
             for item in plan["cleanControls"]]
    if not all(item["byteIdentical"] for item in clean):
        raise RuntimeError("clean audio control changed")
    return candidate, {
        "changedTargetSamples": changed_inside,
        "changedOutsideTargetSamples": changed_outside,
        "cleanControls": clean,
    }


def command_splice(args: argparse.Namespace) -> None:
    base, processed, plan = read_pcm(args.audio), read_pcm(args.processed), read_json(args.plan)
    candidate, audit = splice(base, processed, plan)
    write_pcm(args.output, candidate)
    write_pcm(args.before_targets, montage(base, plan["targets"]))
    write_pcm(args.after_targets, montage(candidate, plan["targets"]))
    write_pcm(args.before_controls, montage(base, plan["cleanControls"]))
    write_pcm(args.after_controls, montage(candidate, plan["cleanControls"]))
    audit.update({
        "baseline": {"path": str(args.audio), "sha256": sha256(args.audio)},
        "candidate": {"path": str(args.output), "sha256": sha256(args.output)},
        "beforeTargets": str(args.before_targets),
        "afterTargets": str(args.after_targets),
        "beforeCleanControls": str(args.before_controls),
        "afterCleanControls": str(args.after_controls),
        "sampleCount": len(candidate),
        "sampleRate": SAMPLE_RATE,
    })
    write_json(args.audit, audit)


def text_in_window(raw: dict, start: float, end: float) -> str:
    items = [item for chunk in raw["alignment"]["chunks"] for item in chunk["rawItems"]
             if start <= (item["start"] + item["end"]) / 2 < end]
    return "".join(item["text"] for item in items)


def is_frozen_qwen_model(model: dict) -> bool:
    return all(model.get(key) == value for key, value in QWEN_MODEL.items()
               if key != "weightSHA256") and all(
        model.get("weightSHA256", {}).get(name) == digest
        for name, digest in QWEN_MODEL["weightSHA256"].items()
    )


def recovered_reference_indices(reference: str, hypothesis: str) -> set[int]:
    result: set[int] = set()
    for match in difflib.SequenceMatcher(
        None, normalize(reference), normalize(hypothesis), autojunk=False
    ).get_matching_blocks():
        result.update(range(match.a, match.a + match.size))
    return result


def change_examples(reference: str, baseline: str, candidate: str) -> dict:
    normalized = normalize(reference)
    baseline_indices = recovered_reference_indices(reference, baseline)
    candidate_indices = recovered_reference_indices(reference, candidate)

    def fragments(indices: set[int]) -> list[str]:
        groups: list[str] = []
        for index in sorted(indices):
            if not groups or index - 1 not in indices:
                groups.append(normalized[index])
            else:
                groups[-1] += normalized[index]
        return sorted(groups, key=lambda value: (-len(value), value))[:5]

    return {
        "recoveredByCandidate": fragments(candidate_indices - baseline_indices),
        "lostByCandidate": fragments(baseline_indices - candidate_indices),
    }


def adjacent_duplicates(text: str) -> int:
    lines = [normalize(line) for line in text.splitlines() if normalize(line)]
    return sum(left == right for left, right in zip(lines, lines[1:]))


def portable_audio_audit(audit: dict) -> dict:
    result = {key: value for key, value in audit.items()
              if key not in {"baseline", "candidate", "beforeTargets", "afterTargets",
                             "beforeCleanControls", "afterCleanControls"}}
    for key in ("baseline", "candidate"):
        digest = audit[key]["sha256"]
        result[key] = {"locator": f"urn:sha256:{digest}", "sha256": digest}
    result["montages"] = {}
    for key in ("beforeTargets", "afterTargets", "beforeCleanControls", "afterCleanControls"):
        path = Path(audit[key])
        result["montages"][key] = {
            "retention": "local-benchmark-artifact",
            "sha256": sha256(path),
        }
    return result


def portable_paths(value):
    if isinstance(value, dict):
        return {key: portable_paths(item) for key, item in value.items()}
    if isinstance(value, list):
        return [portable_paths(item) for item in value]
    if isinstance(value, str):
        return value.replace(str(Path.cwd()), "$REPO")
    return value


def assert_same_json(path: Path, expected: dict) -> None:
    if read_json(path) != expected:
        raise RuntimeError(f"archived JSON differs from scored input: {path}")


def command_report(args: argparse.Namespace) -> None:
    plan, segments, raw = read_json(args.plan), read_json(args.segments), read_json(args.raw)
    assert_same_json(args.retained_raw, raw)
    if (sha256(args.baseline_raw) != "1f5edc2fcb929c9abc2cb85256f326bbf2891a200ef66d1c1cb9a66a9c711ce8"
            or sha256(args.reference_csv) != "df0bce85845cca243e0ed4ae3c5b885e519cc4f0aada9c6ddb1b169cb22f93ba"):
        raise RuntimeError("baseline raw or reference CSV changed")
    baseline_raw = read_json(args.baseline_raw)
    manifest, audit, runtime = read_json(args.manifest), read_json(args.audit), read_json(args.runtime)
    if (not is_frozen_qwen_model(raw.get("model", {}))
            or not is_frozen_qwen_model(baseline_raw.get("model", {}))
            or manifest.get("selectedBackend") != "qwen-ja"):
        raise RuntimeError("candidate changed the frozen Qwen ASR")
    units = {item["id"]: item for item in segments["units"]}
    with args.reference_csv.open(encoding="utf-8-sig", newline="") as handle:
        reference = "\n".join(
            row["japanese"] for row in csv.DictReader(handle)
            if row["speaker_id"] != "SPEAKER_NONE" and row["japanese"].strip()
        )
    annotations = [units[target["id"]]["classification"] for target in plan["targets"]]
    terms = list(dict.fromkeys(
        value for item in annotations for value in item["terms"]["recovered"]
        + item["terms"]["lost"]
    ))
    meanings = list(dict.fromkeys(
        value for item in annotations for value in item["meaning"]["recovered"]
        + item["meaning"]["lost"]
    ))
    baseline_global = classify_unit(reference, baseline_raw["rawASR"], terms, meanings)
    candidate_global = classify_unit(reference, raw["rawASR"], terms, meanings)
    global_delta = (candidate_global["speech"]["recoveredCharacters"]
                    - baseline_global["speech"]["recoveredCharacters"])
    global_dimension_deltas = {
        dimension: (len(candidate_global[dimension]["recovered"])
                    - len(baseline_global[dimension]["recovered"]))
        for dimension in ("terms", "numbers", "meaning")
    }
    global_dimension_changes = {
        dimension: {
            "newlyRecovered": [
                value for value in candidate_global[dimension]["recovered"]
                if value not in baseline_global[dimension]["recovered"]
            ],
            "newlyLost": [
                value for value in baseline_global[dimension]["recovered"]
                if value not in candidate_global[dimension]["recovered"]
            ],
        } for dimension in ("terms", "numbers", "meaning")
    }
    raw_global = {
        "scope": "complete rawASR strings; independent of forced-alignment timestamps",
        "baselineClassification": baseline_global,
        "candidateClassification": candidate_global,
        "recoveredCharacterDelta": global_delta,
        "dimensionDeltas": global_dimension_deltas,
        "dimensionChanges": global_dimension_changes,
        "speechExamples": change_examples(reference, baseline_raw["rawASR"], raw["rawASR"]),
        "baselineAdjacentDuplicates": adjacent_duplicates(baseline_raw["rawASR"]),
        "candidateAdjacentDuplicates": adjacent_duplicates(raw["rawASR"]),
    }
    rows, gained, erased = [], 0, 0
    for target in plan["targets"]:
        baseline = units[target["id"]]
        baseline_text = text_in_window(baseline_raw, target["start"], target["end"])
        candidate_text = text_in_window(raw, target["start"], target["end"])
        annotation = baseline["classification"]
        terms = annotation["terms"]["recovered"] + annotation["terms"]["lost"]
        meanings = annotation["meaning"]["recovered"] + annotation["meaning"]["lost"]
        prior = classify_unit(baseline["referenceJapanese"], baseline_text, terms, meanings)
        observed = classify_unit(baseline["referenceJapanese"], candidate_text, terms, meanings)
        delta = (observed["speech"]["recoveredCharacters"]
                 - prior["speech"]["recoveredCharacters"])
        gained += max(0, delta)
        erased += max(0, -delta)
        rows.append({
            "id": target["id"], "kind": PROTECTED.get(target["id"]),
            "start": target["start"], "end": target["end"],
            "baselineJapanese": baseline_text, "candidateJapanese": candidate_text,
            "referenceJapanese": baseline["referenceJapanese"],
            "baselineClassification": prior, "candidateClassification": observed,
            "recoveredCharacterDelta": delta,
            "speechErased": bool(normalize(baseline_text) and not normalize(candidate_text)),
        })
    clean_rows = []
    for control in plan["cleanControls"]:
        baseline = text_in_window(baseline_raw, control["start"], control["end"])
        candidate = text_in_window(raw, control["start"], control["end"])
        clean_rows.append({"id": control["id"], "kind": control["kind"],
                           "baselineJapanese": baseline, "candidateJapanese": candidate,
                           "textIdentical": baseline == candidate})
    protected = [row for row in rows if row["kind"]]
    durations = manifest.get("stageDurations", {})
    if isinstance(durations, dict):
        total_seconds = sum(durations.values())
    elif isinstance(durations, list) and len(durations) % 2 == 0:
        total_seconds = sum(durations[1::2])
    else:
        raise RuntimeError("unrecognized job stage-duration evidence")
    aligned_dimension_deltas = {
        dimension: sum(
            len(row["candidateClassification"][dimension]["recovered"])
            - len(row["baselineClassification"][dimension]["recovered"])
            for row in rows
        ) for dimension in ("terms", "numbers", "meaning")
    }
    baseline_empty = sum(row["baselineClassification"]["emptyTurn"] for row in rows)
    candidate_empty = sum(row["candidateClassification"]["emptyTurn"] for row in rows)
    baseline_duplicates = sum(
        normalize(left["baselineJapanese"]) == normalize(right["baselineJapanese"])
        for left, right in zip(rows, rows[1:]) if normalize(left["baselineJapanese"])
    )
    candidate_duplicates = sum(
        normalize(left["candidateJapanese"]) == normalize(right["candidateJapanese"])
        for left, right in zip(rows, rows[1:]) if normalize(left["candidateJapanese"])
    )
    generated = {item["path"] for item in manifest.get("generatedFiles", [])}
    final_english = {
        "baselineCharacters": len(args.baseline_english.read_text(encoding="utf-8").strip()),
        "candidateCharacters": (len(args.candidate_english.read_text(encoding="utf-8").strip())
                                if args.candidate_english and args.candidate_english.is_file() else 0),
        "candidateFinalPresent": "english-translation-transcript.txt" in generated
            and args.candidate_english is not None and args.candidate_english.is_file(),
        "comparable": False,
    }
    final_english["comparable"] = final_english["candidateFinalPresent"]
    pipeline_complete = manifest.get("status") == "completed" and not raw.get("failures")
    window_score_valid = pipeline_complete
    gates = {
        "rawGlobalSpeechNotWorse": global_delta >= 0,
        "rawGlobalTermsNumbersMeaningNotWorse": all(
            not changes["newlyLost"] for changes in global_dimension_changes.values()
        ),
        "rawOutputNotEmptyOrMoreDuplicated": not candidate_global["emptyTurn"]
            and raw_global["candidateAdjacentDuplicates"]
                <= raw_global["baselineAdjacentDuplicates"],
        "targetWindowScoreValid": window_score_valid,
        "moreTargetSpeechRecoveredThanErased": window_score_valid and gained > erased,
        "noTargetSpeechErased": window_score_valid
            and not any(row["speechErased"] for row in rows),
        "protectedScreamLaughterSoftVoiceNotWorse": all(
            row["recoveredCharacterDelta"] >= 0 and not row["speechErased"] for row in protected
        ) and window_score_valid,
        "targetTermsNumbersMeaningNotWorse": window_score_valid
            and all(delta >= 0 for delta in aligned_dimension_deltas.values()),
        "noNetNewTargetEmptiesOrDuplicates": window_score_valid
            and candidate_empty <= baseline_empty
            and candidate_duplicates <= baseline_duplicates,
        "cleanAudioByteIdentical": audit["changedOutsideTargetSamples"] == 0
            and all(item["byteIdentical"] for item in audit["cleanControls"]),
        "cleanControlTextIdentical": window_score_valid
            and all(item["textIdentical"] for item in clean_rows),
        "pipelineCompleted": pipeline_complete,
        "finalEnglishPresent": final_english["candidateFinalPresent"],
        "costNotRunaway": runtime["elapsedSeconds"] <= 1200
            and runtime["elapsedSeconds"] + total_seconds <= 2400,
        "developmentOnly": plan["corpusRole"] == "development" and not plan["holdoutOpened"],
    }
    decision = "GO-freeze-DEV-before-holdout" if all(gates.values()) else "NO-GO-stop-before-holdout"
    resume_runtime = read_json(args.resume_runtime) if args.resume_runtime else None
    asr_lifecycle = manifest.get("asrWorker", {}).get("lifecycle", {})
    available_samples = asr_lifecycle.get("availableMemorySamples", [])
    report = {
        "schemaVersion": 1, "ticket": 93, "decision": decision, "gates": gates,
        "rawQwenComparison": raw_global,
        "alignedWindowDiagnostic": {
            "promotional": window_score_valid,
            "reason": None if window_score_valid
                else "forced-alignment pipeline failed; timestamps are diagnostic only",
            "counts": {"targets": len(rows), "recoveredCharactersGained": gained,
                       "recoveredCharactersErased": erased,
                       "dimensionDeltas": aligned_dimension_deltas,
                       "baselineEmptyTurns": baseline_empty,
                       "candidateEmptyTurns": candidate_empty,
                       "baselineDuplicates": baseline_duplicates,
                       "candidateDuplicates": candidate_duplicates},
            "targetWindows": rows,
            "cleanControls": clean_rows,
        },
        "runtime": {"separator": portable_paths(runtime),
                    "resume": portable_paths(resume_runtime),
                    "qwenTranscribingSeconds": dict(zip(durations[::2], durations[1::2])).get(
                        "transcribing") if isinstance(durations, list) else durations.get("transcribing"),
                    "jobStageSeconds": total_seconds,
                    "equivalentTotalWallSeconds": runtime["elapsedSeconds"]
                        + (resume_runtime or {"elapsedSeconds": total_seconds})["elapsedSeconds"],
                    "peakJobMemoryBytes": manifest.get("peakMemoryBytes")},
        "memoryPressure": {
            "minimumAvailableMemoryBytes": min(
                (item["availableMemoryBytes"] for item in available_samples), default=None
            ),
            "asrTransitions": asr_lifecycle.get("pressureTransitions", []),
            "alignmentTransitions": raw.get("alignment", {}).get("worker", {}).get(
                "pressureTransitions", []
            ),
        },
        "rawComparison": {
            "baseline": {"artifact": args.baseline_raw.name,
                         "sha256": sha256(args.baseline_raw)},
            "candidate": {"artifact": args.retained_raw.name,
                          "sha256": sha256(args.retained_raw)},
        },
        "englishFinal": final_english,
        "pipelineFailures": raw.get("failures", []),
        "audioAudit": portable_audio_audit(audit),
        "holdoutOpened": False,
    }
    write_json(args.output, report)
    lines = [
        "# E27 — Qwen + Spleeter vocals DEV (#93)", "",
        f"**Decision: {decision}.** Holdout fermé.", "",
        f"- Raw Qwen global : delta parole {global_delta:+d}; termes/nombres/sens "
            + f"{global_dimension_deltas['terms']:+d}/{global_dimension_deltas['numbers']:+d}/"
            + f"{global_dimension_deltas['meaning']:+d}.",
        f"- Exemples raw récupérés : {raw_global['speechExamples']['recoveredByCandidate']}; "
            + f"perdus : {raw_global['speechExamples']['lostByCandidate']}.",
        f"- Termes candidat récupérés/perdus : "
            + f"{candidate_global['terms']['recovered']}/{candidate_global['terms']['lost']}; "
            + f"nombres : {candidate_global['numbers']['recovered']}/"
            + f"{candidate_global['numbers']['lost']}; sens : "
            + f"{candidate_global['meaning']['recovered']}/{candidate_global['meaning']['lost']}.",
        f"- Fenêtres ciblées : diagnostic aligné non promotionnel ({gained}/{erased}), "
            + "car l'alignement a échoué.",
        f"- Prétraitement : {runtime['elapsedSeconds']:.1f}s; job inchangé : {total_seconds:.1f}s.",
        f"- Anglais FINAL : {'présent' if final_english['candidateFinalPresent'] else 'absent (porte rouge)' }.",
        f"- Portes : `{json.dumps(gates, sort_keys=True)}`.", "",
        "Les SHA des audio complets et montages avant/après sont conservés. Le raw JA candidat "
        "et le JA/EN baseline sont versionnés; aucun EN candidat n'a été produit.",
    ]
    args.markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if decision.startswith("NO-GO"):
        raise RuntimeError(decision)


def self_test() -> None:
    unit = lambda identifier, trigger, start, end, chunk=0: {
        "id": identifier, "chunkIndex": chunk, "chunkStart": 0, "chunkEnd": 1,
        "start": start, "end": end,
        "automaticSignals": {"referenceFreeWeakness": ["weak"],
                             "voiceMusicAcoustic": ["dense"],
                             "voiceMusicTrigger": trigger},
        "referenceJapanese": "must-not-enter-plan", "materialErrorScore": 99,
    }
    units = [unit("cue-0186", True, 0.1, 0.2), unit("cue-0194-part-2", True, 0.2, 0.3),
             unit("cue-0194-part-3", True, 0.3, 0.4), unit("cue-0001", False, 0.4, 0.5),
             unit("cue-0078", False, 0.5, 0.6), unit("cue-0238", False, 0.6, 0.7)]
    document = {"corpusRole": "development", "holdoutOpened": False, "units": units}
    plan = build_plan(document, SAMPLE_RATE)
    serialized = json.dumps(plan)
    assert "must-not-enter-plan" not in serialized
    assert all("materialErrorScore" not in target for target in plan["targets"])
    enriched_model = json.loads(json.dumps(QWEN_MODEL))
    enriched_model["weightSHA256"]["vocab.json"] = "extra-provenance"
    assert is_frozen_qwen_model(enriched_model)
    enriched_model["revision"] = "changed"
    assert not is_frozen_qwen_model(enriched_model)
    base = array("h", range(SAMPLE_RATE))
    processed = array("h", [-1] * plan["separatorInputSampleCount"])
    candidate, audit = splice(base, processed, plan)
    assert audit["changedOutsideTargetSamples"] == 0
    assert candidate[0] == base[0] and candidate[round(.15 * SAMPLE_RATE)] == -1
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "test.wav"
        write_pcm(path, base)
        assert read_pcm(path) == base
        raw_path = Path(directory) / "raw.json"
        write_json(raw_path, {"rawASR": "same"})
        assert_same_json(raw_path, {"rawASR": "same"})
        try:
            assert_same_json(raw_path, {"rawASR": "different"})
        except RuntimeError:
            pass
        else:
            raise AssertionError("different archived raw must fail closed")
    print("qwen_voice_music_harness self-test: PASS")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("self-test")
    plan = sub.add_parser("plan")
    plan.add_argument("--segments", type=Path, required=True)
    plan.add_argument("--audio", type=Path, required=True)
    plan.add_argument("--output", type=Path, required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--audio", type=Path, required=True)
    prepare.add_argument("--plan", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)
    separate = sub.add_parser("separate")
    for name in ("executable", "vocals-model", "accompaniment-model", "input",
                 "output-vocals", "output-accompaniment", "log", "runtime"):
        separate.add_argument(f"--{name}", type=Path, required=True)
    run = sub.add_parser("run-command")
    run.add_argument("--timeout", type=int, required=True)
    run.add_argument("--log", type=Path, required=True)
    run.add_argument("--runtime", type=Path, required=True)
    run.add_argument("argv", nargs=argparse.REMAINDER)
    splice_parser = sub.add_parser("splice")
    for name in ("audio", "processed", "plan", "output", "audit", "before-targets",
                 "after-targets", "before-controls", "after-controls"):
        splice_parser.add_argument(f"--{name}", type=Path, required=True)
    report = sub.add_parser("report")
    for name in ("plan", "segments", "reference-csv", "baseline-raw", "raw", "retained-raw",
                 "manifest", "audit", "runtime", "baseline-english", "output", "markdown"):
        report.add_argument(f"--{name}", type=Path, required=True)
    report.add_argument("--candidate-english", type=Path)
    report.add_argument("--resume-runtime", type=Path)
    return result


def main() -> None:
    args = parser().parse_args()
    if args.command == "self-test": self_test()
    elif args.command == "plan": command_plan(args)
    elif args.command == "prepare": command_prepare(args)
    elif args.command == "separate": command_separate(args)
    elif args.command == "run-command": command_run(args)
    elif args.command == "splice": command_splice(args)
    elif args.command == "report": command_report(args)


if __name__ == "__main__":
    main()
