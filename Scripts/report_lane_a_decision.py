#!/usr/bin/env python3
"""Freeze the #96 Lane A DEV winner and the resulting holdout no-run."""

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE_COMMIT = "ad3d56feffec443e36af7adb68ce7fa9b3e4f32c"
EXPECTED_SOURCES_TREE_SHA256 = "a11fc98669da14c30db3e3cea5c1e2a16342b84c970fbd2eae5277e0d6bb30e7"
EXPECTED_PACKAGE_SHA256 = {
    "Package.swift": "ab6236f33ff99c10d6caaa51da856735cd3a6f93d7b3e9fa28d939edf0719c36",
    "Package.resolved": "71d9161262d1962dd6775c3f9aacf0a9a677d8dfc042e2dfa8c49669e885e41f",
}
REPORTS = {
    "qwenDiagnostic": (
        "docs/japanese-live/experiments/evidence/E23/report.json",
        "0e43cbd5c7f4d6dd0b4706710fb9e473306a40dd7530f72ee2c4dc36a16e8c6a",
    ),
    "funASR": (
        "docs/japanese-live/experiments/evidence/E24/smoke-report.json",
        "56deb9adbef7da757154e7c86bb598cfc90bf7dd232eb92ec298060888c446bc",
    ),
    "reazon": (
        "docs/japanese-live/experiments/evidence/ReazonK2V2/report.json",
        "fdb32727c899c1ee0516ab9ab43bd11531ab789b5f4ab7914c8bd284e73b2ea4",
    ),
    "qwenAnime": (
        "docs/japanese-live/experiments/evidence/E24/qualification.json",
        "e90c4bf6af835ff3eb181a91670b34aa54a8b714820873b4e45b657e6685513f",
    ),
    "fireRed": (
        "docs/japanese-live/experiments/evidence/E25/report.json",
        "8fa4460e1d9b599e6d1dffa40af024e80223380e118f6164359cbbfd2f0f1330",
    ),
    "hotwords": (
        "docs/japanese-live/experiments/evidence/E26/report.json",
        "a065bfcfcc9260660cb4fe00f4c788de37c428febd8f9067e77b69571aebd518",
    ),
    "voiceMusic": (
        "docs/japanese-live/experiments/evidence/E27/report.json",
        "fe0e73831af465a3c526639973b78e8cd65cc61f8a86771fb610289c3323816b",
    ),
    "adaptive": (
        "docs/japanese-live/experiments/evidence/E28/report.json",
        "25d38a79db2673a9baac37be0d376a70cfe0abbb74d8c35f4729696f248a4fee",
    ),
    "whisperKit": (
        "docs/japanese-live/experiments/evidence/E29/report.json",
        "5871c72dc44a7ac1bac93e7815cf612adc0a896344950aff0bf7abd85164c863",
    ),
}
RAW_ARTIFACTS = {
    "voiceMusicCandidateRaw": (
        "docs/japanese-live/experiments/evidence/E27/corrected-resume-failure-raw-asr.json.gz",
        "dcf8b3d4cab5976010fbfcc44aa51b4c8ef06840674f8e89d9bf94d02d8e6eb8",
    ),
    "adaptiveCandidateRaw": (
        "docs/japanese-live/experiments/evidence/E28/candidate-raw-asr.json.gz",
        "51e9e3fc7a9833711b659526d221dbe97a5edb89d74fa6bff345d2f5bd2e68a9",
    ),
    "adaptiveTranslationLog": (
        "docs/japanese-live/experiments/evidence/E28/targeted-translation.log.gz",
        "2f2a933138c8000d3166affd43d0411bd17659e7c88f2e0a2880fedfd6cf85b6",
    ),
    "whisperKitRun": (
        "docs/japanese-live/experiments/evidence/E29/whisperkit-run.json",
        "e5903c6cde8d79b95f8cb375ceb3d867cd2ab3b07964e29bd4f39bfe450477d3",
    ),
    "whisperKitLog": (
        "docs/japanese-live/experiments/evidence/E29/whisperkit.log.gz",
        "1c815658f60feacae28fb20d7ec31fc2c22a4aa1fb4a442e4043d381b24912ea",
    ),
    "whisperKitSelection": (
        "docs/japanese-live/experiments/evidence/E29/selection-report.json",
        "680c739c9f1eebb63fd106b5fc6ef2dc39ffb5e477a4c99f8f96880c36b31b15",
    ),
    "whisperKitTriggerPlan": (
        "docs/japanese-live/experiments/evidence/E29/trigger-plan.json",
        "fcefb0d8a543e572a5356b76ed98833cdf247049e547079bdf8e788502c70b16",
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_tree_sha256(path: Path) -> str:
    manifest = "".join(
        f"{sha256(item)}  {item.relative_to(ROOT)}\n"
        for item in sorted(path.rglob("*")) if item.is_file()
    )
    return hashlib.sha256(manifest.encode()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def choose_winner(candidates: list[dict]) -> dict:
    eligible = [candidate for candidate in candidates if candidate["distinct"] and all((
        candidate["admissible"], candidate["completeReference"],
        candidate["japanesePass"], candidate["englishPass"],
        candidate["noCriticalLoss"], candidate["stable"], candidate["costPass"],
    ))]
    require(len(eligible) <= 1, "multiple distinct DEV candidates require an explicit comparison")
    return eligible[0] if eligible else next(
        candidate for candidate in candidates if candidate["id"] == "qwen-standard"
    )


def validate_inputs(reports: dict[str, dict], controls: dict) -> None:
    expected = {
        "qwenDiagnostic": (87, "qwen-diagnostic-frozen-development-only"),
        "funASR": (88, "NO-GO-unproven-upstream-provenance-and-smoke-generation-runaway"),
        "reazon": (89, "NO-GO"),
        "qwenAnime": (90, "no-go-license-non-eligible"),
        "fireRed": (91, "NO-RUN-fireRed-ineligible"),
        "hotwords": (92, "INAPPLICABLE-NO-RUN-no-native-hotword-mechanism"),
        "voiceMusic": (93, "NO-GO-stop-before-holdout"),
        "adaptive": (94, "NO-GO-english-regression-stop-before-holdout"),
        "whisperKit": (95, "INCONCLUSIVE_REFERENCE_HARNESS_NO_DOWNSTREAM"),
    }
    for name, (ticket, decision) in expected.items():
        report = reports[name]
        require(report.get("ticket") == ticket, f"{name} ticket changed")
        require(report.get("decision") == decision, f"{name} decision changed")
        holdout_opened = report.get("holdoutOpened", report.get("execution", {}).get("holdoutOpened"))
        require(holdout_opened is False, f"{name} opened the holdout")
    adaptive = reports["adaptive"]
    whisperkit = reports["whisperKit"]
    require(adaptive["japanese"]["qwenEdits"] == 3273
            and adaptive["japanese"]["selectedEdits"] == 3229,
            "#94 Japanese comparison changed")
    require(adaptive["english"]["delta"] < 0 and adaptive["promote"] is False,
            "#94 no longer has the frozen English veto")
    require(whisperkit["classification"] == "harness-reference-coverage-gap"
            and whisperkit["diagnostic"]["modelConclusion"] is None
            and whisperkit["trigger"]["referenceEvaluability"]["completeWindowCount"] == 1
            and whisperkit["trigger"]["referenceEvaluability"]["windowCount"] == 6,
            "#95 is no longer the frozen reference-harness inconclusive result")
    require(controls.get("ticket") == 96 and controls.get("baseCommit") == BASE_COMMIT,
            "invalid #96 controls")
    require(controls.get("modelRunsLaunched") == 0
            and controls.get("holdoutOpened") is False
            and controls.get("benchmarkSlotGranted") is False,
            "#96 controls spent model or holdout budget")
    require(controls.get("reporterSelfTestPassed") is True
            and controls.get("build", {}).get("exitCode") == 0
            and controls.get("tests", {}).get("exitCode") == 0,
            "#96 lightweight controls failed")
    require(controls.get("initialTestFailure", {}).get("classification")
            == "infrastructure-missing-metallib"
            and controls.get("metallib", {}).get("passed") is True,
            "the build/harness diagnosis is incomplete")
    require(controls.get("appLaunch", {}).get("exitCode") == 0
            and controls.get("appLaunch", {}).get("classification")
            == "expected-single-instance-lock"
            and controls.get("appLaunch", {}).get("existingInstanceRemainedActive") is True,
            "the application launch did not pass")
    require(controls.get("sourcesTreeSHA256") == EXPECTED_SOURCES_TREE_SHA256,
            "product Sources are not byte-identical to the #95 base")
    for key in ("build", "initialTestFailure", "tests", "appLaunch"):
        log = ROOT / controls[key]["rawLog"]
        require(sha256(log) == controls[key]["rawLogSHA256"], f"{key} log hash changed")
    metallib = ROOT / controls["metallib"]["path"]
    require(sha256(metallib) == controls["metallib"]["sha256"],
            "the verified metallib changed")


def build_report(reports: dict[str, dict], report_hashes: dict[str, str],
                 raw_hashes: dict[str, str], controls: dict) -> dict:
    qwen = reports["qwenDiagnostic"]
    funasr = reports["funASR"]
    reazon = reports["reazon"]
    anime = reports["qwenAnime"]
    fire_red = reports["fireRed"]
    hotwords = reports["hotwords"]
    voice_music = reports["voiceMusic"]
    adaptive = reports["adaptive"]
    whisperkit = reports["whisperKit"]
    model = qwen["provenance"]["e22Model"]
    candidates = [
        {"id": "qwen-standard", "name": "Qwen JA standard", "kind": "single-ASR",
         "distinct": False, "admissible": True, "completeReference": True,
         "japanesePass": True, "englishPass": True, "noCriticalLoss": True,
         "stable": True, "costPass": True},
        {"id": "qwen-parakeet", "name": "Qwen + Parakeet", "kind": "adaptive-ASR",
         "distinct": True, "admissible": True, "completeReference": True,
         "japanesePass": adaptive["developmentEligibleJapanese"],
         "englishPass": adaptive["gates"]["englishNotWorse"],
         "noCriticalLoss": all((adaptive["gates"]["termsNumbersMeaningNotWorse"],
                                adaptive["gates"]["noAddedDuplicate"],
                                adaptive["gates"]["noAddedEmptySpeech"])),
         "stable": all((adaptive["gates"]["noMaterialThresholdVariation"],
                        adaptive["gates"]["timelineCompleteWithoutGapOrDuplication"])),
         "costPass": adaptive["gates"]["costNotRunaway"]},
        {"id": "qwen-parakeet-whisperkit", "name": "WhisperKit ciblé", "kind": "adaptive-ASR",
         "distinct": True, "admissible": True,
         "completeReference": whisperkit["japanese"]["gates"]["completeReferenceCoverageForOverrides"],
         "japanesePass": whisperkit["japanese"]["developmentEligible"],
         "englishPass": whisperkit["english"]["run"],
         "noCriticalLoss": all((whisperkit["japanese"]["badWhisperKitOverrides"] == 0,
                                whisperkit["japanese"]["gates"]["noAddedDuplicate"],
                                whisperkit["japanese"]["gates"]["noAddedEmpty"],
                                whisperkit["japanese"]["gates"]["termsNumbersMeaningNotWorse"])),
         "stable": all((whisperkit["japanese"]["gates"]["selectorCalibratedByBlocks"],
                        whisperkit["japanese"]["gates"]["triggerCalibratedAndSparse"],
                        whisperkit["japanese"]["gates"]["workerExitedCleanly"])),
         "costPass": whisperkit["runtime"]["allHeavyWorkersClean"]},
    ]
    winner = choose_winner(candidates)
    require(winner["id"] == "qwen-standard", "frozen #96 evidence unexpectedly requires holdout")
    counts = qwen["counts"]
    tracks = [
        {
            "id": "qwen-standard", "decision": "WINNER_BASELINE", "admissible": True,
            "speech": {"recoveredCharacters": counts["speechRecoveredCharacters"],
                       "lostOrSubstitutedCharacters": counts["speechLostCharacters"],
                       "emptyTurns": counts["emptyTurns"], "duplicatedTurns": counts["duplicatedTurns"]},
            "terms": {"recovered": counts["termRecovered"], "lost": counts["termLost"]},
            "numbers": {"recovered": counts["numberRecovered"], "lost": counts["numberLost"]},
            "meaning": {"recovered": counts["meaningRecovered"], "lost": counts["meaningLost"]},
            "english": {"chrFPlusPlus": adaptive["english"]["baselineChrFPlusPlus"]},
            "cost": {"developmentASRSeconds": qwen["timings"]["reusedE22TranscriptionSeconds"],
                     "fullEvidenceSeconds": {
                         "e23Report": qwen["timings"]["reusedE22TotalSeconds"],
                         "e24FrozenTiming": anime["frozenTimings"]["e22DevelopmentTotalSeconds"],
                         "status": "source-disagreement-retained",
                     },
                     "peakMemoryBytes": qwen["timings"]["reusedE22PeakMemoryBytes"]},
            "consequence": "baseline Lane A retained; no identifiable holdout gain",
        },
        {
            "id": "funasr", "decision": funasr["decision"], "admissible": False,
            "speech": {"status": "smoke-generation-runaway", "repeatedPhrase": funasr["smoke"]["repeatedPhrase"],
                       "repeatedPhraseCount": funasr["smoke"]["repeatedPhraseCount"]},
            "terms": None, "numbers": None, "meaning": None, "english": None,
            "cost": {"workerSeconds": funasr["smoke"]["workerElapsedSeconds"],
                     "peakMemoryBytes": funasr["smoke"]["peakPhysicalFootprintBytes"]},
            "consequence": "stopped after smoke; no full DEV or English",
        },
        {
            "id": "reazon", "decision": reazon["candidateVerdict"], "admissible": False,
            "speech": {"recoveredVsQwen": reazon["material"]["recovered"],
                       "lostVsQwen": reazon["material"]["lost"],
                       "characters": reazon["CER"]["reazon"]["hypothesisCharacterCount"],
                       "CERPercent": reazon["CER"]["reazon"]["ratePercent"]},
            "terms": {"lost": reazon["material"]["reazon"]["lostTerms"]},
            "numbers": {"lost": reazon["material"]["reazon"]["lostNumbers"]},
            "meaning": {"lost": reazon["material"]["reazon"]["lostMeaningAnchors"]},
            "english": None,
            "cost": {"workerSeconds": reazon["resources"]["worker"]["elapsedSeconds"],
                     "peakMemoryBytes": reazon["resources"]["peakJobMemoryBytes"]},
            "consequence": "quality collapse; downstream stopped despite corrected ULP harness bug",
        },
        {
            "id": "qwen-anime", "decision": anime["decision"], "admissible": False,
            "speech": None, "terms": None, "numbers": None, "meaning": None, "english": None,
            "cost": {"runtimeSeconds": 0.0, "peakMemoryBytes": None},
            "consequence": "license blocks weights, smoke, DEV and product distribution",
        },
        {
            "id": "firered", "decision": fire_red["decision"], "admissible": False,
            "speech": None, "terms": None, "numbers": None, "meaning": None, "english": None,
            "cost": {"runtimeSeconds": 0.0, "peakMemoryBytes": None},
            "consequence": "boundary-loss concentration gate failed; no candidate run",
        },
        {
            "id": "hotwords", "decision": hotwords["decision"], "admissible": False,
            "speech": None, "terms": None, "numbers": None, "meaning": None, "english": None,
            "cost": {"runtimeSeconds": 0.0, "peakMemoryBytes": None},
            "consequence": "no mechanism distinct from the rejected system prompt",
        },
        {
            "id": "qwen-spleeter", "decision": voice_music["decision"], "admissible": False,
            "speech": {"recoveredCharacterDelta": voice_music["rawQwenComparison"]["recoveredCharacterDelta"],
                       "candidateEmptyTurns": voice_music["alignedWindowDiagnostic"]["counts"]["candidateEmptyTurns"],
                       "candidateDuplicates": voice_music["alignedWindowDiagnostic"]["counts"]["candidateDuplicates"]},
            "terms": {"delta": 0}, "numbers": {"delta": 0}, "meaning": {"delta": 0},
            "english": None,
            "cost": {"preprocessingSeconds": voice_music["runtime"]["separator"]["elapsedSeconds"],
                     "jobSeconds": voice_music["runtime"]["jobStageSeconds"],
                     "peakMemoryBytes": voice_music["runtime"]["peakJobMemoryBytes"]},
            "consequence": "lost 31 speech characters, added target empties/duplicate, alignment failed",
        },
        {
            "id": "qwen-parakeet", "decision": adaptive["decision"], "admissible": False,
            "speech": {"qwenEdits": adaptive["japanese"]["qwenEdits"],
                       "candidateEdits": adaptive["japanese"]["selectedEdits"], "editGain": 44,
                       "emptyTurns": adaptive["japanese"]["selectedEmpty"],
                       "duplicates": adaptive["japanese"]["selectedDuplicates"]},
            "terms": {"qwen": 7, "candidate": 7}, "numbers": {"qwen": 11, "candidate": 11},
            "meaning": {"qwen": 6, "candidate": 6},
            "english": {"baselineChrFPlusPlus": adaptive["english"]["baselineChrFPlusPlus"],
                        "candidateChrFPlusPlus": adaptive["english"]["candidateChrFPlusPlus"],
                        "delta": adaptive["english"]["delta"]},
            "cost": {"commandSeconds": adaptive["runtime"]["totalCommandSeconds"],
                     "modelWorkerSeconds": adaptive["runtime"]["totalModelWorkerSeconds"],
                     "peakMemoryBytes": adaptive["runtime"]["peakPhysicalFootprintBytes"]},
            "consequence": "44 Japanese edits recovered but final English regressed; holdout veto",
        },
        {
            "id": "targeted-whisperkit", "decision": whisperkit["decision"], "admissible": False,
            "speech": {"qwenEdits": 3273, "adaptiveEdits": 3229,
                       "provisionalCandidateEdits": whisperkit["japanese"]["provisionalCandidateEdits"],
                       "validCandidateEdits": None},
            "terms": {"provisional": 7}, "numbers": {"provisional": 11},
            "meaning": {"provisional": 6}, "english": None,
            "cost": {"targetSeconds": whisperkit["trigger"]["seconds"],
                     "commandSeconds": whisperkit["runtime"]["whisperKitCommandSeconds"],
                     "workerSeconds": whisperkit["runtime"]["whisperKitWorkerSeconds"],
                     "peakMemoryBytes": whisperkit["runtime"]["incrementalPeakPhysicalFootprintBytes"]},
            "consequence": "model not judged: only 1/6 triggered references complete; retest after reference repair",
        },
    ]
    return {
        "schemaVersion": 1,
        "ticket": 96,
        "decision": "NO-GO-BASELINE-WINNER-HOLDOUT-NO-RUN",
        "corpusRole": "development",
        "automaticSelection": {
            "rule": "a distinct candidate must be admissible, fully referenced, improve Japanese, preserve final English and add no critical loss",
            "candidates": candidates,
            "winner": {"id": winner["id"], "name": winner["name"], "kind": winner["kind"],
                       "modelID": model["modelID"], "revision": model["revision"],
                       "weightSHA256": model["weightSHA256"]},
            "winnerFrozenBeforeHoldout": True,
            "winnerIsBaseline": True,
            "winnerIsDistinct": False,
        },
        "holdout": {
            "status": "NO_RUN",
            "opened": False,
            "modelRunsLaunched": 0,
            "candidate": None,
            "reason": "rerunning the baseline cannot identify or confirm a gain",
            "reopenCondition": "a genuinely distinct candidate passes every DEV gate",
        },
        "tracks": tracks,
        "preflight": {
            "order": ["harness", "build", "input", "reference", "candidate"],
            "currentBuildPassed": True,
            "inputReportsHashVerified": True,
            "referenceDiagnosis": "#95 initial preflight missed coverage; corrected preflight stops before WhisperKit",
            "referenceCoverageCompleteWindows": 1,
            "referenceCoverageWindows": 6,
            "whisperKitModelConclusion": None,
            "candidateRunAuthorized": False,
            "sourceTimingDisagreementSeconds": 60.0,
        },
        "product": {
            "betaOptionAdded": False,
            "uiChanged": False,
            "sourcesByteIdentical": True,
            "sourcesTreeSHA256": EXPECTED_SOURCES_TREE_SHA256,
            "packageSHA256": EXPECTED_PACKAGE_SHA256,
            "defaultASR": "qwen-ja",
            "liveChanged": False,
            "requestJobManifestDeliverablesChanged": False,
            "appLaunch": "passed-existing-single-instance-lock",
        },
        "retest": {
            "ticket": 95,
            "allowed": True,
            "condition": "complete temporal references for every suspect triggered window, then rerun corrected preflight before any model",
            "currentClassification": whisperkit["classification"],
        },
        "controls": controls,
        "provenance": {
            "baseCommit": BASE_COMMIT,
            "sourceReportsSHA256": report_hashes,
            "rawArtifactsSHA256": raw_hashes,
            "reporterSHA256": sha256(Path(__file__)),
        },
    }


def markdown(report: dict) -> str:
    tracks = {row["id"]: row for row in report["tracks"]}
    baseline = tracks["qwen-standard"]
    adaptive = tracks["qwen-parakeet"]
    whisperkit = tracks["targeted-whisperkit"]
    return "\n".join([
        "# E30 — Décision Lane A (#96)", "",
        "**NO-GO option bêta ; HOLDOUT NO-RUN.** Qwen JA standard gagne DEV parce qu’aucun "
        "candidat distinct ne passe toutes les portes. Rejouer Qwen sur le holdout ne peut prouver aucun gain.", "",
        "## Sélection figée", "",
        "Règle automatique : admissibilité + référence complète + gain japonais + anglais final non régressif + "
        "aucune perte critique. Qwen standard est figé avant toute ouverture ; le holdout reste intact.", "",
        f"- Qwen : {baseline['speech']['recoveredCharacters']} caractères récupérés, "
        f"{baseline['speech']['lostOrSubstitutedCharacters']} perdus/substitués, "
        f"termes {baseline['terms']['recovered']}/{baseline['terms']['lost']}, "
        f"nombres {baseline['numbers']['recovered']}/{baseline['numbers']['lost']}, "
        f"sens {baseline['meaning']['recovered']}/{baseline['meaning']['lost']} récupérés/perdus.",
        f"- #94 : edits JA 3273→3229 (+44), dimensions termes/nombres/sens 7/11/6 inchangées, "
        f"mais chrF++ EN {adaptive['english']['baselineChrFPlusPlus']:.3f}→"
        f"{adaptive['english']['candidateChrFPlusPlus']:.3f} ({adaptive['english']['delta']:+.3f}) : veto.",
        f"- #95 : edits provisoires 3229→{whisperkit['speech']['provisionalCandidateEdits']}, "
        "mais 1/6 références seulement est complète ; anglais non exécuté et conclusion modèle absente.", "",
        "## Coûts et conséquences", "",
        "| Piste | Temps / pic | Qualité concrète | Conséquence |", "|---|---|---|---|",
        "| Qwen standard | ASR 68,1 s ; preuve 1064/1124 s selon source ; 17,08 Gio | baseline DEV figée | winner Lane A, aucun gain à tester contre lui-même |",
        "| Fun-ASR | worker 11,63 s ; 2,92 Gio | « 最低だな » ×77 au smoke | arrêt avant DEV/anglais |",
        "| Reazon | worker 23,25 s ; 1,29 Gio | 135 caractères, CER 97,19 %, 0 récupéré/3391 perdus | NO-GO qualité après diagnostic ULP |",
        "| Qwen Anime | 0 s ; aucun processus | licence non admissible | aucun poids/smoke/DEV |",
        "| FireRed | 0 s ; aucun processus | pertes frontière non concentrées | no-run |",
        "| Hotwords | 0 s ; aucun processus | aucune capacité distincte du prompt | no-run |",
        "| Qwen + Spleeter | prétraitement 9,58 s ; job 133,78 s ; 9,61 Gio | parole −31, vides/duplication ajoutés, alignement rouge | aucun anglais |",
        "| Qwen + Parakeet | commandes 650,16 s ; workers 600,00 s ; 11,04 Gio | JA +44, EN chrF++ −0,561 | holdout fermé |",
        "| WhisperKit ciblé | 27,96 s ciblées ; worker 88,45 s ; 3,29 Gio | +10 edits provisoires vs #94, référence incomplète | inconclusif, retestable |", "",
        "## Harness, holdout et produit", "",
        "- L’ordre fail-closed est harness → build → input → référence → candidat. Les hashes E23–E29, "
        "les artefacts bruts et le build courant sont vérifiés avant la décision.",
        "- L’écart historique de coût Qwen est conservé : E23 JSON indique 1064 s, E24 figé 1124 s ; "
        "aucune valeur n’est silencieusement remplacée.",
        "- #95 reste retestable lorsque les six fenêtres suspectes auront des références temporelles complètes ; "
        "le preflight corrigé doit alors passer avant tout modèle.",
        "- Aucun benchmark #96, aucun holdout, aucune option bêta/fantôme. `Sources/`, UI, requête, job, "
        "manifest, Deliverables, défaut Qwen et Live sont byte-identiques au commit de base.", "",
        "- `swift run &` : build réussi puis sortie 0 attendue sur le verrou mono-instance ; "
        "l’instance WhisperASR existante est restée active.", "",
        "Reproduction : `python3 Scripts/report_lane_a_decision.py --self-test && "
        "python3 Scripts/report_lane_a_decision.py`.", "",
    ])


def self_test() -> None:
    baseline = {"id": "qwen-standard", "distinct": False, "admissible": True,
                "completeReference": True, "japanesePass": True,
                "englishPass": True, "noCriticalLoss": True,
                "stable": True, "costPass": True}
    rejected = {"id": "adaptive", "distinct": True, "admissible": True,
                "completeReference": True, "japanesePass": True,
                "englishPass": False, "noCriticalLoss": True,
                "stable": True, "costPass": True}
    assert choose_winner([baseline, rejected])["id"] == "qwen-standard"
    promoted = {**rejected, "englishPass": True}
    assert choose_winner([baseline, promoted])["id"] == "adaptive"
    assert choose_winner([baseline, {**promoted, "stable": False}])["id"] == "qwen-standard"
    assert choose_winner([baseline, {**promoted, "noCriticalLoss": False}])["id"] == "qwen-standard"
    try:
        choose_winner([baseline, promoted, {**promoted, "id": "other"}])
    except RuntimeError:
        pass
    else:
        raise AssertionError("ambiguous DEV evidence must fail closed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    controls_path = ROOT / "docs/japanese-live/experiments/evidence/E30/controls.json"
    report_path = ROOT / "docs/japanese-live/experiments/evidence/E30/report.json"
    provenance_path = ROOT / "docs/japanese-live/experiments/evidence/E30/provenance.json"
    hashes_path = ROOT / "docs/japanese-live/experiments/evidence/E30/sha256.tsv"
    markdown_path = ROOT / "docs/japanese-live/experiments/E30-lane-a-decision.md"

    report_paths = {name: ROOT / path for name, (path, _) in REPORTS.items()}
    report_hashes = {name: sha256(path) for name, path in report_paths.items()}
    require(report_hashes == {name: expected for name, (_, expected) in REPORTS.items()},
            f"frozen Lane A reports changed: {report_hashes}")
    raw_paths = {name: ROOT / path for name, (path, _) in RAW_ARTIFACTS.items()}
    raw_hashes = {name: sha256(path) for name, path in raw_paths.items()}
    require(raw_hashes == {name: expected for name, (_, expected) in RAW_ARTIFACTS.items()},
            f"frozen raw artifacts changed: {raw_hashes}")
    require(source_tree_sha256(ROOT / "Sources") == EXPECTED_SOURCES_TREE_SHA256,
            "Sources changed since the #95 base")
    require({name: sha256(ROOT / name) for name in EXPECTED_PACKAGE_SHA256}
            == EXPECTED_PACKAGE_SHA256, "package files changed since the #95 base")
    reports = {name: json.loads(path.read_text(encoding="utf-8"))
               for name, path in report_paths.items()}
    controls = json.loads(controls_path.read_text(encoding="utf-8"))
    validate_inputs(reports, controls)
    report = build_report(reports, report_hashes, raw_hashes, controls)
    provenance = report["provenance"] | {
        "controlsSHA256": sha256(controls_path),
        "controlArtifactsSHA256": {
            "buildLog": controls["build"]["rawLogSHA256"],
            "initialTestFailureLog": controls["initialTestFailure"]["rawLogSHA256"],
            "testsLog": controls["tests"]["rawLogSHA256"],
            "appLaunchLog": controls["appLaunch"]["rawLogSHA256"],
            "metallib": controls["metallib"]["sha256"],
        },
        "productSourcesTreeSHA256": EXPECTED_SOURCES_TREE_SHA256,
        "packageSHA256": EXPECTED_PACKAGE_SHA256,
    }
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    provenance_path.write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    markdown_path.write_text(markdown(report), encoding="utf-8")
    artifacts = report_paths | raw_paths | {
        "buildLog": ROOT / controls["build"]["rawLog"],
        "initialTestFailureLog": ROOT / controls["initialTestFailure"]["rawLog"],
        "testsLog": ROOT / controls["tests"]["rawLog"],
        "appLaunchLog": ROOT / controls["appLaunch"]["rawLog"],
        "controls": controls_path, "report": report_path,
        "provenance": provenance_path, "markdown": markdown_path,
    }
    hashes_path.write_text("".join(
        f"{sha256(path)}  {path.relative_to(ROOT)}\n" for path in artifacts.values()
    ), encoding="utf-8")


if __name__ == "__main__":
    main()
