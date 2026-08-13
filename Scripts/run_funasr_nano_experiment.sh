#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/issue-88"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
MANIFEST="$ROOT/docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
MODEL="$ROOT/.build/models/sherpa-onnx-funasr-nano-int8-2025-12-30"
RUNTIME="$ROOT/.build/runtimes/funasr-nano-int8/bin/python3"
MODE="${1:-preflight}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in preflight|prepare|smoke) ;;
  *) echo "usage: $0 [preflight|prepare|smoke]" >&2; exit 2 ;;
esac
if [[ "$MODE" != preflight && "${BENCHMARK_SLOT_GRANTED:-}" != 88 ]]; then
  echo "Refusing #88 runtime/model/smoke without BENCHMARK_SLOT_GRANTED=88." >&2
  exit 77
fi
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls"

expected_hash() {
  jq -er --arg label "$1" '.source.references[] | select(.label == $label) | .sha256' "$MANIFEST"
}

resolve_external() {
  local label="$1" expected file
  expected="$(expected_hash "$label")"
  while IFS= read -r file; do
    if [[ "$(shasum -a 256 "$file" | awk '{print $1}')" == "$expected" ]]; then
      printf '%s\n' "$file"
      return
    fi
  done < <(find "$VIDEO_ROOT/1" -maxdepth 1 -type f -print | sort)
  echo "No DEV $label matches $expected" >&2
  return 1
}

verify_file() {
  local path="$1" expected="$2"
  [[ -f "$path" ]] || { echo "Missing cache/input: $path" >&2; return 1; }
  [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected" ]] || {
    echo "Hash mismatch: $path" >&2
    return 1
  }
  printf '%s\t%s\n' "$expected" "$path"
}

resolve_local_reference() {
  local locator="$1" expected="$2" path
  for path in "$ROOT/$locator" "/Users/maz/Documents/projets/whisperASR/$locator"; do
    if [[ -f "$path" && "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected" ]]; then
      printf '%s\n' "$path"
      return
    fi
  done
  echo "No frozen local reference matches $expected for $locator" >&2
  return 1
}

preflight() {
  for tool in bash curl ffmpeg jq python3 shasum swift xcrun; do command -v "$tool" >/dev/null; done
  [[ "$(uname -m)" == arm64 ]]
  [[ "$(python3 -c 'import platform; print(platform.python_version_tuple()[0]+platform.python_version_tuple()[1])')" == 314 ]]
  bash -n Scripts/prepare_funasr_nano_int8.sh Scripts/run_funasr_nano_experiment.sh
  python3 Sources/Runtime/FunASRNanoWorker.py --self-test
  xcrun swift build 2>&1 | tee "$ARTIFACTS/controls/build.log"
  bash Scripts/build_mlx_metallib.sh debug \
    2>&1 | tee "$ARTIFACTS/controls/mlx-metallib.log"
  xcrun swift test --skip-build \
    --filter 'HighQualityASRWorkerTests|HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts' \
    2>&1 | tee "$ARTIFACTS/controls/tests.log"

  source="$(resolve_external source-video)"
  archive="$(resolve_external reference-archive)"
  verify_file "$source" "$(expected_hash source-video)" >"$ARTIFACTS/controls/input.tsv"
  verify_file "$archive" "$(expected_hash reference-archive)" >>"$ARTIFACTS/controls/input.tsv"
  while IFS=$'\t' read -r expected locator; do
    verify_file "$(resolve_local_reference "$locator" "$expected")" "$expected" \
      >>"$ARTIFACTS/controls/reference.tsv"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | [.sha256,.locator] | @tsv' "$MANIFEST")

  verify_file "/Users/maz/.cache/huggingface/hub/models--mlx-community--Qwen3-ForcedAligner-0.6B-4bit/snapshots/2f652af86ae0c73fe189b9429225c908ce4bf020/model.safetensors" \
    630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c >"$ARTIFACTS/controls/fixed-cache.tsv"
  speaker="/Users/maz/Documents/huggingface/models/argmaxinc/speakerkit-coreml"
  verify_file "$speaker/speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/weights/weight.bin" \
    75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4 >>"$ARTIFACTS/controls/fixed-cache.tsv"
  verify_file "$speaker/speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/weights/weight.bin" \
    a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795 >>"$ARTIFACTS/controls/fixed-cache.tsv"
  translator="/Users/maz/.cache/huggingface/hub/models--mlx-community--translategemma-12b-it-4bit/snapshots/f3dcfd54df14672fbcf0731086fb47a797a943ae"
  verify_file "$translator/model-00001-of-00002.safetensors" \
    bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af >>"$ARTIFACTS/controls/fixed-cache.tsv"
  verify_file "$translator/model-00002-of-00002.safetensors" \
    c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89 >>"$ARTIFACTS/controls/fixed-cache.tsv"

  jq -n --arg commit "$(git rev-parse HEAD)" \
    '{ticket:88,status:"READY_FOR_HEAVY_BENCHMARK",commit:$commit,holdoutOpened:false,
      heavyRunsLaunched:0,command:"BENCHMARK_SLOT_GRANTED=88 bash Scripts/run_funasr_nano_experiment.sh prepare",
      next:"prepare exact runtime and weights, then smoke; this runner never starts DEV"}' \
    >"$ARTIFACTS/benchmark-ready.json"
  echo "READY_FOR_HEAVY_BENCHMARK #88"
}

prepare() {
  BENCHMARK_SLOT_GRANTED=88 bash Scripts/prepare_funasr_nano_int8.sh \
    2>&1 | tee "$ARTIFACTS/controls/prepare.log"
}

smoke() {
  [[ -x "$RUNTIME" && -f "$MODEL/provenance.json" ]] || {
    echo "Run the authorized prepare step first." >&2; exit 1;
  }
  fixture="$ARTIFACTS/smoke/dev-30s.wav"
  mkdir -p "$(dirname "$fixture")"
  ffmpeg -hide_banner -loglevel error -y -i "$(resolve_external source-video)" \
    -t 30 -vn -ac 1 -ar 16000 -c:a pcm_s16le "$fixture"
  digest="$(shasum -a 256 "$fixture" | awk '{print $1}')"
  BENCHMARK_SLOT_GRANTED=88 WHISPERASR_ASR_WORKER_SLOT=88 \
  WHISPERASR_RUN_ASR_WORKER_SMOKE=1 WHISPERASR_ASR_WORKER_BACKEND=funasr-nano-int8 \
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE="$fixture" \
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256="$digest" \
  WHISPERASR_FUNASR_PYTHON="$RUNTIME" WHISPERASR_FUNASR_MODEL_DIR="$MODEL" \
  WHISPERASR_FUNASR_PREPARE_TIMEOUT_SECONDS=300 \
  WHISPERASR_FUNASR_REQUEST_TIMEOUT_SECONDS=180 \
    xcrun swift test --skip-build \
      --filter HighQualityASRWorkerTests/testRealBackendCompletesFrozenJapaneseJobWhenOptedIn \
      2>&1 | tee "$ARTIFACTS/smoke/run.log"
  grep -q '\[issue-88\]\[smoke\] transcriptSHA256=' "$ARTIFACTS/smoke/run.log"
}

"$MODE"
