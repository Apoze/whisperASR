#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="${1:-smoke}"
DEFAULT_MANIFEST="$ROOT/docs/japanese-live/corpora/easy-japanese-1/manifest.json"
MANIFEST="${WHISPERASR_JAPANESE_BENCHMARK_MANIFEST:-$DEFAULT_MANIFEST}"
NEMOTRON_REVISION="1a41b75758b0337ff67db7d5408280aaaf23074e"
NEMOTRON_ROOT="${WHISPERASR_NEMOTRON_MODEL_ROOT:-$ROOT/.build/models/nemotron-$NEMOTRON_REVISION}"
ENGINES="${WHISPERASR_JAPANESE_BAKEOFF_ENGINES:-whisper-large-v3-turbo,voxtral-q4-continuous-960ms,nemotron-multilingual-coreml-1120ms,nemotron-multilingual-coreml-560ms}"
RUN_ID="${WHISPERASR_BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
ENGLISH_TURNS=""

if [[ "$SCOPE" != "smoke" && "$SCOPE" != "full" ]]; then
  echo "Usage: $0 [smoke|full]" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
if [[ "$MANIFEST" == "$DEFAULT_MANIFEST" ]]; then
  "$ROOT/Scripts/prepare_japanese_bakeoff.sh"
  if [[ -f "$ROOT/.build/benchmarks/corpora/easy-japanese-1/english-turns.csv" ]]; then
    ENGLISH_TURNS="$ROOT/.build/benchmarks/corpora/easy-japanese-1/english-turns.csv"
  fi
fi

if [[ "${WHISPERASR_OFFLINE:-0}" == "1" ]]; then
  export HF_HUB_OFFLINE=1
  export UV_OFFLINE=1
fi

# Build first, then place MLX's runtime metallib in the Release test bundle.
xcrun swift test -c release \
  --filter JapaneseModelBakeoffTests/testBakeoffScoringSeparatesPrimaryAndDiagnosticTurns
"$ROOT/Scripts/build_mlx_metallib.sh" release

if [[ "$ENGINES" == *nemotron* ]]; then
  if [[ "${WHISPERASR_OFFLINE:-0}" == "1" ]]; then
    for tier in 1120 560; do
      test -f "$NEMOTRON_ROOT/nemotron-multilingual/multilingual/${tier}ms/metadata.json"
    done
  else
    WHISPERASR_PREPARE_NEMOTRON=1 \
    WHISPERASR_NEMOTRON_MODEL_ROOT="$NEMOTRON_ROOT" \
      xcrun swift test -c release --skip-build \
        --filter JapaneseModelBakeoffTests/testPreparePinnedNemotronModelsWhenOptedIn
  fi
fi

BENCHMARK_COMMIT="$(git rev-parse HEAD)"
BENCHMARK_DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then
  BENCHMARK_DIRTY=1
fi

WHISPERASR_JAPANESE_BAKEOFF=1 \
WHISPERASR_JAPANESE_BAKEOFF_SCOPE="$SCOPE" \
WHISPERASR_JAPANESE_BENCHMARK_MANIFEST="$MANIFEST" \
WHISPERASR_JAPANESE_BAKEOFF_APPLE="${WHISPERASR_JAPANESE_BAKEOFF_APPLE:-0}" \
WHISPERASR_JAPANESE_BAKEOFF_ENGINES="$ENGINES" \
WHISPERASR_JAPANESE_ENGLISH_TURNS="$ENGLISH_TURNS" \
WHISPERASR_NEMOTRON_MODEL_ROOT="$NEMOTRON_ROOT" \
WHISPERASR_BENCHMARK_COMMIT="$BENCHMARK_COMMIT" \
WHISPERASR_BENCHMARK_DIRTY="$BENCHMARK_DIRTY" \
WHISPERASR_BENCHMARK_RUN_ID="$RUN_ID" \
WHISPERASR_OFFLINE="${WHISPERASR_OFFLINE:-0}" \
  xcrun swift test -c release --skip-build \
    --filter JapaneseModelBakeoffTests/testJapaneseASRBakeoffWhenOptedIn

echo "Reports: $ROOT/.build/benchmarks/japanese-live/$RUN_ID"
