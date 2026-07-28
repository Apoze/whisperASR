#!/usr/bin/env python3
"""Prepare and validate an attested Firefox → Voxtral product replay."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from source_tree_provenance import snapshot  # noqa: E402


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_sha256(path: Path) -> str:
    if path.is_file():
        return sha256(path)
    if not path.is_dir():
        raise SystemExit(f"missing model artifact: {path}")
    digest = hashlib.sha256()
    files = sorted(
        item for item in path.rglob("*")
        if item.is_file()
        and all(not part.startswith(".") for part in item.relative_to(path).parts)
    )
    for item in files:
        digest.update(item.relative_to(path).as_posix().encode())
        digest.update(b"\0")
        with item.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        digest.update(b"\xff")
    return digest.hexdigest()


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def command(*arguments: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()


def voxtral_recipe(root: Path) -> tuple[Path, dict, dict]:
    path = root / "docs/japanese-live/model-recipes.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    recipe = next(
        item for item in document["recipes"] if item["id"] == "voxtral-q4-960"
    )
    return path, document["common"], recipe


def verified_voxtral_model(recipe: dict) -> tuple[Path, str]:
    directory = (
        Path.home()
        / "Library/Application Support/WhisperASR/Runtime/Models"
        / f"voxtral-{recipe['model']['revision']}"
    )
    observed = artifact_sha256(directory)
    if observed != recipe["model"]["sha256"]:
        raise SystemExit("installed Voxtral model tree differs from the pinned recipe")
    return directory, observed


def prepare(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    run = args.run.resolve()
    video = args.video.resolve()
    app = root / "WhisperASR.app"
    firefox = Path("/Applications/Firefox.app")
    if subprocess.run(
        ["pgrep", "-x", "WhisperASR"],
        check=False,
        capture_output=True,
    ).returncode == 0:
        raise SystemExit("quit WhisperASR before preparing the attested build")
    run.mkdir(parents=True, exist_ok=True)
    source_before_build = snapshot(root)
    environment = os.environ.copy()
    environment.setdefault(
        "DEVELOPER_DIR",
        "/Applications/Xcode.app/Contents/Developer",
    )
    build = subprocess.run(
        [str(root / "Scripts/build_release.sh")],
        cwd=root,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    build_log = run / "release-build.log"
    build_log.write_text(build.stdout, encoding="utf-8")
    if build.returncode:
        raise SystemExit(f"Release build failed; see {build_log}")

    manifest_path = root / "docs/japanese-live/corpora" / args.corpus / "manifest.json"
    app_binary = app / "Contents/MacOS/WhisperASR"
    firefox_binary = firefox / "Contents/MacOS/firefox"
    for path in (video, manifest_path, app_binary, firefox_binary):
        if not path.is_file():
            raise SystemExit(f"missing required file: {path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_video_sha = next(
        item["sha256"]
        for item in manifest["source"]["references"]
        if item["label"] == "source-video"
    )
    if sha256(video) != expected_video_sha:
        raise SystemExit("video SHA-256 differs from the corpus manifest")

    source = snapshot(root)
    if source["treeSHA256"] != source_before_build["treeSHA256"]:
        raise SystemExit("repository sources changed during the Release build")
    source_path = run / "source-provenance.json"
    write_json(source_path, source)
    recipe_path, common, recipe = voxtral_recipe(root)
    model_directory, model_sha = verified_voxtral_model(recipe)
    with (firefox / "Contents/Info.plist").open("rb") as handle:
        firefox_info = plistlib.load(handle)
    fixture_samples = int(manifest["fixture"]["sampleCount"])
    sample_rate = int(common["sampleRate"])
    dirty = bool(command("git", "status", "--porcelain", cwd=root))
    report = {
        "schemaVersion": 1,
        "status": "prepared",
        "preparedAt": datetime.now(UTC).isoformat(),
        "git": {
            "commit": command("git", "rev-parse", "HEAD", cwd=root),
            "dirty": dirty,
            "sourceTreeSHA256": source["treeSHA256"],
            "sourceProvenanceSHA256": sha256(source_path),
        },
        "corpus": {
            "id": args.corpus,
            "manifestFile": str(manifest_path),
            "manifestSHA256": sha256(manifest_path),
            "annotationStatus": manifest["annotations"]["status"],
            "fixtureSampleCount": fixture_samples,
            "fixtureDurationSeconds": fixture_samples / sample_rate,
        },
        "source": {"videoFile": str(video), "videoSHA256": expected_video_sha},
        "application": {
            "bundle": str(app),
            "executableSHA256": sha256(app_binary),
            "buildCommand": "Scripts/build_release.sh",
            "buildLogSHA256": sha256(build_log),
            "sourceTreeSHA256": source["treeSHA256"],
        },
        "recipe": {
            "id": recipe["id"],
            "file": str(recipe_path),
            "sha256": sha256(recipe_path),
            "modelDirectory": str(model_directory),
            "modelArtifactSHA256": model_sha,
        },
        "captureApplication": {
            "bundleID": "org.mozilla.firefox",
            "bundle": str(firefox),
            "version": firefox_info["CFBundleShortVersionString"],
            "executableSHA256": sha256(firefox_binary),
        },
        "configuration": {
            "pipeline": "voxtralApple",
            "sourceLocale": "ja",
            "translationMode": "adaptive",
            "voxtral": "q4-960",
            "playbackRate": 1,
            "microphone": False,
            "uiDriver": "Computer Use",
        },
    }
    write_json(run / "run-manifest.json", report)
    print(run)


def require(condition: bool, message: str, checks: list[str]) -> None:
    if not condition:
        raise SystemExit(f"validation failed: {message}")
    checks.append(message)


def validate(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    run = args.run.resolve()
    manifest = json.loads((run / "run-manifest.json").read_text(encoding="utf-8"))
    checks: list[str] = []
    recorded_source = json.loads(
        (run / "source-provenance.json").read_text(encoding="utf-8")
    )
    current_source = snapshot(root)
    build_prefixes = ("Assets/", "Frameworks/", "Sources/", "Vendor/")
    build_files = {"Package.swift", "Package.resolved"}
    relevant = lambda item: (  # noqa: E731
        item["path"].startswith(build_prefixes) or item["path"] in build_files
    )
    require(
        [item for item in current_source["files"] if relevant(item)]
        == [item for item in recorded_source["files"] if relevant(item)],
        "application build inputs match the captured source provenance",
        checks,
    )
    require(
        sha256(run / "source-provenance.json")
        == manifest["git"]["sourceProvenanceSHA256"],
        "source provenance SHA-256 verified",
        checks,
    )
    require(
        sha256(Path(manifest["source"]["videoFile"])) == manifest["source"]["videoSHA256"],
        "source video SHA-256 verified",
        checks,
    )
    app_binary = Path(manifest["application"]["bundle"]) / "Contents/MacOS/WhisperASR"
    require(
        sha256(app_binary) == manifest["application"]["executableSHA256"],
        "Release executable SHA-256 verified",
        checks,
    )
    require(
        sha256(run / "release-build.log")
        == manifest["application"]["buildLogSHA256"]
        and manifest["application"]["sourceTreeSHA256"]
        == manifest["git"]["sourceTreeSHA256"],
        "Release build is linked to the attested source tree",
        checks,
    )
    firefox_binary = (
        Path(manifest["captureApplication"]["bundle"])
        / "Contents/MacOS/firefox"
    )
    require(
        sha256(firefox_binary)
        == manifest["captureApplication"]["executableSHA256"],
        "Firefox executable SHA-256 verified",
        checks,
    )
    runtime_provenance = json.loads(
        (run / "runtime-provenance.json").read_text(encoding="utf-8")
    )
    require(runtime_provenance["valid"], "runtime provenance is clean", checks)
    ui_proof = json.loads((run / "ui-proof.json").read_text(encoding="utf-8"))
    configuration = manifest["configuration"]
    expected_ui = {
        "driver": configuration["uiDriver"],
        "videoAtStart": True,
        "videoPausedAtStart": True,
        "playbackRate": configuration["playbackRate"],
        "firefoxSelected": True,
        "pipeline": configuration["pipeline"],
        "sourceLocale": configuration["sourceLocale"],
        "voxtral": configuration["voxtral"],
        "videoEnded": True,
    }
    require(
        all(ui_proof.get(key) == value for key, value in expected_ui.items()),
        "Computer Use reviewed the 1× Firefox start state",
        checks,
    )
    for name, key in (
        ("before-record.png", "beforeRecordSHA256"),
        ("firefox-at-start.png", "firefoxAtStartSHA256"),
        ("after-finish.png", "afterFinishSHA256"),
    ):
        require(
            sha256(run / name) == ui_proof[key],
            f"{name} UI proof SHA-256 verified",
            checks,
        )

    sessions = list(run.glob("*-session.json"))
    require(len(sessions) == 1, "exactly one benchmark session report", checks)
    session_path = sessions[0]
    report = json.loads(session_path.read_text(encoding="utf-8"))
    summary = report["summary"]
    recipe_path, common, recipe = voxtral_recipe(root)
    execution = recipe["execution"]
    sample_rate = int(common["sampleRate"])
    rotation_samples = execution["rotationTargetSeconds"] * sample_rate
    post_roll_samples = int(common["productEndpoint"]["postRollSamples"])
    require(
        sha256(recipe_path) == manifest["recipe"]["sha256"],
        "Voxtral recipe SHA-256 verified",
        checks,
    )
    require(
        report["applicationExecutableSHA256"]
        == manifest["application"]["executableSHA256"],
        "session used the attested Release executable",
        checks,
    )
    require(
        report["voxtralModelID"] == recipe["model"]["id"],
        "pinned Voxtral model ID",
        checks,
    )
    require(
        report["voxtralModelRevision"] == recipe["model"]["revision"],
        "pinned Voxtral model revision",
        checks,
    )
    require(
        report["voxtralRuntimePatchSHA256"] == recipe["runtime"]["patchSHA256"],
        "pinned Voxtral runtime patch",
        checks,
    )
    require(
        report["voxtralDelayMilliseconds"]
        == execution["transcriptionDelayMilliseconds"],
        "Voxtral delay matches the recipe",
        checks,
    )
    require(
        report["transportBlockMilliseconds"]
        == execution["transportBlockMilliseconds"],
        "transport block matches the recipe",
        checks,
    )
    require(summary["engine"] == "voxtralApple", "Voxtral → Apple pipeline selected", checks)
    require(summary["translationMode"] == "adaptive", "adaptive Apple mode selected", checks)
    require(
        summary["capturedApplicationBundleIdentifier"] == "org.mozilla.firefox",
        "ScreenCaptureKit captured Firefox",
        checks,
    )
    require(not summary["microphoneIncluded"], "microphone excluded", checks)
    require(summary["pcmComplete"], "ScreenCaptureKit PCM complete", checks)
    timing = summary["captureTiming"]
    require(
        timing["gapCount"] == timing["overlapCount"]
        == timing["invalidPresentationTimestampCount"] == 0,
        "capture timestamps have no gaps, overlaps, or invalid values",
        checks,
    )
    require(summary.get("sourcePipelineFailure") is None, "no source failure", checks)
    require(summary.get("completionFailure") is None, "no completion failure", checks)
    require(summary["endingEndpointFIFOCount"] == 0, "endpoint FIFO drained", checks)
    require(summary["endingTranslationQueueCount"] == 0, "translation queue drained", checks)
    require(not summary["finalTranslationInFlight"], "no final translation in flight", checks)
    final_samples = int(summary["finalSampleCount"])
    fixture_samples = int(manifest["corpus"]["fixtureSampleCount"])
    require(
        fixture_samples - sample_rate
        <= final_samples
        <= fixture_samples + 30 * sample_rate,
        "captured duration is compatible with complete 1× playback",
        checks,
    )
    require(
        summary["helperSentThrough"] == summary["helperAcknowledgedThrough"]
        == final_samples,
        "final helper cursors cover all PCM",
        checks,
    )
    require(summary["endingHelperBacklogSamples"] == 0, "final helper backlog is zero", checks)
    product_cursors = {
        summary["sourceStagedThrough"],
        summary["englishValidatedThrough"],
        summary["committedSampleCount"],
        summary["sourceFinalizedThrough"],
    }
    require(
        len(product_cursors) == 1,
        "source, English, commit, and final cursors agree",
        checks,
    )
    corpus_manifest_path = Path(manifest["corpus"]["manifestFile"])
    require(
        sha256(corpus_manifest_path) == manifest["corpus"]["manifestSHA256"],
        "corpus manifest SHA-256 verified",
        checks,
    )
    corpus_manifest = json.loads(corpus_manifest_path.read_text(encoding="utf-8"))
    last_reference_end = int(corpus_manifest["annotations"]["turns"][-1]["endSample"])
    require(
        last_reference_end
        <= summary["sourceFinalizedThrough"]
        <= final_samples,
        "product final cursor includes the last annotated speech",
        checks,
    )
    require(
        report["maximumCombinedResidentBytes"] < 10 * 1024**3,
        "combined RSS stays below 10 GiB",
        checks,
    )
    require(sha256(run / report["metricsFile"]) == report["metricsSHA256"], "metrics SHA-256 verified", checks)
    require(
        sha256(run / report["canonicalPCMFile"]) == report["canonicalPCMSHA256"],
        "canonical PCM SHA-256 verified",
        checks,
    )
    pcm_stream = json.loads(command(
        "ffprobe",
        "-v", "error",
        "-show_entries", "stream=codec_name,sample_rate,channels,duration_ts",
        "-of", "json",
        str(run / report["canonicalPCMFile"]),
    ))["streams"][0]
    require(
        pcm_stream["codec_name"] == "pcm_f32le"
        and int(pcm_stream["sample_rate"]) == sample_rate
        and pcm_stream["channels"] == 1
        and int(pcm_stream["duration_ts"]) == final_samples,
        "canonical WAV is mono 16 kHz float PCM with exact frame count",
        checks,
    )

    voxtral_sessions = report["voxtralSessions"]
    require(len(voxtral_sessions) >= 2, "at least one product rotation occurred", checks)
    helper_pids = {item["helperProcessIdentifier"] for item in voxtral_sessions}
    require(len(helper_pids) == 1 and None not in helper_pids, "one helper PID for every session", checks)
    cursor = 0
    for index, item in enumerate(voxtral_sessions):
        require(item["startSample"] == cursor, f"session {index} starts contiguously", checks)
        require(item["endSample"] > item["startSample"], f"session {index} is non-empty", checks)
        require(
            item["acknowledgedThroughSample"] == item["endSample"]
            and item["endingBacklogSamples"] == 0,
            f"session {index} ends fully acknowledged",
            checks,
        )
        require(item["transcriptCharacterCount"] > 0, f"session {index} contains speech text", checks)
        if index < len(voxtral_sessions) - 1:
            require(not item["captureEnded"], f"session {index} is a rotation", checks)
            require(
                item["targetSample"] == item["startSample"] + rotation_samples
                and item["endSample"] >= item["targetSample"],
                f"session {index} rotates at or after 720 seconds",
                checks,
            )
            require(
                item["lastSpeechEndSample"] is not None
                and item["endSample"] - item["lastSpeechEndSample"]
                >= post_roll_samples,
                f"session {index} closes after safe VAD post-roll",
                checks,
            )
        cursor = item["endSample"]
    last = voxtral_sessions[-1]
    require(last["captureEnded"], "last session is the capture Finish", checks)
    require(last.get("targetSample") is None, "last session is not marked as a rotation", checks)
    require(cursor == final_samples, "session ranges cover every captured PCM sample", checks)

    result = {
        "schemaVersion": 1,
        "status": "passed",
        "validatedAt": datetime.now(UTC).isoformat(),
        "sessionReport": session_path.name,
        "checks": checks,
        "inputSHA256": {
            path.name: sha256(path)
            for path in (
                run / "run-manifest.json",
                run / "source-provenance.json",
                run / "runtime-provenance.json",
                run / "release-build.log",
                run / "ui-proof.json",
                run / "before-record.png",
                run / "firefox-at-start.png",
                run / "after-finish.png",
                run / "firefox-at-end.png",
                session_path,
                run / report["metricsFile"],
                run / report["canonicalPCMFile"],
            )
        },
    }
    write_json(run / "validation.json", result)
    print(run / "validation.json")


def attest_evaluation(args: argparse.Namespace) -> None:
    root = args.root.resolve()
    run = args.run.resolve()
    validation_path = run / "validation.json"
    validation = json.loads(validation_path.read_text(encoding="utf-8"))
    if validation["status"] != "passed":
        raise SystemExit("the product validation did not pass")
    for name, expected in validation["inputSHA256"].items():
        if sha256(run / name) != expected:
            raise SystemExit(f"validated input changed: {name}")

    reports = list(run.glob("*-evaluation-full.json"))
    if len(reports) != 1:
        raise SystemExit("expected exactly one full evaluation report")
    evaluation = json.loads(reports[0].read_text(encoding="utf-8"))
    oracle = root / "Tests/JapaneseOfflineEvaluationTests.swift"
    manifest = json.loads((run / "run-manifest.json").read_text(encoding="utf-8"))
    session_name = validation["sessionReport"]
    session_identity = evaluation["provenance"]["session"]
    oracle_identity = evaluation["provenance"]["oracle"]
    if (
        evaluation["corpusID"] != manifest["corpus"]["id"]
        or session_identity["fileName"] != session_name
        or session_identity["sha256"] != validation["inputSHA256"][session_name]
        or oracle_identity["fileName"] != oracle.name
        or oracle_identity["sha256"] != sha256(oracle)
    ):
        raise SystemExit("evaluation report does not belong to the validated session and oracle")
    recipe_path, _, recipe = voxtral_recipe(root)
    if (
        manifest["recipe"]["id"] != recipe["id"]
        or sha256(recipe_path) != manifest["recipe"]["sha256"]
    ):
        raise SystemExit("run recipe differs from the current pinned recipe")
    model_directory, model_sha = verified_voxtral_model(recipe)
    expected_model_sha = manifest["recipe"].get(
        "modelArtifactSHA256",
        recipe["model"]["sha256"],
    )
    if model_sha != expected_model_sha:
        raise SystemExit("attested model tree differs from the run recipe")

    result = {
        "schemaVersion": 1,
        "status": "passed",
        "attestedAt": datetime.now(UTC).isoformat(),
        "productValidation": {
            "file": validation_path.name,
            "sha256": sha256(validation_path),
        },
        "evaluation": {
            "file": reports[0].name,
            "sha256": sha256(reports[0]),
        },
        "oracle": {
            "file": str(oracle.relative_to(root)),
            "sha256": sha256(oracle),
        },
        "voxtralModel": {
            "directory": str(model_directory),
            "sha256": model_sha,
        },
    }
    write_json(run / "evaluation-attestation.json", result)
    print(run / "evaluation-attestation.json")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--root", type=Path, required=True)
    prepare_parser.add_argument("--run", type=Path, required=True)
    prepare_parser.add_argument("--corpus", required=True)
    prepare_parser.add_argument("--video", type=Path, required=True)
    prepare_parser.set_defaults(function=prepare)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--root", type=Path, required=True)
    validate_parser.add_argument("--run", type=Path, required=True)
    validate_parser.set_defaults(function=validate)

    attest_parser = subparsers.add_parser("attest-evaluation")
    attest_parser.add_argument("--root", type=Path, required=True)
    attest_parser.add_argument("--run", type=Path, required=True)
    attest_parser.set_defaults(function=attest_evaluation)
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
