#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${1:-}"
CORPUS="${2:-$ROOT/.build/benchmarks/corpora/easy-japanese-1}"

if [[ -z "$SESSION" ]]; then
  echo "Usage: $0 <local-captions-*-session.json> [corpus-directory]" >&2
  exit 2
fi
[[ "$SESSION" = /* ]] || SESSION="$PWD/$SESSION"
[[ "$CORPUS" = /* ]] || CORPUS="$PWD/$CORPUS"
for file in "$SESSION" "$CORPUS/manifest.json" "$CORPUS/audio-16k-mono.wav"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing input: $file" >&2
    exit 1
  fi
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
xcrun swift test --filter JapaneseOfflineEvaluationTests
WHISPERASR_JAPANESE_OFFLINE_SESSION="$SESSION" \
WHISPERASR_JAPANESE_OFFLINE_CORPUS="$CORPUS" \
  xcrun swift test --skip-build \
    --filter JapaneseOfflineEvaluationTests/testGeneratePreviewFinalBlindReportWhenOptedIn

echo "Reports were written beside: $SESSION"
