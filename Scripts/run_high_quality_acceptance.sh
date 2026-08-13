#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$ROOT/.build/benchmarks/high-quality/offline-acceptance"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
MODE="${1:-full}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final|full) ;;
  *) echo "usage: $0 [development|final|full]" >&2; exit 2 ;;
esac
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls"

manifest_for() { printf '%s/docs/japanese-live/corpora/%s/manifest.json\n' "$ROOT" "$1"; }
video_directory() { [[ "$1" == qudu2fx3ncc ]] && printf '%s/1\n' "$VIDEO_ROOT" || printf '%s/2\n' "$VIDEO_ROOT"; }

resolve_corpus_file() {
  local corpus="$1" label="$2" expected file
  expected="$(jq -er --arg label "$label" '.source.references[] | select(.label == $label) | .sha256' "$(manifest_for "$corpus")")"
  while IFS= read -r file; do
    if [[ "$(shasum -a 256 "$file" | awk '{print $1}')" == "$expected" ]]; then
      printf '%s\n' "$file"
      return
    fi
  done < <(find "$(video_directory "$corpus")" -maxdepth 1 -type f -print | sort)
  echo "No $label for $corpus matches $expected" >&2
  return 1
}

verify_corpus() {
  local corpus="$1" manifest reference locator actual
  manifest="$(manifest_for "$corpus")"
  printf '%s\tsource-video\t%s\t%s\n' "$corpus" \
    "$(shasum -a 256 "$(resolve_corpus_file "$corpus" source-video)" | awk '{print $1}')" \
    "$(resolve_corpus_file "$corpus" source-video)"
  printf '%s\treference-archive\t%s\t%s\n' "$corpus" \
    "$(shasum -a 256 "$(resolve_corpus_file "$corpus" reference-archive)" | awk '{print $1}')" \
    "$(resolve_corpus_file "$corpus" reference-archive)"
  while IFS=$'\t' read -r reference locator; do
    actual="$(shasum -a 256 "$ROOT/$locator" | awk '{print $1}')"
    [[ "$actual" == "$reference" ]]
    printf '%s\tlocal-reference\t%s\t%s\n' "$corpus" "$actual" "$ROOT/$locator"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | [.sha256,.locator] | @tsv' "$manifest")
}

source_check() {
  local corpus="$1" log
  log="$ARTIFACTS/controls/source-$corpus.log"
  WHISPERASR_RUN_HIGH_QUALITY_SOURCE_CHECK=1 \
  WHISPERASR_ACCEPTANCE_CORPUS="$corpus" \
  WHISPERASR_ACCEPTANCE_SOURCE="$(resolve_corpus_file "$corpus" source-video)" \
  WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$(resolve_corpus_file "$corpus" reference-archive)" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testFrozenSourceDecodesThroughTheProductLoaderWhenOptedIn \
      2>&1 | tee "$log"
}

run_real_cancellation_control() {
  local ffmpeg fixture digest log="$ARTIFACTS/controls/real-cancellation.log"
  ffmpeg="$(command -v ffmpeg)"
  fixture="$ARTIFACTS/controls/dev-30s.wav"
  "$ffmpeg" -hide_banner -loglevel error -y \
    -i "$(resolve_corpus_file qudu2fx3ncc source-video)" -t 30 -vn -ac 1 -ar 16000 -c:a pcm_s16le "$fixture"
  digest="$(shasum -a 256 "$fixture" | awk '{print $1}')"
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE="$fixture" \
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256="$digest" \
    xcrun swift test --skip-build \
      --filter HighQualityJobTests/testRealOfflineBackendFunctionalGateWhenOptedIn \
      2>&1 | tee "$log"
}

run_controls() {
  xcrun swift build
  xcrun swift test --skip-build \
    --filter 'HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts|HighQualityJobTests/testClassifiesSourcePreparationASRAndExportFailuresAtThePrincipalInterface|HighQualityJobTests/testCancellationIsSafeForEveryOfflineBackend|HighQualityJobTests/testPeakMemoryIsSampledDuringASRStages|HeavyweightModelGateTests|HighQualityLocalTranslationTests'
  python3 Scripts/report_high_quality_acceptance.py --self-test
  source_check qudu2fx3ncc
  run_real_cancellation_control
  jq -n '{build:true, sourceDecode:true, referenceIntegrity:true, realCancellation:true, failureClassification:true, artifactParsing:true}' \
    >"$ARTIFACTS/controls.json"
}

job_id() {
  case "$1/$2" in
    qwen-ja/qudu2fx3ncc) echo 44000001-0000-4000-8000-000000000001 ;;
    parakeet-ja/qudu2fx3ncc) echo 44000001-0000-4000-8000-000000000002 ;;
    whisperkit/qudu2fx3ncc) echo 44000001-0000-4000-8000-000000000003 ;;
    qwen-ja/md62mmdz0m) echo 44000002-0000-4000-8000-000000000001 ;;
    parakeet-ja/md62mmdz0m) echo 44000002-0000-4000-8000-000000000002 ;;
    whisperkit/md62mmdz0m) echo 44000002-0000-4000-8000-000000000003 ;;
  esac
}

model_pin() {
  case "$1" in
    qwen-ja) echo 'ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit|7c70d18cb650655d32eafb952a74a49c6a3caad0' ;;
    parakeet-ja) echo 'FluidInference/parakeet-0.6b-ja-coreml|2952296ff1da4a6d6a7aec545e226367db80c612' ;;
    whisperkit) echo 'argmaxinc/whisperkit-coreml/openai_whisper-large-v3|97a5bf9bbc74c7d9c12c755d04dea59e672e3808' ;;
  esac
}

write_metadata() {
  local backend="$1" corpus="$2" directory="$ARTIFACTS/$1/$2" manifest source archive pin model revision implementation path digest
  manifest="$(manifest_for "$corpus")"
  source="$(resolve_corpus_file "$corpus" source-video)"
  archive="$(resolve_corpus_file "$corpus" reference-archive)"
  pin="$(model_pin "$backend")"; model="${pin%%|*}"; revision="${pin#*|}"
  implementation='{}'
  for path in \
    Sources/HighQualityJob.swift Sources/HeavyweightModelGate.swift \
    Sources/HighQualityForcedAlignerRuntime.swift Sources/HighQualitySpeakerKitRuntime.swift \
    Sources/LocalMLXTranslator.swift Tests/HighQualityAcceptanceTests.swift \
    Scripts/run_high_quality_acceptance.sh Scripts/report_high_quality_acceptance.py \
    Scripts/comet_score_compat.py; do
    digest="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    implementation="$(jq -c --arg path "$path" --arg digest "$digest" '. + {($path):$digest}' <<<"$implementation")"
  done
  mkdir -p "$directory/jobs"
  jq -n \
    --arg backend "$backend" --arg corpus "$corpus" \
    --arg role "$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo untouched-final-holdout)" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg archive "$archive" --arg archiveHash "$(shasum -a 256 "$archive" | awk '{print $1}')" \
    --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg commit "$(git rev-parse HEAD)" --arg model "$model" --arg revision "$revision" \
    --argjson implementation "$implementation" \
    '{schemaVersion:1, backend:$backend, corpusID:$corpus, corpusRole:$role,
      sourcePath:$source, sourceSHA256:$sourceHash,
      referenceArchivePath:$archive, referenceArchiveSHA256:$archiveHash,
      manifestSHA256:$manifestHash, commit:$commit,
      ASRModel:{modelID:$model, revision:$revision},
      fixedModels:{forcedAligner:{modelID:"mlx-community/Qwen3-ForcedAligner-0.6B-4bit",revision:"2f652af86ae0c73fe189b9429225c908ce4bf020"},
        speakerKit:{modelID:"argmaxinc/speakerkit-coreml",revision:"86ec9c929b52208b6656eb6a6361ed0d822a1f78"},
        translator:{modelID:"mlx-community/translategemma-12b-it-4bit",revision:"f3dcfd54df14672fbcf0731086fb47a797a943ae"}},
      implementationSHA256:$implementation}' >"$directory/run-meta.json"
}

finalize_metadata() {
  local backend="$1" corpus="$2" directory="$ARTIFACTS/$1/$2" job temporary
  job="$directory/jobs/$(job_id "$backend" "$corpus")"
  temporary="$directory/run-meta.updated.json"
  jq \
    --arg manifest "$(shasum -a 256 "$job/manifest.json" | awk '{print $1}')" \
    --arg raw "$(shasum -a 256 "$job/raw-asr.json" | awk '{print $1}')" \
    '. + {rawArtifactSHA256:{"manifest.json":$manifest,"raw-asr.json":$raw}}' \
    "$directory/run-meta.json" >"$temporary"
  mv "$temporary" "$directory/run-meta.json"
}

check_candidate() {
  local backend="$1" corpus="$2" job="$ARTIFACTS/$1/$2/jobs/$(job_id "$1" "$2")" manifest="$(manifest_for "$2")"
  jq -e --arg backend "$backend" --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" \
    '.status == "completed" and .selectedBackend == $backend and .failures == []' "$job/manifest.json" >/dev/null
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" \
    '.sampleCount == $samples and (.rawASR | length > 0)
      and .alignment.validationDiagnostics == [] and (.alignment.chunks | length > 0)
      and .diarization.validationDiagnostics == [] and (.diarization.rawSpans | length > 0)
      and .translation.model == "mlx-community/translategemma-12b-it-4bit"
      and .translation.validationFailures == []
      and ([.modelEvents[].kind] | index("guard-failed") | not)' "$job/raw-asr.json" >/dev/null
  jq empty "$job/manifest.json" "$job/raw-asr.json"
}

diagnose_failure() {
  local backend="$1" corpus="$2" diagnostic="$ARTIFACTS/$1/$2/infrastructure-diagnostics.log"
  {
    echo "candidate=$backend corpus=$corpus"
    echo "Rerunning build, source decode, reference integrity, model preparation/cancellation and artifact parsing controls."
    xcrun swift build
    source_check "$corpus"
    verify_corpus "$corpus"
    run_real_cancellation_control
    find "$ARTIFACTS/$backend/$corpus/jobs" -name '*.json' -type f -exec jq empty {} \;
  } >"$diagnostic" 2>&1 || true
  echo "Candidate run failed; infrastructure diagnostics: $diagnostic" >&2
}

run_candidate() {
  local backend="$1" corpus="$2" directory="$ARTIFACTS/$1/$2" job log
  job="$directory/jobs/$(job_id "$backend" "$corpus")"
  log="$directory/run.log"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' "$job/manifest.json" >/dev/null 2>&1; then
    echo "Reusing completed raw run: $backend/$corpus"
    check_candidate "$backend" "$corpus"
    return
  fi
  if [[ -e "$job" ]]; then
    echo "Existing incomplete run retained at $job; move it aside before retrying." >&2
    return 1
  fi
  write_metadata "$backend" "$corpus"
  if ! WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE=1 \
    WHISPERASR_ACCEPTANCE_BACKEND="$backend" \
    WHISPERASR_ACCEPTANCE_CORPUS="$corpus" \
    WHISPERASR_ACCEPTANCE_SOURCE="$(resolve_corpus_file "$corpus" source-video)" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$(resolve_corpus_file "$corpus" reference-archive)" \
    WHISPERASR_ACCEPTANCE_JOB_ID="$(job_id "$backend" "$corpus")" \
    WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$directory/jobs" \
    WHISPERASR_ACCEPTANCE_ALLOW_HOLDOUT="$([[ "$corpus" == md62mmdz0m ]] && echo 1 || echo 0)" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn \
        2>&1 | tee "$log"; then
    diagnose_failure "$backend" "$corpus"
    return 1
  fi
  check_candidate "$backend" "$corpus"
  finalize_metadata "$backend" "$corpus"
}

: >"$ARTIFACTS/corpus-preflight.tsv"
verify_corpus qudu2fx3ncc >>"$ARTIFACTS/corpus-preflight.tsv"
verify_corpus md62mmdz0m >>"$ARTIFACTS/corpus-preflight.tsv"

if [[ "$MODE" != final ]]; then
  run_controls
  for backend in qwen-ja parakeet-ja whisperkit; do run_candidate "$backend" qudu2fx3ncc; done
fi
for backend in qwen-ja parakeet-ja whisperkit; do check_candidate "$backend" qudu2fx3ncc; done

if [[ "$MODE" == development ]]; then
  echo "Development gates passed; holdout scores remain untouched."
  exit 0
fi

source_check md62mmdz0m
for backend in qwen-ja parakeet-ja whisperkit; do run_candidate "$backend" md62mmdz0m; done
for backend in qwen-ja parakeet-ja whisperkit; do check_candidate "$backend" md62mmdz0m; done

REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E06-offline-high-quality-acceptance.md"
python3 Scripts/report_high_quality_acceptance.py "$ARTIFACTS" --json "$REPORT_JSON" --markdown "$REPORT_MD"

COMET_PYTHON="${COMET_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
[[ -x "$COMET_PYTHON" ]] || { echo "COMET v2.2.7 is required at $COMET_PYTHON" >&2; exit 1; }
for corpus in qudu2fx3ncc md62mmdz0m; do
  metrics="$ARTIFACTS/metrics/$corpus"
  "$COMET_PYTHON" Scripts/comet_score_compat.py -s "$metrics/source.ja.txt" \
    -t "$metrics/qwen-ja.en.txt" "$metrics/parakeet-ja.en.txt" "$metrics/whisperkit.en.txt" \
    -r "$metrics/reference.en.txt" --model Unbabel/wmt22-comet-da \
    --gpus "${COMET_GPUS:-1}" --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" >"$metrics/comet-score.raw.txt" 2>&1
done
python3 Scripts/report_high_quality_acceptance.py "$ARTIFACTS" --json "$REPORT_JSON" --markdown "$REPORT_MD"
jq -e 'all(.rows[]; .english.COMET != null and (.gates | to_entries | all(.value == true)))' "$REPORT_JSON" >/dev/null
echo "Selected ASR: $(jq -r .selectedProductDefault "$REPORT_JSON")"
echo "Report: $REPORT_MD"
