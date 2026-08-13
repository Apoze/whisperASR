#!/usr/bin/env python3
"""Report ticket #106 from real HighQualityJob runs."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import tempfile
from collections import Counter
from datetime import datetime
from pathlib import Path

from report_high_quality_acceptance import cer, diarization_metrics, sha256
from report_japanese_l7d import chrf_pp
from report_local_translator_bakeoff import (
    CANDIDATES,
    INTEGRITY_REASON_CODES,
    comet_scores,
    cue_integrity,
    glossary_accuracy,
    representative_examples,
    subtitle_quality,
    translation_rows,
    write_lines,
)

CORPORA = ("qudu2fx3ncc", "md62mmdz0m")
EXPORTS = ("japanese-transcript.txt", "english-translation-transcript.txt",
           "english-subtitles.srt", "english-subtitles.vtt")
ROLES = {CORPORA[0]: "development", CORPORA[1]: "holdout"}
BASELINE = Path("docs/japanese-live/experiments/evidence/E22")
PRESSURE_ATTEMPT = Path(
    "docs/japanese-live/experiments/evidence/E31-12b-pressure-attempt/report.json"
)


def verify_sha256_manifest(path: Path) -> None:
    rows = [line.split("  ", 1) for line in path.read_text(encoding="utf-8").splitlines()]
    assert rows and all(len(row) == 2 for row in rows)
    assert all(sha256(Path(target) if Path(target).is_absolute() else path.parent / target)
               == expected for expected, target in rows)


def current_12b_jobs_complete(rows: list[dict]) -> bool:
    return len(rows) == len(CORPORA) and all(
        row["productStatus"] == "completed" and row["resultRoute"] == "completed"
        and set(row["exportsSHA256"]) == set(EXPORTS) for row in rows
    )


def integrated_campaign_complete(jobs_complete: bool, gates: dict[str, bool]) -> bool:
    return jobs_complete and all(gates.values())


def reused_4b_replay(root: Path) -> tuple[dict | None, list[dict]]:
    reuse_path = root / "4b-replay-reuse.json"
    if not reuse_path.exists():
        return None, []
    reuse = read(reuse_path)
    report_path = Path(reuse["report"]["path"])
    manifest_path = Path(reuse["evidence"]["path"]) / "sha256.tsv"
    assert reuse["audited"] is True and reuse["modelWeightsAccessed"] is False
    assert sha256(report_path) == reuse["report"]["sha256"]
    assert sha256(manifest_path) == reuse["evidence"]["manifestSHA256"]
    verify_sha256_manifest(manifest_path)
    report = read(report_path)
    assert report["workflowAuditable"] is True
    assert report["runMode"] == "TRANSLATION_ONLY_4B"
    return reuse, report["rows"]


def read(path: Path) -> dict:
    if path.suffix == ".gz":
        with gzip.open(path, "rt", encoding="utf-8") as stream:
            return json.load(stream)
    return json.loads(path.read_text(encoding="utf-8"))


def decoded_map(value: dict | list) -> dict[str, float]:
    if isinstance(value, dict):
        return {str(key): float(item) for key, item in value.items()}
    assert len(value) % 2 == 0
    return {str(value[index]): float(value[index + 1])
            for index in range(0, len(value), 2)}


def job_directory(root: Path, candidate: str, corpus: str) -> Path:
    manifests = list((root / candidate / corpus / "jobs").glob("*/manifest.json"))
    assert len(manifests) == 1, (candidate, corpus, manifests)
    return manifests[0].parent


def verified_video1_resume(root: Path, corpus: str, job: Path, run_meta: Path) -> dict | None:
    path = root / "resume-video1-reuse.json"
    if corpus != CORPORA[0] or not path.exists():
        return None
    reuse = read(path)
    retained_root = Path(reuse["retainedEvidence"]["path"])
    retained = retained_root / "video1"
    manifest = retained_root / "sha256.tsv"
    assert reuse["reusedCompletedVideo1"] is True
    assert reuse["modelExecutionAndOutputsUnchanged"] is True
    assert sha256(manifest) == reuse["retainedEvidence"]["manifestSHA256"]
    verify_sha256_manifest(manifest)
    source = reuse["sourceSHA256"]
    current = root / CANDIDATES[0] / corpus
    assert sha256(run_meta) == source["runMetadata"] == sha256(retained / "run-meta.json")
    assert sha256(current / "safety.json") == source["safety"] \
        == sha256(retained / "safety.json")
    assert sha256(current / "cleanup.json") == source["cleanup"] \
        == sha256(retained / "cleanup.json")
    assert sha256(job / "manifest.json") == source["manifest"] \
        == sha256(retained / "manifest.json")
    with gzip.open(retained / "raw-asr.json.gz", "rb") as stream:
        retained_raw = hashlib.sha256(stream.read()).hexdigest()
    assert sha256(job / "raw-asr.json") == source["rawEvidence"] == retained_raw
    assert all(sha256(job / name) == digest == sha256(retained / name)
               for name, digest in source["exports"].items())
    historical_runtime = read(retained / "run-meta.json")["runtimeSHA256"]
    assert historical_runtime == read(retained.parent / "benchmark-ready.json")["runtimeSHA256"]
    return {**reuse, "runtimeProvenanceVerified": True}


def wall_duration(manifest: dict) -> float:
    start = datetime.fromisoformat(manifest["startedAt"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(manifest["finishedAt"].replace("Z", "+00:00"))
    return (end - start).total_seconds()


def stage_summary(raw: dict) -> dict[str, float]:
    stages = decoded_map(raw.get("stageDurations") or {})
    return {
        "sourcePreparation": stages.get("normalizing-source", 0),
        "ASR": stages.get("preparing-asr", 0) + stages.get("transcribing", 0),
        "alignment": stages.get("preparing-alignment", 0) + stages.get("aligning", 0),
        "SpeakerKit": stages.get("preparing-diarization", 0) + stages.get("diarizing", 0),
        "translation": stages.get("translating", 0),
        "export": stages.get("exporting", 0),
    }


def lifecycle(raw: dict, safety: dict, translation_only: bool = False) -> dict:
    all_workers = [
        ("ASR", (raw.get("asrWorker") or {}).get("lifecycle")),
        ("alignment", (raw.get("alignment") or {}).get("worker")),
        ("SpeakerKit", (raw.get("diarization") or {}).get("worker")),
        ("translation", (raw.get("translation") or {}).get("worker")),
    ]
    workers = all_workers[-1:] if translation_only else all_workers
    complete = all(worker for _, worker in workers)
    transitions = [item for _, worker in workers if worker
                   for item in worker.get("pressureTransitions", [])]
    samples = [sample for _, worker in workers if worker
               for sample in worker.get("availableMemorySamples", [])]
    pids = [worker["processIdentifier"] for _, worker in workers if worker]
    strict = complete and all(
        datetime.fromisoformat(left[1]["exitedAt"].replace("Z", "+00:00"))
        <= datetime.fromisoformat(right[1]["startedAt"].replace("Z", "+00:00"))
        for left, right in zip(workers, workers[1:])
    )
    clean = complete and all(worker.get("exitStatus") == 0
                             and not worker.get("forcedTermination")
                             for _, worker in workers)
    return {
        "strictlySequential": strict,
        "cleanWorkerExits": clean,
        "distinctWorkerProcesses": len(pids) == len(set(pids)) == len(workers),
        "upstreamReused": translation_only,
        "peakPhysicalFootprintBytes": max(
            [safety.get("peakPhysicalFootprintBytes", 0), raw.get("peakMemoryBytes", 0)]
            + [worker.get("peakPhysicalFootprintBytes", 0)
               for _, worker in workers if worker]
        ),
        "minimumAvailableMemoryBytes": min(
            (sample["availableMemoryBytes"] for sample in samples), default=None
        ),
        "workerSwapDeltaBytes": sum(
            max(0, worker.get("swapUsedAfterBytes", 0) - worker.get("swapUsedBeforeBytes", 0))
            for _, worker in workers if worker
            and worker.get("swapUsedAfterBytes") is not None
            and worker.get("swapUsedBeforeBytes") is not None
        ),
        "externalSwapDeltaBytes": (safety.get("systemAfter") or {}).get("swapDeltaBytes"),
        "nativePressureLevels": safety.get("nativePressureLevels") or [],
        "pressureTransitions": transitions,
        "externalStopReason": safety.get("stopReason"),
        "runawayGuard": safety.get("postLoadRunawayGuard"),
        "fixedOfflineReserveBytes": 0,
        "workers": [{"stage": stage, **worker} for stage, worker in workers if worker],
    }


def integrity(raw: dict) -> dict:
    translation = raw["translation"]
    verdicts = translation.get("integrityVerdicts") or []
    final = Counter(reason["code"] for verdict in verdicts
                    for reason in verdict.get("reasons", []))
    attempts = Counter(code for batch in translation.get("batches", [])
                       for code in batch.get("validationReasonCodes", []))
    summary = cue_integrity(raw)
    return {
        **summary,
        "terminalVerdicts": dict(Counter(verdict.get("verdict", "unknown")
                                          for verdict in verdicts)),
        "finalReasonCounts": {code: final.get(code, 0) for code in INTEGRITY_REASON_CODES},
        "attemptReasonCounts": {code: attempts.get(code, 0) for code in INTEGRITY_REASON_CODES},
        "validationFailures": translation.get("validationFailures") or [],
        "allTerminalVerdictsPass": len(verdicts) == len(translation["request"]["turns"])
            and all(verdict.get("verdict") == "pass" for verdict in verdicts),
    }


def mean_comet(path: Path, hypothesis: Path) -> float | None:
    values = comet_scores(path, hypothesis)
    return sum(values) / len(values) if values else None


def baseline(corpus: str, metric_dir: Path) -> dict:
    manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
    raw = read(BASELINE / f"{corpus}-raw-asr.json.gz")
    rows = translation_rows(manifest, raw)
    hypothesis = metric_dir / "e22-standard.en.txt"
    write_lines(hypothesis, [row["hypothesis"] for row in rows])
    reference = " ".join(row["reference"] for row in rows)
    return {
        "name": "E22 Standard / TranslateGemma 12B",
        "rawArtifactSHA256": sha256(BASELINE / f"{corpus}-raw-asr.json.gz"),
        "japaneseCERPercent": cer(
            "".join(turn["japanese"] for turn in manifest["annotations"]["turns"]),
            raw["rawASR"],
        )["ratePercent"],
        "chrFPlusPlus": chrf_pp(" ".join(row["hypothesis"] for row in rows), reference),
        "COMET": mean_comet(metric_dir / "comet-score.json", hypothesis),
        "speakers": diarization_metrics(manifest, raw),
    }


def prepare_scoring(root: Path, candidates: list[str]) -> None:
    for corpus in CORPORA:
        manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
        metric_dir = root / "metrics" / corpus
        current = {}
        for candidate in candidates:
            raw = read(job_directory(root, candidate, corpus) / "raw-asr.json")
            current[candidate] = translation_rows(manifest, raw)
        reference_rows = current[candidates[0]]
        write_lines(metric_dir / "source.ja.txt", [row["source"] for row in reference_rows])
        write_lines(metric_dir / "reference.en.txt", [row["reference"] for row in reference_rows])
        for candidate, rows in current.items():
            write_lines(metric_dir / f"{candidate}.en.txt", [row["hypothesis"] for row in rows])
        baseline(corpus, metric_dir)


def score_row(root: Path, candidate: str, corpus: str) -> tuple[dict, list[dict]]:
    job = job_directory(root, candidate, corpus)
    manifest, raw = read(job / "manifest.json"), read(job / "raw-asr.json")
    reference = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
    rows = translation_rows(reference, raw)
    metric_dir = root / "metrics" / corpus
    hypothesis = metric_dir / f"{candidate}.en.txt"
    stages = stage_summary(raw)
    runtime = wall_duration(manifest)
    source_duration = raw["sampleCount"] / raw["sampleRate"]
    safety = read(root / candidate / corpus / "safety.json")
    run_meta = read(root / candidate / corpus / "run-meta.json")
    translation_only = run_meta.get("runMode", "").startswith("TRANSLATION_ONLY_")
    resources = lifecycle(raw, safety, translation_only)
    english_reference = " ".join(row["reference"] for row in rows)
    quality = {
        "japaneseCERPercent": cer(
            "".join(turn["japanese"] for turn in reference["annotations"]["turns"]),
            raw["rawASR"],
        )["ratePercent"],
        "chrFPlusPlus": chrf_pp(" ".join(row["hypothesis"] for row in rows), english_reference),
        "COMET": mean_comet(metric_dir / "comet-score.json", hypothesis),
    }
    artifacts_match = run_meta.get("rawArtifactSHA256") == {
        "manifest.json": sha256(job / "manifest.json"),
        "raw-asr.json": sha256(job / "raw-asr.json"),
    }
    references_match = run_meta.get("corpusManifestSHA256") == sha256(
        Path("docs/japanese-live/corpora") / corpus / "manifest.json"
    ) and run_meta.get("corpusPreflightSHA256") == sha256(root / "corpus-preflight.tsv") \
        and all(Path(item["locator"]).is_file()
                and sha256(Path(item["locator"])) == item["sha256"]
                for item in run_meta.get("localReferences", []))
    resume = verified_video1_resume(
        root, corpus, job, root / candidate / corpus / "run-meta.json"
    )
    recovery = run_meta.get("harnessRecovery") or {}
    implementation = (recovery.get("validatorImplementationSHA256", {})
                      if recovery.get("runtimeImplementationUnchanged") is True
                      else run_meta.get("implementationSHA256", {}))
    implementation = {**implementation,
                      **(run_meta.get("reportRecovery") or {}).get("implementationSHA256", {})}
    if resume:
        implementation = resume["resumeImplementationSHA256"]
    implementation_match = bool(implementation) and all(
        Path(path).is_file() and sha256(Path(path)) == digest
        for path, digest in implementation.items()
    )
    runtime_provenance = run_meta.get("runtimeSHA256") or {}
    runtime_match = (resume or {}).get("runtimeProvenanceVerified") is True \
        or runtime_provenance == {
        "workerExecutable": sha256(Path(".build/debug/WhisperASR")),
        "mlxMetallib": sha256(Path(".build/debug/mlx.metallib")),
    }
    exports = {name: sha256(job / name) for name in EXPORTS if (job / name).is_file()}
    return {
        "role": ROLES[corpus],
        "corpusID": corpus,
        "translator": candidate,
        "runMode": run_meta.get("runMode", "integrated"),
        "productStatus": manifest["status"],
        "resultRoute": run_meta.get("resultRoute"),
        "modelID": raw["translation"]["model"],
        "revision": raw["translation"].get("revision"),
        "quality": quality,
        "integrity": integrity(raw),
        "glossary": glossary_accuracy(raw),
        "subtitleQuality": subtitle_quality(
            (job / "english-subtitles.srt").read_text(encoding="utf-8")
            if (job / "english-subtitles.srt").exists() else None
        ),
        "speakers": diarization_metrics(reference, raw),
        "timingSeconds": {**stages, "total": runtime, "source": source_duration},
        "realTimeFactor": runtime / source_duration,
        "resources": resources,
        "exportsSHA256": exports,
        "provenance": {
            "rawArtifactsMatchMetadata": artifacts_match,
            "referencesMatchMetadata": references_match,
            "implementationMatchesMetadata": implementation_match,
            "runtimeMatchesMetadata": runtime_match,
            "manifestSHA256": sha256(job / "manifest.json"),
            "rawEvidenceSHA256": sha256(job / "raw-asr.json"),
            "runMetadataSHA256": sha256(root / candidate / corpus / "run-meta.json"),
            "reusedCompletedVideo1": resume is not None,
        },
    }, rows


def fmt(value: float | None, digits: int = 2) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def clock(value: float) -> str:
    minutes, seconds = divmod(value, 60)
    return f"{int(minutes)}m {seconds:.1f}s"


def build_report(root: Path, candidates: list[str]) -> tuple[dict, str]:
    four_b_only = candidates == [CANDIDATES[1]]
    rows, examples, baselines = [], {}, {}
    for corpus in CORPORA:
        candidate_rows = {}
        for candidate in candidates:
            row, translations = score_row(root, candidate, corpus)
            rows.append(row)
            candidate_rows[candidate] = translations
        if CANDIDATES[0] not in candidate_rows:
            candidate_rows[CANDIDATES[0]] = translation_rows(
                read(Path("docs/japanese-live/corpora") / corpus / "manifest.json"),
                read(BASELINE / f"{corpus}-raw-asr.json.gz"),
            )
        if CANDIDATES[1] not in candidate_rows:
            replay = (Path("docs/japanese-live/experiments/evidence/E31-translation-only-4b")
                      / f"{CANDIDATES[1]}-{corpus}" / "raw-asr.json.gz")
            if replay.exists():
                candidate_rows[CANDIDATES[1]] = translation_rows(
                    read(Path("docs/japanese-live/corpora") / corpus / "manifest.json"),
                    read(replay),
                )
        examples[corpus] = representative_examples(candidate_rows)
        baselines[corpus] = baseline(corpus, root / "metrics" / corpus)

    translation_only = bool(rows) and all(
        row["runMode"].startswith("TRANSLATION_ONLY_") for row in rows
    )
    resume_full_12b = len(rows) == len(CORPORA) and {
        (row["corpusID"], row["runMode"]) for row in rows
    } == {(CORPORA[0], "FULL_12B_ONLY"), (CORPORA[1], "RESUME_FULL_12B_VIDEO2")}
    full_12b_only = bool(rows) and (
        all(row["runMode"] == "FULL_12B_ONLY" for row in rows) or resume_full_12b
    )
    reuse, reused_rows = reused_4b_replay(root) if full_12b_only else (None, [])
    report_rows = rows + reused_rows
    current_12b_complete = full_12b_only and current_12b_jobs_complete(rows)

    handoff_path = root / "12b-to-4b-handoff.json"
    handoff = read(handoff_path) if handoff_path.exists() else None
    test_status = read(root / "test-status.json")
    routes_are_model_results = all(
        (row["productStatus"] == "completed" and row["resultRoute"] == "completed")
        or (row["productStatus"] == "failed"
            and row["resultRoute"] == "model-quality-rejection")
        for row in report_rows
    )
    gates = {
        "realJobsAuditable": len(rows) == len(candidates) * len(CORPORA)
            and (not full_12b_only or len(reused_rows) == len(CORPORA)),
        "configurationIsStandard": all(
            row["modelID"].endswith(row["translator"])
            and row["resources"]["fixedOfflineReserveBytes"] == 0 for row in report_rows
        ),
        "strictLifecycle": all(
            row["resources"]["strictlySequential"]
            and row["resources"]["cleanWorkerExits"]
            and row["resources"]["distinctWorkerProcesses"]
            and row["resources"]["externalStopReason"] == "completed"
            for row in report_rows
        ),
        "12BExecutionPolicySatisfied": translation_only or full_12b_only or (
            handoff is None and CANDIDATES[0] not in candidates
        ) or (
            handoff is not None and handoff.get("nativePressureLevel") == "normal"
            and all(not worker["resident"] for worker in handoff["translateGemma12BWorkers"])
        ),
        "rawArtifactHashes": all(row["provenance"]["rawArtifactsMatchMetadata"] for row in report_rows),
        "referenceAndImplementationHashes": all(
            row["provenance"]["referencesMatchMetadata"]
            and row["provenance"]["implementationMatchesMetadata"]
            and row["provenance"]["runtimeMatchesMetadata"] for row in report_rows
        ),
        "resultRoutesExcludeHarnessFailures": routes_are_model_results,
        "liveUnchanged": test_status.get("livePassed") is True
            and test_status.get("sha256", {}).get("live-tests.log")
            == sha256(root / "live-tests.log"),
        "fullSwiftTestsPassed": test_status.get("fullSwiftPassed") is True
            and test_status.get("sha256", {}).get("full-swift-test.log")
            == sha256(root / "full-swift-test.log"),
    }
    if full_12b_only:
        gates["audited4BReplayReused"] = reuse is not None
        gates["current12BJobsCompletedWithExports"] = current_12b_complete
    campaign_complete = integrated_campaign_complete(current_12b_complete, gates)
    pressure_attempt = read(PRESSURE_ATTEMPT) if four_b_only or translation_only else None
    if pressure_attempt:
        assert pressure_attempt["classification"] == "INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE"
    report = {
        "schemaVersion": 1,
        "ticket": 106,
        "runMode": ("RESUME_FULL_12B_VIDEO2" if resume_full_12b else rows[0]["runMode"])
            if translation_only or full_12b_only
            else ("4B_ONLY" if four_b_only else "full"),
        "ticket106Concluded": campaign_complete
            if full_12b_only else not (four_b_only or translation_only),
        "campaignClassification": (
            "COMPLETE" if campaign_complete else
            "INCONCLUSIVE_INTEGRATED_12B_INCOMPLETE" if full_12b_only else
            "VALIDATED_PARTIAL_TRANSLATION_REPLAY"
            if translation_only and candidates == [CANDIDATES[0]] else
            "INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE"
            if four_b_only or translation_only else "COMPLETE"
        ),
        "finalIntegrated12BReadiness": (
            {"decision": "NO_READY", "ready": False,
             "blocker": "The existing full command also reruns 4B, outside the granted 12B-only scope."}
            if translation_only and candidates == [CANDIDATES[0]] else None
        ),
        "prior12BAttempt": None if not pressure_attempt else {
            "path": str(PRESSURE_ATTEMPT),
            "sha256": sha256(PRESSURE_ATTEMPT),
            "classification": pressure_attempt["classification"],
            "modelQualityVerdictAssigned": pressure_attempt["modelQualityVerdictAssigned"],
        },
        "configuration": {
            "ASR": "Qwen JA Standard",
            "alignment": "Qwen3 Forced Aligner Standard",
            "diarization": "SpeakerKit Standard",
            "cues": "Standard",
            "overlapRecovery": None,
            "translationDefault": CANDIDATES[0],
            "translationBetaLightweight": CANDIDATES[1],
            "paidAPI": False,
        },
        "rows": report_rows,
        "reused4BReplay": reuse,
        "relevantBaselineByCorpus": baselines,
        "representativeSubtitleDifferences": examples,
        "COMETAvailability": read(root / "comet-availability.json"),
        "crossModelHandoff": handoff,
        "gates": gates,
        "workflowAuditable": all(gates.values()),
        "modelQualityFailuresAreNotHarnessFailures": routes_are_model_results,
        "scopeLimit": (
            "This fresh-process replay validates translation quality and lifecycle on two hashed "
            "upstream artifacts; it is not a completed integrated run."
            if translation_only else
            "Two local videos validate this integrated workflow, not universal subtitle quality."
        ),
    }

    lines = [
        "# Validation offline intégrée #106"
        + (f' — replay traduction {"12B" if candidates == [CANDIDATES[0]] else "4B"}'
           if translation_only else
           (" — partielle 4B_ONLY" if four_b_only else "")), "",
    ]
    if four_b_only:
        lines += [
            "La campagne #106 reste **INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE** : "
            "ce run valide uniquement le 4B et ne produit aucun verdict qualité 12B. "
            "Voir la [preuve brute 12B](evidence/E31-12b-pressure-attempt/report.json).", "",
        ]
    if translation_only:
        lines += [
            "Ce résultat est un replay traduction-only en processus frais sur amont E22 hashé. "
            "Pour la vidéo 1, ASR, alignement et spans SpeakerKit sont byte-identiques aux traces "
            "E31 normalisées ; le HighQualityJob courant vérifie aussi la requête de traduction exacte. "
            "Ce n’est pas un run intégré complet.", "",
        ]
    if full_12b_only:
        lines += [
            ("La vidéo 1 12B complète est réutilisée après vérification de tous ses hashes ; "
             "la vidéo 2 12B vient de la reprise end-to-end actuelle. " if resume_full_12b else
             "Les lignes 12B viennent des deux jobs intégrés actuels. ")
            + "Les lignes 4B réutilisent "
            "le replay exact déjà audité et hashé ; aucun poids 4B n’a été accédé par ce run.", "",
        ]
    lines += [
        "Configuration réelle : Qwen JA Standard, alignement et SpeakerKit/cues Standard, "
        "aucune récupération d’overlap ; 12B reste le défaut et 4B l’option bêta légère.", "",
        "| Vidéo | Modèle | Route | CER JA | chrF++ | COMET | Total / RTF | ASR | Align. | SpeakerKit | Trad. | Mémoire | Intégrité/cues | Locuteurs/overlap |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|",
    ]
    for row in report_rows:
        time, quality, resource = row["timingSeconds"], row["quality"], row["resources"]
        reasons = sum(row["integrity"]["finalReasonCounts"].values())
        subtitles = row["subtitleQuality"]
        pressure = ",".join(resource["nativePressureLevels"]) or "normal"
        swap = resource["externalSwapDeltaBytes"]
        swap = resource["workerSwapDeltaBytes"] if swap is None else swap
        speakers = row["speakers"]
        lines.append(
            f'| {row["role"]} | {row["translator"].split("-")[1]} | {row["resultRoute"]} | '
            f'{fmt(quality["japaneseCERPercent"])} | {fmt(quality["chrFPlusPlus"])} | '
            f'{fmt(quality["COMET"], 4)} | {clock(time["total"])} / {row["realTimeFactor"]:.2f}× | '
            f'{clock(time["ASR"])} | {clock(time["alignment"])} | {clock(time["SpeakerKit"])} | '
            f'{clock(time["translation"])} | {resource["peakPhysicalFootprintBytes"] / 2**30:.2f} GiB; '
            f'pression {pressure}; swap {swap / 2**20:.0f} MiB | '
            f'{reasons} rejet(s); {subtitles["cueCount"]} cues; '
            f'>84c {len(subtitles["over84CharacterCueIDs"])}; '
            f'>20c/s {len(subtitles["over20CharactersPerSecondCueIDs"])} | '
            f'DER {fmt(speakers["DERPercent"])}%; Δspk {speakers["speakerCountAbsoluteError"]}; '
            f'overlap manqué/inventé {speakers["overlap"]["missedSeconds"]:.1f}/'
            f'{speakers["overlap"]["inventedSeconds"]:.1f}s |'
        )
    lines += ["", "## Comparaison concrète", ""]
    for corpus in CORPORA:
        base = baselines[corpus]
        lines.append(
            f'- {ROLES[corpus]} — baseline E22 : CER {fmt(base["japaneseCERPercent"])} %, '
            f'chrF++ {fmt(base["chrFPlusPlus"])}, COMET {fmt(base["COMET"], 4)}.'
        )
        for example in examples[corpus][:3]:
            lines += [
                f'  - JA : {example["source"]}',
                f'    Référence : {example["reference"]}',
                f'    12B {"(E22 historique)" if candidates == [CANDIDATES[1]] else ""}: '
                f'{example["translateGemma12B"]}',
                f'    4B : {example["translateGemma4B"]}',
            ]
    lines += ["", "## Décision", "",
              "Les pannes de validation produit restent classées comme qualité modèle ; toute panne build, runner, référence ou sécurité interdit un verdict modèle.",
              report["scopeLimit"]]
    if report["finalIntegrated12BReadiness"]:
        lines += ["", "**NO_READY** pour le dernier run intégré 12B : la commande `full` existante "
                  "relance aussi le 4B, hors du scope accordé. Aucune nouvelle variante n’est préparée."]
    lines.append("")
    return report, "\n".join(lines)


def self_test() -> None:
    assert decoded_map(["transcribing", 2, "translating", 3]) == {
        "transcribing": 2.0, "translating": 3.0,
    }
    summary = stage_summary({"stageDurations": [
        "preparing-asr", 1, "transcribing", 2, "preparing-alignment", 3,
        "aligning", 4, "preparing-diarization", 5, "diarizing", 6,
    ]})
    assert summary["ASR"] == 3 and summary["alignment"] == 7
    assert summary["SpeakerKit"] == 11
    pressure_attempt = read(PRESSURE_ATTEMPT)
    assert pressure_attempt["classification"] == "INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE"
    assert pressure_attempt["modelQualityVerdictAssigned"] is False
    complete = {"productStatus": "completed", "resultRoute": "completed",
                "exportsSHA256": dict.fromkeys(EXPORTS, "hash")}
    assert current_12b_jobs_complete([complete, complete])
    assert not current_12b_jobs_complete([complete, {**complete, "exportsSHA256": {}}])
    assert integrated_campaign_complete(True, {"jobs": True, "tests": True})
    assert not integrated_campaign_complete(True, {"jobs": True, "tests": False})
    report = Path("docs/high-quality-integrated-e31-translation-only-4b.json")
    evidence = Path("docs/japanese-live/experiments/evidence/E31-translation-only-4b")
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        reuse = {"audited": True, "modelWeightsAccessed": False,
                 "report": {"path": str(report), "sha256": sha256(report)},
                 "evidence": {"path": str(evidence),
                              "manifestSHA256": sha256(evidence / "sha256.tsv")}}
        (root / "4b-replay-reuse.json").write_text(json.dumps(reuse), encoding="utf-8")
        assert len(reused_4b_replay(root)[1]) == len(CORPORA)
        bad = root / "bad"
        bad.mkdir()
        (bad / "sha256.tsv").write_text(f'{"0" * 64}  {bad / "missing.raw"}\n')
        reuse["evidence"] = {"path": str(bad),
                             "manifestSHA256": sha256(bad / "sha256.tsv")}
        (root / "4b-replay-reuse.json").write_text(json.dumps(reuse), encoding="utf-8")
        try:
            reused_4b_replay(root)
            raise AssertionError("invalid 4B manifest accepted")
        except FileNotFoundError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--prepare-scoring", action="store_true")
    parser.add_argument("--candidate", action="append", choices=CANDIDATES)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    assert args.root, "artifact root is required"
    candidates = args.candidate or CANDIDATES
    if args.prepare_scoring:
        prepare_scoring(args.root, candidates)
        return
    assert args.json and args.markdown, "--json and --markdown are required"
    report, markdown = build_report(args.root, candidates)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    args.markdown.write_text(markdown, encoding="utf-8")


if __name__ == "__main__":
    main()
