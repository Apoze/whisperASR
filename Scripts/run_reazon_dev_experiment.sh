#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-preflight}"
REVISION=291488c8151be24d7da4bf7af26e533fad96e407
ARTIFACTS="$ROOT/.build/benchmarks/reazonspeech-k2-v2-89"
MODEL_ROOT="$ARTIFACTS/model-$REVISION"
VENV="$ARTIFACTS/sherpa-onnx-1.13.4"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/ReazonK2V2"
SOURCE="${WHISPERASR_REAZON_DEV_SOURCE:-/Users/maz/Documents/videos/jap/1/Video1.webm}"
ARCHIVE="${WHISPERASR_REAZON_DEV_REFERENCE_ARCHIVE:-/Users/maz/Documents/videos/jap/1/Video1_reference_transcript_and_translation.zip}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
JOB_ID=89000001-0000-4000-8000-000000000003
JOB_ROOT="$ARTIFACTS/development/jobs"
JOB="$JOB_ROOT/$JOB_ID"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/whisperasr-89-clang-cache}"

case "$MODE" in
  preflight|prepare|smoke|development|report) ;;
  *) echo "usage: $0 [preflight|prepare|smoke|development|report]" >&2; exit 2 ;;
esac
[[ "$MODE" == preflight || "$MODE" == report || "${BENCHMARK_SLOT_GRANTED:-}" == 89 ]] || {
  echo "Refusing #89 download or benchmark without BENCHMARK_SLOT_GRANTED=89" >&2
  exit 2
}
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls"

hash() { shasum -a 256 "$1" | awk '{print $1}'; }
assert_hash() {
  local path="$1" expected="$2"
  [[ -f "$path" ]] || { echo "Missing input: $path" >&2; return 1; }
  [[ "$(hash "$path")" == "$expected" ]] || {
    echo "Hash mismatch: $path" >&2
    return 1
  }
}

prepare_local_references() {
  local locator source destination
  while IFS= read -r locator; do
    destination="$ROOT/$locator"
    [[ -f "$destination" ]] && continue
    source="$FROZEN_REPO/$locator"
    [[ -f "$source" ]] || { echo "Missing frozen reference: $source" >&2; return 1; }
    mkdir -p "$(dirname "$destination")"
    ln -s "$source" "$destination"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | .locator' \
    docs/japanese-live/corpora/qudu2fx3ncc/manifest.json)
}

verify_inputs() {
  [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]
  assert_hash "$SOURCE" b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1
  assert_hash "$ARCHIVE" 8f1c4ed3836d5e0f627448f9ecc44ab064d8750cb4464c8849eafabbba401474
  assert_hash docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz \
    1f5edc2fcb929c9abc2cb85256f326bbf2891a200ef66d1c1cb9a66a9c711ce8
  assert_hash docs/japanese-live/experiments/evidence/E23/segments.json \
    e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81
  prepare_local_references
  while IFS=$'\t' read -r expected locator; do
    assert_hash "$ROOT/$locator" "$expected"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | [.sha256,.locator] | @tsv' \
    docs/japanese-live/corpora/qudu2fx3ncc/manifest.json)
}

verify_assets() {
  assert_hash "$MODEL_ROOT/encoder-epoch-99-avg-1.int8.onnx" \
    2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d
  assert_hash "$MODEL_ROOT/decoder-epoch-99-avg-1.onnx" \
    58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124
  assert_hash "$MODEL_ROOT/joiner-epoch-99-avg-1.int8.onnx" \
    49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de
  assert_hash "$MODEL_ROOT/tokens.txt" \
    2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def
  [[ "$($VENV/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("sherpa-onnx"))')" == 1.13.4 ]]
  [[ "$($VENV/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("numpy"))')" == 1.26.4 ]]
}

download_asset() {
  local name="$1" expected="$2" url
  url="https://huggingface.co/reazon-research/reazonspeech-k2-v2/resolve/$REVISION/$name"
  if [[ -f "$MODEL_ROOT/$name" ]] && [[ "$(hash "$MODEL_ROOT/$name")" == "$expected" ]]; then return; fi
  curl --fail --location --retry 3 --output "$MODEL_ROOT/$name.partial" "$url"
  [[ "$(hash "$MODEL_ROOT/$name.partial")" == "$expected" ]] || {
    echo "Downloaded asset hash mismatch: $name" >&2
    return 1
  }
  mv "$MODEL_ROOT/$name.partial" "$MODEL_ROOT/$name"
}

worker_environment() {
  export WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$ROOT/.build/debug/WhisperASR"
  export WHISPERASR_REAZON_WORKER_PYTHON="$VENV/bin/python"
  export WHISPERASR_REAZON_WORKER_SCRIPT="$ROOT/Scripts/reazon_asr_worker.py"
  export WHISPERASR_REAZON_MODEL_ROOT="$MODEL_ROOT"
}

run_preflight() {
  verify_inputs
  /Users/maz/.local/bin/python3.12 Scripts/reazon_asr_worker.py --self-test
  /Users/maz/.local/bin/python3.12 Scripts/report_reazon_dev.py --self-test
  xcrun swift test --filter \
    'HighQualityJobTests/testChunkedASR|HighQualityASRWorkerTests/testEveryBackendRoundTripsOneTranscriptAndExits|HighQualityASRWorkerTests/testWeightEvidenceHashesOnlyModelWeights|HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
}

run_prepare() {
  verify_inputs
  mkdir -p "$MODEL_ROOT"
  [[ -x "$VENV/bin/python" ]] || /Users/maz/.local/bin/python3.12 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --disable-pip-version-check \
    "sherpa-onnx==1.13.4" "numpy==1.26.4"
  download_asset encoder-epoch-99-avg-1.int8.onnx \
    2c7bd08a8a99f9ddd0d9e458456577b1f6279214e51426f114f9eced44c54e1d
  download_asset decoder-epoch-99-avg-1.onnx \
    58b18211ae06265466bfa17172dab574df94f76c8bcb61a3640c28ba860e4124
  download_asset joiner-epoch-99-avg-1.int8.onnx \
    49cc7ea1d3d35a40a27442db5e89996da64bf0e683a903dce76e99e57a12e4de
  download_asset tokens.txt \
    2c3ac659818a48a0c04010e0593bbc4d7c8a24a054340b01131499c05fd52def
  verify_assets
}

run_smoke() {
  verify_inputs
  verify_assets
  [[ -f .build/debug/mlx.metallib ]] || bash Scripts/build_mlx_metallib.sh debug
  worker_environment
  local fixture="$ARTIFACTS/smoke-20s.wav" digest
  ffmpeg -hide_banner -loglevel error -y -i "$SOURCE" -t 20 -vn -ac 1 -ar 16000 \
    -c:a pcm_s16le "$fixture"
  digest="$(hash "$fixture")"
  BENCHMARK_SLOT_GRANTED=89 WHISPERASR_RUN_REAZON_SMOKE=1 \
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE="$fixture" \
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256="$digest" \
  WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$ARTIFACTS/smoke/jobs" \
    xcrun swift test --skip-build \
      --filter HighQualityASRWorkerTests/testRealReazonWorkerCompletesTimestampedSmokeWhenOptedIn \
      2>&1 | tee "$ARTIFACTS/smoke.log"
}

retain_development_evidence() {
  mkdir -p "$EVIDENCE"
  [[ -f "$JOB/manifest.json" ]] && cp "$JOB/manifest.json" "$EVIDENCE/development-manifest.json"
  [[ -f "$JOB/raw-asr.json" ]] && gzip -c "$JOB/raw-asr.json" >"$EVIDENCE/development-raw-asr.json.gz"
  [[ -f "$ARTIFACTS/development/run.log" ]] && gzip -c "$ARTIFACTS/development/run.log" >"$EVIDENCE/development-run.log.gz"
}

run_report() {
  retain_development_evidence
  /Users/maz/.local/bin/python3.12 Scripts/report_reazon_dev.py \
    --manifest "$JOB/manifest.json" --raw "$JOB/raw-asr.json" \
    --json "$EVIDENCE/report.json" \
    --markdown docs/japanese-live/experiments/E24-reazonspeech-k2-v2-dev.md
}

run_development() {
  verify_inputs
  verify_assets
  [[ -f .build/debug/mlx.metallib ]] || bash Scripts/build_mlx_metallib.sh debug
  worker_environment
  [[ ! -e "$JOB" ]] || {
    echo "Existing DEV job retained at $JOB; report it or move it aside before a rerun." >&2
    return 1
  }
  mkdir -p "$JOB_ROOT"
  if ! BENCHMARK_SLOT_GRANTED=89 WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE=1 \
    WHISPERASR_ACCEPTANCE_BACKEND=reazonspeech-k2-v2-int8 \
    WHISPERASR_ACCEPTANCE_CORPUS=qudu2fx3ncc \
    WHISPERASR_ACCEPTANCE_SOURCE="$SOURCE" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$ARCHIVE" \
    WHISPERASR_ACCEPTANCE_JOB_ID="$JOB_ID" \
    WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$JOB_ROOT" \
    WHISPERASR_ACCEPTANCE_TRANSLATION_CONTEXT=product-default \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn \
        2>&1 | tee "$ARTIFACTS/development/run.log"; then
    retain_development_evidence
    echo "Candidate run failed; raw evidence retained. Re-run preflight before attribution." >&2
    return 1
  fi
  run_report
}

case "$MODE" in
  preflight) run_preflight ;;
  prepare) run_prepare ;;
  smoke) run_smoke ;;
  development) run_development ;;
  report) run_report ;;
esac
