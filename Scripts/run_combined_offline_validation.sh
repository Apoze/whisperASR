#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${WHISPERASR_COMBINED_ROOT:-$ROOT/.build/benchmarks/combined-offline-validation}"
BASELINE_ROOT="${WHISPERASR_FROZEN_BASELINE_ROOT:-/Users/maz/Documents/projets/whisperASR/.build/benchmarks/high-quality/offline-acceptance}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
MODE="${1:-full}"
REPORT_JSON="$ROOT/docs/high-quality-combined-e19.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E19-combined-offline-validation.md"
LIVE_LOG="$ARTIFACTS/live-tests.log"
DEFAULT_COMET_PYTHON="$ROOT/.build/comet-venv/bin/python"
[[ -x "$DEFAULT_COMET_PYTHON" ]] || \
  DEFAULT_COMET_PYTHON="/Users/maz/Documents/projets/whisperASR/.build/comet-venv/bin/python"
COMET_PYTHON="${COMET_PYTHON:-$DEFAULT_COMET_PYTHON}"
QWEN_WEIGHT="${WHISPERASR_QWEN_WEIGHT:-/Users/maz/Library/Caches/qwen3-speech/models/ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit/model.safetensors}"
ALIGNER_WEIGHT="${WHISPERASR_ALIGNER_WEIGHT:-/Users/maz/.cache/huggingface/hub/models--mlx-community--Qwen3-ForcedAligner-0.6B-4bit/snapshots/2f652af86ae0c73fe189b9429225c908ce4bf020/model.safetensors}"
TRANSLATOR_ROOT="${WHISPERASR_TRANSLATOR_ROOT:-/Users/maz/.cache/huggingface/hub/models--mlx-community--translategemma-12b-it-4bit/snapshots/f3dcfd54df14672fbcf0731086fb47a797a943ae}"
SPEAKERKIT_ROOT="${WHISPERASR_SPEAKERKIT_ROOT:-/Users/maz/Documents/huggingface/models/argmaxinc/speakerkit-coreml}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in development|final|full) ;; *) echo "usage: $0 [development|final|full]" >&2; exit 2 ;; esac
[[ "${BENCHMARK_SLOT_GRANTED:-}" == "62" ]] || {
  echo "Refusing heavyweight #62 run without BENCHMARK_SLOT_GRANTED=62" >&2
  exit 2
}
[[ -x "$COMET_PYTHON" ]] || { echo "COMET v2.2.7 is required at $COMET_PYTHON" >&2; exit 1; }
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls"

manifest_for() { printf '%s/docs/japanese-live/corpora/%s/manifest.json\n' "$ROOT" "$1"; }
video_directory() { [[ "$1" == qudu2fx3ncc ]] && printf '%s/1\n' "$VIDEO_ROOT" || printf '%s/2\n' "$VIDEO_ROOT"; }
job_id() { [[ "$1" == qudu2fx3ncc ]] && echo 62000001-0000-4000-8000-000000000001 || echo 62000002-0000-4000-8000-000000000001; }

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
  for reference in source-video reference-archive; do
    locator="$(resolve_corpus_file "$corpus" "$reference")"
    printf '%s\t%s\t%s\t%s\n' "$corpus" "$reference" \
      "$(shasum -a 256 "$locator" | awk '{print $1}')" "$locator"
  done
  while IFS=$'\t' read -r reference locator; do
    actual="$(shasum -a 256 "$ROOT/$locator" | awk '{print $1}')"
    [[ "$actual" == "$reference" ]]
    printf '%s\tlocal-reference\t%s\t%s\n' "$corpus" "$actual" "$ROOT/$locator"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | [.sha256,.locator] | @tsv' "$manifest")
}

prepare_local_references() {
  local corpus locator source destination
  for corpus in qudu2fx3ncc md62mmdz0m; do
    while IFS= read -r locator; do
      destination="$ROOT/$locator"
      [[ -f "$destination" ]] && continue
      source="$FROZEN_REPO/$locator"
      [[ -f "$source" ]] || { echo "Missing frozen local reference: $source" >&2; return 1; }
      mkdir -p "$(dirname "$destination")"
      ln -s "$source" "$destination"
    done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | .locator' "$(manifest_for "$corpus")")
  done
}

baseline_job() {
  find "$BASELINE_ROOT/qwen-ja/$1/jobs" -mindepth 1 -maxdepth 1 -type d -print
}

verify_baseline() {
  local corpus="$1" job metadata
  job="$(baseline_job "$corpus")"
  [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]]
  metadata="$BASELINE_ROOT/qwen-ja/$corpus/run-meta.json"
  jq -e --arg manifest "$(shasum -a 256 "$job/manifest.json" | awk '{print $1}')" \
    --arg raw "$(shasum -a 256 "$job/raw-asr.json" | awk '{print $1}')" \
    '.rawArtifactSHA256 == {"manifest.json":$manifest,"raw-asr.json":$raw}' "$metadata" >/dev/null
}

source_check() {
  local corpus="$1"
  WHISPERASR_RUN_HIGH_QUALITY_SOURCE_CHECK=1 \
  WHISPERASR_ACCEPTANCE_CORPUS="$corpus" \
  WHISPERASR_ACCEPTANCE_SOURCE="$(resolve_corpus_file "$corpus" source-video)" \
  WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$(resolve_corpus_file "$corpus" reference-archive)" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testFrozenSourceDecodesThroughTheProductLoaderWhenOptedIn
}

run_real_cancellation_control() {
  local fixture="$ARTIFACTS/controls/dev-30s.wav" digest
  ffmpeg -hide_banner -loglevel error -y -i "$(resolve_corpus_file qudu2fx3ncc source-video)" \
    -t 30 -vn -ac 1 -ar 16000 -c:a pcm_s16le "$fixture"
  digest="$(shasum -a 256 "$fixture" | awk '{print $1}')"
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE="$fixture" \
  WHISPERASR_HIGH_QUALITY_ASR_FIXTURE_SHA256="$digest" \
    xcrun swift test --skip-build \
      --filter HighQualityJobTests/testRealOfflineBackendFunctionalGateWhenOptedIn
}

run_controls() {
  xcrun swift test \
    --filter 'HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts|HighQualityJobTests/testClassifiesSourcePreparationASRAndExportFailuresAtThePrincipalInterface|HighQualityJobTests/testCancellationIsSafeForEveryOfflineBackend|HighQualityJobTests/testPeakMemoryIsSampledDuringASRStages|HeavyweightModelGateTests|HighQualityLocalTranslationTests|HighQualityConversationContextTests' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  [[ -f .build/debug/mlx.metallib ]] || bash Scripts/build_mlx_metallib.sh debug
  python3 Scripts/report_combined_offline_validation.py --self-test
  source_check qudu2fx3ncc 2>&1 | tee "$ARTIFACTS/controls/source-qudu2fx3ncc.log"
  source_check md62mmdz0m 2>&1 | tee "$ARTIFACTS/controls/source-md62mmdz0m.log"
  run_real_cancellation_control 2>&1 | tee "$ARTIFACTS/controls/real-cancellation.log"
  jq -n '{build:true,sourceDecode:true,referenceIntegrity:true,modelPreparation:true,
    realCancellation:true,failureClassification:true,artifactParsing:true,
    selectableBackends:true,paidAPIAbsent:true}' >"$ARTIFACTS/controls.json"
}

candidate_selection() {
  PYTHONPATH=Scripts python3 - <<'PY'
import json
from report_combined_offline_validation import decision_manifest
print(json.dumps(decision_manifest(), ensure_ascii=False))
PY
}

append_weight_provenance() {
  local output="$1" model="$2" revision="$3" file="$4" path="$5" expected="$6"
  local observed temporary size
  [[ -f "$path" ]] || { echo "Missing model weight: $path" >&2; return 1; }
  observed="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$observed" == "$expected" ]] || {
    echo "Model weight hash mismatch: $path ($observed != $expected)" >&2
    return 1
  }
  size="$(stat -f %z "$path")"
  temporary="$output.updated"
  jq --arg model "$model" --arg revision "$revision" --arg file "$file" \
    --arg path "$path" --arg hash "$observed" --argjson size "$size" \
    '.weights += [{modelID:$model,revision:$revision,file:$file,
      sourcePath:$path,sizeBytes:$size,sha256:$hash}]' "$output" >"$temporary"
  mv "$temporary" "$output"
}

write_model_provenance() {
  local output="$ARTIFACTS/model-provenance.json"
  jq -n '{schemaVersion:1,weights:[]}' >"$output"
  append_weight_provenance "$output" \
    'ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit' \
    '7c70d18cb650655d32eafb952a74a49c6a3caad0' 'model.safetensors' "$QWEN_WEIGHT" \
    'bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954'
  append_weight_provenance "$output" \
    'mlx-community/Qwen3-ForcedAligner-0.6B-4bit' \
    '2f652af86ae0c73fe189b9429225c908ce4bf020' 'model.safetensors' "$ALIGNER_WEIGHT" \
    '630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c'
  append_weight_provenance "$output" 'argmaxinc/speakerkit-coreml' \
    '86ec9c929b52208b6656eb6a6361ed0d822a1f78' 'segmenter/W8A16/weight.bin' \
    "$SPEAKERKIT_ROOT/speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/weights/weight.bin" \
    '75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4'
  append_weight_provenance "$output" 'argmaxinc/speakerkit-coreml' \
    '86ec9c929b52208b6656eb6a6361ed0d822a1f78' 'embedder/W8A16/weight.bin' \
    "$SPEAKERKIT_ROOT/speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/weights/weight.bin" \
    'a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795'
  append_weight_provenance "$output" 'argmaxinc/speakerkit-coreml' \
    '86ec9c929b52208b6656eb6a6361ed0d822a1f78' \
    'embedder-preprocessor/W8A16/weight.bin' \
    "$SPEAKERKIT_ROOT/speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/weights/weight.bin" \
    '5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89'
  append_weight_provenance "$output" 'argmaxinc/speakerkit-coreml' \
    '86ec9c929b52208b6656eb6a6361ed0d822a1f78' 'clusterer/W32A32/weight.bin' \
    "$SPEAKERKIT_ROOT/speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/weights/weight.bin" \
    'a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced'
  append_weight_provenance "$output" \
    'mlx-community/translategemma-12b-it-4bit' \
    'f3dcfd54df14672fbcf0731086fb47a797a943ae' \
    'model-00001-of-00002.safetensors' "$TRANSLATOR_ROOT/model-00001-of-00002.safetensors" \
    'bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af'
  append_weight_provenance "$output" \
    'mlx-community/translategemma-12b-it-4bit' \
    'f3dcfd54df14672fbcf0731086fb47a797a943ae' \
    'model-00002-of-00002.safetensors' "$TRANSLATOR_ROOT/model-00002-of-00002.safetensors" \
    'c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89'
}

write_metadata() {
  local corpus="$1" directory="$ARTIFACTS/qwen-ja/$corpus" manifest source archive implementation path digest
  manifest="$(manifest_for "$corpus")"
  source="$(resolve_corpus_file "$corpus" source-video)"
  archive="$(resolve_corpus_file "$corpus" reference-archive)"
  implementation='{}'
  for path in Sources/HighQualityJob.swift Sources/HighQualityConversationContext.swift \
    Sources/HeavyweightModelGate.swift \
    Sources/HighQualityForcedAlignerRuntime.swift Sources/HighQualitySpeakerKitRuntime.swift \
    Sources/LocalMLXTranslator.swift Tests/HeavyweightModelGateTests.swift \
    Tests/HighQualityJobTests.swift Tests/HighQualityLocalTranslationTests.swift \
    Tests/HighQualityAcceptanceTests.swift \
    Scripts/run_combined_offline_validation.sh Scripts/report_combined_offline_validation.py; do
    digest="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    implementation="$(jq -c --arg path "$path" --arg digest "$digest" '. + {($path):$digest}' <<<"$implementation")"
  done
  mkdir -p "$directory/jobs"
  jq -n --arg corpus "$corpus" \
    --arg role "$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo untouched-channel-separated-holdout)" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg archive "$archive" --arg archiveHash "$(shasum -a 256 "$archive" | awk '{print $1}')" \
    --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg commit "$(git rev-parse HEAD)" --arg baselineRoot "$BASELINE_ROOT" \
    --argjson implementation "$implementation" --argjson selection "$(candidate_selection)" \
    '{schemaVersion:1,backend:"qwen-ja",corpusID:$corpus,corpusRole:$role,
      sourcePath:$source,sourceSHA256:$sourceHash,referenceArchivePath:$archive,
      referenceArchiveSHA256:$archiveHash,manifestSHA256:$manifestHash,commit:$commit,
      baselineRoot:$baselineRoot,candidateSelection:$selection,
      configuration:{ASR:"qwen-ja-product-default",alignment:"Qwen3-ForcedAligner",
        diarization:"SpeakerKit-W8A16-auto-library-default-non-exclusive",
        translation:"TranslateGemma-12b-4bit-previous-accepted-v1"},
      implementationSHA256:$implementation}' >"$directory/run-meta.json"
}

finalize_metadata() {
  local corpus="$1" directory="$ARTIFACTS/qwen-ja/$corpus" job provenance temporary
  job="$directory/jobs/$(job_id "$corpus")"
  write_model_provenance
  provenance="$ARTIFACTS/model-provenance.json"
  temporary="$directory/run-meta.updated.json"
  jq --arg manifest "$(shasum -a 256 "$job/manifest.json" | awk '{print $1}')" \
    --arg raw "$(shasum -a 256 "$job/raw-asr.json" | awk '{print $1}')" \
    --arg provenance "$(shasum -a 256 "$provenance" | awk '{print $1}')" \
    '. + {rawArtifactSHA256:{"manifest.json":$manifest,"raw-asr.json":$raw},
      modelProvenance:{path:"model-provenance.json",sha256:$provenance}}' \
    "$directory/run-meta.json" >"$temporary"
  mv "$temporary" "$directory/run-meta.json"
}

check_candidate() {
  local corpus="$1" job="$ARTIFACTS/qwen-ja/$1/jobs/$(job_id "$1")" manifest="$(manifest_for "$1")"
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" '
    .status == "completed" and .selectedBackend == "qwen-ja" and .failures == []
      and .peakMemoryBytes > 0' "$job/manifest.json" >/dev/null
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" '
    .sampleCount == $samples and (.rawASR | length > 0)
      and .model.backend == "qwen-ja"
      and .model.revision == "7c70d18cb650655d32eafb952a74a49c6a3caad0"
      and .alignment.modelID == "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
      and .alignment.revision == "2f652af86ae0c73fe189b9429225c908ce4bf020"
      and .alignment.validationDiagnostics == []
      and .diarization.modelID == "argmaxinc/speakerkit-coreml"
      and .diarization.revision == "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
      and .diarization.useExclusiveReconciliation == false
      and .diarization.validationDiagnostics == []
      and .translation.model == "mlx-community/translategemma-12b-it-4bit"
      and .translation.revision == "f3dcfd54df14672fbcf0731086fb47a797a943ae"
      and .translation.validationFailures == []
      and (.translation.request.conversationContextByCueID | length)
        == (.translation.request.turns | length)
      and ([.modelEvents[].kind] | index("guard-failed") | not)' "$job/raw-asr.json" >/dev/null
  jq empty "$job/manifest.json" "$job/raw-asr.json"
}

diagnose_failure() {
  local corpus="$1" diagnostic="$ARTIFACTS/qwen-ja/$1/infrastructure-diagnostics.log"
  {
    echo "candidate=qwen-ja corpus=$corpus"
    xcrun swift build
    source_check "$corpus"
    verify_corpus "$corpus"
    verify_baseline "$corpus"
    find "$ARTIFACTS/qwen-ja/$corpus/jobs" -name '*.json' -type f -exec jq empty {} \;
  } >"$diagnostic" 2>&1 || true
  echo "Candidate execution failed; infrastructure diagnostics retained at $diagnostic" >&2
}

run_candidate() {
  local corpus="$1" directory="$ARTIFACTS/qwen-ja/$1" job="$ARTIFACTS/qwen-ja/$1/jobs/$(job_id "$1")"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' "$job/manifest.json" >/dev/null 2>&1; then
    echo "Reusing completed raw run: qwen-ja/$corpus"
    check_candidate "$corpus"
    finalize_metadata "$corpus"
    return
  fi
  [[ ! -e "$job" ]] || { echo "Incomplete run retained at $job; move it aside before retrying." >&2; return 1; }
  write_metadata "$corpus"
  if ! WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE=1 \
    WHISPERASR_ACCEPTANCE_BACKEND=qwen-ja \
    WHISPERASR_ACCEPTANCE_CORPUS="$corpus" \
    WHISPERASR_ACCEPTANCE_SOURCE="$(resolve_corpus_file "$corpus" source-video)" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$(resolve_corpus_file "$corpus" reference-archive)" \
    WHISPERASR_ACCEPTANCE_JOB_ID="$(job_id "$corpus")" \
    WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$directory/jobs" \
    WHISPERASR_ACCEPTANCE_TRANSLATION_CONTEXT=product-default \
    WHISPERASR_ACCEPTANCE_ALLOW_HOLDOUT="$([[ "$corpus" == md62mmdz0m ]] && echo 1 || echo 0)" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn \
        2>&1 | tee "$directory/run.log"; then
    diagnose_failure "$corpus"
    return 1
  fi
  check_candidate "$corpus"
  finalize_metadata "$corpus"
}

report() {
  python3 Scripts/report_combined_offline_validation.py "$ARTIFACTS" \
    --baseline-root "$BASELINE_ROOT" --json "$REPORT_JSON" --markdown "$REPORT_MD" \
    --live-log "$LIVE_LOG"
}

score() {
  local corpus="$1" metrics="$ARTIFACTS/metrics/$1"
  "$COMET_PYTHON" Scripts/comet_score_compat.py -s "$metrics/source.ja.txt" \
    -t "$metrics/frozen-product-baseline.en.txt" "$metrics/combined-candidate.en.txt" \
    -r "$metrics/reference.en.txt" --model Unbabel/wmt22-comet-da \
    --gpus "${COMET_GPUS:-1}" --batch_size 8 --num_workers 1 --disable_cache --quiet \
    --to_json "$metrics/comet-score.json" >"$metrics/comet-score.raw.txt" 2>&1
  "$COMET_PYTHON" - <<'PY' >"$metrics/comet-runtime.json"
import json, platform, torch
print(json.dumps({"python": platform.python_version(), "torch": torch.__version__,
  "mpsAvailable": torch.backends.mps.is_available(), "deviceRequest": "MPS"}, indent=2))
PY
}

retain_evidence() {
  local evidence="$ROOT/docs/japanese-live/experiments/evidence/E19" corpus job
  mkdir -p "$evidence"
  cp "$ARTIFACTS/corpus-preflight.tsv" "$ARTIFACTS/controls.json" \
    "$ARTIFACTS/model-provenance.json" "$LIVE_LOG" "$evidence/"
  for corpus in qudu2fx3ncc md62mmdz0m; do
    job="$ARTIFACTS/qwen-ja/$corpus/jobs/$(job_id "$corpus")"
    gzip -n -c "$job/raw-asr.json" >"$evidence/$corpus-raw-asr.json.gz"
    cp "$job/manifest.json" "$evidence/$corpus-manifest.json"
    cp "$ARTIFACTS/qwen-ja/$corpus/run-meta.json" "$evidence/$corpus-run-meta.json"
    gzip -n -c "$ARTIFACTS/qwen-ja/$corpus/run.log" >"$evidence/$corpus-run.log.gz"
    cp "$ARTIFACTS/metrics/$corpus/comet-score.json" "$evidence/$corpus-comet-score.json"
    cp "$ARTIFACTS/metrics/$corpus/comet-runtime.json" "$evidence/$corpus-comet-runtime.json"
    gzip -n -c "$ARTIFACTS/metrics/$corpus/comet-score.raw.txt" >"$evidence/$corpus-comet-score.raw.txt.gz"
  done
  cp "$ARTIFACTS/full-swift-test.log" "$evidence/"
}

prepare_local_references
: >"$ARTIFACTS/corpus-preflight.tsv"
for corpus in qudu2fx3ncc md62mmdz0m; do
  verify_corpus "$corpus" >>"$ARTIFACTS/corpus-preflight.tsv"
  verify_baseline "$corpus"
done

if [[ "$MODE" != final ]]; then run_controls; fi
run_candidate qudu2fx3ncc
report
score qudu2fx3ncc
report
if ! jq -e '.developmentEligible' "$REPORT_JSON" >/dev/null; then
  echo "Development gates failed; untouched holdout remains closed."
  exit 0
fi
[[ "$MODE" != development ]] || { echo "Development gates passed; holdout remains untouched."; exit 0; }

source_check md62mmdz0m
run_candidate md62mmdz0m
score md62mmdz0m
xcrun swift test --filter LiveCaptionTests 2>&1 | tee "$LIVE_LOG"
xcrun swift test 2>&1 | tee "$ARTIFACTS/full-swift-test.log"
jq '. + {liveRegression:true,fullSwiftSuite:true}' "$ARTIFACTS/controls.json" \
  >"$ARTIFACTS/controls.updated.json"
mv "$ARTIFACTS/controls.updated.json" "$ARTIFACTS/controls.json"
report
retain_evidence
report
jq -e '.workflowValid' "$REPORT_JSON" >/dev/null
echo "Decision: $(jq -r .decision "$REPORT_JSON")"
echo "Report: $REPORT_MD"
