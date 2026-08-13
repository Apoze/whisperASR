#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROZEN_ROOT="${WHISPERASR_FROZEN_REPO_ROOT:-/Users/maz/Documents/projets/whisperASR}"
ARTIFACTS="${WHISPERASR_SPEAKERKIT_THRESHOLD_ROOT:-$ROOT/.build/benchmarks/speakerkit-threshold}"
MODEL_CACHE="$ARTIFACTS/model-cache"
MODEL_INVENTORY="$ARTIFACTS/model-cache-manifest.json"
MODE="${1:-development}"
BASE_COMMIT="72fabb14eb29268be7a1f959d52d8dd156138867"
EVIDENCE_ROOT="docs/japanese-live/experiments/evidence/E17"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E17-speakerkit-clustering-threshold.md"
DEVELOPMENT_REPORT="$ROOT/$EVIDENCE_ROOT/development-report.json"
FINAL_REPORT="$ROOT/$EVIDENCE_ROOT/report.json"
THRESHOLDS=(0.45 0.50 0.55 0.60)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final) ;;
  *) echo "usage: $0 [development|final]" >&2; exit 2 ;;
esac
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls" "$ARTIFACTS/frozen" "$MODEL_CACHE" "$EVIDENCE_ROOT"

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

threshold_key() { printf '%s' "$1" | tr . p; }

job_id() {
  local corpus="$1" threshold="$2" prefix code
  [[ "$corpus" == qudu2fx3ncc ]] && prefix=60000001 || prefix=60000002
  code="$(printf '%03d' "$(awk -v value="$threshold" 'BEGIN { print value * 100 }')")"
  echo "$prefix-0000-4000-8000-000000000$code"
}

e06_directory() {
  echo "$FROZEN_ROOT/.build/benchmarks/high-quality/offline-acceptance/qwen-ja/$1"
}

source_path() { jq -er .sourcePath "$(e06_directory "$1")/run-meta.json"; }
corpus_manifest() { echo "$ROOT/docs/japanese-live/corpora/$1/manifest.json"; }

upstream_evidence() {
  [[ "$1" == qudu2fx3ncc ]] \
    && echo "$ROOT/docs/japanese-live/experiments/evidence/E16/development-quantized-raw-asr.json.gz" \
    || echo "$ROOT/docs/japanese-live/experiments/evidence/E16/holdout-quantized-raw-asr.json.gz"
}

materialized_evidence() {
  local corpus="$1" output="$ARTIFACTS/frozen/$1.json" source
  source="$(upstream_evidence "$corpus")"
  if [[ ! -f "$output" ]]; then
    gzip -dc "$source" >"$output"
  fi
  [[ "$(shasum -a 256 "$output" | awk '{print $1}')" \
    == "$(gzip -dc "$source" | shasum -a 256 | awk '{print $1}')" ]]
  echo "$output"
}

verify_frozen_input() {
  local corpus="$1" source manifest evidence expected
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  evidence="$(materialized_evidence "$corpus")"
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

execution_paths() {
  printf '%s\n' \
    Sources/HighQualitySpeakerKitRuntime.swift \
    Tests/HighQualityAcceptanceTests.swift \
    Scripts/run_speakerkit_threshold_experiment.sh \
    Scripts/report_speakerkit_threshold.py \
    Scripts/report_exclusive_reconciliation.py \
    Scripts/report_high_quality_acceptance.py \
    Scripts/report_speakerkit_precision.py
}

implementation_hashes() {
  local result='{}' path digest
  while IFS= read -r path; do
    digest="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    result="$(jq -c --arg path "$path" --arg digest "$digest" \
      '. + {($path):$digest}' <<<"$result")"
  done < <(execution_paths)
  echo "$result"
}

snapshot_sources() {
  local directory="$ROOT/$EVIDENCE_ROOT/execution-sources" result='{}' path snapshot
  mkdir -p "$directory"
  while IFS= read -r path; do
    snapshot="$directory/$(printf '%s' "$path" | tr / _)"
    if [[ -e "$snapshot" ]]; then
      cmp "$ROOT/$path" "$snapshot" >/dev/null || {
        echo "Execution source changed after the first retained snapshot: $path" >&2
        return 1
      }
    else
      cp "$ROOT/$path" "$snapshot"
    fi
    result="$(jq -c --arg path "$path" \
      --arg snapshot "$EVIDENCE_ROOT/execution-sources/$(basename "$snapshot")" \
      '. + {($path):$snapshot}' <<<"$result")"
  done < <(execution_paths)
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

run_controls() {
  run_logged "$ARTIFACTS/controls/build-route.log" xcrun swift test \
    --filter HighQualityAcceptanceTests/testFrozenSpeakerKitThresholdWhenOptedIn
  run_logged "$ARTIFACTS/controls/mlx-metallib.log" \
    bash Scripts/build_mlx_metallib.sh debug
  xcrun swift test --skip-build \
    --filter 'HighQualityJobTests|HighQualityTranslationIntegrityTests|HeavyweightModelGateTests|LiveCaptionTests/testTranslationOnlyPrimarySegmentsDropMissingTranslations|LiveCaptionTests/testClearlyNonEnglishTranslationIsRejected|LiveCaptionTests/testEachPrototypeLoadsOnlyItsRequiredModels|QwenPseudoLiveCoordinatorTests/testPseudoLiveEngineNeverRequestsAppleSpeech|LocalDiarizationShadowTests/testUnpromotedDiarizationCannotInfluenceSubtitleBoundaries' \
    >"$ARTIFACTS/controls/light-tests.log" 2>&1
  tail -n 40 "$ARTIFACTS/controls/light-tests.log"
  python3 Scripts/report_speakerkit_threshold.py --self-test
  jq -n \
    --arg buildPath "$EVIDENCE_ROOT/control-build-route.log" \
    --arg buildHash "$(shasum -a 256 "$ARTIFACTS/controls/build-route.log" | awk '{print $1}')" \
    --arg lightPath "$EVIDENCE_ROOT/control-light-tests.log" \
    --arg lightHash "$(shasum -a 256 "$ARTIFACTS/controls/light-tests.log" | awk '{print $1}')" \
    --arg mlxPath "$EVIDENCE_ROOT/control-mlx-metallib.log" \
    --arg mlxHash "$(shasum -a 256 "$ARTIFACTS/controls/mlx-metallib.log" | awk '{print $1}')" \
    '{buildAndJobTests:true,cancellationTests:true,memoryGateTests:true,
      translationTests:true,liveTests:true,artifactReporterSelfTest:true,
      rawLogs:{buildRoute:{path:$buildPath,sha256:$buildHash},
        lightTests:{path:$lightPath,sha256:$lightHash},
        mlxMetallib:{path:$mlxPath,sha256:$mlxHash}}}' \
    >"$ARTIFACTS/controls.json"
  cp "$ARTIFACTS/controls.json" "$ROOT/$EVIDENCE_ROOT/controls.json"
  cp "$ARTIFACTS/controls/build-route.log" "$ROOT/$EVIDENCE_ROOT/control-build-route.log"
  cp "$ARTIFACTS/controls/light-tests.log" "$ROOT/$EVIDENCE_ROOT/control-light-tests.log"
  cp "$ARTIFACTS/controls/mlx-metallib.log" "$ROOT/$EVIDENCE_ROOT/control-mlx-metallib.log"
}

settings_json() {
  local result='{}' threshold key setting
  for threshold in "$@"; do
    key="$(threshold_key "$threshold")"
    setting="$(jq -n --argjson threshold "$threshold" \
      '{precision:"quantized",segmenterVariant:"W8A16",embedderVariant:"W8A16",
        useExclusiveReconciliation:false,
        principalAttribution:"longest-overlap-stable-label-span",
        numberOfSpeakers:null,minActiveOffset:null,
        clusterDistanceThreshold:$threshold,minClusterSize:null,
        fullRedundancy:true,centroidSource:"finalAssignment",clipTimestamps:[]}')"
    result="$(jq -c --arg key "$key" --argjson setting "$setting" \
      '. + {($key):$setting}' <<<"$result")"
  done
  echo "$result"
}

jobs_json() {
  local corpus="$1" result='{}' threshold key
  shift
  for threshold in "$@"; do
    key="$(threshold_key "$threshold")"
    result="$(jq -c --arg key "$key" --arg job "$(job_id "$corpus" "$threshold")" \
      '. + {($key):$job}' <<<"$result")"
  done
  echo "$result"
}

write_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" role settings jobs source manifest upstream
  local uncertainty snapshots implementation unchanged selected="$2"
  shift 2
  local thresholds=("$@")
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  upstream="$(upstream_evidence "$corpus")"
  role="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo untouched-holdout)"
  uncertainty="$([[ "$corpus" == qudu2fx3ncc ]] \
    && echo 'SPEAKER_13 is a group-reaction/overlap pseudo-speaker excluded from acoustic identity scoring; timing remains reference-limited.' \
    || echo 'Sparse overlap annotations and reference timing remain uncertain.')"
  settings="$(settings_json "${thresholds[@]}")"
  jobs="$(jobs_json "$corpus" "${thresholds[@]}")"
  snapshots="$(snapshot_sources)"
  implementation="$(implementation_hashes)"
  unchanged="$(unchanged_implementation_hashes)"
  mkdir -p "$directory/jobs"
  jq -n \
    --arg corpus "$corpus" --arg role "$role" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg manifest "docs/japanese-live/corpora/$corpus/manifest.json" \
    --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg upstream "${upstream#$ROOT/}" \
    --arg upstreamHash "$(gzip -dc "$upstream" | shasum -a 256 | awk '{print $1}')" \
    --arg controls "$EVIDENCE_ROOT/controls.json" \
    --arg controlsHash "$(shasum -a 256 "$ROOT/$EVIDENCE_ROOT/controls.json" | awk '{print $1}')" \
    --arg baseCommit "$BASE_COMMIT" \
    --arg packageRevision "$(jq -r '.pins[] | select(.identity=="whisperkit") | .state.revision' Package.resolved)" \
    --arg uncertainty "$uncertainty" --arg selected "$selected" \
    --arg developmentReport "$EVIDENCE_ROOT/development-report.json" \
    --arg developmentReportHash "$([[ -f "$DEVELOPMENT_REPORT" ]] && shasum -a 256 "$DEVELOPMENT_REPORT" | awk '{print $1}' || true)" \
    --argjson settings "$settings" --argjson jobs "$jobs" \
    --argjson implementation "$implementation" --argjson snapshots "$snapshots" \
    --argjson unchanged "$unchanged" \
    '{schemaVersion:1,experiment:"E17-speakerkit-clustering-threshold",
      corpusID:$corpus,corpusRole:$role,
      sourcePath:$source,sourceSHA256:$sourceHash,
      corpusManifestPath:$manifest,corpusManifestSHA256:$manifestHash,
      frozenUpstreamEvidencePath:$upstream,
      frozenUpstreamEvidenceContentSHA256:$upstreamHash,
      baselineEvidencePath:$upstream,
      controlEvidencePath:$controls,controlEvidenceSHA256:$controlsHash,
      jobs:$jobs,baseCommit:$baseCommit,
      speakerKit:{modelID:"argmaxinc/speakerkit-coreml",
        revision:"86ec9c929b52208b6656eb6a6361ed0d822a1f78",
        packageRevision:$packageRevision,
        variants:{segmenter:"W8A16",embedder:"W8A16",clusterer:"W32A32"}},
      settings:$settings,
      referenceAnnotations:{pseudoSpeakers:(if $corpus=="qudu2fx3ncc" then
        {SPEAKER_13:"group-reaction/overlap annotation; not one acoustic identity"}
        else {} end),uncertainty:$uncertainty},
      failurePolicy:{candidateAttribution:"withheld until build, source, input, artifact, model-preparation, serialization and baseline controls pass"},
      executionImplementationSHA256:$implementation,
      executionSourceSnapshots:$snapshots,
      reviewedImplementationSHA256:$implementation,
      unchangedImplementations:$unchanged}
      + (if $selected=="" then {} else
        {selectedThreshold:($selected|tonumber),jobID:$jobs[($selected|gsub("\\.";"p"))],
          developmentReportPath:$developmentReport,
          developmentReportSHA256:$developmentReportHash} end)' \
    >"$directory/run-meta.json"
}

check_variant() {
  local corpus="$1" threshold="$2" key="$(threshold_key "$2")" directory="$ARTIFACTS/$1" job
  job="$directory/jobs/$(job_id "$corpus" "$threshold")"
  jq -e '.status == "completed" and .failures == []
    and ([.modelEvents[] | select(.modelID == "argmaxinc/speakerkit-coreml") | .kind]
      | index("load-completed") != null and index("unload-completed") != null
        and index("memory-release-checked") != null and index("guard-failed") == null)' \
    "$job/manifest.json" >/dev/null
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$(corpus_manifest "$corpus")")" \
    '.sampleCount == $samples and .failures == []
      and .diarization.useExclusiveReconciliation == false
      and (.diarization.rawSpans | length > 0)
      and (.diarization.mappings | length > 0)
      and .diarization.validationDiagnostics == []
      and ((.diarization.mappings | length)
        == ([.diarization.mappings[].alignmentItemIndex] | unique | length))
      and .translation.validationFailures == []' "$job/raw-asr.json" >/dev/null
  grep -F "clusterDistanceThreshold=$threshold" "$directory/$key.log" >/dev/null
  for name in japanese-transcript.txt english-translation-transcript.txt \
    english-subtitles.vtt english-subtitles.srt raw-asr.json manifest.json; do
    [[ -s "$job/$name" ]]
  done
}

diagnose_failure() {
  local corpus="$1" threshold="$2" key="$(threshold_key "$2")" directory="$ARTIFACTS/$1"
  local log="$directory/$key-infrastructure-diagnostics.log" classification stage raw
  local build=false source=false inputs=false artifacts=false modelCache=false
  if xcrun swift build >"$log" 2>&1; then build=true; fi
  if [[ "$(shasum -a 256 "$(source_path "$corpus")" | awk '{print $1}')" \
      == "$(jq -r .sourceSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]]; then source=true; fi
  if jq empty "$(materialized_evidence "$corpus")" "$(corpus_manifest "$corpus")" \
      >>"$log" 2>&1; then inputs=true; fi
  if find "$directory/jobs" -name '*.json' -type f -exec jq empty {} + \
      >>"$log" 2>&1; then artifacts=true; fi
  if find "$MODEL_CACHE" -type f -print -quit | grep -q .; then modelCache=true; fi
  if [[ "$build" != true ]]; then classification=runner-build
  elif [[ "$source" != true || "$inputs" != true ]]; then classification=runner-input
  elif [[ "$artifacts" != true ]]; then classification=runner-artifact
  elif [[ "$modelCache" != true ]]; then classification=model-preparation
  else classification=application-runtime; fi
  raw="$(find "$directory/jobs" -name raw-asr.json -type f -print -quit)"
  stage=unknown
  [[ -z "$raw" ]] || stage="$(jq -r '.failures[-1].stage // "unknown"' "$raw")"
  python3 Scripts/report_speakerkit_precision.py \
    --inventory-cache "$MODEL_CACHE" \
    --inventory-output "$directory/$key-model-cache-manifest.json" || true
  jq -n --arg classification "$classification" --arg stage "$stage" \
    --arg threshold "$threshold" --argjson build "$build" --argjson source "$source" \
    --argjson inputs "$inputs" --argjson artifacts "$artifacts" --argjson modelCache "$modelCache" \
    '{classification:$classification,candidateAttribution:"withheld",
      clusterDistanceThreshold:($threshold|tonumber),failingStage:$stage,
      runnerBuild:$build,sourceIntegrity:$source,inputJSON:$inputs,
      artifactJSON:$artifacts,modelCachePresent:$modelCache}' \
    >"$directory/$key-infrastructure-diagnostics.json"
  echo "Run failed; diagnostic attribution retained at $directory" >&2
}

run_variant() {
  local corpus="$1" threshold="$2" key="$(threshold_key "$2")" directory="$ARTIFACTS/$1" job
  job="$directory/jobs/$(job_id "$corpus" "$threshold")"
  verify_frozen_input "$corpus"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' \
      "$job/manifest.json" >/dev/null 2>&1; then
    echo "Reusing completed threshold $threshold: $corpus"
    check_variant "$corpus" "$threshold"
    return
  fi
  if [[ -e "$job" ]]; then
    echo "Incomplete run retained at $job; refusing to overwrite it." >&2
    return 1
  fi
  if ! run_logged "$directory/$key.log" env \
      WHISPERASR_RUN_SPEAKERKIT_THRESHOLD_EXPERIMENT=1 \
      WHISPERASR_SPEAKERKIT_THRESHOLD_EVIDENCE="$(materialized_evidence "$corpus")" \
      WHISPERASR_SPEAKERKIT_THRESHOLD_SOURCE="$(source_path "$corpus")" \
      WHISPERASR_SPEAKERKIT_THRESHOLD_OUTPUT="$directory/jobs" \
      WHISPERASR_SPEAKERKIT_THRESHOLD_JOB_ID="$(job_id "$corpus" "$threshold")" \
      WHISPERASR_SPEAKERKIT_THRESHOLD="$threshold" \
      WHISPERASR_SPEAKERKIT_MODEL_CACHE="$MODEL_CACHE" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testFrozenSpeakerKitThresholdWhenOptedIn; then
    diagnose_failure "$corpus" "$threshold"
    return 1
  fi
  check_variant "$corpus" "$threshold"
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
  local corpus="$1" directory="$ARTIFACTS/$1" uncertainty artifacts='{}' logs='{}' scorers='{}'
  shift
  local thresholds=("$@") threshold key job scorer
  uncertainty="$(jq -r .referenceAnnotations.uncertainty "$directory/run-meta.json")"
  for threshold in "${thresholds[@]}"; do
    key="$(threshold_key "$threshold")"
    job="$directory/jobs/$(job_id "$corpus" "$threshold")"
    scorer="$directory/$key-scorer-input.json.gz"
    python3 Scripts/report_speakerkit_threshold.py --make-scorer-input \
      --manifest "$(corpus_manifest "$corpus")" --raw "$job/raw-asr.json" \
      --output "$scorer" --corpus "$corpus" --threshold "$threshold" \
      --reference-uncertainty "$uncertainty"
    artifacts="$(jq -c --arg key "$key" --argjson value "$(artifact_hashes "$job")" \
      '. + {($key):$value}' <<<"$artifacts")"
    logs="$(jq -c --arg key "$key" \
      --arg value "$(shasum -a 256 "$directory/$key.log" | awk '{print $1}')" \
      '. + {($key):$value}' <<<"$logs")"
    scorers="$(jq -c --arg key "$key" \
      --arg value "$(gzip -dc "$scorer" | shasum -a 256 | awk '{print $1}')" \
      '. + {($key):$value}' <<<"$scorers")"
  done
  python3 Scripts/report_speakerkit_precision.py \
    --inventory-cache "$MODEL_CACHE" --inventory-output "$MODEL_INVENTORY"
  jq --argjson artifacts "$artifacts" --argjson logs "$logs" --argjson scorers "$scorers" \
    --arg inventory "$EVIDENCE_ROOT/model-cache-manifest.json" \
    --arg inventoryHash "$(shasum -a 256 "$MODEL_INVENTORY" | awk '{print $1}')" \
    --argjson reviewed "$(implementation_hashes)" \
    '. + {artifactSHA256:$artifacts,runLogSHA256:$logs,
      scorerInputContentSHA256:$scorers,modelInventoryPath:$inventory,
      modelInventorySHA256:$inventoryHash,reviewedImplementationSHA256:$reviewed}' \
    "$directory/run-meta.json" >"$directory/run-meta.updated.json"
  mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
}

snapshot_runs() {
  local corpus="$1" split directory="$ARTIFACTS/$1" threshold key job
  shift
  local thresholds=("$@")
  split="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)"
  for threshold in "${thresholds[@]}"; do
    key="$(threshold_key "$threshold")"
    job="$directory/jobs/$(job_id "$corpus" "$threshold")"
    gzip -n -c "$job/raw-asr.json" >"$ROOT/$EVIDENCE_ROOT/$split-$key-raw-asr.json.gz"
    cp "$job/manifest.json" "$ROOT/$EVIDENCE_ROOT/$split-$key-manifest.json"
    cp "$directory/$key.log" "$ROOT/$EVIDENCE_ROOT/$split-$key.log"
    cp "$directory/$key-scorer-input.json.gz" \
      "$ROOT/$EVIDENCE_ROOT/$split-$key-scorer-input.json.gz"
  done
  cp "$directory/run-meta.json" "$ROOT/$EVIDENCE_ROOT/$split-run-meta.json"
  cp "$MODEL_INVENTORY" "$ROOT/$EVIDENCE_ROOT/model-cache-manifest.json"
}

if [[ "$MODE" == development ]]; then
  [[ ! -f "$DEVELOPMENT_REPORT" ]] || {
    echo "Retained development decision already exists; refusing to overwrite it." >&2
    exit 1
  }
  run_controls
  verify_frozen_input qudu2fx3ncc
  write_metadata qudu2fx3ncc "" "${THRESHOLDS[@]}"
  for threshold in "${THRESHOLDS[@]}"; do run_variant qudu2fx3ncc "$threshold"; done
  finalize_metadata qudu2fx3ncc "${THRESHOLDS[@]}"
  snapshot_runs qudu2fx3ncc "${THRESHOLDS[@]}"
  python3 Scripts/report_speakerkit_threshold.py "$ARTIFACTS" \
    --json "$DEVELOPMENT_REPORT" --markdown "$REPORT_MD"
  jq '{selectedThreshold:.development.selectedThreshold,
    developmentPromotionEligible:.development.developmentPromotionEligible,decision}' \
    "$DEVELOPMENT_REPORT"
  exit 0
fi

[[ -f "$DEVELOPMENT_REPORT" && -f "$ROOT/$EVIDENCE_ROOT/development-run-meta.json" ]] || {
  echo "Run the development sweep first." >&2
  exit 1
}
jq -e '.development.developmentPromotionEligible == true and .holdoutRun == false' \
  "$DEVELOPMENT_REPORT" >/dev/null || {
  echo "Development did not pass; untouched holdout will not be opened." >&2
  exit 1
}
selected="$(jq -r '.development.selectedThreshold | @text' "$DEVELOPMENT_REPORT")"
verify_frozen_input md62mmdz0m
write_metadata md62mmdz0m "$selected" "$selected"
run_variant md62mmdz0m "$selected"
finalize_metadata md62mmdz0m "$selected"
snapshot_runs md62mmdz0m "$selected"
python3 Scripts/report_speakerkit_threshold.py "$ARTIFACTS" \
  --development-report "$DEVELOPMENT_REPORT" \
  --json "$FINAL_REPORT" --markdown "$REPORT_MD"
jq '{promote,decision}' "$FINAL_REPORT"
