#!/usr/bin/env python3
"""Freeze the #91 Qwen selection and FireRed no-run from existing DEV evidence."""

import argparse
import hashlib
import json
from pathlib import Path


EXPECTED_SHA256 = {
    "qwenDiagnostic": "0e43cbd5c7f4d6dd0b4706710fb9e473306a40dd7530f72ee2c4dc36a16e8c6a",
    "funASR": "56deb9adbef7da757154e7c86bb598cfc90bf7dd232eb92ec298060888c446bc",
    "reazon": "fdb32727c899c1ee0516ab9ab43bd11531ab789b5f4ab7914c8bd284e73b2ea4",
    "qwenAnime": "e90c4bf6af835ff3eb181a91670b34aa54a8b714820873b4e45b657e6685513f",
}
EXPECTED_CONTROLS_SHA256 = "4a97a592cc5c000a9bbd1318b7352eefc7933c00fe699475b8217911181dec83"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def build_report(qwen: dict, funasr: dict, reazon: dict, anime: dict,
                 source_hashes: dict[str, str], artifact_hashes: dict[str, str],
                 controls: dict) -> dict:
    require(qwen.get("ticket") == 87, "expected the frozen #87 diagnostic")
    require(qwen.get("holdoutOpened") is False, "#87 holdout must remain closed")
    require(qwen.get("fireRed", {}).get("eligible") is False,
            "FireRed is eligible; #91 requires an isolated experiment, not this no-run")
    require(funasr.get("ticket") == 88 and funasr.get("readyForFullDevelopment") is False,
            "Fun-ASR is not the frozen #88 NO-GO")
    require(funasr.get("decision") ==
            "NO-GO-unproven-upstream-provenance-and-smoke-generation-runaway",
            "unexpected Fun-ASR decision")
    require(reazon.get("ticket") == 89 and reazon.get("candidateVerdict") == "NO-GO",
            "Reazon is not the frozen #89 NO-GO")
    require(anime.get("ticket") == 90 and anime.get("decision") ==
            "no-go-license-non-eligible", "Qwen Anime is not the frozen #90 NO-GO")
    require(all(row.get("holdoutOpened") is False
                for row in (funasr, reazon, anime)), "a candidate opened the holdout")
    require(controls.get("ticket") == 91 and controls.get("holdoutOpened") is False,
            "invalid #91 controls")
    require(controls.get("modelRunsLaunched") == 0,
            "the no-run controls report a model launch")
    require(controls.get("tests", {}).get("failed") == 0,
            "the #91 control tests did not pass")
    require(controls.get("metallib", {}).get("passed") is True,
            "the #91 metallib control did not pass")

    counts = qwen["counts"]
    fire_red = qwen["fireRed"]
    model = qwen["provenance"]["e22Model"]
    examples = qwen["representativeMaterialErrors"][:3]
    empty = qwen["turnIntegrity"]["empty"][:1]
    return {
        "schemaVersion": 1,
        "ticket": 91,
        "decision": "NO-RUN-fireRed-ineligible",
        "corpusRole": "development",
        "selection": {
            "rule": "promote a DEV candidate only after admissibility and material improvement; otherwise retain Qwen",
            "selected": {
                "recipe": "E22 Standard Qwen with its current segmentation",
                "backend": model["backend"],
                "modelID": model["modelID"],
                "revision": model["revision"],
                "weightSHA256": model["weightSHA256"],
                "reason": "all three new candidates are NO-GO; Qwen is the specified fallback",
            },
            "candidates": [
                {
                    "ticket": 88,
                    "name": "Fun-ASR Nano int8",
                    "eligible": False,
                    "decision": funasr["decision"],
                    "materialEvidence": {
                        "repeatedPhrase": funasr["smoke"]["repeatedPhrase"],
                        "repeatedPhraseCount": funasr["smoke"]["repeatedPhraseCount"],
                        "rawTokenCounts": funasr["smoke"]["rawTokenCounts"],
                    },
                    "harnessErrors": funasr["harnessErrors"],
                },
                {
                    "ticket": 89,
                    "name": "ReazonSpeech K2 v2 int8",
                    "eligible": False,
                    "decision": reazon["candidateVerdict"],
                    "materialEvidence": reazon["material"],
                    "harnessAttribution": reazon["rootCause"]["attribution"],
                },
                {
                    "ticket": 90,
                    "name": "Qwen Anime/Galgame",
                    "eligible": False,
                    "decision": anime["decision"],
                    "licenseEligible": anime["licenseGate"][
                        "eligibleForLocalProductIntegrationAndDistribution"
                    ],
                    "execution": anime["execution"],
                },
            ],
        },
        "segmentationGate": {
            **fire_red,
            "action": "no FireRed run and no segmentation comparison",
            "candidateDeltas": None,
        },
        "frozenBaselineEvidence": {
            "speechRecoveredCharacters": counts["speechRecoveredCharacters"],
            "speechLostCharacters": counts["speechLostCharacters"],
            "emptyTurns": counts["emptyTurns"],
            "duplicatedTurns": counts["duplicatedTurns"],
            "termsRecovered": counts["termRecovered"],
            "termsLost": counts["termLost"],
            "numbersRecovered": counts["numberRecovered"],
            "numbersLost": counts["numberLost"],
            "meaningRecovered": counts["meaningRecovered"],
            "meaningLost": counts["meaningLost"],
            "examples": examples + empty,
            "candidateEffects": "not measured because the prerequisite gate denied the run",
        },
        "execution": {
            "modelRunsLaunched": 0,
            "fireRedRuntimeSeconds": 0.0,
            "fireRedPeakMemoryBytes": None,
            "memoryReason": "no FireRed process was launched",
            "reusedQwenPeakMemoryBytes": qwen["timings"]["reusedE22PeakMemoryBytes"],
            "holdoutOpened": False,
            "heavyBenchmarkAuthorized": False,
        },
        "controls": {
            "sourceReportsSHA256": source_hashes,
            "verifiedArtifactsSHA256": artifact_hashes,
            "verification": controls,
            "buildRunnerFailuresSeparated": True,
            "noInventedMetrics": True,
        },
        "timings": {
            "reusedE22TotalSeconds": qwen["timings"]["reusedE22TotalSeconds"],
            "reusedE22TranscriptionSeconds": qwen["timings"][
                "reusedE22TranscriptionSeconds"
            ],
        },
        "productChanges": "none",
        "uiChanges": "none",
        "standardDefaultsChanged": False,
        "liveChanges": "none",
        "provenance": {"reporterSHA256": sha256(Path(__file__))},
    }


def markdown(report: dict) -> str:
    gate = report["segmentationGate"]
    baseline = report["frozenBaselineEvidence"]
    candidates = report["selection"]["candidates"]
    lines = [
        "# E25 — Sélection Qwen et no-run FireRed (#91)", "",
        "**NO-RUN.** Qwen E22 reste la meilleure recette single-ASR DEV. "
        "Le holdout reste fermé ; aucun modèle, UI, Live ou défaut Standard n’est modifié.", "",
        "## Sélection ASR", "",
        "| Candidat | Verdict figé | Motif matériel |", "|---|---|---|",
        f"| {candidates[0]['name']} | NO-GO | répétition « "
        f"{candidates[0]['materialEvidence']['repeatedPhrase']} » ×"
        f"{candidates[0]['materialEvidence']['repeatedPhraseCount']} et provenance amont non prouvée |",
        f"| {candidates[1]['name']} | NO-GO | 0 récupéré, "
        f"{candidates[1]['materialEvidence']['lost']} perdus face à Qwen |",
        f"| {candidates[2]['name']} | NO-GO | licence non admissible ; aucun poids ni run |",
        "", "Qwen est donc conservé par la règle de fallback du ticket, avec son modèle, "
        "ses poids et sa segmentation E22 inchangés.", "",
        "## Porte FireRed", "",
        f"E23 compte {gate['boundaryLossUnitsOrFragments']}/"
        f"{gate['lossUnitsOrUnassignedCueFragments']} pertes près des frontières "
        f"({gate['boundaryLossShare'] * 100:.1f} %), pour une exposition de "
        f"{gate['boundaryExposureShare'] * 100:.1f} % et une concentration de "
        f"{gate['concentrationRatio']:.2f}×. La porte exige 60 % et 1,5× : "
        f"**{gate['decision']}**.", "",
        "Conséquence : aucune frontière FireRed, aucun delta de trous/duplications, "
        "aucun ASR, alignement ou anglais candidat n’est produit. Ce sont des valeurs "
        "absentes, pas des métriques nulles inventées.", "",
        "## Preuve DEV conservée", "",
        f"- Qwen : {baseline['speechRecoveredCharacters']} caractères récupérés, "
        f"{baseline['speechLostCharacters']} perdus/substitués ; "
        f"{baseline['emptyTurns']} tours vides et {baseline['duplicatedTurns']} dupliqué.",
        f"- Termes {baseline['termsRecovered']}/{baseline['termsLost']} récupérés/perdus ; "
        f"nombres {baseline['numbersRecovered']}/{baseline['numbersLost']} ; "
        f"sens {baseline['meaningRecovered']}/{baseline['meaningLost']}.",
    ]
    for row in baseline["examples"]:
        lines.append(
            f"- {row['start']:.2f}–{row['end']:.2f} s — référence : "
            f"« {row['referenceJapanese']} » ; Qwen : « {row.get('qwenJapanese', '')} »."
        )
    lines += [
        "", "## Exécution et contrôles", "",
        "- 0 modèle lancé ; temps FireRed 0,00 s ; mémoire FireRed non applicable ; "
        f"pic Qwen E22 réutilisé {report['execution']['reusedQwenPeakMemoryBytes']} octets.",
        "- Les erreurs de harnais #88/#89 restent attribuées séparément des NO-GO candidats.",
        f"- Xcode {report['controls']['verification']['xcode']['version']}, metallib vérifié "
        f"(`{report['controls']['verification']['metallib']['sha256']}`), "
        f"{report['controls']['verification']['tests']['executed']} tests, "
        f"{report['controls']['verification']['tests']['skippedOptIn']} opt-in ignorés, 0 échec.",
        "- Entrée, audio, référence, poids Qwen, metallib et rapports sources sont réellement "
        "relus et vérifiés par SHA-256.",
        "- Holdout fermé ; aucun changement produit, UI, défaut Standard ou Live.", "",
        "Reproduction : `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash "
        "Scripts/build_mlx_metallib.sh debug && python3 Scripts/report_firered_no_run.py`.", "",
    ]
    return "\n".join(lines)


def self_test() -> None:
    qwen = {
        "ticket": 87, "holdoutOpened": False,
        "fireRed": {"eligible": False, "decision": "ineligible"},
        "counts": {key: 0 for key in (
            "speechRecoveredCharacters", "speechLostCharacters", "emptyTurns",
            "duplicatedTurns", "termRecovered", "termLost", "numberRecovered",
            "numberLost", "meaningRecovered", "meaningLost")},
        "provenance": {"e22Model": {"backend": "qwen-ja", "modelID": "qwen",
            "revision": "r", "weightSHA256": {}}, "hashes": {}},
        "representativeMaterialErrors": [], "turnIntegrity": {"empty": []},
        "timings": {"reusedE22TotalSeconds": 1, "reusedE22TranscriptionSeconds": 1,
                    "reusedE22PeakMemoryBytes": 1},
    }
    funasr = {"ticket": 88, "holdoutOpened": False, "readyForFullDevelopment": False,
        "decision": "NO-GO-unproven-upstream-provenance-and-smoke-generation-runaway",
        "smoke": {"repeatedPhrase": "x", "repeatedPhraseCount": 1,
                  "rawTokenCounts": [1]}, "harnessErrors": []}
    reazon = {"ticket": 89, "holdoutOpened": False, "candidateVerdict": "NO-GO",
        "material": {"recovered": 0, "lost": 1},
        "rootCause": {"attribution": "harness"}}
    anime = {"ticket": 90, "holdoutOpened": False,
        "decision": "no-go-license-non-eligible",
        "licenseGate": {"eligibleForLocalProductIntegrationAndDistribution": False},
        "execution": {}}
    controls = {"ticket": 91, "holdoutOpened": False, "modelRunsLaunched": 0,
                "tests": {"failed": 0}, "metallib": {"passed": True}}
    report = build_report(qwen, funasr, reazon, anime, {}, {}, controls)
    assert report["selection"]["selected"]["backend"] == "qwen-ja"
    assert report["execution"]["modelRunsLaunched"] == 0
    assert report["execution"]["fireRedPeakMemoryBytes"] is None
    qwen["fireRed"]["eligible"] = True
    try:
        build_report(qwen, funasr, reazon, anime, {}, {}, controls)
    except RuntimeError:
        pass
    else:
        raise AssertionError("an eligible FireRed diagnostic must not produce a no-run")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--qwen", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/E23/report.json"))
    parser.add_argument("--funasr", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/E24/smoke-report.json"))
    parser.add_argument("--reazon", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/ReazonK2V2/report.json"))
    parser.add_argument("--anime", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/E24/qualification.json"))
    parser.add_argument("--controls", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/E25/controls.json"))
    parser.add_argument("--manifest", type=Path, default=Path(
        "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"))
    parser.add_argument("--raw-e22", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz"))
    parser.add_argument("--e22-report", type=Path, default=Path(
        "docs/high-quality-standard-e22.json"))
    parser.add_argument("--source", type=Path, default=Path(
        "/Users/maz/Documents/videos/jap/1/Video1.webm"))
    parser.add_argument("--audio", type=Path, default=Path(
        "/Users/maz/Documents/projets/whisperASR/.build/benchmarks/japanese-live/corpora/"
        "qudu2fx3ncc/audio-16k-mono.wav"))
    parser.add_argument("--character-alignment", type=Path, default=Path(
        "/Users/maz/Documents/projets/whisperASR/.build/benchmarks/japanese-live/corpora/"
        "qudu2fx3ncc/character-alignment.jsonl"))
    parser.add_argument("--qwen-weight", type=Path, default=Path(
        "/Users/maz/Library/Caches/qwen3-speech/models/ph0ryn/"
        "Qwen3-ASR-1.7B-JA-MLX-8bit/model.safetensors"))
    parser.add_argument("--metallib", type=Path, default=Path(
        ".build/debug/mlx.metallib"))
    parser.add_argument("--report", type=Path, default=Path(
        "docs/japanese-live/experiments/evidence/E25/report.json"))
    parser.add_argument("--markdown", type=Path, default=Path(
        "docs/japanese-live/experiments/E25-qwen-firered-no-run.md"))
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    paths = {"qwenDiagnostic": args.qwen, "funASR": args.funasr,
             "reazon": args.reazon, "qwenAnime": args.anime}
    observed = {name: sha256(path) for name, path in paths.items()}
    require(observed == EXPECTED_SHA256,
            f"frozen source report hashes changed: {observed}")
    loaded = {name: json.loads(path.read_text(encoding="utf-8"))
              for name, path in paths.items()}
    require(sha256(args.controls) == EXPECTED_CONTROLS_SHA256,
            "the frozen #91 controls changed")
    controls = json.loads(args.controls.read_text(encoding="utf-8"))
    artifact_paths = {
        "manifest": args.manifest,
        "rawE22": args.raw_e22,
        "e22Report": args.e22_report,
        "source": args.source,
        "audio": args.audio,
        "characterAlignment": args.character_alignment,
        "qwenWeight": args.qwen_weight,
        "metallib": args.metallib,
    }
    artifact_hashes = {name: sha256(path) for name, path in artifact_paths.items()}
    expected_artifacts = dict(loaded["qwenDiagnostic"]["provenance"]["hashes"])
    expected_artifacts["qwenWeight"] = loaded["qwenDiagnostic"]["provenance"][
        "e22Model"
    ]["weightSHA256"]["model.safetensors"]
    expected_artifacts["metallib"] = controls["metallib"]["sha256"]
    require(artifact_hashes == expected_artifacts,
            f"frozen input, reference, model, or metallib changed: {artifact_hashes}")
    report = build_report(loaded["qwenDiagnostic"], loaded["funASR"],
                          loaded["reazon"], loaded["qwenAnime"], observed,
                          artifact_hashes, controls)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")
    args.markdown.write_text(markdown(report), encoding="utf-8")


if __name__ == "__main__":
    main()
