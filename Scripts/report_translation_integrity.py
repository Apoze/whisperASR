#!/usr/bin/env python3
import argparse
import json
from collections import Counter
from pathlib import Path

REASONS = {
    "empty-output",
    "residual-japanese",
    "control-scaffolding",
    "critical-glossary-violation",
    "truncated-output",
    "degenerate-repetition",
    "pathological-length",
    "copied-neighbour",
}


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def fixture_metrics(data: dict) -> dict:
    true_detections = 0
    false_positives = []
    false_negatives = []
    covered = set()
    for fixture in data["fixtures"]:
        verdicts = {row["cueID"]: row for row in fixture["verdicts"]}
        for expectation in fixture["expectations"]:
            cue = expectation["cueID"]
            expected = set(expectation["expectedReasonCodes"])
            actual = {reason["code"] for reason in verdicts[cue]["reasons"]}
            covered.update(expected)
            true_detections += len(expected & actual)
            false_positives.extend(
                {"fixture": fixture["name"], "cueID": cue, "reason": reason}
                for reason in sorted(actual - expected)
            )
            false_negatives.extend(
                {"fixture": fixture["name"], "cueID": cue, "reason": reason}
                for reason in sorted(expected - actual)
            )
    return {
        "trueDetections": true_detections,
        "falsePositives": false_positives,
        "falseNegatives": false_negatives,
        "coveredReasons": sorted(covered),
        "allReasonsCovered": covered == REASONS,
    }


def corpus_metrics(data: dict) -> dict:
    reasons = Counter(
        reason["code"]
        for verdict in data["verdicts"]
        for reason in verdict["reasons"]
    )
    verdicts = Counter(row["verdict"] for row in data["verdicts"])
    return {
        "units": len(data["verdicts"]),
        "verdictCounts": dict(sorted(verdicts.items())),
        "reasonCounts": {reason: reasons.get(reason, 0) for reason in sorted(REASONS)},
        "glossaryOpportunities": sum(
            len(row["glossaryOpportunities"]) for row in data["verdicts"]
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    parser.add_argument("--include-holdout", action="store_true")
    args = parser.parse_args()

    fixtures_path = args.artifacts / "fixtures.json"
    development_path = args.artifacts / "development.json"
    holdout_path = args.artifacts / "holdout.json"
    fixtures = read(fixtures_path)
    development = read(development_path)
    holdout = read(holdout_path) if args.include_holdout else None
    thresholds = development["thresholds"]
    if fixtures["thresholds"] != thresholds or (
        holdout and holdout["thresholds"] != thresholds
    ):
        raise SystemExit("Fixture, development, and holdout thresholds must match exactly.")

    injected = fixture_metrics(fixtures)
    report = {
        "schemaVersion": 1,
        "thresholds": thresholds,
        "injectedCorruptions": injected,
        "realVideos": {
            "development": corpus_metrics(development),
            **({"holdout": corpus_metrics(holdout)} if holdout else {}),
        },
        "rawArtifacts": [
            relative(fixtures_path),
            relative(development_path),
            relative(Path(development["sourceArtifact"])),
            *([relative(holdout_path)] if holdout else []),
            *([relative(Path(holdout["sourceArtifact"]))] if holdout else []),
        ],
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    lines = [
        "# E10 — Deterministic translation-integrity verdicts",
        "",
        "Ticket #51 adds an evidence-only shadow validator. It never changes or rejects a published Deliverable.",
        "",
        "## Frozen development thresholds",
        "",
        f"Version `{thresholds['version']}` was calibrated on the 313 E09 development units and frozen before processing holdout.",
        "",
        "| Minimum length ratio | Maximum length ratio | Copied-output similarity | Corresponding-source ceiling |",
        "|---:|---:|---:|---:|",
        f"| {thresholds['minimumLengthRatio']:.2f} | {thresholds['maximumLengthRatio']:.2f} | {thresholds['copiedOutputSimilarity']:.2f} | {thresholds['correspondingSourceSimilarity']:.2f} |",
        "",
        "## Injected corruptions",
        "",
        "| True detections | False positives | False negatives | All reason codes covered |",
        "|---:|---:|---:|:---:|",
        f"| {injected['trueDetections']} | {len(injected['falsePositives'])} | {len(injected['falseNegatives'])} | {'yes' if injected['allReasonsCovered'] else 'no'} |",
        "",
        "Valid fixtures cover short, long, named-entity, and mixed-punctuation translations. Japanese residue fixtures cover hiragana, katakana, half-width kana, and CJK; the explicit allowlist is empty unless supplied by the caller.",
        "",
        "## Real-video shadow counts",
        "",
        "| Corpus | Units | Pass | Suspect | Hard failure | Glossary opportunities |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for name, metrics in report["realVideos"].items():
        counts = metrics["verdictCounts"]
        lines.append(
            f"| {name} | {metrics['units']} | {counts.get('pass', 0)} | "
            f"{counts.get('suspect', 0)} | {counts.get('hard-failure', 0)} | "
            f"{metrics['glossaryOpportunities']} |"
        )
    lines += ["", "| Reason | Development | Holdout |", "|---|---:|---:|"]
    development_reasons = report["realVideos"]["development"]["reasonCounts"]
    holdout_reasons = report["realVideos"].get("holdout", {}).get("reasonCounts", {})
    for reason in sorted(REASONS):
        lines.append(
            f"| `{reason}` | {development_reasons[reason]} | {holdout_reasons.get(reason, 'pending')} |"
        )
    lines += ["", "## Raw artifacts", ""]
    lines += [f"- `{path}`" for path in report["rawArtifacts"]]
    lines += [
        "",
        "No retry, semantic rewrite, truncation, or product rejection behavior is introduced.",
    ]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
