#!/usr/bin/env python3
"""Prepare the two pinned long-form Japanese benchmark corpora."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import wave
import zipfile
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path


SAMPLE_RATE = 16_000
SPECS = {
    "qudu2fx3ncc": {
        "token": "QUdu2fx3NCc",
        "archive": "1/QUdu2fx3NCc_reference_transcript_and_translation.zip",
        "reference": "1/QUdu2fx3NCc_reference_transcript_and_translation/QUdu2fx3NCc_bilingual_reference.csv",
        "alignment": "1/QUdu2fx3NCc_reference_transcript_and_translation/QUdu2fx3NCc_japanese_character_alignment.jsonl",
        "speaker_map": "1/QUdu2fx3NCc_reference_transcript_and_translation/speaker_map.json",
        "video_sha256": "b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1",
        "archive_sha256": "8f1c4ed3836d5e0f627448f9ecc44ab064d8750cb4464c8849eafabbba401474",
        "reference_sha256": "df0bce85845cca243e0ed4ae3c5b885e519cc4f0aada9c6ddb1b169cb22f93ba",
        "alignment_sha256": "abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7",
        "speaker_map_sha256": "4e1326ac13fab5c76b07451600e6553c65e824b278a1b4c4ce7192e77a73497b",
    },
    "md62mmdz0m": {
        "token": "_mD62MMDz0M",
        "archive": "2/mD62MMDz0M_final_readable_transcript_pack.zip",
        "reference": "2/mD62MMDz0M_final_readable_transcript_pack/mD62MMDz0M_reference.jsonl",
        "alignment": "2/mD62MMDz0M_final_readable_transcript_pack/mD62MMDz0M_japanese_character_alignment.tsv",
        "video_sha256": "a0f913830f4a9994ce366414f4f9abc6cf0e25f64ac15f4d9037c1673e68798d",
        "archive_sha256": "a95e73422dd0b8628f6d8a5cb064e41deb4a64b5a0024e1e1a5a62450e5aff86",
        "reference_sha256": "c1f08461fb393d40cc3e82dc22c3f3befd066b3dd091b6522547228db86996df",
        "alignment_sha256": "446e7a00ad003b904e3de90786ef65f1829cc063217638535b134c084f2db925",
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_sha(path: Path, expected: str) -> None:
    if not path.is_file():
        raise SystemExit(f"Missing input: {path}")
    actual = sha256(path)
    if actual != expected:
        raise SystemExit(f"SHA-256 mismatch for {path}\nexpected: {expected}\nactual:   {actual}")


def sample_index(seconds: str | float) -> int:
    return int(Decimal(str(seconds)) * SAMPLE_RATE)


def video_for(source_root: Path, token: str) -> Path:
    matches = [path for path in source_root.rglob("*.webm") if token in path.name]
    if len(matches) != 1:
        raise SystemExit(f"Expected one video containing {token}, found {len(matches)}")
    return matches[0]


def mark_overlaps(rows: list[dict]) -> None:
    for index, row in enumerate(rows):
        row["overlap"] = row["speech"] and (
            row["speaker"] == "SPEAKER_13" or any(
                other["speech"]
                and row["startSample"] < other["endSample"]
                and other["startSample"] < row["endSample"]
                for other_index, other in enumerate(rows)
                if other_index != index
            )
        )


def qudu_rows(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        source = list(csv.DictReader(handle))
    rows = []
    for item in source:
        speech = item["speaker_id"] != "SPEAKER_NONE"
        rows.append({
            "id": int(item["cue_id"]),
            "speaker": item["speaker_id"],
            "startSample": sample_index(item["start"]),
            "endSample": sample_index(item["end"]),
            "japanese": item["japanese"],
            "english": item["english"],
            "confidence": item["confidence"],
            "note": item["note"] or None,
            "speech": speech,
        })
    mark_overlaps(rows)
    return rows


def md_rows(path: Path) -> list[dict]:
    source = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    rows = []
    for item in source:
        speech = "non-speech vocalization" not in item["note"].lower()
        rows.append({
            "id": int(item["segment_id"].removeprefix("SEG_")),
            "speaker": item["speaker_id"],
            "startSample": sample_index(item["start_seconds"]),
            "endSample": sample_index(item["end_seconds"]),
            "japanese": item["japanese"],
            "english": item["english"],
            "confidence": item["confidence"],
            "note": item["note"] or None,
            "speech": speech,
        })
    mark_overlaps(rows)
    return rows


def extracted_file(root: Path, relative_name: str) -> Path:
    matches = [path for path in root.rglob(Path(relative_name).name) if path.is_file()]
    if len(matches) != 1:
        raise SystemExit(f"Expected one archived {Path(relative_name).name}, found {len(matches)}")
    return matches[0]


def install_references(
    archive: Path, spec: dict, target: Path, corpus_id: str
) -> tuple[list[dict], Path, Path, Path | None]:
    with tempfile.TemporaryDirectory(prefix=f".{corpus_id}-refs-", dir=target.parent) as temporary:
        extracted = Path(temporary)
        with zipfile.ZipFile(archive) as source:
            source.extractall(extracted)
        reference = extracted_file(extracted, spec["reference"])
        alignment = extracted_file(extracted, spec["alignment"])
        speaker_map = extracted_file(extracted, spec["speaker_map"]) if "speaker_map" in spec else None
        require_sha(reference, spec["reference_sha256"])
        require_sha(alignment, spec["alignment_sha256"])
        if speaker_map:
            require_sha(speaker_map, spec["speaker_map_sha256"])

        canonical_reference = target / f"reference{reference.suffix}"
        canonical_alignment = target / f"character-alignment{alignment.suffix}"
        shutil.copyfile(reference, canonical_reference)
        shutil.copyfile(alignment, canonical_alignment)
        canonical_speaker_map = None
        if speaker_map:
            canonical_speaker_map = target / "speaker-map.json"
            shutil.copyfile(speaker_map, canonical_speaker_map)
        rows = qudu_rows(reference) if corpus_id == "qudu2fx3ncc" else md_rows(reference)
    return rows, canonical_reference, canonical_alignment, canonical_speaker_map


def wav_info(path: Path) -> tuple[int, int, int, int]:
    with wave.open(str(path), "rb") as audio:
        return audio.getframerate(), audio.getnchannels(), audio.getsampwidth(), audio.getnframes()


def conversion_command(ffmpeg: str, video: Path, output: Path) -> list[str]:
    return [
        ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(video), "-map", "0:a:0", "-vn", "-sn", "-dn",
        "-af", "pan=mono|c0=0.5*c0+0.5*c1,aresample=16000:resampler=swr:dither_method=none",
        "-c:a", "pcm_s16le", "-fflags", "+bitexact", "-flags:a", "+bitexact",
        "-map_metadata", "-1", str(output),
    ]


def convert(ffmpeg: str, video: Path, output: Path) -> None:
    command = conversion_command(ffmpeg, video, output)
    subprocess.run(command, check=True)


def redacted_command(command: list[str]) -> list[str]:
    return [
        "ffmpeg", *command[1:command.index("-i") + 1], "<video>",
        *command[command.index("-map"): -1], "<wav>",
    ]


def git_evidence(workspace: Path) -> tuple[str, bool]:
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=workspace, check=True, text=True, capture_output=True
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "status", "--porcelain"], cwd=workspace, check=True, text=True, capture_output=True
    ).stdout.strip())
    return commit, dirty


def prepare_corpus(workspace: Path, source_root: Path, corpus_id: str, ffmpeg: str, rebuild: bool) -> None:
    spec = SPECS[corpus_id]
    video = video_for(source_root, spec["token"])
    archive = source_root / spec["archive"]
    for path, expected in [
        (video, spec["video_sha256"]),
        (archive, spec["archive_sha256"]),
    ]:
        require_sha(path, expected)

    target = workspace / ".build/benchmarks/japanese-live/corpora" / corpus_id
    target.mkdir(parents=True, exist_ok=True)
    wav = target / "audio-16k-mono.wav"
    wav_rebuilt = rebuild or not wav.is_file()
    if wav_rebuilt:
        with tempfile.TemporaryDirectory(prefix=f".{corpus_id}-", dir=target.parent) as temporary:
            staged = Path(temporary) / wav.name
            convert(ffmpeg, video, staged)
            os.replace(staged, wav)
    rate, channels, width, sample_count = wav_info(wav)
    if (rate, channels, width) != (SAMPLE_RATE, 1, 2):
        raise SystemExit(f"Unexpected WAV format for {corpus_id}: {(rate, channels, width)}")

    rows, canonical_reference, canonical_alignment, canonical_speaker_map = install_references(
        archive, spec, target, corpus_id
    )
    clamped_ends = 0
    for row in rows:
        if row["endSample"] > sample_count and row["endSample"] - sample_count <= SAMPLE_RATE // 50:
            row["endSample"] = sample_count
            clamped_ends += 1
    if not rows or max(item["endSample"] for item in rows) > sample_count:
        raise SystemExit(f"Reference ranges exceed the canonical WAV for {corpus_id}")
    turns = []
    for row in rows:
        if not row["speech"]:
            continue
        turns.append({
            "id": row["id"],
            "speaker": row["speaker"],
            "startSample": row["startSample"],
            "endSample": row["endSample"],
            "japanese": row["japanese"],
            "english": row["english"],
            "confidence": row["confidence"],
            "criticalTerms": [],
            "overlap": row["overlap"],
            "note": row["note"],
        })

    relative_target = target.relative_to(workspace).as_posix()
    references = [
        {"label": "source-video", "locator": f"urn:sha256:{spec['video_sha256']}", "sha256": spec["video_sha256"]},
        {"label": "reference-archive", "locator": f"urn:sha256:{spec['archive_sha256']}", "sha256": spec["archive_sha256"]},
        {"label": "bilingual-reference", "locator": f"{relative_target}/{canonical_reference.name}", "sha256": spec["reference_sha256"]},
        {"label": "character-alignment", "locator": f"{relative_target}/{canonical_alignment.name}", "sha256": spec["alignment_sha256"]},
    ]
    if canonical_speaker_map:
        references.append({
            "label": "speaker-map", "locator": f"{relative_target}/{canonical_speaker_map.name}",
            "sha256": spec["speaker_map_sha256"],
        })
    manifest = {
        "schemaVersion": 2,
        "corpusID": corpus_id,
        "purpose": "holdout-speaker-changes" if corpus_id == "qudu2fx3ncc" else "holdout-dialogue",
        "source": {
            "description": "Long-form Japanese video benchmark supplied for local development. High-confidence rows are primary; generated/interpolated timing remains explicitly qualified by the reference pack.",
            "references": references,
        },
        "fixture": {
            "channelCount": 1,
            "path": f"{relative_target}/{wav.name}",
            "sampleCount": sample_count,
            "sampleFormat": "pcm_s16le",
            "sampleRate": SAMPLE_RATE,
            "sha256": sha256(wav),
        },
        "annotations": {
            "status": "pending-human-review",
            "reviewedBy": [],
            "reviewNote": "User-supplied bilingual development benchmark. Primary high-confidence turns are accepted for exploratory bakeoff; parts originated from ASR/caption consolidation and character times are interpolated, so this is not represented as independent waveform sign-off. Critical terms remain empty until explicitly reviewed.",
            "turns": turns,
            "voiceChanges": [],
            "negativeRanges": [
                {"range": [row["startSample"], row["endSample"]], "reason": row["note"]}
                for row in rows if not row["speech"]
            ],
        },
    }
    manifest_path = workspace / "docs/japanese-live/corpora" / corpus_id / "manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    commit, dirty = git_evidence(workspace)
    version = subprocess.run([ffmpeg, "-version"], check=True, text=True, capture_output=True).stdout.splitlines()[0]
    report = {
        "schemaVersion": 1,
        "corpusID": corpus_id,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "gitCommit": commit,
        "worktreeDirty": dirty,
        "ffmpegVersion": version,
        "wavRebuilt": wav_rebuilt,
        "conversionCommand": redacted_command(conversion_command(ffmpeg, video, wav)),
        "manifestSHA256": sha256(manifest_path),
        "source": {
            "videoSHA256": spec["video_sha256"],
            "archiveSHA256": spec["archive_sha256"],
            "referenceSHA256": spec["reference_sha256"],
            "alignmentSHA256": spec["alignment_sha256"],
        },
        "fixture": manifest["fixture"],
        "annotations": {
            "sourceRows": len(rows),
            "speechTurns": len(turns),
            "high": sum(row["confidence"] == "high" for row in rows if row["speech"]),
            "medium": sum(row["confidence"] == "medium" for row in rows if row["speech"]),
            "low": sum(row["confidence"] == "low" for row in rows if row["speech"]),
            "overlapTurns": sum(row["overlap"] for row in rows if row["speech"]),
            "nonSpeechTurns": sum(not row["speech"] for row in rows),
            "referenceEndsClampedWithin20ms": clamped_ends,
        },
    }
    (target / "preparation.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"Prepared {corpus_id}: {len(turns)} speech turns, "
        f"{sample_count} samples, {manifest['fixture']['sha256']}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", nargs="?", default="/Users/maz/Documents/videos/jap")
    parser.add_argument("--rebuild", action="store_true")
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parent.parent
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required")
    for corpus_id in SPECS:
        prepare_corpus(workspace, Path(args.source_root).resolve(), corpus_id, ffmpeg, args.rebuild)


if __name__ == "__main__":
    main()
