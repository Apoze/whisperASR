#!/usr/bin/env python3
"""Validate and score the frozen #119 lexical DEV replay."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


class EvidenceError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def numbers(text: str) -> list[str]:
    return re.findall(r"\d+", text)


def normalized_mapping(value: dict[str, list[str]]) -> dict[str, list[str]]:
    return {key: sorted(set(items)) for key, items in sorted(value.items()) if items}


def frozen_path(entry: dict[str, Any], freeze_path: Path) -> Path:
    path = Path(entry["path"])
    if path.is_absolute():
        return path
    candidates = [Path.cwd() / path, freeze_path.parent / path]
    return next((candidate for candidate in candidates if candidate.exists()), candidates[0])


def command(*arguments: str, environment: dict[str, str] | None = None) -> str:
    return subprocess.check_output(arguments, text=True, env=environment).strip()


def gzip_content_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with gzip.open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_gzip_json(path: Path) -> dict[str, Any]:
    with gzip.open(path, "rt") as handle:
        return json.load(handle)


def current_runtime() -> dict[str, Any]:
    developer_environment = dict(__import__("os").environ)
    developer_environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    return {
        "architecture": platform.machine(),
        "modelIdentifier": command("sysctl", "-n", "hw.model"),
        "chip": command("sysctl", "-n", "machdep.cpu.brand_string"),
        "logicalCoreCount": int(command("sysctl", "-n", "hw.ncpu")),
        "memoryBytes": int(command("sysctl", "-n", "hw.memsize")),
        "macOSVersion": command("sw_vers", "-productVersion"),
        "xcodeVersion": command(
            "xcodebuild", "-version", environment=developer_environment
        ).replace("\n", " / "),
        "swiftVersion": command(
            "swift", "--version", environment=developer_environment
        ).splitlines()[0],
        "pythonVersion": platform.python_version(),
    }


def turn_coverage(raw: dict[str, Any]) -> dict[str, Any]:
    turns = raw["translation"]["request"]["turns"]
    intervals = sorted((turn["sourceStart"], turn["sourceEnd"]) for turn in turns)
    merged: list[list[float]] = []
    for start, end in intervals:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    duration = raw["sampleCount"] / raw["sampleRate"]
    covered = sum(end - start for start, end in merged)
    ids = "\n".join(turn["id"] for turn in turns).encode()
    return {
        "pcm": {
            "status": "reused",
            "sampleCount": raw["sampleCount"],
            "sampleRate": raw["sampleRate"],
            "durationSeconds": round(duration, 7),
        },
        "turns": {
            "status": "reused",
            "count": len(turns),
            "idsSHA256": hashlib.sha256(ids).hexdigest(),
            "firstSourceStartSeconds": round(min(start for start, _ in intervals), 3),
            "lastSourceEndSeconds": round(max(end for _, end in intervals), 3),
            "coveredDurationSeconds": round(covered, 3),
            "pcmCoverageRatio": round(covered / duration, 9),
        },
    }


def validate_global_provenance(
    replay: dict[str, Any], freeze: dict[str, Any], freeze_path: Path
) -> dict[str, Any]:
    provenance = freeze["globalProvenance"]
    require(command("git", "rev-parse", "HEAD") == provenance["baseCommit"],
            "base commit differs from freeze")
    for path_string, expected_hash in provenance["implementationSourcesSHA256"].items():
        path = frozen_path({"path": path_string}, freeze_path)
        require(path.is_file() and sha256(path) == expected_hash,
                f"implementation source hash differs: {path_string}")

    producer = provenance["e31Producer"]
    files: dict[str, Path] = {}
    for name in ("runMetadata", "replayReuse", "modelProvenance"):
        entry = producer[name]
        path = frozen_path(entry, freeze_path)
        require(path.is_file() and sha256(path) == entry["sha256"],
                f"E31 {name} hash differs")
        files[name] = path
    raw_entry = producer["rawReplay"]
    raw_path = frozen_path(raw_entry, freeze_path)
    require(sha256(raw_path) == raw_entry["gzipSHA256"], "E31 replay gzip hash differs")
    require(gzip_content_sha256(raw_path) == raw_entry["contentSHA256"],
            "E31 replay content hash differs")
    run_metadata = json.loads(files["runMetadata"].read_text())
    require(run_metadata["commit"] == producer["producerCommit"],
            "E31 producer commit differs")
    require(run_metadata["corpusID"] == replay["corpus"], "E31 corpus differs")
    require(run_metadata["rawArtifactSHA256"]["raw-asr.json"]
            == raw_entry["contentSHA256"], "E31 producer/replay chain differs")
    raw = read_gzip_json(raw_path)
    require(replay["baselineTurns"] == raw["translation"]["request"]["turns"],
            "E31 reused turns differ from lexical replay")

    asr = provenance["execution"]["asr"]
    require(asr["status"] == "reused", "ASR must be marked reused")
    require(raw["model"] == {
        "backend": asr["backend"],
        "modelID": asr["modelID"],
        "revision": asr["revision"],
        "weightSHA256": asr["weightSHA256"],
    }, "reused ASR identity differs from E31")
    model_provenance = json.loads(files["modelProvenance"].read_text())
    weight = next((item for item in model_provenance["weights"]
                   if item["modelID"] == asr["modelID"]), None)
    require(weight is not None and weight["revision"] == asr["revision"]
            and {weight["file"]: weight["sha256"]} == asr["weightSHA256"],
            "ASR weights differ from E31 provenance")

    translation = provenance["execution"]["translation"]
    require(translation == {
        "status": "notRun", "modelID": "notApplicable",
        "revision": "notApplicable", "weightSHA256": "notApplicable",
        "latency": "notApplicable",
    }, "translation provenance must be explicit notRun/notApplicable")
    require(all(value == "notApplicable"
                for value in provenance["execution"]["notApplicable"].values()),
            "non-applicable stages must be explicit")
    require(turn_coverage(raw) == provenance["coverage"], "reused PCM/turn coverage differs")

    latency_entry = provenance["lexicalPassLatency"]
    latency_path = frozen_path(latency_entry, freeze_path)
    require(sha256(latency_path) == latency_entry["sha256"], "latency hash differs")
    latency = json.loads(latency_path.read_text())
    samples = latency["samplesMilliseconds"]
    sorted_samples = sorted(samples)
    require(latency["status"] == "measured"
            and latency["operation"] == "HighQualityLexicalCorrection.apply"
            and latency["turnCount"] == len(replay["baselineTurns"])
            and latency["unionTermCount"] == len(replay["correction"]["scope"]["unionTermIDs"])
            and latency["measuredIterations"] == len(samples)
            and latency["changeCounts"] == [len(replay["correction"]["changes"])] * len(samples)
            and latency["medianMilliseconds"] == sorted_samples[len(samples) // 2]
            and latency["p95Milliseconds"] == sorted_samples[-1],
            "lexical latency evidence is inconsistent")
    expected_latency = {key: value for key, value in latency_entry.items()
                        if key not in {"path", "sha256"}}
    actual_latency = {key: latency[key] for key in expected_latency}
    require(actual_latency == expected_latency, "lexical latency differs from freeze")
    require(provenance["runtime"] == current_runtime(), "hardware/runtime differs from freeze")
    return {"e31Producer": producer, "execution": provenance["execution"],
            "coverage": provenance["coverage"], "lexicalPassLatency": latency,
            "runtime": provenance["runtime"], "baseCommit": provenance["baseCommit"],
            "implementationSourcesSHA256": provenance["implementationSourcesSHA256"]}


def validate_frozen_inputs(
    replay_path: Path,
    reference_path: Path,
    freeze_path: Path,
    replay: dict[str, Any],
    freeze: dict[str, Any],
) -> None:
    require(freeze.get("schemaVersion") == 3, "unexpected freeze schema")
    require(freeze.get("ticket") == 119 and freeze.get("split") == "development",
            "wrong frozen experiment")
    require(replay.get("schemaVersion") == 2 and replay.get("ticket") == 119,
            "wrong replay experiment")
    require(replay.get("corpus") == freeze.get("corpus"), "corpus differs from freeze")

    for name, supplied in (("replay", replay_path), ("reference", reference_path)):
        entry = freeze[name]
        expected_path = frozen_path(entry, freeze_path)
        require(supplied.resolve() == expected_path.resolve(), f"{name} path differs from freeze")
        require(sha256(supplied) == entry["sha256"], f"{name} hash differs from freeze")

    baseline = freeze["baselineRawEvidence"]
    baseline_path = frozen_path(baseline, freeze_path)
    require(baseline_path.is_file(), "frozen baseline is missing")
    require(sha256(baseline_path) == baseline["sha256"], "baseline hash differs from freeze")
    require(gzip_content_sha256(baseline_path) == baseline["contentSHA256"],
            "baseline content hash differs from freeze")
    require(replay.get("sourceArtifact") == baseline["path"],
            "replay source differs from freeze")
    require(replay.get("correction", {}).get("policy") == freeze.get("policy"),
            "correction policy differs from freeze")


def validate_scope(replay: dict[str, Any], freeze: dict[str, Any]) -> None:
    correction = replay["correction"]
    scope = correction["scope"]
    frozen = freeze["closedScope"]
    project_ids = sorted(set(scope["projectMetadataTermIDs"]))
    source_ids = sorted(set(scope["sourceMetadataTermIDs"]))
    cue_local = normalized_mapping(scope["cueLocalSelectedTermIDsByCueID"])
    require(project_ids == frozen["projectMetadataTermIDs"],
            "Project metadata scope differs from freeze")
    require(source_ids == frozen["sourceMetadataTermIDs"],
            "source metadata scope differs from freeze")
    require(cue_local == normalized_mapping(frozen["cueLocalSelectedTermIDsByCueID"]),
            "cue-local scope differs from freeze")

    decisions = replay["selection"]["decisions"]
    selected_project = sorted({
        item["term"]["id"] for item in decisions
        if any(signal["source"] == "project-metadata" for signal in item["signals"])
    })
    selected_source = sorted({
        item["term"]["id"] for item in decisions
        if any(signal["source"] in {"title", "channel", "description"}
               for signal in item["signals"])
    })
    selected_cue_local: dict[str, list[str]] = {}
    for item in decisions:
        for cue_id in item["selectedCueIDs"]:
            selected_cue_local.setdefault(cue_id, []).append(item["term"]["id"])
    require(selected_project == project_ids, "Project metadata audit does not match scope")
    require(selected_source == source_ids, "source metadata audit does not match scope")
    require(normalized_mapping(selected_cue_local) == cue_local,
            "cue-local selection audit does not match scope")

    global_union = sorted(set(project_ids + source_ids + sum(cue_local.values(), [])))
    require(scope["unionTermIDs"] == global_union, "global frozen union is invalid")
    baseline_ids = [turn["id"] for turn in replay["baselineTurns"]]
    union_by_cue = scope["unionTermIDsByCueID"]
    require(set(union_by_cue) == set(baseline_ids), "per-cue union coverage is incomplete")
    for cue_id in baseline_ids:
        expected = sorted(set(project_ids + source_ids + cue_local.get(cue_id, [])))
        require(union_by_cue[cue_id] == expected, f"candidate union differs for {cue_id}")
    for change in correction["changes"]:
        require(change["canonicalTermID"] in union_by_cue.get(change["cueID"], []),
                f"correction outside frozen union for {change['cueID']}")


def validate_corrected_turns(replay: dict[str, Any], freeze: dict[str, Any]) -> None:
    baseline = replay["baselineTurns"]
    corrected = replay["correctedTurns"]
    expected_count = freeze["replay"]["expectedTurnCount"]
    require(len(baseline) == expected_count and len(corrected) == expected_count,
            "correctedTurns is truncated")
    baseline_ids = [turn["id"] for turn in baseline]
    corrected_ids = [turn["id"] for turn in corrected]
    require(len(set(baseline_ids)) == expected_count, "baseline IDs are not unique")
    require(corrected_ids == baseline_ids, "correctedTurns IDs/order differ from baseline")
    preserved = [
        "id", "precedingJapanese", "followingJapanese", "speakerLabel",
        "sourceStart", "sourceEnd",
    ]
    changes_by_cue: dict[str, list[dict[str, Any]]] = {}
    for change in replay["correction"]["changes"]:
        changes_by_cue.setdefault(change["cueID"], []).append(change)
    for before, after in zip(baseline, corrected):
        require(all(before.get(key) == after.get(key) for key in preserved),
                f"context/timing changed for {before['id']}")
        changes = changes_by_cue.get(before["id"], [])
        if not changes:
            require(after["japanese"] == before["japanese"],
                    f"unaudited text change for {before['id']}")
            continue
        require(all(item["originalText"] == before["japanese"] for item in changes),
                f"audit original differs for {before['id']}")
        require(all(item["correctedText"] == after["japanese"] for item in changes),
                f"audit corrected text differs for {before['id']}")
        require(before["japanese"] != after["japanese"],
                f"no-op correction recorded for {before['id']}")
    require(set(changes_by_cue).issubset(set(baseline_ids)), "change references unknown cue")


def build_report(
    replay_path: Path,
    reference_path: Path,
    freeze_path: Path,
) -> dict[str, Any]:
    replay = json.loads(replay_path.read_text())
    reference = json.loads(reference_path.read_text())
    freeze = json.loads(freeze_path.read_text())
    validate_frozen_inputs(replay_path, reference_path, freeze_path, replay, freeze)
    validate_scope(replay, freeze)
    validate_corrected_turns(replay, freeze)
    provenance = validate_global_provenance(replay, freeze, freeze_path)

    turns = {turn["id"]: turn for turn in replay["baselineTurns"]}
    reference_turns = reference["annotations"]["turns"]
    details = []
    useful = wrong = unscorable = number_losses = critical_losses = 0
    critical_scorable_changes = 0
    for change in replay["correction"]["changes"]:
        turn = turns[change["cueID"]]
        start, end = turn.get("sourceStart"), turn.get("sourceEnd")
        overlapping = [] if start is None or end is None else [
            item for item in reference_turns
            if item["startSample"] / 16_000 < end
            and item["endSample"] / 16_000 > start
        ]
        reference_japanese = "".join(item["japanese"] for item in overlapping)
        if not overlapping:
            verdict = "unscorable-no-reference-overlap"
            unscorable += 1
        elif change["canonicalJapanese"] in reference_japanese:
            verdict = "useful"
            useful += 1
        else:
            verdict = "wrong"
            wrong += 1
        number_preserved = numbers(change["originalText"]) == numbers(change["correctedText"])
        number_losses += 0 if number_preserved else 1
        annotated_terms = [
            term for item in overlapping for term in (item.get("criticalTerms") or [])
        ]
        critical_scorable = bool(annotated_terms)
        critical_scorable_changes += int(critical_scorable)
        lost_critical = [
            term["canonical"] for term in annotated_terms
            if term.get("canonical")
            and term["canonical"] in change["originalText"]
            and term["canonical"] not in change["correctedText"]
        ]
        critical_losses += len(lost_critical)
        details.append({
            **change,
            "sourceStart": start,
            "sourceEnd": end,
            "referenceJapanese": reference_japanese,
            "referenceEnglish": " ".join(item["english"] for item in overlapping),
            "referenceTurnIDs": [item["id"] for item in overlapping],
            "verdict": verdict,
            "numberPreserved": number_preserved,
            "criticalTermsStatus": "scored" if critical_scorable else "notScored",
            "lostCriticalTerms": lost_critical if critical_scorable else None,
        })

    all_critical_scorable = bool(details) and critical_scorable_changes == len(details)
    critical_status = (
        "notScored" if not all_critical_scorable
        else "passed" if critical_losses == 0
        else "failed"
    )
    development_passed = (
        useful > wrong and number_losses == 0 and critical_status == "passed"
    )
    return {
        "schemaVersion": 3,
        "ticket": 119,
        "split": "development",
        "corpus": replay["corpus"],
        "frozenPolicy": replay["correction"]["policy"],
        "frozenScope": replay["correction"]["scope"],
        "globalProvenance": provenance,
        "inputs": {
            "freeze": str(freeze_path),
            "freezeSHA256": sha256(freeze_path),
            "replay": str(replay_path),
            "replaySHA256": sha256(replay_path),
            "baselineRawEvidence": replay["sourceArtifact"],
            "reference": str(reference_path),
            "referenceSHA256": sha256(reference_path),
        },
        "metrics": {
            "changedCues": len({item["cueID"] for item in details}),
            "changes": len(details),
            "confirmedUseful": useful,
            "wrong": wrong,
            "unscorable": unscorable,
            "numberLosses": number_losses,
            "criticalTermIntegrity": {
                "status": critical_status,
                "scorableChanges": critical_scorable_changes,
                "totalChanges": len(details),
                "losses": critical_losses if all_critical_scorable else None,
            },
        },
        "gates": {
            "usefulExceedsWrong": useful > wrong,
            "zeroNumberLoss": number_losses == 0,
            "criticalTermIntegrity": critical_status,
            "developmentPassed": development_passed,
            "holdoutOpened": False,
            "downstreamEnglishRun": False,
        },
        "decision": "NO-GO-stop-before-translation-and-holdout",
        "details": details,
    }


def expect_failure(action: Any, contains: str) -> None:
    try:
        action()
    except EvidenceError as error:
        require(contains in str(error), f"unexpected self-test failure: {error}")
    else:
        raise AssertionError(f"expected fail-closed error containing {contains!r}")


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        baseline_path = root / "e31-raw.json.gz"
        run_metadata_path = root / "e31-run-meta.json"
        replay_reuse_path = root / "e31-replay-reuse.json"
        model_provenance_path = root / "e31-model-provenance.json"
        latency_path = root / "latency.json"
        replay_path = root / "replay.json"
        reference_path = root / "reference.json"
        freeze_path = root / "freeze.json"
        turns = [
            {"id": "cue-1", "japanese": "あまゆいも", "precedingJapanese": [],
             "followingJapanese": [], "speakerLabel": None, "sourceStart": 0, "sourceEnd": 1},
            {"id": "cue-2", "japanese": "変更なし", "precedingJapanese": [],
             "followingJapanese": [], "speakerLabel": None, "sourceStart": 1, "sourceEnd": 2},
        ]
        corrected = copy.deepcopy(turns)
        corrected[0]["japanese"] = "甘結もか"
        policy = {
            "version": "ja-closed-v1", "minimumScore": 0.75,
            "ambiguityMargin": 0.08, "minimumFormCharacters": 4,
            "maximumEditDistance": 1, "maximumScoringOperationsPerCue": 512,
        }
        origins = {
            "projectMetadataTermIDs": ["amayui-moka"],
            "sourceMetadataTermIDs": [],
            "cueLocalSelectedTermIDsByCueID": {},
        }
        scope = {
            **origins,
            "unionTermIDs": ["amayui-moka"],
            "unionTermIDsByCueID": {
                "cue-1": ["amayui-moka"], "cue-2": ["amayui-moka"],
            },
        }
        decision = {
            "term": {"id": "amayui-moka"},
            "signals": [{"source": "project-metadata"}],
            "selectedCueIDs": [],
        }
        replay = {
            "schemaVersion": 2, "ticket": 119, "corpus": "fixture",
            "sourceArtifact": str(baseline_path), "baselineTurns": turns,
            "correctedTurns": corrected, "selection": {"decisions": [decision]},
            "correction": {"policy": policy, "scope": scope, "changes": [{
                "cueID": "cue-1", "originalText": "あまゆいも",
                "correctedText": "甘結もか", "canonicalTermID": "amayui-moka",
                "canonicalJapanese": "甘結もか", "matchedForm": "あまゆいも",
                "score": 0.8, "reason": "fixture",
            }]},
        }
        asr_model = {
            "backend": "qwen-ja", "modelID": "fixture/qwen-ja",
            "revision": "fixture-revision",
            "weightSHA256": {"model.safetensors": "fixture-weight"},
        }
        e31_raw = {
            "sampleCount": 32_000, "sampleRate": 16_000,
            "rawASR": [{"fixture": 1}, {"fixture": 2}],
            "model": asr_model,
            "translation": {"request": {"turns": turns}},
        }
        with gzip.open(baseline_path, "wt") as handle:
            json.dump(e31_raw, handle)
        base_commit = command("git", "rev-parse", "HEAD")
        run_metadata = {
            "commit": "e31-producer-commit", "corpusID": "fixture",
            "rawArtifactSHA256": {"raw-asr.json": gzip_content_sha256(baseline_path)},
        }
        run_metadata_path.write_text(json.dumps(run_metadata))
        replay_reuse_path.write_text(json.dumps({"status": "reused"}))
        model_provenance_path.write_text(json.dumps({"weights": [{
            "modelID": asr_model["modelID"], "revision": asr_model["revision"],
            "file": "model.safetensors", "sha256": "fixture-weight",
        }]}))
        latency = {
            "schemaVersion": 1, "ticket": 119, "corpus": "fixture",
            "status": "measured", "operation": "HighQualityLexicalCorrection.apply",
            "method": "ContinuousClock fixture", "buildConfiguration": "debug",
            "warmupIterations": 1, "measuredIterations": 5, "turnCount": 2,
            "unionTermCount": 1, "changeCounts": [1, 1, 1, 1, 1],
            "samplesMilliseconds": [1.0, 2.0, 3.0, 4.0, 5.0],
            "medianMilliseconds": 3.0, "p95Milliseconds": 5.0,
        }
        latency_path.write_text(json.dumps(latency))
        reference = {"annotations": {"turns": [{
            "id": 1, "startSample": 0, "endSample": 16_000,
            "japanese": "甘結もか", "english": "Amayui Moka", "criticalTerms": [],
        }]}}
        reference_path.write_text(json.dumps(reference))
        replay_path.write_text(json.dumps(replay))
        freeze = {
            "schemaVersion": 3, "ticket": 119, "split": "development",
            "corpus": "fixture", "policy": policy, "closedScope": origins,
            "baselineRawEvidence": {
                "path": str(baseline_path), "sha256": sha256(baseline_path),
                "contentSHA256": gzip_content_sha256(baseline_path),
            },
            "reference": {"path": str(reference_path), "sha256": sha256(reference_path)},
            "replay": {"path": str(replay_path), "sha256": sha256(replay_path),
                       "expectedTurnCount": 2},
            "globalProvenance": {
                "baseCommit": base_commit,
                "implementationSourcesSHA256": {
                    str(Path(__file__).resolve()): sha256(Path(__file__).resolve()),
                },
                "e31Producer": {
                    "producerCommit": "e31-producer-commit",
                    "runMetadata": {"path": str(run_metadata_path),
                                    "sha256": sha256(run_metadata_path)},
                    "replayReuse": {"path": str(replay_reuse_path),
                                    "sha256": sha256(replay_reuse_path)},
                    "modelProvenance": {"path": str(model_provenance_path),
                                        "sha256": sha256(model_provenance_path)},
                    "rawReplay": {"path": str(baseline_path),
                                  "gzipSHA256": sha256(baseline_path),
                                  "contentSHA256": gzip_content_sha256(baseline_path)},
                },
                "execution": {
                    "asr": {"status": "reused", **asr_model},
                    "translation": {
                        "status": "notRun", "modelID": "notApplicable",
                        "revision": "notApplicable", "weightSHA256": "notApplicable",
                        "latency": "notApplicable",
                    },
                    "notApplicable": {
                        "newPCMDecode": "notApplicable", "alignmentRun": "notApplicable",
                        "diarizationRun": "notApplicable", "subtitleReflow": "notApplicable",
                        "liveMode": "notApplicable", "holdout": "notApplicable",
                    },
                },
                "coverage": turn_coverage(e31_raw),
                "lexicalPassLatency": {
                    "path": str(latency_path), "sha256": sha256(latency_path), **latency,
                },
                "runtime": current_runtime(),
            },
        }
        freeze_path.write_text(json.dumps(freeze))
        report = build_report(replay_path, reference_path, freeze_path)
        require(report["metrics"]["criticalTermIntegrity"]["status"] == "notScored",
                "empty criticalTerms must remain notScored")
        require(report["gates"]["developmentPassed"] is False,
                "unscored critical terms must block promotion")
        require(report["globalProvenance"]["execution"]["translation"]["status"] == "notRun",
                "translation must remain notRun")

        corrupted_freeze = copy.deepcopy(freeze)
        corrupted_freeze["corpus"] = "other"
        freeze_path.write_text(json.dumps(corrupted_freeze))
        expect_failure(lambda: build_report(replay_path, reference_path, freeze_path), "corpus")
        corrupted_freeze = copy.deepcopy(freeze)
        corrupted_freeze["reference"]["sha256"] = "0" * 64
        freeze_path.write_text(json.dumps(corrupted_freeze))
        expect_failure(lambda: build_report(replay_path, reference_path, freeze_path), "hash")
        corrupted_freeze = copy.deepcopy(freeze)
        source_path = next(iter(corrupted_freeze["globalProvenance"]
                                ["implementationSourcesSHA256"]))
        corrupted_freeze["globalProvenance"]["implementationSourcesSHA256"][source_path] = "0" * 64
        freeze_path.write_text(json.dumps(corrupted_freeze))
        expect_failure(lambda: build_report(replay_path, reference_path, freeze_path),
                       "implementation source hash")
        freeze_path.write_text(json.dumps(freeze))

        corrupted_replay = copy.deepcopy(replay)
        corrupted_replay["correction"]["scope"]["unionTermIDs"].append("outside")
        replay_path.write_text(json.dumps(corrupted_replay))
        corrupted_freeze = copy.deepcopy(freeze)
        corrupted_freeze["replay"]["sha256"] = sha256(replay_path)
        freeze_path.write_text(json.dumps(corrupted_freeze))
        expect_failure(lambda: build_report(replay_path, reference_path, freeze_path), "union")

        corrupted_replay = copy.deepcopy(replay)
        corrupted_replay["correctedTurns"].pop()
        replay_path.write_text(json.dumps(corrupted_replay))
        corrupted_freeze = copy.deepcopy(freeze)
        corrupted_freeze["replay"]["sha256"] = sha256(replay_path)
        freeze_path.write_text(json.dumps(corrupted_freeze))
        expect_failure(lambda: build_report(replay_path, reference_path, freeze_path), "truncated")
    print("self-test: ok")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--replay", type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--freeze", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    require(all((args.replay, args.reference, args.freeze, args.output)),
            "--replay, --reference, --freeze and --output are required")
    report = build_report(args.replay, args.reference, args.freeze)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
