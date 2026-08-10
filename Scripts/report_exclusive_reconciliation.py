#!/usr/bin/env python3
"""Compare frozen principal-Speaker evidence with exclusive SpeakerKit output."""

from __future__ import annotations

import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

from report_high_quality_acceptance import (
    diarization_metrics,
    merge_spans,
    overlap_duration,
    read,
    sha256,
)

CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
PSEUDO_SPEAKERS = {
    "qudu2fx3ncc": {
        "SPEAKER_13": "group-reaction/overlap annotation; not one acoustic identity",
    },
}


def stage_duration(raw: dict, stage: str) -> float | None:
    values = raw.get("stageDurations", {})
    if isinstance(values, dict):
        return values.get(stage)
    return dict(zip(values[::2], values[1::2])).get(stage)


def filtered_manifest(manifest: dict, corpus: str) -> dict:
    result = copy.deepcopy(manifest)
    excluded = set(PSEUDO_SPEAKERS.get(corpus, {}))
    result["annotations"]["turns"] = [
        turn for turn in result["annotations"]["turns"]
        if turn["speaker"] not in excluded
    ]
    return result


def explicit_overlap_metrics(manifest: dict, raw: dict) -> dict:
    sample_rate = manifest["fixture"]["sampleRate"]
    reference = merge_spans([
        (turn["startSample"] / sample_rate, turn["endSample"] / sample_rate)
        for turn in manifest["annotations"]["turns"] if turn.get("overlap")
    ])
    candidate = merge_spans([
        (span["start"], span["end"])
        for span in raw["diarization"]["overlapRanges"]
    ])
    reference_seconds = sum(end - start for start, end in reference)
    candidate_seconds = sum(end - start for start, end in candidate)
    matched_seconds = overlap_duration(reference, candidate)
    precision = matched_seconds / candidate_seconds if candidate_seconds else 0.0
    recall = matched_seconds / reference_seconds if reference_seconds else 1.0
    return {
        "precisionPercent": 100 * precision,
        "recallPercent": 100 * recall,
        "f1Percent": 100 * 2 * precision * recall / (precision + recall)
        if precision + recall else 0.0,
        "referenceSeconds": reference_seconds,
        "candidateSeconds": candidate_seconds,
        "matchedSeconds": matched_seconds,
        "missedSeconds": max(0.0, reference_seconds - matched_seconds),
        "falseAlarmSeconds": max(0.0, candidate_seconds - matched_seconds),
    }


def activity_false_alarm_seconds(manifest: dict, raw: dict) -> float:
    sample_rate = manifest["fixture"]["sampleRate"]
    reference = merge_spans([
        (turn["startSample"] / sample_rate, turn["endSample"] / sample_rate)
        for turn in manifest["annotations"]["turns"]
    ])
    candidate = merge_spans([
        (span["start"], span["end"])
        for span in raw["diarization"]["rawSpans"]
    ])
    candidate_seconds = sum(end - start for start, end in candidate)
    return max(0.0, candidate_seconds - overlap_duration(reference, candidate))


def cross_speaker_overlap_seconds(raw: dict) -> float:
    spans = raw["diarization"]["rawSpans"]
    boundaries = sorted({value for span in spans for value in (span["start"], span["end"])})
    total = 0.0
    for start, end in zip(boundaries, boundaries[1:]):
        active = {
            span["speakerID"] for span in spans
            if span["start"] < end and start < span["end"]
        }
        if len(active) > 1:
            total += end - start
    return total


def translation_is_structured(raw: dict) -> bool:
    request = raw["translation"]["request"]["turns"]
    response = json.loads(raw["translation"]["response"])["translations"]
    expected = [turn["id"] for turn in request]
    observed = [turn["id"] for turn in response]
    return observed == expected and len(observed) == len(set(observed))


def metrics(manifest: dict, raw: dict, corpus: str) -> dict:
    acoustic_manifest = filtered_manifest(manifest, corpus)
    result = diarization_metrics(acoustic_manifest, raw)
    result["overlap"] = explicit_overlap_metrics(manifest, raw)
    result["activityFalseAlarmSeconds"] = activity_false_alarm_seconds(
        acoustic_manifest, raw
    )
    result["crossSpeakerOverlapSeconds"] = cross_speaker_overlap_seconds(raw)
    result["runtimeSeconds"] = stage_duration(raw, "diarizing")
    result["preparationSeconds"] = stage_duration(raw, "preparing-diarization")
    result["peakMemoryBytes"] = raw["diarization"]["peakMemoryBytes"]
    return result


def one_variable(meta: dict) -> bool:
    baseline = copy.deepcopy(meta["settings"]["baseline"])
    candidate = copy.deepcopy(meta["settings"]["candidate"])
    before = baseline.pop("useExclusiveReconciliation", None)
    after = candidate.pop("useExclusiveReconciliation", None)
    return before is False and after is True and baseline == candidate


def implementation_matches(meta: dict) -> bool:
    hashes = meta.get("implementationSHA256")
    return isinstance(hashes, dict) and bool(hashes) and all(
        Path(path).is_file() and sha256(Path(path)) == expected
        for path, expected in hashes.items()
    )


def gzip_content_sha256(path: Path) -> str | None:
    digest = hashlib.sha256()
    try:
        with gzip.open(path, "rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def corpus_report(root: Path, corpus: str) -> dict:
    directory = root / corpus
    meta = read(directory / "run-meta.json")
    manifest_path = Path(meta["corpusManifestPath"])
    baseline_path = Path(meta["baselineEvidencePath"])
    runtime_path = Path(meta["baselineRuntimeEvidencePath"])
    runtime_snapshot_path = Path(meta["baselineRuntimeSnapshotPath"])
    candidate_job = directory / "jobs" / meta["candidateJobID"]
    candidate_path = candidate_job / "raw-asr.json"
    baseline = read(baseline_path)
    candidate = read(candidate_path)
    runtime = read(runtime_path)
    manifest = read(manifest_path)
    baseline_metrics = metrics(manifest, baseline, corpus)
    baseline_metrics["runtimeSeconds"] = stage_duration(runtime, "diarizing")
    baseline_metrics["preparationSeconds"] = stage_duration(
        runtime, "preparing-diarization"
    )
    baseline_metrics["peakMemoryBytes"] = runtime["diarization"]["peakMemoryBytes"]
    candidate_metrics = metrics(manifest, candidate, corpus)
    baseline_japanese = "".join(
        cue["text"] for cue in baseline["alignment"]["mergedCues"]
    )
    candidate_japanese = "".join(
        turn["japanese"] for turn in candidate["translation"]["request"]["turns"]
    )
    controls = read(root / "controls.json")
    artifact_hashes = meta.get("candidateArtifactSHA256", {})
    gates = {
        "provenance": (
            sha256(manifest_path) == meta["corpusManifestSHA256"]
            and sha256(baseline_path) == meta["baselineEvidenceSHA256"]
            and sha256(runtime_path) == meta["baselineRuntimeEvidenceSHA256"]
            and gzip_content_sha256(runtime_snapshot_path)
            == meta["baselineRuntimeEvidenceSHA256"]
            and sha256(Path(meta["sourcePath"])) == meta["sourceSHA256"]
            and sha256(candidate_path) == artifact_hashes.get("raw-asr.json")
            and sha256(candidate_job / "manifest.json")
            == artifact_hashes.get("manifest.json")
            and implementation_matches(meta)
        ),
        "frozenASRAlignment": (
            baseline["rawASR"] == candidate["rawASR"]
            and baseline["alignment"]["chunks"] == candidate["alignment"]["chunks"]
            and baseline["alignment"]["mergedCues"]
            == candidate["alignment"]["mergedCues"]
            and baseline["sampleCount"] == candidate["sampleCount"]
            and baseline["sampleRate"] == candidate["sampleRate"]
        ),
        "oneVariable": one_variable(meta),
        "sameSpeakerKit": (
            baseline["diarization"]["modelID"]
            == candidate["diarization"]["modelID"]
            and baseline["diarization"]["revision"]
            == candidate["diarization"]["revision"]
        ),
        "exclusiveEvidence": candidate["diarization"].get(
            "useExclusiveReconciliation"
        ) is True,
        "oneActivePrincipalPerFrame": (
            candidate_metrics["crossSpeakerOverlapSeconds"] < 1e-9
            and not candidate["diarization"]["overlapRanges"]
        ),
        "rawEvidence": (
            bool(baseline["diarization"]["rawSpans"])
            and bool(candidate["diarization"]["rawSpans"])
            and "mappings" in baseline["diarization"]
            and "mappings" in candidate["diarization"]
        ),
        "pseudoSpeakersDeclared": set(PSEUDO_SPEAKERS.get(corpus, {}))
        == set(meta["referenceAnnotations"]["pseudoSpeakers"]),
        "zeroDuplication": candidate_metrics["duplicationCount"] == 0,
        "japanesePreserved": baseline_japanese == candidate_japanese,
        "translationStructured": translation_is_structured(candidate),
        "deterministicControls": all(controls.values()),
        "translationAndLiveUnchanged": (
            controls["translationTests"]
            and controls["liveTests"]
            and all(
                item["baseSHA256"] == item["candidateSHA256"]
                for item in meta["unchangedImplementations"].values()
            )
        ),
    }
    baseline_error = baseline_metrics["speakerAttributedJapaneseError"]["ratePercent"]
    candidate_error = candidate_metrics["speakerAttributedJapaneseError"]["ratePercent"]
    gates["principalSpeakerGain"] = candidate_error < baseline_error
    return {
        "corpusID": corpus,
        "role": meta["corpusRole"],
        "pseudoSpeakers": meta["referenceAnnotations"]["pseudoSpeakers"],
        "baseline": baseline_metrics,
        "exclusive": candidate_metrics,
        "gates": gates,
        "eligible": all(gates.values()),
        "rawArtifacts": {
            "baseline": str(baseline_path),
            "baselineRuntime": str(runtime_path),
            "baselineRuntimeSnapshot": str(runtime_snapshot_path),
            "candidate": str(candidate_path),
            "runMetadata": str(directory / "run-meta.json"),
        },
    }


def markdown(report: dict) -> str:
    def portable(path: str) -> str:
        marker = "/.build/"
        return ".build/" + path.split(marker, 1)[1] if marker in path else path

    lines = [
        "# E15 — Exclusive SpeakerKit reconciliation",
        "",
        "One variable changes: `useExclusiveReconciliation=false` becomes `true`. "
        "ASR, alignment, SpeakerKit revision, clustering settings and principal-Speaker "
        "mapping stay fixed.",
        "",
        "`SPEAKER_13` in the development reference is declared as group reactions/overlap, "
        "not as one acoustic identity. Overlap scores still use all explicit overlap annotations.",
        "",
        "| Corpus | Mode | DER | JER | Speaker JA error | Count error | Dup. | "
        "Overlap P/R/F1 | Overlap FA | Activity FA | Runtime | Peak memory |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in report["rows"]:
        for label, key in (("non-exclusive", "baseline"), ("exclusive", "exclusive")):
            value = row[key]
            overlap = value["overlap"]
            lines.append(
                f'| {row["corpusID"]} ({row["role"]}) | {label} | '
                f'{value["DERPercent"]:.2f}% | {value["JERPercent"]:.2f}% | '
                f'{value["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | '
                f'{value["speakerCountAbsoluteError"]} | {value["duplicationCount"]} | '
                f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/'
                f'{overlap["f1Percent"]:.1f}% | '
                f'{overlap["falseAlarmSeconds"]:.2f}s | '
                f'{value["activityFalseAlarmSeconds"]:.2f}s | '
                f'{value["runtimeSeconds"]:.2f}s | '
                f'{value["peakMemoryBytes"] / 1_048_576:.0f} MiB |'
            )
    if not report["holdoutRun"]:
        lines += ["", "Untouched holdout: not run."]
    lines += [
        "",
        f'**Decision:** {report["decision"]}.',
        "",
        "Raw evidence:",
        "",
        "Lossless raw snapshots, pinned settings and runner logs are checked in under "
        "`docs/japanese-live/experiments/evidence/E15/`.",
        "",
    ]
    for row in report["rows"]:
        lines.append(
            f'- `{row["corpusID"]}` baseline '
            f'`{portable(row["rawArtifacts"]["baseline"])}`; candidate '
            f'`{portable(row["rawArtifacts"]["candidate"])}`; baseline runtime snapshot '
            f'`{row["rawArtifacts"]["baselineRuntimeSnapshot"]}`.'
        )
    return "\n".join(lines) + "\n"


def self_test() -> None:
    raw = {
        "stageDurations": ["diarizing", 2.5],
        "diarization": {
            "rawSpans": [
                {"speakerID": 0, "start": 0.0, "end": 1.0},
                {"speakerID": 1, "start": 1.0, "end": 2.0},
            ],
            "overlapRanges": [],
        },
    }
    manifest = {
        "fixture": {"sampleRate": 10},
        "annotations": {"turns": [
            {"speaker": "A", "startSample": 0, "endSample": 10},
            {"speaker": "GROUP", "startSample": 10, "endSample": 20,
             "overlap": True},
        ]},
    }
    assert stage_duration(raw, "diarizing") == 2.5
    assert cross_speaker_overlap_seconds(raw) == 0
    assert explicit_overlap_metrics(manifest, raw)["recallPercent"] == 0
    assert one_variable({"settings": {
        "baseline": {"threshold": None, "useExclusiveReconciliation": False},
        "candidate": {"threshold": None, "useExclusiveReconciliation": True},
    }})
    script = Path(__file__)
    assert implementation_matches({
        "implementationSHA256": {str(script): sha256(script)},
    })
    assert not implementation_matches({"implementationSHA256": {}})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    assert args.root and args.json and args.markdown
    rows = [
        corpus_report(args.root, corpus)
        for corpus in CORPORA if (args.root / corpus / "run-meta.json").exists()
    ]
    development = next(row for row in rows if row["role"] == "development")
    holdout = next((row for row in rows if row["role"] == "untouched-holdout"), None)
    development_eligible = development["eligible"]
    if not development_eligible:
        decision = "do not promote; development gates or principal-Speaker gain failed"
    elif holdout is None:
        decision = "development candidate eligible; holdout remains untouched"
    elif holdout["eligible"]:
        decision = "promote exclusive reconciliation"
    else:
        decision = "do not promote; untouched holdout did not confirm all gates"
    report = {
        "schemaVersion": 1,
        "experiment": "E15-exclusive-reconciliation",
        "primaryMetric": "speaker-attributed Japanese error rate",
        "developmentPromotionEligible": development_eligible,
        "holdoutRun": holdout is not None,
        "promote": holdout is not None and holdout["eligible"],
        "decision": decision,
        "rows": rows,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    args.markdown.write_text(markdown(report), encoding="utf-8")


if __name__ == "__main__":
    main()
