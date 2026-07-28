#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
SWIFT_STATE="$TOOLS/swiftpm"
STAMP="${WHISPERASR_L8B2_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
TARGETS="${WHISPERASR_L8B2_TARGETS:-240 480 720}"
REPLAY_COUNT="${WHISPERASR_L8B2_REPLAY_COUNT:-1}"
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
case "$REPLAY_COUNT" in
  1|2) ;;
  *) echo "Unsupported replay count: $REPLAY_COUNT" >&2; exit 2 ;;
esac
mkdir -p \
  "$SWIFT_STATE/cache" \
  "$SWIFT_STATE/config" \
  "$SWIFT_STATE/security" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE"
prebuild_provenance="$ROOT/.build/benchmarks/japanese-live/l8b2-source-$STAMP.json"
prebuild_sha="$(Scripts/source_tree_provenance.py \
  --root "$ROOT" \
  --output "$prebuild_provenance")"

/usr/bin/sandbox-exec -p "$SANDBOX" Scripts/verify_japanese_corpora.sh
xcrun swift test \
  --disable-sandbox \
  --cache-path "$SWIFT_STATE/cache" \
  --config-path "$SWIFT_STATE/config" \
  --security-path "$SWIFT_STATE/security" \
  --scratch-path "$ROOT/.build" \
  -c release \
  --filter JapaneseModelBakeoffTests.testVoxtralRotation
Scripts/build_mlx_metallib.sh release

COMMIT="$(git rev-parse HEAD)"
DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then DIRTY=1; fi

for target in $TARGETS; do
  case "$target" in
    240|480|720) ;;
    *) echo "Unsupported rotation target: $target" >&2; exit 2 ;;
  esac
  replay_suffix=""
  if [[ "$REPLAY_COUNT" != 1 ]]; then replay_suffix="-${REPLAY_COUNT}x"; fi
  run_id="l8b2-voxtral-rotation-${target}s${replay_suffix}-$STAMP"
  output="$ROOT/.build/benchmarks/japanese-live/runs/$run_id"
  mkdir -p "$output"
  source_sha="$(Scripts/source_tree_provenance.py \
    --root "$ROOT" \
    --output "$output/source-provenance.json")"
  if [[ "$source_sha" != "$prebuild_sha" ]]; then
    echo "Source tree changed during the L8B2 build." >&2
    exit 3
  fi
  runtime_sha="$(Scripts/runtime_provenance.py \
    --root "$ROOT" \
    --output "$output/runtime-provenance.json")"

  WHISPERASR_L7C_REPLAY=1 \
  WHISPERASR_L7C_REPLAY_COUNT="$REPLAY_COUNT" \
  WHISPERASR_JAPANESE_BAKEOFF_ENGINES=voxtral-q4-continuous-960ms \
  WHISPERASR_VOXTRAL_ROTATION_SECONDS="$target" \
  WHISPERASR_BENCHMARK_COMMIT="$COMMIT" \
  WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="$source_sha" \
  WHISPERASR_BENCHMARK_RUNTIME_SHA256="$runtime_sha" \
  WHISPERASR_BENCHMARK_DIRTY="$DIRTY" \
  WHISPERASR_BENCHMARK_RUN_ID="$run_id" \
  WHISPERASR_OFFLINE=1 \
  WHISPERASR_EXTERNAL_NETWORK_DENIED=1 \
  WHISPERASR_PROCESS_ALREADY_SANDBOXED=1 \
    /usr/bin/sandbox-exec -p "$SANDBOX" \
    /Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
    -XCTest WhisperASRTests.JapaneseModelBakeoffTests/testCorrectiveStressReplaysWhenOptedIn \
    "$ROOT/.build/release/WhisperASRPackageTests.xctest"

  verified_source_sha="$(Scripts/source_tree_provenance.py \
    --root "$ROOT" \
    --output "$output/source-provenance-after.json")"
  if [[ "$verified_source_sha" != "$source_sha" ]]; then
    echo "Source tree changed during L8B2 ${target}s." >&2
    exit 3
  fi
  echo "L8B2 ${target}s: $output/live-replay.json"
done
