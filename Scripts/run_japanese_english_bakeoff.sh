#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_MANIFEST="$ROOT/docs/japanese-live/corpora/easy-japanese-1/manifest.json"
MANIFEST="${WHISPERASR_JAPANESE_BENCHMARK_MANIFEST:-$DEFAULT_MANIFEST}"
CORPUS_ID="$(/usr/bin/jq -r '.corpusID' "$MANIFEST")"
EXPECTED_TURNS="$(/usr/bin/jq -r '.annotations.turns | length' "$MANIFEST")"
REPORT="${WHISPERASR_JAPANESE_ASR_APPLE_REPORT:-$ROOT/.build/benchmarks/$CORPUS_ID-asr-bakeoff-full-full.json}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
if [[ "$MANIFEST" == "$DEFAULT_MANIFEST" ]]; then
  "$ROOT/Scripts/prepare_japanese_bakeoff.sh"
fi

if ! /usr/bin/jq -e --argjson expectedTurns "$EXPECTED_TURNS" '
  .scope == "full"
  and (.selectedTurnIDs | length) == $expectedTurns
  and ([.engines[].engine] | sort) == ([
    "cohere-transcribe-03-2026-mlx-8bit",
    "qwen3-asr-1.7b-mlx-8bit",
    "voxtral-q4-continuous-960ms",
    "whisper-large-v3-turbo"
  ] | sort)
' "$REPORT" >/dev/null; then
  echo "Missing complete $EXPECTED_TURNS-turn ASR report: $REPORT" >&2
  echo "Run: Scripts/run_japanese_bakeoff.sh full" >&2
  exit 2
fi

if ! /usr/bin/jq -e '.appleHighFidelityEnabled == true' "$REPORT" >/dev/null; then
  echo "The bilingual oracle requires a complete ASR+Apple report: $REPORT" >&2
  echo "Run: WHISPERASR_JAPANESE_BAKEOFF_APPLE=1 Scripts/run_japanese_bakeoff.sh full" >&2
  exit 3
fi

xcrun swift test -c release \
  --filter JapaneseEnglishFullBakeoffTests/testBlindArtifactsMaskEveryAvailableCandidate

WHISPERASR_JAPANESE_ENGLISH_BAKEOFF=1 \
WHISPERASR_JAPANESE_ENGLISH_REQUIRE_COMPLETE=1 \
WHISPERASR_JAPANESE_BENCHMARK_MANIFEST="$MANIFEST" \
WHISPERASR_JAPANESE_ASR_APPLE_REPORT="$REPORT" \
  xcrun swift test -c release --skip-build \
    --filter JapaneseEnglishFullBakeoffTests/testFullEnglishBakeoffWhenOptedIn

echo "Reports: $ROOT/.build/benchmarks/$CORPUS_ID-english-bakeoff-*.json"
