#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/conversation-context"
E12="$ROOT/docs/japanese-live/experiments/evidence/E12"
MODE="${1:-full}"
COMET_PYTHON="${COMET_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
REPORT_JSON="$ROOT/docs/high-quality-context-e14.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E14-previous-accepted-context.md"
LIVE_LOG="$ARTIFACTS/live-tests.log"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in development|full) ;; *) echo "usage: $0 [development|full]" >&2; exit 2 ;; esac
[[ -x "$COMET_PYTHON" ]] || { echo "COMET v2.2.7 is required at $COMET_PYTHON" >&2; exit 1; }
cd "$ROOT"

if [[ ! -f .build/debug/mlx.metallib ]]; then
  swift test --filter HighQualityConversationContextTests/testNativeContextPromptAlternatesAcceptedRolesAndKeepsCurrentUserClean
  bash Scripts/build_mlx_metallib.sh debug
fi

run_split() {
  local split="$1" output="$ARTIFACTS/$1/context.json"
  mkdir -p "$ARTIFACTS/$split"
  gzip -dc "$E12/$split-direct-protocol.json.gz" >"$ARTIFACTS/$split/baseline.json"
  WHISPERASR_RUN_CONTEXT_EXPERIMENT=1 \
  WHISPERASR_CONTEXT_SPLIT="$split" \
  WHISPERASR_CONTEXT_ALLOW_HOLDOUT="$([[ "$split" == holdout ]] && echo 1 || echo 0)" \
  WHISPERASR_CONTEXT_BASELINE="$ARTIFACTS/$split/baseline.json" \
  WHISPERASR_CONTEXT_OUTPUT="$output" \
    swift test --filter HighQualityConversationContextTests/testWritesFrozenContextCorpusWhenOptedIn
}

report() {
  python3 Scripts/report_conversation_context.py "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD" --live-log "$LIVE_LOG"
}

score() {
  local split="$1" metrics="$ARTIFACTS/metrics/$1"
  "$COMET_PYTHON" Scripts/comet_score_compat.py \
    -s "$metrics/source.ja.txt" \
    -t "$metrics/direct-no-context.en.txt" "$metrics/previous-accepted.en.txt" \
    -r "$metrics/reference.en.txt" --model Unbabel/wmt22-comet-da \
    --gpus "${COMET_GPUS:-1}" --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" >"$metrics/comet-score.raw.txt" 2>&1
}

run_split development
report
score development
report
jq -e '.gates.development | .evidenceIntegrity and .zeroTerminalHardFailures and .primaryQualityGain and .noIntegrityRegression' "$REPORT_JSON" >/dev/null
[[ "$MODE" == development ]] && { echo "Development gates passed; holdout remains untouched."; exit 0; }

run_split holdout
swift test --filter LiveCaptionTests 2>&1 | tee "$LIVE_LOG"
mkdir -p docs/japanese-live/experiments/evidence/E14
gzip -n -c "$ARTIFACTS/development/context.json" >docs/japanese-live/experiments/evidence/E14/development-context.json.gz
gzip -n -c "$ARTIFACTS/holdout/context.json" >docs/japanese-live/experiments/evidence/E14/holdout-context.json.gz
report
score holdout
gzip -n -c "$ARTIFACTS/metrics/development/comet-score.json" >docs/japanese-live/experiments/evidence/E14/development-comet-score.json.gz
gzip -n -c "$ARTIFACTS/metrics/holdout/comet-score.json" >docs/japanese-live/experiments/evidence/E14/holdout-comet-score.json.gz
cp "$LIVE_LOG" docs/japanese-live/experiments/evidence/E14/live-tests.log
report
jq -e '.promoted' "$REPORT_JSON" >/dev/null
echo "Report: $REPORT_MD"
