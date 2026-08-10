#!/usr/bin/env python3
"""Audit the frozen SpeakerKit versus FluidAudio Offline experiment."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
import tempfile
from pathlib import Path

from report_exclusive_reconciliation import gzip_content_sha256, metrics
from report_high_quality_acceptance import read, sha256
from report_speakerkit_precision import (
    complete_evidence,
    controls_are_valid,
    translation_unchanged,
    valid_deliverables,
)

ENGINES = ("speakerkit", "fluid-audio-offline")
MODEL_IDS = {
    "speakerkit": "argmaxinc/speakerkit-coreml",
    "fluid-audio-offline": "FluidInference/speaker-diarization-coreml/offline",
}
MODEL_REVISIONS = {
    "speakerkit": "86ec9c929b52208b6656eb6a6361ed0d822a1f78",
    "fluid-audio-offline": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
}
EXPECTED_FILES = {
    "english-subtitles.srt",
    "english-subtitles.vtt",
    "english-translation-transcript.txt",
    "japanese-transcript.txt",
    "manifest.json",
    "raw-asr.json",
}
EVIDENCE_ROOT = Path("docs/japanese-live/experiments/evidence/E18")
MAX_MEMORY_BYTES = 16 * 1_024 * 1_024 * 1_024
PSEUDO_SPEAKERS = {
    "qudu2fx3ncc": {
        "SPEAKER_13": "group-reaction/overlap annotation; not one acoustic identity",
    },
}


def read_gzip(path: Path) -> dict:
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def one_variable(meta: dict) -> bool:
    settings = meta.get("settings", {})
    if set(settings) != set(ENGINES):
        return False
    baseline = copy.deepcopy(settings["speakerkit"])
    candidate = copy.deepcopy(settings["fluid-audio-offline"])
    baseline_engine = baseline.pop("engine", None)
    candidate_engine = candidate.pop("engine", None)
    baseline_model = baseline.pop("engineConfiguration", None)
    candidate_model = candidate.pop("engineConfiguration", None)
    return (
        baseline_engine == "speakerkit"
        and candidate_engine == "fluid-audio-offline"
        and baseline_model == {
            "precision": "quantized",
            "segmenterVariant": "W8A16",
            "embedderVariant": "W8A16",
            "clusterDistanceThreshold": 0.60,
        }
        and candidate_model == {
            "pipeline": "offline-vbx-community",
            "clusteringThreshold": 0.60,
            "exclusiveSegments": False,
            "computeUnits": "all",
            "fbankComputeUnits": "cpuOnly",
        }
        and baseline == candidate == {
            "speakerCount": "automatic",
            "useExclusiveReconciliation": False,
            "completeDiarizationAttribution": True,
            "principalAttribution": "longest-overlap-then-nearest-span-stable-label",
            "frozenUpstream": True,
        }
    )


def frozen_pipeline_matches(frozen: dict, observed: dict) -> bool:
    return (
        frozen.get("rawASR") == observed.get("rawASR")
        and frozen.get("alignment", {}).get("chunks")
        == observed.get("alignment", {}).get("chunks")
        and frozen.get("alignment", {}).get("mergedCues")
        == observed.get("alignment", {}).get("mergedCues")
        and frozen.get("sampleCount") == observed.get("sampleCount")
        and frozen.get("sampleRate") == observed.get("sampleRate")
        and translation_unchanged(frozen.get("translation"), observed.get("translation"))
    )


def model_lifecycle(raw: dict, model_id: str) -> bool:
    events = [
        event.get("kind") for event in raw.get("modelEvents", [])
        if event.get("modelID") == model_id
    ]
    return (
        "load-started" in events
        and "load-completed" in events
        and "unload-completed" in events
        and "memory-release-checked" in events
        and "guard-failed" not in events
    )


def execution_sources_match(meta: dict) -> bool:
    hashes = meta.get("executionImplementationSHA256", {})
    snapshots = meta.get("executionSourceSnapshots", {})
    reviewed = meta.get("reviewedImplementationSHA256", {})
    return (
        isinstance(hashes, dict)
        and bool(hashes)
        and hashes == reviewed
        and set(hashes) == set(snapshots)
        and all(
            Path(snapshots[path]).is_file()
            and sha256(Path(snapshots[path])) == digest
            for path, digest in hashes.items()
        )
    )


def inventory_valid(meta: dict, engine: str) -> bool:
    info = meta.get("modelInventories", {}).get(engine, {})
    path = Path(info.get("path", ""))
    if not path.is_file() or sha256(path) != info.get("sha256"):
        return False
    inventory = read(path)
    files = inventory.get("files", [])
    return (
        bool(files)
        and any(item.get("size", 0) > 0 for item in files)
        and all(
            item.get("size", -1) >= 0 and len(item.get("sha256", "")) == 64
            for item in files
        )
    )


def retained_artifacts_match(meta: dict, split: str, engine: str, job: Path) -> bool:
    hashes = meta.get("artifactSHA256", {}).get(engine, {})
    prefix = EVIDENCE_ROOT / f"{split}-{engine}"
    scorer = prefix.with_name(prefix.name + "-scorer-input.json.gz")
    try:
        scorer_input = read_gzip(scorer)
    except (OSError, json.JSONDecodeError):
        return False
    return (
        set(hashes) == EXPECTED_FILES
        and all(
            (job / name).is_file() and sha256(job / name) == digest
            for name, digest in hashes.items()
        )
        and prefix.with_name(prefix.name + "-raw-asr.json.gz").is_file()
        and prefix.with_name(prefix.name + "-manifest.json").is_file()
        and prefix.with_name(prefix.name + ".log").is_file()
        and gzip_content_sha256(prefix.with_name(prefix.name + "-raw-asr.json.gz"))
        == hashes["raw-asr.json"]
        and sha256(prefix.with_name(prefix.name + "-manifest.json"))
        == hashes["manifest.json"]
        and sha256(prefix.with_name(prefix.name + ".log"))
        == meta.get("runLogSHA256", {}).get(engine)
        and gzip_content_sha256(scorer)
        == meta.get("scorerInputContentSHA256", {}).get(engine)
        and scorer_input.get("engine") == engine
        and scorer_input.get("corpusID") == meta.get("corpusID")
        and scorer_input.get("rawEvidence") == read(job / "raw-asr.json")
        and scorer_input.get("exclusions")
        == PSEUDO_SPEAKERS.get(meta.get("corpusID"), {})
    )


def cancellation_evidence_valid(meta: dict) -> bool:
    info = meta.get("fluidAudioCancellationEvidence", {})
    manifest_path = Path(info.get("manifestPath", ""))
    raw_path = Path(info.get("rawASRPath", ""))
    log_path = Path(info.get("logPath", ""))
    try:
        manifest = read(manifest_path)
        raw = read_gzip(raw_path)
        log = log_path.read_text(encoding="utf-8")
    except (OSError, json.JSONDecodeError):
        return False
    return (
        sha256(manifest_path) == info.get("manifestSHA256")
        and gzip_content_sha256(raw_path) == info.get("rawASRContentSHA256")
        and sha256(log_path) == info.get("logSHA256")
        and manifest.get("jobID") == info.get("jobID")
        and manifest.get("status") == "cancelled"
        and bool(manifest.get("failures"))
        and manifest["failures"][-1].get("stage") == "cancelled"
        and bool(raw.get("failures"))
        and raw["failures"][-1].get("stage") == "cancelled"
        and model_lifecycle(raw, MODEL_IDS["fluid-audio-offline"])
        and "[fluid-audio-cancellation] retained=true" in log
    )


def observed_configuration(engine: str, model: dict) -> bool:
    config = model.get("configuration") or {}
    shared = (
        config.get("speakerCount") == "automatic"
        and model.get("speakerCountPolicy")
        == {"mode": "automatic"}
        and model.get("useExclusiveReconciliation") is False
    )
    if engine == "speakerkit":
        return shared and config == {
            "engine": "speakerkit-pyannote",
            "runtimeRevision": "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d",
            "segmenterVariant": "W8A16",
            "embedderVariant": "W8A16",
            "clusterDistanceThreshold": "0.6",
            "speakerCount": "automatic",
            "exclusiveReconciliation": "false",
        }
    return shared and config == {
        "engine": "fluid-audio-offline-vbx",
        "runtimeRevision": "19600a485baa4998812e4654b70d2bab8f2c9949",
        "computeUnits": "all",
        "fbankComputeUnits": "cpuOnly",
        "clusteringThreshold": "0.6",
        "speakerCount": "automatic",
        "exclusiveSegments": "false",
        "embeddingExcludeOverlap": "true",
        "segmentationStepRatio": "0.2",
        "embeddingBatchSize": "32",
    }


def common_gates(
    meta: dict,
    split: str,
    engine: str,
    manifest: dict,
    frozen: dict,
    raw: dict,
    job: Path,
) -> dict:
    controls = read(Path(meta["controlEvidencePath"]))
    job_manifest = read(job / "manifest.json")
    model = raw.get("diarization") or {}
    value = metrics(manifest, raw, meta["corpusID"])
    remote = meta.get("fluidAudioRemoteRevision", {})
    development_frozen = split != "holdout" or (
        Path(meta.get("developmentReportPath", "")).is_file()
        and sha256(Path(meta["developmentReportPath"]))
        == meta.get("developmentReportSHA256")
    )
    mapping_count = sum(
        len(chunk.get("rawItems", [])) for chunk in raw["alignment"]["chunks"]
    )
    mapping_indices = [
        item.get("alignmentItemIndex") for item in model.get("mappings", [])
    ]
    return {
        "provenance": (
            sha256(Path(meta["sourcePath"])) == meta["sourceSHA256"]
            and sha256(Path(meta["corpusManifestPath"]))
            == meta["corpusManifestSHA256"]
            and gzip_content_sha256(Path(meta["frozenUpstreamEvidencePath"]))
            == meta["frozenUpstreamEvidenceContentSHA256"]
            and sha256(Path(meta["controlEvidencePath"]))
            == meta["controlEvidenceSHA256"]
            and execution_sources_match(meta)
            and inventory_valid(meta, engine)
            and retained_artifacts_match(meta, split, engine, job)
            and development_frozen
        ),
        "oneVariable": one_variable(meta),
        "frozenASRAlignmentTranslation": frozen_pipeline_matches(frozen, raw),
        "modelIdentityRevisionConfiguration": (
            model.get("modelID") == MODEL_IDS[engine]
            and model.get("revision") == MODEL_REVISIONS[engine]
            and observed_configuration(engine, model)
            and (
                engine != "fluid-audio-offline"
                or remote.get("before") == MODEL_REVISIONS[engine]
                and remote.get("after") == MODEL_REVISIONS[engine]
            )
        ),
        "completeDiarizationEvidence": complete_evidence(raw),
        "stablePrincipalAttribution": (
            len(model.get("mappings", [])) == mapping_count
            and all(isinstance(index, int) for index in mapping_indices)
            and sorted(mapping_indices) == list(range(mapping_count))
            and {
                item.get("attributionReason") for item in model.get("mappings", [])
            } <= {"longest-overlap", "nearest-span-fallback"}
        ),
        "fluidAudioCancellationFailClosed": cancellation_evidence_valid(meta),
        "validDeliverables": valid_deliverables(job_manifest),
        "renameConsistency": meta.get("renameConsistency", {}).get(engine) is True,
        "lifecycleAndMemoryRelease": model_lifecycle(raw, MODEL_IDS[engine]),
        "runtimeAndMemoryMeasured": (
            isinstance(value.get("runtimeSeconds"), (int, float))
            and value["runtimeSeconds"] > 0
            and isinstance(model.get("peakMemoryBytes"), int)
            and 0 < model["peakMemoryBytes"] <= MAX_MEMORY_BYTES
        ),
        "zeroDuplication": value.get("duplicationCount") == 0,
        "translationAndLiveUnchanged": (
            controls_are_valid(controls)
            and controls.get("translationTests") is True
            and controls.get("liveTests") is True
            and all(
                item["baseSHA256"] == item["candidateSHA256"]
                for item in meta.get("unchangedImplementations", {}).values()
            )
        ),
    }


def quality_gates(baseline: dict, candidate: dict) -> dict:
    return {
        "strictSpeakerAttributedJapaneseGain": (
            candidate["speakerAttributedJapaneseError"]["ratePercent"]
            < baseline["speakerAttributedJapaneseError"]["ratePercent"]
        ),
        "noUnattributedContentRegression": (
            candidate["speakerAttributedJapaneseError"]["unattributedCharacterCount"]
            <= baseline["speakerAttributedJapaneseError"]["unattributedCharacterCount"]
        ),
        "DERDoesNotRegress": candidate["DERPercent"] <= baseline["DERPercent"],
        "JERDoesNotRegress": candidate["JERPercent"] <= baseline["JERPercent"],
        "speakerCountErrorDoesNotRegress": (
            candidate["speakerCountAbsoluteError"]
            <= baseline["speakerCountAbsoluteError"]
        ),
    }


def split_report(root: Path, corpus: str, split: str) -> dict:
    directory = root / corpus
    meta = read(directory / "run-meta.json")
    manifest = read(Path(meta["corpusManifestPath"]))
    frozen = read_gzip(Path(meta["frozenUpstreamEvidencePath"]))
    raws = {
        engine: read(directory / "jobs" / meta["jobs"][engine] / "raw-asr.json")
        for engine in ENGINES
    }
    values = {engine: metrics(manifest, raws[engine], corpus) for engine in ENGINES}
    gates = {
        engine: common_gates(
            meta,
            split,
            engine,
            manifest,
            frozen,
            raws[engine],
            directory / "jobs" / meta["jobs"][engine],
        )
        for engine in ENGINES
    }
    quality = quality_gates(values["speakerkit"], values["fluid-audio-offline"])
    return {
        "corpusID": corpus,
        "role": meta["corpusRole"],
        "referenceAnnotations": meta["referenceAnnotations"],
        "metrics": values,
        "gates": gates,
        "candidateQualityGates": quality,
        "candidateEligible": (
            all(all(items.values()) for items in gates.values())
            and all(quality.values())
        ),
        "rawArtifacts": {
            engine: {
                "rawASR": str(EVIDENCE_ROOT / f"{split}-{engine}-raw-asr.json.gz"),
                "manifest": str(EVIDENCE_ROOT / f"{split}-{engine}-manifest.json"),
                "log": str(EVIDENCE_ROOT / f"{split}-{engine}.log"),
                "scorerInput": str(EVIDENCE_ROOT / f"{split}-{engine}-scorer-input.json.gz"),
            }
            for engine in ENGINES
        },
    }


def build_report(root: Path, development_report_path: Path | None) -> dict:
    development = split_report(root, "qudu2fx3ncc", "development")
    holdout = None
    if development_report_path:
        frozen = read(development_report_path)
        if frozen.get("development") != development:
            raise SystemExit("Frozen development report no longer matches retained DEV evidence.")
        holdout = split_report(root, "md62mmdz0m", "holdout")
        holdout["developmentDecisionFrozen"] = sha256(development_report_path)
    if not development["candidateEligible"]:
        decision = "keep SpeakerKit; FluidAudio did not pass development"
    elif holdout is None:
        decision = "FluidAudio passed development; untouched holdout remains closed"
    elif holdout["candidateEligible"]:
        decision = "promote FluidAudio Offline for high-quality batch diarization"
    else:
        decision = "keep SpeakerKit; FluidAudio gain did not hold on untouched holdout"
    return {
        "schemaVersion": 1,
        "experiment": "E18-fluid-audio-offline",
        "primaryMetric": "speaker-attributed Japanese error rate",
        "development": development,
        "holdout": holdout,
        "holdoutRun": holdout is not None,
        "promote": holdout is not None and holdout["candidateEligible"],
        "decision": decision,
        "limitedEvidence": "two supplied videos; no universal domain-quality claim",
    }


def markdown(report: dict) -> str:
    lines = [
        "# E18 — SpeakerKit versus FluidAudio Offline",
        "",
        "Frozen Qwen JA ASR, alignment, translation, speaker-count policy, raw-overlap "
        "and complete deterministic principal-attribution rules; only the native "
        "diarization engine changes. Complete attribution is experiment-only and "
        "remains disabled in the product.",
        "",
        "| Split | Engine | DER | JER | Speaker JA error | Count error | Dup. | "
        "Overlap P/R/F1 | Runtime | Peak memory |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for split in ("development", "holdout"):
        section = report.get(split)
        if not section:
            continue
        for engine in ENGINES:
            value = section["metrics"][engine]
            overlap = value["overlap"]
            lines.append(
                f'| {split} | {engine} | {value["DERPercent"]:.2f}% | '
                f'{value["JERPercent"]:.2f}% | '
                f'{value["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | '
                f'{value["speakerCountAbsoluteError"]} | {value["duplicationCount"]} | '
                f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/'
                f'{overlap["f1Percent"]:.1f}% | {value["runtimeSeconds"]:.2f}s | '
                f'{value["peakMemoryBytes"] / 1_048_576:.0f} MiB |'
            )
    if report.get("holdout") is None:
        lines += ["", "Untouched holdout: not run."]
    lines += [
        "",
        f'**Decision:** {report["decision"]}.' ,
        "",
        "Raw evidence, exact scorer inputs, source snapshots, model inventories, "
        "remote revision checks, logs and failure diagnostics are retained under "
        "`docs/japanese-live/experiments/evidence/E18/`.",
        "",
    ]
    return "\n".join(lines)


def make_scorer_input(args: argparse.Namespace) -> None:
    payload = {
        "schemaVersion": 1,
        "corpusID": args.corpus,
        "engine": args.engine,
        "exclusions": PSEUDO_SPEAKERS.get(args.corpus, {}),
        "referenceUncertainty": args.reference_uncertainty,
        "corpusManifest": read(args.manifest),
        "rawEvidence": read(args.raw),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as handle:
            handle.write((json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n").encode())


def self_test() -> None:
    shared = {
        "speakerCount": "automatic",
        "useExclusiveReconciliation": False,
        "completeDiarizationAttribution": True,
        "principalAttribution": "longest-overlap-then-nearest-span-stable-label",
        "frozenUpstream": True,
    }
    meta = {
        "settings": {
            "speakerkit": {
                **shared,
                "engine": "speakerkit",
                "engineConfiguration": {
                    "precision": "quantized", "segmenterVariant": "W8A16",
                    "embedderVariant": "W8A16", "clusterDistanceThreshold": .60,
                },
            },
            "fluid-audio-offline": {
                **shared,
                "engine": "fluid-audio-offline",
                "engineConfiguration": {
                    "pipeline": "offline-vbx-community", "clusteringThreshold": .60,
                    "exclusiveSegments": False, "computeUnits": "all",
                    "fbankComputeUnits": "cpuOnly",
                },
            },
        }
    }
    assert one_variable(meta)
    meta["settings"]["fluid-audio-offline"]["speakerCount"] = "expected"
    assert not one_variable(meta)
    baseline = {
        "speakerAttributedJapaneseError": {
            "ratePercent": 20.0, "unattributedCharacterCount": 2,
        },
        "DERPercent": 30.0, "JERPercent": 25.0, "speakerCountAbsoluteError": 1,
    }
    candidate = copy.deepcopy(baseline)
    candidate["speakerAttributedJapaneseError"]["ratePercent"] = 19.0
    assert all(quality_gates(baseline, candidate).values())
    candidate["JERPercent"] = 26.0
    assert not all(quality_gates(baseline, candidate).values())
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        path = root / "raw.json.gz"
        with path.open("wb") as output:
            with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as handle:
                handle.write(b'{}\n')
        assert read_gzip(path) == {}
        assert gzip_content_sha256(path) == hashlib.sha256(b'{}\n').hexdigest()

        job_id = "61000001-0000-4000-8000-000000000003"
        manifest_path = root / "manifest.json"
        cancellation_raw = root / "cancelled-raw.json.gz"
        log_path = root / "cancelled.log"
        manifest_path.write_text(json.dumps({
            "jobID": job_id,
            "status": "cancelled",
            "failures": [{"stage": "cancelled"}],
        }))
        raw = {
            "failures": [{"stage": "cancelled"}],
            "modelEvents": [
                {"modelID": MODEL_IDS["fluid-audio-offline"], "kind": kind}
                for kind in (
                    "load-started", "load-completed", "unload-completed",
                    "memory-release-checked",
                )
            ],
        }
        with cancellation_raw.open("wb") as output:
            with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as handle:
                handle.write(json.dumps(raw).encode())
        log_path.write_text("[fluid-audio-cancellation] retained=true\n")
        cancellation_meta = {"fluidAudioCancellationEvidence": {
            "jobID": job_id,
            "manifestPath": str(manifest_path),
            "manifestSHA256": sha256(manifest_path),
            "rawASRPath": str(cancellation_raw),
            "rawASRContentSHA256": gzip_content_sha256(cancellation_raw),
            "logPath": str(log_path),
            "logSHA256": sha256(log_path),
        }}
        assert cancellation_evidence_valid(cancellation_meta)
        cancellation_meta["fluidAudioCancellationEvidence"]["logSHA256"] = "0" * 64
        assert not cancellation_evidence_valid(cancellation_meta)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--development-report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--make-scorer-input", action="store_true")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--corpus")
    parser.add_argument("--engine", choices=ENGINES)
    parser.add_argument("--reference-uncertainty")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.make_scorer_input:
        if not all((args.manifest, args.raw, args.output, args.corpus,
                    args.engine, args.reference_uncertainty)):
            parser.error("scorer input requires manifest, raw, output, corpus, engine and uncertainty")
        make_scorer_input(args)
        return
    if not all((args.root, args.json, args.markdown)):
        parser.error("report requires root, --json and --markdown")
    report = build_report(args.root, args.development_report)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    args.markdown.write_text(markdown(report), encoding="utf-8")


if __name__ == "__main__":
    main()
