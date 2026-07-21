#!/usr/bin/env python3
"""Validate the L7C full-video matrix and normalize its raw evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from source_tree_provenance import snapshot

CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
WINDOWS = {f"{corpus}-full" for corpus in CORPORA}
PREFLIGHT_WINDOWS = {
    "qudu-fast-1",
    "qudu-fast-2",
    "md62-dialogue-1",
    "md62-dialogue-2",
}
CONTROL_TURN_COUNT = 470
EXPECTED_CANDIDATE_SESSION_COUNT = 22
WLK_FINAL_LATENCY_SCOPE = "capture-eos-to-accepted-apple-high-fidelity"
NATIVE = {
    "whisper-large-v3-turbo",
    "mlx-whisper-large-v3-turbo",
    "voxtral-q4-continuous-960ms",
    "nemotron-multilingual-coreml-1120ms",
    "nemotron-multilingual-coreml-560ms",
    "kotoba-whisper-v2.0-q5",
    "qwen3-asr-1.7b",
    "whispermlx-v3.12.2-turbo-long-form",
}
WHISPERMLX_VAD = "whispermlx-v3.12.2-turbo-vad-finals"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1_048_576):
            digest.update(chunk)
    return digest.hexdigest()


def exact(actual: list[tuple], expected: set[tuple]) -> bool:
    return len(actual) == len(set(actual)) == len(expected) and set(actual) == expected


def corpus_signature(report: dict) -> tuple[tuple, ...]:
    return tuple(sorted(
        (
            item.get("corpusID"),
            item.get("manifestSHA256"),
            item.get("audioSHA256"),
            item.get("annotationStatus"),
        )
        for item in report.get("corpora", [])
    ))


def self_test() -> None:
    assert exact([("a", 1), ("b", 1)], {("a", 1), ("b", 1)})
    assert not exact([("a", 1), ("a", 1)], {("a", 1), ("b", 1)})
    assert WINDOWS == {"qudu2fx3ncc-full", "md62mmdz0m-full"}
    assert len(NATIVE) * len(WINDOWS) + 3 * len(WINDOWS) == EXPECTED_CANDIDATE_SESSION_COUNT
    terminal_silence = {
        "windowStartSample": 10,
        "windowEndSample": 100,
        "terminalSilenceStartSample": 80,
        "terminalSilenceEndSample": 100,
    }
    assert terminal_silence_valid(terminal_silence)
    assert required_through(terminal_silence) == 80
    assert required_through({"windowEndSample": 100}) == 100
    alignment = {
        "schemaVersion": 4,
        "status": "diagnostic-only",
        "corpusID": "fixture",
        "provenance": {
            "manifest": {"sha256": "manifest"},
            "canonicalAudio": {"sha256": "audio"},
        },
        "alignment": {
            "sampleRate": 16_000,
            "firefoxSamplesPerCanonicalSample": 1.0,
            "maximumResidualSamples": 10,
            "anchors": [
                {"coarseCorrelation": 0.99, "sampleCorrelation": 0.95,
                 "residualSamples": 10}
                for _ in range(5)
            ],
        },
    }
    assert alignment_valid(alignment, "fixture", "manifest", "audio")


def native_key(session: dict) -> tuple:
    return session.get("recipeID"), session.get("windowID"), session.get("replay")


def live_key(session: dict) -> tuple:
    return session.get("windowID"), session.get("replay")


def terminal_silence_valid(session: dict) -> bool:
    start = session.get("terminalSilenceStartSample")
    end = session.get("terminalSilenceEndSample")
    if start is None and end is None:
        return True
    return (
        isinstance(start, int)
        and isinstance(end, int)
        and isinstance(session.get("windowStartSample"), int)
        and isinstance(session.get("windowEndSample"), int)
        and session.get("windowStartSample") <= start <= session.get("windowEndSample")
        and end == session.get("windowEndSample")
    )


def required_through(session: dict) -> int | None:
    if terminal_silence_valid(session):
        silence_start = session.get("terminalSilenceStartSample")
        return silence_start if silence_start is not None else session.get("windowEndSample")
    return None


def translated(events: list[dict]) -> bool:
    return bool(events) and all(
        not event.get("error")
        and bool(str(event.get("source") or event.get("japanese") or "").strip())
        and bool(str(event.get("english") or "").strip())
        for event in events
    )


def native_asr_complete(session: dict) -> bool:
    start = session.get("windowStartSample")
    end = session.get("windowEndSample")
    required = required_through(session)
    finalized = session.get("asrFinalizedThrough")
    audio_ms = session.get("audioMilliseconds")
    asr_wall = session.get("asrWallMilliseconds")
    pipeline_wall = session.get("pipelineWallMilliseconds")
    return (
        isinstance(start, int)
        and isinstance(end, int)
        and end > start
        and session.get("expectedSampleCount") == end - start
        and session.get("pcmAnalyzedThrough") == end
        and isinstance(required, int)
        and isinstance(finalized, int)
        and required <= finalized <= end
        and session.get("unaccountedSampleCount") == 0
        and not session.get("errors")
        and bool(str(session.get("japaneseFinal") or "").strip())
        and bool(session.get("fragments"))
        and isinstance(session.get("continuousCER"), dict)
        and bool(str(session.get("effectiveRecipeSHA256") or "").strip())
        and bool(str(session.get("finalLatencyScope") or "").strip())
        and isinstance(audio_ms, (int, float)) and audio_ms > 0
        and isinstance(asr_wall, (int, float)) and asr_wall >= 0
        and isinstance(pipeline_wall, (int, float)) and pipeline_wall >= asr_wall
        and isinstance(session.get("endToEndWallRTF"), (int, float))
        and abs(session["endToEndWallRTF"] - pipeline_wall / audio_ms) <= 1e-6
        and isinstance(session.get("maximumResidentBytes"), int)
        and session["maximumResidentBytes"] > 0
        and isinstance(session.get("averageCPUPercent"), (int, float))
        and session["averageCPUPercent"] >= 0
        and bool(str(session.get("thermalStateBefore") or "").strip())
        and bool(str(session.get("thermalStateAfter") or "").strip())
    )


def native_session_complete(session: dict, require_english: bool = True) -> bool:
    if not native_asr_complete(session):
        return False
    if not require_english:
        return True
    required = required_through(session)
    english_through = session.get("englishValidatedThrough")
    events = session.get("finalTranslationEvents", [])
    fragments = session.get("fragments", [])
    preview_role = session.get("previewRole")
    preview_valid = (
        preview_role == "apple-speech-common"
        and session.get("previewLatencyScope") == "shared-apple-speech-control"
    ) or (
        preview_role == "candidate-native"
        and session.get("previewLatencyScope")
            == "source-phrase-start-to-accepted-apple-low-latency"
        and translated(session.get("previewEvents", []))
        and session.get("previewSourceFirstLatencyMilliseconds")
        and session.get("previewFirstLatencyMilliseconds")
        and isinstance(session.get("previewRevisionCount"), int)
        and session["previewRevisionCount"] >= 0
    )
    return (
        preview_valid
        and session.get("finalTranslationsAppendOnly") is True
        and translated(events)
        and len(events) == len(fragments)
        and all(
            event.get("sourceStartSample") == fragment.get("startSample")
            and str(event.get("source") or "").strip()
                == str(fragment.get("text") or "").strip()
            for event, fragment in zip(events, fragments)
        )
        and isinstance(english_through, int)
        and required <= english_through <= session["windowEndSample"]
        and len({event.get("finalID") for event in events}) == len(events)
        and all(
            isinstance(event.get("sourceStartSample"), int)
            and isinstance(event.get("sourceEndSample"), int)
            and session["windowStartSample"] <= event["sourceStartSample"]
            < event["sourceEndSample"] <= session["windowEndSample"]
            for event in events
        )
        and max(
            event.get("sourceEndSample")
                if isinstance(event.get("sourceEndSample"), int) else -1
            for event in events
        ) >= required
    )


def native_report_complete(
    report: dict,
    sessions: list[dict],
    require_english: bool = True,
) -> bool:
    raw_complete = all(
        native_session_complete(session, require_english=require_english)
        for session in sessions
    )
    return raw_complete and report.get("matrixComplete") is True


def live_asr_complete(session: dict) -> bool:
    start = session.get("windowStartSample")
    end = session.get("windowEndSample")
    audio_ms = session.get("audioMilliseconds")
    asr_wall = session.get("asrWallMilliseconds")
    pipeline_wall = session.get("pipelineWallMilliseconds")
    return (
        isinstance(start, int)
        and isinstance(end, int)
        and end > start
        and session.get("expectedSampleCount") == end - start
        and session.get("sentSampleCount") == session.get("expectedSampleCount")
        and session.get("readyToStopReceived") is True
        and not session.get("errors")
        and bool(str(session.get("japaneseFinal") or "").strip())
        and any(
            event.get("isFinal") is True
            and bool(str(event.get("text") or "").strip())
            for event in session.get("sourceEvents", [])
        )
        and session.get("lastAnnotatedSpeechPresent") is True
        and isinstance(session.get("japaneseCERDetail"), dict)
        and isinstance(audio_ms, (int, float)) and audio_ms > 0
        and isinstance(asr_wall, (int, float)) and asr_wall >= 0
        and isinstance(pipeline_wall, (int, float)) and pipeline_wall >= asr_wall
        and isinstance(session.get("endToEndWallRTF"), (int, float))
        and abs(session["endToEndWallRTF"] - pipeline_wall / audio_ms) <= 1e-6
        and isinstance(session.get("maximumObservedResidentBytes"), int)
        and session["maximumObservedResidentBytes"] > 0
        and isinstance(session.get("averageCPUPercent"), (int, float))
        and session["averageCPUPercent"] >= 0
        and bool(str(session.get("thermalStateBefore") or "").strip())
        and bool(str(session.get("thermalStateAfter") or "").strip())
    )


def live_session_complete(session: dict) -> bool:
    return (
        live_asr_complete(session)
        and session.get("previewLatencyScope")
            == "source-phrase-start-to-accepted-apple-low-latency"
        and session.get("previewSourceFirstLatencyMilliseconds")
        and session.get("previewFirstLatencyMilliseconds")
        and isinstance(session.get("previewRevisionCount"), int)
        and session["previewRevisionCount"] >= 0
        and session.get("previewTranslationComplete") is True
        and translated(session.get("previewEvents", []))
        and session.get("finalTranslationComplete") is True
        and session.get("finalTranslationsAppendOnly") is True
        and translated(session.get("finalEvents", []))
        and session.get("finalExpectedEventCount") == len(session.get("finalEvents", []))
        and len(session.get("finalEndpointLatencyMilliseconds", []))
            == len(session.get("finalEvents", []))
        and session.get("finalLatencyScope") == WLK_FINAL_LATENCY_SCOPE
        and session.get("finalBoundaryMode") == "window-eos-only-no-live-phrase-final"
        and (session.get("endingProcessingBacklogSeconds") or 0) <= 0.1
    )


def apple_session_complete(session: dict) -> bool:
    return (
        session.get("source") == "apple-speech"
        and live_asr_complete(session)
        and session.get("previewLatencyScope")
            == "source-phrase-start-to-accepted-apple-low-latency"
        and session.get("previewSourceFirstLatencyMilliseconds")
        and session.get("previewFirstLatencyMilliseconds")
        and isinstance(session.get("previewRevisionCount"), int)
        and session["previewRevisionCount"] >= 0
        and session.get("previewTranslationComplete") is True
        and translated(session.get("previewEvents", []))
        and not session.get("finalEvents")
        and session.get("finalExpectedEventCount") == 0
        and session.get("finalTranslationsAppendOnly") is True
        and session.get("finalTranslationComplete") is False
        and session.get("finalLatencyScope") == "not-applicable-preview-only"
    )


def control_complete(
    report: dict,
    expected_turns: dict[tuple[str, int], tuple[int, int]],
    expected_corpora: set[tuple],
) -> bool:
    turns = report.get("turns", [])
    actual_keys = [(turn.get("corpusID"), turn.get("turnID")) for turn in turns]
    return (
        len(expected_turns) == CONTROL_TURN_COUNT
        and report.get("translationPath")
            == "human Japanese reference -> Apple highFidelity English"
        and exact(actual_keys, set(expected_turns))
        and {
            (
                item.get("corpusID"),
                item.get("manifestSHA256"),
                item.get("annotationStatus"),
                item.get("turnCount"),
            )
            for item in report.get("corpora", [])
        } == expected_corpora
        and all(
            (turn.get("startSample"), turn.get("endSample"))
                == expected_turns[(turn.get("corpusID"), turn.get("turnID"))]
            and not turn.get("error")
            and bool(str(turn.get("english") or "").strip())
            and isinstance(turn.get("milliseconds"), (int, float))
            and turn.get("milliseconds") >= 0
            and turn.get("attemptCount") in (1, 2, 3)
            for turn in turns
        )
    )


def startups_valid(report: dict, expected_count: int) -> bool:
    models = report.get("models", [])
    return len(models) == expected_count and all(
        isinstance(model.get("setupMilliseconds"), (int, float))
        and model["setupMilliseconds"] >= 0
        and bool(str(model.get("startupMeasurementScope") or "").strip())
        and (
            not str(model.get("runtime") or "").startswith(("mlx-whisper", "whispermlx"))
            or (
                isinstance(model.get("warmupMilliseconds"), (int, float))
                and model["warmupMilliseconds"] >= 0
            )
        )
        for model in models
    )


def effective_recipes_consistent(sessions: list[dict]) -> bool:
    by_recipe: dict[str, set[str]] = {}
    for session in sessions:
        recipe = session.get("recipeID")
        digest = session.get("effectiveRecipeSHA256")
        if not recipe or not digest:
            return False
        by_recipe.setdefault(recipe, set()).add(digest)
    return bool(by_recipe) and all(len(values) == 1 for values in by_recipe.values())


def alignment_valid(
    report: dict,
    corpus: str,
    manifest_sha: str,
    fixture_sha: str,
) -> bool:
    alignment = report.get("alignment", {})
    anchors = alignment.get("anchors", [])
    provenance = report.get("provenance", {})
    scale = alignment.get("firefoxSamplesPerCanonicalSample")
    maximum_residual = alignment.get("maximumResidualSamples")
    return (
        report.get("schemaVersion") == 4
        and report.get("status") == "diagnostic-only"
        and report.get("corpusID") == corpus
        and provenance.get("manifest", {}).get("sha256") == manifest_sha
        and provenance.get("canonicalAudio", {}).get("sha256") == fixture_sha
        and alignment.get("sampleRate") == 16_000
        and isinstance(scale, (int, float))
        and abs(scale - 1) <= 0.001
        and isinstance(maximum_residual, (int, float))
        and abs(maximum_residual) <= 160
        and len(anchors) >= 5
        and all(
            isinstance(anchor.get("coarseCorrelation"), (int, float))
            and anchor["coarseCorrelation"] >= 0.95
            and isinstance(anchor.get("sampleCorrelation"), (int, float))
            and anchor["sampleCorrelation"] >= 0.85
            and isinstance(anchor.get("residualSamples"), (int, float))
            and abs(anchor["residualSamples"]) <= 160
            for anchor in anchors
        )
    )


def firefox_evidence(
    manifest_paths: list[Path],
    alignment_paths: list[Path],
    manifests: dict[str, dict],
    root: Path,
) -> tuple[bool, list[dict]]:
    if not len(manifest_paths) == len(alignment_paths) == len(CORPORA):
        return False, []
    alignments = {report.get("corpusID"): (path, report) for path in alignment_paths
                  for report in [load(path)]}
    summaries = []
    valid = set(alignments) == set(CORPORA)
    for path in manifest_paths:
        report = load(path)
        corpus = report.get("corpus", {}).get("id")
        if corpus not in manifests or corpus not in alignments:
            valid = False
            continue
        manifest = manifests[corpus]
        manifest_path = root / "docs" / "japanese-live" / "corpora" / corpus / "manifest.json"
        fixture_path = root / manifest["fixture"]["path"]
        manifest_sha = sha256(manifest_path)
        fixture_sha = sha256(fixture_path)
        alignment_path, alignment_report = alignments[corpus]
        artifacts = report.get("artifacts", {})
        session_path = path.parent / str(artifacts.get("sessionFile") or "missing")
        session = load(session_path) if session_path.is_file() else {}
        canonical_pcm_path = path.parent / str(
            session.get("canonicalPCMFile") or "missing"
        )
        metrics_path = path.parent / str(session.get("metricsFile") or "missing")
        metrics_csv_path = path.parent / str(
            session.get("metricsCSVFile") or "missing"
        )
        application = report.get("application", {})
        attestation_path = Path(str(application.get("buildAttestationFile") or "missing"))
        attestation = load(attestation_path) if attestation_path.is_file() else {}
        source = report.get("source", {})
        candidate = report.get("candidate", {})
        firefox = report.get("captureApplication", {})
        declared_artifacts_valid = all(
            (path.parent / str(artifacts.get(file_key) or "missing")).is_file()
            and sha256(path.parent / str(artifacts[file_key])) == artifacts.get(sha_key)
            for file_key, sha_key in (
                ("comparisonFile", "comparisonSHA256"),
                ("blindReportFile", "blindReportSHA256"),
                ("keyReportFile", "keyReportSHA256"),
            )
        )
        current_application_path = Path(str(application.get("file") or "missing"))
        current_application_matches_capture = (
            current_application_path.is_file()
            and sha256(current_application_path) == application.get("sha256")
        )
        alignment_provenance = alignment_report.get("provenance", {})
        source_valid = (
            report.get("schemaVersion") == 1
            and report.get("status") == "finalized"
            and report.get("git", {}).get("dirty") is False
            and bool(str(report.get("git", {}).get("commit") or "").strip())
            and firefox.get("bundleID") == "org.mozilla.firefox"
            and report.get("configuration", {}).get("realTimeReplayCount") == 1
            and report.get("configuration", {}).get("microphone") is False
            and report.get("corpus", {}).get("manifestSHA256") == manifest_sha
            and report.get("corpus", {}).get("fixtureSHA256") == fixture_sha
            and fixture_sha == manifest["fixture"]["sha256"]
            and path.parent == alignment_path.parent
            and artifacts.get("fullReportFile") == alignment_path.name
            and artifacts.get("fullReportSHA256") == sha256(alignment_path)
            and session_path.is_file()
            and sha256(session_path) == artifacts.get("sessionSHA256")
            and session.get("applicationExecutableSHA256") == application.get("sha256")
            and session.get("summary", {}).get("pcmComplete") is True
            and session.get("summary", {}).get("microphoneIncluded") is False
            and session.get("summary", {}).get("capturedApplicationBundleIdentifier")
                == "org.mozilla.firefox"
            and session.get("summary", {}).get("captureTiming", {}).get("gapCount") == 0
            and session.get("summary", {}).get("captureTiming", {}).get("overlapCount") == 0
            and canonical_pcm_path.is_file()
            and sha256(canonical_pcm_path) == session.get("canonicalPCMSHA256")
            and metrics_path.is_file()
            and sha256(metrics_path) == session.get("metricsSHA256")
            and metrics_csv_path.is_file()
            and alignment_provenance.get("firefoxAudio", {}).get("fileName")
                == canonical_pcm_path.name
            and alignment_provenance.get("firefoxAudio", {}).get("sha256")
                == session.get("canonicalPCMSHA256")
            and alignment_provenance.get("session", {}).get("fileName")
                == session_path.name
            and alignment_provenance.get("session", {}).get("sha256")
                == artifacts.get("sessionSHA256")
            and alignment_provenance.get("metrics", {}).get("fileName")
                == metrics_path.name
            and alignment_provenance.get("metrics", {}).get("sha256")
                == session.get("metricsSHA256")
            and declared_artifacts_valid
            and attestation_path.is_file()
            and sha256(attestation_path) == application.get("buildAttestationSHA256")
            and attestation.get("application", {}).get("sha256")
                == application.get("sha256")
            and attestation.get("git") == report.get("git")
            and Path(str(source.get("videoFile") or "missing")).is_file()
            and sha256(Path(source["videoFile"])) == source.get("videoSHA256")
            and Path(str(candidate.get("file") or "missing")).is_file()
            and sha256(Path(candidate["file"])) == candidate.get("sha256")
            and Path(str(firefox.get("executableFile") or "missing")).is_file()
            and sha256(Path(firefox["executableFile"]))
                == firefox.get("executableSHA256")
            and alignment_valid(
                alignment_report,
                corpus,
                manifest_sha,
                fixture_sha,
            )
        )
        valid = valid and source_valid
        anchors = alignment_report.get("alignment", {}).get("anchors", [])
        summaries.append({
            "corpusID": corpus,
            "valid": source_valid,
            "runManifest": {"path": str(path), "sha256": sha256(path)},
            "alignmentReport": {
                "path": str(alignment_path),
                "sha256": sha256(alignment_path),
            },
            "minimumCoarseCorrelation": min(
                (anchor.get("coarseCorrelation", 0) for anchor in anchors),
                default=0,
            ),
            "minimumSampleCorrelation": min(
                (anchor.get("sampleCorrelation", 0) for anchor in anchors),
                default=0,
            ),
            "maximumResidualSamples": alignment_report.get("alignment", {}).get(
                "maximumResidualSamples"
            ),
            "capturePCM": {
                "path": str(canonical_pcm_path),
                "sha256": session.get("canonicalPCMSHA256"),
            },
            "metrics": {"path": str(metrics_path), "sha256": session.get("metricsSHA256")},
            "applicationBuildAttestation": {
                "path": str(attestation_path),
                "sha256": application.get("buildAttestationSHA256"),
            },
            "historicalApplicationBinaryStillMatches": current_application_matches_capture,
        })
    return valid and {item["corpusID"] for item in summaries} == set(CORPORA), summaries


def candidate_row(candidate: str, sessions: list[dict], live: bool = False) -> dict:
    if live:
        complete = sum(live_session_complete(item) for item in sessions)
        maximum_rss = max(
            (item.get("maximumObservedResidentBytes") or 0 for item in sessions),
            default=0,
        )
        latency_scopes = sorted({
            item.get("finalLatencyScope") for item in sessions
            if item.get("finalLatencyScope")
        })
    else:
        complete = sum(native_session_complete(item) for item in sessions)
        maximum_rss = max(
            (item.get("maximumResidentBytes") or 0 for item in sessions),
            default=0,
        )
        latency_scopes = sorted({
            item.get("finalLatencyScope") for item in sessions
            if item.get("finalLatencyScope")
        })
    return {
        "candidate": candidate,
        "sessionCount": len(sessions),
        "completeSessionCount": complete,
        "errorSessionCount": sum(bool(item.get("errors")) for item in sessions),
        "maximumResidentBytes": maximum_rss,
        "finalLatencyScopes": latency_scopes,
    }


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--whispermlx-vad", type=Path, required=True)
    parser.add_argument("--apple", type=Path, required=True)
    parser.add_argument("--simulstreaming", type=Path, required=True)
    parser.add_argument("--localagreement", type=Path, required=True)
    parser.add_argument("--translation-control", type=Path, required=True)
    parser.add_argument(
        "--firefox-run-manifest",
        type=Path,
        action="append",
        required=True,
    )
    parser.add_argument(
        "--firefox-alignment-report",
        type=Path,
        action="append",
        required=True,
    )
    parser.add_argument("--recipes", type=Path, required=True)
    parser.add_argument("--source-provenance", type=Path, required=True)
    parser.add_argument("--runtime-provenance", type=Path, required=True)
    parser.add_argument("--runtime-provenance-final", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    preflight = load(args.preflight)
    native = load(args.native)
    vad = load(args.whispermlx_vad)
    apple = load(args.apple)
    simul = load(args.simulstreaming)
    local = load(args.localagreement)
    control = load(args.translation_control)
    reports = [preflight, native, vad, apple, simul, local, control]
    source = load(args.source_provenance)
    runtime = load(args.runtime_provenance)
    runtime_final = load(args.runtime_provenance_final)
    recipe_sha = sha256(args.recipes)

    preflight_expected = {
        (WHISPERMLX_VAD, window, replay)
        for window in PREFLIGHT_WINDOWS
        for replay in range(1, 4)
    }
    native_expected = {
        (candidate, window, 1) for candidate in NATIVE for window in WINDOWS
    }
    vad_expected = {(WHISPERMLX_VAD, window, 1) for window in WINDOWS}
    live_expected = {(window, 1) for window in WINDOWS}
    preflight_sessions = preflight.get("sessions", [])
    native_sessions = native.get("sessions", [])
    vad_sessions = vad.get("sessions", [])
    apple_sessions = apple.get("sessions", [])
    simul_sessions = simul.get("sessions", [])
    local_sessions = local.get("sessions", [])

    manifests = {
        corpus: load(
            args.source_root / "docs" / "japanese-live" / "corpora" / corpus / "manifest.json"
        )
        for corpus in CORPORA
    }
    firefox_valid, firefox_summaries = firefox_evidence(
        args.firefox_run_manifest,
        args.firefox_alignment_report,
        manifests,
        args.source_root,
    )
    expected_control = {
        (corpus, turn["id"]): (turn["startSample"], turn["endSample"])
        for corpus, manifest in manifests.items()
        for turn in manifest["annotations"]["turns"]
    }
    actual_control = [
        (turn.get("corpusID"), turn.get("turnID")) for turn in control.get("turns", [])
    ]

    commits = {report.get("gitCommit") for report in reports}
    source_shas = {report.get("sourceTreeSHA256") for report in reports}
    runtime_shas = {report.get("runtimeSHA256") for report in reports}
    dirty = {report.get("worktreeDirty") for report in reports}
    recipe_shas = {
        report.get("modelRecipesSHA256")
        for report in [preflight, native, vad, apple, simul, local]
    }
    corpus_reports = [preflight, native, vad, apple, simul, local]
    expected_corpus_signature = tuple(sorted(
        (
            corpus,
            sha256(
                args.source_root
                / "docs" / "japanese-live" / "corpora" / corpus / "manifest.json"
            ),
            manifest["fixture"]["sha256"],
            manifest["annotations"]["status"],
        )
        for corpus, manifest in manifests.items()
    ))
    corpus_consistent = all(
        corpus_signature(report) == expected_corpus_signature
        for report in corpus_reports
    )
    schemas_valid = (
        preflight.get("schemaVersion") == 2
        and native.get("schemaVersion") == 4
        and vad.get("schemaVersion") == 4
        and apple.get("schemaVersion") == 9
        and simul.get("schemaVersion") == 9
        and local.get("schemaVersion") == 9
        and control.get("schemaVersion") == 1
    )
    scopes_valid = (
        preflight.get("benchmarkScope") == "corrective"
        and all(
            report.get("benchmarkScope") == "full-video"
            for report in (native, vad, apple, simul, local)
        )
    )
    report_shapes_valid = (
        preflight.get("sampleRate") == 16_000
        and preflight.get("replayCount") == 3
        and set(preflight.get("expectedRecipeIDs", [])) == {WHISPERMLX_VAD}
        and startups_valid(preflight, 1)
        and native.get("sampleRate") == 16_000
        and native.get("replayCount") == 1
        and set(native.get("expectedRecipeIDs", [])) == NATIVE
        and startups_valid(native, len(NATIVE))
        and vad.get("sampleRate") == 16_000
        and vad.get("replayCount") == 1
        and set(vad.get("expectedRecipeIDs", [])) == {WHISPERMLX_VAD}
        and startups_valid(vad, 1)
        and all(
            report.get("replayCount") == 1 and report.get("blockSamples") == 1_600
            for report in (apple, simul, local)
        )
        and apple.get("effectiveRecipeSHA256") is None
        and all(
            bool(str(report.get("effectiveRecipeSHA256") or "").strip())
            for report in (simul, local)
        )
        and simul.get("effectiveRecipeSHA256") != local.get("effectiveRecipeSHA256")
        and effective_recipes_consistent(preflight_sessions)
        and effective_recipes_consistent(native_sessions)
        and effective_recipes_consistent(vad_sessions)
    )
    wlk_configs_valid = all(
        report.get("benchmarkScope") == "full-video"
        and report.get("whisperLiveKitConfiguration", {}).get("retentionSeconds") == "1200"
        and report.get("whisperLiveKitConfiguration", {}).get("backendPolicy") == policy
        for report, policy in ((simul, "simulstreaming"), (local, "localagreement"))
    )
    measured_processes_network_denied = (
        preflight.get("networkDenied") is True
        and native.get("networkDenied") is True
        and vad.get("networkDenied") is True
        and control.get("networkDenied") is True
        and apple.get("remoteNetworkDeniedForXCTest") is True
        and simul.get("remoteNetworkDeniedForXCTest") is True
        and local.get("remoteNetworkDeniedForXCTest") is True
    )
    attempted = (
        schemas_valid
        and scopes_valid
        and report_shapes_valid
        and exact([native_key(item) for item in preflight_sessions], preflight_expected)
        and exact([native_key(item) for item in native_sessions], native_expected)
        and exact([native_key(item) for item in vad_sessions], vad_expected)
        and exact([live_key(item) for item in apple_sessions], live_expected)
        and exact([live_key(item) for item in simul_sessions], live_expected)
        and exact([live_key(item) for item in local_sessions], live_expected)
        and len(expected_control) == CONTROL_TURN_COUNT
        and exact(actual_control, set(expected_control))
        and preflight.get("matrixAttempted") is True
        and native.get("matrixAttempted") is True
        and vad.get("matrixAttempted") is True
        and simul.get("matrixAttempted") is True
        and local.get("matrixAttempted") is True
        and recipe_shas == {recipe_sha}
        and len(commits) == 1
        and source_shas == {source.get("treeSHA256")}
        and runtime_shas == {runtime.get("runtimeSHA256")}
        and dirty == {False}
        and runtime.get("valid") is True
        and runtime_final == runtime
        and snapshot(args.source_root.resolve())["treeSHA256"] == source.get("treeSHA256")
        and corpus_consistent
        and wlk_configs_valid
        and measured_processes_network_denied
        and firefox_valid
    )

    expected_control_corpora = {
        (
            corpus,
            sha256(
                args.source_root
                / "docs" / "japanese-live" / "corpora" / corpus / "manifest.json"
            ),
            manifest["annotations"]["status"],
            len(manifest["annotations"]["turns"]),
        )
        for corpus, manifest in manifests.items()
    }
    preflight_complete = native_report_complete(
        preflight,
        preflight_sessions,
        require_english=False,
    )
    native_complete = native_report_complete(native, native_sessions)
    vad_complete = native_report_complete(vad, vad_sessions)
    apple_complete = all(apple_session_complete(item) for item in apple_sessions)
    simul_complete = simul.get("matrixComplete") is True and all(
        item.get("source")
            == "whisperlivekit-simulstreaming-mlx-encoder-pytorch-cpu-decoder"
        and live_session_complete(item)
        for item in simul_sessions
    )
    local_complete = local.get("matrixComplete") is True and all(
        item.get("source") == "whisperlivekit-localagreement-mlx"
        and live_session_complete(item)
        for item in local_sessions
    )
    controls_complete = control_complete(
        control,
        expected_control,
        expected_control_corpora,
    )

    grouped: dict[str, list[dict]] = {}
    for session in native_sessions + vad_sessions:
        grouped.setdefault(session["recipeID"], []).append(session)
    rows = [candidate_row(candidate, sessions) for candidate, sessions in grouped.items()]
    rows += [
        candidate_row("whisperlivekit-simulstreaming", simul_sessions, live=True),
        candidate_row("whisperlivekit-localagreement", local_sessions, live=True),
    ]
    rows.sort(key=lambda item: item["candidate"])

    ja_asr = {
        "schemaVersion": 1,
        "sessions": [
            {
                "pipeline": item["recipeID"],
                "corpusID": item["corpusID"],
                "windowID": item["windowID"],
                "fragments": item.get("fragments", []),
                "japaneseFinal": item.get("japaneseFinal", ""),
                "continuousCER": item.get("continuousCER"),
                "lastSpeech": item.get("lastSpeech"),
                "criticalTerms": item.get("criticalTerms"),
                "asrMilliseconds": item.get("asrMilliseconds", []),
                "audioMilliseconds": item.get("audioMilliseconds"),
                "asrWallMilliseconds": item.get("asrWallMilliseconds"),
                "pipelineWallMilliseconds": item.get("pipelineWallMilliseconds"),
                "computeRTF": item.get("computeRTF"),
                "endToEndWallRTF": item.get("endToEndWallRTF"),
                "maximumBacklogMilliseconds": item.get("maximumBacklogMilliseconds"),
                "endingBacklogMilliseconds": item.get("endingBacklogMilliseconds"),
                "maximumResidentBytes": item.get("maximumResidentBytes"),
                "averageCPUPercent": item.get("averageCPUPercent"),
                "thermalStateBefore": item.get("thermalStateBefore"),
                "thermalStateAfter": item.get("thermalStateAfter"),
                "errors": item.get("errors", []),
            }
            for item in native_sessions + vad_sessions
        ] + [
            {
                "pipeline": pipeline,
                "corpusID": item["corpusID"],
                "windowID": item["windowID"],
                "sourceEvents": item.get("sourceEvents", []),
                "japaneseFinal": item.get("japaneseFinal", ""),
                "continuousCER": item.get("japaneseCERDetail"),
                "audioMilliseconds": item.get("audioMilliseconds"),
                "asrWallMilliseconds": item.get("asrWallMilliseconds"),
                "pipelineWallMilliseconds": item.get("pipelineWallMilliseconds"),
                "endToEndWallRTF": item.get("endToEndWallRTF"),
                "maximumBacklogMilliseconds": 1000 * (
                    item.get("maximumProcessingBacklogSeconds") or 0
                ),
                "endingBacklogMilliseconds": 1000 * (
                    item.get("endingProcessingBacklogSeconds") or 0
                ),
                "maximumResidentBytes": item.get("maximumObservedResidentBytes"),
                "averageCPUPercent": item.get("averageCPUPercent"),
                "thermalStateBefore": item.get("thermalStateBefore"),
                "thermalStateAfter": item.get("thermalStateAfter"),
                "errors": item.get("errors", []),
            }
            for pipeline, sessions in (
                ("whisperlivekit-simulstreaming", simul_sessions),
                ("whisperlivekit-localagreement", local_sessions),
            )
            for item in sessions
        ],
    }
    en_preview = {
        "schemaVersion": 1,
        "commonAppleSpeech": apple_sessions,
        "commonAppleSpeechAppliesTo": sorted(
            item for item in NATIVE | {WHISPERMLX_VAD}
            if item not in {
                "voxtral-q4-continuous-960ms",
                "nemotron-multilingual-coreml-1120ms",
                "nemotron-multilingual-coreml-560ms",
            }
        ),
        "candidateNative": [
            {
                "pipeline": item["recipeID"],
                "corpusID": item["corpusID"],
                "latencyScope": item.get("previewLatencyScope"),
                "sourceFirstLatencyMilliseconds": item.get(
                    "previewSourceFirstLatencyMilliseconds", []
                ),
                "firstLatencyMilliseconds": item.get(
                    "previewFirstLatencyMilliseconds", []
                ),
                "revisionCount": item.get("previewRevisionCount"),
                "events": item.get("previewEvents", []),
            }
            for item in native_sessions + vad_sessions
            if item.get("previewEvents")
        ],
        "whisperLiveKit": [
            {
                "pipeline": pipeline,
                "corpusID": item["corpusID"],
                "latencyScope": item.get("previewLatencyScope"),
                "sourceFirstLatencyMilliseconds": item.get(
                    "previewSourceFirstLatencyMilliseconds", []
                ),
                "firstLatencyMilliseconds": item.get(
                    "previewFirstLatencyMilliseconds", []
                ),
                "revisionCount": item.get("previewRevisionCount"),
                "events": item.get("previewEvents", []),
            }
            for pipeline, sessions in (
                ("whisperlivekit-simulstreaming", simul_sessions),
                ("whisperlivekit-localagreement", local_sessions),
            )
            for item in sessions
        ],
    }
    en_final = {
        "schemaVersion": 1,
        "candidateNative": [
            {
                "pipeline": item["recipeID"],
                "corpusID": item["corpusID"],
                "latencyScope": item.get("finalLatencyScope"),
                "events": item.get("finalTranslationEvents", []),
            }
            for item in native_sessions + vad_sessions
        ],
        "whisperLiveKit": [
            {
                "pipeline": pipeline,
                "corpusID": item["corpusID"],
                "latencyScope": item.get("finalLatencyScope"),
                "events": item.get("finalEvents", []),
            }
            for pipeline, sessions in (
                ("whisperlivekit-simulstreaming", simul_sessions),
                ("whisperlivekit-localagreement", local_sessions),
            )
            for item in sessions
        ],
        "humanJapaneseControl": control.get("turns", []),
    }
    candidate_session_count = (
        len(native_sessions) + len(vad_sessions) + len(simul_sessions) + len(local_sessions)
    )
    raw_asr_complete = (
        all(native_asr_complete(item) for item in preflight_sessions)
        and all(native_asr_complete(item) for item in native_sessions + vad_sessions)
        and all(live_asr_complete(item) for item in apple_sessions)
        and all(live_asr_complete(item) for item in simul_sessions + local_sessions)
    )
    apple_evidence_complete = (
        apple_complete
        and all(native_session_complete(item) for item in native_sessions + vad_sessions)
        and all(live_session_complete(item) for item in simul_sessions + local_sessions)
        and controls_complete
    )
    matrix_complete = (
        attempted
        and candidate_session_count == EXPECTED_CANDIDATE_SESSION_COUNT
        and preflight_complete
        and native_complete
        and vad_complete
        and apple_complete
        and simul_complete
        and local_complete
        and controls_complete
        and all(row["completeSessionCount"] == row["sessionCount"] for row in rows)
    )
    comparison = {
        "schemaVersion": 2,
        "lot": "L7C",
        "gitCommit": next(iter(commits)) if len(commits) == 1 else None,
        "modelRecipesSHA256": recipe_sha,
        "sourceTreeSHA256": source.get("treeSHA256"),
        "sourceProvenanceSHA256": sha256(args.source_provenance),
        "runtimeSHA256": runtime.get("runtimeSHA256"),
        "runtimeProvenanceSHA256": sha256(args.runtime_provenance),
        "finalRuntimeProvenanceSHA256": sha256(args.runtime_provenance_final),
        "worktreeClean": dirty == {False},
        "measuredProcessesRemoteNetworkDenied": measured_processes_network_denied,
        "appleSystemServiceOfflineProven": False,
        "physicalOfflineProofDeferredTo": "L10",
        "firefoxSourceEvidenceValidated": firefox_valid,
        "firefoxSourceEvidence": firefox_summaries,
        "replayInput": {
            "source": "manifest-pinned canonical mono PCM at 16 kHz",
            "pace": "1x real time",
            "appliesTo": "all 22 candidate sessions",
            "firefoxEvidenceRole": "source-acquisition attestation only",
        },
        "corporaConsistent": corpus_consistent,
        "matrixAttempted": attempted,
        "matrixComplete": matrix_complete,
        "rawASRComplete": raw_asr_complete,
        "appleEvidenceComplete": apple_evidence_complete,
        "translationControlComplete": controls_complete,
        "preflightComplete": preflight_complete,
        "reportedMatrixComplete": {
            "preflight": preflight.get("matrixComplete"),
            "native": native.get("matrixComplete"),
            "whispermlxVAD": vad.get("matrixComplete"),
            "applePreviewRawOnly": apple.get("matrixComplete"),
            "simulstreaming": simul.get("matrixComplete"),
            "localagreement": local.get("matrixComplete"),
        },
        "preflightSessionCount": len(preflight_sessions),
        "expectedPreflightSessionCount": 12,
        "candidateSessionCount": candidate_session_count,
        "expectedCandidateSessionCount": EXPECTED_CANDIDATE_SESSION_COUNT,
        "applePreviewSessionCount": len(apple_sessions),
        "translationControlTurnCount": len(actual_control),
        "candidates": rows,
        "reports": [
            {"path": str(path), "sha256": sha256(path)}
            for path in (
                args.preflight,
                args.native,
                args.whispermlx_vad,
                args.apple,
                args.simulstreaming,
                args.localagreement,
                args.translation_control,
            )
        ],
    }

    args.output.mkdir(parents=True, exist_ok=True)
    for name, payload in (
        ("ja-asr.json", ja_asr),
        ("en-preview.json", en_preview),
        ("en-final.json", en_final),
        ("comparison.json", comparison),
    ):
        (args.output / name).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    lines = [
        "# L7C — deux vidéos complètes",
        "",
        f"Matrice tentée : **{'oui' if attempted else 'non'}** — "
        f"{comparison['candidateSessionCount']}/{EXPECTED_CANDIDATE_SESSION_COUNT} "
        f"sessions moteur, {len(apple_sessions)}/2 previews Apple et "
        f"{len(actual_control)}/{CONTROL_TURN_COUNT} contrôles.",
        f"Preflight WhisperMLX : **{'valide' if preflight_complete else 'incomplet'}** — "
        f"{len(preflight_sessions)}/12 sessions. Matrice complète : "
        f"**{'oui' if matrix_complete else 'non'}**.",
        f"Source Firefox : **{'validée' if firefox_valid else 'incomplète'}**. "
        "Les 22 sessions rejouent ensuite le PCM canonique aligné à vitesse 1×.",
        "",
        "| Pipeline | Sessions exploitables | Erreurs | Scope final | RSS max |",
        "| --- | ---: | ---: | --- | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| {row['candidate']} | {row['completeSessionCount']}/{row['sessionCount']} | "
            f"{row['errorSessionCount']} | {', '.join(row['finalLatencyScopes'])} | "
            f"{row['maximumResidentBytes'] / 1024**3:.2f} Gio |"
        )
    (args.output / "report-fr.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if not attempted:
        raise SystemExit("L7C matrix or provenance is incomplete")


if __name__ == "__main__":
    main()
