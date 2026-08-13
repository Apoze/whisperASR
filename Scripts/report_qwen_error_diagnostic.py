#!/usr/bin/env python3
"""Freeze the DEV-only Qwen error diagnostic from E22 evidence."""

from __future__ import annotations

import argparse
import difflib
import gzip
import hashlib
import json
import math
import re
import sys
import time
import wave
from array import array
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
RAW_E22 = ROOT / "docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz"
E22_REPORT = ROOT / "docs/high-quality-standard-e22.json"
EXPECTED = {
    "manifest": "a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b",
    "rawE22": "1f5edc2fcb929c9abc2cb85256f326bbf2891a200ef66d1c1cb9a66a9c711ce8",
    "e22Report": "7cb21ebab639fcbc290dc30d951e9a15864701a64fee5907f0b09da522ab6a13",
    "source": "b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1",
    "audio": "494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2",
    "characterAlignment": "abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7",
}
MODEL_ID = "ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit"
MODEL_REVISION = "7c70d18cb650655d32eafb952a74a49c6a3caad0"
MODEL_WEIGHT = "bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954"
NUMBER_RE = re.compile(r"[0-9０-９]+")
MEANING_ANCHORS = {
    31: ["3ゲージ", "残っています"],
    32: ["リーサル", "ドーーーン"],
    56: ["豪鬼", "9000", "10000"],
    57: ["1000", "でかい"],
    107: ["2対2"],
    126: ["2800"],
    131: ["前に行かない", "バックステップ", "チャンス"],
    137: ["ラスト1ラウンド"],
    199: ["次の試合", "あります"],
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize(text: str) -> str:
    return re.sub(r"[^0-9A-Za-z\u3040-\u30ff\u3400-\u9fff]", "", text).lower()


def split_units(chunks: list[dict], maximum_seconds: float = 8.0) -> list[dict]:
    units = []
    for chunk in chunks:
        items_by_cue: dict[str, list[dict]] = {}
        for item in chunk["rawItems"]:
            items_by_cue.setdefault(item["cueID"], []).append(item)
        for cue in chunk["cues"]:
            items = items_by_cue.get(cue["id"], [])
            if cue["end"] - cue["start"] <= maximum_seconds or not items:
                groups = [items]
            else:
                groups = []
                for item in items:
                    if groups and item["end"] - groups[-1][0]["start"] <= maximum_seconds:
                        groups[-1].append(item)
                    else:
                        groups.append([item])
            for part, group in enumerate(groups, 1):
                if len(groups) == 1:
                    start, end, text = cue["start"], cue["end"], cue["text"]
                else:
                    start = group[0]["start"]
                    end = max(item["end"] for item in group)
                    text = "".join(item["text"] for item in group)
                units.append({
                    "id": cue["id"] if len(groups) == 1 else f'{cue["id"]}-part-{part}',
                    "parentCueID": cue["id"],
                    "chunkIndex": chunk["index"],
                    "chunkStart": chunk["sourceStart"],
                    "chunkEnd": chunk["sourceEnd"],
                    "start": start,
                    "end": end,
                    "text": text,
                    "rawItemCount": len(group),
                    "zeroDurationRawItemCount": sum(
                        item["end"] <= item["start"] for item in group
                    ),
                })
    assert units and all(0 < unit["end"] - unit["start"] <= maximum_seconds + 1e-6
                         for unit in units)
    return units


def assign_reference(units: list[dict], reference_rows: list[dict]) -> list[dict]:
    unassigned = []
    for unit in units:
        unit["referenceCharacters"] = []
    for row in reference_rows:
        if row["speaker_id"] == "SPEAKER_NONE":
            continue
        for character in row["characters"]:
            midpoint = (character["start"] + character["end"]) / 2
            target = next((unit for unit in units
                           if unit["start"] <= midpoint < unit["end"]), None)
            if target is None:
                unassigned.append({
                    "cueID": int(row["cue_id"]),
                    "char": character["char"],
                    "start": character["start"],
                    "end": character["end"],
                })
                continue
            target["referenceCharacters"].append({
                "cueID": int(row["cue_id"]),
                "char": character["char"],
                "start": character["start"],
                "end": character["end"],
                "method": character["method"],
                "confidence": character["confidence"],
            })
    return unassigned


def classify_unit(reference: str, hypothesis: str, terms: list[str] | None = None,
                  meaning_anchors: list[str] | None = None) -> dict:
    reference_normalized, hypothesis_normalized = normalize(reference), normalize(hypothesis)
    equal = lost = inserted = 0
    for tag, left_start, left_end, right_start, right_end in difflib.SequenceMatcher(
        None, reference_normalized, hypothesis_normalized, autojunk=False
    ).get_opcodes():
        if tag == "equal":
            equal += left_end - left_start
        elif tag == "delete":
            lost += left_end - left_start
        elif tag == "insert":
            inserted += right_end - right_start
        else:
            lost += left_end - left_start
            inserted += right_end - right_start
    numbers = list(dict.fromkeys(NUMBER_RE.findall(reference)))
    terms = [term for term in terms or [] if normalize(term) in reference_normalized]
    meaning_anchors = [anchor for anchor in meaning_anchors or []
                       if normalize(anchor) in reference_normalized]

    def partition(values: list[str]) -> dict:
        recovered, missed = [], []
        for value in values:
            (recovered if normalize(value) in hypothesis_normalized else missed).append(value)
        return {"recovered": recovered, "lost": missed}

    return {
        "speech": {
            "recoveredCharacters": equal,
            "lostCharacters": lost,
            "insertedOrSubstitutedCharacters": inserted,
            "referenceCharacters": len(reference_normalized),
        },
        "terms": partition(terms),
        "numbers": partition(numbers),
        "meaning": partition(meaning_anchors),
        "emptyTurn": bool(reference_normalized and not hypothesis_normalized),
        "similarityPercent": 100 * difflib.SequenceMatcher(
            None, reference_normalized, hypothesis_normalized, autojunk=False
        ).ratio(),
    }


def read_audio(audio: Path, sample_rate: int) -> array:
    with wave.open(str(audio), "rb") as handle:
        if (handle.getnchannels(), handle.getsampwidth(), handle.getframerate()) \
                != (1, 2, sample_rate):
            raise RuntimeError("runner-input: expected 16 kHz mono PCM s16le")
        payload = handle.readframes(handle.getnframes())
    samples = array("h")
    samples.frombytes(payload)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def rms_dbfs(values: array | list[int]) -> float:
    if not values:
        return -120.0
    mean_square = sum(value * value for value in values) / len(values)
    return -120.0 if mean_square == 0 else 20 * math.log10(math.sqrt(mean_square) / 32768)


def audio_features(samples: array, start: float, end: float, sample_rate: int) -> dict:
    values = samples[max(0, round(start * sample_rate)):min(len(samples), round(end * sample_rate))]
    if not values:
        raise RuntimeError("runner-input: acoustic segment is outside decoded audio")
    square_sum = sum(value * value for value in values)
    difference_sum = sum((right - left) ** 2 for left, right in zip(values, values[1:]))
    rms = math.sqrt(square_sum / len(values)) if square_sum else 0
    edge = max(1, min(len(values) // 2, sample_rate // 4))
    return {
        "rmsDBFS": rms_dbfs(values),
        "leading250msDBFS": rms_dbfs(values[:edge]),
        "trailing250msDBFS": rms_dbfs(values[-edge:]),
        "zeroCrossingRate": sum(
            (left < 0 <= right) or (right < 0 <= left)
            for left, right in zip(values, values[1:])
        ) / max(1, len(values) - 1),
        "highFrequencyRatio": difference_sum / max(1, 4 * square_sum),
        "crestFactor": max(abs(value) for value in values) / max(1, rms),
    }


def glossary_terms(raw: dict) -> list[str]:
    forms = []
    for decision in raw["glossary"]["decisions"]:
        forms.extend(decision["term"].get("japaneseForms", []))
    return list(dict.fromkeys(forms))


def material_score(unit: dict) -> int:
    classification = unit["classification"]
    return (classification["speech"]["lostCharacters"]
            + 5 * len(classification["terms"]["lost"])
            + 5 * len(classification["numbers"]["lost"])
            + 5 * len(classification["meaning"]["lost"])
            + 10 * int(classification["emptyTurn"])
            + 10 * int(unit["duplicatedTurn"]))


def build_diagnostic(source: Path, audio: Path, character_alignment: Path) -> tuple[dict, dict]:
    started = time.monotonic()
    with gzip.open(RAW_E22, "rt", encoding="utf-8") as handle:
        raw = json.load(handle)
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    e22 = json.loads(E22_REPORT.read_text(encoding="utf-8"))
    reference_rows = [json.loads(line) for line in character_alignment.read_text(
        encoding="utf-8"
    ).splitlines() if line]
    dev_row = next(row for row in e22["rows"] if row["corpusID"] == "qudu2fx3ncc")
    hashes = {
        "manifest": sha256(MANIFEST),
        "rawE22": sha256(RAW_E22),
        "e22Report": sha256(E22_REPORT),
        "source": sha256(source),
        "audio": sha256(audio),
        "characterAlignment": sha256(character_alignment),
    }
    gates = {
        "runner": {
            "pythonSupported": sys.version_info >= (3, 11),
            "stdlibPCMReader": True,
        },
        "input": {
            "frozenHashes": hashes == EXPECTED,
            "developmentOnly": raw["source"]["fileName"] == "Video1.webm",
            "sourceHashDeclared": hashes["source"] == next(
                item["sha256"] for item in manifest["source"]["references"]
                if item["label"] == "source-video"
            ),
            "audioHashDeclared": hashes["audio"] == manifest["fixture"]["sha256"],
            "sampleCount": raw["sampleCount"] == manifest["fixture"]["sampleCount"],
            "qwenPinned": raw["model"] == {
                "backend": "qwen-ja", "modelID": MODEL_ID,
                "revision": MODEL_REVISION,
                "weightSHA256": {"model.safetensors": MODEL_WEIGHT},
            },
        },
        "reference": {
            "complete": manifest["annotations"]["status"] == "complete",
            "turnsPresent": len(manifest["annotations"]["turns"]) == 199,
            "characterAlignmentPresent": len(reference_rows) == 200
                and reference_rows[-1]["speaker_id"] == "SPEAKER_NONE",
            "characterAlignmentHashDeclared": hashes["characterAlignment"] == next(
                item["sha256"] for item in manifest["source"]["references"]
                if item["label"] == "character-alignment"
            ),
            "e22ArtifactGates": all(dev_row["artifactGates"].values()),
            "e22BuildAndReferenceControls": e22["controls"]["build"]
                and e22["controls"]["sourceDecode"]
                and e22["controls"]["referenceIntegrity"]
                and e22["controlProvenance"],
        },
    }
    failing_group = next((group for group in ("runner", "input", "reference")
                          if not all(gates[group].values())), None)
    if failing_group:
        raise RuntimeError(f"runner-{failing_group}: candidate attribution withheld: {gates}")

    sample_rate = raw["sampleRate"]
    samples = read_audio(audio, sample_rate)
    if len(samples) != raw["sampleCount"]:
        raise RuntimeError("runner-input: frozen PCM sample count differs from E22")
    units = split_units(raw["alignment"]["chunks"])
    unassigned_reference = assign_reference(units, reference_rows)
    known_terms = glossary_terms(raw)
    previous_text = ""
    for unit in units:
        characters = unit.pop("referenceCharacters")
        reference = "".join(character["char"] for character in characters)
        turn_ids = list(dict.fromkeys(character["cueID"] for character in characters))
        anchors = [anchor for turn_id in turn_ids for anchor in MEANING_ANCHORS.get(turn_id, [])]
        terms = [term for term in known_terms if normalize(term) in normalize(reference)]
        unit["referenceTurnIDs"] = turn_ids
        unit["referenceJapanese"] = reference
        unit["classification"] = classify_unit(reference, unit["text"], terms, anchors)
        normalized = normalize(unit["text"])
        unit["duplicatedTurn"] = bool(normalized and normalized == previous_text)
        previous_text = normalized
        unit["boundaryDistanceSeconds"] = min(
            unit["start"] - unit["chunkStart"], unit["chunkEnd"] - unit["end"]
        )
        unit["nearASRBoundary"] = unit["boundaryDistanceSeconds"] <= 1.0
        unit["audio"] = audio_features(samples, unit["start"], unit["end"], sample_rate)
        zero_rate = unit["zeroDurationRawItemCount"] / max(1, unit["rawItemCount"])
        duration = unit["end"] - unit["start"]
        weakness = []
        if zero_rate >= 0.08:
            weakness.append("alignment-zero-duration-rate>=0.08")
        if len(normalized) / duration < 1 or len(normalized) / duration > 12:
            weakness.append("qwen-character-rate-outside-1-to-12-per-second")
        if unit["classification"]["emptyTurn"]:
            weakness.append("speech-without-text")
        if unit["duplicatedTurn"]:
            weakness.append("exact-consecutive-duplicate")
        acoustic = []
        if unit["audio"]["rmsDBFS"] >= -32:
            acoustic.append("active-rms>=-32-dBFS")
        if unit["audio"]["highFrequencyRatio"] >= 0.10:
            acoustic.append("broadband-ratio>=0.10")
        if unit["audio"]["crestFactor"] <= 6:
            acoustic.append("dense-crest-factor<=6")
        if max(unit["audio"]["leading250msDBFS"], unit["audio"]["trailing250msDBFS"]) >= -32:
            acoustic.append("active-segment-edge>=-32-dBFS")
        active_mix = any(signal.startswith("active-") for signal in acoustic)
        textured_mix = any(signal.startswith(("broadband-", "dense-")) for signal in acoustic)
        unit["automaticSignals"] = {
            "referenceFreeWeakness": weakness,
            "voiceMusicAcoustic": acoustic,
            "voiceMusicTrigger": bool(weakness and active_mix and textured_mix),
        }
        unit["materialErrorScore"] = material_score(unit)

    referenced = [unit for unit in units if unit["referenceJapanese"]]
    losses = [unit for unit in referenced if unit["classification"]["speech"]["lostCharacters"] >= 3]
    boundary_losses = [unit for unit in losses if unit["nearASRBoundary"]]
    triggered = sorted(
        (unit for unit in units if unit["automaticSignals"]["voiceMusicTrigger"]
         and unit["materialErrorScore"] > 0),
        key=lambda unit: unit["materialErrorScore"], reverse=True,
    )
    hard = triggered[:8]
    material = sorted(
        (unit for unit in units if unit["materialErrorScore"] > 0),
        key=lambda unit: unit["materialErrorScore"], reverse=True,
    )
    assigned_cue_ids = {cue_id for unit in units for cue_id in unit["referenceTurnIDs"]}
    empty_reference_cues = [
        int(row["cue_id"]) for row in reference_rows
        if row["speaker_id"] != "SPEAKER_NONE" and int(row["cue_id"]) not in assigned_cue_ids
    ]
    chunk_boundaries = [boundary for chunk in raw["alignment"]["chunks"]
                        for boundary in (chunk["sourceStart"], chunk["sourceEnd"])]
    unassigned_by_cue = {}
    for character in unassigned_reference:
        unassigned_by_cue.setdefault(character["cueID"], []).append(character)
    unassigned_loss_fragments = []
    for cue_id, characters in sorted(unassigned_by_cue.items()):
        distance = min(
            abs(point - boundary)
            for character in characters
            for point in (character["start"], character["end"])
            for boundary in chunk_boundaries
        )
        unassigned_loss_fragments.append({
            "cueID": cue_id,
            "normalizedCharacterCount": sum(len(normalize(row["char"])) for row in characters),
            "boundaryDistanceSeconds": distance,
            "nearASRBoundary": distance <= 1,
        })
    empty_details = []
    for row in reference_rows:
        cue_id = int(row["cue_id"])
        if cue_id not in empty_reference_cues:
            continue
        distance = min(abs(row["start"] - boundary) for boundary in chunk_boundaries)
        distance = min(distance, min(abs(row["end"] - boundary)
                                     for boundary in chunk_boundaries))
        terms = [term for term in known_terms if normalize(term) in normalize(row["japanese"])]
        classification = classify_unit(
            row["japanese"], "", terms, MEANING_ANCHORS.get(cue_id, [])
        )
        empty_details.append({
            "cueID": cue_id,
            "start": row["start"],
            "end": row["end"],
            "referenceJapanese": row["japanese"],
            "boundaryDistanceSeconds": distance,
            "nearASRBoundary": distance <= 1,
            "classification": classification,
        })
    unassigned_normalized = sum(len(normalize(row["char"])) for row in unassigned_reference)
    boundary_loss_count = len(boundary_losses) + sum(
        row["nearASRBoundary"] for row in unassigned_loss_fragments
    )
    loss_count = len(losses) + len(unassigned_loss_fragments)
    boundary_share = boundary_loss_count / max(1, loss_count)
    exposure = (sum(unit["nearASRBoundary"] for unit in referenced)
                + sum(row["nearASRBoundary"] for row in unassigned_loss_fragments)) \
        / max(1, len(referenced) + len(unassigned_loss_fragments))
    concentration = boundary_share / max(0.0001, exposure)
    fire_red_eligible = boundary_loss_count >= 3 and boundary_share >= 0.60 \
        and concentration >= 1.5
    counts = {
        "units": len(units),
        "referenceAssignedUnits": len(referenced),
        "unassignedReferenceCharacters": unassigned_normalized,
        "unassignedReferenceLossFragments": len(unassigned_loss_fragments),
        "maximumDurationSeconds": max(unit["end"] - unit["start"] for unit in units),
        "speechRecoveredCharacters": sum(
            unit["classification"]["speech"]["recoveredCharacters"] for unit in referenced
        ),
        "speechLostCharacters": unassigned_normalized + sum(
            unit["classification"]["speech"]["lostCharacters"] for unit in referenced
        ),
        "termRecovered": sum(len(unit["classification"]["terms"]["recovered"])
                             for unit in referenced),
        "termLost": sum(len(unit["classification"]["terms"]["lost"])
                        for unit in referenced)
            + sum(len(row["classification"]["terms"]["lost"])
                  for row in empty_details),
        "numberRecovered": sum(len(unit["classification"]["numbers"]["recovered"])
                               for unit in referenced),
        "numberLost": sum(len(unit["classification"]["numbers"]["lost"])
                          for unit in referenced)
            + sum(len(row["classification"]["numbers"]["lost"])
                  for row in empty_details),
        "meaningRecovered": sum(len(unit["classification"]["meaning"]["recovered"])
                                for unit in referenced),
        "meaningLost": sum(len(unit["classification"]["meaning"]["lost"])
                           for unit in referenced)
            + sum(len(row["classification"]["meaning"]["lost"])
                  for row in empty_details),
        "emptyTurns": len(empty_reference_cues)
            + sum(unit["classification"]["emptyTurn"] for unit in units),
        "duplicatedTurns": sum(unit["duplicatedTurn"] for unit in units),
        "voiceMusicTriggeredMaterialWindows": len(triggered),
    }
    segments = {
        "schemaVersion": 1,
        "ticket": 87,
        "corpusRole": "development",
        "holdoutOpened": False,
        "unitDefinition": {
            "source": "E22 Qwen forced-aligned cues split only at model-returned item times",
            "maximumSeconds": 8,
            "usesReferenceToDefineBoundaries": False,
            "sampleRate": sample_rate,
            "audioSHA256": hashes["source"],
            "pcmSHA256": hashes["audio"],
            "referenceCharacterAlignmentSHA256": hashes["characterAlignment"],
        },
        "units": units,
        "unassignedReference": {
            "normalizedCharacterCount": unassigned_normalized,
            "emptyReferenceCueIDs": empty_reference_cues,
            "lossFragments": unassigned_loss_fragments,
            "characters": unassigned_reference,
        },
    }
    report = {
        "schemaVersion": 1,
        "ticket": 87,
        "decision": "qwen-diagnostic-frozen-development-only",
        "candidateAttribution": "allowed-after-runner-input-reference-controls",
        "holdoutOpened": False,
        "productChanges": "none",
        "liveChanges": "none",
        "standardDefaultsChanged": False,
        "controls": gates,
        "counts": counts,
        "classification": {
            "speech": "reference-relative recovered/lost Japanese characters",
            "terms": "pinned glossary Japanese forms present in the authoritative DEV reference",
            "numbers": "Arabic and full-width number tokens",
            "meaning": "predeclared DEV propositions for terms, numbers, negation and game state",
            "emptyAndDuplicateTurns": "empty against non-empty reference; exact consecutive duplicate",
            "boundary": "material unit or unassigned reference cue fragment within 1.0 second of an E22 ASR-window edge",
        },
        "representativeMaterialErrors": [{
            "id": unit["id"], "start": unit["start"], "end": unit["end"],
            "referenceJapanese": unit["referenceJapanese"], "qwenJapanese": unit["text"],
            "classification": unit["classification"],
            "nearASRBoundary": unit["nearASRBoundary"],
        } for unit in material[:12]],
        "turnIntegrity": {
            "empty": empty_details,
            "duplicates": [{
                "id": unit["id"], "start": unit["start"], "end": unit["end"],
                "qwenJapanese": unit["text"],
            } for unit in units if unit["duplicatedTurn"]],
        },
        "voiceMusic": {
            "runtimeRule": "one reference-free Qwen/alignment weakness AND active audio AND one broadband/dense mix proxy",
            "thresholds": {
                "alignmentZeroDurationRate": 0.08,
                "characterRatePerSecond": [1, 12],
                "activeRMSDBFS": -32,
                "broadbandHighFrequencyRatio": 0.10,
                "denseMaximumCrestFactor": 6,
                "activeSegmentEdgeDBFS": -32,
            },
            "hardDevelopmentWindows": [{
                "id": unit["id"], "start": unit["start"], "end": unit["end"],
                "referenceJapanese": unit["referenceJapanese"], "qwenJapanese": unit["text"],
                "signals": unit["automaticSignals"], "audio": unit["audio"],
                "materialErrorScore": unit["materialErrorScore"],
            } for unit in hard],
            "productEligible": False,
            "reason": "diagnostic trigger frozen on DEV; no enhancement candidate has been run",
        },
        "fireRed": {
            "rule": "eligible only with >=3 boundary-loss units/fragments, >=60% near an edge, and >=1.5x enrichment over boundary exposure",
            "lossUnitsOrUnassignedCueFragments": loss_count,
            "boundaryLossUnitsOrFragments": boundary_loss_count,
            "boundaryLossShare": boundary_share,
            "boundaryExposureShare": exposure,
            "concentrationRatio": concentration,
            "eligible": fire_red_eligible,
            "decision": "eligible-for-isolated-development-experiment" if fire_red_eligible
                else "ineligible-no-concentrated-boundary-loss",
        },
        "developmentToHoldout": {
            "state": "holdout-closed",
            "authorization": "none",
            "requiredBeforeOpening": [
                "freeze one candidate and all thresholds from DEV",
                "recover more material speech than lost",
                "no worse terms or numbers",
                "no net empty or duplicated turns",
                "no semantic inversion",
                "retain raw outputs, timings, memory and hashes",
            ],
        },
        "timings": {
            "diagnosticSeconds": time.monotonic() - started,
            "modelRunsLaunched": 0,
            "reusedE22TotalSeconds": dev_row["candidate"]["runtimeSeconds"],
            "reusedE22TranscriptionSeconds": dev_row["candidate"]["stageDurations"]["transcribing"],
            "reusedE22PeakMemoryBytes": dev_row["candidate"]["peakMemoryBytes"],
        },
        "provenance": {
            "hashes": hashes,
            "reporterSHA256": sha256(Path(__file__)),
            "decodedSampleCount": len(samples),
            "e22Model": raw["model"],
        },
        "limits": "One supplied DEV video; this diagnostic does not prove universal anime, VTuber, gaming, conversation, voice or music quality.",
    }
    return segments, report


def markdown(report: dict, segments_path: Path) -> str:
    counts, fire_red, timing = report["counts"], report["fireRed"], report["timings"]
    lines = [
        "# E23 — Diagnostic figé des erreurs Qwen (#87)", "",
        "E22 est réutilisé sans relancer de modèle. Le holdout reste fermé ; aucun changement produit, UI, Live ou valeur Standard.", "",
        "## Résultat", "",
        f'- {counts["units"]} segments acoustiques DEV, tous ≤ {counts["maximumDurationSeconds"]:.2f} s, reliés au SHA audio `{report["provenance"]["hashes"]["audio"]}`.',
        f'- Parole : {counts["speechRecoveredCharacters"]} caractères récupérés et {counts["speechLostCharacters"]} perdus/substitués.',
        f'- Termes : {counts["termRecovered"]} récupérés, {counts["termLost"]} perdus. Nombres : {counts["numberRecovered"]} récupérés, {counts["numberLost"]} perdus.',
        f'- Sens déclarés : {counts["meaningRecovered"]} récupérés, {counts["meaningLost"]} perdus. Tours vides/dupliqués : {counts["emptyTurns"]}/{counts["duplicatedTurns"]}.',
        f'- Voix/musique : {counts["voiceMusicTriggeredMaterialWindows"]} fenêtres DEV difficiles déclenchées automatiquement.',
        f'- FireRed : **{fire_red["decision"]}** ({fire_red["boundaryLossUnitsOrFragments"]}/{fire_red["lossUnitsOrUnassignedCueFragments"]} pertes près des frontières, concentration {fire_red["concentrationRatio"]:.2f}×).', "",
        "## Exemples concrets", "",
    ]
    for row in report["representativeMaterialErrors"][:5]:
        lines += [
            f'- {row["start"]:.2f}–{row["end"]:.2f} s — référence : « {row["referenceJapanese"]} » ; Qwen : « {row["qwenJapanese"]} ».',
        ]
    if report["turnIntegrity"]["empty"]:
        row = report["turnIntegrity"]["empty"][0]
        lines += [f'- Tour vide {row["start"]:.2f}–{row["end"]:.2f} s : « {row["referenceJapanese"]} ».']
    lines += ["", "## Coût et provenance", "",
              f'- Diagnostic : {timing["diagnosticSeconds"]:.2f} s, 0 modèle lancé.',
              f'- Preuve E22 réutilisée : {timing["reusedE22TotalSeconds"] / 60:.0f} min {timing["reusedE22TotalSeconds"] % 60:.0f} s au total, ASR {timing["reusedE22TranscriptionSeconds"]:.1f} s, pic {timing["reusedE22PeakMemoryBytes"] / 2**30:.2f} Gio.',
              f'- Segments bruts : `{segments_path}`.', "",
              "Commande : `python3 Scripts/report_qwen_error_diagnostic.py --source <Video1.webm> --audio <audio-16k-mono.wav> --character-alignment <character-alignment.jsonl> --segments-json docs/japanese-live/experiments/evidence/E23/segments.json --report-json docs/japanese-live/experiments/evidence/E23/report.json --markdown docs/japanese-live/experiments/E23-qwen-error-diagnostic.md`.", "",
              "Le déclencheur voix/musique est seulement figé pour une expérience DEV future. Aucun traitement audio ni option n’est promu.", ""]
    return "\n".join(lines)


def self_test() -> None:
    chunks = [{
        "index": 0, "sourceStart": 0.0, "sourceEnd": 12.0,
        "cues": [{"id": "cue-1", "start": 0.0, "end": 12.0, "text": "一二三四"}],
        "rawItems": [
            {"cueID": "cue-1", "start": 0.0, "end": 3.0, "text": "一"},
            {"cueID": "cue-1", "start": 3.0, "end": 6.0, "text": "二"},
            {"cueID": "cue-1", "start": 6.0, "end": 9.0, "text": "三"},
            {"cueID": "cue-1", "start": 9.0, "end": 12.0, "text": "四"},
        ],
    }]
    units = split_units(chunks, maximum_seconds=8.0)
    assert [unit["text"] for unit in units] == ["一二", "三四"]
    assert all(unit["end"] - unit["start"] <= 8 for unit in units)
    diagnostic = classify_unit("3ゲージ残っています", "3ゲージ")
    assert diagnostic["numbers"]["recovered"] == ["3"]
    assert diagnostic["speech"]["lostCharacters"] > 0
    empty = classify_unit("リーサルだー！ドーーーン!!!2", "", ["リーサル"], ["ドーーーン"])
    assert empty["terms"]["lost"] == ["リーサル"]
    assert empty["numbers"]["lost"] == ["2"]
    assert empty["meaning"]["lost"] == ["ドーーーン"]
    reference_rows = [{"cue_id": "031", "speaker_id": "SPEAKER_01", "characters": [
        {"char": "三", "start": 1.0, "end": 1.2, "method": "fixture", "confidence": "high"},
        {"char": "本", "start": 9.0, "end": 9.2, "method": "fixture", "confidence": "high"},
    ]}]
    assert assign_reference(units, reference_rows) == []
    assert ["".join(row["char"] for row in unit["referenceCharacters"])
            for unit in units] == ["三", "本"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--audio", type=Path)
    parser.add_argument("--character-alignment", type=Path)
    parser.add_argument("--segments-json", type=Path)
    parser.add_argument("--report-json", type=Path)
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not all((args.source, args.audio, args.character_alignment, args.segments_json,
                args.report_json, args.markdown)):
        parser.error("--source, --audio, --character-alignment, --segments-json, "
                     "--report-json and --markdown are required")
    segments, report = build_diagnostic(args.source, args.audio, args.character_alignment)
    args.segments_json.parent.mkdir(parents=True, exist_ok=True)
    args.segments_json.write_text(json.dumps(segments, ensure_ascii=False, indent=2) + "\n",
                                  encoding="utf-8")
    relative_segments = args.segments_json.resolve().relative_to(ROOT)
    report["provenance"]["segments"] = {
        "path": str(relative_segments),
        "sha256": sha256(args.segments_json),
    }
    args.report_json.parent.mkdir(parents=True, exist_ok=True)
    args.report_json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                encoding="utf-8")
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text(markdown(report, relative_segments),
                             encoding="utf-8")


if __name__ == "__main__":
    main()
