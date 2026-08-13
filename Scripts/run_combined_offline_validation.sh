#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="${WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE:-$ROOT/.build/debug/WhisperASR}"
ARTIFACTS="${WHISPERASR_COMBINED_ROOT:-$ROOT/.build/benchmarks/standard-offline-validation-77}"
BASELINE_ROOT="${WHISPERASR_FROZEN_BASELINE_ROOT:-/Users/maz/Documents/projets/whisperASR/.build/benchmarks/high-quality/offline-acceptance}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
MODE="${1:-full}"
REPORT_JSON="$ROOT/docs/high-quality-standard-e22.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E22-standard-offline-validation.md"
QUALITY_JSON="$ROOT/docs/japanese-live/experiments/evidence/E22/quality-report.json"
RESOURCES_JSON="$ROOT/docs/japanese-live/experiments/evidence/E22/resources-report.json"
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

case "$MODE" in preflight|development|final|full) ;; *) echo "usage: $0 [preflight|development|final|full]" >&2; exit 2 ;; esac
[[ "$MODE" == preflight || "${BENCHMARK_SLOT_GRANTED:-}" == "77" ]] || {
  echo "Refusing heavyweight #77 run without BENCHMARK_SLOT_GRANTED=77" >&2
  exit 2
}
[[ -x "$COMET_PYTHON" ]] || { echo "COMET v2.2.7 is required at $COMET_PYTHON" >&2; exit 1; }
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls"

manifest_for() { printf '%s/docs/japanese-live/corpora/%s/manifest.json\n' "$ROOT" "$1"; }
video_directory() { [[ "$1" == qudu2fx3ncc ]] && printf '%s/1\n' "$VIDEO_ROOT" || printf '%s/2\n' "$VIDEO_ROOT"; }
job_id() { [[ "$1" == qudu2fx3ncc ]] && echo 77000001-0000-4000-8000-000000000001 || echo 77000002-0000-4000-8000-000000000001; }

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
  local corpus="$1" locator source destination
  while IFS= read -r locator; do
    destination="$ROOT/$locator"
    [[ -f "$destination" ]] && continue
    source="$FROZEN_REPO/$locator"
    [[ -f "$source" ]] || { echo "Missing frozen local reference: $source" >&2; return 1; }
    mkdir -p "$(dirname "$destination")"
    ln -s "$source" "$destination"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | .locator' "$(manifest_for "$corpus")")
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
  [[ -x "$WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE" ]] || {
    echo "Missing worker executable: $WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE" >&2
    return 1
  }
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
    --filter 'HighQualityJobTests/testSpeakerBetaControlsVisibilityAndSafeDefaults|HighQualityJobTests/testIndependentSpeakerBetaSettingsReachSpeakerKitManifestAndRawEvidence|HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts|HighQualityJobTests/testClassifiesSourcePreparationASRAndExportFailuresAtThePrincipalInterface|HighQualityJobTests/testCancellationIsSafeForEveryOfflineBackend|HighQualityJobTests/testPeakMemoryIsSampledDuringASRStages|HighQualityJobTests/testEnglish|HighQualityJobTests/testAlignmentAndDiarizationWorkerEvidenceReachesRawEvidence|HeavyweightModelGateTests|HighQualityASRWorkerTests|HighQualityAlignmentSpeakerWorkerTests|HighQualityTranslationWorkerTests|HighQualityLocalTranslationTests|HighQualityConversationContextTests' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  xcrun swift test --filter HighQualityJobTests/testYouTube \
    2>&1 | tee "$ARTIFACTS/controls/youtube-revalidation.log"
  local test_binary="$ROOT/.build/debug/WhisperASRPackageTests.xctest/Contents/MacOS/WhisperASRPackageTests"
  jq -n \
    --arg source "$(shasum -a 256 Sources/YouTubeAcquirer.swift | awk '{print $1}')" \
    --arg job "$(shasum -a 256 Sources/HighQualityJob.swift | awk '{print $1}')" \
    --arg tests "$(shasum -a 256 Tests/HighQualityJobTests.swift | awk '{print $1}')" \
    --arg binary "$(shasum -a 256 "$test_binary" | awk '{print $1}')" \
    --arg log "$(shasum -a 256 "$ARTIFACTS/controls/youtube-revalidation.log" | awk '{print $1}')" \
    '{kind:"current-code-youtube-control",implementationSHA256:{
      "Sources/YouTubeAcquirer.swift":$source,"Sources/HighQualityJob.swift":$job,
      "Tests/HighQualityJobTests.swift":$tests},testBinarySHA256:$binary,
      testLogSHA256:$log}' >"$ARTIFACTS/control-provenance.json"
  [[ -f .build/debug/mlx.metallib ]] || bash Scripts/build_mlx_metallib.sh debug
  python3 Scripts/report_combined_offline_validation.py --self-test
  source_check qudu2fx3ncc 2>&1 | tee "$ARTIFACTS/controls/source-qudu2fx3ncc.log"
  run_real_cancellation_control 2>&1 | tee "$ARTIFACTS/controls/real-cancellation.log"
  jq -n '{build:true,sourceDecode:true,referenceIntegrity:true,modelPreparation:true,
    realCancellation:true,failureClassification:true,artifactParsing:true,
    selectableBackends:true,paidAPIAbsent:true,isolatedWorkers:true,
    dynamicMemoryPressure:true,liveMutualExclusion:true,standardSpeakerDefaults:true,
    speakerBetaOptionsIndependent:true,translatorSelections:true,
    deliverableCombinations:true,youtubeAcquisition:true,englishOnly:true}' \
    >"$ARTIFACTS/controls.json"
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
  for path in Sources/HighQualityJob.swift Sources/HighQualityJobView.swift \
    Sources/HighQualityConversationContext.swift Sources/HighQualityWorkerProcess.swift \
    Sources/HighQualityASRWorker.swift Sources/HighQualityAlignmentSpeakerWorker.swift \
    Sources/HighQualityTranslationWorker.swift Sources/HeavyweightModelGate.swift \
    Sources/HighQualityForcedAlignerRuntime.swift Sources/HighQualitySpeakerKitRuntime.swift \
    Sources/HighQualityTranslationIntegrity.swift Sources/LocalMLXTranslator.swift \
    Sources/YouTubeAcquirer.swift Tests/HeavyweightModelGateTests.swift \
    Tests/HighQualityJobTests.swift Tests/HighQualityLocalTranslationTests.swift \
    Tests/HighQualityTranslationIntegrityTests.swift \
    Tests/HighQualityAcceptanceTests.swift Tests/HighQualityASRWorkerTests.swift \
    Tests/HighQualityAlignmentSpeakerWorkerTests.swift \
    Tests/HighQualityTranslationWorkerTests.swift \
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
    --arg reporter "$(shasum -a 256 Scripts/report_combined_offline_validation.py | awk '{print $1}')" \
    --arg comet "$(shasum -a 256 Scripts/comet_score_compat.py | awk '{print $1}')" \
    '. + {rawArtifactSHA256:{"manifest.json":$manifest,"raw-asr.json":$raw},
      modelProvenance:{path:"model-provenance.json",sha256:$provenance},
      scoringImplementationSHA256:{
        "Scripts/report_combined_offline_validation.py":$reporter,
        "Scripts/comet_score_compat.py":$comet}}' \
    "$directory/run-meta.json" >"$temporary"
  mv "$temporary" "$directory/run-meta.json"
}

revalidate_candidate() {
  local corpus="$1" directory="$ARTIFACTS/qwen-ja/$1"
  local job="$directory/jobs/$(job_id "$1")" log="$directory/revalidation.log"
  WHISPERASR_REVALIDATE_TRANSLATION_EVIDENCE="$job/raw-asr.json" \
    xcrun swift test \
      --filter HighQualityTranslationIntegrityTests/testRevalidatesRecordedTranslationEvidenceWhenOptedIn \
      2>&1 | tee "$log"
  local test_binary="$ROOT/.build/debug/WhisperASRPackageTests.xctest/Contents/MacOS/WhisperASRPackageTests"
  local temporary="$(mktemp)" integrity job_hash test_hash
  integrity="$(shasum -a 256 Sources/HighQualityTranslationIntegrity.swift | awk '{print $1}')"
  job_hash="$(shasum -a 256 Sources/HighQualityJob.swift | awk '{print $1}')"
  test_hash="$(shasum -a 256 Tests/HighQualityTranslationIntegrityTests.swift | awk '{print $1}')"
  jq --arg raw "$(shasum -a 256 "$job/raw-asr.json" | awk '{print $1}')" \
    --arg log "$(shasum -a 256 "$log" | awk '{print $1}')" \
    --arg binary "$(shasum -a 256 "$test_binary" | awk '{print $1}')" \
    --arg integrity "$integrity" --arg jobHash "$job_hash" --arg testHash "$test_hash" '
      . + {revalidation:{kind:"current-code-raw-replay",rawArtifactSHA256:$raw,
        implementationSHA256:{
          "Sources/HighQualityTranslationIntegrity.swift":$integrity,
          "Sources/HighQualityJob.swift":$jobHash,
          "Tests/HighQualityTranslationIntegrityTests.swift":$testHash},
        testBinarySHA256:$binary,testLogSHA256:$log}}' \
    "$directory/run-meta.json" >"$temporary"
  mv "$temporary" "$directory/run-meta.json"
}

check_candidate() {
  local corpus="$1" job="$ARTIFACTS/qwen-ja/$1/jobs/$(job_id "$1")" manifest="$(manifest_for "$1")"
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" '
    .status == "completed" and .selectedBackend == "qwen-ja" and .failures == []
      and .translationModel.modelID == "mlx-community/translategemma-12b-it-4bit"
      and .speakerConfiguration == {enhancedPrecision:false,sensitiveDetection:false,
        countPolicy:{mode:"automatic"}}
      and .peakMemoryBytes > 0' "$job/manifest.json" >/dev/null
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" '
    def worker_ok:
      . != null and .exitStatus == 0 and .forcedTermination == false
        and .peakPhysicalFootprintBytes > 0
        and (.availableMemorySamples | length) > 0
        and .swapUsedBeforeBytes != null and .swapUsedAfterBytes != null
        and ([.pressureTransitions[].level] | index("critical") | not);
    .sampleCount == $samples and (.rawASR | length > 0)
      and .model.backend == "qwen-ja"
      and .model.revision == "7c70d18cb650655d32eafb952a74a49c6a3caad0"
      and .alignment.modelID == "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
      and .alignment.revision == "2f652af86ae0c73fe189b9429225c908ce4bf020"
      and .alignment.validationDiagnostics == []
      and ([.alignment.semanticUnits[] | select(.end <= .start)] | length) == 0
      and .diarization.modelID == "argmaxinc/speakerkit-coreml"
      and .diarization.revision == "86ec9c929b52208b6656eb6a6361ed0d822a1f78"
      and .diarization.useExclusiveReconciliation == false
      and .diarization.validationDiagnostics == []
      and .translation.model == "mlx-community/translategemma-12b-it-4bit"
      and .translation.revision == "f3dcfd54df14672fbcf0731086fb47a797a943ae"
      and .translation.validationFailures == []
      and .speakerConfiguration == {enhancedPrecision:false,sensitiveDetection:false,
        countPolicy:{mode:"automatic"}}
      and (.translation.request.conversationContextByCueID | length)
        == (.translation.request.turns | length)
      and ([.modelEvents[].kind] | index("guard-failed") | not)
      and ([.modelEvents[] | select(.kind == "memory-pressure-checked")]
        | length) == 4
      and all(.modelEvents[] | select(.kind == "memory-pressure-checked");
        (.message | contains("policy=macos-memory-pressure"))
          and (.message | contains("reserve=0")))
      and ([.asrWorker.lifecycle, .alignment.worker, .diarization.worker,
        .translation.worker] | all(worker_ok))
      and ([.asrWorker.lifecycle.processIdentifier, .alignment.worker.processIdentifier,
        .diarization.worker.processIdentifier, .translation.worker.processIdentifier]
        | unique | length) == 4
      and .asrWorker.lifecycle.exitedAt <= .alignment.worker.startedAt
      and .alignment.worker.exitedAt <= .diarization.worker.startedAt
      and .diarization.worker.exitedAt <= .translation.worker.startedAt' \
    "$job/raw-asr.json" >/dev/null
  for path in japanese-transcript.txt english-translation-transcript.txt \
    english-subtitles.srt english-subtitles.vtt; do
    [[ -s "$job/$path" ]]
  done
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
    revalidate_candidate "$corpus"
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
    if [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]]; then
      finalize_metadata "$corpus"
      retain_failure_evidence "$corpus"
      report
    fi
    return 1
  fi
  check_candidate "$corpus"
  finalize_metadata "$corpus"
  revalidate_candidate "$corpus"
}

report() {
  local scope="${1:-full}"
  python3 Scripts/report_combined_offline_validation.py "$ARTIFACTS" \
    --baseline-root "$BASELINE_ROOT" --json "$REPORT_JSON" --markdown "$REPORT_MD" \
    --quality-json "$QUALITY_JSON" --resources-json "$RESOURCES_JSON" \
    --live-log "$LIVE_LOG" $([[ "$scope" == development ]] && echo --development-only)
}

prepare_score_inputs() {
  local scope="${1:-full}"
  python3 Scripts/report_combined_offline_validation.py "$ARTIFACTS" \
    --baseline-root "$BASELINE_ROOT" --prepare-scoring \
    $([[ "$scope" == development ]] && echo --development-only)
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
  local evidence="$ROOT/docs/japanese-live/experiments/evidence/E22" corpus job deliverable
  mkdir -p "$evidence"
  cp "$ARTIFACTS/corpus-preflight.tsv" "$ARTIFACTS/controls.json" \
    "$ARTIFACTS/model-provenance.json" "$ARTIFACTS/control-provenance.json" \
    "$ARTIFACTS/development-report.json" "$ARTIFACTS/holdout-opened.json" \
    "$LIVE_LOG" "$evidence/"
  cp "$ARTIFACTS/controls/"*.log "$evidence/"
  for corpus in qudu2fx3ncc md62mmdz0m; do
    job="$ARTIFACTS/qwen-ja/$corpus/jobs/$(job_id "$corpus")"
    gzip -n -c "$job/raw-asr.json" >"$evidence/$corpus-raw-asr.json.gz"
    cp "$job/manifest.json" "$evidence/$corpus-manifest.json"
    for deliverable in japanese-transcript.txt english-translation-transcript.txt \
      english-subtitles.srt english-subtitles.vtt; do
      cp "$job/$deliverable" "$evidence/$corpus-$deliverable"
    done
    cp "$ARTIFACTS/qwen-ja/$corpus/run-meta.json" "$evidence/$corpus-run-meta.json"
    cp "$ARTIFACTS/qwen-ja/$corpus/revalidation.log" \
      "$evidence/$corpus-revalidation.log"
    gzip -n -c "$ARTIFACTS/qwen-ja/$corpus/run.log" >"$evidence/$corpus-run.log.gz"
    cp "$ARTIFACTS/metrics/$corpus/comet-score.json" "$evidence/$corpus-comet-score.json"
    cp "$ARTIFACTS/metrics/$corpus/comet-runtime.json" "$evidence/$corpus-comet-runtime.json"
    gzip -n -c "$ARTIFACTS/metrics/$corpus/comet-score.raw.txt" >"$evidence/$corpus-comet-score.raw.txt.gz"
  done
  cp "$ARTIFACTS/full-swift-test.log" "$evidence/"
  retain_burnout_evidence "$evidence"
}

retain_burnout_evidence() {
  local evidence="$1" directory path
  for directory in "$ARTIFACTS"/experiments/burnout-targeted-*; do
    [[ -d "$directory" ]] || continue
    for path in "$directory"/*; do
      [[ -f "$path" ]] || continue
      gzip -n -c "$path" >"$evidence/burnout-targeted-$(basename "$path").gz"
    done
  done
  for directory in "$ARTIFACTS"/attempts/qudu2fx3ncc-burnout-precanonicalization-*; do
    [[ -d "$directory" ]] || continue
    gzip -n -c "$directory/jobs/$(job_id qudu2fx3ncc)/raw-asr.json" \
      >"$evidence/qudu2fx3ncc-precanonicalization-raw-asr.json.gz"
    cp "$directory/jobs/$(job_id qudu2fx3ncc)/manifest.json" \
      "$evidence/qudu2fx3ncc-precanonicalization-manifest.json"
  done
}

retain_failure_evidence() {
  local corpus="$1" evidence="$ROOT/docs/japanese-live/experiments/evidence/E22"
  local directory="$ARTIFACTS/qwen-ja/$corpus" job="$directory/jobs/$(job_id "$corpus")"
  local prior="$ARTIFACTS/attempts/qudu2fx3ncc-20260811T011611Z"
  local window30="$ARTIFACTS/attempts/qudu2fx3ncc-window30-20260811T013745Z"
  local experiment
  mkdir -p "$evidence"
  cp "$ARTIFACTS/corpus-preflight.tsv" "$ARTIFACTS/controls.json" \
    "$ARTIFACTS/model-provenance.json" "$evidence/"
  cp "$ARTIFACTS/controls/"*.log "$evidence/"
  cp "$job/manifest.json" "$evidence/$corpus-manifest.json"
  gzip -n -c "$job/raw-asr.json" >"$evidence/$corpus-raw-asr.json.gz"
  cp "$directory/run-meta.json" "$directory/infrastructure-diagnostics.log" "$evidence/"
  gzip -n -c "$directory/run.log" >"$evidence/$corpus-run.log.gz"
  if [[ -f "$prior/jobs/$(job_id "$corpus")/manifest.json" && \
        -f "$prior/jobs/$(job_id "$corpus")/raw-asr.json" ]]; then
    cp "$prior/jobs/$(job_id "$corpus")/manifest.json" "$evidence/$corpus-prior-attempt-manifest.json"
    gzip -n -c "$prior/jobs/$(job_id "$corpus")/raw-asr.json" \
      >"$evidence/$corpus-prior-attempt-raw-asr.json.gz"
  fi
  if [[ -f "$window30/jobs/$(job_id "$corpus")/manifest.json" && \
        -f "$window30/jobs/$(job_id "$corpus")/raw-asr.json" ]]; then
    cp "$window30/jobs/$(job_id "$corpus")/manifest.json" \
      "$evidence/$corpus-window30-manifest.json"
    gzip -n -c "$window30/jobs/$(job_id "$corpus")/raw-asr.json" \
      >"$evidence/$corpus-window30-raw-asr.json.gz"
  fi
  for experiment in dev-alignment-window-15 dev-alignment-window-20 \
    dev-alignment-window-25 dev-alignment-window-20-owned-retry; do
    [[ -f "$ARTIFACTS/experiments/$experiment.json" ]] || continue
    gzip -n -c "$ARTIFACTS/experiments/$experiment.json" \
      >"$evidence/$experiment.json.gz"
    [[ ! -f "$ARTIFACTS/experiments/$experiment.log" ]] || \
      gzip -n -c "$ARTIFACTS/experiments/$experiment.log" \
        >"$evidence/$experiment.log.gz"
  done
  retain_burnout_evidence "$evidence"
}

run_preflight() {
  local tool commit
  for tool in jq ffmpeg shasum xcrun python3; do command -v "$tool" >/dev/null; done
  for commit in a513c22cbba69546f62b1982f8991b188a3919b9 \
    db1edc9 804980c 1347e5d e248a12; do
    git merge-base --is-ancestor "$commit" HEAD
  done
  bash -n Scripts/run_combined_offline_validation.sh
  python3 Scripts/report_combined_offline_validation.py --self-test
  "$COMET_PYTHON" -c 'import comet, torch; assert torch.backends.mps.is_available()'
  xcrun swift build 2>&1 | tee "$ARTIFACTS/controls/preflight-build.log"
  xcrun swift test \
    --filter 'HighQualityJobTests/testSpeakerBetaControlsVisibilityAndSafeDefaults|HighQualityJobTests/testIndependentSpeakerBetaSettingsReachSpeakerKitManifestAndRawEvidence|HighQualityJobTests/testEnglishSubtitles|HeavyweightModelGateTests|HighQualityLocalTranslationTests/testTranslateGemmaModelsArePinnedAndUseTheSameTranslationContract|HighQualityAlignmentSpeakerWorkerTests/testIndependentBetaSettingsCrossWorkerBoundary' \
    2>&1 | tee "$ARTIFACTS/controls/preflight-tests.log"
  write_model_provenance
  jq -n --arg commit "$(git rev-parse HEAD)" '{ticket:77,status:"BENCHMARK_READY",
    commit:$commit,baseCommit:"a513c22cbba69546f62b1982f8991b188a3919b9",
    integratedTickets:[71,72,73,74,75,76],heavyModelsLoaded:false,
    command:"BENCHMARK_SLOT_GRANTED=77 bash Scripts/run_combined_offline_validation.sh full",
    steps:["development controls and real Standard workflow","development integrity and quality gates","untouched holdout only after development passes","Live regression and full Swift suite","retain raw deliverables, telemetry, hashes, quality and resource reports"],
    estimatedDuration:"35-60 minutes",estimatedPeakWorkerMemory:"12-14 GiB",
    memoryPolicy:"native macOS pressure and swap telemetry; no fixed offline reserve"}' \
    >"$ARTIFACTS/benchmark-ready.json"
  echo "BENCHMARK_READY #77"
  echo "Command: BENCHMARK_SLOT_GRANTED=77 bash Scripts/run_combined_offline_validation.sh full"
}

prepare_local_references qudu2fx3ncc
: >"$ARTIFACTS/corpus-preflight.tsv"
verify_corpus qudu2fx3ncc >>"$ARTIFACTS/corpus-preflight.tsv"
verify_baseline qudu2fx3ncc

if [[ "$MODE" == preflight ]]; then
  run_preflight
  exit 0
fi

if [[ "$MODE" == final ]]; then
  [[ -f "$ARTIFACTS/controls.json" ]]
  [[ -f "$ARTIFACTS/qwen-ja/qudu2fx3ncc/jobs/$(job_id qudu2fx3ncc)/manifest.json" ]]
fi

if [[ "$MODE" != final ]]; then run_controls; fi
run_candidate qudu2fx3ncc
prepare_score_inputs development
score qudu2fx3ncc
report development
if ! jq -e '.developmentEligible' "$REPORT_JSON" >/dev/null; then
  echo "Development gates failed; untouched holdout remains closed."
  exit 1
fi
cp "$REPORT_JSON" "$ARTIFACTS/development-report.json"
[[ "$MODE" != development ]] || { echo "Development gates passed; holdout remains untouched."; exit 0; }

jq -n --arg report "$(shasum -a 256 "$ARTIFACTS/development-report.json" | awk '{print $1}')" \
  --arg openedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ticket:77,developmentReportSHA256:$report,openedAt:$openedAt}' \
  >"$ARTIFACTS/holdout-opened.json"
prepare_local_references md62mmdz0m
verify_corpus md62mmdz0m >>"$ARTIFACTS/corpus-preflight.tsv"
verify_baseline md62mmdz0m
source_check md62mmdz0m
run_candidate md62mmdz0m
prepare_score_inputs full
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
