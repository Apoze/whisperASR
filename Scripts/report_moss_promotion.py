#!/usr/bin/env python3
"""Freeze issue #100 as a verified no-promotion when DEV has no MOSS winner."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile

import report_moss_joint as joint


ROOT = Path(__file__).resolve().parents[1]
E25 = ROOT / "docs/japanese-live/experiments/evidence/E25-moss-joint"
OUTPUT = ROOT / "docs/japanese-live/experiments/evidence/E26-moss-promotion/decision.json"
BASE_COMMIT = "7988ead17293c0a8aad8dbc57a5b5ea1496745d1"
E25_VERIFIER_SHA256 = "83355239003f209546a7a90224004653870b9b175997a64d32c3c7ea07e9844a"
E25_DECISION_SHA256 = "38eca9a058c0dc95421fb3b7591cb73f7460db9d52c53947b761b2ef9b226052"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(f"issue-100 fail-closed: {message}")


def authenticate_upstream(candidate: dict | None = None) -> dict[str, str]:
    verifier_path = ROOT / "Scripts/report_moss_joint.py"
    decision_path = E25 / "decision.json"
    require(sha256(verifier_path) == E25_VERIFIER_SHA256, "#99 verifier changed")
    require(sha256(decision_path) == E25_DECISION_SHA256, "#99 decision changed")
    committed = read_json(decision_path) if candidate is None else candidate
    require(committed == joint.expected_decision(), "#99 evidence is not authentic")
    require(committed.get("issue") == 99, "wrong upstream issue")
    require(committed.get("corpusRole") == "development", "upstream is not DEV")
    require(committed.get("disposition") == "not-run", "unexpected joint disposition")
    require(committed["condition"].get("authorized") is False, "joint run was authorized")
    require(committed["candidateSelection"].get("bestMOSS") is None, "DEV winner appeared")
    require(
        committed["candidateSelection"].get("decision") == "no-admissible-candidate",
        "DEV selection changed",
    )
    require(committed["safety"].get("holdoutOpened") is False, "upstream opened holdout")
    return {
        "jointVerifierSHA256": sha256(verifier_path),
        "jointDecisionSHA256": sha256(decision_path),
    }


def expected_decision() -> dict:
    upstream_hashes = authenticate_upstream()
    return {
        "schemaVersion": 1,
        "issue": 100,
        "experiment": "E26-moss-promotion-decision",
        "disposition": "not-promoted",
        "promotionGate": {
            "checked": True,
            "required": "one frozen MOSS winner on complete development video",
            "open": False,
            "observed": "bestMOSS=null; decision=no-admissible-candidate",
            "blockingEvidence": "#98 Metal OOM before first token; #99 conditional no-run",
        },
        "holdout": {
            "attempted": False,
            "opened": False,
            "configuration": None,
            "passes": 0,
            "reason": "The DEV promotion gate is closed.",
        },
        "assessment": {
            "correctAttribution": "not-assessable",
            "incorrectAttribution": "not-assessable",
            "unattributedSpeech": "not-assessable",
            "duplication": "not-assessable",
            "overlap": "not-assessable",
            "durationSeconds": None,
            "peakMemoryBytes": None,
            "metrics": None,
        },
        "product": {
            "mossUIOptionAdded": False,
            "mossRuntimeAdded": False,
            "mossDefaultAdded": False,
            "speakerKitStandardRemainsDefault": True,
            "existingSpeakerKitOptionsChanged": False,
            "liveChanged": False,
        },
        "provenance": {
            "baseCommit": BASE_COMMIT,
            "upstreamIssue": 99,
            "verifierSHA256": sha256(Path(__file__)),
            **upstream_hashes,
        },
        "verdict": "NO-PROMOTION: aucun gagnant MOSS sur DEV; holdout fermé",
    }


def check(decision: dict, expected: dict) -> None:
    require(decision == expected, "committed decision does not match authenticated evidence")


def write(decision: dict) -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(decision, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile("w", dir=OUTPUT.parent, delete=False, encoding="utf-8") as handle:
        handle.write(payload)
        temporary = Path(handle.name)
    os.replace(temporary, OUTPUT)


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    expected = expected_decision()
    if args.write:
        write(expected)
    elif args.check:
        check(read_json(OUTPUT), expected)
    else:
        tampered = copy.deepcopy(joint.expected_decision())
        tampered["candidateSelection"]["bestMOSS"] = "unproven-candidate"
        try:
            authenticate_upstream(tampered)
        except ValueError:
            return
        raise AssertionError("unproven DEV winner was accepted")


if __name__ == "__main__":
    main()
