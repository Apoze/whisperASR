#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/metricx-reranking"
E14="$ROOT/docs/japanese-live/experiments/evidence/E14"
PROVENANCE="$ROOT/docs/metricx-24-e15.json"
POLICY="$ARTIFACTS/policy.json"
REPORT_JSON="$ROOT/docs/high-quality-metricx-e15.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E15-metricx-reranking.md"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E15"
LIVE_LOG="$ARTIFACTS/live-tests.log"
METRICX_SOURCE="$ROOT/.build/metricx-runtime/source"
METRICX_PYTHON="${METRICX_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
COMET_PYTHON="${COMET_PYTHON:-$METRICX_PYTHON}"
MODE="${1:-full}"
SOURCE_REVISION="fc4978eb064670f7cc33e93ea4f52d38396b8ae6"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in development|full) ;; *) echo "usage: $0 [development|full]" >&2; exit 2 ;; esac
[[ -x "$METRICX_PYTHON" ]] || { echo "MetricX Python runtime is missing: $METRICX_PYTHON" >&2; exit 1; }
[[ -x "$COMET_PYTHON" ]] || { echo "COMET Python runtime is missing: $COMET_PYTHON" >&2; exit 1; }
cd "$ROOT"

if [[ ! -d "$METRICX_SOURCE/.git" ]]; then
  mkdir -p "$(dirname "$METRICX_SOURCE")"
  git clone --filter=blob:none https://github.com/google-research/metricx.git "$METRICX_SOURCE"
  git -C "$METRICX_SOURCE" checkout --detach "$SOURCE_REVISION"
fi
[[ "$(git -C "$METRICX_SOURCE" rev-parse HEAD)" == "$SOURCE_REVISION" ]] || {
  echo "MetricX source revision mismatch" >&2
  exit 1
}

python3 Scripts/report_metricx_reranking.py --self-test
python3 Scripts/run_metricx_24_qe.py --self-test
PYTHONPATH="$METRICX_SOURCE" "$METRICX_PYTHON" -c \
  'import sentencepiece, torch, transformers; from metricx24.models import MT5ForRegression; print(torch.__version__, transformers.__version__)'

run_split() {
  local split="$1" artifact="$E14/$1-context.json.gz" directory="$ARTIFACTS/$1"
  python3 Scripts/report_metricx_reranking.py prepare "$split" "$artifact" "$directory"
  "$METRICX_PYTHON" Scripts/run_metricx_24_qe.py \
    --input "$directory/metricx-input.jsonl" \
    --output "$directory/metricx-scores.jsonl" \
    --runtime "$directory/metricx-runtime.json" \
    --worker-metadata "$directory/metricx-worker.json" \
    --producer-artifact "$artifact" \
    --source-root "$METRICX_SOURCE" \
    --device cpu 2>&1 | tee "$directory/metricx-run.log"
}

score_split() {
  local split="$1" metrics="$ARTIFACTS/$1/metrics"
  "$COMET_PYTHON" Scripts/comet_score_compat.py \
    -s "$metrics/source.ja.txt" \
    -t "$metrics/baseline.en.txt" "$metrics/metricx.en.txt" \
    -r "$metrics/reference.en.txt" \
    --model Unbabel/wmt22-comet-da --gpus "${COMET_GPUS:-1}" \
    --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" >"$metrics/comet-score.raw.txt" 2>&1
}

make_report() {
  python3 Scripts/report_metricx_reranking.py report \
    "$ARTIFACTS" "$PROVENANCE" "$POLICY" "$REPORT_JSON" "$REPORT_MD" "$LIVE_LOG"
}

package_split() {
  local split="$1" directory="$ARTIFACTS/$1"
  for file in pairs.json metricx-input.jsonl metricx-scores.jsonl metricx-runtime.json \
      metricx-worker.json metricx-run.log selection.json external-evaluation.json \
      selected-translation.json metricx-smoke-input.jsonl metricx-smoke-scores.jsonl \
      metricx-smoke-runtime.json metricx-smoke-worker.json \
      infrastructure-failure-transformers-4.57.6.json \
      infrastructure-failure-missing-protobuf.json \
      infrastructure-failure-protobuf-5.29.5.json; do
    [[ -f "$directory/$file" ]] && gzip -n -c "$directory/$file" >"$EVIDENCE/$split-$file.gz"
  done
  for file in comet-score.json comet-score.raw.txt; do
    [[ -f "$directory/metrics/$file" ]] \
      && gzip -n -c "$directory/metrics/$file" >"$EVIDENCE/$split-$file.gz"
  done
}

package_evidence() {
  mkdir -p "$EVIDENCE"
  cp "$PROVENANCE" "$EVIDENCE/provenance.json"
  cp "$POLICY" "$EVIDENCE/policy.json"
  cp "$ARTIFACTS/runtime-lock.txt" "$EVIDENCE/runtime-lock.txt"
  package_split development
  if [[ -d "$ARTIFACTS/holdout" ]]; then package_split holdout; fi
  if [[ -f "$LIVE_LOG" ]]; then cp "$LIVE_LOG" "$EVIDENCE/live-tests.log"; fi
  if [[ -d "$ARTIFACTS/verification" ]]; then
    if [[ -f "$ARTIFACTS/verification/implementation-verification.json" ]]; then
      cp "$ARTIFACTS/verification/implementation-verification.json" \
        "$EVIDENCE/implementation-verification.json"
    fi
    for file in swift-test-full.log swift-test-excluding-known-base-failure.log \
        swift-test-e13-control.log app-launch.log; do
      if [[ -f "$ARTIFACTS/verification/$file" ]]; then
        gzip -n -c "$ARTIFACTS/verification/$file" >"$EVIDENCE/$file.gz"
      fi
    done
  fi
}

run_split development
python3 Scripts/report_metricx_reranking.py calibrate "$ARTIFACTS/development" "$PROVENANCE" "$POLICY"
python3 Scripts/report_metricx_reranking.py apply development \
  "$E14/development-context.json.gz" \
  "docs/japanese-live/corpora/qudu2fx3ncc/manifest.json" \
  "$ARTIFACTS/development" "$POLICY"
score_split development
make_report
package_evidence
make_report

if ! jq -e '.readyForHoldout' "$REPORT_JSON" >/dev/null; then
  echo "MetricX is a development no-go; holdout remains untouched."
  exit 0
fi
[[ "$MODE" == development ]] && { echo "Development gates passed; policy frozen before holdout."; exit 0; }

run_split holdout
python3 Scripts/report_metricx_reranking.py apply holdout \
  "$E14/holdout-context.json.gz" \
  "docs/japanese-live/corpora/md62mmdz0m/manifest.json" \
  "$ARTIFACTS/holdout" "$POLICY"
score_split holdout
xcrun swift test --filter LiveCaptionTests 2>&1 | tee "$LIVE_LOG"
make_report
package_evidence
make_report
echo "Report: $REPORT_MD"
