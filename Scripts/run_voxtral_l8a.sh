#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
SWIFT_STATE="$TOOLS/swiftpm"
STAMP="${WHISPERASR_L8A_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
NATIVE_RUN_ID="l8a-voxtral-native-$STAMP"
DIAGNOSTIC_RUN_ID="l8a-voxtral-apple-$STAMP"
OUTPUT_RUN_ID="l8a-voxtral-diagnostic-$STAMP"
OUTPUT="$ROOT/.build/benchmarks/japanese-live/runs/$OUTPUT_RUN_ID"
BASELINE="$ROOT/.build/benchmarks/japanese-live/runs/l7c-native-full-20260721T173540Z/live-replay.json"
PROVENANCE="$OUTPUT/source-provenance.json"
RUNTIME_PROVENANCE="$OUTPUT/runtime-provenance.json"
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
mkdir -p \
  "$OUTPUT" \
  "$SWIFT_STATE/cache" \
  "$SWIFT_STATE/config" \
  "$SWIFT_STATE/security" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE"

/usr/bin/python3 Scripts/report_voxtral_l8a.py --self-test
SOURCE_TREE_SHA256="$(Scripts/source_tree_provenance.py --root "$ROOT" --output "$PROVENANCE")"
/usr/bin/sandbox-exec -p "$SANDBOX" Scripts/verify_japanese_corpora.sh
xcrun swift test \
  --disable-sandbox \
  --cache-path "$SWIFT_STATE/cache" \
  --config-path "$SWIFT_STATE/config" \
  --security-path "$SWIFT_STATE/security" \
  --scratch-path "$ROOT/.build" \
  -c release \
  --filter JapaneseTranslationControlTests/testTemporalTextDistributionDoesNotDuplicateCharacters
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

WHISPERASR_L7C_REPLAY=1 \
WHISPERASR_L7C_REPLAY_COUNT=1 \
WHISPERASR_JAPANESE_BAKEOFF_ENGINES=voxtral-q4-continuous-960ms \
WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
WHISPERASR_BENCHMARK_RUNTIME_SHA256="$RUNTIME_SHA256" \
WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
WHISPERASR_BENCHMARK_RUN_ID="$NATIVE_RUN_ID" \
WHISPERASR_OFFLINE=1 \
WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
WHISPERASR_PROCESS_ALREADY_SANDBOXED=1 \
  "${RUNNER[@]}"

NATIVE="$ROOT/.build/benchmarks/japanese-live/runs/$NATIVE_RUN_ID/live-replay.json"
WHISPERASR_L8A_VOXTRAL_DIAGNOSTIC=1 \
WHISPERASR_L8A_NATIVE_REPORT="$NATIVE" \
WHISPERASR_L8A_RUN_ID="$DIAGNOSTIC_RUN_ID" \
WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$SOURCE_TREE_SHA256" \
WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
  /usr/bin/sandbox-exec -p "$SANDBOX" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest WhisperASRTests.JapaneseTranslationControlTests/testVoxtralFourLevelAppleDiagnosticWhenOptedIn \
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"

/usr/bin/python3 Scripts/report_voxtral_l8a.py \
  --native "$NATIVE" \
  --diagnostic "$ROOT/.build/benchmarks/japanese-live/runs/$DIAGNOSTIC_RUN_ID/voxtral-four-level-apple.json" \
  --baseline "$BASELINE" \
  --output "$OUTPUT"

echo "L8A report: $OUTPUT"
