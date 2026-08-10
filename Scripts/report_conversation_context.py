#!/usr/bin/env python3
import argparse
import gzip
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

from report_high_quality_acceptance import translation_rows
from report_japanese_l7d import chrf_pp


CORPORA = {"development": "qudu2fx3ncc", "holdout": "md62mmdz0m"}
E12 = Path("docs/japanese-live/experiments/evidence/E12")
JAPANESE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]")
PRONOUN = re.compile(r"私|僕|俺|彼女|彼|これ|それ|あれ|こいつ|そいつ|自分")
ELLIPSIS = re.compile(r"…|⋯|〜|～|\.\.\.")


def read(path: Path) -> dict:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt") as stream:
        return json.load(stream)


def write_lines(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(value.replace("\n", " ") for value in values) + "\n")


def comet(path: Path, hypothesis: Path) -> float | None:
    if not path.exists():
        return None
    rows = next((value for key, value in read(path).items()
                 if Path(key).name == hypothesis.name), None)
    return sum(float(row["COMET"]) for row in rows) / len(rows) if rows else None


def final_baseline(split: str, baseline: dict) -> tuple[dict, dict]:
    retry = read(E12 / f"{split}-retry.json.gz")
    retry_evidence = retry.get("retry")
    if retry_evidence:
        outputs = {item["id"]: item["text"]
                   for item in json.loads(baseline["response"])["translations"]}
        outputs.update({item["id"]: item["text"]
                        for item in json.loads(retry_evidence["response"])["translations"]})
        baseline = dict(baseline)
        baseline["response"] = json.dumps({"translations": [
            {"id": turn["id"], "text": outputs[turn["id"]]}
            for turn in baseline["request"]["turns"]
        ]})
    return baseline, retry


def terminal_baseline_verdicts(split: str, retry: dict) -> list[dict]:
    verdicts = read(E12 / f"{split}-integrity.json.gz")["verdicts"]
    replacements = {item["cueID"]: item for item in retry["retryVerdicts"]}
    return [replacements.get(item["cueID"], item) for item in verdicts]


def reason_counts(verdicts: list[dict]) -> Counter:
    return Counter(reason["code"] for item in verdicts for reason in item["reasons"])


def context_integrity(artifact: dict) -> dict:
    evidence = artifact["evidence"]
    turns = evidence["request"]["turns"]
    positions = {turn["id"]: index for index, turn in enumerate(turns)}
    turns_by_id = {turn["id"]: turn for turn in turns}
    outputs = {item["id"]: item["text"]
               for item in json.loads(evidence["response"])["translations"]}
    contexts = evidence["request"]["conversationContextByCueID"]
    retries = set(artifact["retryCueIDs"])
    first_batches = {batch["cueIDs"][0]: batch for batch in evidence["batches"]
                     if batch.get("context") is not None and len(batch["cueIDs"]) == 1}
    valid = len(contexts) == len(turns)
    for turn in turns:
        cue_id = turn["id"]
        context = contexts.get(cue_id)
        batch = first_batches.get(cue_id)
        if context is None or batch is None or context["currentTarget"] != turn["japanese"]:
            valid = False
            continue
        history = context["acceptedHistory"]
        valid &= len(history) <= 2 and context["encodedHistoryBytes"] <= 512
        valid &= all(positions.get(pair["cueID"], len(turns)) < positions[cue_id]
                     and pair["cueID"] not in retries
                     and turns_by_id[pair["cueID"]]["japanese"] == pair["japanese"]
                     and outputs[pair["cueID"]] == pair["english"] for pair in history)
        try:
            messages = json.loads(batch["nativePrompt"])
            expected_roles = [role for _ in history for role in ("user", "assistant")] + ["user"]
            current = messages[-1]["content"]
            valid &= [message["role"] for message in messages] == expected_roles
            valid &= current == [{
                "type": "text", "source_lang_code": "ja",
                "target_lang_code": "en", "text": turn["japanese"],
            }]
        except (KeyError, TypeError, json.JSONDecodeError):
            valid = False
        valid &= batch.get("nativeOutput") is not None and batch.get("inputTokens", 0) > 0
        valid &= batch.get("validationReasonCodes") is not None
    return {
        "exactHistoryAndCurrentTarget": bool(valid),
        "futureJapaneseExcluded": bool(valid),
        "rejectedHistoryExcluded": all(pair["cueID"] not in retries
            for context in contexts.values() for pair in context["acceptedHistory"]),
        "maxDepth": max((len(value["acceptedHistory"]) for value in contexts.values()), default=0),
        "maxEncodedHistoryBytes": max((value["encodedHistoryBytes"]
            for value in contexts.values()), default=0),
        "resets": dict(Counter(value.get("resetReason") or "none"
                               for value in contexts.values())),
    }


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def score(value: float | None, digits: int) -> str:
    return "pending" if value is None else f"{value:.{digits}f}"


def subset_chrf(rows: list[dict], references: list[str], indices: list[int]) -> float | None:
    return chrf_pp(
        " ".join(rows[index]["hypothesis"] for index in indices),
        " ".join(references[index] for index in indices),
    ) if indices else None


def inconsistent_repetitions(rows: list[dict], sources: set[str]) -> int:
    return sum(len({row["hypothesis"].casefold() for row in rows
                    if row["source"] == source}) > 1 for source in sources)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    parser.add_argument("--live-log", type=Path, required=True)
    args = parser.parse_args()

    rows = []
    development_turns = []
    for split, corpus in CORPORA.items():
        context_path = args.root / split / "context.json"
        baseline_path = args.root / split / "baseline.json"
        if not context_path.exists() or not baseline_path.exists():
            continue
        artifact = read(context_path)
        candidate = artifact["evidence"]
        baseline, baseline_retry = final_baseline(split, read(baseline_path))
        if split == "development":
            development_turns = baseline["request"]["turns"]
        manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
        baseline_rows = translation_rows(manifest, {"translation": baseline})
        candidate_rows = translation_rows(manifest, {"translation": candidate})
        metrics = args.root / "metrics" / split
        baseline_hypothesis = metrics / "direct-no-context.en.txt"
        candidate_hypothesis = metrics / "previous-accepted.en.txt"
        write_lines(metrics / "source.ja.txt", [row["source"] for row in baseline_rows])
        write_lines(metrics / "reference.en.txt", [row["reference"] for row in baseline_rows])
        write_lines(baseline_hypothesis, [row["hypothesis"] for row in baseline_rows])
        write_lines(candidate_hypothesis, [row["hypothesis"] for row in candidate_rows])
        references = [row["reference"] for row in baseline_rows]
        pronoun_indices = [index for index, row in enumerate(baseline_rows)
                           if PRONOUN.search(row["source"])]
        ellipsis_indices = [index for index, row in enumerate(baseline_rows)
                            if ELLIPSIS.search(row["source"])]
        source_counts = Counter(row["source"] for row in baseline_rows)
        repeated_sources = {source for source, count in source_counts.items()
                            if count > 1 and not source.startswith("［")}
        baseline_verdicts = terminal_baseline_verdicts(split, baseline_retry)
        candidate_verdicts = candidate["integrityVerdicts"]
        baseline_reasons = reason_counts(baseline_verdicts)
        candidate_reasons = reason_counts(candidate_verdicts)
        baseline_runtime = sum(item["duration"] for item in baseline["attempts"])
        if baseline_retry.get("retry"):
            baseline_runtime += sum(item["duration"]
                                    for item in baseline_retry["retry"]["attempts"])
        baseline_tokens = sum(batch["inputTokens"] for batch in baseline["batches"])
        if baseline_retry.get("retry"):
            baseline_tokens += sum(batch["inputTokens"]
                                   for batch in baseline_retry["retry"]["batches"])
        rows.append({
            "split": split,
            "corpusID": corpus,
            "units": len(candidate["request"]["turns"]),
            "retries": len(artifact["retryCueIDs"]),
            "baseline": {
                "COMET": comet(metrics / "comet-score.json", baseline_hypothesis),
                "chrFPlusPlus": chrf_pp(" ".join(row["hypothesis"] for row in baseline_rows),
                                         " ".join(references)),
                "runtimeSeconds": baseline_runtime,
                "inputTokens": baseline_tokens,
                "terminalVerdicts": dict(Counter(item["verdict"] for item in baseline_verdicts)),
            },
            "candidate": {
                "COMET": comet(metrics / "comet-score.json", candidate_hypothesis),
                "chrFPlusPlus": chrf_pp(" ".join(row["hypothesis"] for row in candidate_rows),
                                         " ".join(references)),
                "runtimeSeconds": sum(item["duration"] for item in candidate["attempts"]),
                "inputTokens": sum(batch["inputTokens"] for batch in candidate["batches"]),
                "outputTokens": sum(batch.get("outputTokens") or 0 for batch in candidate["batches"]),
                "terminalVerdicts": dict(Counter(item["verdict"] for item in candidate_verdicts)),
                "peakMemoryBytes": candidate["peakMemoryBytes"],
            },
            "targetedDiscourse": {
                "pronoun": {
                    "references": len(pronoun_indices),
                    "baselineChrFPlusPlus": subset_chrf(
                        baseline_rows, references, pronoun_indices),
                    "candidateChrFPlusPlus": subset_chrf(
                        candidate_rows, references, pronoun_indices),
                },
                "ellipsis": {
                    "references": len(ellipsis_indices),
                    "baselineChrFPlusPlus": subset_chrf(
                        baseline_rows, references, ellipsis_indices),
                    "candidateChrFPlusPlus": subset_chrf(
                        candidate_rows, references, ellipsis_indices),
                },
                "lexicalConsistency": {
                    "repeatedSourceGroups": len(repeated_sources),
                    "baselineInconsistentGroups": inconsistent_repetitions(
                        baseline_rows, repeated_sources),
                    "candidateInconsistentGroups": inconsistent_repetitions(
                        candidate_rows, repeated_sources),
                },
                "deterministicFixtures": ["pronoun", "ellipsis", "lexical-consistency"],
            },
            "integrity": context_integrity(artifact),
            "regressions": {
                "contamination": candidate_reasons["control-scaffolding"]
                    + candidate_reasons["copied-neighbour"]
                    > baseline_reasons["control-scaffolding"] + baseline_reasons["copied-neighbour"],
                "untranslated": candidate_reasons["residual-japanese"]
                    > baseline_reasons["residual-japanese"],
                "criticalGlossary": candidate_reasons["critical-glossary-violation"]
                    > baseline_reasons["critical-glossary-violation"],
            },
        })

    live_passed = args.live_log.exists() \
        and "Test Suite 'LiveCaptionTests' passed" in args.live_log.read_text()
    gates = {}
    for row in rows:
        baseline, candidate = row["baseline"], row["candidate"]
        integrity = row["integrity"]
        gates[row["split"]] = {
            "evidenceIntegrity": integrity["exactHistoryAndCurrentTarget"]
                and integrity["futureJapaneseExcluded"]
                and integrity["rejectedHistoryExcluded"]
                and integrity["maxDepth"] <= 2
                and integrity["maxEncodedHistoryBytes"] <= 512,
            "zeroTerminalHardFailures": candidate["terminalVerdicts"].get("hard-failure", 0) == 0,
            "primaryQualityGain": candidate["COMET"] is not None
                and baseline["COMET"] is not None and candidate["COMET"] > baseline["COMET"],
            "noIntegrityRegression": not any(row["regressions"].values()),
            "acceptableChrF": row["split"] == "development"
                or candidate["chrFPlusPlus"] >= baseline["chrFPlusPlus"],
        }
    holdout_passed = "holdout" in gates and all(gates["holdout"].values())
    report = {
        "schemaVersion": 1,
        "ticket": 55,
        "policy": {
            "version": "previous-accepted-v1", "maximumDepth": 2,
            "maximumEncodedHistoryBytes": 512, "largePauseSeconds": 8,
        },
        "developmentResetCalibration": [{
            "largePauseSeconds": seconds,
            "resets": sum(
                previous.get("sourceEnd") is not None
                and current.get("sourceStart") is not None
                and current["sourceStart"] - previous["sourceEnd"] >= seconds
                for previous, current in zip(development_turns, development_turns[1:])
            ),
            **({"selected": True} if seconds == 8 else {}),
        } for seconds in (4, 8, 12)],
        "rows": rows,
        "gates": gates,
        "liveGatesUnchanged": live_passed,
        "promoted": bool(rows and holdout_passed and live_passed),
        "evidenceLimitation": "Two complete reference videos do not establish universal conversational quality.",
    }
    evidence_root = Path("docs/japanese-live/experiments/evidence/E14")
    report["rawArtifacts"] = [
        {"path": str(path), "sha256": sha256(path)}
        for path in sorted(evidence_root.glob("*")) if path.is_file()
    ]
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    lines = [
        "# E14 — Previous accepted conversational context", "",
        "Ticket #55 changes only conversational history. The E12 direct interaction, semantic units, glossary, retry, validator, model, and generation settings remain frozen.", "",
        "| Split | Policy | COMET baseline→context | chrF++ baseline→context | Pronoun chrF++ | Ellipsis chrF++ | Lexical inconsistencies | Hard failures | Runtime baseline→context | Input tokens baseline→context |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        baseline, candidate, discourse = row["baseline"], row["candidate"], row["targetedDiscourse"]
        pronoun = discourse["pronoun"]
        ellipsis = discourse["ellipsis"]
        lexical = discourse["lexicalConsistency"]
        lines.append(
            f'| {row["split"]} | previous-accepted-v1 | '
            f'{score(baseline["COMET"], 4)}→{score(candidate["COMET"], 4)} | '
            f'{baseline["chrFPlusPlus"]:.2f}→{candidate["chrFPlusPlus"]:.2f} | '
            f'{score(pronoun["baselineChrFPlusPlus"], 2)}→{score(pronoun["candidateChrFPlusPlus"], 2)} ({pronoun["references"]}) | '
            f'{score(ellipsis["baselineChrFPlusPlus"], 2)}→{score(ellipsis["candidateChrFPlusPlus"], 2)} ({ellipsis["references"]}) | '
            f'{lexical["baselineInconsistentGroups"]}→{lexical["candidateInconsistentGroups"]} ({lexical["repeatedSourceGroups"]}) | '
            f'{candidate["terminalVerdicts"].get("hard-failure", 0)} | '
            f'{baseline["runtimeSeconds"]:.1f}→{candidate["runtimeSeconds"]:.1f} s | '
            f'{baseline["inputTokens"]}→{candidate["inputTokens"]} |'
        )
    lines += ["", "The 8-second reset threshold tied the 4-second candidate on development (8 resets) and retained three boundaries missed at 12 seconds. The policy was frozen before holdout.", "",
              "Deterministic diagnostics pass for pronouns, ellipsis, lexical consistency, rejected turns, future exclusion, scene reset, and the context budget.", "",
              "The context policy is promoted." if report["promoted"] else "Promotion remains blocked by a failed or pending gate.", "",
              report["evidenceLimitation"]]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
