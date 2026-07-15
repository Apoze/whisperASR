#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${WHISPERASR_JAPANESE_ASR_APPLE_REPORT:-$ROOT/.build/benchmarks/easy-japanese-1-asr-bakeoff-full-full.json}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
"$ROOT/Scripts/prepare_japanese_bakeoff.sh"

if ! /usr/bin/jq -e '
  .scope == "full"
  and (.selectedTurnIDs | length) == 59
  and ([.engines[].engine] | sort) == ([
    "cohere-transcribe-03-2026-mlx-8bit",
    "qwen3-asr-1.7b-mlx-8bit",
    "voxtral-q4-continuous-960ms",
    "whisper-large-v3-turbo"
  ] | sort)
' "$REPORT" >/dev/null; then
  echo "Missing complete 59-turn ASR report: $REPORT" >&2
  echo "Run: Scripts/run_japanese_bakeoff.sh full" >&2
  exit 2
fi

if /usr/bin/jq -e '.appleHighFidelityEnabled == true' "$REPORT" >/dev/null; then
  echo "Apple enrichment: enabled from the existing ASR+Apple report"
else
  echo "Apple enrichment: unavailable; producing an explicit Whisper-direct-only blind report"
fi

xcrun swift test -c release \
  --filter JapaneseEnglishFullBakeoffTests/testBlindArtifactsRotateAllSixCandidates

WHISPERASR_JAPANESE_ENGLISH_BAKEOFF=1 \
WHISPERASR_JAPANESE_ASR_APPLE_REPORT="$REPORT" \
  xcrun swift test -c release --skip-build \
    --filter JapaneseEnglishFullBakeoffTests/testFullEnglishBakeoffWhenOptedIn

echo "Reports: $ROOT/.build/benchmarks/easy-japanese-1-english-bakeoff-*.json"
