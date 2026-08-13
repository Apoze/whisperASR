#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/direct-translation"
MODE="${1:-full}"
DEV_BASELINE="${WHISPERASR_DIRECT_DEV_BASELINE:-$ROOT/.build/benchmarks/semantic-translation/development-reviewed/2A743BB5-FC2A-4EC8-B9D1-474127ECD5D2/raw-asr.json}"
HOLDOUT_BASELINE="${WHISPERASR_DIRECT_HOLDOUT_BASELINE:-$ROOT/.build/benchmarks/semantic-translation/holdout-reviewed/8FD31A4B-F61D-4A6E-99C9-6A127AA2EDF2/raw-asr.json}"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E09-direct-translategemma.md"
COMET_PYTHON="${COMET_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in development|final|full) ;; *) echo "usage: $0 [development|final|full]" >&2; exit 2 ;; esac
[[ -f "$DEV_BASELINE" ]] || { echo "Frozen E08 development artifact is required." >&2; exit 1; }
[[ -x "$COMET_PYTHON" ]] || { echo "COMET v2.2.7 is required at $COMET_PYTHON" >&2; exit 1; }
mkdir -p "$ARTIFACTS"
cd "$ROOT"

run_split() {
  local split="$1" baseline="$2" output="$ARTIFACTS/$1/direct-protocol.json"
  [[ -f "$output" ]] && { echo "Reusing $output"; return; }
  mkdir -p "$ARTIFACTS/$split"
  WHISPERASR_RUN_DIRECT_TRANSLATION_EXPERIMENT=1 \
  WHISPERASR_DIRECT_TRANSLATION_EVIDENCE="$baseline" \
  WHISPERASR_DIRECT_TRANSLATION_OUTPUT="$output" \
  WHISPERASR_DIRECT_TRANSLATION_ALLOW_HOLDOUT="$([[ "$split" == holdout ]] && echo 1 || echo 0)" \
    xcrun swift test --skip-build \
      --filter HighQualityLocalTranslationTests/testOfficialDirectProtocolOnFrozenSemanticUnitsWhenOptedIn \
      2>&1 | tee "$ARTIFACTS/$split/run.log"
}

report() {
  python3 Scripts/report_direct_translation.py "$ARTIFACTS" "$DEV_BASELINE" "$HOLDOUT_BASELINE" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
}

score() {
  local split="$1" metrics="$ARTIFACTS/metrics/$1"
  "$COMET_PYTHON" Scripts/comet_score_compat.py \
    -s "$metrics/source.ja.txt" \
    -t "$metrics/existing-protocol.en.txt" "$metrics/direct-protocol.en.txt" \
    -r "$metrics/reference.en.txt" --model Unbabel/wmt22-comet-da \
    --gpus "${COMET_GPUS:-1}" --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" >"$metrics/comet-score.raw.txt" 2>&1
}

if [[ "$MODE" != final ]]; then
  run_split development "$DEV_BASELINE"
  report
  score development
  report
  jq -e '.gates.development | to_entries | all(.value == true)' "$REPORT_JSON" >/dev/null
fi
[[ -f "$ARTIFACTS/development/direct-protocol.json" ]] || { echo "Development gates must pass first." >&2; exit 1; }
if [[ "$MODE" == final ]]; then
  report
  jq -e '.gates.development | to_entries | all(.value == true)' "$REPORT_JSON" >/dev/null
fi
[[ "$MODE" == development ]] && { echo "Development gates passed; holdout remains untouched."; exit 0; }

[[ -f "$HOLDOUT_BASELINE" ]] || { echo "Frozen E08 holdout artifact is required." >&2; exit 1; }
run_split holdout "$HOLDOUT_BASELINE"
report
score holdout
report
jq -e '.gates | to_entries | all(.value | to_entries | all(.value == true))' "$REPORT_JSON" >/dev/null
echo "Report: $REPORT_MD"
