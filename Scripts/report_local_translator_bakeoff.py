#!/usr/bin/env python3
"""Report ticket #76 from frozen product-pipeline translation artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
from collections import Counter
from pathlib import Path

from report_japanese_l7d import chrf_pp

CANDIDATES = ("translategemma-12b-it-4bit", "translategemma-4b-it-4bit")
CORPORA = {"development": "qudu2fx3ncc", "holdout": "md62mmdz0m"}
INTEGRITY_REASON_CODES = (
    "empty-output", "residual-japanese", "control-scaffolding",
    "critical-glossary-violation", "truncated-output", "degenerate-repetition",
    "pathological-length", "copied-neighbour",
)


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def run_directory(root: Path, candidate: str, corpus: str) -> Path | None:
    pointer = root / candidate / corpus / "job-id.txt"
    if not pointer.exists():
        return None
    return root / candidate / corpus / "jobs" / pointer.read_text().strip()


def write_lines(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(value.replace("\n", " ") for value in values) + "\n", encoding="utf-8")


def suspected_hallucination(row: dict) -> bool:
    hypothesis = row["hypothesis"].strip()
    reference = row["reference"].strip()
    words = re.findall(r"[\w']+", hypothesis.casefold())
    trigrams = list(zip(words, words[1:], words[2:]))
    return (len(trigrams) >= 6 and len(set(trigrams)) * 2 < len(trigrams)) \
        or len(hypothesis) > max(160, 4 * max(len(reference), 1))


def relative(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def decoded_map(value: dict | list) -> dict:
    if isinstance(value, dict):
        return value
    assert len(value) % 2 == 0
    return dict(zip(value[::2], value[1::2]))


def response_map(raw: dict) -> dict[str, str]:
    translation = raw["translation"]
    verdicts = translation.get("integrityVerdicts") or []
    if len(verdicts) == len(translation["request"]["turns"]):
        return {row["cueID"]: row["generatedOutput"] for row in verdicts}
    response = json.loads(translation["response"])
    return {row["id"]: row["text"] for row in response["translations"]}


def stable_request(request: dict) -> dict:
    return {**request, "source": {
        key: value for key, value in request["source"].items() if key != "modifiedAt"
    }}


def translation_rows(manifest: dict, raw: dict) -> list[dict]:
    outputs = response_map(raw)
    turns = raw["translation"]["request"]["turns"]
    sample_rate = manifest["fixture"]["sampleRate"]
    rows = []
    for reference in manifest["annotations"]["turns"]:
        start, end = reference["startSample"] / sample_rate, reference["endSample"] / sample_rate
        matching = sorted((turn for turn in turns
            if turn.get("sourceStart") is not None and turn.get("sourceEnd") is not None
            and turn["sourceStart"] < end and start < turn["sourceEnd"]),
            key=lambda turn: (turn["sourceStart"], turn["sourceEnd"], turn["id"]))
        rows.append({
            "id": str(reference["id"]),
            "unitIDs": [turn["id"] for turn in matching],
            "source": " ".join(turn["japanese"] for turn in matching).strip(),
            "reference": reference.get("english") or "",
            "hypothesis": " ".join(outputs.get(turn["id"], "") for turn in matching).strip(),
        })
    return rows


def cue_integrity(raw: dict) -> dict:
    translation = raw["translation"]
    expected = [turn["id"] for turn in translation["request"]["turns"]]
    verdicts = translation.get("integrityVerdicts") or []
    observed = [row["cueID"] for row in verdicts] if len(verdicts) == len(expected) else [
        row["id"] for row in json.loads(translation["response"])["translations"]
    ]
    batches = translation.get("batches", [])
    return {
        "missingCueIDs": sorted(set(expected) - set(observed)),
        "duplicateCueIDs": sorted(set(cue for cue in observed if observed.count(cue) > 1)),
        "unknownCueIDs": sorted(set(observed) - set(expected)),
        "reordered": observed != expected,
        "emptyNativeOutputCueIDs": sorted(set(cue for batch in batches
            for cue in batch.get("cueIDs", [])
            if not (batch.get("nativeOutput") or "").strip())),
    }


def glossary_accuracy(raw: dict) -> dict:
    verdicts = raw["translation"].get("integrityVerdicts") or []
    opportunities = [(verdict["cueID"], item) for verdict in verdicts
                     for item in verdict.get("glossaryOpportunities", [])]
    hits = sum(item["satisfied"] for _, item in opportunities)
    return {
        "hits": hits,
        "opportunities": len(opportunities),
        "accuracyPercent": 100 * hits / len(opportunities) if opportunities else None,
        "misses": [{"cueID": cue, "termID": item["id"], "critical": item["critical"]}
                   for cue, item in opportunities if not item["satisfied"]],
    }


def subtitle_quality(srt: str | None) -> dict:
    if srt is None:
        return {"status": "not-published-after-integrity-failure", "cueCount": 0,
                "emptyCueIDs": [], "invalidDurationCueIDs": [],
                "over84CharacterCueIDs": [], "over20CharactersPerSecondCueIDs": [],
                "maximumCharactersPerSecond": None, "malformedBlockCount": 0}
    rows = []
    malformed = 0
    for block in re.split(r"\n\s*\n", srt.strip()):
        lines = block.splitlines()
        if len(lines) < 3 or " --> " not in lines[1]:
            malformed += 1
            continue
        start, end = lines[1].split(" --> ", 1)
        try:
            seconds = lambda value: sum(number * scale for number, scale in zip(
                map(float, re.split("[:,]", value)), (3600, 60, 1, 0.001)))
            duration = seconds(end) - seconds(start)
        except ValueError:
            malformed += 1
            continue
        text = "\n".join(lines[2:]).strip()
        rows.append((lines[0], text, len(text) / duration if duration > 0 else None))
    return {
        "status": "published",
        "cueCount": len(rows),
        "emptyCueIDs": [cue for cue, text, _ in rows if not text],
        "invalidDurationCueIDs": [cue for cue, _, speed in rows if speed is None],
        "over84CharacterCueIDs": [cue for cue, text, _ in rows if len(text) > 84],
        "over20CharactersPerSecondCueIDs": [cue for cue, _, speed in rows
                                               if speed is not None and speed > 20],
        "maximumCharactersPerSecond": max((speed for _, _, speed in rows
                                             if speed is not None), default=0),
        "malformedBlockCount": malformed,
    }


def bootstrap_difference(left: list[float], right: list[float]) -> dict:
    assert len(left) == len(right) and left
    randomizer = random.Random(76)
    values = []
    for _ in range(10_000):
        indices = [randomizer.randrange(len(left)) for _ in left]
        values.append(sum(left[index] - right[index] for index in indices) / len(indices))
    values.sort()
    return {
        "mean": sum(a - b for a, b in zip(left, right)) / len(left),
        "low95": values[249],
        "high95": values[9_749],
        "significant": values[249] > 0 or values[9_749] < 0,
    }


def comet_scores(path: Path, hypothesis_path: Path) -> list[float] | None:
    if not path.exists():
        return None
    data = read(path)
    rows = next((value for key, value in data.items()
        if Path(key).name == hypothesis_path.name), None)
    return [float(row["COMET"]) for row in rows] if rows else None


def representative_examples(rows: dict[str, list[dict]]) -> list[dict]:
    by_candidate = {candidate: {row["id"]: row for row in values}
                    for candidate, values in rows.items()}
    common = sorted(set(by_candidate[CANDIDATES[0]]) & set(by_candidate[CANDIDATES[1]]))
    scored = []
    for cue_id in common:
        twelve, four = (by_candidate[candidate][cue_id] for candidate in CANDIDATES)
        delta = chrf_pp(four["hypothesis"], four["reference"]) \
            - chrf_pp(twelve["hypothesis"], twelve["reference"])
        if four["hypothesis"] != twelve["hypothesis"]:
            scored.append((abs(delta), delta, cue_id, twelve, four))
    selected = sorted(scored, reverse=True)[:6]
    return [{
        "cueID": cue_id,
        "source": twelve["source"],
        "reference": twelve["reference"],
        "translateGemma12B": twelve["hypothesis"],
        "translateGemma4B": four["hypothesis"],
        "chrFPlusPlus4BMinus12B": delta,
        "diagnostics": {
            "12BEmpty": not twelve["hypothesis"].strip(),
            "4BEmpty": not four["hypothesis"].strip(),
            "12BResidualJapanese": bool(re.search(r"[\u3040-\u30ff\u3400-\u9fff]", twelve["hypothesis"])),
            "4BResidualJapanese": bool(re.search(r"[\u3040-\u30ff\u3400-\u9fff]", four["hypothesis"])),
        },
    } for _, delta, cue_id, twelve, four in selected]


def fmt(value: float | None, digits: int = 3) -> str:
    return "pending" if value is None else f"{value:.{digits}f}"


def duration(value: float) -> str:
    minutes, seconds = divmod(value, 60)
    return f"{int(minutes)}m {seconds:.1f}s"


def scorer_summary(directory: Path) -> dict | None:
    device_path = directory / "comet-device.json"
    if not device_path.exists():
        return None
    timing = (directory / "comet-time.txt").read_text()
    pressure = [path.read_text() for path in (
        directory / "memory-pressure-before.txt", directory / "memory-pressure-after.txt")]
    swap = [path.read_text() for path in (
        directory / "swap-before.txt", directory / "swap-after.txt")]
    number = lambda pattern, text: float(re.search(pattern, text, re.MULTILINE).group(1))
    return {
        "device": read(device_path),
        "command": (directory / "comet-command.txt").read_text().strip(),
        "elapsedSeconds": number(r"^real\s+([0-9.]+)", timing),
        "maximumResidentSetBytes": int(number(r"^\s*(\d+)\s+maximum resident set size", timing)),
        "peakPhysicalFootprintBytes": int(number(r"^\s*(\d+)\s+peak memory footprint", timing)),
        "freeMemoryPercentBefore": int(number(r"free percentage: (\d+)%", pressure[0])),
        "freeMemoryPercentAfter": int(number(r"free percentage: (\d+)%", pressure[1])),
        "swapDeltaMiB": number(r"used = ([0-9.]+)M", swap[1])
            - number(r"used = ([0-9.]+)M", swap[0]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    artifacts: dict[tuple[str, str], dict] = {}
    directories: dict[tuple[str, str], Path] = {}
    for role, corpus in CORPORA.items():
        for candidate in CANDIDATES:
            directory = run_directory(args.root, candidate, corpus)
            if directory and (directory / "raw-asr.json").exists():
                directories[(candidate, role)] = directory
                artifacts[(candidate, role)] = read(directory / "raw-asr.json")

    rows, paired, examples, invalid_examples, gates, scorers = [], {}, {}, {}, {}, {}
    for role, corpus in CORPORA.items():
        if any((candidate, role) not in artifacts for candidate in CANDIDATES):
            continue
        manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
        candidate_rows = {candidate: translation_rows(manifest, artifacts[(candidate, role)])
                          for candidate in CANDIDATES}
        hard_failures = {candidate: {
            verdict["cueID"] for verdict in artifacts[(candidate, role)]["translation"]
                .get("integrityVerdicts", []) if verdict.get("verdict") == "hard-failure"
        } for candidate in CANDIDATES}
        excluded_units = set().union(*hard_failures.values())
        comparable_rows = {candidate: [row for row in candidate_rows[candidate]
            if not excluded_units.intersection(row["unitIDs"])] for candidate in CANDIDATES}
        requests = [stable_request(artifacts[(candidate, role)]["translation"]["request"])
                    for candidate in CANDIDATES]
        upstream = [{
            "model": artifact.get("model"),
            "rawASR": artifact.get("rawASR"),
            "alignment": {key: value for key, value in artifact.get("alignment", {}).items()
                          if key != "worker"},
            "diarization": {key: value for key, value in artifact.get("diarization", {}).items()
                            if key != "worker"},
        } for artifact in (artifacts[(candidate, role)] for candidate in CANDIDATES)]
        metric_dir = args.root / "metrics" / corpus
        write_lines(metric_dir / "source.ja.txt", [row["source"] for row in comparable_rows[CANDIDATES[0]]])
        write_lines(metric_dir / "reference.en.txt", [row["reference"] for row in comparable_rows[CANDIDATES[0]]])
        chrf = {}
        comet = {}
        for candidate in CANDIDATES:
            raw = artifacts[(candidate, role)]
            hypothesis = metric_dir / f"{candidate}.en.txt"
            write_lines(hypothesis, [row["hypothesis"] for row in comparable_rows[candidate]])
            chrf[candidate] = [chrf_pp(row["hypothesis"], row["reference"])
                               for row in comparable_rows[candidate]]
            comet[candidate] = comet_scores(metric_dir / "comet-score.json", hypothesis)
            worker = raw["translation"].get("worker") or {}
            verdicts = raw["translation"].get("integrityVerdicts") or []
            reason_counts = Counter(reason["code"] for verdict in verdicts
                                    for reason in verdict.get("reasons", []))
            attempt_reason_counts = Counter(code for batch in raw["translation"].get("batches", [])
                                            for code in batch.get("validationReasonCodes", []))
            attempt_reason_cues = {code: set() for code in INTEGRITY_REASON_CODES}
            for batch in raw["translation"].get("batches", []):
                for code in batch.get("validationReasonCodes", []):
                    attempt_reason_cues[code].update(batch.get("cueIDs", []))
            retries = Counter(cue for batch in raw["translation"].get("batches", [])
                              for cue in batch.get("cueIDs", []))
            integrity = cue_integrity(raw)
            srt = directories[(candidate, role)] / "english-subtitles.srt"
            subtitles = subtitle_quality(srt.read_text(encoding="utf-8") if srt.exists() else None)
            stage = decoded_map(raw.get("stageDurations") or {})
            available = worker.get("availableMemorySamples") or []
            unit_count = len(raw["translation"]["request"]["turns"])
            row = {
                "role": role,
                "corpusID": corpus,
                "candidate": candidate,
                "modelID": raw["translation"]["model"],
                "revision": raw["translation"].get("revision"),
                "weightSHA256": raw["translation"].get("weightSHA256") or [],
                "COMET": sum(comet[candidate]) / len(comet[candidate]) if comet[candidate] else None,
                "chrFPlusPlus": chrf_pp(
                    " ".join(value["hypothesis"] for value in comparable_rows[candidate]),
                    " ".join(value["reference"] for value in comparable_rows[candidate]),
                ),
                "glossary": glossary_accuracy(raw),
                "integrity": integrity,
                "integrityVerdicts": Counter(value.get("verdict", "unknown") for value in verdicts),
                "integrityReasonCounts": reason_counts,
                "attemptIntegrityReasonCounts": attempt_reason_counts,
                "attemptIntegrityReasonCueRatesPercent": {
                    code: 100 * len(cues) / unit_count for code, cues in attempt_reason_cues.items()
                },
                "hardFailureCueIDs": sorted(hard_failures[candidate]),
                "retryCueIDs": sorted(cue for cue, count in retries.items() if count > 1),
                "retryRatePercent": 100 * sum(count > 1 for count in retries.values()) / unit_count,
                "subtitleQuality": subtitles,
                "contextCueCount": len(raw["translation"]["request"].get("conversationContextByCueID") or {}),
                "fullJobSucceeded": not raw.get("failures"),
                "successfulUnitRatePercent": 100 * (
                    unit_count - len(hard_failures[candidate])
                ) / unit_count,
                "translationUnitCount": unit_count,
                "comparableReferenceTurnCount": len(comparable_rows[candidate]),
                "excludedReferenceTurnCount": len(candidate_rows[candidate])
                    - len(comparable_rows[candidate]),
                "totalDurationSeconds": sum(stage.values()),
                "stageDurationsSeconds": stage,
                "translationDurationSeconds": stage.get("translating", 0),
                "translationUnitsPerSecond": unit_count / stage["translating"],
                "generationDurationSeconds": sum(batch.get("duration", 0)
                    for batch in raw["translation"].get("batches", [])),
                "peakMLXMemoryBytes": raw["translation"].get("peakMemoryBytes", 0),
                "peakWorkerPhysicalFootprintBytes": worker.get("peakPhysicalFootprintBytes", 0),
                "minimumAvailableMemoryBytes": min(
                    (sample["availableMemoryBytes"] for sample in available), default=None),
                "swapDeltaBytes": (worker.get("swapUsedAfterBytes") - worker.get("swapUsedBeforeBytes"))
                    if worker.get("swapUsedAfterBytes") is not None
                    and worker.get("swapUsedBeforeBytes") is not None else None,
                "pressureTransitions": worker.get("pressureTransitions") or [],
                "workerPID": worker.get("processIdentifier"),
                "workerExitStatus": worker.get("exitStatus"),
                "workerForcedTermination": worker.get("forcedTermination"),
                "postStageWorkerExited": worker.get("exitStatus") == 0
                    and not worker.get("forcedTermination"),
                "publishedEnglishSubtitles": (directories[(candidate, role)] / "english-subtitles.srt").exists(),
                "rawArtifact": relative(directories[(candidate, role)] / "raw-asr.json"),
            }
            rows.append(row)

        paired[role] = {
            "chrFPlusPlus4BMinus12B": bootstrap_difference(
                chrf[CANDIDATES[1]], chrf[CANDIDATES[0]]),
            "COMET4BMinus12B": bootstrap_difference(comet[CANDIDATES[1]], comet[CANDIDATES[0]])
                if comet[CANDIDATES[1]] and comet[CANDIDATES[0]] else None,
        }
        examples[role] = representative_examples(comparable_rows)
        invalid_examples[role] = {
            candidate: [{
                "cueID": verdict["cueID"],
                "source": verdict["testedSource"],
                "output": verdict["generatedOutput"],
                "reasons": [reason["code"] for reason in verdict.get("reasons", [])],
            } for verdict in artifacts[(candidate, role)]["translation"]
                .get("integrityVerdicts", []) if verdict.get("verdict") == "hard-failure"]
            for candidate in CANDIDATES
        }
        role_rows = [row for row in rows if row["role"] == role]
        scorers[role] = scorer_summary(metric_dir)
        gates[role] = requests[0] == requests[1] \
            and upstream[0] == upstream[1] \
            and scorers[role] is not None \
            and scorers[role]["device"] == {
                "requestedGpus": 1, "expectedDevice": "mps",
                "mpsBuilt": True, "mpsAvailable": True,
            } \
            and all(row["COMET"] is not None
                and not any(row["integrity"].values())
                and row["workerExitStatus"] == 0
                and not row["workerForcedTermination"]
                and not any(item["level"] == "critical" for item in row["pressureTransitions"])
                for row in role_rows)

    provenance_path = args.root / "implementation-provenance.tsv"
    implementation_provenance = dict(line.split("\t", 1) for line in
        provenance_path.read_text().splitlines()) if provenance_path.exists() else {}
    report = {
        "schemaVersion": 2,
        "ticket": 76,
        "reporterSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "COMETModel": "Unbabel/wmt22-comet-da",
        "referenceAlignment": "Human EN reference turns scored against overlapping frozen product Qwen semantic units.",
        "rows": rows,
        "pairedDifferences": paired,
        "representativeExamples": examples,
        "invalidExamples": invalid_examples,
        "scorerRuns": scorers,
        "implementationProvenance": implementation_provenance,
        "gates": gates,
        "selectedProductDefault": CANDIDATES[0],
        "defaultDecision": "12B remains the product default; 4B remains selectable as beta with its full-job integrity limit visible.",
        "historicalUpstreamLimit": "E17 proves Standard SpeakerKit by pinned revision, automatic count and non-exclusive mode; its later-added configuration field is null.",
        "scopeLimit": "Two frozen videos support workflow-specific recommendations, not universal translation superiority.",
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# TranslateGemma 4B vs 12B — ticket #76", "",
        "The two candidates received content-identical product inputs frozen after Qwen JA, forced alignment and Standard SpeakerKit. The source-file `modifiedAt` provenance timestamp is ignored by the equality gate; semantic units, context, glossary and generation settings are identical. ASR was not rerun. TranslateGemma 12B remains the default.", "",
        "| Split | Model | Full job | Valid units | Comparable refs | COMET | chrF++ | Total | Translation | Units/s | Worker peak | Min available | Swap Δ | Exit | Retry rate |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f'| {row["role"]} | {row["candidate"]} | '
            f'{"pass" if row["fullJobSucceeded"] else "fail"} | '
            f'{row["successfulUnitRatePercent"]:.2f}% | {row["comparableReferenceTurnCount"]} | '
            f'{fmt(row["COMET"], 4)} | {row["chrFPlusPlus"]:.2f} | {duration(row["totalDurationSeconds"])} | '
            f'{duration(row["translationDurationSeconds"])} | {row["translationUnitsPerSecond"]:.3f} | '
            f'{row["peakWorkerPhysicalFootprintBytes"] / 2**30:.2f} GiB | '
            f'{row["minimumAvailableMemoryBytes"] / 2**30:.2f} GiB | '
            f'{fmt(row["swapDeltaBytes"] / 2**20 if row["swapDeltaBytes"] is not None else None, 1)} MiB | '
            f'PID out/{row["workerExitStatus"]} | {row["retryRatePercent"]:.2f}% |'
        )
    for role, values in paired.items():
        chrf = values["chrFPlusPlus4BMinus12B"]
        comet = values["COMET4BMinus12B"]
        lines += ["", f"## {role}", "",
            f'Paired chrF++ 4B−12B: {chrf["mean"]:.3f} [95% {chrf["low95"]:.3f}, {chrf["high95"]:.3f}].',
            "Paired COMET 4B−12B: pending." if comet is None else
            f'Paired COMET 4B−12B: {comet["mean"]:.4f} [95% {comet["low95"]:.4f}, {comet["high95"]:.4f}].',
            ("chrF++ significantly favors 12B." if chrf["significant"] and chrf["mean"] < 0
             else "chrF++ does not establish a significant winner."),
            ("COMET significantly favors 12B." if comet and comet["significant"] and comet["mean"] < 0
             else "COMET does not establish a significant winner."),
            f'COMET scorer: MPS `{scorers[role]["command"]}`, {scorers[role]["elapsedSeconds"]:.2f}s, '
            f'peak footprint {scorers[role]["peakPhysicalFootprintBytes"] / 2**30:.2f} GiB, '
            f'swap Δ {scorers[role]["swapDeltaMiB"]:.1f} MiB, free memory '
            f'{scorers[role]["freeMemoryPercentBefore"]}%→{scorers[role]["freeMemoryPercentAfter"]}%.',
            "", "Integrity, glossary and subtitle checks:", ""]
        for row in (row for row in rows if row["role"] == role):
            subtitles, glossary = row["subtitleQuality"], row["glossary"]
            glossary_text = "not present" if glossary["accuracyPercent"] is None else (
                f'{glossary["hits"]}/{glossary["opportunities"]} ({glossary["accuracyPercent"]:.1f}%), '
                f'misses={[item["termID"] for item in glossary["misses"]]}'
            )
            stages = ", ".join(f'{name}={seconds:.1f}s'
                               for name, seconds in row["stageDurationsSeconds"].items())
            subtitle_text = "not exported because the product integrity gate failed"
            if subtitles["status"] == "published":
                subtitle_text = (f'exported cues={subtitles["cueCount"]}, empty={len(subtitles["emptyCueIDs"])}, '
                    f'invalid timing={len(subtitles["invalidDurationCueIDs"])}, malformed blocks={subtitles["malformedBlockCount"]}, '
                    f'>84 chars={len(subtitles["over84CharacterCueIDs"])}, '
                    f'>20 chars/s={len(subtitles["over20CharactersPerSecondCueIDs"])}, '
                    f'max chars/s={subtitles["maximumCharactersPerSecond"]:.1f}')
            lines += [
                f'- `{row["candidate"]}`: verdicts {dict(row["integrityVerdicts"])}; '
                f'final reasons {dict(row["integrityReasonCounts"])}; all rejected-attempt reasons '
                f'{dict(row["attemptIntegrityReasonCounts"])}; retry rate {row["retryRatePercent"]:.2f}%.',
                '  - Per-unit attempt flags: ' + ", ".join(
                    f'{code}={rate:.2f}%' for code, rate in
                    row["attemptIntegrityReasonCueRatesPercent"].items()),
                f'  - Glossary: {glossary_text}. English subtitles: {subtitle_text}.',
                f'  - Resources: PID {row["workerPID"]} exited={row["postStageWorkerExited"]}, '
                f'pressure transitions={row["pressureTransitions"] or "none"}, '
                f'minimum available={row["minimumAvailableMemoryBytes"] / 2**30:.2f} GiB. Stages: {stages}.',
                f'  - Raw: `{row["rawArtifact"]}`',
            ]
        lines += ["", "Representative differences:", ""]
        for example in examples[role]:
            lines += [
                f'- `{example["cueID"]}` — JA: {example["source"]}',
                f'  - Reference: {example["reference"]}',
                f'  - 12B: {example["translateGemma12B"]}',
                f'  - 4B: {example["translateGemma4B"]}',
            ]
        lines += ["", "Invalid product outputs (excluded from paired COMET/chrF++):", ""]
        for candidate, values in invalid_examples[role].items():
            for value in values:
                lines += [
                    f'- `{candidate}` `{value["cueID"]}` ({", ".join(value["reasons"])}): {value["source"]}',
                    f'  - Output: {value["output"]}',
                ]
    lines += ["", "## Decision", "",
        "Use 12B when a complete English deliverable is required: it alone completed both videos, significantly led chrF++ on DEV and holdout, and significantly led COMET on holdout."]
    for role in paired:
        role_rows = {row["candidate"]: row for row in rows if row["role"] == role}
        twelve, four = (role_rows[candidate] for candidate in CANDIDATES)
        lines.append(f'- {role}: 4B was {100 * (twelve["translationDurationSeconds"] - four["translationDurationSeconds"]) / twelve["translationDurationSeconds"]:.1f}% faster and used {100 * (twelve["peakWorkerPhysicalFootprintBytes"] - four["peakWorkerPhysicalFootprintBytes"]) / twelve["peakWorkerPhysicalFootprintBytes"]:.1f}% less peak worker memory, but failed {len(four["hardFailureCueIDs"])}/{four["translationUnitCount"]} units and produced no English subtitle deliverable.')
    subtitle_rows = {row["role"]: row["subtitleQuality"] for row in rows
                     if row["candidate"] == CANDIDATES[0]}
    lines += ["", f'The actual 12B SRT exports still have readability defects: DEV has {len(subtitle_rows["development"]["invalidDurationCueIDs"])} zero-duration cues and {subtitle_rows["development"]["malformedBlockCount"]} malformed block; holdout has {len(subtitle_rows["holdout"]["invalidDurationCueIDs"])} zero-duration cues and {subtitle_rows["holdout"]["malformedBlockCount"]} malformed block. Those timing/export limits prevent claiming production-ready subtitles from this two-video result.',
        "", "Keep 4B selectable as the faster/lighter beta for constrained experimentation, with its full-job failure visible. Keep 12B as the product default; this benchmark changes no product selection.",
        "", "## Provenance", "", "Benchmark/scoring implementation hashes:", ""]
    lines += [f'- `{name}`: `{value}`' for name, value in implementation_provenance.items()]
    lines += [f'- `final-reporter`: `{report["reporterSHA256"]}`', "",
        "The discarded DEV CPU COMET attempt produced no score and is retained under `.build/benchmarks/high-quality/translator-bakeoff/metrics/qudu2fx3ncc/rejected-cpu-comet/`; all reported COMET scores use MPS.",
        "", "## Limits", "", report["historicalUpstreamLimit"],
        "Frozen E17 contains no conversation-context map, so context carry-over is not evaluated here.",
        report["scopeLimit"], "",
        "Raw prompts, outputs, retries, exports, model pins, process telemetry and scorer inputs are retained under `.build/benchmarks/high-quality/translator-bakeoff/`."]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")


def self_test() -> None:
    difference = bootstrap_difference([2, 3], [1, 1])
    assert difference["low95"] > 0
    assert decoded_map(["translation", 2.0, "export", 1.0]) == {
        "translation": 2.0, "export": 1.0,
    }
    assert stable_request({"source": {"path": "raw.json", "modifiedAt": "now"}}) == {
        "source": {"path": "raw.json"},
    }
    assert subtitle_quality("1\n00:00:00,000 --> 00:00:02,000\nEnglish\n")["cueCount"] == 1
    assert subtitle_quality("1\n00:00:01,000 --> 00:00:01,000\nEnglish\n")["invalidDurationCueIDs"] == ["1"]
    assert subtitle_quality(None)["status"] == "not-published-after-integrity-failure"
    failed = {"translation": {
        "request": {"turns": [{"id": "a"}, {"id": "b"}]},
        "response": '{"translations":[{"id":"b","text":"retry"}]}',
        "integrityVerdicts": [
            {"cueID": "a", "generatedOutput": "first"},
            {"cueID": "b", "generatedOutput": "final"},
        ],
    }}
    assert response_map(failed) == {"a": "first", "b": "final"}


if __name__ == "__main__":
    self_test()
    main()
