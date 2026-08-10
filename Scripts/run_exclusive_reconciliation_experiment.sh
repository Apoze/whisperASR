#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROZEN_ROOT="${WHISPERASR_FROZEN_REPO_ROOT:-/Users/maz/Documents/projets/whisperASR}"
ARTIFACTS="${WHISPERASR_EXCLUSIVE_RECONCILIATION_ROOT:-$ROOT/.build/benchmarks/exclusive-reconciliation}"
MODE="${1:-development}"
BASE_COMMIT="6dcbfdb017ffc55b3fc376994ac00e39cd025155"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E15-exclusive-reconciliation.md"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final) ;;
  *) echo "usage: $0 [development|final]" >&2; exit 2 ;;
esac
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls"

run_logged() {
  local log="$1"
  shift
  if "$@" >"$log" 2>&1; then
    tail -n 40 "$log"
    return 0
  fi
  tail -n 40 "$log"
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

runtime_evidence() {
  find "$(e06_directory "$1")/jobs" -name raw-asr.json -type f -print -quit
}

corpus_manifest() {
  echo "$ROOT/docs/japanese-live/corpora/$1/manifest.json"
}

job_id() {
  [[ "$1" == qudu2fx3ncc ]] \
    && echo 57000001-0000-4000-8000-000000000001 \
    || echo 57000002-0000-4000-8000-000000000001
}

source_path() {
  jq -er .sourcePath "$(e06_directory "$1")/run-meta.json"
}

verify_frozen_input() {
  local corpus="$1" source manifest baseline runtime expected
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  baseline="$(baseline_evidence "$corpus")"
  runtime="$(runtime_evidence "$corpus")"
  [[ -f "$source" && -f "$manifest" && -f "$baseline" && -f "$runtime" ]]
  expected="$(jq -er .sourceSHA256 "$(e06_directory "$corpus")/run-meta.json")"
  [[ "$(shasum -a 256 "$source" | awk '{print $1}')" == "$expected" ]]
  [[ "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    == "$(jq -er .manifestSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]]
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" \
    '.sampleCount == $samples and .model.backend == "qwen-ja"
      and (.rawASR | length > 0)
      and (.alignment.chunks | length > 0)
      and (.alignment.mergedCues | length > 0)
      and (.diarization.rawSpans | length > 0)
      and ((.diarization.mappings | length)
        == ([.diarization.mappings[].alignmentItemIndex] | unique | length))' \
    "$baseline" >/dev/null
  jq empty "$runtime"
}

run_controls() {
  local log="$ARTIFACTS/controls/light-tests.log"
  run_logged "$ARTIFACTS/controls/build-route.log" xcrun swift test \
    --filter HighQualityJobTests/testExclusiveSpeakerReconciliationIsAuditableAndKeepsOneTranslationPerUnit
  run_logged "$ARTIFACTS/controls/mlx-metallib.log" \
    bash Scripts/build_mlx_metallib.sh debug
  xcrun swift test --skip-build \
    --filter 'HighQualityJobTests|HighQualityTranslationIntegrityTests|HeavyweightModelGateTests|LiveCaptionTests/testTranslationOnlyPrimarySegmentsDropMissingTranslations|LiveCaptionTests/testClearlyNonEnglishTranslationIsRejected|LiveCaptionTests/testEachPrototypeLoadsOnlyItsRequiredModels|QwenPseudoLiveCoordinatorTests/testPseudoLiveEngineNeverRequestsAppleSpeech|LocalDiarizationShadowTests/testUnpromotedDiarizationCannotInfluenceSubtitleBoundaries' \
    >"$log" 2>&1
  tail -n 40 "$log"
  run_logged "$ARTIFACTS/controls/principal-replay.log" env \
    WHISPERASR_RUN_PRINCIPAL_SPEAKER_EXPERIMENT=1 \
    WHISPERASR_PRINCIPAL_SPEAKER_EVIDENCE="$(baseline_evidence qudu2fx3ncc)" \
    WHISPERASR_PRINCIPAL_SPEAKER_OUTPUT="$ARTIFACTS/controls/principal-replay" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testFrozenPrincipalSpeakerAttributionWhenOptedIn
  python3 Scripts/report_exclusive_reconciliation.py --self-test
  jq -n '{buildAndJobTests:true, baselinePrincipalReplay:true,
    cancellationAndRenameTests:true, translationTests:true, liveTests:true,
    artifactReporterSelfTest:true}' >"$ARTIFACTS/controls.json"
}

implementation_hashes() {
  local result='{}' path digest
  for path in \
    Sources/HighQualityJob.swift Sources/HighQualitySpeakerKitRuntime.swift \
    Tests/HighQualityJobTests.swift Tests/HighQualityAcceptanceTests.swift \
    Scripts/run_exclusive_reconciliation_experiment.sh \
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
  local corpus="$1" directory="$ARTIFACTS/$1" baseline runtime manifest source role pseudo split
  local implementation unchanged e06meta
  baseline="$(baseline_evidence "$corpus")"
  runtime="$(runtime_evidence "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  source="$(source_path "$corpus")"
  e06meta="$(e06_directory "$corpus")/run-meta.json"
  role="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo untouched-holdout)"
  split="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)"
  pseudo="$([[ "$corpus" == qudu2fx3ncc ]] \
    && jq -nc '{"SPEAKER_13":"group-reaction/overlap annotation; not one acoustic identity"}' \
    || jq -nc '{}')"
  implementation="$(implementation_hashes)"
  unchanged="$(unchanged_implementation_hashes)"
  mkdir -p "$directory/jobs"
  jq -n \
    --arg corpus "$corpus" --arg role "$role" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg manifest "$manifest" --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg baseline "$baseline" --arg baselineHash "$(shasum -a 256 "$baseline" | awk '{print $1}')" \
    --arg runtime "$runtime" --arg runtimeHash "$(shasum -a 256 "$runtime" | awk '{print $1}')" \
    --arg runtimeSnapshot "docs/japanese-live/experiments/evidence/E15/$split-baseline-runtime-raw-asr.json.gz" \
    --arg jobID "$(job_id "$corpus")" --arg baseCommit "$BASE_COMMIT" \
    --arg speakerModel "$(jq -r .fixedModels.speakerKit.modelID "$e06meta")" \
    --arg speakerRevision "$(jq -r .fixedModels.speakerKit.revision "$e06meta")" \
    --arg whisperKitRevision "$(jq -r '.pins[] | select(.identity=="whisperkit") | .state.revision' Package.resolved)" \
    --argjson pseudo "$pseudo" --argjson implementation "$implementation" \
    --argjson unchanged "$unchanged" \
    '{schemaVersion:1, experiment:"E15-exclusive-reconciliation",
      corpusID:$corpus, corpusRole:$role,
      sourcePath:$source, sourceSHA256:$sourceHash,
      corpusManifestPath:$manifest, corpusManifestSHA256:$manifestHash,
      baselineEvidencePath:$baseline, baselineEvidenceSHA256:$baselineHash,
      baselineRuntimeEvidencePath:$runtime, baselineRuntimeEvidenceSHA256:$runtimeHash,
      baselineRuntimeSnapshotPath:$runtimeSnapshot,
      candidateJobID:$jobID, baseCommit:$baseCommit,
      speakerKit:{modelID:$speakerModel,revision:$speakerRevision,
        packageRevision:$whisperKitRevision},
      settings:{
        baseline:{useExclusiveReconciliation:false,precision:"pinned-coreml-artifact",
          numberOfSpeakers:null,minActiveOffset:null,clusterDistanceThreshold:null,
          minClusterSize:null,fullRedundancy:true,centroidSource:"finalAssignment",
          clipTimestamps:[]},
        candidate:{useExclusiveReconciliation:true,precision:"pinned-coreml-artifact",
          numberOfSpeakers:null,minActiveOffset:null,clusterDistanceThreshold:null,
          minClusterSize:null,fullRedundancy:true,centroidSource:"finalAssignment",
          clipTimestamps:[]}},
      referenceAnnotations:{pseudoSpeakers:$pseudo},
      executionImplementationSHA256:$implementation,
      reviewedImplementationSHA256:$implementation,
      unchangedImplementations:$unchanged}' >"$directory/run-meta.json"
}

finalize_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" job temporary split implementation
  job="$directory/jobs/$(job_id "$corpus")"
  temporary="$directory/run-meta.updated.json"
  split="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)"
  implementation="$(implementation_hashes)"
  jq -e '.executionImplementationSHA256 | type == "object" and length > 0' \
    "$directory/run-meta.json" >/dev/null || {
      echo "Missing immutable execution hashes; refusing to relabel reused evidence." >&2
      return 1
    }
  jq \
    --arg raw "$(shasum -a 256 "$job/raw-asr.json" | awk '{print $1}')" \
    --arg manifest "$(shasum -a 256 "$job/manifest.json" | awk '{print $1}')" \
    --arg runtimeSnapshot "docs/japanese-live/experiments/evidence/E15/$split-baseline-runtime-raw-asr.json.gz" \
    --argjson implementation "$implementation" \
    '. + {candidateArtifactSHA256:{"raw-asr.json":$raw,"manifest.json":$manifest},
      baselineRuntimeSnapshotPath:$runtimeSnapshot,
      reviewedImplementationSHA256:$implementation} | del(.implementationSHA256)' \
    "$directory/run-meta.json" >"$temporary"
  mv "$temporary" "$directory/run-meta.json"
}

check_candidate() {
  local corpus="$1" directory="$ARTIFACTS/$1" job manifest
  job="$directory/jobs/$(job_id "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  jq -e '.status == "completed" and .failures == []' "$job/manifest.json" >/dev/null
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" \
    '.sampleCount == $samples and .failures == []
      and .diarization.useExclusiveReconciliation == true
      and (.diarization.rawSpans | length > 0)
      and .diarization.overlapRanges == []
      and .diarization.validationDiagnostics == []
      and ((.diarization.mappings | length)
        == ([.diarization.mappings[].alignmentItemIndex] | unique | length))
      and .translation.validationFailures == []' "$job/raw-asr.json" >/dev/null
  jq empty "$job/manifest.json" "$job/raw-asr.json"
}

diagnose_failure() {
  local corpus="$1" directory="$ARTIFACTS/$1" log="$ARTIFACTS/$1/infrastructure-diagnostics.log"
  local build=false source=false inputs=false artifacts=false classification stage="unknown"
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
  else classification=candidate-product-or-speakerkit; fi
  if find "$directory/jobs" -name raw-asr.json -type f -print -quit | grep -q .; then
    stage="$(find "$directory/jobs" -name raw-asr.json -type f -print -quit \
      | xargs jq -r '.failures[-1].stage // "none"')"
  fi
  jq -n --arg classification "$classification" --arg stage "$stage" \
    --argjson build "$build" --argjson source "$source" \
    --argjson inputs "$inputs" --argjson artifacts "$artifacts" \
    '{classification:$classification,failingStage:$stage,
      runnerBuild:$build,sourceIntegrity:$source,inputJSON:$inputs,artifactJSON:$artifacts}' \
    >"$directory/infrastructure-diagnostics.json"
  echo "Candidate failed; retained evidence and diagnosis at $directory" >&2
}

run_candidate() {
  local corpus="$1" directory="$ARTIFACTS/$1" job log
  job="$directory/jobs/$(job_id "$corpus")"
  log="$directory/run.log"
  verify_frozen_input "$corpus"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' \
      "$job/manifest.json" >/dev/null 2>&1; then
    echo "Reusing completed exclusive run: $corpus"
    check_candidate "$corpus"
    finalize_metadata "$corpus"
    return
  fi
  if [[ -e "$job" ]]; then
    echo "Incomplete run retained at $job; refusing to overwrite or rerun it." >&2
    return 1
  fi
  write_metadata "$corpus"
  if ! run_logged "$log" env \
      WHISPERASR_RUN_EXCLUSIVE_RECONCILIATION_EXPERIMENT=1 \
      WHISPERASR_EXCLUSIVE_RECONCILIATION_EVIDENCE="$(baseline_evidence "$corpus")" \
      WHISPERASR_EXCLUSIVE_RECONCILIATION_SOURCE="$(source_path "$corpus")" \
      WHISPERASR_EXCLUSIVE_RECONCILIATION_OUTPUT="$directory/jobs" \
      WHISPERASR_EXCLUSIVE_RECONCILIATION_JOB_ID="$(job_id "$corpus")" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testFrozenExclusiveSpeakerReconciliationWhenOptedIn; then
    diagnose_failure "$corpus"
    return 1
  fi
  check_candidate "$corpus"
  finalize_metadata "$corpus"
}

write_report() {
  python3 Scripts/report_exclusive_reconciliation.py "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
}

snapshot_evidence() {
  local corpus="$1" split evidence job
  split="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)"
  evidence="$ROOT/docs/japanese-live/experiments/evidence/E15"
  job="$ARTIFACTS/$corpus/jobs/$(job_id "$corpus")"
  mkdir -p "$evidence"
  gzip -n -c "$(baseline_evidence "$corpus")" \
    >"$evidence/$split-baseline-raw-asr.json.gz"
  gzip -n -c "$(runtime_evidence "$corpus")" \
    >"$evidence/$split-baseline-runtime-raw-asr.json.gz"
  gzip -n -c "$job/raw-asr.json" \
    >"$evidence/$split-exclusive-raw-asr.json.gz"
  cp "$job/manifest.json" "$evidence/$split-exclusive-manifest.json"
  cp "$ARTIFACTS/$corpus/run-meta.json" "$evidence/$split-run-meta.json"
  cp "$ARTIFACTS/$corpus/run.log" "$evidence/$split-run.log"
  cp "$ARTIFACTS/controls.json" "$evidence/controls.json"
}

snapshot_report() {
  cp "$REPORT_JSON" "$ROOT/docs/japanese-live/experiments/evidence/E15/report.json"
}

if [[ "$MODE" == development ]]; then
  verify_frozen_input qudu2fx3ncc
  run_controls
  run_candidate qudu2fx3ncc
  snapshot_evidence qudu2fx3ncc
  write_report
  snapshot_report
  jq '{developmentPromotionEligible,decision}' "$REPORT_JSON"
  exit 0
fi

[[ -f "$REPORT_JSON" && -f "$ARTIFACTS/controls.json" ]] || {
  echo "Run the development experiment first." >&2
  exit 1
}
jq -e '.developmentPromotionEligible == true' "$REPORT_JSON" >/dev/null || {
  echo "Development did not pass; untouched holdout will not be run." >&2
  exit 1
}
run_candidate md62mmdz0m
snapshot_evidence md62mmdz0m
write_report
snapshot_report
jq '{promote,decision}' "$REPORT_JSON"
