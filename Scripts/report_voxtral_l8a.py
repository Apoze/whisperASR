#!/usr/bin/env python3
"""Summarize the L8A Voxtral integrity and four-level Apple diagnostic."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

from report_japanese_l7d import chrf_pp, percentile


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def milliseconds(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1f} ms"


def translation_summary(
    items: list[dict],
    reference_by_corpus: dict[str, str],
) -> dict:
    ordered = sorted(
        items,
        key=lambda item: (
            item["corpusID"],
            item["startSample"],
            item["endSample"],
            item["unitID"],
        ),
    )
    successful = [
        item for item in ordered
        if item.get("error") is None and str(item.get("english") or "").strip()
    ]
    def useful_characters(item: dict) -> int:
        return sum(
            not character.isspace()
            for character in str(item.get("sourceJapanese") or "")
        )

    present_characters = sum(useful_characters(item) for item in ordered)
    translated_characters = sum(
        useful_characters(item) for item in successful
    )
    hypotheses_by_corpus: dict[str, list[str]] = {}
    for item in successful:
        hypotheses_by_corpus.setdefault(item["corpusID"], []).append(item["english"])
    corpora = sorted(reference_by_corpus)
    reference = " ".join(reference_by_corpus[corpus] for corpus in corpora)
    hypothesis = " ".join(
        " ".join(hypotheses_by_corpus.get(corpus, [])) for corpus in corpora
    )
    return {
        "itemCount": len(items),
        "successfulCount": len(successful),
        "unitCoveragePercent": 100 * len(successful) / len(items) if items else 0,
        "sourceCharacterCount": present_characters,
        "translatedSourceCharacterCount": translated_characters,
        "sourceCharacterCoveragePercent":
            100 * translated_characters / present_characters
            if present_characters else 0,
        "p95Milliseconds": percentile(
            [float(item["milliseconds"]) for item in successful], 0.95
        ),
        "chrfPlusPlus": chrf_pp(hypothesis, reference) if reference else 0,
    }


def build(native_path: Path, diagnostic_path: Path, baseline_path: Path) -> dict:
    native = load(native_path)
    diagnostic = load(diagnostic_path)
    baseline = load(baseline_path)
    sessions = sorted(
        (
            session for session in native["sessions"]
            if session["recipeID"] == "voxtral-q4-continuous-960ms"
        ),
        key=lambda session: session["corpusID"],
    )
    baseline_sessions = [
        session for session in baseline["sessions"]
        if session["recipeID"] == "voxtral-q4-continuous-960ms"
    ]
    baseline_cer = {
        session["corpusID"]: session["continuousCER"]["overall"]["rate"]
        for session in baseline_sessions
    }
    if len(sessions) != 2 or len(baseline_sessions) != 2:
        raise ValueError("L8A requires exactly two current and baseline sessions.")
    if {session["corpusID"] for session in sessions} != set(baseline_cer):
        raise ValueError("L8A requires one Voxtral Q4/960 session per corpus.")
    if diagnostic.get("nativeReportSHA256") != sha256(native_path):
        raise ValueError("Diagnostic does not reference the supplied native report.")
    if diagnostic.get("gitCommit") != native.get("gitCommit"):
        raise ValueError("Diagnostic and native commits differ.")
    if diagnostic.get("sourceTreeSHA256") != native.get("sourceTreeSHA256"):
        raise ValueError("Diagnostic and native source trees differ.")

    corpus_rows = []
    for session in sessions:
        corpus = session["corpusID"]
        evidence = session.get("voxtralEvidence") or {}
        cer = session["continuousCER"]["overall"]["rate"]
        preview_apple = [
            (
                event["completedUptimeNanoseconds"]
                - event["translationStartedUptimeNanoseconds"]
            ) / 1_000_000
            for event in session["previewEvents"]
            if event.get("error") is None
        ]
        final_apple = [
            (
                event["acceptedUptimeNanoseconds"]
                - event["translationStartedUptimeNanoseconds"]
            ) / 1_000_000
            for event in session["finalTranslationEvents"]
            if event.get("error") is None
        ]
        translation_errors = [
            error for error in session["errors"]
            if error.startswith("Apple lowLatency preview")
            or error.startswith("Apple highFidelity final")
        ]
        source_errors = [
            error for error in session["errors"]
            if error not in translation_errors
        ]
        source_final = session.get("finalSourceLatencyMilliseconds", [])
        corpus_rows.append({
            "corpusID": corpus,
            "continuousCER": cer,
            "baselineCER": baseline_cer[corpus],
            "baselineWithinTwoPoints": abs(cer - baseline_cer[corpus]) <= 0.02,
            "lastSpeechPresent": session["lastSpeech"]["heuristicPresent"],
            "lastVADSpeechEndSample": evidence.get("lastVADSpeechEndSample"),
            "lastStreamTextObservedAtSample":
                evidence.get("lastStreamTextObservedAtSample"),
            "lastUsefulTextObservedAtSample":
                evidence.get("lastUsefulTextObservedAtSample"),
            "helperAcknowledgedThroughSample":
                evidence.get("helperAcknowledgedThroughSample"),
            "sourceStagedThroughSample": evidence.get("sourceStagedThroughSample"),
            "englishValidatedThroughSample": session["englishValidatedThrough"],
            "retainedSampleCount":
                session["windowEndSample"] - session["englishValidatedThrough"],
            "boundaryCounts": dict(sorted(Counter(
                boundary["kind"] for boundary in evidence.get("boundaries", [])
            ).items())),
            "degradedBoundaryCount": sum(
                boundary.get("degradation") is not None
                for boundary in evidence.get("boundaries", [])
            ),
            "previewSourceP95Milliseconds": percentile(
                session["previewSourceFirstLatencyMilliseconds"], 0.95
            ),
            "previewEndToEndP95Milliseconds": percentile(
                session["previewFirstLatencyMilliseconds"], 0.95
            ),
            "previewAppleP95Milliseconds": percentile(preview_apple, 0.95),
            "finalSourceP95Milliseconds": percentile(source_final, 0.95),
            "finalEndToEndP95Milliseconds": percentile([
                float(event["endpointToAcceptedMilliseconds"])
                for event in session["finalTranslationEvents"]
                if event.get("error") is None
            ], 0.95),
            "finalAppleP95Milliseconds": percentile(final_apple, 0.95),
            "pcmAcknowledgedCompletely":
                evidence.get("helperAcknowledgedThroughSample")
                == session["windowEndSample"],
            "asrFedCompletely":
                session["asrFedSampleCount"] == session["expectedSampleCount"],
            "asrFinalizedCompletely":
                session["asrFinalizedThrough"] == session["windowEndSample"],
            "unaccountedSampleCount": session["unaccountedSampleCount"],
            "endingBacklogMilliseconds": session["endingBacklogMilliseconds"],
            "sourceErrors": source_errors,
            "nativeTranslationErrorCount": len(translation_errors),
        })

    levels: dict[str, list[dict]] = {}
    for item in diagnostic["items"]:
        levels.setdefault(item["level"], []).append(item)
    reference_by_corpus: dict[str, str] = {}
    for item in levels.get("human-japanese-human-boundaries", []):
        if item.get("referenceEnglish"):
            reference_by_corpus.setdefault(item["corpusID"], "")
            reference_by_corpus[item["corpusID"]] += " " + item["referenceEnglish"]
    level_rows = {
        level: translation_summary(items, reference_by_corpus)
        for level, items in sorted(levels.items())
    }
    gate = (
        all(row["baselineWithinTwoPoints"] for row in corpus_rows)
        and all(row["pcmAcknowledgedCompletely"] for row in corpus_rows)
        and all(row["asrFedCompletely"] for row in corpus_rows)
        and all(row["asrFinalizedCompletely"] for row in corpus_rows)
        and all(row["unaccountedSampleCount"] == 0 for row in corpus_rows)
        and all(row["endingBacklogMilliseconds"] == 0 for row in corpus_rows)
        and all(row["previewSourceP95Milliseconds"] is not None for row in corpus_rows)
        and all(row["finalSourceP95Milliseconds"] is not None for row in corpus_rows)
        and all(not row["sourceErrors"] for row in corpus_rows)
        and next(
            row for row in corpus_rows if row["corpusID"] == "qudu2fx3ncc"
        )["lastSpeechPresent"] is False
        and set(level_rows) == {
            "human-japanese-human-boundaries",
            "voxtral-japanese-human-boundaries",
            "human-japanese-product-boundaries",
            "voxtral-japanese-product-boundaries",
        }
        and level_rows["human-japanese-human-boundaries"]["unitCoveragePercent"] == 100
        and level_rows["human-japanese-human-boundaries"]["sourceCharacterCount"]
            == level_rows["human-japanese-product-boundaries"]["sourceCharacterCount"]
        and level_rows["voxtral-japanese-human-boundaries"]["sourceCharacterCount"]
            == level_rows["voxtral-japanese-product-boundaries"]["sourceCharacterCount"]
    )
    return {
        "schemaVersion": 1,
        "lot": "L8A",
        "nativeReportSHA256": sha256(native_path),
        "diagnosticReportSHA256": sha256(diagnostic_path),
        "baselineReportSHA256": sha256(baseline_path),
        "reportGeneratorSHA256": sha256(Path(__file__)),
        "gitCommit": native["gitCommit"],
        "sourceTreeSHA256": native["sourceTreeSHA256"],
        "modelRecipesSHA256": native["modelRecipesSHA256"],
        "gatePassed": gate,
        "corpora": corpus_rows,
        "translationLevels": level_rows,
        "note": (
            "Text is distributed losslessly to the nearest temporal boundary "
            "after ASR and only for diagnosis. "
            "References never affected Voxtral input or product boundaries."
        ),
    }


def report_fr(result: dict) -> str:
    lines = [
        "# L8A — diagnostic Voxtral fiable",
        "",
        f"Gate : **{'passé' if result['gatePassed'] else 'échoué'}**.",
        "",
        "| Corpus | CER | Dernière parole | Dernier VAD / texte utile | PCM accusé | "
        "Preview source / Apple p95 | Fin capture Voxtral | "
        "Finales clauses total / Apple p95 | Frontières dégradées |",
        "|---|---:|---|---:|---|---:|---:|---:|---:|",
    ]
    for row in result["corpora"]:
        lines.append(
            f"| {row['corpusID']} | {100 * row['continuousCER']:.1f} % | "
            f"{'oui' if row['lastSpeechPresent'] else 'non'} | "
            f"{row['lastVADSpeechEndSample']} / {row['lastUsefulTextObservedAtSample']} | "
            f"{'oui' if row['pcmAcknowledgedCompletely'] else 'non'} | "
            f"{milliseconds(row['previewSourceP95Milliseconds'])} / "
            f"{milliseconds(row['previewAppleP95Milliseconds'])} | "
            f"{milliseconds(row['finalSourceP95Milliseconds'])} | "
            f"{milliseconds(row['finalEndToEndP95Milliseconds'])} / "
            f"{milliseconds(row['finalAppleP95Milliseconds'])} | "
            f"{row['degradedBoundaryCount']} |"
        )
    if any(row["nativeTranslationErrorCount"] for row in result["corpora"]):
        lines += [
            "",
            "Des traductions Apple simultanées ont échoué sur ce run. "
            "Les latences Voxtral restent mesurées indépendamment.",
        ]
    lines += [
        "",
        "## Traduction diagnostique",
        "",
        "| Niveau | Unités | Caractères source utiles | chrF++ corpus | p95 Apple |",
        "|---|---:|---:|---:|---:|",
    ]
    for level, row in result["translationLevels"].items():
        lines.append(
            f"| {level} | {row['successfulCount']}/{row['itemCount']} "
            f"({row['unitCoveragePercent']:.1f} %) | "
            f"{row['sourceCharacterCoveragePercent']:.1f} % | "
            f"{row['chrfPlusPlus']:.1f} | {milliseconds(row['p95Milliseconds'])} |"
        )
    lines += [
        "",
        "Chaque niveau est comparé à la traduction complète de chaque corpus, "
        "sans recopier les tours anglais sur les fragments. Le découpage temporel "
        "conserve chaque caractère utile (hors espaces) en l'affectant à la frontière "
        "la plus proche; cela reste une approximation postérieure au replay.",
    ]
    return "\n".join(lines) + "\n"


def self_test() -> None:
    assert translation_summary([], {})["unitCoveragePercent"] == 0
    assert milliseconds(None) == "n/a"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", type=Path)
    parser.add_argument("--diagnostic", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.native or not args.diagnostic or not args.baseline or not args.output:
        parser.error("--native, --diagnostic, --baseline and --output are required")
    result = build(args.native, args.diagnostic, args.baseline)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "comparison.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (args.output / "report-fr.md").write_text(report_fr(result), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
