#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
RUN_ID="${WHISPERASR_BENCHMARK_RUN_ID:-l5-stress-$(date -u +%Y%m%dT%H%M%SZ)}"
MANIFESTS="$ROOT/docs/japanese-live/corpora/qudu2fx3ncc/manifest.json,$ROOT/docs/japanese-live/corpora/md62mmdz0m/manifest.json"
ENGINES="whisper-large-v3-turbo,mlx-whisper-large-v3-turbo,voxtral-q4-continuous-960ms,nemotron-multilingual-coreml-1120ms,nemotron-multilingual-coreml-560ms,kotoba-whisper-v2.0-q5,qwen3-asr-1.7b,whispermlx-v3.12.2-turbo"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HF_HOME="$TOOLS/huggingface"
export TORCH_HOME="$TOOLS/torch"
export NLTK_DATA="$TOOLS/nltk"
export UV_CACHE_DIR="$TOOLS/uv-cache"

cd "$ROOT"
python3 Scripts/prepare_japanese_video_corpora.py /Users/maz/Documents/videos/jap
if [[ "${WHISPERASR_PREPARE_L5_TOOLS:-0}" == "1" ]]; then
  Scripts/prepare_japanese_l5_tools.sh
fi

xcrun swift test -c release \
  --filter JapaneseModelBakeoffTests/testL5StressPackIsFixedAndBandSeparated
Scripts/build_mlx_metallib.sh release

if [[ "${WHISPERASR_OFFLINE:-0}" == "1" ]]; then
  export HF_HUB_OFFLINE=1
  export TRANSFORMERS_OFFLINE=1
  export UV_OFFLINE=1
  export WHISPERASR_EXTERNAL_NETWORK_DENIED=1
else
  export WHISPERASR_EXTERNAL_NETWORK_DENIED=0
fi

BENCHMARK_RUNNER=(
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
  -XCTest WhisperASRTests.JapaneseModelBakeoffTests/testJapaneseASRBakeoffWhenOptedIn
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"
)

BENCHMARK_COMMIT="$(git rev-parse HEAD)"
BENCHMARK_DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then
  BENCHMARK_DIRTY=1
fi

WHISPERASR_JAPANESE_BAKEOFF=1 \
WHISPERASR_JAPANESE_BAKEOFF_SCOPE=stress \
WHISPERASR_JAPANESE_BENCHMARK_MANIFESTS="$MANIFESTS" \
WHISPERASR_JAPANESE_BAKEOFF_ENGINES="$ENGINES" \
WHISPERASR_BENCHMARK_COMMIT="$BENCHMARK_COMMIT" \
WHISPERASR_BENCHMARK_DIRTY="$BENCHMARK_DIRTY" \
WHISPERASR_BENCHMARK_RUN_ID="$RUN_ID" \
WHISPERASR_OFFLINE="${WHISPERASR_OFFLINE:-0}" \
  "${BENCHMARK_RUNNER[@]}"

echo "Reports: $ROOT/.build/benchmarks/japanese-live/runs/$RUN_ID"
