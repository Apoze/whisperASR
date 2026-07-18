#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${1:-}"
MANIFEST="${2:-$ROOT/docs/japanese-live/corpora/easy-japanese-1/manifest.json}"

if [[ -z "$SESSION" ]]; then
  echo "Usage: $0 <local-captions-*-session.json> [manifest.json]" >&2
  exit 2
fi
[[ "$SESSION" = /* ]] || SESSION="$PWD/$SESSION"
[[ "$MANIFEST" = /* ]] || MANIFEST="$PWD/$MANIFEST"
for file in "$SESSION" "$MANIFEST"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing input: $file" >&2
    exit 1
  fi
done
if [[ "$(/usr/bin/jq -r '.corpusID' "$MANIFEST")" != "easy-japanese-1" ]]; then
  echo "The exact product replay currently requires the Easy Japanese capture session." >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
xcrun swift test --filter JapaneseOfflineEvaluationTests
WHISPERASR_JAPANESE_OFFLINE_SESSION="$SESSION" \
WHISPERASR_JAPANESE_BENCHMARK_MANIFEST="$MANIFEST" \
  xcrun swift test --skip-build \
    --filter JapaneseOfflineEvaluationTests/testGeneratePreviewFinalBlindReportWhenOptedIn

echo "Reports were written beside: $SESSION"
