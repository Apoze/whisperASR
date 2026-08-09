#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/high-quality/translator-bakeoff"
MODE="${1:-full}"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final|full) ;;
  *) echo "usage: $0 [development|final|full]" >&2; exit 2 ;;
esac

verify_corpus_file() {
  local directory="$1" label="$2" expected="$3" file actual
  while IFS= read -r file; do
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      printf '%s\t%s\t%s\n' "$label" "$actual" "$file"
      return
    fi
  done < <(find "$directory" -maxdepth 1 -type f -print | sort)
  echo "No $label under $directory matches $expected" >&2
  exit 1
}

mkdir -p "$ARTIFACTS"
: >"$ARTIFACTS/corpus-preflight.tsv"
for corpus in qudu2fx3ncc md62mmdz0m; do
  [[ "$corpus" == qudu2fx3ncc ]] && directory="$VIDEO_ROOT/1" || directory="$VIDEO_ROOT/2"
  manifest="$ROOT/docs/japanese-live/corpora/$corpus/manifest.json"
  verify_corpus_file "$directory" "$corpus/source-video" \
    "$(jq -er '.source.references[] | select(.label == "source-video") | .sha256' "$manifest")" \
    >>"$ARTIFACTS/corpus-preflight.tsv"
  verify_corpus_file "$directory" "$corpus/reference-archive" \
    "$(jq -er '.source.references[] | select(.label == "reference-archive") | .sha256' "$manifest")" \
    >>"$ARTIFACTS/corpus-preflight.tsv"
done

run_candidate() {
  local candidate="$1" corpus="$2"
  local output="$ARTIFACTS/$candidate/$corpus/run.json"
  mkdir -p "$(dirname "$output")"
  WHISPERASR_RUN_TRANSLATOR_BAKEOFF=1 \
  WHISPERASR_TRANSLATOR_CANDIDATE="$candidate" \
  WHISPERASR_TRANSLATOR_CORPUS="$corpus" \
  WHISPERASR_TRANSLATOR_OUTPUT="$output" \
  WHISPERASR_TRANSLATOR_ALLOW_HOLDOUT="$([[ "$corpus" == md62mmdz0m ]] && echo 1 || echo 0)" \
    swift test --skip-build \
      --filter LocalTranslatorBakeoffTests/testRealCandidateOnFrozenCorpusWhenOptedIn \
      2>&1 | tee "${output%.json}.log"
}

check_development_gates() {
  local translate="$ARTIFACTS/translategemma-12b-it-4bit/qudu2fx3ncc/run.json"
  local qwen="$ARTIFACTS/qwen3-14b-4bit/qudu2fx3ncc/run.json"
  check_artifact "$translate" translategemma-12b-it-4bit \
    f3dcfd54df14672fbcf0731086fb47a797a943ae qudu2fx3ncc
  check_artifact "$qwen" qwen3-14b-4bit \
    a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4 qudu2fx3ncc
  [[ "$(jq -r .frozenInputSHA256 "$translate")" == "$(jq -r .frozenInputSHA256 "$qwen")" ]]
  [[ "$(jq -cS .request "$translate" | shasum -a 256)" == "$(jq -cS .request "$qwen" | shasum -a 256)" ]]
}

check_artifact() {
  local artifact="$1" candidate="$2" revision="$3" corpus="$4"
  local manifest="$ROOT/docs/japanese-live/corpora/$corpus/manifest.json"
  jq -e \
    --arg candidate "$candidate" \
    --arg revision "$revision" \
    --arg corpus "$corpus" \
    --arg manifest "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg job "$(shasum -a 256 "$ROOT/Sources/HighQualityJob.swift" | awk '{print $1}')" \
    --arg runtime "$(shasum -a 256 "$ROOT/Sources/LocalMLXTranslator.swift" | awk '{print $1}')" \
    --arg test "$(shasum -a 256 "$ROOT/Tests/LocalTranslatorBakeoffTests.swift" | awk '{print $1}')" \
    --arg runner "$(shasum -a 256 "$ROOT/Scripts/run_local_translator_bakeoff.sh" | awk '{print $1}')" \
    --arg reporter "$(shasum -a 256 "$ROOT/Scripts/report_local_translator_bakeoff.py" | awk '{print $1}')" \
    '.candidate == $candidate
      and .revision == $revision
      and .runtimeVersion == "3.31.4"
      and .corpusID == $corpus
      and .manifestSHA256 == $manifest
      and .contextBudgetTokens == 2048
      and .generation == {maxTokens: 256, temperature: 0, thinking: false}
      and .implementationSHA256["Sources/HighQualityJob.swift"] == $job
      and .implementationSHA256["Sources/LocalMLXTranslator.swift"] == $runtime
      and .implementationSHA256["Tests/LocalTranslatorBakeoffTests.swift"] == $test
      and .implementationSHA256["Scripts/run_local_translator_bakeoff.sh"] == $runner
      and .implementationSHA256["Scripts/report_local_translator_bakeoff.py"] == $reporter
      and (.gates | to_entries | all(.value == true))' \
    "$artifact" >/dev/null
}

swift test --filter HighQualityLocalTranslationTests/testTranslatorCandidatesArePinnedAndShareOneFrozenPrompt

if [[ "$MODE" != final ]]; then
  run_candidate translategemma-12b-it-4bit qudu2fx3ncc
  run_candidate qwen3-14b-4bit qudu2fx3ncc
fi
check_development_gates

if [[ "$MODE" == development ]]; then
  echo "Development gates passed; holdout remains untouched."
  exit 0
fi

run_candidate translategemma-12b-it-4bit md62mmdz0m
run_candidate qwen3-14b-4bit md62mmdz0m

REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E05-local-translator-bakeoff.md"
python3 "$ROOT/Scripts/report_local_translator_bakeoff.py" \
  "$ARTIFACTS" --json "$REPORT_JSON" --markdown "$REPORT_MD"

COMET_SCORE="${COMET_SCORE:-$ROOT/.build/comet-venv/bin/comet-score}"
if [[ ! -x "$COMET_SCORE" ]]; then
  echo "COMET is required: create .build/comet-venv with unbabel-comet==2.2.7." >&2
  exit 1
fi
for corpus in qudu2fx3ncc md62mmdz0m; do
  metrics="$ARTIFACTS/metrics/$corpus"
  "$COMET_SCORE" \
    -s "$metrics/source.ja.txt" \
    -t "$metrics/translategemma-12b-it-4bit.en.txt" "$metrics/qwen3-14b-4bit.en.txt" \
    -r "$metrics/reference.en.txt" \
    --model Unbabel/wmt22-comet-da \
    --gpus 0 --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" \
    >"$metrics/comet-score.raw.txt" 2>&1
done

python3 "$ROOT/Scripts/report_local_translator_bakeoff.py" \
  "$ARTIFACTS" --json "$REPORT_JSON" --markdown "$REPORT_MD"
echo "Report: $REPORT_MD"
