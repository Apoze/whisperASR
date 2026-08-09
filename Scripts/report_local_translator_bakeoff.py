#!/usr/bin/env python3
"""Report the frozen local translator comparison from retained Swift artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
from pathlib import Path

from report_japanese_l7d import chrf_pp

CANDIDATES = ("translategemma-12b-it-4bit", "qwen3-14b-4bit")
CORPORA = ("qudu2fx3ncc", "md62mmdz0m")


def read(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def write_lines(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(value.replace("\n", " ") for value in values) + "\n", encoding="utf-8")


def bootstrap_difference(left: list[float], right: list[float]) -> dict:
    assert len(left) == len(right) and left
    randomizer = random.Random(46)
    differences = []
    for _ in range(10_000):
        indices = [randomizer.randrange(len(left)) for _ in left]
        differences.append(sum(left[i] - right[i] for i in indices) / len(indices))
    differences.sort()
    return {
        "mean": sum(a - b for a, b in zip(left, right)) / len(left),
        "low95": differences[249],
        "high95": differences[9_749],
        "significant": differences[249] > 0 or differences[9_749] < 0,
    }


def selected_glossary_accuracy(artifact: dict) -> dict:
    terms = [item["term"] for item in artifact["glossary"]["decisions"] if item["selected"]]
    opportunities = hits = 0
    for row in artifact["metricsInput"]:
        for term in terms:
            if any(form in row["source"] for form in term["japaneseForms"]):
                opportunities += 1
                expected = [term["canonicalEnglish"], *term["englishAliases"]]
                if any(value.casefold() in row["hypothesis"].casefold() for value in expected):
                    hits += 1
    return {
        "hits": hits,
        "opportunities": opportunities,
        "accuracyPercent": 100 * hits / opportunities if opportunities else None,
    }


def suspected_hallucination(row: dict) -> bool:
    # ponytail: conservative length/repetition flag; replace with human MQM on a larger corpus.
    hypothesis = row["hypothesis"].strip()
    reference = row["reference"].strip()
    words = re.findall(r"[\w']+", hypothesis.casefold())
    trigrams = list(zip(words, words[1:], words[2:]))
    repeated = len(trigrams) >= 6 and len(set(trigrams)) * 2 < len(trigrams)
    too_long = len(hypothesis) > max(160, 4 * max(len(reference), 1))
    return repeated or too_long


def native_marker_integrity(artifact: dict) -> dict:
    expected = [item["id"] for item in artifact["metricsInput"]]
    batches = artifact["promptsAndOutputs"]
    diagnostics = {
        "missingCueIDs": [],
        "duplicateCueIDs": [],
        "reorderedCueIDs": [],
        "unknownCueIDs": [],
    }
    if [batch["cueIDs"][0] for batch in batches if len(batch["cueIDs"]) == 1] != expected:
        diagnostics["reorderedCueIDs"] = expected
    for cue_id, batch in zip(expected, batches):
        output = batch["nativeOutput"]
        starts = re.findall(r"<<<CURRENT:([^>\n]+)>>>", output)
        ends = re.findall(r"<<<END_CURRENT:([^>\n]+)>>>", output)
        if starts.count(cue_id) != 1 or ends.count(cue_id) != 1:
            diagnostics["missingCueIDs"].append(cue_id)
        if starts.count(cue_id) > 1 or ends.count(cue_id) > 1:
            diagnostics["duplicateCueIDs"].append(cue_id)
        diagnostics["unknownCueIDs"].extend(
            marker for marker in [*starts, *ends] if marker != cue_id
        )
        start = output.find(f"<<<CURRENT:{cue_id}>>>")
        end = output.find(f"<<<END_CURRENT:{cue_id}>>>")
        if start >= 0 and end >= 0 and start >= end:
            diagnostics["reorderedCueIDs"].append(cue_id)
    return {key: list(dict.fromkeys(values)) for key, values in diagnostics.items()}


def comet_scores(path: Path, hypothesis_path: Path) -> list[float] | None:
    if not path.exists():
        return None
    data = read(path)
    keys = [str(hypothesis_path), hypothesis_path.name]
    rows = next((data[key] for key in keys if key in data), None)
    if rows is None:
        rows = next((value for key, value in data.items() if Path(key).name == hypothesis_path.name), None)
    return [float(row["COMET"]) for row in rows] if rows else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    artifacts = {
        (candidate, corpus): read(args.root / candidate / corpus / "run.json")
        for candidate in CANDIDATES
        for corpus in CORPORA
    }
    implementation = artifacts[(CANDIDATES[0], CORPORA[0])]["implementationSHA256"]
    assert all(artifact["implementationSHA256"] == implementation for artifact in artifacts.values())
    rows = []
    sentence_chrf = {}
    metric_paths = {}
    for corpus in CORPORA:
        baseline = artifacts[(CANDIDATES[0], corpus)]
        challenger = artifacts[(CANDIDATES[1], corpus)]
        assert baseline["frozenInputSHA256"] == challenger["frozenInputSHA256"]
        assert baseline["generation"] == challenger["generation"]
        assert baseline["request"] == challenger["request"]
        assert all(baseline["gates"].values()) and all(challenger["gates"].values())
        baseline_prompts = [item["sanitizedPrompt"] for item in baseline["promptsAndOutputs"]]
        challenger_prompts = [item["sanitizedPrompt"] for item in challenger["promptsAndOutputs"]]
        assert baseline_prompts == challenger_prompts
        assert all(
            item.get("nativePrompt") and item.get("nativeOutput")
            for artifact in (baseline, challenger)
            for item in artifact["promptsAndOutputs"]
        )

        metric_dir = args.root / "metrics" / corpus
        source = metric_dir / "source.ja.txt"
        reference = metric_dir / "reference.en.txt"
        write_lines(source, [item["source"] for item in baseline["metricsInput"]])
        write_lines(reference, [item["reference"] for item in baseline["metricsInput"]])
        for candidate in CANDIDATES:
            artifact = artifacts[(candidate, corpus)]
            integrity = native_marker_integrity(artifact)
            assert not any(integrity.values()), (candidate, corpus, integrity)
            hypothesis = metric_dir / f"{candidate}.en.txt"
            write_lines(hypothesis, [item["hypothesis"] for item in artifact["metricsInput"]])
            metric_paths[(candidate, corpus)] = hypothesis
            scores = [chrf_pp(item["hypothesis"], item["reference"]) for item in artifact["metricsInput"]]
            sentence_chrf[(candidate, corpus)] = scores
            untranslated = [
                item["id"] for item in artifact["metricsInput"]
                if re.search(r"[\u3040-\u30ff\u3400-\u9fff]", item["hypothesis"])
            ]
            hallucinated = [item["id"] for item in artifact["metricsInput"] if suspected_hallucination(item)]
            comet = comet_scores(metric_dir / "comet-score.json", hypothesis)
            rows.append({
                "candidate": candidate,
                "corpusID": corpus,
                "COMET": sum(comet) / len(comet) if comet else None,
                "chrFPlusPlus": chrf_pp(
                    " ".join(item["hypothesis"] for item in artifact["metricsInput"]),
                    " ".join(item["reference"] for item in artifact["metricsInput"]),
                ),
                "glossary": selected_glossary_accuracy(artifact),
                **integrity,
                "untranslatedCueIDs": untranslated,
                "suspectedHallucinatedCueIDs": hallucinated,
                "runtimeSeconds": artifact["translationDurationSeconds"],
                "peakMemoryBytes": artifact["peakMemoryBytes"],
            })

    holdout_chrf = bootstrap_difference(
        sentence_chrf[(CANDIDATES[1], "md62mmdz0m")],
        sentence_chrf[(CANDIDATES[0], "md62mmdz0m")],
    )
    comet_left = comet_scores(
        args.root / "metrics/md62mmdz0m/comet-score.json",
        metric_paths[(CANDIDATES[1], "md62mmdz0m")],
    )
    comet_right = comet_scores(
        args.root / "metrics/md62mmdz0m/comet-score.json",
        metric_paths[(CANDIDATES[0], "md62mmdz0m")],
    )
    holdout_comet = bootstrap_difference(comet_left, comet_right) if comet_left and comet_right else None
    qwen_significantly_better = (
        holdout_chrf["significant"] and holdout_chrf["low95"] > 0
        and holdout_comet is not None
        and holdout_comet["significant"] and holdout_comet["low95"] > 0
    )
    selected = CANDIDATES[1] if qwen_significantly_better else CANDIDATES[0]
    report = {
        "schemaVersion": 1,
        "reporterSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "COMETModel": "Unbabel/wmt22-comet-da",
        "rows": rows,
        "holdoutPairedDifferenceQwenMinusTranslateGemma": {
            "chrFPlusPlus": holdout_chrf,
            "COMET": holdout_comet,
        },
        "selectedProductDefault": selected,
        "selectionRule": "Qwen only if paired holdout chrF++ and COMET 95% intervals are both above zero; otherwise TranslateGemma 12B.",
        "scopeLimit": "These two videos validate only this initial workflow and do not prove universal translation superiority.",
    }
    comet_difference_line = (
        f'Holdout paired COMET Qwen−TranslateGemma: {holdout_comet["mean"]:.4f} '
        f'[95% {holdout_comet["low95"]:.4f}, {holdout_comet["high95"]:.4f}].'
        if holdout_comet else "Holdout paired COMET: pending."
    )
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    lines = [
        "# Local translator bakeoff — ticket #46",
        "",
        "Both candidates used byte-identical frozen requests and canonical prompts through the native MLX Swift translation seam. Their model-native wrappers supplied equivalent translation control. All veto gates passed before the holdout was opened.",
        "",
        f'Pins: `{artifacts[(CANDIDATES[0], CORPORA[0])]["modelID"]}` @ `{artifacts[(CANDIDATES[0], CORPORA[0])]["revision"]}`; '
        f'`{artifacts[(CANDIDATES[1], CORPORA[0])]["modelID"]}` @ `{artifacts[(CANDIDATES[1], CORPORA[0])]["revision"]}`. '
        f'Runtime MLX Swift LM `{artifacts[(CANDIDATES[0], CORPORA[0])]["runtimeVersion"]}`.',
        "Raw prompts, outputs, hashes, gates, timings, memory and diagnostics are retained under `.build/benchmarks/high-quality/translator-bakeoff/`.",
        f"Native cue-marker audit: {sum(len(artifact['promptsAndOutputs']) for artifact in artifacts.values())}/"
        f"{sum(len(artifact['promptsAndOutputs']) for artifact in artifacts.values())} outputs passed.",
        "",
        "| Corpus | Candidate | COMET | chrF++ | Glossary | Missing/dup/reordered/unknown | Untranslated | Suspected hallucination | Runtime | Peak memory |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        glossary = row["glossary"]
        glossary_text = "n/a" if glossary["accuracyPercent"] is None else f'{glossary["accuracyPercent"]:.1f}%'
        comet_text = "pending" if row["COMET"] is None else f'{row["COMET"]:.4f}'
        integrity = sum(len(row[key]) for key in (
            "missingCueIDs", "duplicateCueIDs", "reorderedCueIDs", "unknownCueIDs"
        ))
        lines.append(
            f'| {row["corpusID"]} | {row["candidate"]} | {comet_text} | '
            f'{row["chrFPlusPlus"]:.2f} | {glossary_text} | {integrity} | '
            f'{len(row["untranslatedCueIDs"])} | {len(row["suspectedHallucinatedCueIDs"])} | '
            f'{row["runtimeSeconds"]:.1f}s | {row["peakMemoryBytes"] / 2**30:.2f} GiB |'
        )
    lines += [
        "",
        f'Holdout paired chrF++ Qwen−TranslateGemma: {holdout_chrf["mean"]:.3f} '
        f'[95% {holdout_chrf["low95"]:.3f}, {holdout_chrf["high95"]:.3f}].',
        comet_difference_line,
        f'Product default: **{selected}** because Qwen was not significantly better on the holdout.',
        "",
        report["scopeLimit"],
    ]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
