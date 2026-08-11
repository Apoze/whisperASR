#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/high-quality/translator-bakeoff"
UPSTREAM="$ROOT/docs/japanese-live/experiments/evidence/E17-speaker-count"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
MODE="${1:-development}"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E21-translategemma-4b-vs-12b.md"
COMET_PYTHON="${COMET_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

case "$MODE" in
  development) corpus=qudu2fx3ncc; role=development ;;
  holdout) corpus=md62mmdz0m; role=holdout ;;
  *) echo "usage: $0 [development|holdout]" >&2; exit 2 ;;
esac

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

verify_corpus_file() {
  local directory="$1" label="$2" expected="$3" file
  while IFS= read -r file; do
    if [[ "$(sha256 "$file")" == "$expected" ]]; then
      printf '%s\t%s\t%s\n' "$label" "$expected" "$file"
      return
    fi
  done < <(find "$directory" -maxdepth 1 -type f -print | sort)
  echo "No $label under $directory matches $expected" >&2
  exit 1
}

prepare_upstream() {
  local split="$1" id="$2" source output
  source="$UPSTREAM/$split-automatic-raw-asr.json.gz"
  output="$ARTIFACTS/frozen/$id/raw-asr.json"
  mkdir -p "$(dirname "$output")"
  gzip -dc "$source" >"$output"
  jq -e --arg id "$id" '
    .model == {
      backend:"qwen-ja",
      modelID:"ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit",
      revision:"7c70d18cb650655d32eafb952a74a49c6a3caad0"
    }
    and .alignment.modelID == "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
    and .alignment.revision == "2f652af86ae0c73fe189b9429225c908ce4bf020"
    and .diarization.modelID == "argmaxinc/speakerkit-coreml"
    and .diarization.revision == "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
    and .diarization.speakerCountPolicy == {mode:"automatic"}
    and .diarization.useExclusiveReconciliation == false
    and .diarization.configuration == null
    and (.translation.request.turns | length) == (if $id == "qudu2fx3ncc" then 313 else 273 end)
  ' "$output" >/dev/null
  printf '%s\t%s\t%s\t%s\n' "$id/upstream-gzip" "$(sha256 "$source")" \
    "$source" "historical-speakerkit-configuration=null" >>"$ARTIFACTS/provenance.tsv"
  printf '%s\t%s\t%s\n' "$id/frozen-json" "$(sha256 "$output")" "$output" \
    >>"$ARTIFACTS/provenance.tsv"
}

verify_model() {
  local candidate="$1" revision cache snapshot file expected
  cache="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
  case "$candidate" in
    translategemma-4b-it-4bit)
      revision=5788ec08c047f3f2e17808101b8d9566ac930d58
      snapshot="$cache/models--mlx-community--translategemma-4b-it-4bit/snapshots/$revision"
      set -- "model.safetensors:113acb0c29997a3015af84bec2c8f967cb7b15f8959d1c26b9628b921e324c40"
      ;;
    translategemma-12b-it-4bit)
      revision=f3dcfd54df14672fbcf0731086fb47a797a943ae
      snapshot="$cache/models--mlx-community--translategemma-12b-it-4bit/snapshots/$revision"
      set -- \
        "model-00001-of-00002.safetensors:bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af" \
        "model-00002-of-00002.safetensors:c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89"
      ;;
  esac
  for file in "$@"; do
    expected="${file#*:}"; file="${file%%:*}"
    [[ -f "$snapshot/$file" ]] || { echo "Missing cached model file: $snapshot/$file" >&2; exit 1; }
    [[ "$(sha256 "$snapshot/$file")" == "$expected" ]] \
      || { echo "Model hash mismatch: $candidate/$file" >&2; exit 1; }
    printf '%s\t%s\t%s\t%s\n' "$candidate" "$revision" "$expected" "$snapshot/$file" \
      >>"$ARTIFACTS/model-provenance.tsv"
  done
}

check_worker_exit() {
  local raw="$1" pid
  pid="$(jq -er '.translation.worker.processIdentifier' "$raw")"
  jq -e '
    .translation.worker.exitStatus == 0
    and .translation.worker.forcedTermination == false
    and ([.translation.worker.pressureTransitions[] | select(.level == "critical")] | length) == 0
    and ([.failures[] | select(.stage != "translation")] | length) == 0
  ' "$raw" >/dev/null
  if kill -0 "$pid" 2>/dev/null; then
    echo "Translation worker PID $pid still exists after handoff" >&2
    exit 1
  fi
}

run_candidate() {
  local candidate="$1" id="$2" split="$3" job_id output raw log status=0
  if [[ -f "$ARTIFACTS/$candidate/$id/job-id.txt" ]]; then
    job_id="$(<"$ARTIFACTS/$candidate/$id/job-id.txt")"
    raw="$ARTIFACTS/$candidate/$id/jobs/$job_id/raw-asr.json"
    [[ -f "$raw" ]] || { echo "Retained job is missing evidence: $raw" >&2; exit 1; }
    check_worker_exit "$raw"
    echo "Reusing retained $candidate result: $raw"
    return
  fi
  job_id="$(uuidgen)"
  output="$ARTIFACTS/$candidate/$id/jobs"
  raw="$output/$job_id/raw-asr.json"
  log="$ARTIFACTS/$candidate/$id/run.log"
  mkdir -p "$output"
  printf '%s\n' "$job_id" >"$ARTIFACTS/$candidate/$id/job-id.txt"
  WHISPERASR_RUN_SEMANTIC_TRANSLATION_EXPERIMENT=1 \
  WHISPERASR_SEMANTIC_TRANSLATION_EVIDENCE="$ARTIFACTS/frozen/$id/raw-asr.json" \
  WHISPERASR_SEMANTIC_TRANSLATION_OUTPUT="$output" \
  WHISPERASR_TRANSLATOR_CANDIDATE="$candidate" \
  WHISPERASR_TRANSLATOR_CORPUS="$id" \
  WHISPERASR_TRANSLATOR_JOB_ID="$job_id" \
  WHISPERASR_TRANSLATOR_ALLOW_HOLDOUT="$([[ "$split" == holdout ]] && echo 1 || echo 0)" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testFrozenSemanticTranslationExperimentWhenOptedIn \
      2>&1 | tee "$log" || status=$?
  [[ -f "$raw" ]] || { echo "Missing product evidence: $raw" >&2; exit 1; }
  check_worker_exit "$raw"
  if [[ "$status" != 0 ]]; then
    jq -e '
      (.failures | length) == 1
      and .failures[0].stage == "translation"
      and (.failures[0].message | contains("failed validation twice"))
    ' "$raw" >/dev/null || return "$status"
    echo "Retained product translation-quality rejection for $candidate"
  fi
}

check_pair() {
  local id="$1" four twelve
  four="$ARTIFACTS/translategemma-4b-it-4bit/$id/jobs/$(<"$ARTIFACTS/translategemma-4b-it-4bit/$id/job-id.txt")/raw-asr.json"
  twelve="$ARTIFACTS/translategemma-12b-it-4bit/$id/jobs/$(<"$ARTIFACTS/translategemma-12b-it-4bit/$id/job-id.txt")/raw-asr.json"
  [[ "$(jq -cS '.translation.request | del(.source.modifiedAt)' "$four" | shasum -a 256)" \
      == "$(jq -cS '.translation.request | del(.source.modifiedAt)' "$twelve" | shasum -a 256)" ]]
  [[ "$(jq -cS '{model,rawASR,alignment:(.alignment|del(.worker)),diarization:(.diarization|del(.worker))}' "$four" | shasum -a 256)" \
      == "$(jq -cS '{model,rawASR,alignment:(.alignment|del(.worker)),diarization:(.diarization|del(.worker))}' "$twelve" | shasum -a 256)" ]]
}

report() {
  python3 "$ROOT/Scripts/report_local_translator_bakeoff.py" "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
}

score_comet() {
  local id="$1" metrics pid status gpus="${COMET_GPUS:-1}"
  metrics="$ARTIFACTS/metrics/$id"
  [[ -x "$COMET_PYTHON" ]] || {
    COMET_PYTHON=/Users/maz/Documents/projets/whisperASR/.build/comet-venv/bin/python
  }
  [[ -x "$COMET_PYTHON" ]] || { echo "Local unbabel-comet==2.2.7 environment is required." >&2; exit 1; }
  [[ "$($COMET_PYTHON -c 'import importlib.metadata as m; print(m.version("unbabel-comet"))')" == 2.2.7 ]]
  COMET_REQUESTED_GPUS="$gpus" "$COMET_PYTHON" -c '
import json, os, torch
print(json.dumps({
    "requestedGpus": int(os.environ["COMET_REQUESTED_GPUS"]),
    "expectedDevice": "mps",
    "mpsBuilt": torch.backends.mps.is_built(),
    "mpsAvailable": torch.backends.mps.is_available(),
}))
' >"$metrics/comet-device.json"
  jq -e '.requestedGpus == 1 and .expectedDevice == "mps" and .mpsBuilt and .mpsAvailable' \
    "$metrics/comet-device.json" >/dev/null
  printf '%s\n' "Scripts/comet_score_compat.py --gpus $gpus --num_workers 1" \
    >"$metrics/comet-command.txt"
  /usr/bin/memory_pressure -Q >"$metrics/memory-pressure-before.txt"
  /usr/sbin/sysctl vm.swapusage >"$metrics/swap-before.txt"
  /usr/bin/time -lp -o "$metrics/comet-time.txt" \
    "$COMET_PYTHON" "$ROOT/Scripts/comet_score_compat.py" \
      -s "$metrics/source.ja.txt" \
      -t "$metrics/translategemma-12b-it-4bit.en.txt" \
         "$metrics/translategemma-4b-it-4bit.en.txt" \
      -r "$metrics/reference.en.txt" \
      --model Unbabel/wmt22-comet-da --gpus "$gpus" --batch_size 8 --num_workers 1 \
      --disable_cache --quiet --to_json "$metrics/comet-score.json" \
      >"$metrics/comet-score.raw.txt" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$metrics/comet-pid.txt"
  status=0; wait "$pid" || status=$?
  /usr/bin/memory_pressure -Q >"$metrics/memory-pressure-after.txt"
  /usr/sbin/sysctl vm.swapusage >"$metrics/swap-after.txt"
  [[ "$status" == 0 ]] || return "$status"
  ! kill -0 "$pid" 2>/dev/null
}

mkdir -p "$ARTIFACTS"
if [[ "$MODE" == development ]]; then
  : >"$ARTIFACTS/provenance.tsv"
  : >"$ARTIFACTS/model-provenance.tsv"
else
  touch "$ARTIFACTS/provenance.tsv" "$ARTIFACTS/model-provenance.tsv"
fi
printf 'git-head\t%s\n' "$(git -C "$ROOT" rev-parse HEAD)" >>"$ARTIFACTS/provenance.tsv"
prepare_upstream "$role" "$corpus"
manifest="$ROOT/docs/japanese-live/corpora/$corpus/manifest.json"
directory="$VIDEO_ROOT/$([[ "$corpus" == qudu2fx3ncc ]] && echo 1 || echo 2)"
verify_corpus_file "$directory" "$corpus/source-video" \
  "$(jq -er '.source.references[] | select(.label == "source-video") | .sha256' "$manifest")" \
  >>"$ARTIFACTS/provenance.tsv"
verify_corpus_file "$directory" "$corpus/reference-archive" \
  "$(jq -er '.source.references[] | select(.label == "reference-archive") | .sha256' "$manifest")" \
  >>"$ARTIFACTS/provenance.tsv"
verify_model translategemma-4b-it-4bit
verify_model translategemma-12b-it-4bit
xcrun swift build
"$ROOT/Scripts/build_mlx_metallib.sh" debug
bin_path="$(xcrun swift build --show-bin-path)"
[[ -x "$bin_path/WhisperASR" ]] || { echo "Missing child executable: $bin_path/WhisperASR" >&2; exit 1; }
[[ -s "$bin_path/mlx.metallib" ]] || { echo "Missing child metallib: $bin_path/mlx.metallib" >&2; exit 1; }
printf 'child-metallib\t%s\t%s\n' "$(sha256 "$bin_path/mlx.metallib")" \
  "$bin_path/mlx.metallib" >>"$ARTIFACTS/provenance.tsv"
{
  printf 'git-head\t%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
  printf 'worker-executable\t%s\n' "$(sha256 "$bin_path/WhisperASR")"
  printf 'runner\t%s\n' "$(sha256 "$ROOT/Scripts/run_local_translator_bakeoff.sh")"
  printf 'reporter\t%s\n' "$(sha256 "$ROOT/Scripts/report_local_translator_bakeoff.py")"
  printf 'acceptance-test\t%s\n' "$(sha256 "$ROOT/Tests/HighQualityAcceptanceTests.swift")"
  printf 'comet-wrapper\t%s\n' "$(sha256 "$ROOT/Scripts/comet_score_compat.py")"
  printf 'child-metallib\t%s\n' "$(sha256 "$bin_path/mlx.metallib")"
} >"$ARTIFACTS/implementation-provenance.tsv"

if [[ "$MODE" == holdout ]]; then
  jq -e '.gates.development == true' "$REPORT_JSON" >/dev/null \
    || { echo "Development gates must pass before opening the holdout." >&2; exit 1; }
fi

run_candidate translategemma-4b-it-4bit "$corpus" "$role"
run_candidate translategemma-12b-it-4bit "$corpus" "$role"
check_pair "$corpus"
report
score_comet "$corpus"
report
jq -e --arg role "$role" '.gates[$role] == true' "$REPORT_JSON" >/dev/null
echo "Report: $REPORT_MD"
