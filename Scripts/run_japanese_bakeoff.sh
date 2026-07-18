#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="${1:-smoke}"
DEFAULT_MANIFEST="$ROOT/docs/japanese-live/corpora/easy-japanese-1/manifest.json"
MANIFEST="${WHISPERASR_JAPANESE_BENCHMARK_MANIFEST:-$DEFAULT_MANIFEST}"

if [[ "$SCOPE" != "smoke" && "$SCOPE" != "full" ]]; then
  echo "Usage: $0 [smoke|full]" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
if [[ "$MANIFEST" == "$DEFAULT_MANIFEST" ]]; then
  "$ROOT/Scripts/prepare_japanese_bakeoff.sh"
fi

# Build first, then place MLX's runtime metallib in the Release test bundle.
xcrun swift test -c release \
  --filter JapaneseModelBakeoffTests/testBakeoffScoringSeparatesPrimaryAndDiagnosticTurns
"$ROOT/Scripts/build_mlx_metallib.sh" release

WHISPERASR_JAPANESE_BAKEOFF=1 \
WHISPERASR_JAPANESE_BAKEOFF_SCOPE="$SCOPE" \
WHISPERASR_JAPANESE_BENCHMARK_MANIFEST="$MANIFEST" \
WHISPERASR_JAPANESE_BAKEOFF_APPLE="${WHISPERASR_JAPANESE_BAKEOFF_APPLE:-0}" \
  xcrun swift test -c release --skip-build \
    --filter JapaneseModelBakeoffTests/testJapaneseASRBakeoffWhenOptedIn

CORPUS_ID="$(/usr/bin/jq -r '.corpusID' "$MANIFEST")"
echo "Reports: $ROOT/.build/benchmarks/$CORPUS_ID-asr-bakeoff-$SCOPE-*.json"
