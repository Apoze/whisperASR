#!/usr/bin/env python3
"""Score ticket #44 from retained HighQualityJob artifacts and frozen local references."""

from __future__ import annotations

import argparse
import csv
import difflib
import functools
import hashlib
import json
import math
import re
import statistics
import unicodedata
from datetime import datetime
from pathlib import Path

from report_japanese_l7d import chrf_pp, percentile
from report_local_translator_bakeoff import comet_scores, suspected_hallucination, write_lines

BACKENDS = ("qwen-ja", "parakeet-ja", "whisperkit")
CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
HOLDOUT = "md62mmdz0m"


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_directory(root: Path, backend: str, corpus: str) -> Path:
    manifests = list((root / backend / corpus / "jobs").glob("*/manifest.json"))
    assert len(manifests) == 1, (backend, corpus, manifests)
    return manifests[0].parent


def normalize_ja(text: str) -> str:
    text = re.sub(r"[［\[].*?[］\]]", "", text).replace("（笑）", "").replace("(笑)", "")
    text = unicodedata.normalize("NFKC", text).casefold()
    return "".join(char for char in text if not unicodedata.category(char).startswith(("P", "Z", "C")))


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for row, left_char in enumerate(left, 1):
        current = [row]
        for column, right_char in enumerate(right, 1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (left_char != right_char),
            ))
        previous = current
    return previous[-1]


def cer(reference: str, hypothesis: str) -> dict:
    reference = normalize_ja(reference)
    hypothesis = normalize_ja(hypothesis)
    edits = edit_distance(reference, hypothesis)
    return {
        "editDistance": edits,
        "referenceCharacterCount": len(reference),
        "hypothesisCharacterCount": len(hypothesis),
        "ratePercent": 100 * edits / len(reference) if reference else None,
    }


def candidate_characters(raw: dict) -> list[dict]:
    result = []
    for item in raw["alignment"]["chunks"]:
        for value in item["rawItems"]:
            characters = normalize_ja(value["text"])
            if not characters:
                continue
            duration = (value["end"] - value["start"]) / len(characters)
            result.extend({
                "char": character,
                "start": value["start"] + index * duration,
                "end": value["start"] + (index + 1) * duration,
            } for index, character in enumerate(characters))
    return result


def reference_characters(path: Path) -> dict[int, list[dict]]:
    result: dict[int, list[dict]] = {}
    if path.suffix == ".jsonl":
        for line in path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            result[int(row["cue_id"])] = [
                {"char": normalize_ja(item["char"]), "start": item["start"], "end": item["end"]}
                for item in row["characters"] if normalize_ja(item["char"])
            ]
        return result

    def seconds(value: str) -> float:
        hours, minutes, seconds_value = value.split(":")
        return int(hours) * 3600 + int(minutes) * 60 + float(seconds_value)

    with path.open(encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t"):
            turn_id = int(re.search(r"\d+", row["segment_id"]).group())
            character = normalize_ja(row["character"])
            if character:
                result.setdefault(turn_id, []).append({
                    "char": character,
                    "start": seconds(row["char_start"]),
                    "end": seconds(row["char_end"]),
                })
    return result


def turn_hypothesis(turn: dict, characters: list[dict], sample_rate: int) -> str:
    start = turn["startSample"] / sample_rate
    end = turn["endSample"] / sample_rate
    return "".join(item["char"] for item in characters if item["start"] < end and start < item["end"])


def pooled_turn_cer(turns: list[dict], characters: list[dict], sample_rate: int) -> dict:
    scores = [cer(turn["japanese"], turn_hypothesis(turn, characters, sample_rate)) for turn in turns]
    edits = sum(score["editDistance"] for score in scores)
    references = sum(score["referenceCharacterCount"] for score in scores)
    return {
        "editDistance": edits,
        "referenceCharacterCount": references,
        "turnCount": len(turns),
        "ratePercent": 100 * edits / references if references else None,
    }


def timing_metrics(turns: list[dict], reference: dict[int, list[dict]], candidate: list[dict], sample_rate: int) -> dict:
    errors = []
    for turn in turns:
        reference_items = reference.get(turn["id"], [])
        start = turn["startSample"] / sample_rate
        end = turn["endSample"] / sample_rate
        candidate_items = [item for item in candidate if item["start"] < end and start < item["end"]]
        matcher = difflib.SequenceMatcher(
            None,
            [item["char"] for item in reference_items],
            [item["char"] for item in candidate_items],
            autojunk=False,
        )
        for block in matcher.get_matching_blocks():
            for offset in range(block.size):
                expected = reference_items[block.a + offset]
                observed = candidate_items[block.b + offset]
                errors += [abs(expected["start"] - observed["start"]) * 1000,
                           abs(expected["end"] - observed["end"]) * 1000]
    return {
        "matchedBoundaryCount": len(errors),
        "meanMilliseconds": statistics.mean(errors) if errors else None,
        "medianMilliseconds": statistics.median(errors) if errors else None,
        "p95Milliseconds": percentile(errors, 0.95),
    }


def translation_rows(manifest: dict, raw: dict) -> list[dict]:
    translation = raw["translation"]
    response = json.loads(translation["response"])
    output = {item["id"]: item["text"] for item in response["translations"]}
    turns = translation["request"]["turns"]
    result = []
    for reference in manifest["annotations"]["turns"]:
        start = reference["startSample"] / manifest["fixture"]["sampleRate"]
        end = reference["endSample"] / manifest["fixture"]["sampleRate"]
        matching = sorted((turn for turn in turns
            if turn.get("sourceStart") is not None and turn.get("sourceEnd") is not None
            and turn["sourceStart"] < end and start < turn["sourceEnd"]),
            key=lambda item: (item["sourceStart"], item["sourceEnd"], item["id"]))
        result.append({
            "id": str(reference["id"]),
            "source": reference["japanese"],
            "reference": reference.get("english") or "",
            "hypothesis": " ".join(output.get(turn["id"], "") for turn in matching).strip(),
        })
    return result


def cue_integrity(raw: dict) -> dict:
    translation = raw["translation"]
    expected = [item["id"] for item in translation["request"]["turns"]]
    observed = [item["id"] for item in json.loads(translation["response"])["translations"]]
    starts = []
    ends = []
    for batch in translation["batches"]:
        starts += re.findall(r"<<<CURRENT:([^>\n]+)>>>", batch.get("nativeOutput") or "")
        ends += re.findall(r"<<<END_CURRENT:([^>\n]+)>>>", batch.get("nativeOutput") or "")
    return {
        "missingCueIDs": sorted(set(expected) - set(observed)),
        "duplicateCueIDs": sorted({cue_id for cue_id in observed if observed.count(cue_id) > 1}),
        "reordered": observed != expected,
        "unknownCueIDs": sorted(set(observed) - set(expected)),
        "nativeMarkerFailures": sorted(cue_id for cue_id in expected
            if starts.count(cue_id) != 1 or ends.count(cue_id) != 1),
    }


def structured_cues_are_valid(integrity: dict) -> bool:
    return not any(integrity[key] for key in (
        "missingCueIDs", "duplicateCueIDs", "reordered", "unknownCueIDs",
    ))


def glossary_accuracy(raw: dict, rows: list[dict]) -> dict:
    terms = [item["term"] for item in raw["glossary"]["decisions"] if item["selected"]]
    opportunities = hits = 0
    for row in rows:
        for term in terms:
            if any(form in row["source"] for form in term["japaneseForms"]):
                opportunities += 1
                expected = [term["canonicalEnglish"], *term["englishAliases"]]
                hits += any(value.casefold() in row["hypothesis"].casefold() for value in expected)
    return {
        "hits": hits,
        "opportunities": opportunities,
        "accuracyPercent": 100 * hits / opportunities if opportunities else None,
    }


def overlap_duration(left: list[tuple[float, float]], right: list[tuple[float, float]]) -> float:
    return sum(max(0, min(a_end, b_end) - max(a_start, b_start))
        for a_start, a_end in left for b_start, b_end in right)


def merge_spans(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    result = []
    for start, end in sorted(spans):
        if result and start <= result[-1][1]:
            result[-1] = result[-1][0], max(result[-1][1], end)
        else:
            result.append((start, end))
    return result


def best_speaker_mapping(reference: dict[str, list[tuple[float, float]]], candidate: dict[int, list[tuple[float, float]]]) -> dict[int, str]:
    ref_ids, hyp_ids = sorted(reference), sorted(candidate)
    weights = {(hyp, ref): overlap_duration(candidate[hyp], reference[ref])
        for hyp in hyp_ids for ref in ref_ids}

    def assign(rows, columns, weight):
        if len(columns) > 16:
            # ponytail: greedy ceiling for pathological speaker counts; replace with Hungarian if observed.
            available, result = set(columns), {}
            for row in rows:
                if available:
                    column = max(available, key=lambda value: weight(row, value))
                    result[row] = column
                    available.remove(column)
            return result

        @functools.lru_cache(maxsize=None)
        def solve(index: int, used: int):
            if index == len(rows):
                return 0.0, ()
            best = solve(index + 1, used)
            for column_index, column in enumerate(columns):
                if used & (1 << column_index):
                    continue
                tail_score, tail = solve(index + 1, used | (1 << column_index))
                value = weight(rows[index], column) + tail_score
                if value > best[0]:
                    best = value, ((rows[index], column), *tail)
            return best

        return dict(solve(0, 0)[1])

    if len(hyp_ids) <= len(ref_ids):
        return assign(hyp_ids, ref_ids, lambda hyp, ref: weights[hyp, ref])
    inverse = assign(ref_ids, hyp_ids, lambda ref, hyp: weights[hyp, ref])
    return {hyp: ref for ref, hyp in inverse.items()}


def diarization_metrics(manifest: dict, raw: dict) -> dict:
    sample_rate = manifest["fixture"]["sampleRate"]
    reference: dict[str, list[tuple[float, float]]] = {}
    for turn in manifest["annotations"]["turns"]:
        reference.setdefault(turn["speaker"], []).append((
            turn["startSample"] / sample_rate, turn["endSample"] / sample_rate,
        ))
    candidate: dict[int, list[tuple[float, float]]] = {}
    for span in raw["diarization"]["rawSpans"]:
        candidate.setdefault(span["speakerID"], []).append((span["start"], span["end"]))
    reference = {speaker: merge_spans(spans) for speaker, spans in reference.items()}
    candidate = {speaker: merge_spans(spans) for speaker, spans in candidate.items()}
    mapping = best_speaker_mapping(reference, candidate)
    boundaries = sorted({value for spans in [*reference.values(), *candidate.values()]
        for span in spans for value in span})
    miss = false_alarm = confusion = denominator = 0.0
    ref_overlap = hyp_overlap = overlap_match = 0.0
    for start, end in zip(boundaries, boundaries[1:]):
        if start == end:
            continue
        duration = end - start
        ref_active = {speaker for speaker, spans in reference.items()
            if any(left < end and start < right for left, right in spans)}
        hyp_active = {speaker for speaker, spans in candidate.items()
            if any(left < end and start < right for left, right in spans)}
        correct = sum(mapping.get(speaker) in ref_active for speaker in hyp_active)
        denominator += len(ref_active) * duration
        miss += max(0, len(ref_active) - len(hyp_active)) * duration
        false_alarm += max(0, len(hyp_active) - len(ref_active)) * duration
        confusion += max(0, min(len(ref_active), len(hyp_active)) - correct) * duration
        ref_is_overlap, hyp_is_overlap = len(ref_active) > 1, len(hyp_active) > 1
        ref_overlap += ref_is_overlap * duration
        hyp_overlap += hyp_is_overlap * duration
        overlap_match += (ref_is_overlap and hyp_is_overlap) * duration

    inverse = {reference_id: hypothesis_id for hypothesis_id, reference_id in mapping.items()}
    jer = []
    for speaker, spans in reference.items():
        hypothesis = candidate.get(inverse.get(speaker), [])
        intersection = overlap_duration(spans, hypothesis)
        union = sum(end - start for start, end in spans) + sum(end - start for start, end in hypothesis) - intersection
        jer.append(1 - intersection / union if union else 1.0)
    precision = overlap_match / hyp_overlap if hyp_overlap else 0.0
    recall = overlap_match / ref_overlap if ref_overlap else 0.0
    return {
        "DERPercent": 100 * (miss + false_alarm + confusion) / denominator if denominator else None,
        "JERPercent": 100 * statistics.mean(jer) if jer else None,
        "referenceSpeakerCount": len(reference),
        "candidateSpeakerCount": len(candidate),
        "speakerCountAbsoluteError": abs(len(reference) - len(candidate)),
        "overlap": {
            "precisionPercent": 100 * precision,
            "recallPercent": 100 * recall,
            "f1Percent": 100 * 2 * precision * recall / (precision + recall) if precision + recall else 0.0,
            "referenceSeconds": ref_overlap,
            "candidateSeconds": hyp_overlap,
            "missedSeconds": max(0, ref_overlap - overlap_match),
            "inventedSeconds": max(0, hyp_overlap - overlap_match),
        },
    }


def gates(root: Path, backend: str, corpus: str, manifest: dict, raw: dict, metadata: dict, job: Path) -> dict:
    integrity = cue_integrity(raw)
    model_ids = [
        raw["model"]["modelID"], raw["alignment"]["modelID"],
        raw["diarization"]["modelID"], raw["translation"]["model"],
    ]
    events = raw["modelEvents"]
    duration = raw["sampleCount"] / raw["sampleRate"]
    items = [item for chunk in raw["alignment"]["chunks"] for item in chunk["rawItems"]]
    required = {
        "japanese-transcript.txt", "english-translation-transcript.txt",
        "english-subtitles.vtt", "english-subtitles.srt", "raw-asr.json", "manifest.json",
    }
    controls = read(root / "controls.json")
    return {
        "provenance": metadata["sourceSHA256"] == next(item["sha256"] for item in manifest["source"]["references"] if item["label"] == "source-video")
            and metadata["referenceArchiveSHA256"] == next(item["sha256"] for item in manifest["source"]["references"] if item["label"] == "reference-archive"),
        "sourceDecode": raw["sampleCount"] == manifest["fixture"]["sampleCount"],
        "functional": metadata["backend"] == backend and raw["rawASR"].strip() != "",
        "artifacts": required == {path.name for path in job.iterdir()},
        "cancellation": controls["realCancellation"],
        "failureClassification": controls["failureClassification"],
        "timestampIntegrity": bool(items) and all(0 <= item["start"] <= item["end"] <= duration for item in items)
            and not raw["alignment"]["validationDiagnostics"],
        "speakerIntegrity": bool(raw["diarization"]["rawSpans"])
            and not raw["diarization"]["validationDiagnostics"],
        "translationIntegrity": raw["translation"]["model"] == "mlx-community/translategemma-12b-it-4bit"
            and not raw["translation"]["validationFailures"]
            and structured_cues_are_valid(integrity),
        "exclusiveResidentModel": not any(event["kind"] == "guard-failed" for event in events)
            and all(all(any(event["kind"] == kind and event["modelID"] == model for event in events)
                for kind in ("reserve-checked", "load-completed", "unload-completed", "memory-release-checked"))
                for model in model_ids),
        "memoryReserve": all("reserve=8589934592" in (event.get("message") or "")
            for event in events if event["kind"] == "reserve-checked"),
    }


def iso_duration(manifest: dict) -> float:
    return (datetime.fromisoformat(manifest["finishedAt"].replace("Z", "+00:00"))
        - datetime.fromisoformat(manifest["startedAt"].replace("Z", "+00:00"))).total_seconds()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert cer("日本語。", "日本語")["ratePercent"] == 0
        assert edit_distance("abc", "adc") == 1
        assert merge_spans([(0, 1), (0.5, 2), (3, 4)]) == [(0, 2), (3, 4)]
        assert best_speaker_mapping({"A": [(0, 2)]}, {7: [(0, 2)]}) == {7: "A"}
        assert structured_cues_are_valid({
            "missingCueIDs": [], "duplicateCueIDs": [], "reordered": False,
            "unknownCueIDs": [], "nativeMarkerFailures": ["cue-0001"],
        })
        return
    assert args.root and args.json and args.markdown

    manifests = {corpus: read(Path("docs/japanese-live/corpora") / corpus / "manifest.json") for corpus in CORPORA}
    artifacts = {}
    rows = []
    metric_paths = {}
    for backend in BACKENDS:
        for corpus in CORPORA:
            job = run_directory(args.root, backend, corpus)
            product_manifest = read(job / "manifest.json")
            raw = read(job / "raw-asr.json")
            metadata = read(args.root / backend / corpus / "run-meta.json")
            manifest = manifests[corpus]
            characters = candidate_characters(raw)
            selected_turns = [turn for turn in manifest["annotations"]["turns"]
                if turn["confidence"] == "high" and not turn.get("overlap")]
            alignment_reference = next(item for item in manifest["source"]["references"]
                if item["label"] == "character-alignment")
            reference_path = Path(alignment_reference["locator"])
            translations = translation_rows(manifest, raw)
            integrity = cue_integrity(raw)
            metric_dir = args.root / "metrics" / corpus
            source_path = metric_dir / "source.ja.txt"
            reference_path_en = metric_dir / "reference.en.txt"
            hypothesis_path = metric_dir / f"{backend}.en.txt"
            write_lines(source_path, [item["source"] for item in translations])
            write_lines(reference_path_en, [item["reference"] for item in translations])
            write_lines(hypothesis_path, [item["hypothesis"] for item in translations])
            metric_paths[(backend, corpus)] = hypothesis_path
            comet = comet_scores(metric_dir / "comet-score.json", hypothesis_path)
            candidate_gates = gates(args.root, backend, corpus, manifest, raw, metadata, job)
            row = {
                "backend": backend,
                "corpusID": corpus,
                "corpusRole": metadata["corpusRole"],
                "model": product_manifest["model"],
                "gates": candidate_gates,
                "japanese": {
                    "overallCER": cer("".join(turn["japanese"] for turn in manifest["annotations"]["turns"]), raw["rawASR"]),
                    "highConfidenceNonOverlapCER": pooled_turn_cer(selected_turns, characters, manifest["fixture"]["sampleRate"]),
                    "allTimedTurnsCER": pooled_turn_cer(manifest["annotations"]["turns"], characters, manifest["fixture"]["sampleRate"]),
                    "annotatedTerminology": {"accuracyPercent": None, "opportunities": 0,
                        "diagnostic": "unavailable: frozen manifests contain no criticalTerms"},
                },
                "english": {
                    "COMET": statistics.mean(comet) if comet else None,
                    "chrFPlusPlus": chrf_pp(" ".join(item["hypothesis"] for item in translations), " ".join(item["reference"] for item in translations)),
                    "glossary": glossary_accuracy(raw, translations),
                    "cueIntegrity": integrity,
                    "untranslatedCueIDs": [item["id"] for item in translations if re.search(r"[\u3040-\u30ff\u3400-\u9fff]", item["hypothesis"])],
                    "suspectedHallucinatedCueIDs": [item["id"] for item in translations if suspected_hallucination(item)],
                },
                "timing": timing_metrics(selected_turns, reference_characters(reference_path), characters, manifest["fixture"]["sampleRate"]),
                "diarization": diarization_metrics(manifest, raw),
                "runtimeSeconds": iso_duration(product_manifest),
                "stageDurations": product_manifest["stageDurations"],
                "peakMemoryBytes": product_manifest["peakMemoryBytes"],
                "rawArtifactDirectory": str(job),
            }
            rows.append(row)
            artifacts[(backend, corpus)] = (product_manifest, raw, metadata)

    for corpus in CORPORA:
        baseline = artifacts[(BACKENDS[0], corpus)]
        for backend in BACKENDS[1:]:
            candidate = artifacts[(backend, corpus)]
            assert baseline[2]["implementationSHA256"] == candidate[2]["implementationSHA256"]
            assert baseline[2]["sourceSHA256"] == candidate[2]["sourceSHA256"]
            for component in ("alignment", "diarization"):
                assert (baseline[1][component]["modelID"], baseline[1][component]["revision"]) == (candidate[1][component]["modelID"], candidate[1][component]["revision"])
            assert (baseline[1]["translation"]["model"], baseline[1]["translation"]["revision"]) == (candidate[1]["translation"]["model"], candidate[1]["translation"]["revision"])
    assert all(all(row["gates"].values()) for row in rows), "A veto gate failed; raw artifacts remain available."

    holdout = [row for row in rows if row["corpusID"] == HOLDOUT]
    selected = min(holdout, key=lambda row: (
        row["japanese"]["highConfidenceNonOverlapCER"]["ratePercent"],
        row["japanese"]["overallCER"]["ratePercent"],
        row["peakMemoryBytes"],
    ))["backend"]
    report = {
        "schemaVersion": 1,
        "rows": rows,
        "selectedProductDefault": selected,
        "scoringImplementationSHA256": {
            "Scripts/report_high_quality_acceptance.py": sha256(Path(__file__)),
            "Scripts/comet_score_compat.py": sha256(Path("Scripts/comet_score_compat.py")),
        },
        "selectionRule": "Lowest untouched-holdout high-confidence non-overlap Japanese CER; exact ties use overall CER then peak memory.",
        "oneVariableAudit": "Only HighQualityASRBackend changed; source, product seam, forced aligner, SpeakerKit, TranslateGemma, deliverables and implementation hashes were fixed.",
        "scopeLimit": "These two supplied videos validate the initial offline workflow only; they do not establish broad ASR superiority.",
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Offline high-quality acceptance — ticket #44", "",
        report["oneVariableAudit"],
        "Raw manifests, ASR/alignment/diarization/translation evidence, prompts, native outputs, hashes and diagnostics are retained under `.build/benchmarks/high-quality/offline-acceptance/`.", "",
        "| Corpus | ASR | CER high | CER overall | COMET | chrF++ | Timing mean/median/p95 | DER / JER | Speakers ref/cand/error | Overlap P/R/F1 | Runtime | Peak |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        english, timing, diarization = row["english"], row["timing"], row["diarization"]
        comet = "pending" if english["COMET"] is None else f'{english["COMET"]:.4f}'
        timing_text = "n/a" if timing["meanMilliseconds"] is None else f'{timing["meanMilliseconds"]:.0f}/{timing["medianMilliseconds"]:.0f}/{timing["p95Milliseconds"]:.0f} ms'
        overlap = diarization["overlap"]
        lines.append(
            f'| {row["corpusID"]} | {row["backend"]} | {row["japanese"]["highConfidenceNonOverlapCER"]["ratePercent"]:.2f}% | '
            f'{row["japanese"]["overallCER"]["ratePercent"]:.2f}% | {comet} | {english["chrFPlusPlus"]:.2f} | {timing_text} | '
            f'{diarization["DERPercent"]:.2f}% / {diarization["JERPercent"]:.2f}% | '
            f'{diarization["referenceSpeakerCount"]}/{diarization["candidateSpeakerCount"]}/{diarization["speakerCountAbsoluteError"]} | '
            f'{overlap["precisionPercent"]:.1f}/{overlap["recallPercent"]:.1f}/{overlap["f1Percent"]:.1f}% | '
            f'{row["runtimeSeconds"]:.0f}s | {row["peakMemoryBytes"] / 2**30:.2f} GiB |'
        )
    lines += ["", "## English diagnostics", "",
        "| Corpus | ASR | Glossary | Structured cue IDs | Native marker misses | Untranslated | Hallucination flags |",
        "|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        english, glossary, integrity = row["english"], row["english"]["glossary"], row["english"]["cueIntegrity"]
        glossary_text = "n/a" if glossary["opportunities"] == 0 else f'{glossary["accuracyPercent"]:.1f}% ({glossary["hits"]}/{glossary["opportunities"]})'
        cue_text = "PASS" if structured_cues_are_valid(integrity) else "FAIL"
        lines.append(
            f'| {row["corpusID"]} | {row["backend"]} | {glossary_text} | {cue_text} | '
            f'{len(integrity["nativeMarkerFailures"])} | {len(english["untranslatedCueIDs"])} | '
            f'{len(english["suspectedHallucinatedCueIDs"])} |'
        )
    lines += ["", "Native marker misses, untranslated cues and hallucination flags are retained diagnostics; the structured one-to-one cue-ID mapping is the veto gate.",
        "", "All veto gates passed for all three selectable backends. Frozen `criticalTerms` opportunities: 0, therefore Japanese terminology accuracy is explicitly n/a.",
        f'Product default: **{selected}** by the predeclared holdout rule.', "", report["scopeLimit"]]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
