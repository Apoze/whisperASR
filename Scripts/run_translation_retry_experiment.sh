#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/translation-retry"
DIRECT="$ROOT/.build/benchmarks/direct-translation"
INTEGRITY="$ROOT/.build/benchmarks/translation-integrity"
MODE="${1:-full}"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E11-translation-retry.md"
COMET_PYTHON="${COMET_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in development|final|full) ;; *) echo "usage: $0 [development|final|full]" >&2; exit 2 ;; esac
[[ -x "$COMET_PYTHON" ]] || { echo "COMET v2.2.7 is required at $COMET_PYTHON" >&2; exit 1; }
mkdir -p "$ARTIFACTS"
cd "$ROOT"

run_split() {
  local split="$1" output="$ARTIFACTS/$1/retry.json"
  [[ -f "$DIRECT/$split/direct-protocol.json" ]] || { echo "E09 $split artifact is required." >&2; exit 1; }
  [[ -f "$INTEGRITY/$split.json" ]] || { echo "E10 $split verdicts are required." >&2; exit 1; }
  [[ -f "$output" ]] && { echo "Reusing $output"; return; }
  mkdir -p "$ARTIFACTS/$split"
  WHISPERASR_RUN_TRANSLATION_RETRY_EXPERIMENT=1 \
  WHISPERASR_TRANSLATION_RETRY_CORPUS="$split" \
  WHISPERASR_TRANSLATION_RETRY_BASELINE="$DIRECT/$split/direct-protocol.json" \
  WHISPERASR_TRANSLATION_RETRY_VERDICTS="$INTEGRITY/$split.json" \
  WHISPERASR_TRANSLATION_RETRY_OUTPUT="$output" \
  WHISPERASR_TRANSLATION_RETRY_ALLOW_HOLDOUT="$([[ "$split" == holdout ]] && echo 1 || echo 0)" \
    xcrun swift test --filter HighQualityTranslationIntegrityTests/testRetriesFrozenRejectedUnitsWhenOptedIn \
      2>&1 | tee "$ARTIFACTS/$split/run.log"
}

report() {
  python3 Scripts/report_translation_retry.py "$ARTIFACTS" "$DIRECT" "$INTEGRITY" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
}

score() {
  local split="$1" metrics="$ARTIFACTS/metrics/$1"
  "$COMET_PYTHON" Scripts/comet_score_compat.py \
    -s "$DIRECT/metrics/$split/source.ja.txt" \
    -t "$metrics/selective-retry.en.txt" \
    -r "$DIRECT/metrics/$split/reference.en.txt" --model Unbabel/wmt22-comet-da \
    --gpus "${COMET_GPUS:-1}" --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" >"$metrics/comet-score.raw.txt" 2>&1
}

if [[ "$MODE" != final ]]; then
  run_split development
  report
  score development
  report
  jq -e '.gates.development | to_entries | all(.value == true)' "$REPORT_JSON" >/dev/null
fi
[[ -f "$ARTIFACTS/development/retry.json" ]] || { echo "Development gates must pass first." >&2; exit 1; }
[[ "$MODE" == development ]] && { echo "Development gates passed; holdout remains untouched."; exit 0; }

run_split holdout
xcrun swift test --filter LiveCaptionTests 2>&1 | tee "$ARTIFACTS/live-tests.log"
report
score holdout
report
jq -e '.liveGatesUnchanged and (.gates | to_entries | all(.value | to_entries | all(.value == true)))' "$REPORT_JSON" >/dev/null
echo "Report: $REPORT_MD"
