#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOPE="${1:-smoke}"
CORPUS="${WHISPERASR_JAPANESE_BAKEOFF_CORPUS:-$ROOT/.build/benchmarks/corpora/easy-japanese-1}"

if [[ "$SCOPE" != "smoke" && "$SCOPE" != "full" ]]; then
  echo "Usage: $0 [smoke|full]" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
"$ROOT/Scripts/prepare_japanese_bakeoff.sh"

# Build first, then place MLX's runtime metallib in the Release test bundle.
xcrun swift test -c release \
  --filter JapaneseModelBakeoffTests/testBakeoffScoringSeparatesPrimaryAndDiagnosticTurns
"$ROOT/Scripts/build_mlx_metallib.sh" release

WHISPERASR_JAPANESE_BAKEOFF=1 \
WHISPERASR_JAPANESE_BAKEOFF_SCOPE="$SCOPE" \
WHISPERASR_JAPANESE_BAKEOFF_CORPUS="$CORPUS" \
WHISPERASR_JAPANESE_BAKEOFF_APPLE="${WHISPERASR_JAPANESE_BAKEOFF_APPLE:-0}" \
  xcrun swift test -c release --skip-build \
    --filter JapaneseModelBakeoffTests/testJapaneseASRBakeoffWhenOptedIn

echo "Reports: $ROOT/.build/benchmarks/easy-japanese-1-asr-bakeoff-$SCOPE-*.json"
