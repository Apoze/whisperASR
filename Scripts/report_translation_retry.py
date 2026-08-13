#!/usr/bin/env python3
import argparse
import json
from collections import Counter
from pathlib import Path

from report_high_quality_acceptance import translation_rows
from report_japanese_l7d import chrf_pp


CORPORA = {"development": "qudu2fx3ncc", "holdout": "md62mmdz0m"}


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def write_lines(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(value.replace("\n", " ") for value in values) + "\n")


def comet(path: Path, hypothesis: Path) -> float | None:
    if not path.exists():
        return None
    rows = next((value for key, value in read(path).items()
                 if Path(key).name == hypothesis.name), None)
    return sum(float(row["COMET"]) for row in rows) / len(rows) if rows else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("direct_root", type=Path)
    parser.add_argument("integrity_root", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    direct_report = read(args.direct_root / "report.json")
    direct_rows = {(row["split"], row["protocol"]): row for row in direct_report["rows"]}
    rows = []
    for split in ("development", "holdout"):
        retry_path = args.root / split / "retry.json"
        if not retry_path.exists():
            continue
        direct_path = args.direct_root / split / "direct-protocol.json"
        verdict_path = args.integrity_root / f"{split}.json"
        direct = read(direct_path)
        validation = read(verdict_path)
        retry = read(retry_path)
        outputs = {
            item["id"]: item["text"]
            for item in json.loads(direct["response"])["translations"]
        }
        retry_evidence = retry.get("retry")
        if retry_evidence:
            outputs.update({
                item["id"]: item["text"]
                for item in json.loads(retry_evidence["response"])["translations"]
            })
        turns = direct["request"]["turns"]
        candidate = dict(direct)
        candidate["response"] = json.dumps({
            "translations": [
                {"id": turn["id"], "text": outputs[turn["id"]]} for turn in turns
            ]
        })
        manifest = read(Path("docs/japanese-live/corpora") / CORPORA[split] / "manifest.json")
        aligned = translation_rows(manifest, {"translation": candidate})
        hypotheses = [item["hypothesis"] for item in aligned]
        metrics = args.root / "metrics" / split
        hypothesis = metrics / "selective-retry.en.txt"
        reference = args.direct_root / "metrics" / split / "reference.en.txt"
        source = args.direct_root / "metrics" / split / "source.ja.txt"
        write_lines(hypothesis, hypotheses)
        references = [item["reference"] for item in aligned]
        first = Counter(item["verdict"] for item in validation["verdicts"])
        retried = Counter(item["verdict"] for item in retry["retryVerdicts"])
        terminal_hard = retried.get("hard-failure", 0)
        terminal_suspect = retried.get("suspect", 0)
        retry_runtime = sum(item["duration"] for item in retry_evidence["attempts"]) \
            if retry_evidence else 0
        direct_row = direct_rows[(split, "direct-protocol")]
        existing_row = direct_rows[(split, "existing-protocol")]
        candidate_comet = comet(metrics / "comet-score.json", hypothesis)
        candidate_chrf = chrf_pp(" ".join(hypotheses), " ".join(references))
        total_runtime = direct_row["runtimeSeconds"] + retry_runtime
        rows.append({
            "split": split,
            "units": len(turns),
            "retries": len(retry["rejectedCueIDs"]),
            "retryRate": len(retry["rejectedCueIDs"]) / len(turns),
            "firstPass": dict(first),
            "terminalHardFailures": terminal_hard,
            "terminalSuspects": terminal_suspect,
            "COMET": candidate_comet,
            "chrFPlusPlus": candidate_chrf,
            "directCOMET": direct_row["COMET"],
            "existingCOMET": existing_row["COMET"],
            "runtimeSeconds": total_runtime,
            "addedRuntimeSeconds": retry_runtime,
            "peakMemoryBytes": max(
                direct.get("peakMemoryBytes", 0),
                retry_evidence.get("peakMemoryBytes", 0) if retry_evidence else 0,
            ),
            "rawArtifacts": [relative(direct_path), relative(verdict_path), relative(retry_path)],
            "sourceFile": relative(source),
            "referenceFile": relative(reference),
            "hypothesisFile": relative(hypothesis),
        })

    live_log = args.root / "live-tests.log"
    gates = {}
    for row in rows:
        gates[row["split"]] = {
            "zeroHardIntegrityFailuresAfterRetry": row["terminalHardFailures"] == 0,
            "holdoutGainRetained": row["COMET"] is not None
                and row["existingCOMET"] is not None
                and row["COMET"] > row["existingCOMET"],
            "acceptableAddedRuntime": row["addedRuntimeSeconds"]
                <= max(row["runtimeSeconds"] - row["addedRuntimeSeconds"], 1) * 0.10,
        }
    report = {
        "schemaVersion": 1,
        "model": direct_report["model"],
        "revision": direct_report["revision"],
        "rows": rows,
        "gates": gates,
        "liveGatesUnchanged": live_log.exists() and "failed" not in live_log.read_text().lower(),
        "liveTestLog": relative(live_log),
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    lines = [
        "# E11 — Selective translation retry", "",
        "Ticket #52 retries only units rejected by the frozen E10 validator. Attempt B removes neighbours, metadata, aliases, and non-critical terms.", "",
        "| Split | Units | Retries | Retry rate | Terminal hard | Terminal suspect | COMET | chrF++ | Runtime | Added runtime | Peak memory |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        score = "pending" if row["COMET"] is None else f'{row["COMET"]:.4f}'
        lines.append(
            f'| {row["split"]} | {row["units"]} | {row["retries"]} | '
            f'{row["retryRate"]:.2%} | {row["terminalHardFailures"]} | '
            f'{row["terminalSuspects"]} | {score} | {row["chrFPlusPlus"]:.2f} | '
            f'{row["runtimeSeconds"]:.1f} s | {row["addedRuntimeSeconds"]:.1f} s | '
            f'{row["peakMemoryBytes"] / 1_073_741_824:.2f} GiB |'
        )
    lines += ["", "## Raw artifacts", ""]
    for row in rows:
        lines += [f'- `{path}`' for path in row["rawArtifacts"]]
    passed = rows and all(all(values.values()) for values in gates.values()) \
        and report["liveGatesUnchanged"]
    lines += ["", "Promotion gates pass." if passed else "Promotion remains blocked by a failed or pending gate."]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
