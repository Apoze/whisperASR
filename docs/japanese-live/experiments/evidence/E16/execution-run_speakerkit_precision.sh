#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROZEN_ROOT="${WHISPERASR_FROZEN_REPO_ROOT:-/Users/maz/Documents/projets/whisperASR}"
ARTIFACTS="${WHISPERASR_SPEAKERKIT_PRECISION_ROOT:-$ROOT/.build/benchmarks/speakerkit-precision}"
MODEL_CACHE="$ARTIFACTS/model-cache"
MODEL_INVENTORY="$ARTIFACTS/model-cache-manifest.json"
MODE="${1:-development}"
BASE_COMMIT="0faf0caa1074ae94d064e449107f73f5e120c5d3"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E16-speakerkit-precision.md"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final) ;;
  *) echo "usage: $0 [development|final]" >&2; exit 2 ;;
esac
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls" "$MODEL_CACHE"

run_logged() {
  local log="$1"
  shift
  if "$@" >"$log" 2>&1; then
    tail -n 40 "$log"
    return 0
  fi
  tail -n 80 "$log"
  return 1
}

baseline_evidence() {
  case "$1" in
    qudu2fx3ncc)
      echo "$FROZEN_ROOT/.build/benchmarks/principal-speaker-attribution/development-pass2/24714AB0-F273-44A3-9828-67B54766070D/raw-asr.json"
      ;;
    md62mmdz0m)
      echo "$FROZEN_ROOT/.build/benchmarks/principal-speaker-attribution/holdout/88088247-41D7-4780-94F1-7EC7630DD312/raw-asr.json"
      ;;
  esac
}

e06_directory() {
  echo "$FROZEN_ROOT/.build/benchmarks/high-quality/offline-acceptance/qwen-ja/$1"
}

source_path() {
  jq -er .sourcePath "$(e06_directory "$1")/run-meta.json"
}

corpus_manifest() {
  echo "$ROOT/docs/japanese-live/corpora/$1/manifest.json"
}

job_id() {
  local corpus="$1" precision="$2"
  if [[ "$corpus" == qudu2fx3ncc ]]; then
    [[ "$precision" == quantized ]] \
      && echo 58000001-0000-4000-8000-000000000001 \
      || echo 58000001-0000-4000-8000-000000000002
  else
    [[ "$precision" == quantized ]] \
      && echo 58000002-0000-4000-8000-000000000001 \
      || echo 58000002-0000-4000-8000-000000000002
  fi
}

verify_frozen_input() {
  local corpus="$1" source manifest evidence expected
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  evidence="$(baseline_evidence "$corpus")"
  [[ -f "$source" && -f "$manifest" && -f "$evidence" ]]
  expected="$(jq -er .sourceSHA256 "$(e06_directory "$corpus")/run-meta.json")"
  [[ "$(shasum -a 256 "$source" | awk '{print $1}')" == "$expected" ]]
  [[ "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    == "$(jq -er .manifestSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]]
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" \
    '.sampleCount == $samples and .model.backend == "qwen-ja"
      and (.rawASR | length > 0)
      and (.alignment.chunks | length > 0)
      and (.alignment.mergedCues | length > 0)' "$evidence" >/dev/null
}

run_controls() {
  local log="$ARTIFACTS/controls/light-tests.log"
  run_logged "$ARTIFACTS/controls/build-route.log" xcrun swift test \
    --filter HighQualityAcceptanceTests/testFrozenSpeakerKitPrecisionWhenOptedIn
  run_logged "$ARTIFACTS/controls/mlx-metallib.log" \
    bash Scripts/build_mlx_metallib.sh debug
  xcrun swift test --skip-build \
    --filter 'HighQualityJobTests|HighQualityTranslationIntegrityTests|HeavyweightModelGateTests|LiveCaptionTests/testTranslationOnlyPrimarySegmentsDropMissingTranslations|LiveCaptionTests/testClearlyNonEnglishTranslationIsRejected|LiveCaptionTests/testEachPrototypeLoadsOnlyItsRequiredModels|QwenPseudoLiveCoordinatorTests/testPseudoLiveEngineNeverRequestsAppleSpeech|LocalDiarizationShadowTests/testUnpromotedDiarizationCannotInfluenceSubtitleBoundaries' \
    >"$log" 2>&1
  tail -n 40 "$log"
  python3 Scripts/report_speakerkit_precision.py --self-test
  jq -n '{buildAndJobTests:true,cancellationTests:true,memoryGateTests:true,
    translationTests:true,liveTests:true,artifactReporterSelfTest:true}' \
    >"$ARTIFACTS/controls.json"
}

implementation_hashes() {
  local result='{}' path digest
  for path in \
    Sources/HighQualityJob.swift Sources/HighQualitySpeakerKitRuntime.swift \
    Tests/HighQualityAcceptanceTests.swift Tests/HighQualityJobTests.swift \
    Scripts/run_speakerkit_precision_experiment.sh \
    Scripts/report_speakerkit_precision.py \
    Scripts/report_exclusive_reconciliation.py \
    Scripts/report_high_quality_acceptance.py; do
    digest="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    result="$(jq -c --arg path "$path" --arg digest "$digest" \
      '. + {($path):$digest}' <<<"$result")"
  done
  echo "$result"
}

unchanged_implementation_hashes() {
  local result='{}' path base candidate
  for path in \
    Sources/AppleLiveServices.swift Sources/HighQualityTranslationIntegrity.swift \
    Sources/LiveRecoveryStore.swift Sources/LocalMLXTranslator.swift \
    Sources/QwenPseudoLiveCoordinator.swift Sources/TranslationService.swift; do
    base="$(git show "$BASE_COMMIT:$path" | shasum -a 256 | awk '{print $1}')"
    candidate="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    result="$(jq -c --arg path "$path" --arg base "$base" --arg candidate "$candidate" \
      '. + {($path):{baseSHA256:$base,candidateSHA256:$candidate}}' <<<"$result")"
  done
  echo "$result"
}

write_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" source manifest role implementation unchanged
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  role="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo untouched-holdout)"
  implementation="$(implementation_hashes)"
  unchanged="$(unchanged_implementation_hashes)"
  mkdir -p "$directory/jobs"
  jq -n \
    --arg corpus "$corpus" --arg role "$role" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg manifest "$manifest" --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg evidence "$(baseline_evidence "$corpus")" \
    --arg evidenceHash "$(shasum -a 256 "$(baseline_evidence "$corpus")" | awk '{print $1}')" \
    --arg baselineJob "$(job_id "$corpus" quantized)" \
    --arg candidateJob "$(job_id "$corpus" full)" \
    --arg baseCommit "$BASE_COMMIT" \
    --arg packageRevision "$(jq -r '.pins[] | select(.identity=="whisperkit") | .state.revision' Package.resolved)" \
    --argjson implementation "$implementation" --argjson unchanged "$unchanged" \
    '{schemaVersion:1,experiment:"E16-speakerkit-precision",
      corpusID:$corpus,corpusRole:$role,
      sourcePath:$source,sourceSHA256:$sourceHash,
      corpusManifestPath:$manifest,corpusManifestSHA256:$manifestHash,
      frozenUpstreamEvidencePath:$evidence,
      frozenUpstreamEvidenceSHA256:$evidenceHash,
      jobs:{baseline:$baselineJob,candidate:$candidateJob},baseCommit:$baseCommit,
      speakerKit:{modelID:"argmaxinc/speakerkit-coreml",
        revision:"86ec9c929b52208b6656eb6a6361ed0d822a1f78",
        packageRevision:$packageRevision,
        downloadPatterns:{
          baseline:["speaker_segmenter/pyannote-v3/W8A16/*",
            "speaker_embedder/pyannote-v3/W8A16/*",
            "speaker_clusterer/pyannote-v4/W32A32/*"],
          candidate:["speaker_segmenter/pyannote-v3/W32A32/*",
            "speaker_embedder/pyannote-v3/W16A16/*",
            "speaker_clusterer/pyannote-v4/W32A32/*"]}},
      settings:{
        baseline:{precision:"quantized",segmenterVariant:"W8A16",
          embedderVariant:"W8A16",useExclusiveReconciliation:false,
          principalAttribution:"longest-overlap-stable-label-span",
          numberOfSpeakers:null,minActiveOffset:null,clusterDistanceThreshold:null,
          minClusterSize:null,fullRedundancy:true,centroidSource:"finalAssignment",
          clipTimestamps:[]},
        candidate:{precision:"full",segmenterVariant:"W32A32",
          embedderVariant:"W16A16",useExclusiveReconciliation:false,
          principalAttribution:"longest-overlap-stable-label-span",
          numberOfSpeakers:null,minActiveOffset:null,clusterDistanceThreshold:null,
          minClusterSize:null,fullRedundancy:true,centroidSource:"finalAssignment",
          clipTimestamps:[]}},
      costPolicy:{qualityFirst:true,maximumObservedMemoryBytes:17179869184,
        reason:"Any strict holdout speaker-quality gain is acceptable only if the 8 GiB reserve, completion, and memory-release gates pass."},
      failurePolicy:{candidateAttribution:"withheld until build, source, input, artifact, load, cancellation and memory-release diagnostics pass"},
      executionImplementationSHA256:$implementation,
      reviewedImplementationSHA256:$implementation,
      unchangedImplementations:$unchanged}' >"$directory/run-meta.json"
}

artifact_hashes() {
  local job="$1" result='{}' name digest
  for name in japanese-transcript.txt english-translation-transcript.txt \
    english-subtitles.vtt english-subtitles.srt raw-asr.json manifest.json; do
    digest="$(shasum -a 256 "$job/$name" | awk '{print $1}')"
    result="$(jq -c --arg name "$name" --arg digest "$digest" \
      '. + {($name):$digest}' <<<"$result")"
  done
  echo "$result"
}

finalize_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" temporary baseline candidate implementation
  baseline="$(artifact_hashes "$directory/jobs/$(job_id "$corpus" quantized)")"
  candidate="$(artifact_hashes "$directory/jobs/$(job_id "$corpus" full)")"
  implementation="$(implementation_hashes)"
  python3 Scripts/report_speakerkit_precision.py \
    --inventory-cache "$MODEL_CACHE" --inventory-output "$MODEL_INVENTORY"
  jq --arg inventory "$MODEL_INVENTORY" \
    --arg inventoryHash "$(shasum -a 256 "$MODEL_INVENTORY" | awk '{print $1}')" \
    --argjson baseline "$baseline" --argjson candidate "$candidate" \
    --argjson implementation "$implementation" \
    '. + {modelInventoryPath:$inventory,modelInventorySHA256:$inventoryHash,
      artifactSHA256:{baseline:$baseline,candidate:$candidate},
      reviewedImplementationSHA256:$implementation}' \
    "$directory/run-meta.json" >"$directory/run-meta.updated.json"
  mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
}

check_variant() {
  local corpus="$1" precision="$2" directory="$ARTIFACTS/$1" job
  job="$directory/jobs/$(job_id "$corpus" "$precision")"
  jq -e '.status == "completed" and .failures == []
    and ([.modelEvents[] | select(.modelID == "argmaxinc/speakerkit-coreml") | .kind]
      | index("load-completed") != null and index("unload-completed") != null
        and index("memory-release-checked") != null)' "$job/manifest.json" >/dev/null
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$(corpus_manifest "$corpus")")" \
    '.sampleCount == $samples and .failures == []
      and .diarization.useExclusiveReconciliation == false
      and (.diarization.rawSpans | length > 0)
      and (.diarization.mappings | length > 0)
      and .diarization.validationDiagnostics == []
      and ((.diarization.mappings | length)
        == ([.diarization.mappings[].alignmentItemIndex] | unique | length))
      and .translation.validationFailures == []' "$job/raw-asr.json" >/dev/null
  for name in japanese-transcript.txt english-translation-transcript.txt \
    english-subtitles.vtt english-subtitles.srt raw-asr.json manifest.json; do
    [[ -s "$job/$name" ]]
  done
}

diagnose_failure() {
  local corpus="$1" precision="$2" directory="$ARTIFACTS/$1" log classification stage raw
  local partial_inventory="$ARTIFACTS/$1/$2-model-cache-manifest.json"
  local build=false source=false inputs=false artifacts=false
  log="$directory/$precision-infrastructure-diagnostics.log"
  if xcrun swift build >"$log" 2>&1; then build=true; fi
  if [[ "$(shasum -a 256 "$(source_path "$corpus")" | awk '{print $1}')" \
      == "$(jq -r .sourceSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]]; then
    source=true
  fi
  if jq empty "$(baseline_evidence "$corpus")" "$(corpus_manifest "$corpus")" \
      >>"$log" 2>&1; then inputs=true; fi
  if find "$directory/jobs" -name '*.json' -type f -exec jq empty {} + \
      >>"$log" 2>&1; then artifacts=true; fi
  if [[ "$build" != true ]]; then classification=runner-build
  elif [[ "$source" != true || "$inputs" != true ]]; then classification=runner-input
  elif [[ "$artifacts" != true ]]; then classification=runner-artifact
  else classification=application-runtime; fi
  raw="$(find "$directory/jobs" -name raw-asr.json -type f -print -quit)"
  stage=unknown
  [[ -z "$raw" ]] || stage="$(jq -r '.failures[-1].stage // "unknown"' "$raw")"
  python3 Scripts/report_speakerkit_precision.py \
    --inventory-cache "$MODEL_CACHE" --inventory-output "$partial_inventory" || true
  jq -n --arg classification "$classification" --arg stage "$stage" \
    --arg precision "$precision" --arg inventory "$partial_inventory" --argjson build "$build" \
    --argjson source "$source" --argjson inputs "$inputs" --argjson artifacts "$artifacts" \
    '{classification:$classification,candidateAttribution:"withheld",
      precision:$precision,failingStage:$stage,runnerBuild:$build,
      sourceIntegrity:$source,inputJSON:$inputs,artifactJSON:$artifacts,
      partialModelInventory:$inventory}' \
    >"$directory/$precision-infrastructure-diagnostics.json"
  echo "Run failed; application/runtime attribution retained at $directory" >&2
}

run_variant() {
  local corpus="$1" precision="$2" directory="$ARTIFACTS/$1" job log
  job="$directory/jobs/$(job_id "$corpus" "$precision")"
  log="$directory/$precision.log"
  verify_frozen_input "$corpus"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' \
      "$job/manifest.json" >/dev/null 2>&1; then
    echo "Reusing completed $precision run: $corpus"
    check_variant "$corpus" "$precision"
    return
  fi
  if [[ -e "$job" ]]; then
    echo "Incomplete run retained at $job; refusing to overwrite it." >&2
    return 1
  fi
  if ! run_logged "$log" env \
      WHISPERASR_RUN_SPEAKERKIT_PRECISION_EXPERIMENT=1 \
      WHISPERASR_SPEAKERKIT_PRECISION_EVIDENCE="$(baseline_evidence "$corpus")" \
      WHISPERASR_SPEAKERKIT_PRECISION_SOURCE="$(source_path "$corpus")" \
      WHISPERASR_SPEAKERKIT_PRECISION_OUTPUT="$directory/jobs" \
      WHISPERASR_SPEAKERKIT_PRECISION_JOB_ID="$(job_id "$corpus" "$precision")" \
      WHISPERASR_SPEAKERKIT_PRECISION="$precision" \
      WHISPERASR_SPEAKERKIT_MODEL_CACHE="$MODEL_CACHE" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testFrozenSpeakerKitPrecisionWhenOptedIn; then
    diagnose_failure "$corpus" "$precision"
    return 1
  fi
  check_variant "$corpus" "$precision"
}

snapshot_evidence() {
  local corpus="$1" split evidence directory precision job
  split="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)"
  evidence="$ROOT/docs/japanese-live/experiments/evidence/E16"
  directory="$ARTIFACTS/$corpus"
  mkdir -p "$evidence"
  for precision in quantized full; do
    job="$directory/jobs/$(job_id "$corpus" "$precision")"
    gzip -n -c "$job/raw-asr.json" >"$evidence/$split-$precision-raw-asr.json.gz"
    cp "$job/manifest.json" "$evidence/$split-$precision-manifest.json"
    cp "$directory/$precision.log" "$evidence/$split-$precision.log"
  done
  cp "$directory/run-meta.json" "$evidence/$split-run-meta.json"
  cp "$ARTIFACTS/controls.json" "$evidence/controls.json"
  cp "$MODEL_INVENTORY" "$evidence/model-cache-manifest.json"
}

write_report() {
  python3 Scripts/report_speakerkit_precision.py "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
  cp "$REPORT_JSON" "$ROOT/docs/japanese-live/experiments/evidence/E16/report.json"
}

run_corpus() {
  local corpus="$1" directory="$ARTIFACTS/$1"
  verify_frozen_input "$corpus"
  [[ -f "$directory/run-meta.json" ]] || write_metadata "$corpus"
  run_variant "$corpus" quantized
  run_variant "$corpus" full
  finalize_metadata "$corpus"
  snapshot_evidence "$corpus"
  write_report
}

if [[ "$MODE" == development ]]; then
  run_controls
  run_corpus qudu2fx3ncc
  jq '{developmentPromotionEligible,decision}' "$REPORT_JSON"
  exit 0
fi

[[ -f "$REPORT_JSON" && -f "$ARTIFACTS/controls.json" ]] || {
  echo "Run the development experiment first." >&2
  exit 1
}
jq -e '.developmentPromotionEligible == true' "$REPORT_JSON" >/dev/null || {
  echo "Development did not pass; untouched holdout will not be opened." >&2
  exit 1
}
run_corpus md62mmdz0m
jq '{promote,decision}' "$REPORT_JSON"
