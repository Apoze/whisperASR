#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
STAMP="${WHISPERASR_L7B_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
NATIVE_RUN_ID="l7b-native-$STAMP"
SIMUL_RUN_ID="l7b-wlk-simulstreaming-$STAMP"
LOCAL_RUN_ID="l7b-wlk-localagreement-$STAMP"
AGGREGATE_RUN_ID="l7b-aggregate-$STAMP"
PROVENANCE="$ROOT/.build/benchmarks/japanese-live/runs/$AGGREGATE_RUN_ID/source-provenance.json"
RUNTIME_PROVENANCE="$ROOT/.build/benchmarks/japanese-live/runs/$AGGREGATE_RUN_ID/runtime-provenance.json"
ENGINES="whisper-large-v3-turbo,mlx-whisper-large-v3-turbo,voxtral-q4-continuous-960ms,nemotron-multilingual-coreml-1120ms,nemotron-multilingual-coreml-560ms,kotoba-whisper-v2.0-q5,qwen3-asr-1.7b,whispermlx-v3.12.2-turbo"
SANDBOX='(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(allow network-outbound (remote ip "localhost:*"))'

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HF_HOME="$TOOLS/huggingface"
export TORCH_HOME="$TOOLS/torch"
export NLTK_DATA="$TOOLS/nltk"
export UV_CACHE_DIR="$TOOLS/uv-cache"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export UV_OFFLINE=1

cd "$ROOT"
Scripts/aggregate_japanese_l7b.py --self-test
SOURCE_TREE_SHA256="$(Scripts/source_tree_provenance.py --root "$ROOT" --output "$PROVENANCE")"
Scripts/verify_japanese_corpora.sh
WHISPERASR_VERIFY_MODEL_RECIPES=1 \
  xcrun swift test -c release --filter JapaneseModelRecipeTests
Scripts/build_mlx_metallib.sh release
RUNTIME_SHA256="$(Scripts/runtime_provenance.py --root "$ROOT" --output "$RUNTIME_PROVENANCE")"

COMMIT="$(git rev-parse HEAD)"
DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then DIRTY=1; fi
RUNNER=(
  /usr/bin/sandbox-exec -p "$SANDBOX"
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
  -XCTest WhisperASRTests.JapaneseModelBakeoffTests/testCorrectiveStressReplaysWhenOptedIn
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"
)

WHISPERASR_L7B_REPLAY=1 \
WHISPERASR_L7B_REPLAY_COUNT="${WHISPERASR_L7B_REPLAY_COUNT:-3}" \
WHISPERASR_L7B_WINDOW_LIMIT="${WHISPERASR_L7B_WINDOW_LIMIT:-4}" \
WHISPERASR_JAPANESE_BAKEOFF_ENGINES="$ENGINES" \
WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
WHISPERASR_BENCHMARK_RUN_ID="$NATIVE_RUN_ID" \
WHISPERASR_OFFLINE=1 \
WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
WHISPERASR_PROCESS_ALREADY_SANDBOXED=1 \
  "${RUNNER[@]}"

for POLICY in simulstreaming localagreement; do
  WHISPERASR_WLK_POLICY="$POLICY" \
  WHISPERASR_WLK_MIN_CHUNK_SECONDS=0.1 \
  WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
  WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
  WHISPERASR_L6_RUN_ID="l7b-wlk-$POLICY-$STAMP" \
  WHISPERASR_L6_REPLAY_COUNT="${WHISPERASR_L7B_REPLAY_COUNT:-3}" \
  WHISPERASR_L6_WINDOW_LIMIT="${WHISPERASR_L7B_WINDOW_LIMIT:-4}" \
  WHISPERASR_L6_SOURCES=whisperlivekit \
    Scripts/run_japanese_live_replay.sh
done

Scripts/source_tree_provenance.py --root "$ROOT" --expect "$SOURCE_TREE_SHA256"

"$TOOLS/whisperlivekit/5874bdeeaddf968ab73e005eb287e1b597b0eb37/venv/bin/python" \
  Scripts/aggregate_japanese_l7b.py \
  --native "$ROOT/.build/benchmarks/japanese-live/runs/$NATIVE_RUN_ID/live-replay.json" \
  --simulstreaming "$ROOT/.build/benchmarks/japanese-live/runs/$SIMUL_RUN_ID/live-replay.json" \
  --localagreement "$ROOT/.build/benchmarks/japanese-live/runs/$LOCAL_RUN_ID/live-replay.json" \
  --recipes "$ROOT/docs/japanese-live/model-recipes.json" \
  --source-provenance "$PROVENANCE" \
  --source-root "$ROOT" \
  --runtime-provenance "$RUNTIME_PROVENANCE" \
  --output "$ROOT/.build/benchmarks/japanese-live/runs/$AGGREGATE_RUN_ID"

Scripts/source_tree_provenance.py --root "$ROOT" --expect "$SOURCE_TREE_SHA256"

echo "Native report: $ROOT/.build/benchmarks/japanese-live/runs/$NATIVE_RUN_ID"
echo "WhisperLiveKit reports: $ROOT/.build/benchmarks/japanese-live/runs/l7b-wlk-*-$STAMP"
echo "Aggregate report: $ROOT/.build/benchmarks/japanese-live/runs/$AGGREGATE_RUN_ID"
