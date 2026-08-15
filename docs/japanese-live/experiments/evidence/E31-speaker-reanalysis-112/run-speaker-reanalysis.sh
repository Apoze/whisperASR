#!/bin/zsh
set -euo pipefail

if [[ "${BENCHMARK_SLOT_GRANTED:-}" != "112-FINAL" ]]; then
  print -u2 "Set BENCHMARK_SLOT_GRANTED=112-FINAL only during the granted final replay slot."
  exit 2
fi
if [[ $# -ne 1 || ! -f "$1" ]]; then
  print -u2 "usage: BENCHMARK_SLOT_GRANTED=112-FINAL $0 /path/to/Video1.webm"
  exit 2
fi

script_dir="${0:A:h}"
repository="$(git -C "$script_dir" rev-parse --show-toplevel)"
source_video="${1:A}"
frozen="$repository/docs/japanese-live/experiments/evidence/E31-full-12b-only-warning-attempt/video1/raw-asr.json.gz"
test_name="HighQualityAcceptanceTests/testRealSavedSpeakerReanalysisWhenOptedIn"
expected_source="b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1"
expected_gzip="bd0c6dcac367851d5ff13057b424fdff3bdde3b27077117fa2b4c7e6b1ec9a1a"
expected_raw="95b5089cf630f717cabf4c4c545673c46fa6bd62d74d2722e7930f084b6d48c5"
tracked_files=(
  Sources/HighQualityJob.swift
  Sources/HighQualityJobView.swift
  Sources/HighQualitySpeakerKitRuntime.swift
  Sources/HighQualityAlignmentSpeakerWorker.swift
  Tests/HighQualityAcceptanceTests.swift
  Tests/HighQualityJobTests.swift
  Package.swift
  Package.resolved
  docs/japanese-live/experiments/evidence/E31-speaker-reanalysis-112/run-speaker-reanalysis.sh
)

[[ "$(shasum -a 256 "$source_video" | awk '{print $1}')" == "$expected_source" ]]
[[ "$(shasum -a 256 "$frozen" | awk '{print $1}')" == "$expected_gzip" ]]
gzip -t "$frozen"
git -C "$repository" diff --quiet HEAD -- "${tracked_files[@]}"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_directory="${WHISPERASR_SPEAKER_REANALYSIS_ARCHIVE:-$script_dir/replays/$stamp}"
[[ ! -e "$run_directory" ]]
mkdir -p "$run_directory/jobs" "$repository/.build/clang-cache-ticket-112"
raw_evidence="$run_directory/e31-raw-asr.json"
gzip -dc "$frozen" > "$raw_evidence"
[[ "$(shasum -a 256 "$raw_evidence" | awk '{print $1}')" == "$expected_raw" ]]

{
  print -r -- "execution_commit=$(git -C "$repository" rev-parse HEAD)"
  print -r -- "test=$test_name"
  print -r -- "slot=BENCHMARK_SLOT_GRANTED=112-FINAL"
  print -r -- "source=$source_video"
  print -r -- "source_sha256=$expected_source"
  print -r -- "frozen_gzip_sha256=$expected_gzip"
  print -r -- "frozen_raw_sha256=$expected_raw"
  print -r -- "tracked_sources_match_execution_commit=true"
  print -r -- "raw_historical_relabelled=false"
  for tracked_file in "${tracked_files[@]}"; do
    shasum -a 256 "$repository/$tracked_file"
  done
} > "$run_directory/provenance.txt"

(
  cd "$repository"
  /usr/bin/time -lp env \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    CLANG_MODULE_CACHE_PATH="$repository/.build/clang-cache-ticket-112" \
    WHISPERASR_RUN_SPEAKER_REANALYSIS=1 \
    WHISPERASR_SPEAKER_REANALYSIS_EVIDENCE="$raw_evidence" \
    WHISPERASR_SPEAKER_REANALYSIS_SOURCE="$source_video" \
    WHISPERASR_SPEAKER_REANALYSIS_OUTPUT="$run_directory/jobs" \
    WHISPERASR_SPEAKER_REANALYSIS_JOB_ID=11211211-1121-4112-8112-112112112112 \
    WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$repository/.build/debug/WhisperASR" \
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
    test --disable-sandbox --filter "$test_name"
) 2>&1 | tee "$run_directory/run.log"

(
  cd "$run_directory"
  find . -type f ! -name sha256.tsv | sort | while IFS= read -r artifact_name; do
    shasum -a 256 "$artifact_name"
  done
) > "$run_directory/sha256.tsv"
