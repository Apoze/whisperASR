#!/usr/bin/env python3
"""Score ticket #62 from the frozen #44 baseline and the real combined candidate."""

from __future__ import annotations

import argparse
import collections
import json
import re
from datetime import datetime
from pathlib import Path

from report_high_quality_acceptance import (
    cer,
    cue_integrity,
    diarization_metrics,
    glossary_accuracy,
    sha256,
    structured_cues_are_valid,
    translation_rows,
)
from report_japanese_l7d import chrf_pp
from report_local_translator_bakeoff import comet_scores, write_lines


CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
HOLDOUT = "md62mmdz0m"
MODEL_IDS = (
    "ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit",
    "mlx-community/Qwen3-ForcedAligner-0.6B-4bit",
    "argmaxinc/speakerkit-coreml",
    "mlx-community/translategemma-12b-it-4bit",
)
MODEL_REVISIONS = {
    MODEL_IDS[0]: "7c70d18cb650655d32eafb952a74a49c6a3caad0",
    MODEL_IDS[1]: "2f652af86ae0c73fe189b9429225c908ce4bf020",
    MODEL_IDS[2]: "86ec9c929b52208b6656eb6a6361ed0d822a1f78",
    MODEL_IDS[3]: "f3dcfd54df14672fbcf0731086fb47a797a943ae",
}
MODEL_WEIGHT_SHA256 = {
    (MODEL_IDS[0], "model.safetensors"):
        "bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954",
    (MODEL_IDS[1], "model.safetensors"):
        "630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c",
    (MODEL_IDS[2], "segmenter/W8A16/weight.bin"):
        "75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4",
    (MODEL_IDS[2], "embedder/W8A16/weight.bin"):
        "a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795",
    (MODEL_IDS[2], "embedder-preprocessor/W8A16/weight.bin"):
        "5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89",
    (MODEL_IDS[2], "clusterer/W32A32/weight.bin"):
        "a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced",
    (MODEL_IDS[3], "model-00001-of-00002.safetensors"):
        "bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af",
    (MODEL_IDS[3], "model-00002-of-00002.safetensors"):
        "c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89",
}
DECISIONS = (
    (54, Path("docs/high-quality-glossary-e13.json"), "baseline", False),
    (55, Path("docs/high-quality-context-e14.json"), "previous-accepted-v1", True),
    (56, Path("docs/high-quality-metricx-e15.json"), "baseline", False),
    (57, Path("docs/japanese-live/experiments/evidence/E15/report.json"), "non-exclusive", False),
    (58, Path("docs/japanese-live/experiments/evidence/E16/report.json"), "W8A16/W8A16", False),
    (59, Path("docs/japanese-live/experiments/evidence/E17-speaker-count/report.json"), "automatic", False),
    (60, Path("docs/japanese-live/experiments/evidence/E17/report.json"), "library-default", False),
    (61, Path("docs/japanese-live/experiments/evidence/E18/development-report.json"), "speakerkit", False),
)


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def job_directory(root: Path, corpus: str) -> Path | None:
    manifests = list((root / "qwen-ja" / corpus / "jobs").glob("*/manifest.json"))
    if not manifests:
        return None
    assert len(manifests) == 1, (root, corpus, manifests)
    return manifests[0].parent


def duration(manifest: dict) -> float:
    start = datetime.fromisoformat(manifest["startedAt"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(manifest["finishedAt"].replace("Z", "+00:00"))
    return (end - start).total_seconds()


def decision_manifest() -> list[dict]:
    rows = []
    for ticket, path, selected, promoted in DECISIONS:
        report = read(path)
        actual = bool(report.get("promoted", False))
        if ticket == 55:
            assert actual and all(all(values.values()) for values in report["gates"].values())
        else:
            assert not actual
        rows.append({
            "ticket": ticket,
            "report": str(path),
            "sha256": sha256(path),
            "promoted": promoted,
            "selectedBehavior": selected,
            "recordedDecision": report.get("decision") or ("promoted" if actual else "not-promoted"),
        })
    return rows


def model_lifecycle(raw: dict) -> dict:
    events = raw["modelEvents"]
    indexes = {(event["modelID"], event["kind"]): index
               for index, event in enumerate(events) if event["modelID"] in MODEL_IDS}
    required = ("reserve-checked", "load-completed", "unload-completed", "memory-release-checked")
    complete = all((model, kind) in indexes for model in MODEL_IDS for kind in required)
    sequential = complete and all(
        indexes[(left, "memory-release-checked")] < indexes[(right, "load-completed")]
        for left, right in zip(MODEL_IDS, MODEL_IDS[1:])
    )
    reserve = all(
        "reserve=8589934592" in (event.get("message") or "")
        for event in events if event["kind"] == "reserve-checked"
    )
    release_fields = {
        event["modelID"]: dict(re.findall(r"(runtimePeak|minimumAvailable|maximum|reserve)=(\d+)", event.get("message") or ""))
        for event in events if event["kind"] == "memory-release-checked"
    }
    runtime_reserve = complete and all(
        model in release_fields
        and set(release_fields[model]) == {
            "runtimePeak", "minimumAvailable", "maximum", "reserve"
        }
        and int(release_fields[model]["runtimePeak"])
            <= int(release_fields[model]["maximum"])
        and int(release_fields[model]["minimumAvailable"])
            >= int(release_fields[model]["reserve"])
        for model in MODEL_IDS
    )
    return {
        "completeLoadUnloadRelease": complete,
        "sequential": sequential,
        "eightGiBReserve": reserve,
        "runtimeReservePreserved": runtime_reserve,
        "noGuardFailure": not any(event["kind"] == "guard-failed" for event in events),
        "metricXAbsent": not any("metricx" in event["modelID"].casefold() for event in events),
    }


def translation_integrity(raw: dict) -> dict:
    translation = raw["translation"]
    mapping = cue_integrity(raw)
    verdicts = translation.get("integrityVerdicts") or []
    reasons = collections.Counter(
        reason["code"] for verdict in verdicts for reason in verdict["reasons"]
    )
    turns = translation["request"]["turns"]
    response = json.loads(translation["response"])["translations"]
    outputs = {item["id"]: item["text"] for item in response}
    contexts = translation["request"].get("conversationContextByCueID") or {}
    retry_ids = {
        cue_id for batch in translation["batches"]
        if batch.get("attemptNumber") == 2
        for cue_id in batch["cueIDs"]
    }
    context_valid = set(contexts) == {turn["id"] for turn in turns} and all(
        context["policyVersion"] == "previous-accepted-v1"
        and context["currentTarget"] == next(turn["japanese"] for turn in turns
                                             if turn["id"] == cue_id)
        and len(context["acceptedHistory"]) <= 2
        and context["encodedHistoryBytes"] <= 512
        for cue_id, context in contexts.items()
    )
    return {
        "cueMapping": mapping,
        "structuredOneToOne": structured_cues_are_valid(mapping),
        "emptyCueIDs": [turn["id"] for turn in turns if not outputs.get(turn["id"], "").strip()],
        "reasonCounts": dict(sorted(reasons.items())),
        "allTerminalVerdictsPass": len(verdicts) == len(turns)
            and all(verdict["verdict"] == "pass" and not verdict["reasons"] for verdict in verdicts),
        "validationFailures": translation["validationFailures"],
        "contextEvidenceValid": context_valid,
        "retryCueIDs": sorted(retry_ids),
        "retryRate": len(retry_ids) / len(turns) if turns else 0,
    }


def stable_speaker_labels(raw: dict) -> bool:
    diarization = raw["diarization"]
    spans = diarization["rawSpans"]
    labels = {}
    for mapping in diarization["mappings"]:
        if not re.fullmatch(r"SPEAKER_\d{2}", mapping["speakerLabel"]):
            return False
        speaker_id = spans[mapping["spanIndex"]]["speakerID"]
        if speaker_id in labels and labels[speaker_id] != mapping["speakerLabel"]:
            return False
        labels[speaker_id] = mapping["speakerLabel"]
    return bool(labels)


def weight_provenance_valid(weight_items: list[dict]) -> bool:
    observed = {
        (item["modelID"], item["file"]): item["sha256"]
        for item in weight_items
        if item.get("revision") == MODEL_REVISIONS.get(item.get("modelID"))
    }
    return len(weight_items) == len(observed) == len(MODEL_WEIGHT_SHA256) \
        and observed == MODEL_WEIGHT_SHA256


def model_provenance_gates(root: Path, raw: dict, metadata: dict) -> dict:
    descriptor = metadata.get("modelProvenance") or {}
    relative_path = descriptor.get("path")
    if not relative_path:
        return {"modelRevisions": False, "weightHashes": False}
    path = root / relative_path
    if not path.is_file() or descriptor.get("sha256") != sha256(path):
        return {"modelRevisions": False, "weightHashes": False}
    provenance = read(path)
    observed_revisions = {
        raw["model"]["modelID"]: raw["model"].get("revision"),
        raw["alignment"]["modelID"]: raw["alignment"].get("revision"),
        raw["diarization"]["modelID"]: raw["diarization"].get("revision"),
        raw["translation"]["model"]: raw["translation"].get("revision"),
    }
    weight_items = provenance.get("weights", [])
    return {
        "modelRevisions": observed_revisions == MODEL_REVISIONS,
        "weightHashes": weight_provenance_valid(weight_items),
    }


def speaker_gates(
    baseline: dict,
    candidate: dict,
    labels_are_stable: bool,
    overlap_evidence_retained: bool,
    decisions: list[dict],
) -> dict:
    return {
        "zeroTranscriptDuplication": candidate["duplicationCount"] == 0,
        "stableLabels": labels_are_stable,
        "rejectedCandidatesRemainBaseline": all(
            not row["promoted"] for row in decisions if row["ticket"] >= 57
        ),
        "speakerAttributedJapaneseErrorGain":
            candidate["speakerAttributedJapaneseError"]["ratePercent"]
            < baseline["speakerAttributedJapaneseError"]["ratePercent"],
        "rawOverlapRetained": overlap_evidence_retained,
        "zeroInventedOverlap": candidate["overlap"]["inventedSeconds"] == 0,
    }


def artifact_gates(root: Path, corpus: str, manifest: dict, raw: dict, metadata: dict,
                   job: Path, decisions: list[dict]) -> dict:
    required = {
        "english-subtitles.srt", "english-subtitles.vtt",
        "english-translation-transcript.txt", "japanese-transcript.txt",
        "manifest.json", "raw-asr.json",
    }
    source_hash = next(item["sha256"] for item in manifest["source"]["references"]
                       if item["label"] == "source-video")
    archive_hash = next(item["sha256"] for item in manifest["source"]["references"]
                        if item["label"] == "reference-archive")
    lifecycle = model_lifecycle(raw)
    return {
        "upstreamDecisions": metadata["candidateSelection"] == decisions,
        "sourceProvenance": metadata["sourceSHA256"] == source_hash
            and metadata["referenceArchiveSHA256"] == archive_hash,
        "sourceDecode": raw["sampleCount"] == manifest["fixture"]["sampleCount"],
        "deliverables": required == {path.name for path in job.iterdir()},
        "selectedQwenJA": raw["model"]["backend"] == "qwen-ja"
            and raw["model"]["modelID"] == MODEL_IDS[0],
        "selectedAligner": raw["alignment"]["modelID"] == MODEL_IDS[1]
            and not raw["alignment"]["validationDiagnostics"],
        "selectedSpeakerBaseline": raw["diarization"]["modelID"] == MODEL_IDS[2]
            and raw["diarization"].get("useExclusiveReconciliation") is False
            and not raw["diarization"]["validationDiagnostics"],
        "selectedTranslateGemma": raw["translation"]["model"] == MODEL_IDS[3],
        "lifecycle": all(lifecycle.values()),
        "rawArtifactHashes": metadata["rawArtifactSHA256"] == {
            "manifest.json": sha256(job / "manifest.json"),
            "raw-asr.json": sha256(job / "raw-asr.json"),
        },
        **model_provenance_gates(root, raw, metadata),
    }


def metric_mean(path: Path, hypothesis: Path) -> float | None:
    scores = comet_scores(path, hypothesis)
    return sum(scores) / len(scores) if scores else None


def score_corpus(root: Path, baseline_root: Path, corpus: str,
                 decisions: list[dict]) -> dict | None:
    candidate_job = job_directory(root, corpus)
    if candidate_job is None:
        return None
    baseline_job = job_directory(baseline_root, corpus)
    assert baseline_job is not None
    manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
    candidate_manifest, candidate = read(candidate_job / "manifest.json"), read(candidate_job / "raw-asr.json")
    baseline_manifest, baseline = read(baseline_job / "manifest.json"), read(baseline_job / "raw-asr.json")
    metadata = read(root / "qwen-ja" / corpus / "run-meta.json")
    baseline_metadata = read(baseline_root / "qwen-ja" / corpus / "run-meta.json")
    assert baseline_metadata["rawArtifactSHA256"] == {
        "manifest.json": sha256(baseline_job / "manifest.json"),
        "raw-asr.json": sha256(baseline_job / "raw-asr.json"),
    }
    baseline_rows = translation_rows(manifest, baseline)
    candidate_rows = translation_rows(manifest, candidate)
    metrics = root / "metrics" / corpus
    source = metrics / "source.ja.txt"
    reference = metrics / "reference.en.txt"
    baseline_hypothesis = metrics / "frozen-product-baseline.en.txt"
    candidate_hypothesis = metrics / "combined-candidate.en.txt"
    write_lines(source, [row["source"] for row in candidate_rows])
    write_lines(reference, [row["reference"] for row in candidate_rows])
    write_lines(baseline_hypothesis, [row["hypothesis"] for row in baseline_rows])
    write_lines(candidate_hypothesis, [row["hypothesis"] for row in candidate_rows])
    comet_path = metrics / "comet-score.json"
    integrity = translation_integrity(candidate)
    baseline_speaker = diarization_metrics(manifest, baseline)
    speaker = diarization_metrics(manifest, candidate)
    baseline_comet = metric_mean(comet_path, baseline_hypothesis)
    candidate_comet = metric_mean(comet_path, candidate_hypothesis)
    reference_text = " ".join(row["reference"] for row in candidate_rows)
    baseline_chrf = chrf_pp(" ".join(row["hypothesis"] for row in baseline_rows), reference_text)
    candidate_chrf = chrf_pp(" ".join(row["hypothesis"] for row in candidate_rows), reference_text)
    translation_gates = {
        "structuredOneToOne": integrity["structuredOneToOne"],
        "zeroEmpty": not integrity["emptyCueIDs"],
        "zeroIntegrityReason": not integrity["reasonCounts"],
        "allTerminalVerdictsPass": integrity["allTerminalVerdictsPass"],
        "zeroValidationFailure": not integrity["validationFailures"],
        "contextEvidence": integrity["contextEvidenceValid"],
    }
    speaker_gate_results = speaker_gates(
        baseline_speaker,
        speaker,
        stable_speaker_labels(candidate),
        "overlapRanges" in candidate["diarization"],
        decisions,
    )
    return {
        "corpusID": corpus,
        "role": "development" if corpus != HOLDOUT else "untouched-channel-separated-holdout",
        "baseline": {
            "commit": baseline_metadata["commit"],
            "COMET": baseline_comet,
            "chrFPlusPlus": baseline_chrf,
            "runtimeSeconds": duration(baseline_manifest),
            "peakMemoryBytes": baseline_manifest["peakMemoryBytes"],
            "diarization": baseline_speaker,
        },
        "candidate": {
            "commit": metadata["commit"],
            "COMET": candidate_comet,
            "chrFPlusPlus": candidate_chrf,
            "japaneseCER": cer("".join(turn["japanese"] for turn in manifest["annotations"]["turns"]), candidate["rawASR"]),
            "terminology": glossary_accuracy(candidate, candidate_rows),
            "translationIntegrity": integrity,
            "diarization": speaker,
            "runtimeSeconds": duration(candidate_manifest),
            "stageDurations": candidate_manifest["stageDurations"],
            "retryRate": integrity["retryRate"],
            "peakMemoryBytes": candidate_manifest["peakMemoryBytes"],
        },
        "artifactGates": artifact_gates(root, corpus, manifest, candidate, metadata, candidate_job, decisions),
        "translationGates": translation_gates,
        "speakerGates": speaker_gate_results,
        "qualityGates": {
            "COMETGain": baseline_comet is not None and candidate_comet is not None
                and candidate_comet > baseline_comet,
            "chrFPlusPlusNonRegression": candidate_chrf >= baseline_chrf,
        },
        "rawArtifacts": {
            "baseline": str(baseline_job),
            "candidate": str(candidate_job),
            "metrics": str(metrics),
        },
    }


def row_passes(row: dict) -> bool:
    return all(row[group] and all(row[group].values()) for group in (
        "artifactGates", "translationGates", "speakerGates", "qualityGates",
    ))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--baseline-root", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--live-log", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert duration({"startedAt": "2026-01-01T00:00:00Z", "finishedAt": "2026-01-01T00:00:02Z"}) == 2
        assert not row_passes({group: {"gate": group != "qualityGates"} for group in (
            "artifactGates", "translationGates", "speakerGates", "qualityGates",
        )})
        baseline_speaker = {
            "speakerAttributedJapaneseError": {"ratePercent": 10.0},
        }
        candidate_speaker = {
            "duplicationCount": 0,
            "speakerAttributedJapaneseError": {"ratePercent": 10.0},
            "overlap": {"inventedSeconds": 0.1},
        }
        gates = speaker_gates(
            baseline_speaker, candidate_speaker, True, True, [],
        )
        assert not gates["speakerAttributedJapaneseErrorGain"]
        assert not gates["zeroInventedOverlap"]
        assert len(MODEL_REVISIONS) == 4 and len(MODEL_WEIGHT_SHA256) == 8
        retained_path = Path(
            "docs/japanese-live/experiments/evidence/E19-safety-stop/"
            "model-weight-verification.json"
        )
        retained = read(retained_path)
        assert {
            (item["modelID"], item["file"]): item["sha256"]
            for item in retained["weights"]
        } == MODEL_WEIGHT_SHA256
        assert weight_provenance_valid(retained["weights"])
        stale = dict(retained["weights"][0], revision="stale")
        assert not weight_provenance_valid([*retained["weights"], stale])
        duplicate = [*retained["weights"][:-1], retained["weights"][0]]
        assert not weight_provenance_valid(duplicate)
        raw_models = {
            "model": {"modelID": MODEL_IDS[0], "revision": MODEL_REVISIONS[MODEL_IDS[0]]},
            "alignment": {"modelID": MODEL_IDS[1], "revision": MODEL_REVISIONS[MODEL_IDS[1]]},
            "diarization": {"modelID": MODEL_IDS[2], "revision": MODEL_REVISIONS[MODEL_IDS[2]]},
            "translation": {"model": MODEL_IDS[3], "revision": MODEL_REVISIONS[MODEL_IDS[3]]},
        }
        assert all(model_provenance_gates(Path("."), raw_models, {
            "modelProvenance": {
                "path": str(retained_path),
                "sha256": sha256(retained_path),
            },
        }).values())
        classification = read(Path(
            "docs/japanese-live/experiments/evidence/E19-safety-stop/"
            "translategemma-memory-smoke-classification.json"
        ))
        evidence_root = Path(
            "docs/japanese-live/experiments/evidence/E19-safety-stop"
        )
        assert all(
            sha256(evidence_root / source["path"]) == source["sha256"]
            for source in classification["sourceArtifacts"].values()
        )
        return
    assert args.root and args.baseline_root and args.json and args.markdown and args.live_log
    decisions = decision_manifest()
    rows = [row for corpus in CORPORA
            if (row := score_corpus(args.root, args.baseline_root, corpus, decisions))]
    controls = read(args.root / "controls.json") if (args.root / "controls.json").exists() else {}
    live_passed = args.live_log.exists() and "Test Suite 'LiveCaptionTests' passed" in args.live_log.read_text()
    development = next((row for row in rows if row["corpusID"] != HOLDOUT), None)
    holdout = next((row for row in rows if row["corpusID"] == HOLDOUT), None)
    development_eligible = development is not None and row_passes(development)
    workflow_valid = all(controls.values()) and all(
        all(row["artifactGates"].values()) for row in rows
    )
    promoted = bool(development_eligible and holdout and row_passes(holdout) and live_passed
                    and controls.get("fullSwiftSuite", False))
    report = {
        "schemaVersion": 1,
        "ticket": 62,
        "candidateSelection": decisions,
        "configuration": {
            "ASR": "qwen-ja-product-default",
            "alignment": "Qwen3-ForcedAligner",
            "diarization": "SpeakerKit-W8A16-auto-library-default-non-exclusive",
            "translation": "TranslateGemma-12b-4bit-previous-accepted-v1",
            "rejectedCandidatesRemainDisabled": True,
        },
        "rows": rows,
        "controls": controls,
        "liveGates": live_passed,
        "developmentEligible": development_eligible,
        "workflowValid": workflow_valid,
        "promoted": promoted,
        "decision": "promote-combined-offline-candidate" if promoted else (
            "holdout-not-opened" if holdout is None and development_eligible else
            "no-go-development" if not development_eligible else "no-go-holdout"
        ),
        "productChanges": "translation context only" if promoted else "none",
        "scopeLimit": "Two complete supplied videos validate only this offline workflow; they do not prove universal anime, VTuber, gaming, conversation, speaker, or overlap quality.",
    }
    evidence = Path("docs/japanese-live/experiments/evidence/E19")
    report["retainedEvidence"] = [
        {"path": str(path), "sha256": sha256(path)}
        for path in sorted(evidence.glob("*")) if path.is_file()
    ]
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    lines = [
        "# E19 — Combined offline candidate", "",
        "Only #55 previous-accepted context is eligible; #54, #56 and #57–#61 retain baseline behavior.", "",
        "| Split | COMET baseline→candidate | chrF++ baseline→candidate | CER | DER / JER | Speaker JA error | Speakers ref/cand | Overlap P/R/F1 | Retry | Runtime | Peak | Gates |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        baseline, candidate, speaker = row["baseline"], row["candidate"], row["candidate"]["diarization"]
        comet = "pending" if candidate["COMET"] is None else f'{baseline["COMET"]:.4f}→{candidate["COMET"]:.4f}'
        overlap = speaker["overlap"]
        lines.append(
            f'| {row["role"]} | {comet} | {baseline["chrFPlusPlus"]:.2f}→{candidate["chrFPlusPlus"]:.2f} | '
            f'{candidate["japaneseCER"]["ratePercent"]:.2f}% | {speaker["DERPercent"]:.2f}% / {speaker["JERPercent"]:.2f}% | '
            f'{speaker["speakerAttributedJapaneseError"]["ratePercent"]:.2f}% | {speaker["referenceSpeakerCount"]}/{speaker["candidateSpeakerCount"]} | '
            f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/{overlap["f1Percent"]:.1f}% | '
            f'{100*candidate["retryRate"]:.2f}% | {candidate["runtimeSeconds"]:.0f}s | {candidate["peakMemoryBytes"]/2**30:.2f} GiB | '
            f'{"PASS" if row_passes(row) else "FAIL"} |'
        )
    lines += ["", f'**Decision: {report["decision"]}.**', "", report["scopeLimit"]]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
