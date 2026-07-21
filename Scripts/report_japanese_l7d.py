#!/usr/bin/env python3
"""Build the L7D decision report from an L7C aggregate."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path


CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
BASELINE_RSS_GIB = 4.19
MEMORY_LIMIT_GIB = min(10.0, BASELINE_RSS_GIB * 1.2)
BATCH_PREVIEW = {
    "whisper-large-v3-turbo",
    "mlx-whisper-large-v3-turbo",
    "kotoba-whisper-v2.0-q5",
    "qwen3-asr-1.7b",
    "whispermlx-v3.12.2-turbo-long-form",
    "whispermlx-v3.12.2-turbo-vad-finals",
}
PIPELINE_ORDER = (
    "kotoba-whisper-v2.0-q5",
    "voxtral-q4-continuous-960ms",
    "nemotron-multilingual-coreml-1120ms",
    "nemotron-multilingual-coreml-560ms",
    "qwen3-asr-1.7b",
    "mlx-whisper-large-v3-turbo",
    "whisper-large-v3-turbo",
    "whispermlx-v3.12.2-turbo-long-form",
    "whispermlx-v3.12.2-turbo-vad-finals",
    "whisperlivekit-simulstreaming",
    "whisperlivekit-localagreement",
)
LABELS = {
    "kotoba-whisper-v2.0-q5": "Kotoba Whisper v2.0 Q5",
    "voxtral-q4-continuous-960ms": "Voxtral Q4/960",
    "nemotron-multilingual-coreml-1120ms": "Nemotron 1120",
    "nemotron-multilingual-coreml-560ms": "Nemotron 560",
    "qwen3-asr-1.7b": "Qwen3-ASR 1.7B",
    "mlx-whisper-large-v3-turbo": "mlx-whisper Turbo",
    "whisper-large-v3-turbo": "Whisper Turbo",
    "whispermlx-v3.12.2-turbo-long-form": "whispermlx long-form",
    "whispermlx-v3.12.2-turbo-vad-finals": "whispermlx VAD",
    "whisperlivekit-simulstreaming": "WhisperLiveKit SimulStreaming",
    "whisperlivekit-localagreement": "WhisperLiveKit LocalAgreement",
}
VERDICTS = {
    "kotoba-whisper-v2.0-q5": "meilleur final observé; final trop lent",
    "voxtral-q4-continuous-960ms": "rapide, mais dernière parole perdue sur qudu",
    "nemotron-multilingual-coreml-1120ms": "rapide et léger, mais finals vides",
    "nemotron-multilingual-coreml-560ms": "aucun avantage sur 1120; finals vides",
    "qwen3-asr-1.7b": "qualité instable et mémoire trop haute",
    "mlx-whisper-large-v3-turbo": "rapide, qualité insuffisante",
    "whisper-large-v3-turbo": "témoin nettement dépassé",
    "whispermlx-v3.12.2-turbo-long-form": "batch trop lent et trop imprécis",
    "whispermlx-v3.12.2-turbo-vad-finals": "hallucinations et omissions",
    "whisperlivekit-simulstreaming": "backlog et mémoire rédhibitoires",
    "whisperlivekit-localagreement": "ne tient pas la durée",
}
NEGATION = re.compile(
    r"\b(?:no|not|never|nothing|nobody|neither|nor|without|cannot|can['’]t|"
    r"don['’]t|doesn['’]t|didn['’]t|won['’]t|wouldn['’]t|isn['’]t|"
    r"aren['’]t|wasn['’]t|weren['’]t|shouldn['’]t|couldn['’]t|mustn['’]t|"
    r"haven['’]t|hasn['’]t|hadn['’]t)\b",
    re.IGNORECASE,
)
NUMBER_WORDS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
    "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
    "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
    "eighteen": "18", "nineteen": "19", "twenty": "20",
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[math.floor((len(ordered) - 1) * fraction)]


def normalize(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).lower().split())


def ngrams(items: list[str], order: int) -> Counter[tuple[str, ...]]:
    return Counter(tuple(items[index:index + order]) for index in range(len(items) - order + 1))


def chrf_pp(hypothesis: str, reference: str) -> float:
    """Small stdlib chrF++ diagnostic: char order 6, word order 2, beta 2."""
    hyp = normalize(hypothesis)
    ref = normalize(reference)
    if not ref:
        return 100.0 if not hyp else 0.0
    precisions: list[float] = []
    recalls: list[float] = []
    streams = (
        (list(hyp.replace(" ", "")), list(ref.replace(" ", "")), 6),
        (re.findall(r"[\w']+|[^\w\s]", hyp), re.findall(r"[\w']+|[^\w\s]", ref), 2),
    )
    for hyp_items, ref_items, maximum_order in streams:
        for order in range(1, maximum_order + 1):
            if len(ref_items) < order:
                continue
            hyp_counts = ngrams(hyp_items, order) if len(hyp_items) >= order else Counter()
            ref_counts = ngrams(ref_items, order)
            matches = sum((hyp_counts & ref_counts).values())
            precisions.append(matches / sum(hyp_counts.values()) if hyp_counts else 0.0)
            recalls.append(matches / sum(ref_counts.values()))
    precision = sum(precisions) / len(precisions)
    recall = sum(recalls) / len(recalls)
    return 500 * precision * recall / (4 * precision + recall) if precision or recall else 0.0


def event_range(event: dict) -> tuple[int, int] | None:
    for start_key, end_key in (
        ("sourceStartSample", "sourceEndSample"),
        ("localStartSample", "localEndSample"),
        ("startSample", "endSample"),
    ):
        start, end = event.get(start_key), event.get(end_key)
        if isinstance(start, int) and isinstance(end, int) and start < end:
            return start, end
    return None


def final_previews(events: list[dict]) -> list[dict]:
    latest: dict[object, dict] = {}
    for index, event in enumerate(events):
        span = event_range(event)
        key = event.get("phraseKey")
        if key is None:
            key = (span, event.get("sourceSequence"), index)
        latest[key] = event
    return sorted(latest.values(), key=lambda item: event_range(item) or (sys.maxsize, sys.maxsize))


def overlaps(event: dict, turn: dict) -> bool:
    span = event_range(event)
    return bool(span and span[0] < turn["endSample"] and turn["startSample"] < span[1])


def number_tokens(text: str) -> set[str]:
    tokens = set(re.findall(r"\b\d+(?:[.,]\d+)?\b", normalize(text)))
    for word in re.findall(r"[a-z]+", normalize(text)):
        if word in NUMBER_WORDS:
            tokens.add(NUMBER_WORDS[word])
    return tokens


def english_score(events_by_corpus: dict[str, list[dict]], manifests: dict[str, dict]) -> dict:
    references: list[str] = []
    hypotheses: list[str] = []
    covered_characters = 0
    total_characters = 0
    short_scores: list[float] = []
    short_count = 0
    negation_total = negation_kept = 0
    number_total = number_kept = 0
    critical_term_count = 0
    for corpus in CORPORA:
        events = [event for event in events_by_corpus.get(corpus, []) if str(event.get("english") or "").strip()]
        turns = [
            turn for turn in manifests[corpus]["annotations"]["turns"]
            if turn.get("confidence") == "high" and not turn.get("overlap")
        ]
        selected_events = [event for event in events if any(overlaps(event, turn) for turn in turns)]
        selected_events.sort(key=lambda item: event_range(item) or (sys.maxsize, sys.maxsize))
        references.extend(str(turn.get("english") or "") for turn in turns)
        hypotheses.extend(str(event.get("english") or "") for event in selected_events)
        for turn in turns:
            reference = str(turn.get("english") or "")
            matching = [event for event in events if overlaps(event, turn)]
            hypothesis = " ".join(str(event.get("english") or "") for event in matching)
            weight = len(normalize(reference).replace(" ", ""))
            total_characters += weight
            if hypothesis:
                covered_characters += weight
            if len(re.findall(r"[\w']+", normalize(reference))) <= 4:
                short_count += 1
                short_scores.append(chrf_pp(hypothesis, reference))
            if NEGATION.search(reference):
                negation_total += 1
                negation_kept += bool(NEGATION.search(hypothesis))
            expected_numbers = number_tokens(reference)
            if expected_numbers:
                number_total += 1
                number_kept += expected_numbers.issubset(number_tokens(hypothesis))
            critical_term_count += len(turn.get("criticalTerms") or [])
    return {
        "chrfPlusPlus": chrf_pp(" ".join(hypotheses), " ".join(references)),
        "coveragePercent": 100 * covered_characters / total_characters if total_characters else 0.0,
        "shortResponseChrfPlusPlus": sum(short_scores) / len(short_scores) if short_scores else None,
        "shortResponseCount": short_count,
        "negationRecallPercent": 100 * negation_kept / negation_total if negation_total else None,
        "negationTurnCount": negation_total,
        "numberRecallPercent": 100 * number_kept / number_total if number_total else None,
        "numberTurnCount": number_total,
        "nameRecallPercent": None,
        "nameDiagnostic": "unavailable: manifests contain no criticalTerms" if not critical_term_count else "manual bilingual review required",
    }


def group_entries(entries: list[dict], event_key: str = "events") -> dict[str, dict[str, list[dict]]]:
    grouped: dict[str, dict[str, list[dict]]] = {}
    for entry in entries:
        grouped.setdefault(entry["pipeline"], {})[entry["corpusID"]] = entry.get(event_key, [])
    return grouped


def pooled_cer(sessions: list[dict]) -> float:
    edits = references = 0
    for session in sessions:
        overall = (session.get("continuousCER") or {}).get("overall", {})
        edits += overall.get("editDistance") or 0
        references += overall.get("referenceCharacterCount") or 0
    return edits / references if references else math.inf


def native_integrity(session: dict) -> bool:
    required = session.get("terminalSilenceStartSample", session.get("windowEndSample"))
    last_speech = session.get("lastSpeech") or {}
    return (
        not session.get("errors")
        and session.get("pcmAnalyzedThrough") == session.get("windowEndSample")
        and session.get("unaccountedSampleCount") == 0
        and last_speech.get("heuristicPresent") is True
        and isinstance(required, int)
        and (session.get("asrFinalizedThrough") or -1) >= required
        and (session.get("englishValidatedThrough") or -1) >= required
    )


def live_integrity(session: dict) -> bool:
    return (
        not session.get("errors")
        and session.get("sentSampleCount") == session.get("expectedSampleCount")
        and session.get("readyToStopReceived") is True
        and session.get("lastAnnotatedSpeechPresent") is True
        and (session.get("endingProcessingBacklogSeconds") or 0) <= 0.1
    )


def find_raw_reports(comparison: dict) -> tuple[dict, dict, dict, dict]:
    reports = [load(Path(item["path"])) for item in comparison["reports"]]
    native = next(report for report in reports if str(report.get("runID", "")).startswith("l7c-native-full-"))
    vad = next(report for report in reports if str(report.get("runID", "")).startswith("l7c-whispermlx-vad-full-"))
    simul = next(report for report in reports if str(report.get("runID", "")).startswith("l7c-wlk-simulstreaming-full-"))
    local = next(report for report in reports if str(report.get("runID", "")).startswith("l7c-wlk-localagreement-full-"))
    return native, vad, simul, local


def fmt(value: float | None, suffix: str = "") -> str:
    return "n/a" if value is None or math.isinf(value) else f"{value:.1f}{suffix}"


def self_test() -> None:
    assert chrf_pp("same text", "same text") == 100.0
    assert chrf_pp("abc", "xyz") == 0.0
    assert percentile([3, 1, 2], 0.5) == 2
    assert event_range({"localStartSample": 1, "localEndSample": 2}) == (1, 2)
    assert len(final_previews([{"phraseKey": 1, "english": "a"}, {"phraseKey": 1, "english": "b"}])) == 1
    assert number_tokens("two and 3") == {"2", "3"}


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("--aggregate", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    ja = load(args.aggregate / "ja-asr.json")
    preview = load(args.aggregate / "en-preview.json")
    final = load(args.aggregate / "en-final.json")
    comparison_path = args.aggregate / "comparison.json"
    comparison = load(comparison_path)
    manifests = {
        corpus: load(args.source_root / "docs" / "japanese-live" / "corpora" / corpus / "manifest.json")
        for corpus in CORPORA
    }
    native_raw, vad_raw, simul_raw, local_raw = find_raw_reports(comparison)

    ja_grouped: dict[str, list[dict]] = {}
    for session in ja["sessions"]:
        ja_grouped.setdefault(session["pipeline"], []).append(session)
    final_grouped = group_entries(final["candidateNative"] + final["whisperLiveKit"])
    preview_grouped = group_entries(preview["candidateNative"] + preview["whisperLiveKit"])
    common_preview_events = {
        session["corpusID"]: final_previews(session.get("previewEvents", []))
        for session in preview["commonAppleSpeech"]
    }
    common_preview_sessions = preview["commonAppleSpeech"]
    common_preview_latencies = [
        value for session in preview["commonAppleSpeech"]
        for value in session.get("previewFirstLatencyMilliseconds", [])
    ]
    human_events: dict[str, list[dict]] = {corpus: [] for corpus in CORPORA}
    for event in final["humanJapaneseControl"]:
        human_events[event["corpusID"]].append(event)
    human_score = english_score(human_events, manifests)
    human_latencies = [event["milliseconds"] for event in final["humanJapaneseControl"]]

    raw_native = native_raw["sessions"] + vad_raw["sessions"]
    raw_by_pipeline: dict[str, list[dict]] = {}
    for session in raw_native:
        raw_by_pipeline.setdefault(session["recipeID"], []).append(session)
    live_by_pipeline = {
        "whisperlivekit-simulstreaming": simul_raw["sessions"],
        "whisperlivekit-localagreement": local_raw["sessions"],
    }
    setup = {
        recipe: model for recipe, model in zip(native_raw["expectedRecipeIDs"], native_raw["models"])
    }
    setup["whispermlx-v3.12.2-turbo-vad-finals"] = vad_raw["models"][0]

    rows = []
    for pipeline in PIPELINE_ORDER:
        sessions = ja_grouped[pipeline]
        by_corpus = {session["corpusID"]: session for session in sessions}
        final_events = final_grouped.get(pipeline, {})
        final_score = english_score(final_events, manifests)
        final_latencies = [
            event["endpointToAcceptedMilliseconds"]
            for events in final_events.values() for event in events
            if isinstance(event.get("endpointToAcceptedMilliseconds"), (int, float))
        ]
        final_p95_by_corpus = {
            corpus: percentile([
                event["endpointToAcceptedMilliseconds"]
                for event in final_events.get(corpus, [])
                if isinstance(event.get("endpointToAcceptedMilliseconds"), (int, float))
            ], 0.95)
            for corpus in CORPORA
        }
        if pipeline in live_by_pipeline:
            raw_sessions = live_by_pipeline[pipeline]
            integrity = all(live_integrity(session) for session in raw_sessions)
            rss = max(session.get("maximumObservedResidentBytes") or 0 for session in raw_sessions)
            backlog_ms = max(1000 * (session.get("maximumProcessingBacklogSeconds") or 0) for session in raw_sessions)
            setup_ms = None
        else:
            raw_sessions = raw_by_pipeline[pipeline]
            integrity = all(native_integrity(session) for session in raw_sessions)
            rss = max(session.get("maximumResidentBytes") or 0 for session in raw_sessions)
            backlog_ms = max(session.get("maximumBacklogMilliseconds") or 0 for session in raw_sessions)
            setup_ms = setup.get(pipeline, {}).get("setupMilliseconds")
        if pipeline in BATCH_PREVIEW:
            preview_events = common_preview_events
            preview_latencies = common_preview_latencies
            preview_sessions = common_preview_sessions
            preview_revision_count = sum(
                session.get("previewRevisionCount") or 0 for session in preview_sessions
            )
        else:
            preview_events = {
                corpus: final_previews(events)
                for corpus, events in preview_grouped.get(pipeline, {}).items()
            }
            matching_preview_entries = [
                item for item in preview["candidateNative"] + preview["whisperLiveKit"]
                if item["pipeline"] == pipeline
            ]
            preview_latencies = [
                value for item in matching_preview_entries
                for value in item.get("firstLatencyMilliseconds", [])
            ]
            preview_sessions = raw_sessions
            preview_revision_count = sum(
                item.get("revisionCount") or 0 for item in matching_preview_entries
            )
        preview_score = english_score(preview_events, manifests)
        rtf = sum((session.get("computeRTF") or session.get("endToEndWallRTF") or 0) for session in sessions) / len(sessions)
        cpu_values = [
            session["averageCPUPercent"] for session in raw_sessions
            if isinstance(session.get("averageCPUPercent"), (int, float))
        ]
        preview_p50 = percentile(preview_latencies, 0.5)
        preview_p95 = percentile(preview_latencies, 0.95)
        preview_worst = max(preview_latencies, default=None)
        final_p95 = percentile(final_latencies, 0.95)
        rss_gib = rss / 1024**3
        preview_gate = (
            preview_score["coveragePercent"] >= 95
            and preview_p50 is not None and preview_p50 <= 1000
            and preview_p95 is not None and preview_p95 <= 1800
            and preview_worst is not None and preview_worst <= 3000
        )
        final_gate = integrity and all(
            value is not None and value <= 1500
            for value in final_p95_by_corpus.values()
        )
        memory_gate = rss_gib <= MEMORY_LIMIT_GIB
        rows.append({
            "pipeline": pipeline,
            "label": LABELS[pipeline],
            "japaneseCERPercent": 100 * pooled_cer(sessions),
            "japaneseCERByCorpusPercent": {
                corpus: 100 * pooled_cer([by_corpus[corpus]]) for corpus in CORPORA
            },
            "rtf": rtf,
            "setupMilliseconds": setup_ms,
            "preview": {
                **preview_score,
                "p50Milliseconds": preview_p50,
                "p95Milliseconds": preview_p95,
                "worstMilliseconds": preview_worst,
                "revisionCount": preview_revision_count,
                "confirmedPrefixRewriteCount": sum(
                    session.get("confirmedPrefixRewriteCount") or 0
                    for session in preview_sessions
                ),
                "gatePassed": preview_gate,
            },
            "final": {
                **final_score,
                "p95Milliseconds": final_p95,
                "p95ByCorpusMilliseconds": final_p95_by_corpus,
                "appendOnly": all(
                    session.get("finalTranslationsAppendOnly") is True
                    for session in raw_sessions
                ),
                "gatePassed": final_gate,
            },
            "averageCPUPercent": sum(cpu_values) / len(cpu_values) if cpu_values else None,
            "thermalStateBefore": sorted({
                session.get("thermalStateBefore", "not-measured") for session in raw_sessions
            }),
            "thermalStateAfter": sorted({
                session.get("thermalStateAfter", "not-measured") for session in raw_sessions
            }),
            "maximumRSSGiB": rss_gib,
            "maximumBacklogMilliseconds": backlog_ms,
            "integrityPassed": integrity,
            "memoryGatePassed": memory_gate,
            "verdict": VERDICTS[pipeline],
        })

    best_observed = min(
        (row for row in rows if row["integrityPassed"] and row["memoryGatePassed"]),
        key=lambda row: row["japaneseCERPercent"],
    )["pipeline"]
    payload = {
        "schemaVersion": 1,
        "lot": "L7D",
        "sourceL7C": {
            "directory": str(args.aggregate.resolve()),
            "comparisonSHA256": sha256(comparison_path),
            "gitCommit": comparison["gitCommit"],
            "sourceTreeSHA256": comparison["sourceTreeSHA256"],
            "runtimeSHA256": comparison["runtimeSHA256"],
            "modelRecipesSHA256": comparison["modelRecipesSHA256"],
            "matrixAttempted": comparison["matrixAttempted"],
            "candidateSessionCount": comparison["candidateSessionCount"],
        },
        "corpora": [
            {
                "corpusID": corpus,
                "manifestSHA256": sha256(
                    args.source_root / "docs" / "japanese-live" / "corpora" / corpus / "manifest.json"
                ),
                "audioSHA256": manifests[corpus]["fixture"]["sha256"],
                "annotationStatus": manifests[corpus]["annotations"]["status"],
            }
            for corpus in CORPORA
        ],
        "references": {
            "annotationStatus": sorted({manifest["annotations"]["status"] for manifest in manifests.values()}),
            "promotionAllowed": False,
            "reason": "pending human review and no pipeline passes every product gate",
        },
        "humanJapaneseToAppleFinal": {
            **human_score,
            "p50Milliseconds": percentile(human_latencies, 0.5),
            "p95Milliseconds": percentile(human_latencies, 0.95),
            "turnCount": len(human_latencies),
        },
        "memoryGateGiB": MEMORY_LIMIT_GIB,
        "bestObserved": best_observed,
        "integrationAllowed": False,
        "pipelines": rows,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "comparison-l7d.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# L7D — comparaison et décision",
        "",
        "## Résultat",
        "",
        "**Aucun pipeline ne passe tous les gates. L8 ne doit pas démarrer.**",
        "",
        "Le meilleur final observé est **Kotoba Whisper v2.0 Q5 + Apple highFidelity** : "
        "il conserve la dernière parole sur les deux vidéos et obtient le meilleur CER groupé, "
        "mais son final p95 dépasse 1,5 s. Voxtral reste très bon sur `md62`, mais perd la "
        "dernière parole de `qudu`; il ne peut donc pas être promu.",
        "",
        "Les scores anglais chrF++ sont des diagnostics automatiques : une traduction correcte "
        "peut employer d'autres mots. Les références restent `pending-human-review`.",
        f"Preuve source : commit `{comparison['gitCommit'][:7]}`, recettes "
        f"`{comparison['modelRecipesSHA256']}`, comparaison L7C `{sha256(comparison_path)}`.",
        "",
        "## Comparaison simple",
        "",
        "| Pipeline | CER JP | CER qudu / md62 | Preview EN chrF++ / cov / p95 | Final EN chrF++ / cov / p95 | RTF | RSS | Verdict |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in rows:
        preview_row = row["preview"]
        final_row = row["final"]
        final_latency = (
            f"{fmt(final_row['p95Milliseconds'], ' ms')}*"
            if row["pipeline"].startswith("whisperlivekit-")
            else fmt(final_row["p95Milliseconds"], " ms")
        )
        lines.append(
            f"| {row['label']} | {row['japaneseCERPercent']:.1f} % | "
            f"{row['japaneseCERByCorpusPercent']['qudu2fx3ncc']:.1f} / "
            f"{row['japaneseCERByCorpusPercent']['md62mmdz0m']:.1f} % | "
            f"{preview_row['chrfPlusPlus']:.1f} / {preview_row['coveragePercent']:.1f} % / "
            f"{fmt(preview_row['p95Milliseconds'], ' ms')} | "
            f"{final_row['chrfPlusPlus']:.1f} / {final_row['coveragePercent']:.1f} % / "
            f"{final_latency} | {row['rtf']:.3f} | "
            f"{row['maximumRSSGiB']:.2f} Gio | {row['verdict']} |"
        )
    control = payload["humanJapaneseToAppleFinal"]
    lines += [
        "",
        "## Traduction Apple isolée",
        "",
        f"Sur le japonais humain propre : chrF++ **{control['chrfPlusPlus']:.1f}**, "
        f"couverture **{control['coveragePercent']:.1f} %**, p95 **{control['p95Milliseconds']:.0f} ms** "
        f"sur {control['turnCount']} tours. Le traducteur est rapide et complet, mais sa fidélité "
        "sémantique n'est pas validée sans les deux juges bilingues prévus.",
        "",
        "La couverture du tableau est pondérée par les caractères des références anglaises "
        "`high`, sans overlap. `*` Pour WhisperLiveKit, 0 ms signifie seulement « accepté à EOS » "
        "sur un transcript incomplet; ce n'est pas une finale live réussie.",
        "",
        "Diagnostics ciblés : les négations, nombres et réponses courtes sont présents dans "
        "`comparison-l7d.json`. Les noms ne sont pas scorables automatiquement : les deux "
        "manifestes ne contiennent aucun `criticalTerms`.",
        "",
        "## Décision",
        "",
        "- Architecture de développement recommandée : **Apple Speech lowLatency preview → "
        "Kotoba Q5 final → Apple highFidelity final**.",
        "- Ce n'est pas une promotion produit : preview Apple p50 >1 s et pire >3 s; final "
        "Kotoba p95 >1,5 s; références non validées humainement.",
        "- Voxtral reste un challenger utile uniquement après correction prouvée de sa "
        "finalisation/dernière parole sur `qudu`.",
        "- Nemotron, WhisperLiveKit, Qwen et les deux modes `whispermlx` sont écartés pour cette "
        "architecture. Qwen 0.6B et l'alignement L6A ne sont pas déclenchés.",
        "- Aucun arbitrage GPT Pro n'est demandé : les finalistes ne sont pas bloqués par une "
        "ambiguïté linguistique, mais par des gates objectifs.",
    ]
    (args.output / "report-fr.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
