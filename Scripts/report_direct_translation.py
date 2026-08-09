#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path

from report_high_quality_acceptance import translation_rows
from report_japanese_l7d import chrf_pp

CORPORA = {
    "development": "qudu2fx3ncc",
    "holdout": "md62mmdz0m",
}
JAPANESE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uff66-\uff9f]")
SCAFFOLD = re.compile(
    r"SPEAKER_ID:|CONTEXT_(?:BEFORE|AFTER):|<<<(?:END_)?CURRENT:|```|"
    r"^(?:here(?: is|'s) the translation|(?:english )?translation):?",
    re.IGNORECASE,
)


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def display_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return str(path)


def write_lines(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(value.replace("\n", " ") for value in values) + "\n")


def comet_scores(path: Path, hypothesis: Path) -> list[float] | None:
    if not path.exists():
        return None
    data = read(path)
    rows = next((value for key, value in data.items() if Path(key).name == hypothesis.name), None)
    return [float(row["COMET"]) for row in rows] if rows else None


def cue_integrity(translation: dict) -> bool:
    expected = [turn["id"] for turn in translation["request"]["turns"]]
    observed = [item["id"] for item in json.loads(translation["response"])["translations"]]
    return observed == expected and len(observed) == len(set(observed))


def direct_prompt_integrity(translation: dict) -> bool:
    turns = {turn["id"]: turn for turn in translation["request"]["turns"]}
    if len(translation["batches"]) != len(turns):
        return False
    for batch in translation["batches"]:
        if len(batch["cueIDs"]) != 1:
            return False
        turn = turns.get(batch["cueIDs"][0])
        try:
            messages = json.loads(batch["nativePrompt"])
            content = messages[0]["content"]
        except (KeyError, TypeError, json.JSONDecodeError):
            return False
        if (turn is None or len(messages) != 1 or messages[0]["role"] != "user"
                or len(content) != 1 or content[0] != {
                    "type": "text", "source_lang_code": "ja",
                    "target_lang_code": "en", "text": turn["japanese"],
                }
                or batch["sanitizedPrompt"] != turn["japanese"]
                or batch.get("model") != translation["model"]
                or batch.get("revision") != translation["revision"]
                or batch.get("duration") is None):
            return False
    return True


def marker_misses(translation: dict) -> int:
    misses = 0
    for batch in translation["batches"]:
        cue = batch["cueIDs"][0]
        output = batch.get("nativeOutput") or ""
        misses += not (output.count(f"<<<CURRENT:{cue}>>>") == 1
                       and output.count(f"<<<END_CURRENT:{cue}>>>") == 1)
    return misses


def contamination_count(translation: dict) -> int:
    turns = {turn["id"]: turn for turn in translation["request"]["turns"]}
    outputs_by_source = {}
    for batch in translation["batches"]:
        source = turns[batch["cueIDs"][0]]["japanese"]
        outputs_by_source.setdefault(source, []).append(batch["sanitizedOutput"])
    count = 0
    for batch in translation["batches"]:
        output = batch["sanitizedOutput"]
        turn = turns[batch["cueIDs"][0]]
        neighbours = turn["precedingJapanese"] + turn["followingJapanese"]
        translated_neighbours = [
            (source, candidate)
            for source in neighbours
            for candidate in outputs_by_source.get(source, [])
            if source != turn["japanese"] and candidate
        ]
        current_characters = set(JAPANESE.findall(turn["japanese"]))
        count += bool(
            SCAFFOLD.search(output)
            or any(text and text in output for text in neighbours)
            or any(
                candidate in output
                and (candidate != output or current_characters.isdisjoint(JAPANESE.findall(source)))
                for source, candidate in translated_neighbours
            )
        )
    return count


def protocol_row(name: str, translation: dict, rows: list[dict], metrics: Path) -> dict:
    hypothesis = metrics / f"{name}.en.txt"
    write_lines(hypothesis, [row["hypothesis"] for row in rows])
    comet = comet_scores(metrics / "comet-score.json", hypothesis)
    return {
        "protocol": name,
        "units": len(translation["request"]["turns"]),
        "COMET": sum(comet) / len(comet) if comet else None,
        "chrFPlusPlus": chrf_pp(
            " ".join(row["hypothesis"] for row in rows),
            " ".join(row["reference"] for row in rows),
        ),
        "cueIntegrity": cue_integrity(translation),
        "markerMisses": marker_misses(translation) if name == "existing-protocol" else None,
        "scaffoldingOrContextContamination": contamination_count(translation),
        "untranslated": sum(bool(JAPANESE.search(row["hypothesis"])) for row in rows),
        "runtimeSeconds": sum(item["duration"] for item in translation["attempts"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("development_baseline", type=Path)
    parser.add_argument("holdout_baseline", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    rows = []
    freezes = []
    for split, corpus in CORPORA.items():
        direct_path = args.root / split / "direct-protocol.json"
        if not direct_path.exists():
            continue
        baseline_path = args.development_baseline if split == "development" else args.holdout_baseline
        baseline_raw = read(baseline_path)
        baseline = baseline_raw["translation"]
        direct = read(direct_path)
        manifest = read(Path("docs/japanese-live/corpora") / corpus / "manifest.json")
        baseline_rows = translation_rows(manifest, baseline_raw)
        direct_rows = translation_rows(manifest, {"translation": direct})
        metrics = args.root / "metrics" / split
        write_lines(metrics / "source.ja.txt", [row["source"] for row in baseline_rows])
        write_lines(metrics / "reference.en.txt", [row["reference"] for row in baseline_rows])
        existing = protocol_row("existing-protocol", baseline, baseline_rows, metrics)
        candidate = protocol_row("direct-protocol", direct, direct_rows, metrics)
        existing["rawArtifact"] = display_path(baseline_path)
        candidate["rawArtifact"] = display_path(direct_path)
        rows += [{"corpus": corpus, "split": split, **existing},
                 {"corpus": corpus, "split": split, **candidate}]
        freezes.append({
            "split": split,
            "requestUnchanged": direct["request"] == baseline["request"],
            "modelUnchanged": direct["model"] == baseline["model"],
            "revisionUnchanged": direct["revision"] == baseline["revision"],
            "directPromptIntegrity": direct_prompt_integrity(direct),
        })

    by_split = {(row["split"], row["protocol"]): row for row in rows}
    gates = {}
    for split in {row["split"] for row in rows}:
        existing = by_split[(split, "existing-protocol")]
        direct = by_split[(split, "direct-protocol")]
        frozen = next(item for item in freezes if item["split"] == split)
        gates[split] = {
            "frozenInputs": all(value for key, value in frozen.items() if key != "split"),
            "cueIntegrity": direct["cueIntegrity"],
            "noContamination": direct["scaffoldingOrContextContamination"] == 0,
            "noUntranslated": direct["untranslated"] == 0,
            "qualityGain": (direct["COMET"] is not None and existing["COMET"] is not None
                and direct["COMET"] > existing["COMET"])
                or direct["chrFPlusPlus"] > existing["chrFPlusPlus"],
            "noCOMETRegression": direct["COMET"] is not None and existing["COMET"] is not None
                and direct["COMET"] >= existing["COMET"],
        }
    report = {
        "model": "mlx-community/translategemma-12b-it-4bit",
        "revision": "f3dcfd54df14672fbcf0731086fb47a797a943ae",
        "generation": {"maxTokens": 256, "temperature": 0, "thinking": False},
        "rows": rows,
        "freezes": freezes,
        "gates": gates,
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    lines = [
        "# E09 — Official direct TranslateGemma interaction", "",
        "Ticket #50 changes only the prompt protocol. Semantic units, model revision, glossary state, generation settings, references, and scorers are frozen from E08.", "",
        "TranslateGemma stays pinned to revision `f3dcfd54df14672fbcf0731086fb47a797a943ae` with 256 output tokens, temperature 0, and thinking disabled.", "",
    ]
    for split in ("development", "holdout"):
        selected = [row for row in rows if row["split"] == split]
        if not selected:
            continue
        lines += [f"## {split.title()}", "",
            "| Protocol | Units | COMET | chrF++ | Marker misses | Marker/context contamination | Untranslated | Runtime |",
            "|---|---:|---:|---:|---:|---:|---:|---:|"]
        for row in selected:
            comet = "pending" if row["COMET"] is None else f'{row["COMET"]:.4f}'
            markers = "n/a" if row["markerMisses"] is None else str(row["markerMisses"])
            lines.append(
                f'| {row["protocol"]} | {row["units"]} | {comet} | {row["chrFPlusPlus"]:.2f} | '
                f'{markers} | {row["scaffoldingOrContextContamination"]} | {row["untranslated"]} | '
                f'{row["runtimeSeconds"]:.1f} s |'
            )
        direct = next(row for row in selected if row["protocol"] == "direct-protocol")
        lines += ["", f'Raw direct artifact: `{direct["rawArtifact"]}` (native prompts, tokens, outputs, timings, and model identity per unit).', ""]
    if "holdout" in gates and all(gates["holdout"].values()):
        lines.append("The untouched holdout promotion gates pass; Live behavior remains covered by the unchanged full test suite.")
    else:
        lines.append("Promotion remains pending until every holdout gate and the unchanged Live suite pass.")
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.markdown.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
