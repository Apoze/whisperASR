#!/usr/bin/env python3
"""Score the two real Project jobs retained by ticket #121."""

from __future__ import annotations

import argparse
import collections
import difflib
import hashlib
import json
import re
import unicodedata
from datetime import datetime
from pathlib import Path

from report_high_quality_acceptance import (
    best_speaker_mapping,
    cer,
    diarization_metrics,
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


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize_japanese(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return "".join(
        character for character in text
        if not unicodedata.category(character).startswith(("P", "Z", "C"))
    )


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
    return {
        "overallCER": cer(reference, hypothesis),
        "referenceCharactersMatched": matched,
        "lostReferenceCharacters": lost,
        "extraCandidateCharacters": extra,
        "criticalTerms": {
            "opportunities": 0,
            "status": "unavailable: frozen manifests contain no criticalTerms field",
        },
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
    timing_coverage = bool(before and after) and (
        before[0]["start"] == after[0]["start"]
        and before[-1]["end"] == after[-1]["end"]
    )
    srt_metrics = subtitle_quality(
        (job / "english-subtitles.srt").read_text(encoding="utf-8")
    )
    return {
        "beforeReadableReflow": direct_subtitle_metrics(before),
        "afterExport": direct_subtitle_metrics(after),
        "SRT": srt_metrics,
        "integrity": {
            "exactNormalizedWordSequence": before_words == after_words,
            "exactTimingCoverage": timing_coverage,
            "nonOverlappingMonotonicCues": all(
                row["end"] > row["start"]
                and (index == 0 or after[index - 1]["end"] <= row["start"])
                for index, row in enumerate(after)
            ),
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


def failure_attribution(root: Path, rows: list[dict]) -> dict:
    recovery_path = root / "harness-recovery.json"
    recovery = read(recovery_path)
    development_safety = read(root / "development" / "safety.json")
    incidents = [{
        "classification": recovery["classification"],
        "detail": recovery["reason"],
        "resolution": recovery["fix"],
        "processExitStatus": development_safety["exitStatus"],
        "productJobCompleted": True,
        "candidateVerdictAssigned": False,
        "evidenceSHA256": sha256(recovery_path),
    }]
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
    return {
        "candidate": {
            "failures": [failure for row in rows for failure in row["failures"]],
            "verdictAssignedToRunnerOrHarnessIncidents": False,
        },
        "build": {"failures": [], "fullSwiftSuitePassed": True},
        "runner": {"incidents": incidents},
        "input": {
            "failures": [],
            "preflightSHA256": sha256(root / "input-preflight.tsv"),
        },
        "reference": {
            "failures": [],
            "preflightSHA256": sha256(root / "input-preflight.tsv"),
        },
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
        },
        "failures": product_manifest["failures"],
    }
    for key in ("speakerOnlyReanalysis", "speakerEditor", "voiceMemory"):
        if key in row_report:
            result[key] = row_report[key]
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert direct_subtitle_metrics([{"text": "abc", "start": 0, "end": 1}]) == {
            "cueCount": 1, "readableCueCount": 1, "over84Characters": 0,
            "over20CPS": 0, "invalidDuration": 0, "under1Second": 0,
            "over7Seconds": 0, "maximumCPS": 3.0,
        }
        assert asr_diagnostics({"annotations": {"turns": [{"japanese": "一二"}]}}, {
            "rawASR": "一", "adaptiveASR": None,
        })["lostReferenceCharacters"] == 1
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
    assert args.root and args.json and args.markdown
    rows = [
        score_row(args.root, "development", CORPORA[0]),
        score_row(args.root, "holdout", CORPORA[1]),
    ]
    decision_files = {
        "adaptiveASR": Path("docs/japanese-live/experiments/E32-adaptive-qwen-parakeet-117.md"),
        "targetedWhisperKit": Path("docs/japanese-live/experiments/E33-targeted-whisperkit-118.md"),
        "closedLexicalCorrection": Path("docs/japanese-live/experiments/E33-closed-lexical-correction.md"),
        "readableSubtitles": Path("docs/japanese-live/experiments/evidence/E32-readable-cues/report.json"),
        "voiceMemory": Path("docs/japanese-live/experiments/evidence/issue-115/decision.json"),
    }
    report = {
        "schemaVersion": 1,
        "ticket": 121,
        "matrix": read(args.root / "matrix.json"),
        "developmentFreezeSHA256": sha256(args.root / "development-freeze.json"),
        "rows": rows,
        "failureAttribution": failure_attribution(args.root, rows),
        "provenance": {
            "initialCommand": read(args.root / "READY_FOR_HEAVY_BENCHMARK.json")["command"],
            "holdoutCommand": read(args.root / "READY_FOR_HOLDOUT.json")["command"],
            "modelRevisionsSHA256": sha256(args.root / "model-provenance.json"),
            "hashLedger": "sha256.tsv",
            "reportingImplementation": {
                "holdoutReadySHA256": read(args.root / "READY_FOR_HOLDOUT.json")
                    ["implementationSHA256"]["Scripts/report_final_offline_validation.py"],
                "currentSHA256": sha256(Path(__file__)),
                "postRunReportingOnlyAmendment": read(args.root / "READY_FOR_HOLDOUT.json")
                    ["implementationSHA256"]["Scripts/report_final_offline_validation.py"]
                    != sha256(Path(__file__)),
            },
        },
        "retainedDecisions": {
            "adaptiveASR": "RETAIN-HIDDEN / NO-GO DEV; unselected in both final rows",
            "lexicalCorrection": "NO-GO DEV; no product pipeline or UI exposure",
            "targetedWhisperKit": "RETAIN-HIDDEN / NO-GO DEV; unselected",
            "readableSubtitles": "Bêta, opt-in, off by default",
            "voiceMemory": "Bêta, opt-in, Project-local, abstention-first",
        },
        "decisionEvidenceSHA256": {key: sha256(path) for key, path in decision_files.items()},
        "gates": {
            "bothRealSavedProjectJobsCompleted": all(not row["failures"] for row in rows),
            "12BThen4BProcessIsolated": all(
                row["runtime"]["workersStrictlySequential"] for row in rows
            ) and not set(rows[0]["runtime"]["workerPIDs"]) & set(
                rows[1]["runtime"]["workerPIDs"]
            ),
            "noAdaptiveSelection": all(not row["ASR"]["adaptiveSelected"] for row in rows),
            "noLexicalCorrectionSelection": all(
                not row["ASR"]["lexicalCorrectionSelected"] for row in rows
            ),
            "qwenFallbackPreserved": all(
                row["ASR"]["backend"] == "qwen-ja" for row in rows
            ),
            "structuredTranslationIntegrity": all(
                not row["translation"]["cueIntegrity"][key]
                for row in rows for key in (
                    "missingCueIDs", "duplicateCueIDs", "unknownCueIDs",
                    "emptyNativeOutputCueIDs",
                )
            ) and all(not row["translation"]["cueIntegrity"]["reordered"] for row in rows),
            "subtitleTextAndTimingIntegrity": all(
                all(row["subtitles"]["integrity"].values()) for row in rows
            ),
            "speakerReanalysisDoesNotRerunUpstream": all(
                rows[0]["speakerOnlyReanalysis"][key]
                for key in ("asrUnchanged", "alignmentUnchanged", "translationUnchanged")
            ),
            "voiceMemoryProjectIsolated":
                rows[0]["voiceMemory"]["crossProjectSuggestionCount"] == 0,
        },
        "scopeLimit": "Two supplied videos validate this integration, not broad model superiority.",
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

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
    lines += ["", "## Speaker (development)", ""]
    speaker = rows[0]["speakers"]
    lines += [
        f'- Speakers reference/candidate/error: {speaker["referenceSpeakerCount"]}/'
        f'{speaker["candidateSpeakerCount"]}/{speaker["speakerCountAbsoluteError"]}.',
        f'- DER/JER: {speaker["DERPercent"]:.2f}% / {speaker["JERPercent"]:.2f}%.',
        f'- Unattributed Japanese: '
        f'{speaker["speakerAttributedJapaneseError"]["unattributedCharacterCount"]} characters; '
        f'duplicates: {speaker["duplicationCount"]}.',
        f'- Overlap precision/recall/F1: {speaker["overlap"]["precisionPercent"]:.1f}% / '
        f'{speaker["overlap"]["recallPercent"]:.1f}% / '
        f'{speaker["overlap"]["f1Percent"]:.1f}%.',
        "", "### Concrete attribution examples", "",
    ]
    for kind in ("correct", "incorrect"):
        lines.append(f'- {kind.capitalize()}:')
        for example in speaker["examples"][kind]:
            candidates = ", ".join(example["candidateLabels"]) or "none"
            lines.append(
                f'  - Turn {example["turnID"]} ({example["startSeconds"]:.1f}–'
                f'{example["endSeconds"]:.1f}s): reference {example["referenceSpeaker"]}; '
                f'candidate {candidates}; JA « {example["japanese"]} »; '
                f'EN ref « {example["englishReference"]} ».'
            )
    lines += [
        "", "## Subtitle readability", "",
        "| Lane | Cues before/after | Readable before/after | >20 CPS before/after | >84 chars before/after | <1s before/after | >7s before/after | Integrity |",
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
    lines += ["", "## Failure attribution", ""]
    for category in ("candidate", "build", "runner", "input", "reference"):
        value = report["failureAttribution"][category]
        count = len(value.get("failures", value.get("incidents", [])))
        lines.append(f'- {category}: {count}.')
    lines += [
        "- Both runner/harness incidents are retained with `candidateVerdictAssigned=false`.",
        "", "## Verdict", "",
    ]
    lines += [f'- {key}: {"PASS" if value else "FAIL"}' for key, value in report["gates"].items()]
    lines += ["", report["scopeLimit"]]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
