#!/usr/bin/env python3
"""Freeze the #92 no-run when Qwen exposes prompt context, not native hotwords."""

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_SHA256 = {
    "e25": "8fa4460e1d9b599e6d1dffa40af024e80223380e118f6164359cbbfd2f0f1330",
    "history": "5b4e9c0a83a56ce2eff63313b3d22f186b38dac119e8f49e6fd0f1135bae7645",
    "localRuntime": "45855a1a1a5d7bd1cb35272192bccd9826d70547399c1dd217ffb1b6deb57dbd",
    "localRuntimeTree": "df435c57d45f24bd71042618bfc70acbd2a008c5a86cc66c4ed3cf707c576d43",
    "productionWrapper": "06c8eb7819ec542f94c72e729243e7ba03c8f2fcdcee4b9ee8e9f9186c2c8567",
    "officialExcerpt": "b12b68288d9808d9fdac78325dc4e2f43a727f60c0b7ce1487317cfb95cf331e",
    "officialScan": "49131ba06ee160da680d9c4059fb4709ba292f624ef798ad0983fa3b4e27b57f",
    "testStability": "1454b47d67df120ace3744e6f34473ae4e717d89a63e2a4abd6c30de5bfd7a8b",
    "sources": "c433e06ad423de13fa5543a0cc5a2616b7212ead5dd447e80ff9d95c4cc9c6f7",
    "controls": "10fe5ad57e488834215648fd1fa492c8ed5acee19ecf709a7647be5ce7fa1f63",
}
SCAN_TERMS = ("hotword", "contextualbias", "logitbias", "logitsbias")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def scan_sources(paths: list[Path]) -> list[dict]:
    matches = []
    for path in paths:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            normalized = normalized_identifier(line)
            for term in SCAN_TERMS:
                if term in normalized:
                    matches.append({"path": str(path.relative_to(ROOT)),
                                    "line": line_number, "term": term})
    return matches


def normalized_identifier(line: str) -> str:
    return "".join(character for character in line.lower() if character.isalnum())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def build_report(e25: dict, sources: dict, controls: dict, hashes: dict) -> dict:
    selected = e25["selection"]["selected"]
    conclusion = sources["conclusion"]
    require(e25.get("ticket") == 91 and selected.get("backend") == "qwen-ja",
            "E25 does not freeze Qwen JA as the winning single ASR")
    require(selected.get("modelID") == sources["winner"]["modelID"],
            "capability evidence targets a different model")
    require(sources["officialRuntime"]["distinctFromPrompt"] is False,
            "official Qwen now exposes a distinct mechanism; run the DEV experiment")
    require(sources["localRuntime"]["distinctFromPrompt"] is False,
            "local Qwen now exposes a distinct mechanism; run the DEV experiment")
    require(not sources["officialRuntime"]["apiScan"]["matches"]
            and not sources["localRuntime"]["negativeSearch"]["matches"],
            "a dedicated hotword mechanism was found; run the DEV experiment")
    require(conclusion == {
        "nativeHotwordMechanismExposed": False,
        "reason": "the only contextual input is ordinary system-prompt conditioning in both official and local runtimes",
        "experimentApplicable": False,
    }, "unexpected capability conclusion")
    require(controls.get("ticket") == 92 and controls.get("modelRunsLaunched") == 0,
            "invalid #92 no-run controls")
    require(controls.get("holdoutOpened") is False,
            "holdout must remain closed")
    require(controls.get("tests", {}).get("failed") == 0,
            "control tests failed")
    require(controls.get("metallib", {}).get("passed") is True,
            "metallib control failed")

    baseline = e25["frozenBaselineEvidence"]
    return {
        "schemaVersion": 1,
        "ticket": 92,
        "decision": "INAPPLICABLE-NO-RUN-no-native-hotword-mechanism",
        "corpusRole": "development",
        "winningRecipe": {
            "recipe": selected["recipe"],
            "backend": selected["backend"],
            "modelID": selected["modelID"],
            "revision": selected["revision"],
            "weightSHA256": selected["weightSHA256"],
        },
        "capabilityGate": {
            "rule": "run only if the winning backend exposes contextual biasing distinct from prompt conditioning",
            "officialContextPlacement": sources["officialRuntime"]["contextPlacement"],
            "localContextPlacement": sources["localRuntime"]["contextPlacement"],
            "dedicatedHotwordParameter": False,
            "decoderLogitBias": False,
            "distinctFromPreviouslyTestedPrompt": False,
            "eligible": False,
            "reason": conclusion["reason"],
        },
        "experiment": {
            "scoringStarted": False,
            "catalog": None,
            "encodedBudget": None,
            "cueLocalSelection": None,
            "matchingRules": None,
            "offOutput": None,
            "onOutput": None,
            "falsePositives": None,
            "concreteCandidateExamples": [],
            "materialMeasurements": {
                "criticalTermsRecovered": None,
                "falseSubstitutions": None,
                "speechLost": None,
                "numbersLost": None,
                "meaningLost": None,
                "englishEffects": None,
            },
            "reason": "the prerequisite failed before catalog construction or scoring",
        },
        "frozenBaselineEvidence": {
            "speechRecoveredCharacters": baseline["speechRecoveredCharacters"],
            "speechLostCharacters": baseline["speechLostCharacters"],
            "termsRecovered": baseline["termsRecovered"],
            "termsLost": baseline["termsLost"],
            "numbersRecovered": baseline["numbersRecovered"],
            "numbersLost": baseline["numbersLost"],
            "meaningRecovered": baseline["meaningRecovered"],
            "meaningLost": baseline["meaningLost"],
            "examples": baseline["examples"],
        },
        "execution": {
            "modelRunsLaunched": 0,
            "candidateRuntimeSeconds": 0.0,
            "candidatePeakMemoryBytes": None,
            "heavyBenchmarkAuthorized": False,
            "holdoutOpened": False,
        },
        "controls": {
            "sourceSHA256": hashes,
            "verification": controls,
            "classification": "capability-inapplicable-not-execution-failure",
        },
        "rawArtifacts": {
            "officialRuntimeExcerpt": sources["officialRuntime"]["rawExcerpt"],
            "officialAPIScan": sources["officialRuntime"]["apiScan"]["artifact"],
            "capabilityManifest": "capability-sources.json",
            "testStability": controls["tests"]["stabilityEvidence"],
            "candidateOutput": None,
        },
        "productChanges": "none",
        "uiChanges": "none",
        "standardDefaultsChanged": False,
        "liveChanges": "none",
        "postCorrectionAdded": False,
        "provenance": {"reporterSHA256": sha256(Path(__file__))},
    }


def markdown(report: dict, sources: dict) -> str:
    baseline = report["frozenBaselineEvidence"]
    official = sources["officialRuntime"]
    local = sources["localRuntime"]
    history = sources["localPromptHistory"]
    return "\n".join([
        "# E26 — Hotwords Qwen inapplicables (#92)", "",
        "**INAPPLICABLE / NO-RUN.** Qwen E22 reste le meilleur single-ASR DEV, mais son "
        "backend n’expose aucun hotword natif distinct d’un prompt. Le holdout reste fermé.", "",
        "## Preuve de capacité", "",
        f"- Runtime officiel Qwen épinglé à `{official['revision']}` : le scan des 830 lignes de "
        "l’API publique ne trouve aucun mécanisme dédié ; `context` devient le "
        f"contenu du message `system`, puis passe dans le chat template ([source]({official['url']}), "
        f"blob `{official['blobSHA']}`).",
        f"- Port Swift local `{local['path']}` (`{local['sha256']}`) : le contexte est tokenisé "
        "entre `<|im_start|>system` et `<|im_end|>` sur les chemins unitaire et batch.",
        f"- Historique local `{history['commit']}` : les essais courts avaient déjà produit un "
        "prompt echo ; Qwen est depuis volontairement exécuté sans prompt.",
        "- Le signal communautaire #106 reproduit ce même echo avec `context=hot_word`. "
        "La demande #157 d’un paramètre hotwords dédié a été fermée sans ajout d’API.", "",
        "Il n’existe donc ni paramètre hotword dédié, ni score par terme, ni biais de logits "
        "séparé. Relancer `context` répéterait l’expérience prompt déjà rejetée.", "",
        "## Conséquence expérimentale", "",
        "- Aucun catalogue, budget encodé, sélection cue-locale ou règle de matching n’est "
        "fabriqué après l’échec de la porte de capacité.",
        "- Aucun off/on, faux positif ou effet anglais candidat n’est mesuré ; ces champs restent "
        "absents, pas remplacés par des zéros.",
        f"- La baseline figée reste : termes {baseline['termsRecovered']}/{baseline['termsLost']} "
        f"récupérés/perdus, nombres {baseline['numbersRecovered']}/{baseline['numbersLost']}, "
        f"sens {baseline['meaningRecovered']}/{baseline['meaningLost']}.",
        "- Aucune post-correction, UI, valeur Standard ou modification Live.", "",
        "## Exécution et contrôles", "",
        "- 0 modèle lancé ; temps candidat 0,00 s ; mémoire candidate non applicable ; holdout fermé.",
        f"- Xcode {report['controls']['verification']['xcode']['version']}, metallib "
        f"`{report['controls']['verification']['metallib']['sha256']}`, "
        f"{report['controls']['verification']['tests']['executed']} tests exécutés, 0 échec.",
        f"- Incidents runner consignés : "
        f"{len(report['controls']['verification']['failures']['runner'])} ; "
        "erreurs build : 0 ; erreurs modèle : 0. Une observation test non reproduite est "
        "conservée ; quatre relances consécutives sont vertes.",
        "- Verdict classé `capability-inapplicable`, pas comme un échec d’exécution.", "",
        "Reproduction : `python3 Scripts/report_qwen_hotwords_no_run.py`.", "",
    ])


def self_test() -> None:
    assert any(term in normalized_identifier("let logitsBias = value")
               for term in SCAN_TERMS)
    e25 = {"ticket": 91, "selection": {"selected": {
        "recipe": "qwen", "backend": "qwen-ja", "modelID": "m", "revision": "r",
        "weightSHA256": {}}}, "frozenBaselineEvidence": {
        "speechRecoveredCharacters": 1, "speechLostCharacters": 2,
        "termsRecovered": 1, "termsLost": 2, "numbersRecovered": 1,
        "numbersLost": 2, "meaningRecovered": 1, "meaningLost": 2, "examples": []}}
    sources = {"winner": {"modelID": "m"},
        "officialRuntime": {"distinctFromPrompt": False, "contextPlacement": "system",
            "rawExcerpt": "raw", "apiScan": {"matches": [], "artifact": "scan"}},
        "localRuntime": {"distinctFromPrompt": False, "contextPlacement": "system",
            "negativeSearch": {"matches": []}},
        "conclusion": {"nativeHotwordMechanismExposed": False,
            "reason": "the only contextual input is ordinary system-prompt conditioning in both official and local runtimes",
            "experimentApplicable": False}}
    controls = {"ticket": 92, "modelRunsLaunched": 0, "holdoutOpened": False,
                "tests": {"failed": 0, "stabilityEvidence": "stability"},
                "metallib": {"passed": True},
                "failures": {"runner": [], "build": [], "model": []}}
    report = build_report(e25, sources, controls, {})
    assert report["decision"].startswith("INAPPLICABLE-NO-RUN")
    assert report["experiment"]["onOutput"] is None
    sources["officialRuntime"]["distinctFromPrompt"] = True
    try:
        build_report(e25, sources, controls, {})
    except RuntimeError:
        pass
    else:
        raise AssertionError("a native mechanism must not produce the no-run report")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--e25", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E25/report.json")
    parser.add_argument("--history", type=Path, default=ROOT / "docs/japanese-live/research-live-ja-en-2026.md")
    parser.add_argument("--local-runtime", type=Path, default=ROOT / "Vendor/SpeechSwiftPrototype/Sources/Qwen3ASR/Qwen3ASR.swift")
    parser.add_argument("--local-module", type=Path, default=ROOT / "Vendor/SpeechSwiftPrototype/Sources/Qwen3ASR")
    parser.add_argument("--production-wrapper", type=Path, default=ROOT / "Sources/LocalEnglishModels.swift")
    parser.add_argument("--sources", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E26/capability-sources.json")
    parser.add_argument("--official-excerpt", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E26/primary-sources/qwen3_asr-context.py")
    parser.add_argument("--official-scan", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E26/official-api-scan.json")
    parser.add_argument("--controls", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E26/controls.json")
    parser.add_argument("--test-stability", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E26/test-stability.json")
    parser.add_argument("--report", type=Path, default=ROOT / "docs/japanese-live/experiments/evidence/E26/report.json")
    parser.add_argument("--markdown", type=Path, default=ROOT / "docs/japanese-live/experiments/E26-qwen-hotwords-no-run.md")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return

    paths = {"e25": args.e25, "history": args.history,
             "localRuntime": args.local_runtime, "productionWrapper": args.production_wrapper,
             "officialExcerpt": args.official_excerpt, "officialScan": args.official_scan,
             "testStability": args.test_stability, "sources": args.sources,
             "controls": args.controls}
    hashes = {name: sha256(path) for name, path in paths.items()}
    hashes["localRuntimeTree"] = source_tree_sha256(args.local_module)
    require(hashes == EXPECTED_SHA256, f"frozen capability evidence changed: {hashes}")
    official = args.official_excerpt.read_text(encoding="utf-8")
    local = args.local_runtime.read_text(encoding="utf-8")
    history = args.history.read_text(encoding="utf-8")
    official_scan = json.loads(args.official_scan.read_text(encoding="utf-8"))
    test_stability = json.loads(args.test_stability.read_text(encoding="utf-8"))
    require('{"role": "system", "content": context or ""}' in official
            and "apply_chat_template" in official and "hotword" not in official.lower(),
            "official context is no longer plain prompt conditioning")
    require("<|im_start|>system\\n{context}<|im_end|>" in local
            and "tokenizer.encode(context)" in local,
            "local context is no longer plain prompt conditioning")
    local_paths = sorted(item for item in args.local_module.rglob("*") if item.is_file())
    require(not scan_sources(local_paths + [args.production_wrapper]),
            "local Qwen module or production wrapper now exposes a hotword mechanism")
    require("répétition du prompt système" in history and "prompt echo" in history,
            "local prompt-echo history is missing")
    e25 = json.loads(args.e25.read_text(encoding="utf-8"))
    sources = json.loads(args.sources.read_text(encoding="utf-8"))
    controls = json.loads(args.controls.read_text(encoding="utf-8"))
    require(official_scan["source"] == {
                "repository": sources["officialRuntime"]["repository"],
                "revision": sources["officialRuntime"]["revision"],
                "path": sources["officialRuntime"]["path"],
                "blobSHA": sources["officialRuntime"]["blobSHA"],
                "lineCount": 830,
            } and official_scan["scan"]["terms"] == sources["officialRuntime"]["apiScan"]["terms"]
            and official_scan["scan"]["matches"] == sources["officialRuntime"]["apiScan"]["matches"],
            "official pinned API scan changed")
    require(hashes["localRuntimeTree"] == sources["localRuntime"]["moduleTreeSHA256"]
            and hashes["productionWrapper"] == sources["localRuntime"]["productionWrapper"]["sha256"],
            "local Qwen scan scope changed")
    require(len(test_stability["reproductionAttempts"])
            == controls["tests"]["consecutivePassingReruns"]
            and all(attempt["failed"] == 0 for attempt in test_stability["reproductionAttempts"]),
            "test stability evidence is incomplete")
    report = build_report(e25, sources, controls, hashes)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.markdown.write_text(markdown(report, sources), encoding="utf-8")


if __name__ == "__main__":
    main()
