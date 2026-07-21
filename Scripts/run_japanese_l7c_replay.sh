#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
SWIFT_STATE="$TOOLS/swiftpm"
STAMP="${WHISPERASR_L7C_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
PRELIGHT_RUN_ID="l7c-whispermlx-vad-preflight-$STAMP"
NATIVE_RUN_ID="l7c-native-full-$STAMP"
VAD_RUN_ID="l7c-whispermlx-vad-full-$STAMP"
APPLE_RUN_ID="l7c-apple-preview-full-$STAMP"
SIMUL_RUN_ID="l7c-wlk-simulstreaming-full-$STAMP"
LOCAL_RUN_ID="l7c-wlk-localagreement-full-$STAMP"
CONTROL_RUN_ID="l7c-human-apple-final-$STAMP"
AGGREGATE_RUN_ID="l7c-aggregate-$STAMP"
AGGREGATE="$ROOT/.build/benchmarks/japanese-live/runs/$AGGREGATE_RUN_ID"
PROVENANCE="$AGGREGATE/source-provenance.json"
RUNTIME_PROVENANCE="$AGGREGATE/runtime-provenance.json"
FIREFOX_QUDU="$ROOT/.build/benchmarks/japanese-live/runs/l7-firefox-turbo-qudu2fx3ncc-20260719T182555Z"
FIREFOX_MD62="$ROOT/.build/benchmarks/japanese-live/runs/l7-firefox-turbo-md62mmdz0m-20260719T190903Z"
NATIVE_ENGINES="whisper-large-v3-turbo,mlx-whisper-large-v3-turbo,voxtral-q4-continuous-960ms,nemotron-multilingual-coreml-1120ms,nemotron-multilingual-coreml-560ms,kotoba-whisper-v2.0-q5,qwen3-asr-1.7b,whispermlx-v3.12.2-turbo"
WHISPERMLX_ENGINE="whispermlx-v3.12.2-turbo"
SANDBOX='(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(allow network-outbound (remote ip "localhost:*"))'

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HF_HOME="$TOOLS/huggingface"
export TORCH_HOME="$TOOLS/torch"
export NLTK_DATA="$TOOLS/nltk"
export UV_CACHE_DIR="$TOOLS/uv-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_STATE/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_STATE/module-cache"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export UV_OFFLINE=1

cd "$ROOT"
COMMIT="$(git rev-parse HEAD)"
DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then DIRTY=1; fi
if [[ "$DIRTY" != "0" ]]; then
  echo "L7C requires a clean worktree for reproducible provenance." >&2
  exit 2
fi
RUN_DIRECTORIES=(
  "$ROOT/.build/benchmarks/japanese-live/runs/$PRELIGHT_RUN_ID"
  "$ROOT/.build/benchmarks/japanese-live/runs/$NATIVE_RUN_ID"
  "$ROOT/.build/benchmarks/japanese-live/runs/$VAD_RUN_ID"
  "$ROOT/.build/benchmarks/japanese-live/runs/$APPLE_RUN_ID"
  "$ROOT/.build/benchmarks/japanese-live/runs/$SIMUL_RUN_ID"
  "$ROOT/.build/benchmarks/japanese-live/runs/$LOCAL_RUN_ID"
  "$ROOT/.build/benchmarks/japanese-live/runs/$CONTROL_RUN_ID"
  "$AGGREGATE"
)
for directory in "${RUN_DIRECTORIES[@]}"; do
  if [[ -e "$directory" ]]; then
    echo "Refusing to reuse an existing L7C run directory: $directory" >&2
    exit 2
  fi
done
mkdir -p \
  "$AGGREGATE" \
  "$SWIFT_STATE/cache" \
  "$SWIFT_STATE/config" \
  "$SWIFT_STATE/security" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE"
/usr/bin/python3 Scripts/aggregate_japanese_l7c.py --self-test
SOURCE_TREE_SHA256="$(Scripts/source_tree_provenance.py --root "$ROOT" --output "$PROVENANCE")"
/usr/bin/sandbox-exec -p "$SANDBOX" Scripts/verify_japanese_corpora.sh
WHISPERASR_VERIFY_MODEL_RECIPES=1 \
  /usr/bin/sandbox-exec -p "$SANDBOX" xcrun swift test \
    --disable-sandbox \
    --cache-path "$SWIFT_STATE/cache" \
    --config-path "$SWIFT_STATE/config" \
    --security-path "$SWIFT_STATE/security" \
    --scratch-path "$ROOT/.build" \
    -c release \
    --filter JapaneseModelRecipeTests
Scripts/build_mlx_metallib.sh release
RUNTIME_SHA256="$(Scripts/runtime_provenance.py --root "$ROOT" --output "$RUNTIME_PROVENANCE")"

verify_runtime() {
  local current
  current="$(Scripts/runtime_provenance.py \
    --root "$ROOT" \
    --output "$AGGREGATE/runtime-provenance-final.json")"
  if [[ "$current" != "$RUNTIME_SHA256" ]]; then
    echo "Benchmark runtime changed during L7C." >&2
    exit 2
  fi
}

RUNNER=(
  /usr/bin/sandbox-exec -p "$SANDBOX"
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
  -XCTest WhisperASRTests.JapaneseModelBakeoffTests/testCorrectiveStressReplaysWhenOptedIn
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"
)

run_model_matrix() {
  local run_id="$1"
  local engines="$2"
  local scope="$3"
  local mode="$4"
  if [[ "$scope" == "full-video" ]]; then
    WHISPERASR_L7C_REPLAY=1 \
    WHISPERASR_L7C_REPLAY_COUNT=1 \
    WHISPERASR_WHISPERMLX_MODE="$mode" \
    WHISPERASR_JAPANESE_BAKEOFF_ENGINES="$engines" \
    WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
    WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
    WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
    WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
    WHISPERASR_BENCHMARK_RUN_ID="$run_id" \
    WHISPERASR_OFFLINE=1 \
    WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
    WHISPERASR_PROCESS_ALREADY_SANDBOXED=1 \
      "${RUNNER[@]}"
  else
    WHISPERASR_L7C_VAD_PREFLIGHT=1 \
    WHISPERASR_L7B_REPLAY_COUNT=3 \
    WHISPERASR_L7B_WINDOW_LIMIT=4 \
    WHISPERASR_WHISPERMLX_MODE="$mode" \
    WHISPERASR_JAPANESE_BAKEOFF_ENGINES="$engines" \
    WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
    WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
    WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
    WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
    WHISPERASR_BENCHMARK_RUN_ID="$run_id" \
    WHISPERASR_OFFLINE=1 \
    WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
    WHISPERASR_PROCESS_ALREADY_SANDBOXED=1 \
      "${RUNNER[@]}"
  fi
  Scripts/source_tree_provenance.py --root "$ROOT" --expect "$SOURCE_TREE_SHA256"
  verify_runtime
}

run_live_matrix() {
  local run_id="$1"
  local sources="$2"
  local policy="$3"
  WHISPERASR_WLK_POLICY="$policy" \
  WHISPERASR_WLK_MIN_CHUNK_SECONDS=0.1 \
  WHISPERASR_WLK_RETENTION_SECONDS=1200 \
  WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
  WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
  WHISPERASR_L6_RUN_ID="$run_id" \
  WHISPERASR_L6_SCOPE=full-video \
  WHISPERASR_L6_REPLAY_COUNT=1 \
  WHISPERASR_L6_SOURCES="$sources" \
    Scripts/run_japanese_live_replay.sh
  Scripts/source_tree_provenance.py --root "$ROOT" --expect "$SOURCE_TREE_SHA256"
  verify_runtime
}

run_model_matrix "$PRELIGHT_RUN_ID" "$WHISPERMLX_ENGINE" corrective vad-finals
run_model_matrix "$NATIVE_RUN_ID" "$NATIVE_ENGINES" full-video long-form
run_model_matrix "$VAD_RUN_ID" "$WHISPERMLX_ENGINE" full-video vad-finals
run_live_matrix "$APPLE_RUN_ID" apple-speech simulstreaming
run_live_matrix "$SIMUL_RUN_ID" whisperlivekit simulstreaming
run_live_matrix "$LOCAL_RUN_ID" whisperlivekit localagreement

CONTROL_REPORT="$ROOT/.build/benchmarks/japanese-live/runs/$CONTROL_RUN_ID/human-translation-control.json"
WHISPERASR_L7C_TRANSLATION_CONTROL=1 \
WHISPERASR_L7C_RUN_ID="$CONTROL_RUN_ID" \
WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
  /usr/bin/sandbox-exec -p "$SANDBOX" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest WhisperASRTests.JapaneseTranslationControlTests/testHumanJapaneseToAppleFinalWhenOptedIn \
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"

Scripts/source_tree_provenance.py --root "$ROOT" --expect "$SOURCE_TREE_SHA256"
verify_runtime
/usr/bin/python3 Scripts/aggregate_japanese_l7c.py \
  --preflight "$ROOT/.build/benchmarks/japanese-live/runs/$PRELIGHT_RUN_ID/live-replay.json" \
  --native "$ROOT/.build/benchmarks/japanese-live/runs/$NATIVE_RUN_ID/live-replay.json" \
  --whispermlx-vad "$ROOT/.build/benchmarks/japanese-live/runs/$VAD_RUN_ID/live-replay.json" \
  --apple "$ROOT/.build/benchmarks/japanese-live/runs/$APPLE_RUN_ID/live-replay.json" \
  --simulstreaming "$ROOT/.build/benchmarks/japanese-live/runs/$SIMUL_RUN_ID/live-replay.json" \
  --localagreement "$ROOT/.build/benchmarks/japanese-live/runs/$LOCAL_RUN_ID/live-replay.json" \
  --translation-control "$CONTROL_REPORT" \
  --firefox-run-manifest "$FIREFOX_QUDU/run-manifest.json" \
  --firefox-alignment-report "$FIREFOX_QUDU/l7-evaluation-evaluation-full.json" \
  --firefox-run-manifest "$FIREFOX_MD62/run-manifest.json" \
  --firefox-alignment-report "$FIREFOX_MD62/l7-evaluation-evaluation-full.json" \
  --recipes "$ROOT/docs/japanese-live/model-recipes.json" \
  --source-provenance "$PROVENANCE" \
  --runtime-provenance "$RUNTIME_PROVENANCE" \
  --runtime-provenance-final "$AGGREGATE/runtime-provenance-final.json" \
  --source-root "$ROOT" \
  --output "$AGGREGATE"

echo "Aggregate report: $AGGREGATE"
