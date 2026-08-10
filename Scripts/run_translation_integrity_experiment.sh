#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/translation-integrity"
MODE="${1:-full}"
DEV_INPUT="${WHISPERASR_TRANSLATION_INTEGRITY_DEV_INPUT:-$ROOT/.build/benchmarks/direct-translation/development/direct-protocol.json}"
HOLDOUT_INPUT="${WHISPERASR_TRANSLATION_INTEGRITY_HOLDOUT_INPUT:-$ROOT/.build/benchmarks/direct-translation/holdout/direct-protocol.json}"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E10-translation-integrity.md"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in development|final|full) ;; *) echo "usage: $0 [development|final|full]" >&2; exit 2 ;; esac
[[ -f "$DEV_INPUT" ]] || { echo "Frozen E09 development artifact is required." >&2; exit 1; }
mkdir -p "$ARTIFACTS"
cd "$ROOT"

run_fixtures() {
  WHISPERASR_TRANSLATION_INTEGRITY_FIXTURES_OUTPUT="$ARTIFACTS/fixtures.json" \
    xcrun swift test --filter HighQualityTranslationIntegrityTests/testDeterministicCorruptionFixturesAndValidTranslations
  xcrun swift test --skip-build \
    --filter HighQualityTranslationIntegrityTests/testValidTranslationCompletesWithoutRetry
}

run_split() {
  local corpus="$1" input="$2" output="$ARTIFACTS/$1.json"
  WHISPERASR_RUN_TRANSLATION_INTEGRITY_EXPERIMENT=1 \
  WHISPERASR_TRANSLATION_INTEGRITY_CORPUS="$corpus" \
  WHISPERASR_TRANSLATION_INTEGRITY_INPUT="$input" \
  WHISPERASR_TRANSLATION_INTEGRITY_OUTPUT="$output" \
  WHISPERASR_TRANSLATION_INTEGRITY_ALLOW_HOLDOUT="$([[ "$corpus" == holdout ]] && echo 1 || echo 0)" \
    xcrun swift test --skip-build \
      --filter HighQualityTranslationIntegrityTests/testWritesFrozenCorpusVerdictsWhenOptedIn
}

report() {
  python3 Scripts/report_translation_integrity.py "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD" "$@"
}

if [[ "$MODE" != final ]]; then
  run_fixtures
  run_split development "$DEV_INPUT"
  report
  jq -e '.injectedCorruptions | .allReasonsCovered and (.falsePositives == []) and (.falseNegatives == [])' "$REPORT_JSON" >/dev/null
fi
[[ -f "$ARTIFACTS/development.json" ]] || { echo "Development verdicts must exist first." >&2; exit 1; }
[[ "$MODE" == development ]] && { echo "Development thresholds frozen; holdout remains unprocessed."; exit 0; }

[[ -f "$HOLDOUT_INPUT" ]] || { echo "Frozen E09 holdout artifact is required." >&2; exit 1; }
run_split holdout "$HOLDOUT_INPUT"
report --include-holdout
jq -e '.injectedCorruptions | .allReasonsCovered and (.falsePositives == []) and (.falseNegatives == [])' "$REPORT_JSON" >/dev/null
jq -S .thresholds "$ARTIFACTS/development.json" >"$ARTIFACTS/development-thresholds.json"
jq -S .thresholds "$ARTIFACTS/holdout.json" >"$ARTIFACTS/holdout-thresholds.json"
cmp "$ARTIFACTS/development-thresholds.json" "$ARTIFACTS/holdout-thresholds.json"
echo "Report: $REPORT_MD"
