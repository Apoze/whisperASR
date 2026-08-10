#!/usr/bin/env python3
"""Select and audit SpeakerKit's internal clustering threshold."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
import math
import tempfile
from pathlib import Path

from report_exclusive_reconciliation import metrics
from report_high_quality_acceptance import read, sha256
from report_speakerkit_precision import (
    complete_evidence,
    controls_are_valid,
    model_lifecycle,
    translation_unchanged,
    valid_deliverables,
)

THRESHOLDS = (0.45, 0.50, 0.55, 0.60)
DEFAULT_THRESHOLD = 0.60
EXPECTED_FILES = {
    "english-subtitles.srt",
    "english-subtitles.vtt",
    "english-translation-transcript.txt",
    "japanese-transcript.txt",
    "manifest.json",
    "raw-asr.json",
}
EVIDENCE_ROOT = Path("docs/japanese-live/experiments/evidence/E17")
MAX_PRODUCT_MEMORY_BYTES = 16 * 1_024 * 1_024 * 1_024
PSEUDO_SPEAKERS = {
    "qudu2fx3ncc": {
        "SPEAKER_13": "group-reaction/overlap annotation; not one acoustic identity",
    },
}


def threshold_key(value: float) -> str:
    return f"{value:.2f}".replace(".", "p")


def read_gzip(path: Path) -> dict:
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        return json.load(handle)


def gzip_content_sha256(path: Path) -> str | None:
    digest = hashlib.sha256()
    try:
        with gzip.open(path, "rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def setting_only_changes_threshold(settings: dict) -> bool:
    if set(settings) != {threshold_key(value) for value in THRESHOLDS}:
        return False
    normalized = []
    for threshold in THRESHOLDS:
        setting = copy.deepcopy(settings[threshold_key(threshold)])
        observed = setting.pop("clusterDistanceThreshold", None)
        if not math.isclose(observed, threshold, abs_tol=1e-9):
            return False
        normalized.append(setting)
    return all(item == normalized[0] for item in normalized[1:]) and normalized[0] == {
        "precision": "quantized",
        "segmenterVariant": "W8A16",
        "embedderVariant": "W8A16",
        "useExclusiveReconciliation": False,
        "principalAttribution": "longest-overlap-stable-label-span",
        "numberOfSpeakers": None,
        "minActiveOffset": None,
        "minClusterSize": None,
        "fullRedundancy": True,
        "centroidSource": "finalAssignment",
        "clipTimestamps": [],
    }


def frozen_pipeline_matches(baseline: dict, candidate: dict) -> bool:
    return (
        baseline["rawASR"] == candidate["rawASR"]
        and baseline["alignment"]["chunks"] == candidate["alignment"]["chunks"]
        and baseline["alignment"]["mergedCues"]
        == candidate["alignment"]["mergedCues"]
        and baseline["sampleCount"] == candidate["sampleCount"]
        and baseline["sampleRate"] == candidate["sampleRate"]
        and translation_unchanged(baseline["translation"], candidate["translation"])
    )


def execution_sources_match(meta: dict) -> bool:
    hashes = meta.get("executionImplementationSHA256")
    snapshots = meta.get("executionSourceSnapshots")
    if not isinstance(hashes, dict) or not hashes or not isinstance(snapshots, dict):
        return False
    if set(hashes) != set(snapshots):
        return False
    return all(
        Path(snapshots[path]).is_file()
        and sha256(Path(snapshots[path])) == digest
        for path, digest in hashes.items()
    )


def reviewed_sources_match(meta: dict) -> bool:
    hashes = meta.get("reviewedImplementationSHA256")
    return isinstance(hashes, dict) and bool(hashes) and all(
        Path(path).is_file() and sha256(Path(path)) == digest
        for path, digest in hashes.items()
    )


def retained_run_matches(
    meta: dict,
    split: str,
    key: str,
    job: Path,
    manifest: dict,
    raw: dict,
) -> bool:
    artifacts = meta.get("artifactSHA256", {}).get(key, {})
    if set(artifacts) != EXPECTED_FILES:
        return False
    if not all((job / name).is_file() and sha256(job / name) == digest
               for name, digest in artifacts.items()):
        return False
    prefix = EVIDENCE_ROOT / f"{split}-{key}"
    scorer = prefix.with_name(prefix.name + "-scorer-input.json.gz")
    try:
        scorer_input = read_gzip(scorer)
    except (OSError, json.JSONDecodeError):
        return False
    return (
        prefix.with_name(prefix.name + "-raw-asr.json.gz").is_file()
        and prefix.with_name(prefix.name + "-manifest.json").is_file()
        and prefix.with_name(prefix.name + ".log").is_file()
        and gzip_content_sha256(prefix.with_name(prefix.name + "-raw-asr.json.gz"))
        == artifacts["raw-asr.json"]
        and sha256(prefix.with_name(prefix.name + "-manifest.json"))
        == artifacts["manifest.json"]
        and sha256(prefix.with_name(prefix.name + ".log"))
        == meta.get("runLogSHA256", {}).get(key)
        and gzip_content_sha256(scorer)
        == meta.get("scorerInputContentSHA256", {}).get(key)
        and scorer_input.get("corpusManifest") == manifest
        and scorer_input.get("rawEvidence") == raw
        and scorer_input.get("threshold") == meta["settings"][key]["clusterDistanceThreshold"]
        and scorer_input.get("exclusions") == PSEUDO_SPEAKERS.get(meta["corpusID"], {})
        and scorer_input.get("referenceUncertainty")
        == meta["referenceAnnotations"]["uncertainty"]
    )


def common_run_gates(
    root: Path,
    meta: dict,
    split: str,
    key: str,
    manifest: dict,
    baseline: dict,
    candidate: dict,
    job: Path,
) -> dict:
    controls = read(Path(meta["controlEvidencePath"]))
    candidate_manifest = read(job / "manifest.json")
    inventory_path = Path(meta["modelInventoryPath"])
    inventory = read(inventory_path)
    inventory_paths = {item["path"] for item in inventory.get("files", [])}
    threshold = meta["settings"][key]["clusterDistanceThreshold"]
    log = EVIDENCE_ROOT / f"{split}-{key}.log"
    model = candidate.get("diarization") or {}
    return {
        "provenance": (
            sha256(Path(meta["sourcePath"])) == meta["sourceSHA256"]
            and sha256(Path(meta["corpusManifestPath"]))
            == meta["corpusManifestSHA256"]
            and gzip_content_sha256(Path(meta["frozenUpstreamEvidencePath"]))
            == meta["frozenUpstreamEvidenceContentSHA256"]
            and sha256(Path(meta["controlEvidencePath"]))
            == meta["controlEvidenceSHA256"]
            and inventory_path.is_file()
            and sha256(inventory_path) == meta["modelInventorySHA256"]
            and all(any(fragment in path for path in inventory_paths) for fragment in (
                "speaker_segmenter/pyannote-v3/W8A16/",
                "speaker_embedder/pyannote-v3/W8A16/",
                "speaker_clusterer/pyannote-v4/W32A32/",
            ))
            and execution_sources_match(meta)
            and reviewed_sources_match(meta)
            and retained_run_matches(meta, split, key, job, manifest, candidate)
        ),
        "declaredSettingObserved": (
            log.is_file()
            and f"clusterDistanceThreshold={threshold:.2f}" in log.read_text(errors="replace")
        ),
        "frozenASRAlignmentTranslation": frozen_pipeline_matches(baseline, candidate),
        "speakerKitFrozen": (
            model.get("modelID") == meta["speakerKit"]["modelID"]
            and model.get("revision") == meta["speakerKit"]["revision"]
            and model.get("useExclusiveReconciliation") is False
        ),
        "completeDiarizationEvidence": complete_evidence(candidate),
        "validDeliverables": valid_deliverables(candidate_manifest),
        "lifecycleAndMemoryRelease": model_lifecycle(candidate),
        "runtimeAndMemoryMeasured": (
            isinstance(metrics(manifest, candidate, meta["corpusID"])["runtimeSeconds"], (int, float))
            and metrics(manifest, candidate, meta["corpusID"])["runtimeSeconds"] > 0
            and isinstance(model.get("peakMemoryBytes"), int)
            and 0 < model["peakMemoryBytes"] <= MAX_PRODUCT_MEMORY_BYTES
        ),
        "zeroDuplication": metrics(manifest, candidate, meta["corpusID"])["duplicationCount"] == 0,
        "translationAndLiveUnchanged": (
            controls_are_valid(controls)
            and controls["translationTests"]
            and controls["liveTests"]
            and all(
                value["baseSHA256"] == value["candidateSHA256"]
                for value in meta["unchangedImplementations"].values()
            )
        ),
    }


def candidate_vetoes(candidate: dict, baseline: dict) -> dict:
    return {
        "strictSpeakerAttributedJapaneseGain": (
            candidate["speakerAttributedJapaneseError"]["ratePercent"]
            < baseline["speakerAttributedJapaneseError"]["ratePercent"]
        ),
        "noSpokenContentLoss": (
            candidate["speakerAttributedJapaneseError"]["unattributedCharacterCount"]
            <= baseline["speakerAttributedJapaneseError"]["unattributedCharacterCount"]
        ),
        "DERDoesNotRegress": candidate["DERPercent"] <= baseline["DERPercent"],
        "JERDoesNotRegress": candidate["JERPercent"] <= baseline["JERPercent"],
        "speakerCountErrorDoesNotRegress": (
            candidate["speakerCountAbsoluteError"] <= baseline["speakerCountAbsoluteError"]
        ),
    }


def selection_key(item: dict) -> tuple:
    value = item["metrics"]
    return (
        value["speakerAttributedJapaneseError"]["ratePercent"],
        value["JERPercent"],
        value["DERPercent"],
        value["speakerCountAbsoluteError"],
        item["threshold"],
    )


def development_report(root: Path) -> dict:
    corpus = "qudu2fx3ncc"
    directory = root / corpus
    meta = read(directory / "run-meta.json")
    manifest = read(Path(meta["corpusManifestPath"]))
    raws = {
        key: read(directory / "jobs" / job / "raw-asr.json")
        for key, job in meta["jobs"].items()
    }
    baseline_key = threshold_key(DEFAULT_THRESHOLD)
    baseline = raws[baseline_key]
    frozen = read_gzip(Path(meta["frozenUpstreamEvidencePath"]))
    rows = []
    for threshold in THRESHOLDS:
        key = threshold_key(threshold)
        job = directory / "jobs" / meta["jobs"][key]
        value = metrics(manifest, raws[key], corpus)
        common = common_run_gates(root, meta, "development", key, manifest, frozen, raws[key], job)
        vetoes = candidate_vetoes(value, metrics(manifest, baseline, corpus))
        rows.append({
            "threshold": threshold,
            "metrics": value,
            "gates": common,
            "vetoesVersusDefault": vetoes,
            "eligibleCandidate": threshold != DEFAULT_THRESHOLD
            and all(common.values()) and all(vetoes.values()),
            "rawArtifacts": {
                "rawASR": str(EVIDENCE_ROOT / f"development-{key}-raw-asr.json.gz"),
                "manifest": str(EVIDENCE_ROOT / f"development-{key}-manifest.json"),
                "log": str(EVIDENCE_ROOT / f"development-{key}.log"),
                "scorerInput": str(EVIDENCE_ROOT / f"development-{key}-scorer-input.json.gz"),
            },
        })
    eligible = [row for row in rows if row["eligibleCandidate"]]
    selected = min(eligible, key=selection_key) if eligible else None
    infrastructure = setting_only_changes_threshold(meta["settings"]) and all(
        all(row["gates"].values()) for row in rows
    )
    return {
        "corpusID": corpus,
        "role": "development",
        "referenceAnnotations": meta["referenceAnnotations"],
        "oneVariable": setting_only_changes_threshold(meta["settings"]),
        "allRunsValid": infrastructure,
        "rows": rows,
        "selectedThreshold": selected["threshold"] if selected else DEFAULT_THRESHOLD,
        "developmentPromotionEligible": infrastructure and selected is not None,
    }


def holdout_report(root: Path, development: dict, development_report_path: Path) -> dict | None:
    corpus = "md62mmdz0m"
    directory = root / corpus
    if not (directory / "run-meta.json").is_file():
        return None
    meta = read(directory / "run-meta.json")
    threshold = meta["selectedThreshold"]
    key = threshold_key(threshold)
    manifest = read(Path(meta["corpusManifestPath"]))
    baseline = read_gzip(Path(meta["baselineEvidencePath"]))
    job = directory / "jobs" / meta["jobID"]
    candidate = read(job / "raw-asr.json")
    baseline_metrics = metrics(manifest, baseline, corpus)
    candidate_metrics = metrics(manifest, candidate, corpus)
    gates = common_run_gates(
        root, meta, "holdout", key, manifest, baseline, candidate, job
    )
    gates.update(candidate_vetoes(candidate_metrics, baseline_metrics))
    gates["developmentSelectionFrozen"] = (
        development["developmentPromotionEligible"]
        and math.isclose(threshold, development["selectedThreshold"], abs_tol=1e-9)
        and sha256(development_report_path) == meta["developmentReportSHA256"]
    )
    return {
        "corpusID": corpus,
        "role": "untouched-holdout",
        "referenceAnnotations": meta["referenceAnnotations"],
        "baselineThreshold": DEFAULT_THRESHOLD,
        "baseline": baseline_metrics,
        "selectedThreshold": threshold,
        "candidate": candidate_metrics,
        "gates": gates,
        "eligible": all(gates.values()),
        "rawArtifacts": {
            "baseline": meta["baselineEvidencePath"],
            "candidate": str(EVIDENCE_ROOT / f"holdout-{key}-raw-asr.json.gz"),
            "manifest": str(EVIDENCE_ROOT / f"holdout-{key}-manifest.json"),
            "log": str(EVIDENCE_ROOT / f"holdout-{key}.log"),
            "scorerInput": str(EVIDENCE_ROOT / f"holdout-{key}-scorer-input.json.gz"),
        },
    }


def markdown(report: dict) -> str:
    lines = [
        "# E17 — SpeakerKit clustering threshold",
        "",
        "Only `clusterDistanceThreshold` changes across 0.45, 0.50, 0.55 and 0.60. "
        "SpeakerKit W8A16/W8A16, Auto speaker count, non-exclusive reconciliation, "
        "principal attribution, ASR, alignment, glossary and translation remain frozen.",
        "",
        "| Corpus | Threshold | DER | JER | Speaker JA error | Count error | Dup. | "
        "Overlap P/R/F1 | Runtime | Peak memory |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    development = report["development"]
    for row in development["rows"]:
        value = row["metrics"]
        overlap = value["overlap"]
        lines.append(
            f'| qudu2fx3ncc (development) | {row["threshold"]:.2f} | '
            f'{value["DERPercent"]:.2f}% | {value["JERPercent"]:.2f}% | '
            f'{value["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | '
            f'{value["speakerCountAbsoluteError"]} | {value["duplicationCount"]} | '
            f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/'
            f'{overlap["f1Percent"]:.1f}% | {value["runtimeSeconds"]:.2f}s | '
            f'{value["peakMemoryBytes"] / 1_048_576:.0f} MiB |'
        )
    holdout = report.get("holdout")
    if holdout:
        for label, threshold, value in (
            ("default", DEFAULT_THRESHOLD, holdout["baseline"]),
            ("selected", holdout["selectedThreshold"], holdout["candidate"]),
        ):
            overlap = value["overlap"]
            lines.append(
                f'| md62mmdz0m (holdout {label}) | {threshold:.2f} | '
                f'{value["DERPercent"]:.2f}% | {value["JERPercent"]:.2f}% | '
                f'{value["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | '
                f'{value["speakerCountAbsoluteError"]} | {value["duplicationCount"]} | '
                f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/'
                f'{overlap["f1Percent"]:.1f}% | {value["runtimeSeconds"]:.2f}s | '
                f'{value["peakMemoryBytes"] / 1_048_576:.0f} MiB |'
            )
    else:
        lines += ["", "Untouched holdout: not run."]
    lines += [
        "",
        f'**Decision:** {report["decision"]}.' ,
        "",
        "Selection is lexicographic on speaker-attributed Japanese error, JER, DER, "
        "speaker-count error and threshold, after strict gain and every veto gate. "
        "Reference pseudo-speakers, uncertainty, exact scorer inputs, raw spans, mappings, "
        "settings, manifests and logs are retained under "
        "`docs/japanese-live/experiments/evidence/E17/`.",
        "",
    ]
    return "\n".join(lines)


def build_report(root: Path, development_report_path: Path | None) -> dict:
    development = development_report(root)
    holdout = None
    if development_report_path:
        frozen = read(development_report_path)
        if frozen.get("development") != development:
            raise SystemExit("Frozen development report no longer matches retained DEV evidence.")
        holdout = holdout_report(root, development, development_report_path)
    if not development["developmentPromotionEligible"]:
        decision = "do not promote; no non-default threshold passed every development gate"
    elif holdout is None:
        decision = (
            f'development selected {development["selectedThreshold"]:.2f}; '
            "holdout remains closed"
        )
    elif holdout["eligible"]:
        decision = f'promote internal threshold {development["selectedThreshold"]:.2f}'
    else:
        decision = "do not promote; untouched holdout did not confirm every gate"
    return {
        "schemaVersion": 1,
        "experiment": "E17-speakerkit-clustering-threshold",
        "primaryMetric": "speaker-attributed Japanese error rate",
        "selectionRule": [
            "strict speaker-attributed Japanese gain versus 0.60",
            "no spoken-content, DER, JER, speaker-count, duplication or integrity veto",
            "lexicographic speaker JA error, JER, DER, count error, threshold",
        ],
        "development": development,
        "holdout": holdout,
        "holdoutRun": holdout is not None,
        "promote": holdout is not None and holdout["eligible"],
        "decision": decision,
        "limitedEvidence": "two supplied videos; no universal domain-quality claim",
    }


def make_scorer_input(args: argparse.Namespace) -> None:
    manifest = read(args.manifest)
    raw = read(args.raw)
    result = {
        "schemaVersion": 1,
        "corpusID": args.corpus,
        "threshold": args.threshold,
        "exclusions": PSEUDO_SPEAKERS.get(args.corpus, {}),
        "referenceUncertainty": args.reference_uncertainty,
        "corpusManifest": manifest,
        "rawEvidence": raw,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as handle:
            handle.write((json.dumps(result, ensure_ascii=False, sort_keys=True) + "\n").encode())


def self_test() -> None:
    base = {
        "precision": "quantized", "segmenterVariant": "W8A16",
        "embedderVariant": "W8A16", "useExclusiveReconciliation": False,
        "principalAttribution": "longest-overlap-stable-label-span",
        "numberOfSpeakers": None, "minActiveOffset": None,
        "minClusterSize": None, "fullRedundancy": True,
        "centroidSource": "finalAssignment", "clipTimestamps": [],
    }
    settings = {
        threshold_key(value): {**base, "clusterDistanceThreshold": value}
        for value in THRESHOLDS
    }
    assert setting_only_changes_threshold(settings)
    settings["0p45"]["minClusterSize"] = 1
    assert not setting_only_changes_threshold(settings)
    example = lambda threshold, error, jer: {
        "threshold": threshold,
        "metrics": {"speakerAttributedJapaneseError": {"ratePercent": error},
                    "JERPercent": jer, "DERPercent": 50,
                    "speakerCountAbsoluteError": 1},
    }
    assert min([example(.45, 40, 30), example(.50, 40, 29)], key=selection_key)["threshold"] == .50
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "value.json.gz"
        with path.open("wb") as output:
            with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as handle:
                handle.write(b'{}\n')
        assert read_gzip(path) == {}
        assert gzip_content_sha256(path) == hashlib.sha256(b'{}\n').hexdigest()


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
    parser.add_argument("--threshold", type=float)
    parser.add_argument("--reference-uncertainty")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.make_scorer_input:
        if not all((args.manifest, args.raw, args.output, args.corpus,
                    args.threshold is not None, args.reference_uncertainty)):
            parser.error("scorer input requires manifest, raw, output, corpus, threshold and uncertainty")
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
