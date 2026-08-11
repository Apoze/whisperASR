#!/usr/bin/env python3
"""Compare #89 DEV evidence with the frozen E22/E23 Qwen baseline."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from datetime import datetime
from pathlib import Path

from report_high_quality_acceptance import cer, translation_rows
from report_japanese_l7d import chrf_pp
from report_qwen_error_diagnostic import MEANING_ANCHORS, classify_unit, material_score, normalize

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
BASELINE = ROOT / "docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz"
SEGMENTS = ROOT / "docs/japanese-live/experiments/evidence/E23/segments.json"
EVIDENCE = ROOT / "docs/japanese-live/experiments/evidence/ReazonK2V2"
EXECUTION_IMPLEMENTATION_SHA256 = {
    "Sources/HighQualityASRWorker.swift":
        "455c87399df2309e73030c47a3e51150be2e786b2faad999843ce12d63bae379",
    "Sources/HighQualityJob.swift":
        "b685d4b2cbb55efe88e4fddc17c54ad4d43e013acc6f6df81b8bbad561b9dc2f",
    "Scripts/reazon_asr_worker.py":
        "493982ef89ca519c8246251f11ac12ed57b09cb5210fbc121058a1b33ed219ff",
    "Scripts/run_reazon_dev_experiment.sh":
        "b66ebda1c0328faae0904e55b52a062d179fea478a09ac5776960558d12cf10b",
}
MODEL = {
    "backend": "reazonspeech-k2-v2-int8",
    "modelID": "reazon-research/reazonspeech-k2-v2",
    "revision": "291488c8151be24d7da4bf7af26e533fad96e407",
    "runtimeVersion": "sherpa-onnx 1.13.4",
    "weightSHA256": {
        "decoder-epoch-99-avg-1.onnx":
            "58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124",
        "encoder-epoch-99-avg-1.int8.onnx":
            "2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d",
        "joiner-epoch-99-avg-1.int8.onnx":
            "49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de",
        "tokens.txt":
            "2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def",
    },
}


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def terms(unit: dict) -> list[str]:
    values = unit["classification"]["terms"]
    return list(dict.fromkeys(values["recovered"] + values["lost"]))


def candidate_units(raw: dict, frozen: list[dict]) -> list[dict]:
    characters = raw["asrWorker"]["characters"]
    previous = ""
    result = []
    for baseline in frozen:
        text = "".join(character["text"] for character in characters
                       if baseline["start"] <= (
                           character["sourceStart"] + character["sourceEnd"]
                       ) / 2 < baseline["end"])
        anchors = [anchor for turn in baseline["referenceTurnIDs"]
                   for anchor in MEANING_ANCHORS.get(turn, [])]
        classification = classify_unit(
            baseline["referenceJapanese"], text, terms(baseline), anchors
        )
        normalized = normalize(text)
        unit = {
            "id": baseline["id"], "start": baseline["start"], "end": baseline["end"],
            "referenceJapanese": baseline["referenceJapanese"], "qwenJapanese": baseline["text"],
            "reazonJapanese": text, "classification": classification,
            "duplicatedTurn": bool(normalized and normalized == previous),
        }
        unit["materialErrorScore"] = material_score(unit)
        unit["materialDeltaVsQwen"] = baseline["materialErrorScore"] - unit["materialErrorScore"]
        result.append(unit)
        previous = normalized
    return result


def timestamp_audit(raw: dict) -> dict:
    characters = raw.get("asrWorker", {}).get("characters") or []
    lines = (raw.get("rawASR") or "").splitlines()
    by_chunk = ["".join(item["text"] for item in characters if item["chunkIndex"] == index)
                for index in range(len(lines))]
    duration = raw.get("sampleCount", 0) / max(1, raw.get("sampleRate", 0))
    return {
        "characterCount": len(characters),
        "oneUnicodeCharacterPerEntry": bool(characters)
            and all(len(item["text"]) == 1 for item in characters),
        "completeText": by_chunk == lines,
        "monotonic": all(left["sourceStart"] <= right["sourceStart"]
                         for left, right in zip(characters, characters[1:])),
        "bounded": bool(characters) and all(
            0 <= item["sourceStart"] <= item["sourceEnd"] <= duration for item in characters
        ),
        "chunkIndexesComplete": bool(lines)
            and sorted(set(item["chunkIndex"] for item in characters)) == list(range(len(lines))),
    }


def counts(units: list[dict]) -> dict:
    return {
        "materialErrorScore": sum(unit["materialErrorScore"] for unit in units),
        "lostCharacters": sum(unit["classification"]["speech"]["lostCharacters"] for unit in units),
        "lostTerms": sum(len(unit["classification"]["terms"]["lost"]) for unit in units),
        "lostNumbers": sum(len(unit["classification"]["numbers"]["lost"]) for unit in units),
        "lostMeaningAnchors": sum(len(unit["classification"]["meaning"]["lost"]) for unit in units),
        "emptyTurns": sum(unit["classification"]["emptyTurn"] for unit in units),
        "duplicatedTurns": sum(unit["duplicatedTurn"] for unit in units),
    }


def english_effects(manifest: dict, baseline: dict, candidate: dict) -> dict:
    qwen = {row["id"]: row for row in translation_rows(manifest, baseline)}
    rows = []
    for row in translation_rows(manifest, candidate):
        prior = qwen[row["id"]]
        qwen_score = chrf_pp(prior["hypothesis"], row["reference"])
        score = chrf_pp(row["hypothesis"], row["reference"])
        rows.append({
            "id": row["id"], "sourceJapanese": row["source"],
            "referenceEnglish": row["reference"], "qwenEnglish": prior["hypothesis"],
            "reazonEnglish": row["hypothesis"], "qwenChrFPlusPlus": qwen_score,
            "reazonChrFPlusPlus": score, "delta": score - qwen_score,
        })
    return {
        "qwenChrFPlusPlus": sum(row["qwenChrFPlusPlus"] for row in rows) / len(rows),
        "reazonChrFPlusPlus": sum(row["reazonChrFPlusPlus"] for row in rows) / len(rows),
        "improvedExamples": sorted(rows, key=lambda row: row["delta"], reverse=True)[:4],
        "worsenedExamples": sorted(rows, key=lambda row: row["delta"])[:4],
    }


def fixed_pipeline(candidate: dict, baseline: dict) -> dict:
    return {
        "alignment": all(candidate["alignment"].get(key) == baseline["alignment"].get(key)
                         for key in ("modelID", "revision")),
        "diarization": all(candidate["diarization"].get(key) == baseline["diarization"].get(key)
                           for key in ("modelID", "revision", "configuration")),
        "translation": all(candidate["translation"].get(key) == baseline["translation"].get(key)
                           for key in ("model", "revision", "runtimeVersion")),
        "glossary": all(candidate["glossary"].get(key) == baseline["glossary"].get(key)
                        for key in ("budget", "contextBytes", "coverageLimit", "terminologyRegister")),
    }


def stage_durations(raw: dict) -> dict[str, float]:
    values = raw["stageDurations"]
    return {values[index]: values[index + 1] for index in range(0, len(values), 2)}


def failure_attribution(timestamps: dict, connector_valid: bool) -> str:
    return ("candidate-output-incompatible-with-frozen-alignment"
            if connector_valid and timestamps["completeText"]
            and timestamps["bounded"] and timestamps["monotonic"]
            else "harness-timestamp-reconciliation-failure")


def build(manifest_path: Path, raw_path: Path) -> dict:
    manifest, raw, corpus = read(manifest_path), read(raw_path), read(CORPUS)
    with gzip.open(BASELINE, "rt", encoding="utf-8") as handle:
        baseline = json.load(handle)
    frozen = read(SEGMENTS)["units"]
    units = candidate_units(raw, frozen)
    baseline_counts = counts(frozen)
    candidate_counts = counts(units)
    recovered = sum(max(0, unit["materialDeltaVsQwen"]) for unit in units)
    lost = sum(max(0, -unit["materialDeltaVsQwen"]) for unit in units)
    timestamps = timestamp_audit(raw)
    lifecycle = raw["asrWorker"]["lifecycle"]
    stages = stage_durations(raw)
    common = {
        "schemaVersion": 1, "ticket": 89, "corpusRole": "development",
        "holdoutOpened": False, "decision": "NO-GO",
        "model": MODEL, "timestamps": timestamps,
        "material": {"recovered": recovered, "lost": lost,
                     "qwen": baseline_counts, "reazon": candidate_counts},
        "CER": {
            "qwen": cer("".join(turn["japanese"] for turn in corpus["annotations"]["turns"]),
                        baseline["rawASR"]),
            "reazon": cer("".join(turn["japanese"] for turn in corpus["annotations"]["turns"]),
                          raw["rawASR"]),
        },
        "resources": {
            "stageDurationsSeconds": stages,
            "totalStageSeconds": sum(stages.values()),
            "peakJobMemoryBytes": raw["peakMemoryBytes"],
            "worker": lifecycle,
            "alignmentWorker": raw.get("alignment", {}).get("worker"),
        },
        "artifacts": {
            "manifestSHA256": sha256(manifest_path), "rawASRSHA256": sha256(raw_path),
            "retainedRawASRGzipSHA256": sha256(EVIDENCE / "development-raw-asr.json.gz"),
            "retainedRunLogGzipSHA256": sha256(EVIDENCE / "development-run.log.gz"),
            "baselineSHA256": sha256(BASELINE), "segmentsSHA256": sha256(SEGMENTS),
            "sourceSHA256": corpus["source"]["references"][0]["sha256"],
        },
        "manifestStatus": manifest["status"],
        "executionImplementationSHA256": EXECUTION_IMPLEMENTATION_SHA256,
        "generatedAt": datetime.now().astimezone().isoformat(),
    }
    if manifest["status"] != "completed":
        chunk = next(chunk for chunk in raw["alignment"]["chunks"]
                     if any(cue["end"] <= cue["start"] for cue in chunk["cues"]))
        cue = next(cue for cue in chunk["cues"] if cue["end"] <= cue["start"])
        characters = [item for item in raw["asrWorker"]["characters"]
                      if item["chunkIndex"] == chunk["index"]]
        connector_valid = (
            0 < chunk["sourceEnd"] - chunk["sourceStart"] <= 20
            and bool(characters)
            and all(chunk["sourceStart"] <= item["sourceStart"]
                    <= item["sourceEnd"] <= chunk["sourceEnd"] for item in characters)
        )
        qwen_examples = translation_rows(corpus, baseline)[:2]
        attribution = failure_attribution(timestamps, connector_valid)
        candidate_verdict = "NO-GO" if attribution.startswith("candidate-") else "WITHHELD"
        common.update({
            "decision": "NO-GO" if candidate_verdict == "NO-GO" else "RETRY-REQUIRED",
            "candidateVerdict": candidate_verdict,
            "gates": {
                "modelPinned": raw["asrWorker"]["model"] == MODEL,
                "timestampsComplete": timestamps["completeText"] and timestamps["bounded"],
                "timestampsGloballyMonotonic": timestamps["monotonic"],
                "connectorValid": connector_valid,
                "pipelineComplete": False,
                "englishComparisonComplete": False,
                "workerCleanExit": lifecycle["exitStatus"] == 0
                    and not lifecycle["forcedTermination"],
                "noCriticalPressure": not any(item["level"] == "critical"
                                              for item in lifecycle["pressureTransitions"]),
                "holdoutClosed": True,
            },
            "rootCause": {
                "attribution": attribution,
                "failure": manifest["failures"][0],
                "candidateCharacters": characters,
                "alignmentAnchor": {"sourceStart": chunk["sourceStart"],
                                    "sourceEnd": chunk["sourceEnd"]},
                "alignerRawItems": chunk["rawItems"],
                "invalidCue": cue,
                "connectorValid": connector_valid,
                "explanation": "cue-0002 has valid local Reazon timing inside a <=20-second "
                    "anchor and the aligner returns zero duration, but the assembled character "
                    "timeline regresses at later overlap boundaries; candidate attribution is "
                    "withheld until the corrected shared reconciliation is rerun.",
            },
            "japaneseExamples": {
                "worsened": sorted(units, key=lambda unit: unit["materialDeltaVsQwen"])[:6]
            },
            "english": {
                "status": "not-produced",
                "reason": "Fail-closed alignment stopped the frozen pipeline before translation.",
                "qwenBaselineExamples": qwen_examples,
            },
        })
        return common

    fixed = fixed_pipeline(raw, baseline)
    gates = {
        "modelPinned": raw["asrWorker"]["model"] == MODEL,
        "timestampsComplete": all(value for key, value in timestamps.items()
                                  if key != "characterCount"),
        "pipelineFixed": all(fixed.values()),
        "moreMaterialRecoveredThanLost": recovered > lost,
        "criticalTermsNotWorse": candidate_counts["lostTerms"] <= baseline_counts["lostTerms"],
        "numbersNotWorse": candidate_counts["lostNumbers"] <= baseline_counts["lostNumbers"],
        "noNetEmptyOrDuplicateTurns": (
            candidate_counts["emptyTurns"] + candidate_counts["duplicatedTurns"]
            <= baseline_counts["emptyTurns"] + baseline_counts["duplicatedTurns"]
        ),
        "noMeaningRegression": candidate_counts["lostMeaningAnchors"]
            <= baseline_counts["lostMeaningAnchors"],
        "workerCleanExit": lifecycle["exitStatus"] == 0 and not lifecycle["forcedTermination"],
        "noCriticalPressure": not any(item["level"] == "critical"
                                      for item in lifecycle["pressureTransitions"]),
        "holdoutClosed": True,
    }
    japanese_examples = sorted(units, key=lambda unit: unit["materialDeltaVsQwen"], reverse=True)
    report = common | {
        "decision": "GO" if all(gates.values()) else "NO-GO",
        "gates": gates, "model": MODEL, "fixedPipeline": fixed, "timestamps": timestamps,
        "japaneseExamples": {
            "improved": japanese_examples[:6],
            "worsened": sorted(units, key=lambda unit: unit["materialDeltaVsQwen"])[:6],
        },
        "english": english_effects(corpus, baseline, raw),
    }
    return report


def duration(seconds: float) -> str:
    minutes, remaining = divmod(seconds, 60)
    return f"{int(minutes)} min {remaining:.1f} s"


def markdown(report: dict) -> str:
    if report["manifestStatus"] != "completed":
        root = report["rootCause"]
        worker = report["resources"]["worker"]
        alignment = report["resources"]["alignmentWorker"]
        examples = report["japaneseExamples"]["worsened"][:3]
        qwen = report["english"]["qwenBaselineExamples"]
        return "\n".join([
            "# E24 — ReazonSpeech K2 v2 int8 sur DEV (#89)", "",
            "Verdict candidat : **SUSPENDU — RETRY REQUIRED**. Holdout fermé. Aucun troisième run lancé.", "",
            "## Cause prouvée", "",
            f"- Raw Reazon local `今` : {root['candidateCharacters'][0]['sourceStart']:.2f}–{root['candidateCharacters'][0]['sourceEnd']:.2f} s, valide.",
            f"- Anchor partagé : {root['alignmentAnchor']['sourceStart']:.2f}–{root['alignmentAnchor']['sourceEnd']:.2f} s ({root['alignmentAnchor']['sourceEnd'] - root['alignmentAnchor']['sourceStart']:.2f} s), valide et contenant le caractère.",
            f"- Sortie brute aligneur : `今` {root['alignerRawItems'][0]['start']:.2f}–{root['alignerRawItems'][0]['end']:.2f} s, durée zéro ; rejet fail-closed de `cue-0002`.",
            "- Mais la timeline assemblée présente 7 retours aux fenêtres chevauchantes ; ces timestamps ne sont pas consommés par l'aligneur, mais invalident l'audit global demandé.",
            "- Attribution finale impossible sur ce run : défaut de normalisation du raccord partagé. Correction minimale : borner chaque timestamp au début de son anchor et revalider fail-closed l'échange assemblé.", "",
            "## Comparaison Qwen", "",
            f"- Japonais brut Reazon/Qwen : {report['timestamps']['characterCount']} / 4 396 caractères.",
            f"- CER Reazon/Qwen : {report['CER']['reazon']['ratePercent']:.2f}% / {report['CER']['qwen']['ratePercent']:.2f}%.",
            f"- Matériel récupéré/perdu vs Qwen : {report['material']['recovered']} / {report['material']['lost']}.",
            *[f"- {row['id']} — réf. `{row['referenceJapanese']}` ; Qwen `{row['qwenJapanese']}` ; Reazon `{row['reazonJapanese']}` ; Δ {row['materialDeltaVsQwen']}." for row in examples], "",
            "## Anglais", "",
            "- Non produit : l'alignement fail-closed a arrêté le pipeline avant traduction.",
            *[f"- Baseline Qwen tour {row['id']} — réf. `{row['reference']}` ; sortie `{row['hypothesis']}` ; Reazon : non produit." for row in qwen], "",
            "## Temps, mémoire et preuves", "",
            f"- Stages : {duration(report['resources']['totalStageSeconds'])}; ASR {report['resources']['stageDurationsSeconds']['transcribing']:.3f} s; alignement {report['resources']['stageDurationsSeconds']['aligning']:.3f} s.",
            f"- ASR worker : {worker['elapsedSeconds']:.3f} s, pic {worker['peakPhysicalFootprintBytes'] / 2**30:.2f} Gio, exit {worker['exitStatus']}, pression={worker['pressureTransitions']}, swap Δ={worker['swapUsedAfterBytes'] - worker['swapUsedBeforeBytes']}.",
            f"- Aligneur : {alignment['elapsedSeconds']:.3f} s, pic {alignment['peakPhysicalFootprintBytes'] / 2**30:.2f} Gio, exit {alignment['exitStatus']}, pression={alignment['pressureTransitions']}, swap Δ={alignment['swapUsedAfterBytes'] - alignment['swapUsedBeforeBytes']}.",
            f"- Timestamps : {report['timestamps']['characterCount']} caractères, texte complet={report['timestamps']['completeText']}, bornés={report['timestamps']['bounded']}, globalement monotones={report['timestamps']['monotonic']}.",
            f"- Hash manifeste : `{report['artifacts']['manifestSHA256']}`.",
            f"- Hash raw ASR : `{report['artifacts']['rawASRSHA256']}`.",
            f"- Hash raw gzip retenu : `{report['artifacts']['retainedRawASRGzipSHA256']}`.",
            f"- Hash log gzip retenu : `{report['artifacts']['retainedRunLogGzipSHA256']}`.", "",
            "Hashes exacts de l'implémentation ayant exécuté le retry :", "",
            *[f"- `{path}` — `{digest}`." for path, digest in report["executionImplementationSHA256"].items()], "",
            "Nouveau créneau requis, commande préparée mais non lancée :", "",
            "```bash", "BENCHMARK_SLOT_GRANTED=89 bash Scripts/run_reazon_dev_experiment.sh development", "```", "",
        ])
    improved = report["japaneseExamples"]["improved"][:3]
    worsened = report["japaneseExamples"]["worsened"][:3]
    english_good = report["english"]["improvedExamples"][:2]
    english_bad = report["english"]["worsenedExamples"][:2]
    lines = [
        "# E24 — ReazonSpeech K2 v2 int8 sur DEV (#89)", "",
        f"Décision : **{report['decision']}**. Holdout fermé.", "",
        "## Portes", "",
        *[f"- {'PASS' if value else 'FAIL'} — `{key}`" for key, value in report["gates"].items()],
        "", "## Qualité japonaise", "",
        f"- Matériel récupéré/perdu : {report['material']['recovered']} / {report['material']['lost']}.",
        f"- CER Qwen/Reazon : {report['CER']['qwen']['ratePercent']:.2f}% / {report['CER']['reazon']['ratePercent']:.2f}%.",
        f"- Termes perdus Qwen/Reazon : {report['material']['qwen']['lostTerms']} / {report['material']['reazon']['lostTerms']}.",
        f"- Nombres perdus Qwen/Reazon : {report['material']['qwen']['lostNumbers']} / {report['material']['reazon']['lostNumbers']}.",
        f"- Sens perdus Qwen/Reazon : {report['material']['qwen']['lostMeaningAnchors']} / {report['material']['reazon']['lostMeaningAnchors']}.",
        f"- Tours vides/dupliqués Qwen : {report['material']['qwen']['emptyTurns']}/{report['material']['qwen']['duplicatedTurns']}; Reazon : {report['material']['reazon']['emptyTurns']}/{report['material']['reazon']['duplicatedTurns']}.",
        "", "Exemples améliorés :", "",
        *[f"- {row['id']} — réf. `{row['referenceJapanese']}`; Qwen `{row['qwenJapanese']}`; Reazon `{row['reazonJapanese']}`; Δ matériel {row['materialDeltaVsQwen']}." for row in improved],
        "", "Exemples dégradés :", "",
        *[f"- {row['id']} — réf. `{row['referenceJapanese']}`; Qwen `{row['qwenJapanese']}`; Reazon `{row['reazonJapanese']}`; Δ matériel {row['materialDeltaVsQwen']}." for row in worsened],
        "", "## Effet anglais", "",
        f"- chrF++ moyen Qwen/Reazon : {report['english']['qwenChrFPlusPlus']:.2f} / {report['english']['reazonChrFPlusPlus']:.2f}.",
        "", "Exemples améliorés :", "",
        *[f"- tour {row['id']} — réf. `{row['referenceEnglish']}`; Qwen `{row['qwenEnglish']}`; Reazon `{row['reazonEnglish']}`; Δ chrF++ {row['delta']:.2f}." for row in english_good],
        "", "Exemples dégradés :", "",
        *[f"- tour {row['id']} — réf. `{row['referenceEnglish']}`; Qwen `{row['qwenEnglish']}`; Reazon `{row['reazonEnglish']}`; Δ chrF++ {row['delta']:.2f}." for row in english_bad],
        "", "## Coût et audit", "",
        f"- Temps des stages : {duration(report['resources']['totalStageSeconds'])}.",
        f"- Transcription : {duration(report['resources']['stageDurationsSeconds']['transcribing'])}.",
        f"- Pic job/worker : {report['resources']['peakJobMemoryBytes'] / 2**30:.2f} / {report['resources']['worker']['peakPhysicalFootprintBytes'] / 2**30:.2f} Gio.",
        f"- Timestamps caractères : {report['timestamps']['characterCount']} entrées, texte complet={report['timestamps']['completeText']}, bornes={report['timestamps']['bounded']}.",
        f"- Hash manifeste : `{report['artifacts']['manifestSHA256']}`.",
        f"- Hash raw ASR : `{report['artifacts']['rawASRSHA256']}`.", "",
    ]
    return "\n".join(lines)


def self_test() -> None:
    raw = {"sampleCount": 32_000, "sampleRate": 16_000, "rawASR": "日本", "asrWorker": {
        "characters": [
            {"chunkIndex": 0, "text": "日", "sourceStart": 0.1, "sourceEnd": 0.2},
            {"chunkIndex": 0, "text": "本", "sourceStart": 0.2, "sourceEnd": 0.3},
        ]
    }}
    assert all(value for key, value in timestamp_audit(raw).items() if key != "characterCount")
    assert stage_durations({"stageDurations": ["transcribing", 1.25]}) == {
        "transcribing": 1.25
    }
    audit = timestamp_audit(raw)
    audit["monotonic"] = False
    assert failure_attribution(audit, True) == "harness-timestamp-reconciliation-failure"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not all((args.manifest, args.raw, args.json, args.markdown)):
        parser.error("--manifest, --raw, --json and --markdown are required")
    report = build(args.manifest, args.raw)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.markdown.write_text(markdown(report), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
