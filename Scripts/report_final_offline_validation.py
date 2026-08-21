#!/usr/bin/env python3
"""Score the two real Project jobs retained by ticket #121."""

from __future__ import annotations

import argparse
import collections
import difflib
import gzip
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import unicodedata
from datetime import datetime
from pathlib import Path

from report_high_quality_acceptance import (
    best_speaker_mapping,
    cer,
    diarization_metrics,
    edit_distance,
    merge_spans,
    overlap_duration,
    translation_rows,
)
from report_japanese_l7d import chrf_pp
from report_local_translator_bakeoff import (
    cue_integrity,
    glossary_accuracy,
    response_map,
    subtitle_quality,
    suspected_hallucination,
)


CORPORA = ("qudu2fx3ncc", "md62mmdz0m")


def test_log_summary(text: str, suite: str) -> dict:
    if re.search(
        r"(?:error: no such module|Build failed|emit-module command failed|"
        r"fatal error:.*(?:build|compile))",
        text,
        re.IGNORECASE,
    ):
        return {
            "status": "buildFailed", "suite": suite, "executed": None,
            "skipped": None, "failures": None, "buildStatus": "failed",
        }
    pattern = re.compile(
        rf"Test Suite '{re.escape(suite)}' (passed|failed).*?\n\s*"
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?"
        r"(\d+) failures",
        re.DOTALL,
    )
    matches = list(pattern.finditer(text))
    if not matches:
        return {
            "status": "notScored", "suite": suite, "executed": None,
            "skipped": None, "failures": None,
            "buildStatus": "passed" if "Build complete!" in text else "notObserved",
        }
    match = matches[-1]
    executed, skipped, failures = (
        int(match.group(2)), int(match.group(3) or 0), int(match.group(4))
    )
    return {
        "status": "passed" if match.group(1) == "passed" and failures == 0
            else "testFailed",
        "suite": suite,
        "executed": executed,
        "skipped": skipped,
        "failures": failures,
        "buildStatus": "passed" if "Build complete!" in text else "notObserved",
    }


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_sha256(value) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def ready_artifacts(root: Path) -> tuple[dict, dict]:
    return (
        read(root / "READY_FOR_HEAVY_BENCHMARK.json"),
        read(root / "READY_FOR_HOLDOUT.json"),
    )


def corpus_and_pcm_provenance(root: Path, corpus: str, raw: dict) -> dict:
    initial_ready, holdout_ready = ready_artifacts(root)
    manifest_path = Path("docs/japanese-live/corpora") / corpus / "manifest.json"
    manifest = read(manifest_path)
    preflight_path = root / "input-preflight.tsv"
    preflight_sha = sha256(preflight_path)
    pinned_preflight_hashes = {
        initial_ready.get("provenanceSHA256", {}).get("inputs"),
        holdout_ready.get("provenanceSHA256", {}).get("inputs"),
    }
    actual_references = []
    for line in preflight_path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t", 3)
        if len(fields) == 4 and fields[0] == corpus:
            actual_references.append((fields[1], fields[2]))
    expected_references = []
    source_sha = None
    for reference in manifest["source"]["references"]:
        label = reference["label"]
        if label == "source-video":
            source_sha = reference["sha256"]
        expected_references.append((
            label if label in {"source-video", "reference-archive"} else "local-reference",
            reference["sha256"],
        ))
    references_match = collections.Counter(actual_references) == collections.Counter(
        expected_references
    )
    expected_samples = manifest["fixture"]["sampleCount"]
    expected_rate = manifest["fixture"]["sampleRate"]
    processed_samples = raw.get("sampleCount")
    processed_rate = raw.get("sampleRate")
    complete_pcm = (
        isinstance(processed_samples, int) and processed_samples == expected_samples
        and processed_rate == expected_rate
    )
    pinned = pinned_preflight_hashes == {preflight_sha}
    verified = bool(source_sha) and references_match and pinned and complete_pcm
    return {
        "status": "verified" if verified else "notScored",
        "corpusSHA256": source_sha,
        "manifestSHA256": sha256(manifest_path),
        "canonicalPCMSHA256": manifest["fixture"]["sha256"],
        "inputPreflightSHA256": preflight_sha,
        "inputPreflightPinnedByBothREADYArtifacts": pinned,
        "referenceHashesMatchPinnedPreflight": references_match,
        "pcmCoverage": {
            "expectedSampleCount": expected_samples,
            "processedSampleCount": processed_samples,
            "sampleRate": processed_rate,
            "expectedSeconds": expected_samples / expected_rate,
            "processedSeconds": (
                processed_samples / processed_rate
                if isinstance(processed_samples, int) and processed_rate else None
            ),
            "ratio": (
                processed_samples / expected_samples
                if isinstance(processed_samples, int) and expected_samples else None
            ),
            "complete": complete_pcm,
        },
    }


def model_provenance_summary(root: Path) -> dict:
    initial_ready, holdout_ready = ready_artifacts(root)
    path = root / "model-provenance.json"
    actual = sha256(path)
    pinned = {
        initial_ready.get("provenanceSHA256", {}).get("models"),
        holdout_ready.get("provenanceSHA256", {}).get("models"),
    }
    payload = read(path)
    weights = payload.get("weights") or []
    required = ("modelID", "revision", "file", "sizeBytes", "sha256")
    weight_rows_valid = bool(weights) and all(
        all(weight.get(key) is not None for key in required)
        and re.fullmatch(r"[0-9a-f]{64}", weight["sha256"]) is not None
        for weight in weights
    )
    verified = pinned == {actual} and weight_rows_valid
    return {
        "status": "verified" if verified else "notScored",
        "modelProvenanceSHA256": actual,
        "pinnedByBothREADYArtifacts": pinned == {actual},
        "weights": [{key: weight[key] for key in required} for weight in weights],
    }


def execution_provenance(root: Path) -> dict:
    initial_ready, holdout_ready = ready_artifacts(root)
    patch_path = root / "worktree.patch"
    actual_patch = sha256(patch_path) if patch_path.exists() else None
    lanes = []
    for lane, ready in (("development", initial_ready), ("holdout", holdout_ready)):
        expected_patch = ready.get("provenanceSHA256", {}).get("uncommittedPatch")
        patch_verified = bool(expected_patch) and expected_patch == actual_patch
        implementation = ready.get("implementationSHA256") or {}
        commit = ready.get("baseCommit")
        commit_available = subprocess.run(
            ["git", "cat-file", "-e", f"{commit}^{{commit}}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        ).returncode == 0
        diff_manifest = []
        if commit_available:
            for path, executed_sha in sorted(implementation.items()):
                base = subprocess.run(
                    ["git", "show", f"{commit}:{path}"], capture_output=True, check=False,
                )
                base_sha = hashlib.sha256(base.stdout).hexdigest() \
                    if base.returncode == 0 else None
                if base_sha != executed_sha:
                    diff_manifest.append({
                        "path": path, "baseSHA256": base_sha,
                        "executedSHA256": executed_sha,
                    })
        diff_manifest_complete = commit_available and bool(implementation) and all(
            re.fullmatch(r"[0-9a-f]{64}", digest or "") is not None
            for digest in implementation.values()
        )
        lanes.append({
            "lane": lane,
            "executedCommit": commit,
            "patchSHA256": expected_patch,
            "patchArtifactSHA256": actual_patch if expected_patch else None,
            "patchVerified": patch_verified,
            "implementationSetSHA256": json_sha256(implementation),
            "diffManifestSHA256": json_sha256(diff_manifest)
                if diff_manifest_complete else None,
            "diffManifest": diff_manifest,
            "diffManifestComplete": diff_manifest_complete,
        })
    return {
        "lanes": lanes,
        "allExecutedCommitsRecorded": all(
            re.fullmatch(r"[0-9a-f]{40}", row["executedCommit"] or "") is not None
            for row in lanes
        ),
        "allExecutionPatchesVerified": all(row["patchVerified"] for row in lanes),
        "allExecutionDiffManifestsComplete": all(
            row["diffManifestComplete"] for row in lanes
        ),
        "historicalInsufficiency": (
            None if all(row["patchVerified"] for row in lanes)
            else "READY_FOR_HOLDOUT did not pin the amended worktree patch; exact implementation hashes remain recorded."
        ),
    }


def normalize_japanese(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return "".join(
        character for character in text
        if not unicodedata.category(character).startswith(("P", "Z", "C"))
    )


def asr_reference_examples(manifest: dict, raw: dict, limit: int = 3) -> list[dict]:
    sample_rate = manifest["fixture"]["sampleRate"]
    candidates = sorted(raw.get("resultTurns") or [], key=lambda row: (
        row.get("start", math.inf), row.get("end", math.inf), row.get("id", "")
    ))
    rows = []
    for turn in manifest["annotations"]["turns"]:
        start = turn["startSample"] / sample_rate
        end = turn["endSample"] / sample_rate
        hypothesis = "".join(
            candidate.get("japanese") or "" for candidate in candidates
            if candidate.get("start") is not None and candidate.get("end") is not None
            and candidate["start"] < end and start < candidate["end"]
        )
        reference = turn["japanese"]
        normalized_reference = normalize_japanese(reference)
        normalized_hypothesis = normalize_japanese(hypothesis)
        distance = edit_distance(normalized_reference, normalized_hypothesis)
        rows.append({
            "turnID": turn["id"],
            "startSeconds": start,
            "endSeconds": end,
            "referenceJapanese": reference,
            "hypothesisJapanese": hypothesis,
            "editDistance": distance,
            "referenceCharacterCount": len(normalized_reference),
            "status": "scored",
        })
    return sorted(rows, key=lambda row: (
        -(row["editDistance"] / max(row["referenceCharacterCount"], 1)),
        row["turnID"],
    ))[:limit]


def asr_diagnostics(manifest: dict, raw: dict) -> dict:
    reference = normalize_japanese("".join(
        turn["japanese"] for turn in manifest["annotations"]["turns"]
    ))
    hypothesis = normalize_japanese(raw["rawASR"])
    matched = lost = extra = 0
    for tag, left, right, candidate_left, candidate_right in difflib.SequenceMatcher(
        None, reference, hypothesis, autojunk=False
    ).get_opcodes():
        if tag == "equal":
            matched += right - left
        elif tag == "delete":
            lost += right - left
        elif tag == "insert":
            extra += candidate_right - candidate_left
        else:
            lost += right - left
            extra += candidate_right - candidate_left
    number_pattern = re.compile(r"[0-9一二三四五六七八九十百千万億兆]+")
    reference_numbers = collections.Counter(number_pattern.findall(reference))
    candidate_numbers = collections.Counter(number_pattern.findall(hypothesis))
    number_matches = sum((reference_numbers & candidate_numbers).values())
    critical_terms = [
        {"turnID": turn["id"], "termID": term}
        for turn in manifest["annotations"]["turns"]
        for term in turn.get("criticalTerms", [])
    ]
    critical_diagnostics = {
        "opportunities": len(critical_terms),
        "status": "notScored",
        "recovered": None,
        "lost": None,
        "reason": "reference contains zero annotated critical-term opportunities"
            if not critical_terms else
            "reference provides term IDs without independent surface-form scoring data",
    }
    return {
        "overallCER": cer(reference, hypothesis),
        "referenceCharactersMatched": matched,
        "lostReferenceCharacters": lost,
        "extraCandidateCharacters": extra,
        "criticalTerms": critical_diagnostics,
        "numbers": {
            "referenceOccurrences": sum(reference_numbers.values()),
            "exactMatchedOccurrences": number_matches,
            "lostOccurrences": sum(reference_numbers.values()) - number_matches,
            "extraOccurrences": sum(candidate_numbers.values()) - number_matches,
        },
        "adaptiveOverrides": 0,
        "adaptiveAbstentions": 0,
        "adaptiveSelected": raw.get("adaptiveASR") is not None,
        "lexicalCorrectionSelected": raw.get("lexicalCorrection") is not None,
        "backend": raw.get("model", {}).get("backend"),
        "examples": asr_reference_examples(manifest, raw),
    }


def direct_subtitle_metrics(rows: list[dict]) -> dict:
    over_84 = over_20 = invalid = under_1 = over_7 = readable = 0
    maximum_cps = 0.0
    for row in rows:
        start, end, text = row.get("start"), row.get("end"), row.get("text", "")
        if start is None or end is None or end <= start:
            invalid += 1
            continue
        duration = end - start
        cps = len(text) / duration
        maximum_cps = max(maximum_cps, cps)
        over_84 += len(text) > 84
        over_20 += cps > 20
        under_1 += duration < 1
        over_7 += duration > 7
        readable += len(text) <= 84 and cps <= 20 and 1 <= duration <= 7
    return {
        "cueCount": len(rows),
        "readableCueCount": readable,
        "over84Characters": over_84,
        "over20CPS": over_20,
        "invalidDuration": invalid,
        "under1Second": under_1,
        "over7Seconds": over_7,
        "maximumCPS": maximum_cps,
    }


def coverage_intervals(rows: list[dict]) -> list[tuple[float, float]]:
    valid = sorted(
        (float(row["start"]), float(row["end"])) for row in rows
        if isinstance(row.get("start"), (int, float))
        and isinstance(row.get("end"), (int, float))
        and math.isfinite(row["start"]) and math.isfinite(row["end"])
        and row["end"] > row["start"]
    )
    merged: list[tuple[float, float]] = []
    for start, end in valid:
        if merged and start <= merged[-1][1] + 1e-6:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def interval_integrity(before: list[dict], after: list[dict]) -> dict:
    invalid = [str(row.get("id", "?")) for row in after
        if not isinstance(row.get("start"), (int, float))
        or not isinstance(row.get("end"), (int, float))
        or not math.isfinite(row["start"]) or not math.isfinite(row["end"])
        or row["end"] <= row["start"]]
    ordered = sorted(after, key=lambda row: (row.get("start", math.inf), row.get("end", math.inf)))
    overlaps = sum(
        ordered[index]["start"] < ordered[index - 1]["end"] - 1e-6
        for index in range(1, len(ordered))
        if all(isinstance(ordered[value].get(key), (int, float))
            for value, key in ((index, "start"), (index - 1, "end")))
    )
    before_coverage, after_coverage = coverage_intervals(before), coverage_intervals(after)
    intersection = overlap_duration(before_coverage, after_coverage)
    before_seconds = sum(end - start for start, end in before_coverage)
    after_seconds = sum(end - start for start, end in after_coverage)
    lost = max(0.0, before_seconds - intersection)
    invented = max(0.0, after_seconds - intersection)
    return {
        "allCueIntervalsValid": not invalid,
        "invalidCueIDs": invalid,
        "accidentalOverlapCount": overlaps,
        "lostCoverageSeconds": round(lost, 9),
        "inventedCoverageSeconds": round(invented, 9),
        "coverageIntervalsMatch": lost <= 1e-6 and invented <= 1e-6,
    }


def subtitle_timestamp(value: str) -> float:
    match = re.fullmatch(r"(\d+):(\d{2}):(\d{2})[,.](\d{3})", value.strip())
    if not match:
        raise ValueError(value)
    hours, minutes, seconds, milliseconds = map(int, match.groups())
    return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000


def parsed_subtitle_export(text: str) -> list[dict]:
    rows = []
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = [line.rstrip() for line in block.splitlines()]
        timing_index = next((index for index, line in enumerate(lines) if " --> " in line), None)
        if timing_index is None:
            continue
        start_text, end_text = lines[timing_index].split(" --> ", 1)
        caption = " ".join(lines[timing_index + 1:]).strip()
        voice = re.match(r"^<v ([^>]+)>", caption)
        bracket = re.match(r"^\[([^]]+)\]\s*", caption)
        speaker = voice.group(1) if voice else bracket.group(1) if bracket else None
        if voice:
            caption = caption[voice.end():]
        elif bracket:
            caption = caption[bracket.end():]
        rows.append({
            "id": lines[timing_index - 1] if timing_index else str(len(rows) + 1),
            "start": subtitle_timestamp(start_text),
            "end": subtitle_timestamp(end_text),
            "text": " ".join(caption.split()),
            "speaker": speaker,
        })
    return rows


def export_consistency(srt: str, vtt: str, cues: list[dict]) -> dict:
    exports = {"SRT": parsed_subtitle_export(srt), "VTT": parsed_subtitle_export(vtt)}
    mismatches = []
    for name, rows in exports.items():
        if len(rows) != len(cues):
            mismatches.append(f"{name}:cue-count")
            continue
        for index, (row, cue) in enumerate(zip(rows, cues)):
            expected_text = " ".join(str(cue["text"]).split())
            if abs(row["start"] - cue["start"]) > 0.001 \
                    or abs(row["end"] - cue["end"]) > 0.001 \
                    or row["text"] != expected_text:
                mismatches.append(f"{name}:{index + 1}")
    if len(exports["SRT"]) == len(exports["VTT"]):
        for index, (srt, vtt) in enumerate(zip(exports["SRT"], exports["VTT"])):
            if srt["speaker"] != vtt["speaker"]:
                mismatches.append(f"speaker:{index + 1}")
    return {
        "consistent": not mismatches,
        "mismatches": mismatches,
        "srtCueCount": len(exports["SRT"]),
        "vttCueCount": len(exports["VTT"]),
    }


def subtitle_diagnostics(job: Path, raw: dict) -> dict:
    outputs = response_map(raw)
    source_turns = raw["translation"]["request"]["turns"]
    before = [{
        "id": turn["id"],
        "text": outputs.get(turn["id"], ""),
        "start": turn.get("sourceStart"),
        "end": turn.get("sourceEnd"),
    } for turn in source_turns]
    after = [{
        "id": cue["id"], "text": cue["text"],
        "start": cue["start"], "end": cue["end"],
    } for cue in raw["subtitleCues"]]
    before_words = " ".join(row["text"] for row in before).split()
    after_words = " ".join(row["text"] for row in after).split()
    intervals = interval_integrity(before, after)
    exports = export_consistency(
        (job / "english-subtitles.srt").read_text(encoding="utf-8"),
        (job / "english-subtitles.vtt").read_text(encoding="utf-8"),
        after,
    )
    srt_metrics = subtitle_quality(
        (job / "english-subtitles.srt").read_text(encoding="utf-8")
    )
    return {
        "beforeReadableReflow": direct_subtitle_metrics(before),
        "afterExport": direct_subtitle_metrics(after),
        "SRT": srt_metrics,
        "intervals": intervals,
        "exportConsistency": exports,
        "integrity": {
            "exactNormalizedWordSequence": before_words == after_words,
            "exactTimingCoverage": intervals["coverageIntervalsMatch"],
            "nonOverlappingMonotonicCues": intervals["allCueIntervalsValid"]
                and intervals["accidentalOverlapCount"] == 0,
            "srtVttMatchPersistedCues": exports["consistent"],
        },
    }


def runtime_seconds(manifest: dict) -> float:
    start = datetime.fromisoformat(manifest["startedAt"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(manifest["finishedAt"].replace("Z", "+00:00"))
    return (end - start).total_seconds()


def examples(rows: list[dict], limit: int = 3) -> list[dict]:
    ranked = sorted(rows, key=lambda row: (
        row["reference"] == row["hypothesis"],
        -abs(len(row["reference"]) - len(row["hypothesis"])),
        row["id"],
    ))
    return [{key: row[key] for key in ("id", "source", "reference", "hypothesis")}
            for row in ranked[:limit]]


def speaker_examples(manifest: dict, raw: dict, limit: int = 3) -> dict:
    """Return concrete time-bound examples without pretending labels are identities."""
    sample_rate = manifest["fixture"]["sampleRate"]
    reference: dict[str, list[tuple[float, float]]] = {}
    for turn in manifest["annotations"]["turns"]:
        reference.setdefault(turn["speaker"], []).append((
            turn["startSample"] / sample_rate,
            turn["endSample"] / sample_rate,
        ))
    candidate: dict[int, list[tuple[float, float]]] = {}
    for span in raw["diarization"]["rawSpans"]:
        candidate.setdefault(span["speakerID"], []).append((span["start"], span["end"]))
    reference = {speaker: merge_spans(spans) for speaker, spans in reference.items()}
    candidate = {speaker: merge_spans(spans) for speaker, spans in candidate.items()}
    mapping = best_speaker_mapping(reference, candidate)
    labels = {
        speaker_id: f"SPEAKER_{index:02d}"
        for index, speaker_id in enumerate(sorted(candidate))
    }
    rows = []
    for turn in manifest["annotations"]["turns"]:
        turn_span = [(
            turn["startSample"] / sample_rate,
            turn["endSample"] / sample_rate,
        )]
        overlaps = sorted((
            (overlap_duration(turn_span, spans), speaker_id)
            for speaker_id, spans in candidate.items()
        ), reverse=True)
        active = [(duration, speaker_id) for duration, speaker_id in overlaps if duration > 0]
        top_speaker = active[0][1] if active else None
        rows.append({
            "turnID": turn["id"],
            "startSeconds": turn_span[0][0],
            "endSeconds": turn_span[0][1],
            "referenceSpeaker": turn["speaker"],
            "candidateLabels": [labels[speaker_id] for _, speaker_id in active],
            "mappedReferenceSpeakers": [mapping.get(speaker_id) for _, speaker_id in active],
            "attributionCorrect": top_speaker is not None
                and mapping.get(top_speaker) == turn["speaker"],
            "japanese": turn["japanese"],
            "englishReference": turn["english"],
        })
    return {
        "correct": [row for row in rows if row["attributionCorrect"]][:limit],
        "incorrect": [row for row in rows if not row["attributionCorrect"]][:limit],
    }


def verification_summary(root: Path) -> dict:
    specifications = {
        "full": ("full-swift-test.log", "All tests"),
        "live": ("live-tests.log", "Selected tests"),
        "safeCombinedOptions": ("safe-options-combined.log", "Selected tests"),
    }
    result = {}
    for key, (name, suite) in specifications.items():
        path = root / name
        if not path.exists():
            result[key] = {
                "status": "notScored", "suite": suite, "executed": None,
                "skipped": None, "failures": None, "buildStatus": "notObserved",
                "logPresent": False,
            }
            continue
        result[key] = {
            **test_log_summary(path.read_text(encoding="utf-8", errors="replace"), suite),
            "logPresent": True,
            "logSHA256": sha256(path),
        }
    return result


def failure_attribution(root: Path, rows: list[dict], verification: dict) -> dict:
    recovery_path = root / "harness-recovery.json"
    incidents = []
    if recovery_path.exists():
        recovery = read(recovery_path)
        safety_path = root / "development" / "safety.json"
        development_safety = read(safety_path) if safety_path.exists() else {}
        incidents.append({
            "classification": recovery["classification"],
            "detail": recovery["reason"],
            "resolution": recovery["fix"],
            "processExitStatus": development_safety.get("exitStatus"),
            "productJobCompleted": True,
            "strictFailClosedDevelopment": False,
            "candidateVerdictAssigned": False,
            "evidenceSHA256": sha256(recovery_path),
        })
    archived = sorted(root.parent.glob("final-validation-121-warning-stop-*"))
    if archived:
        failure_path = archived[-1] / "failure.json"
        safety_path = archived[-1] / "development" / "safety.json"
        failure = read(failure_path)
        incidents.insert(0, {
            "classification": failure["classification"],
            "detail": failure["detail"],
            "resolution": "Warning pressure is telemetry; critical and independent runaway guards remain vetoes.",
            "candidateVerdictAssigned": failure["candidateVerdictAssigned"],
            "evidenceSHA256": {
                "failure": sha256(failure_path),
                "safety": sha256(safety_path),
            },
        })
    current_failure = read(root / "failure.json") if (root / "failure.json").exists() else None
    categories = {key: [] for key in ("build", "test", "input", "reference")}
    if current_failure and current_failure.get("classification") in categories:
        categories[current_failure["classification"]].append(current_failure)
    if verification["full"]["status"] == "buildFailed":
        categories["build"].append({
            "classification": "build", "detail": "full Swift build failed",
            "logSHA256": verification["full"].get("logSHA256"),
        })
    for key in ("full", "live", "safeCombinedOptions"):
        if verification[key]["status"] in ("testFailed", "notScored"):
            categories["test"].append({
                "classification": "test", "suite": key,
                "status": verification[key]["status"],
                "logSHA256": verification[key].get("logSHA256"),
            })
    preflight = root / "input-preflight.tsv"
    return {
        "candidate": {
            "failures": [failure for row in rows for failure in row["failures"]],
            "verdictAssignedToRunnerOrHarnessIncidents": False,
        },
        "build": {"failures": categories["build"]},
        "test": {"failures": categories["test"]},
        "runner": {"incidents": incidents},
        "input": {
            "failures": categories["input"],
            "preflightSHA256": sha256(preflight) if preflight.exists() else None,
        },
        "reference": {
            "failures": categories["reference"],
            "preflightSHA256": sha256(preflight) if preflight.exists() else None,
        },
    }


def development_gate_values(row: dict, manifest: dict, safety: dict) -> dict:
    """Compute every DEV gate from persisted evidence; missing data always fails."""
    cue_integrity = row.get("translation", {}).get("cueIntegrity", {})
    subtitle_integrity = row.get("subtitles", {}).get("integrity", {})
    reanalysis = row.get("speakerOnlyReanalysis", {})
    editor = row.get("speakerEditor", {})
    voice = row.get("voiceMemory", {})
    configuration = row.get("configuration", {})
    asr = row.get("ASR", {})
    lifecycle = row.get("runtime", {}).get("lifecycle", {})
    audit_kinds = set(editor.get("auditKinds") or [])
    required_audits = {"rename", "merge", "reassign", "reset"}
    return {
        "cleanProcessExit": safety.get("stopReason") == "completed"
            and safety.get("exitStatus") == 0
            and safety.get("forcedTermination") is False,
        "savedProjectCompleted": manifest.get("status") == "completed"
            and manifest.get("failures") == [],
        "workersStrictlySequential": row.get("runtime", {}).get(
            "workersStrictlySequential"
        ) is True,
        "workerLifecycleAndUnload": lifecycle.get("allExitedAndUnloadedCleanly") is True
            and bool(lifecycle.get("workers"))
            and set(row.get("runtime", {}).get("workerPIDs") or []) == {
                worker.get("processIdentifier")
                for worker in lifecycle.get("workers", {}).values()
            },
        "structuredTranslationIntegrity": all(
            cue_integrity.get(key) == [] for key in (
                "missingCueIDs", "duplicateCueIDs", "unknownCueIDs",
                "emptyNativeOutputCueIDs",
            )
        ) and cue_integrity.get("reordered") is False,
        "subtitleIntegrity": bool(subtitle_integrity)
            and all(value is True for value in subtitle_integrity.values()),
        "speakerOnlyReanalysis": all(
            reanalysis.get(key) is True for key in (
                "asrUnchanged", "alignmentUnchanged", "translationUnchanged"
            )
        ) and reanalysis.get("count") == 1
            and manifest.get("speakerReanalysisCount") == 1,
        "speakerEditor": required_audits <= audit_kinds
            and editor.get("turnCount") == editor.get("cueCount")
            and editor.get("exportHashesMatch") is True,
        "voiceMemoryProjectIsolation": voice.get("beta") is True
            and voice.get("offByDefault") is True
            and (voice.get("localProjectProfileCount") or 0) >= 1
            and voice.get("crossProjectSuggestionCount") == 0,
        "safeBaselineConfiguration": configuration == {
            "translator": "translategemma-12b-it-4bit",
            "speakerLabels": True,
            "readableSubtitles": False,
        } and asr.get("backend") == "qwen-ja"
            and asr.get("adaptiveSelected") is False
            and asr.get("lexicalCorrectionSelected") is False,
    }


def worker_lifecycle_summary(raw: dict) -> dict:
    workers = {
        "ASR": raw.get("asrWorker", {}).get("lifecycle"),
        "alignment": raw.get("alignment", {}).get("worker"),
        "diarizationCurrent": raw.get("diarization", {}).get("worker"),
        "translation": raw.get("translation", {}).get("worker"),
    }
    for index, reanalysis in enumerate(raw.get("speakerReanalyses") or []):
        workers[f"diarizationBeforeReanalysis{index + 1}"] = reanalysis.get(
            "replacedDiarization", {}
        ).get("worker")
    summaries = {}
    for name, lifecycle in workers.items():
        if not isinstance(lifecycle, dict):
            continue
        samples = lifecycle.get("availableMemorySamples") or []
        summaries[name] = {
            key: lifecycle.get(key) for key in (
                "processIdentifier", "startedAt", "exitedAt", "elapsedSeconds",
                "exitStatus", "terminationReason", "forcedTermination",
                "peakPhysicalFootprintBytes", "swapUsedBeforeBytes", "swapUsedAfterBytes",
            )
        }
        summaries[name]["memorySampleCount"] = len(samples)
        summaries[name]["minimumAvailableMemoryBytes"] = min(
            (sample.get("availableMemoryBytes") for sample in samples
             if isinstance(sample.get("availableMemoryBytes"), (int, float))),
            default=None,
        )
    return {
        "workers": summaries,
        "allExitedAndUnloadedCleanly": bool(summaries) and all(
            worker["exitStatus"] == 0 and worker["terminationReason"] == "exit"
            and worker["forcedTermination"] is False and worker["exitedAt"] is not None
            for worker in summaries.values()
        ),
    }


def score_row(root: Path, lane: str, corpus: str) -> dict:
    row_report = read(root / lane / "row-report.json")
    job = Path(row_report["jobDirectory"])
    product_manifest = read(job / "manifest.json")
    raw = read(job / "raw-asr.json")
    reference_manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
    translations = translation_rows(reference_manifest, raw)
    hypothesis = " ".join(row["hypothesis"] for row in translations)
    reference = " ".join(row["reference"] for row in translations)
    integrity = cue_integrity(raw)
    result = {
        "lane": lane,
        "corpusID": corpus,
        "configuration": {
            key: row_report[key] for key in (
                "translator", "speakerLabels", "readableSubtitles"
            )
        },
        "jobDirectory": str(job),
        "corpusProvenance": corpus_and_pcm_provenance(root, corpus, raw),
        "rawArtifactSHA256": {
            name: sha256(job / name) for name in (
                "manifest.json", "raw-asr.json", "japanese-transcript.txt",
                "english-translation-transcript.txt", "english-subtitles.vtt",
                "english-subtitles.srt",
            )
        },
        "ASR": asr_diagnostics(reference_manifest, raw),
        "translation": {
            "chrFPlusPlus": chrf_pp(hypothesis, reference),
            "cueIntegrity": integrity,
            "glossary": glossary_accuracy(raw),
            "untranslatedCueIDs": [row["id"] for row in translations
                if re.search(r"[\u3040-\u30ff\u3400-\u9fff]", row["hypothesis"])],
            "suspectedHallucinatedCueIDs": [row["id"] for row in translations
                if suspected_hallucination(row)],
            "examples": examples(translations),
        },
        "speakers": ({
                **diarization_metrics(reference_manifest, raw),
                "examples": speaker_examples(reference_manifest, raw),
            } if raw.get("diarization") else {
                "status": "disabled by pairwise row",
                "referenceSpeakerCount": len({
                    row["speaker"] for row in reference_manifest["annotations"]["turns"]
                }),
                "candidateSpeakerCount": None,
            }),
        "subtitles": subtitle_diagnostics(job, raw),
        "runtime": {
            "wallSeconds": runtime_seconds(product_manifest),
            "stageDurations": product_manifest["stageDurations"],
            "peakMemoryBytes": product_manifest["peakMemoryBytes"],
            "workersStrictlySequential": row_report["strictlySequential"],
            "workerPIDs": row_report["workerPIDs"],
            "lifecycle": worker_lifecycle_summary(raw),
        },
        "failures": product_manifest["failures"],
    }
    for key in ("speakerOnlyReanalysis", "speakerEditor", "voiceMemory"):
        if key in row_report:
            result[key] = row_report[key]
    if "speakerEditor" in result:
        expected = result["speakerEditor"].get("exportSHA256", {})
        result["speakerEditor"]["exportHashesMatch"] = all(
            result["rawArtifactSHA256"].get(name) == digest
            for name, digest in expected.items()
        ) and set(expected) == {
            "japanese-transcript.txt", "english-translation-transcript.txt",
            "english-subtitles.vtt", "english-subtitles.srt",
        }
    return result


def development_freeze_snapshot(root: Path) -> dict:
    row = score_row(root, "development", CORPORA[0])
    job = Path(row["jobDirectory"])
    manifest = read(job / "manifest.json")
    safety = read(root / "development" / "safety.json")
    gates = development_gate_values(row, manifest, safety)
    return {
        "schemaVersion": 2,
        "ticket": 121,
        "derivation": {
            "status": "computed-before-holdout",
            "reporterSHA256": sha256(Path(__file__)),
            "allFunctionalGatesPassed": all(gates.values()),
        },
        "matrixSHA256": sha256(root / "matrix.json"),
        "readySHA256": sha256(root / "READY_FOR_HEAVY_BENCHMARK.json"),
        "developmentArtifactsSHA256": {
            "manifest": sha256(job / "manifest.json"),
            "rawEvidence": sha256(job / "raw-asr.json"),
            "rowReport": sha256(root / "development" / "row-report.json"),
            "safety": sha256(root / "development" / "safety.json"),
        },
        "computedGates": gates,
        "qualitySnapshot": {
            "ASR": row["ASR"],
            "translation": {
                "chrFPlusPlus": row["translation"]["chrFPlusPlus"],
                "cueIntegrity": row["translation"]["cueIntegrity"],
            },
            "speakers": row["speakers"],
            "subtitles": row["subtitles"],
        },
        "qualityMetricsAreReportingOnly": True,
        "productDefaultPromotionAuthorized": False,
    }


def validate_development_freeze(current: dict, recomputed: dict) -> dict:
    errors = []
    if current.get("schemaVersion") != 2:
        errors.append("schemaVersion must be 2")
    derivation = current.get("derivation", {})
    if derivation.get("status") != "computed-before-holdout":
        errors.append("freeze derivation status is invalid")
    if derivation.get("allFunctionalGatesPassed") is not True:
        errors.append("freeze functional gates were not all passed")
    if current != recomputed:
        errors.append("freeze does not exactly match recomputed gates and artifact hashes")
    return {"valid": not errors, "errors": errors}


def write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent,
            prefix=f".{path.name}.", delete=False
        ) as output:
            temporary_name = output.name
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
    finally:
        if temporary_name and Path(temporary_name).exists():
            Path(temporary_name).unlink()


def freeze_diagnostics(root: Path) -> dict:
    path = root / "development-freeze.json"
    if not path.exists():
        return {"strictFailClosed": False, "insufficiencies": ["freeze missing"]}
    freeze = read(path)
    safety_path = root / "development" / "safety.json"
    safety = read(safety_path) if safety_path.exists() else {}
    insufficiencies = []
    if freeze.get("derivation", {}).get("status") != "computed-before-holdout":
        insufficiencies.append("historical freeze does not prove computed gates before holdout")
    if safety.get("exitStatus") != 0:
        insufficiencies.append(
            f'historical DEV XCTest exit was {safety.get("exitStatus")}, not zero'
        )
    if safety.get("stopReason") != "completed" or safety.get("forcedTermination") is not False:
        insufficiencies.append("historical DEV process lifecycle was not a clean completion")
    computed = freeze.get("computedGates")
    if not isinstance(computed, dict) or not computed or not all(computed.values()):
        insufficiencies.append("historical freeze lacks a complete passing computed gate set")
    return {
        "strictFailClosed": not insufficiencies,
        "freezeSHA256": sha256(path),
        "insufficiencies": insufficiencies,
        "historicalRecoveryOnly": bool(insufficiencies),
    }


def retained_decision_diagnostics() -> dict:
    ledger_path = Path(
        "docs/japanese-live/experiments/evidence/issue-121/retained-decisions.json"
    )
    ledger = read(ledger_path)
    hashes_match = True
    for decision in ledger["decisions"].values():
        for evidence in decision.values():
            if isinstance(evidence, dict) and "path" in evidence and "sha256" in evidence:
                hashes_match = hashes_match and sha256(Path(evidence["path"])) == evidence["sha256"]
    adaptive = read(Path(ledger["decisions"]["adaptiveASR117"]["evidence"]["path"]))
    whisper = read(Path(ledger["decisions"]["targetedWhisperKit118"]["evidence"]["path"]))
    lexical = read(Path(ledger["decisions"]["closedLexicalCorrection119"]["evidence"]["path"]))
    voice = read(Path(ledger["decisions"]["voiceMemory115"]["evidence"]["path"]))
    readable = read(Path(ledger["decisions"]["readableSubtitles"]["evidence"]["path"]))
    high_quality_ui = Path("Sources/HighQualityJobView.swift").read_text(encoding="utf-8")
    gates = {
        "decisionEvidenceHashesMatch": hashes_match,
        "adaptiveASRRetainedHidden": adaptive.get("result") == "RETAIN_HIDDEN_DEV_NO_GO"
            and adaptive.get("execution", {}).get("holdoutOpened") is False
            and adaptive.get("scope", {}).get("adaptiveExposed") is False
            and adaptive.get("scope", {}).get("standardDefaultPreserved") is True,
        "targetedWhisperKitRetainedHidden": whisper.get("result")
            == "RETAIN_HIDDEN_DEV_NO_GO"
            and whisper.get("execution", {}).get("holdoutOpened") is False
            and whisper.get("scope", {}).get("adaptiveExposed") is False
            and whisper.get("scope", {}).get("standardDefaultPreserved") is True,
        "lexicalCorrectionRemainsNoGo": lexical.get("gates", {}).get(
            "developmentPassed"
        ) is False and lexical.get("gates", {}).get("downstreamEnglishRun") is False
            and lexical.get("gates", {}).get("holdoutOpened") is False,
        "voiceMemoryRemainsBetaOffByDefault": voice.get("decision") == "GO_BETA_OPT_IN"
            and voice.get("defaultEnabled") is False,
        "readableSubtitlesRemainBetaOffByDefault": readable.get("decision") == "GO-beta"
            and readable.get("gates", {}).get("defaultOff") is True,
        "rejectedCandidatesRemainAbsentFromHighQualityUI": not re.search(
            r"adaptive|lexical", high_quality_ui, re.IGNORECASE
        ),
    }
    return {"ledgerSHA256": sha256(ledger_path), "gates": gates}


def report_markdown(report: dict) -> str:
    rows = report["rows"]
    lines = [
        "# Final offline validation — #121", "",
        "| Lane | Translator | Speaker | Readable | CER | chrF++ | Runtime | Peak |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f'| {row["lane"]} | {row["configuration"]["translator"]} | '
            f'{row["configuration"]["speakerLabels"]} | '
            f'{row["configuration"]["readableSubtitles"]} | '
            f'{row["ASR"]["overallCER"]["ratePercent"]:.2f}% | '
            f'{row["translation"]["chrFPlusPlus"]:.2f} | '
            f'{row["runtime"]["wallSeconds"]:.0f}s | '
            f'{row["runtime"]["peakMemoryBytes"] / 2**30:.2f} GiB |'
        )
    lines += ["", "## Provenance d’exécution", ""]
    for row in rows:
        corpus = row["corpusProvenance"]
        pcm = corpus["pcmCoverage"]
        coverage = (
            f'{pcm["ratio"] * 100:.3f} %'
            if isinstance(pcm["ratio"], (int, float)) else "notScored"
        )
        lines.append(
            f'- {row["lane"]}: corpus `{corpus["corpusSHA256"]}`; manifest '
            f'`{corpus["manifestSHA256"]}`; PCM {pcm["processedSampleCount"]}/'
            f'{pcm["expectedSampleCount"]} échantillons '
            f'({coverage}, {"PASS" if pcm["complete"] else "FAIL"}).'
        )
    for lane in report["provenance"]["execution"]["lanes"]:
        patch_or_diff = lane["patchSHA256"] or lane["diffManifestSHA256"]
        provenance_kind = "patch" if lane["patchSHA256"] else "manifeste de diff"
        lines.append(
            f'- {lane["lane"]}: commit exécuté `{lane["executedCommit"]}`; '
            f'{provenance_kind} `{patch_or_diff}`; '
            f'{"patch exact vérifié" if lane["patchVerified"] else "patch brut absent, manifeste dérivé fail-closed"}.'
        )
    models = report["provenance"]["models"]
    lines.append(
        f'- `model-provenance.json`: `{models["modelProvenanceSHA256"]}` '
        f'({models["status"]}).'
    )
    for weight in models["weights"]:
        lines.append(
            f'- Poids `{weight["modelID"]}` / `{weight["file"]}`: '
            f'`{weight["sha256"]}`.'
        )
    lines += ["", "## ASR — exemples japonais réels référence ↔ hypothèse", ""]
    for row in rows:
        lines.append(f'- {row["lane"]}:')
        for example in row["ASR"]["examples"]:
            lines.append(
                f'  - {example["turnID"]} ({example["startSeconds"]:.1f}–'
                f'{example["endSeconds"]:.1f}s): ref « {example["referenceJapanese"]} »; '
                f'hyp « {example["hypothesisJapanese"]} ».')
        critical = row["ASR"]["criticalTerms"]
        lines.append(f'  - Termes critiques: {critical["status"]} — {critical["reason"]}.')
        lines.append("  - Traductions de référence ↔ sortie:")
        for example in row["translation"]["examples"][:2]:
            lines.append(
                f'    - JA « {example["source"]} »; EN ref « {example["reference"]} »; '
                f'EN hyp « {example["hypothesis"]} ».')
    speaker = rows[0]["speakers"]
    lines += [
        "", "## Speaker (development)", "",
        f'- Locuteurs référence/candidat/écart: {speaker["referenceSpeakerCount"]}/'
        f'{speaker["candidateSpeakerCount"]}/{speaker["speakerCountAbsoluteError"]}.',
        f'- DER/JER: {speaker["DERPercent"]:.2f}% / {speaker["JERPercent"]:.2f}%.',
        f'- Japonais non attribué: '
        f'{speaker["speakerAttributedJapaneseError"]["unattributedCharacterCount"]} caractères; '
        f'duplications: {speaker["duplicationCount"]}.',
        f'- Overlap précision/rappel/F1: {speaker["overlap"]["precisionPercent"]:.1f}% / '
        f'{speaker["overlap"]["recallPercent"]:.1f}% / '
        f'{speaker["overlap"]["f1Percent"]:.1f}%.',
        "- Exemples d’attribution incorrecte:",
    ]
    for example in speaker["examples"]["incorrect"][:2]:
        lines.append(
            f'  - {example["turnID"]} ({example["startSeconds"]:.1f}–'
            f'{example["endSeconds"]:.1f}s): référence {example["referenceSpeaker"]}; '
            f'candidats {", ".join(example["candidateLabels"]) or "aucun"}; '
            f'JA « {example["japanese"]} ».')
    lines += [
        "", "## Lisibilité des sous-titres", "",
        "| Lane | Cues avant/après | Lisibles avant/après | >20 CPS | >84 caractères | <1s | >7s | Intégrité |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        before = row["subtitles"]["beforeReadableReflow"]
        after = row["subtitles"]["afterExport"]
        lines.append(
            f'| {row["lane"]} | {before["cueCount"]}/{after["cueCount"]} | '
            f'{before["readableCueCount"]}/{after["readableCueCount"]} | '
            f'{before["over20CPS"]}/{after["over20CPS"]} | '
            f'{before["over84Characters"]}/{after["over84Characters"]} | '
            f'{before["under1Second"]}/{after["under1Second"]} | '
            f'{before["over7Seconds"]}/{after["over7Seconds"]} | '
            f'{"PASS" if all(row["subtitles"]["integrity"].values()) else "FAIL"} |'
        )
    lines += ["", "## Vérifications légères et décisions", ""]
    for name, value in report["verification"].items():
        lines.append(
            f'- {name}: {value["status"]}, {value.get("executed")} tests, '
            f'{value.get("failures")} échec(s).')
    lines += ["", "### Attribution des échecs", ""]
    for category in ("candidate", "build", "test", "runner", "input", "reference"):
        evidence = report["failureAttribution"][category]
        count = len(evidence.get("failures", evidence.get("incidents", [])))
        lines.append(f'- {category}: {count}.')
    lines += [
        f'- Freeze DEV strictement fail-closed: {report["freeze"]["strictFailClosed"]}.',
        f'- Limites historiques: {"; ".join(report["freeze"]["insufficiencies"]) or "aucune"}.',
        f'- TranslateGemma 4B: {report["finalDecisions"]["translateGemma4B"]}.',
        f'- Réanalyse Speaker-only: {report["finalDecisions"]["speakerOnlyReanalysis"]}.',
        f'- Éditeur de locuteurs: {report["finalDecisions"]["speakerEditor"]}.',
        f'- Décision produit globale: {report["finalDecisions"]["overall"]}.',
        "", "## Portes", "",
    ]
    lines += [f'- {key}: {"PASS" if value else "FAIL"}' for key, value in report["gates"].items()]
    lines += ["", report["scopeLimit"]]
    return "\n".join(lines) + "\n"


def sanitized(value, replacements: list[tuple[str, str]]):
    if isinstance(value, dict):
        return {key: sanitized(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [sanitized(item, replacements) for item in value]
    if isinstance(value, str):
        for source, replacement in replacements:
            value = value.replace(source, replacement)
    return value


def write_bundle(bundle: Path, root: Path, verification_root: Path, report: dict, markdown: str) -> None:
    bundle.mkdir(parents=True, exist_ok=True)
    replacements = [
        (str(root.resolve()), "<LOCAL_ARTIFACT_ROOT>"),
        (str(Path.cwd().resolve()), "<WORKTREE>"),
        (str(Path.home()), "<HOME>"),
    ]
    (bundle / "report.json").write_text(
        json.dumps(sanitized(report, replacements), ensure_ascii=False, indent=2, sort_keys=True)
        + "\n", encoding="utf-8"
    )
    (bundle / "report.md").write_text(
        sanitized(markdown, replacements), encoding="utf-8"
    )
    (bundle / "current-validation-matrix.json").write_text(
        json.dumps(report["matrix"], ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    historical_root = bundle / "historical"
    snapshot_source_root = Path(
        "docs/japanese-live/experiments/evidence/issue-121/historical"
    )
    for name in ("holdout-runner.sh", "post-run-reporter-amendment.py"):
        source = snapshot_source_root / name
        destination = historical_root / name
        if not source.exists():
            raise FileNotFoundError(f"missing historical source snapshot: {source}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.resolve() != destination.resolve():
            shutil.copyfile(source, destination)
    historical = historical_root / "artifacts"
    historical.mkdir(parents=True, exist_ok=True)
    selected = [
        "READY_FOR_HEAVY_BENCHMARK.json", "READY_FOR_HOLDOUT.json",
        "development-freeze.json", "harness-recovery.json", "matrix.json",
        "model-provenance.json", "development/row-report.json",
        "development/run-meta.json", "development/safety.json",
        "holdout/row-report.json", "holdout/run-meta.json", "holdout/safety.json",
    ]
    for relative in selected:
        source = root / relative
        if not source.exists():
            continue
        destination = historical / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            json.dumps(sanitized(read(source), replacements), ensure_ascii=False,
                       indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    preflight = root / "input-preflight.tsv"
    if preflight.exists():
        (historical / "input-preflight.tsv").write_text(
            sanitized(preflight.read_text(encoding="utf-8"), replacements),
            encoding="utf-8",
        )
    artifact_ledger = []
    for path in sorted(file for file in root.rglob("*") if file.is_file()):
        artifact_ledger.append({
            "path": str(path.relative_to(root)), "sha256": sha256(path),
            "sizeBytes": path.stat().st_size,
            "availability": "historical local artifact; content not duplicated in Git unless snapshotted",
        })
    (bundle / "historical" / "raw-artifact-ledger.json").write_text(
        json.dumps(artifact_ledger, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    initial_ready = read(root / "READY_FOR_HEAVY_BENCHMARK.json")
    holdout_ready = read(root / "READY_FOR_HOLDOUT.json")
    initial_runner_hash = initial_ready["implementationSHA256"][
        "Scripts/run_final_offline_validation.sh"
    ]
    execution_reporter_hash = initial_ready["implementationSHA256"][
        "Scripts/report_final_offline_validation.py"
    ]
    holdout_runner_hash = holdout_ready["implementationSHA256"][
        "Scripts/run_final_offline_validation.sh"
    ]
    if sha256(historical_root / "holdout-runner.sh") != holdout_runner_hash:
        raise ValueError("historical holdout runner does not match READY_FOR_HOLDOUT")
    status = {
        "initialDevelopmentRunner": {
            "contentSHA256": initial_runner_hash,
            "derivedFrom": "READY_FOR_HEAVY_BENCHMARK.json implementationSHA256",
            "exactContentAvailable": False,
        },
        "executionReporter": {
            "contentSHA256": execution_reporter_hash,
            "derivedFrom": "READY_FOR_HEAVY_BENCHMARK.json implementationSHA256",
            "exactContentAvailable": False,
        },
        "holdoutRunner": {
            "path": "historical/holdout-runner.sh", "exactContentAvailable": True,
            "sha256": holdout_runner_hash,
            "derivedFrom": "READY_FOR_HOLDOUT.json implementationSHA256",
        },
        "postRunReporterAmendment": {
            "path": "historical/post-run-reporter-amendment.py",
            "exactContentAvailable": True,
            "sha256": sha256(historical_root / "post-run-reporter-amendment.py"),
            "derivedFrom": "exact retained post-run source snapshot",
        },
        "interpretation": "Historical DEV recovery is preserved but is not claimed as strictly fail-closed.",
    }
    (bundle / "historical" / "execution-source-status.json").write_text(
        json.dumps(status, indent=2, sort_keys=True) + "\n"
    )
    current_sources = bundle / "current-sources"
    current_sources.mkdir(exist_ok=True)
    for source in (Path("Scripts/report_final_offline_validation.py"),
                   Path("Scripts/run_final_offline_validation.sh")):
        shutil.copyfile(source, current_sources / source.name)
    verification = bundle / "verification"
    verification.mkdir(exist_ok=True)
    for name in ("full-swift-test.log", "live-tests.log", "safe-options-combined.log",
                 "app-launch.log", "app-launch.json"):
        source = verification_root / name
        if not source.exists():
            continue
        content = source.read_text(encoding="utf-8", errors="replace")
        with (verification / f"{name}.gz").open("wb") as compressed:
            with gzip.GzipFile(fileobj=compressed, mode="wb", mtime=0) as archive:
                archive.write(sanitized(content, replacements).encode("utf-8"))
    source_paths = sorted(
        list(Path("Sources").rglob("*.swift")) + list(Path("Tests").rglob("*.swift"))
        + [Path("Package.swift"), Path("Package.resolved"),
           Path("Scripts/report_final_offline_validation.py"),
           Path("Scripts/run_final_offline_validation.sh"),
           Path("Scripts/run_mossformer2_oracle_experiment.sh"),
           Path("Scripts/report_high_quality_acceptance.py"),
           Path("Scripts/report_japanese_l7d.py"),
           Path("Scripts/report_local_translator_bakeoff.py")]
    )
    source_ledger = [{"path": str(path), "sha256": sha256(path)}
                     for path in source_paths if path.exists()]
    (bundle / "source-ledger.json").write_text(
        json.dumps(source_ledger, indent=2, sort_keys=True) + "\n"
    )
    (bundle / "README.md").write_text(
        "# Issue #121 evidence\n\n"
        "Sanitized audit bundle. Raw local execution artifacts are identified by the "
        "historical ledger; they are not duplicated because they contain large user-derived "
        "transcripts. Historical execution sources and current fail-closed amendments are "
        "kept separate. Derived artifacts are path-sanitized; the exact historical runner "
        "snapshot necessarily retains its original local path literals. It contains no "
        "credential. The historical DEV freeze is explicitly non-promotional.\n",
        encoding="utf-8",
    )
    ledger_lines = []
    for path in sorted(file for file in bundle.rglob("*") if file.is_file()
                       and file.name != "sha256.tsv"):
        ledger_lines.append(f"{sha256(path)}  {path.relative_to(bundle)}")
    (bundle / "sha256.tsv").write_text("\n".join(ledger_lines) + "\n")


def build_report(root: Path, verification_root: Path) -> dict:
    rows = [
        score_row(root, "development", CORPORA[0]),
        score_row(root, "holdout", CORPORA[1]),
    ]
    verification = verification_summary(verification_root)
    freeze = freeze_diagnostics(root)
    decisions = retained_decision_diagnostics()
    models = model_provenance_summary(root)
    execution = execution_provenance(root)
    functional_gates = {
        "bothRealSavedProjectJobsCompleted": all(not row["failures"] for row in rows),
        "12BThen4BProcessIsolated": all(
            row["runtime"]["workersStrictlySequential"] for row in rows
        ) and not set(rows[0]["runtime"]["workerPIDs"]) & set(rows[1]["runtime"]["workerPIDs"]),
        "allWorkerLifecyclesExitedAndUnloaded": all(
            row["runtime"]["lifecycle"]["allExitedAndUnloadedCleanly"]
            and set(row["runtime"]["workerPIDs"]) == {
                worker["processIdentifier"]
                for worker in row["runtime"]["lifecycle"]["workers"].values()
            }
            for row in rows
        ),
        "noAdaptiveSelection": all(not row["ASR"]["adaptiveSelected"] for row in rows),
        "noLexicalCorrectionSelection": all(
            not row["ASR"]["lexicalCorrectionSelected"] for row in rows
        ),
        "qwenFallbackPreserved": all(row["ASR"]["backend"] == "qwen-ja" for row in rows),
        "structuredTranslationIntegrity": all(
            not row["translation"]["cueIntegrity"][key]
            for row in rows for key in (
                "missingCueIDs", "duplicateCueIDs", "unknownCueIDs",
                "emptyNativeOutputCueIDs",
            )
        ) and all(not row["translation"]["cueIntegrity"]["reordered"] for row in rows),
        "subtitleTextTimingAndExportsIntegrity": all(
            all(row["subtitles"]["integrity"].values()) for row in rows
        ),
        "speakerReanalysisDoesNotRerunUpstream": all(
            rows[0]["speakerOnlyReanalysis"].get(key) is True
            for key in ("asrUnchanged", "alignmentUnchanged", "translationUnchanged")
        ),
        "speakerEditorExportsMatchPersistedFiles": rows[0]["speakerEditor"].get(
            "exportHashesMatch"
        ) is True,
        "voiceMemoryProjectIsolated": rows[0]["voiceMemory"][
            "crossProjectSuggestionCount"
        ] == 0,
        "retainedNoGoAndBetaDecisionsVerified": all(decisions["gates"].values()),
        "safeOptionsCombinedTestPassed": verification["safeCombinedOptions"]["status"]
            == "passed",
        "fullSwiftTestsPassed": verification["full"]["status"] == "passed",
        "liveTestsPassed": verification["live"]["status"] == "passed",
        "corpusAndPCMProvenanceVerified": all(
            row["corpusProvenance"]["status"] == "verified" for row in rows
        ),
        "modelWeightHashesVerified": models["status"] == "verified",
        "executionCommitAndDiffProvenanceRecorded": (
            execution["allExecutedCommitsRecorded"]
            and execution["allExecutionDiffManifestsComplete"]
        ),
    }
    promotion_gates = {
        "developmentFreezeStrictlyFailClosed": freeze["strictFailClosed"],
        "executionPatchProvenanceComplete": execution["allExecutionPatchesVerified"],
        "criticalASRTermsScored": all(
            row["ASR"]["criticalTerms"]["status"] == "scored" for row in rows
        ),
    }
    holdout_ready = read(root / "READY_FOR_HOLDOUT.json") \
        if (root / "READY_FOR_HOLDOUT.json").exists() else {}
    historical_matrix = read(root / "matrix.json")
    matrix = json.loads(json.dumps(historical_matrix))
    if not any(row.get("lane") == "model-free-safe-options-combined"
               for row in matrix.get("rows", [])):
        matrix.setdefault("rows", []).append({
            "order": "post-run-lightweight-amendment",
            "lane": "model-free-safe-options-combined",
            "fixtureOnly": True,
            "speakerLabels": True,
            "readableSubtitles": True,
            "test": "HighQualityJobTests/testSpeakerLabelsAndReadableSubtitlesRemainIndependentWhenCombined",
            "historicalHeavyExecution": False,
        })
    matrix["amendment"] = {
        "historicalExecutionMatrixSHA256": sha256(root / "matrix.json"),
        "reason": "Adds only the current model-free combination of already-supported safe options; no historical heavy-run claim.",
    }
    report = {
        "schemaVersion": 2,
        "ticket": 121,
        "matrix": matrix,
        "rows": rows,
        "verification": verification,
        "failureAttribution": failure_attribution(root, rows, verification),
        "freeze": freeze,
        "retainedDecisionDiagnostics": decisions,
        "provenance": {
            "initialCommand": read(root / "READY_FOR_HEAVY_BENCHMARK.json").get("command"),
            "holdoutCommand": holdout_ready.get("command"),
            "modelRevisionsSHA256": sha256(root / "model-provenance.json"),
            "models": models,
            "execution": execution,
            "reporterSHA256": sha256(Path(__file__)),
        },
        "gates": {**functional_gates, **promotion_gates},
        "supportedFeatureEvidencePassed": all(functional_gates.values()),
        "functionalAcceptancePassed": all(functional_gates.values())
            and freeze["strictFailClosed"],
        "productDefaultPromotionAuthorized": all(functional_gates.values())
            and all(promotion_gates.values()),
        "finalDecisions": {
            "translateGemma4B": "KEEP_BETA_SELECTABLE; off by default; no superiority claim across different holdout videos",
            "speakerOnlyReanalysis": "GO_SUPPORTED_RESULT_ACTION; reuses ASR/alignment/translation and completed in "
                f'{rows[0]["speakerOnlyReanalysis"]["wallTimeSeconds"]:.3f} seconds on DEV',
            "speakerEditor": "GO_SUPPORTED_RESULT_ACTION; rename/reassign/merge/reset audit and regenerated export hashes verified",
            "overall": "NO_DEFAULT_CHANGE; historical DEV freeze and critical-term reference coverage are insufficient for promotion",
        },
        "scopeLimit": "Two supplied videos validate integration behavior, not broad model superiority.",
    }
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--verification-root", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--development-freeze", type=Path)
    parser.add_argument("--verify-development-freeze", type=Path)
    parser.add_argument("--classify-test-log", type=Path)
    parser.add_argument("--suite")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        passing_log = """Build complete! (1.0s)
Test Suite 'All tests' passed at 2026-08-20 00:00:00.000.
    Executed 12 tests, with 2 tests skipped and 0 failures (0 unexpected) in 1.0 seconds
"""
        assert test_log_summary(passing_log, "All tests")["status"] == "passed"
        one_test_log = passing_log.replace(
            "All tests", "Selected tests"
        ).replace("12 tests", "1 test").replace("2 tests skipped and ", "")
        assert test_log_summary(one_test_log, "Selected tests")["status"] == "passed"
        assert test_log_summary("error: no such module 'XCTest'", "All tests")[
            "status"
        ] == "buildFailed"
        with tempfile.TemporaryDirectory() as directory:
            verification_root = Path(directory)
            (verification_root / "full-swift-test.log").write_text(passing_log)
            (verification_root / "live-tests.log").write_text(
                passing_log.replace("All tests", "Selected tests")
            )
            verification = verification_summary(verification_root)
            assert verification["full"]["status"] == "passed"
            assert failure_attribution(
                verification_root, [{"failures": []}], verification
            )["runner"]["incidents"] == []
        development_gates = development_gate_values(
            {
                "runtime": {
                    "workersStrictlySequential": True,
                    "workerPIDs": [1],
                    "lifecycle": {
                        "allExitedAndUnloadedCleanly": True,
                        "workers": {"ASR": {"processIdentifier": 1, "exitStatus": 0}},
                    },
                },
                "translation": {"cueIntegrity": {
                    "missingCueIDs": [], "duplicateCueIDs": [], "unknownCueIDs": [],
                    "emptyNativeOutputCueIDs": [], "reordered": False,
                }},
                "subtitles": {"integrity": {"all": True}},
                "speakerOnlyReanalysis": {
                    "asrUnchanged": True, "alignmentUnchanged": True,
                    "translationUnchanged": True, "count": 1,
                },
                "speakerEditor": {
                    "auditKinds": ["rename", "merge", "reassign", "reset"],
                    "turnCount": 2, "cueCount": 2, "exportHashesMatch": True,
                },
                "voiceMemory": {
                    "beta": True, "offByDefault": True,
                    "localProjectProfileCount": 1, "crossProjectSuggestionCount": 0,
                },
                "configuration": {
                    "translator": "translategemma-12b-it-4bit",
                    "speakerLabels": True, "readableSubtitles": False,
                },
                "ASR": {
                    "adaptiveSelected": False, "lexicalCorrectionSelected": False,
                    "backend": "qwen-ja",
                },
            },
            {"status": "completed", "failures": [], "speakerReanalysisCount": 1},
            {"stopReason": "completed", "exitStatus": 0, "forcedTermination": False},
        )
        assert all(development_gates.values())
        missing_reanalysis_worker = {
            "workersStrictlySequential": True,
            "workerPIDs": [1],
            "lifecycle": {
                "allExitedAndUnloadedCleanly": True,
                "workers": {
                    "ASR": {"processIdentifier": 1},
                    "speakerReanalysis": {"processIdentifier": 2},
                },
            },
        }
        mismatched_row = {
            "runtime": missing_reanalysis_worker,
            "translation": {"cueIntegrity": {
                "missingCueIDs": [], "duplicateCueIDs": [], "unknownCueIDs": [],
                "emptyNativeOutputCueIDs": [], "reordered": False,
            }},
            "subtitles": {"integrity": {"all": True}},
            "speakerOnlyReanalysis": {
                "asrUnchanged": True, "alignmentUnchanged": True,
                "translationUnchanged": True, "count": 1,
            },
            "speakerEditor": {
                "auditKinds": ["rename", "merge", "reassign", "reset"],
                "turnCount": 2, "cueCount": 2, "exportHashesMatch": True,
            },
            "voiceMemory": {
                "beta": True, "offByDefault": True,
                "localProjectProfileCount": 1, "crossProjectSuggestionCount": 0,
            },
            "configuration": {
                "translator": "translategemma-12b-it-4bit",
                "speakerLabels": True, "readableSubtitles": False,
            },
            "ASR": {
                "adaptiveSelected": False, "lexicalCorrectionSelected": False,
                "backend": "qwen-ja",
            },
        }
        assert development_gate_values(
            mismatched_row,
            {"status": "completed", "failures": [], "speakerReanalysisCount": 1},
            {"stopReason": "completed", "exitStatus": 0, "forcedTermination": False},
        )["workerLifecycleAndUnload"] is False
        assert development_gate_values(
            {}, {}, {"stopReason": "completed", "exitStatus": 1,
                     "forcedTermination": False}
        )["cleanProcessExit"] is False
        lifecycle = worker_lifecycle_summary({
            "asrWorker": {"lifecycle": {
                "processIdentifier": 1, "exitStatus": 0, "terminationReason": "exit",
                "forcedTermination": False, "exitedAt": "2026-01-01T00:00:01Z",
                "availableMemorySamples": [{"availableMemoryBytes": 42}],
            }}
        })
        assert lifecycle["allExitedAndUnloadedCleanly"] is True
        assert lifecycle["workers"]["ASR"]["minimumAvailableMemoryBytes"] == 42
        expected_freeze = {
            "schemaVersion": 2,
            "derivation": {
                "status": "computed-before-holdout",
                "allFunctionalGatesPassed": True,
            },
            "developmentArtifactsSHA256": {"manifest": "expected"},
        }
        assert validate_development_freeze(expected_freeze, expected_freeze)["valid"] is True
        stale_freeze = json.loads(json.dumps(expected_freeze))
        stale_freeze["developmentArtifactsSHA256"]["manifest"] = "stale"
        assert validate_development_freeze(stale_freeze, expected_freeze)["valid"] is False
        with tempfile.TemporaryDirectory() as directory:
            atomic_target = Path(directory) / "freeze.json"
            write_text_atomic(atomic_target, '{"schemaVersion":2}\n')
            assert atomic_target.read_text() == '{"schemaVersion":2}\n'
            assert list(Path(directory).iterdir()) == [atomic_target]
        with tempfile.TemporaryDirectory() as directory:
            provenance_root = Path(directory)
            corpus = CORPORA[0]
            manifest = read(
                Path("docs/japanese-live/corpora") / corpus / "manifest.json"
            )
            lines = []
            for reference in manifest["source"]["references"]:
                label = reference["label"]
                emitted_label = (
                    label if label in {"source-video", "reference-archive"}
                    else "local-reference"
                )
                lines.append(
                    f'{corpus}\t{emitted_label}\t{reference["sha256"]}\t/path\n'
                )
            preflight = provenance_root / "input-preflight.tsv"
            preflight.write_text("".join(lines), encoding="utf-8")
            model_payload = {"weights": [{
                "modelID": "model", "revision": "revision", "file": "weights.bin",
                "sizeBytes": 1, "sha256": "a" * 64,
            }]}
            model_path = provenance_root / "model-provenance.json"
            model_path.write_text(json.dumps(model_payload), encoding="utf-8")
            patch_path = provenance_root / "worktree.patch"
            patch_path.write_text("diff", encoding="utf-8")
            current_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], text=True
            ).strip()
            initial_ready = {
                "baseCommit": current_commit,
                "provenanceSHA256": {
                    "inputs": sha256(preflight), "models": sha256(model_path),
                    "uncommittedPatch": sha256(patch_path),
                },
                "implementationSHA256": {"source": "1" * 64},
            }
            holdout_ready = {
                "baseCommit": current_commit,
                "provenanceSHA256": {
                    "inputs": sha256(preflight), "models": sha256(model_path),
                },
                "implementationSHA256": {"source": "2" * 64},
            }
            (provenance_root / "READY_FOR_HEAVY_BENCHMARK.json").write_text(
                json.dumps(initial_ready), encoding="utf-8"
            )
            (provenance_root / "READY_FOR_HOLDOUT.json").write_text(
                json.dumps(holdout_ready), encoding="utf-8"
            )
            raw = {
                "sampleCount": manifest["fixture"]["sampleCount"],
                "sampleRate": manifest["fixture"]["sampleRate"],
            }
            assert corpus_and_pcm_provenance(
                provenance_root, corpus, raw
            )["status"] == "verified"
            assert model_provenance_summary(provenance_root)["status"] == "verified"
            execution = execution_provenance(provenance_root)
            assert execution["lanes"][0]["patchVerified"] is True
            assert execution["lanes"][1]["patchVerified"] is False
            assert execution["allExecutionPatchesVerified"] is False
            assert execution["allExecutionDiffManifestsComplete"] is True
        before_cues = [{"id": "unit-1", "text": "one two", "start": 0.0, "end": 2.0}]
        after_cues = [
            {"id": "unit-1", "text": "one", "start": 0.0, "end": 1.0},
            {"id": "unit-1-s2", "text": "two", "start": 1.0, "end": 2.0},
        ]
        assert interval_integrity(before_cues, after_cues)["coverageIntervalsMatch"] is True
        assert export_consistency(
            "1\n00:00:00,000 --> 00:00:01,000\none\n\n"
            "2\n00:00:01,000 --> 00:00:02,000\ntwo\n",
            "WEBVTT\n\nunit-1\n00:00:00.000 --> 00:00:01.000\none\n\n"
            "unit-1-s2\n00:00:01.000 --> 00:00:02.000\ntwo\n",
            after_cues,
        )["consistent"] is True
        assert export_consistency(
            "1\n00:00:00,000 --> 00:00:01,000\n[A] one\n",
            "WEBVTT\n\nunit-1\n00:00:00.000 --> 00:00:01.000\n<v B>one\n",
            [after_cues[0]],
        )["consistent"] is False
        asr_fixture_manifest = {
            "fixture": {"sampleRate": 10},
            "annotations": {"turns": [{
                "id": 1, "japanese": "一二", "english": "one two",
                "criticalTerms": [], "startSample": 0, "endSample": 10,
            }]},
        }
        asr_fixture_raw = {
            "rawASR": "一", "adaptiveASR": None,
            "resultTurns": [{"id": "unit-1", "japanese": "一", "start": 0, "end": 1}],
        }
        fixture_asr = asr_diagnostics(asr_fixture_manifest, asr_fixture_raw)
        assert fixture_asr["lostReferenceCharacters"] == 1
        assert fixture_asr["criticalTerms"]["status"] == "notScored"
        assert fixture_asr["examples"][0]["referenceJapanese"] == "一二"
        assert fixture_asr["examples"][0]["hypothesisJapanese"] == "一"
        fixture_manifest = {
            "fixture": {"sampleRate": 10},
            "annotations": {"turns": [
                {"id": 1, "speaker": "A", "startSample": 0, "endSample": 10,
                 "japanese": "一", "english": "one"},
                {"id": 2, "speaker": "B", "startSample": 10, "endSample": 20,
                 "japanese": "二", "english": "two"},
            ]},
        }
        fixture_raw = {"diarization": {"rawSpans": [
            {"speakerID": 7, "start": 0, "end": 1},
            {"speakerID": 7, "start": 1, "end": 2},
        ]}}
        fixture_examples = speaker_examples(fixture_manifest, fixture_raw)
        assert fixture_examples["correct"][0]["turnID"] == 1
        assert fixture_examples["incorrect"][0]["turnID"] == 2
        return
    if args.classify_test_log:
        assert args.suite
        summary = test_log_summary(
            args.classify_test_log.read_text(encoding="utf-8", errors="replace"),
            args.suite,
        )
        print(json.dumps(summary, sort_keys=True))
        raise SystemExit(0 if summary["status"] == "passed" else 1)
    assert args.root
    if args.verify_development_freeze:
        recomputed = development_freeze_snapshot(args.root)
        validation = validate_development_freeze(
            read(args.verify_development_freeze), recomputed
        )
        print(json.dumps(validation, sort_keys=True))
        raise SystemExit(0 if validation["valid"] else 1)
    if args.development_freeze:
        snapshot = development_freeze_snapshot(args.root)
        if not snapshot["derivation"]["allFunctionalGatesPassed"]:
            raise SystemExit("DEV freeze refused: computed functional gates did not all pass")
        write_text_atomic(
            args.development_freeze,
            json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        )
        return
    assert args.json and args.markdown
    verification_root = args.verification_root or args.root
    report = build_report(args.root, verification_root)
    markdown = report_markdown(report)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text(markdown, encoding="utf-8")
    if args.bundle:
        write_bundle(args.bundle, args.root, verification_root, report, markdown)


if __name__ == "__main__":
    main()
