#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROZEN_ROOT="${WHISPERASR_FROZEN_REPO_ROOT:-/Users/maz/Documents/projets/whisperASR}"
ARTIFACTS="${WHISPERASR_FLUID_AUDIO_ROOT:-$ROOT/.build/benchmarks/fluid-audio-offline}"
SPEAKERKIT_CACHE="$ARTIFACTS/speakerkit-model-cache"
FLUID_CACHE="$ARTIFACTS/fluid-audio-model-cache"
MODE="${1:-development}"
BASE_COMMIT="f6dbfa652a054bd2620edc04a1d52eb077dfbe9b"
EVIDENCE_ROOT="docs/japanese-live/experiments/evidence/E18"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E18-fluid-audio-offline.md"
DEVELOPMENT_REPORT="$ROOT/$EVIDENCE_ROOT/development-report.json"
DEVELOPMENT_FREEZE="$ROOT/$EVIDENCE_ROOT/development-report.sha256"
FINAL_REPORT="$ROOT/$EVIDENCE_ROOT/report.json"
FLUID_REVISION="1ed7a662fdc7109e36d822db793ee6eebdaf8594"
ENGINES=(speakerkit fluid-audio-offline)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final) ;;
  *) echo "usage: $0 [development|final]" >&2; exit 2 ;;
esac
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls" "$ARTIFACTS/frozen" \
  "$SPEAKERKIT_CACHE" "$FLUID_CACHE" "$EVIDENCE_ROOT"

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

corpus_metadata() {
  case "$1" in
    qudu2fx3ncc)
      jq -cn '{jobPrefix:"61000001",role:"development",split:"development",
        upstreamEvidence:"docs/japanese-live/experiments/evidence/E16/development-quantized-raw-asr.json.gz",
        uncertainty:"SPEAKER_13 is a group-reaction/overlap pseudo-speaker excluded from acoustic identity scoring; timing remains reference-limited.",
        pseudoSpeakers:{SPEAKER_13:"group-reaction/overlap annotation; not one acoustic identity"}}'
      ;;
    md62mmdz0m)
      jq -cn '{jobPrefix:"61000002",role:"untouched-holdout",split:"holdout",
        upstreamEvidence:"docs/japanese-live/experiments/evidence/E16/holdout-quantized-raw-asr.json.gz",
        uncertainty:"Sparse overlap annotations and reference timing remain uncertain.",
        pseudoSpeakers:{}}'
      ;;
    *) echo "Unknown corpus: $1" >&2; return 1 ;;
  esac
}

corpus_value() { corpus_metadata "$1" | jq -er --arg key "$2" '.[$key]'; }
e06_directory() { echo "$FROZEN_ROOT/.build/benchmarks/high-quality/offline-acceptance/qwen-ja/$1"; }
source_path() { jq -er .sourcePath "$(e06_directory "$1")/run-meta.json"; }
corpus_manifest() { echo "$ROOT/docs/japanese-live/corpora/$1/manifest.json"; }
upstream_evidence() { echo "$ROOT/$(corpus_value "$1" upstreamEvidence)"; }

engine_metadata() {
  case "$1" in
    speakerkit)
      jq -cn --arg cache "$SPEAKERKIT_CACHE" \
        '{suffix:1,cache:$cache,modelID:"argmaxinc/speakerkit-coreml",
          remoteRepository:null,remoteRevision:null,
          runtimeIdentity:"whisperkit",
          runtimeRevision:"1e2a163736dfa5a198e637ae44c114e1c6d5cc2d"}'
      ;;
    fluid-audio-offline)
      jq -cn --arg cache "$FLUID_CACHE" --arg revision "$FLUID_REVISION" \
        '{suffix:2,cache:$cache,
          modelID:"FluidInference/speaker-diarization-coreml/offline",
          remoteRepository:"FluidInference/speaker-diarization-coreml",
          remoteRevision:$revision,runtimeIdentity:"fluidaudio",
          runtimeRevision:"19600a485baa4998812e4654b70d2bab8f2c9949"}'
      ;;
    *) echo "Unknown engine: $1" >&2; return 1 ;;
  esac
}

engine_value() { engine_metadata "$1" | jq -r --arg key "$2" '.[$key] // ""'; }

job_id() {
  local prefix suffix
  prefix="$(corpus_value "$1" jobPrefix)"
  suffix="$(engine_value "$2" suffix)"
  printf '%s-0000-4000-8000-00000000000%d\n' "$prefix" "$suffix"
}

model_cache() { engine_value "$1" cache; }

materialized_evidence() {
  local corpus="$1" output="$ARTIFACTS/frozen/$1.json" source
  source="$(upstream_evidence "$corpus")"
  if [[ ! -f "$output" ]]; then gzip -dc "$source" >"$output"; fi
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
      and (.rawASR | length > 0) and (.alignment.chunks | length > 0)
      and (.alignment.mergedCues | length > 0) and .translation != null' \
    "$evidence" >/dev/null
}

execution_paths() {
  printf '%s\n' \
    Sources/HighQualityJob.swift \
    Sources/HighQualityRuntimeMemorySampler.swift \
    Sources/HighQualitySpeakerKitRuntime.swift \
    Sources/HighQualityFluidAudioRuntime.swift \
    Tests/HighQualityAcceptanceTests.swift \
    Scripts/run_fluid_audio_offline_experiment.sh \
    Scripts/report_fluid_audio_offline.py \
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
        echo "Execution source changed after retained DEV snapshot: $path" >&2
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
    --filter HighQualityAcceptanceTests/testFrozenDiarizerEngineWhenOptedIn
  run_logged "$ARTIFACTS/controls/mlx-metallib.log" \
    bash Scripts/build_mlx_metallib.sh debug
  xcrun swift test --skip-build \
    --filter 'HighQualityJobTests/testAutoAndExpectedSpeakerCountsReachSpeakerKitAndRawEvidence|HighQualityJobTests/testCancellationDuringSpeakerKitReleasesDiarizationRuntime|HighQualityJobTests/testCompleteAttributionIsOptInAndUsesDeterministicNearestSpan|HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts|HighQualityJobTests/testExclusiveSpeakerReconciliationIsAuditableAndKeepsOneTranslationPerUnit|HighQualityJobTests/testSemanticTranslationUnitsIgnoreDiarizationAndPreserveAlignedJapanese|HighQualityJobTests/testSpeakerRenameRegeneratesAllDeliverablesWithoutChangingRawIdentity|HighQualityTranslationIntegrityTests|HeavyweightModelGateTests|LiveCaptionTests/testTranslationOnlyPrimarySegmentsDropMissingTranslations|LiveCaptionTests/testClearlyNonEnglishTranslationIsRejected|LiveCaptionTests/testEachPrototypeLoadsOnlyItsRequiredModels|QwenPseudoLiveCoordinatorTests/testPseudoLiveEngineNeverRequestsAppleSpeech|LocalDiarizationShadowTests/testUnpromotedDiarizationCannotInfluenceSubtitleBoundaries' \
    >"$ARTIFACTS/controls/light-tests.log" 2>&1
  tail -n 40 "$ARTIFACTS/controls/light-tests.log"
  python3 Scripts/report_fluid_audio_offline.py --self-test
  jq -n \
    --arg buildPath "$EVIDENCE_ROOT/control-build-route.log" \
    --arg buildHash "$(shasum -a 256 "$ARTIFACTS/controls/build-route.log" | awk '{print $1}')" \
    --arg lightPath "$EVIDENCE_ROOT/control-light-tests.log" \
    --arg lightHash "$(shasum -a 256 "$ARTIFACTS/controls/light-tests.log" | awk '{print $1}')" \
    --arg mlxPath "$EVIDENCE_ROOT/control-mlx-metallib.log" \
    --arg mlxHash "$(shasum -a 256 "$ARTIFACTS/controls/mlx-metallib.log" | awk '{print $1}')" \
    '{buildAndJobTests:true,cancellationTests:false,memoryGateTests:true,
      translationTests:true,liveTests:true,artifactReporterSelfTest:true,
      rawLogs:{buildRoute:{path:$buildPath,sha256:$buildHash},
        lightTests:{path:$lightPath,sha256:$lightHash},
        mlxMetallib:{path:$mlxPath,sha256:$mlxHash}}}' \
    >"$ARTIFACTS/controls.json"
  cp "$ARTIFACTS/controls.json" "$ROOT/$EVIDENCE_ROOT/controls.json"
  cp "$ARTIFACTS/controls/build-route.log" "$ROOT/$EVIDENCE_ROOT/control-build-route.log"
  cp "$ARTIFACTS/controls/light-tests.log" "$ROOT/$EVIDENCE_ROOT/control-light-tests.log"
  cp "$ARTIFACTS/controls/mlx-metallib.log" "$ROOT/$EVIDENCE_ROOT/control-mlx-metallib.log"
  if [[ -f "$ARTIFACTS/controls/light-tests-hang-attempt1.log" ]]; then
    cp "$ARTIFACTS/controls/light-tests-hang-attempt1.log" \
      "$ROOT/$EVIDENCE_ROOT/control-light-tests-hang-attempt1.log"
    gzip -n -c "$ARTIFACTS/controls/light-tests-hang-attempt1.sample" \
      >"$ROOT/$EVIDENCE_ROOT/control-light-tests-hang-attempt1.sample.txt.gz"
  fi
}

cancellation_job_id() {
  printf '%s-0000-4000-8000-000000000003\n' "$(corpus_value "$1" jobPrefix)"
}

run_fluid_cancellation() {
  local corpus="$1" directory="$ARTIFACTS/$1" id job log
  id="$(cancellation_job_id "$corpus")"
  job="$directory/cancellation-jobs/$id"
  log="$directory/fluid-audio-cancellation.log"
  if [[ ! -f "$job/manifest.json" ]]; then
    run_logged "$log" env \
      WHISPERASR_RUN_FLUID_AUDIO_CANCELLATION=1 \
      WHISPERASR_FLUID_CANCELLATION_EVIDENCE="$(materialized_evidence "$corpus")" \
      WHISPERASR_FLUID_CANCELLATION_SOURCE="$(source_path "$corpus")" \
      WHISPERASR_FLUID_CANCELLATION_OUTPUT="$directory/cancellation-jobs" \
      WHISPERASR_FLUID_CANCELLATION_JOB_ID="$id" \
      WHISPERASR_FLUID_CANCELLATION_MODEL_CACHE="$FLUID_CACHE" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testFluidAudioCancellationWhenOptedIn
  fi
  jq -e '.status == "cancelled"
    and .failures[-1].stage == "cancelled"
    and ([.modelEvents[]
      | select(.modelID == "FluidInference/speaker-diarization-coreml/offline") | .kind]
      | index("load-completed") != null and index("unload-completed") != null
        and index("memory-release-checked") != null and index("guard-failed") == null)' \
    "$job/manifest.json" >/dev/null
  jq -e '.failures[-1].stage == "cancelled"' "$job/raw-asr.json" >/dev/null
  grep -F '[fluid-audio-cancellation] retained=true' "$log" >/dev/null
  gzip -n -c "$job/raw-asr.json" \
    >"$ROOT/$EVIDENCE_ROOT/development-fluid-audio-cancellation-raw-asr.json.gz"
  cp "$job/manifest.json" \
    "$ROOT/$EVIDENCE_ROOT/development-fluid-audio-cancellation-manifest.json"
  cp "$log" "$ROOT/$EVIDENCE_ROOT/development-fluid-audio-cancellation.log"
  jq '.cancellationTests = true' "$ARTIFACTS/controls.json" \
    >"$ARTIFACTS/controls.updated.json"
  mv "$ARTIFACTS/controls.updated.json" "$ARTIFACTS/controls.json"
  cp "$ARTIFACTS/controls.json" "$ROOT/$EVIDENCE_ROOT/controls.json"
}

settings_json() {
  jq -cn '{
    speakerkit:{engine:"speakerkit",speakerCount:"automatic",
      useExclusiveReconciliation:false,
      completeDiarizationAttribution:true,
      principalAttribution:"longest-overlap-then-nearest-span-stable-label",frozenUpstream:true,
      engineConfiguration:{precision:"quantized",segmenterVariant:"W8A16",
        embedderVariant:"W8A16",clusterDistanceThreshold:0.60}},
    "fluid-audio-offline":{engine:"fluid-audio-offline",speakerCount:"automatic",
      useExclusiveReconciliation:false,
      completeDiarizationAttribution:true,
      principalAttribution:"longest-overlap-then-nearest-span-stable-label",frozenUpstream:true,
      engineConfiguration:{pipeline:"offline-vbx-community",clusteringThreshold:0.60,
        exclusiveSegments:false,computeUnits:"all",fbankComputeUnits:"cpuOnly"}}}'
}

write_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" source manifest metadata role uncertainty
  local pseudo implementation snapshots unchanged dev_hash=''
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  metadata="$(corpus_metadata "$corpus")"
  role="$(jq -er .role <<<"$metadata")"
  uncertainty="$(jq -er .uncertainty <<<"$metadata")"
  pseudo="$(jq -c .pseudoSpeakers <<<"$metadata")"
  implementation="$(implementation_hashes)"
  snapshots="$(snapshot_sources)"
  unchanged="$(unchanged_implementation_hashes)"
  [[ "$role" != untouched-holdout ]] || dev_hash="$(cat "$DEVELOPMENT_FREEZE")"
  mkdir -p "$directory/jobs"
  jq -n \
    --arg corpus "$corpus" --arg role "$role" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg manifest "docs/japanese-live/corpora/$corpus/manifest.json" \
    --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg upstream "$(corpus_value "$corpus" upstreamEvidence)" \
    --arg upstreamHash "$(gzip -dc "$(upstream_evidence "$corpus")" | shasum -a 256 | awk '{print $1}')" \
    --arg controls "$EVIDENCE_ROOT/controls.json" \
    --arg controlsHash "$(shasum -a 256 "$ROOT/$EVIDENCE_ROOT/controls.json" | awk '{print $1}')" \
    --arg baselineJob "$(job_id "$corpus" speakerkit)" \
    --arg candidateJob "$(job_id "$corpus" fluid-audio-offline)" \
    --arg baseCommit "$BASE_COMMIT" \
    --arg uncertainty "$uncertainty" --arg devHash "$dev_hash" \
    --argjson pseudo "$pseudo" --argjson settings "$(settings_json)" \
    --argjson implementation "$implementation" --argjson snapshots "$snapshots" \
    --argjson unchanged "$unchanged" \
    '{schemaVersion:1,experiment:"E18-fluid-audio-offline",
      corpusID:$corpus,corpusRole:$role,
      sourcePath:$source,sourceSHA256:$sourceHash,
      corpusManifestPath:$manifest,corpusManifestSHA256:$manifestHash,
      frozenUpstreamEvidencePath:$upstream,
      frozenUpstreamEvidenceContentSHA256:$upstreamHash,
      controlEvidencePath:$controls,controlEvidenceSHA256:$controlsHash,
      jobs:{speakerkit:$baselineJob,"fluid-audio-offline":$candidateJob},
      baseCommit:$baseCommit,settings:$settings,
      referenceAnnotations:{pseudoSpeakers:$pseudo,uncertainty:$uncertainty},
      failurePolicy:{candidateAttribution:"withheld until build, model preparation, input, reference and evidence controls pass"},
      executionImplementationSHA256:$implementation,
      executionSourceSnapshots:$snapshots,
      reviewedImplementationSHA256:$implementation,
      unchangedImplementations:$unchanged}
      + (if $devHash == "" then {} else {
        developmentReportPath:"docs/japanese-live/experiments/evidence/E18/development-report.json",
        developmentReportSHA256:$devHash} end)' >"$directory/run-meta.json"
}

verify_remote_model_revision() {
  local corpus="$1" engine="$2" phase="$3" directory="$ARTIFACTS/$1"
  local repository expected observed file
  repository="$(engine_value "$engine" remoteRepository)"
  [[ -n "$repository" ]] || return 0
  expected="$(engine_value "$engine" remoteRevision)"
  file="$directory/$engine-revision-$phase.txt"
  if ! observed="$(git ls-remote "https://huggingface.co/$repository" HEAD \
      | awk 'NR == 1 {print $1}')"; then
    printf '%s\n' unavailable >"$file"
    diagnose_failure "$corpus" "$engine"
    return 1
  fi
  printf '%s\n' "$observed" >"$file"
  [[ "$observed" == "$expected" ]] || {
    echo "$engine model revision drift at $phase: $observed" >&2
    diagnose_failure "$corpus" "$engine"
    return 1
  }
}

check_variant() {
  local corpus="$1" engine="$2" directory="$ARTIFACTS/$1" job model
  job="$directory/jobs/$(job_id "$corpus" "$engine")"
  model="$(engine_value "$engine" modelID)"
  jq -e --arg model "$model" '.status == "completed" and .failures == []
    and ([.modelEvents[] | select(.modelID == $model) | .kind]
      | index("load-completed") != null and index("unload-completed") != null
        and index("memory-release-checked") != null and index("guard-failed") == null)' \
    "$job/manifest.json" >/dev/null
  jq -e --arg model "$model" \
    --argjson samples "$(jq '.fixture.sampleCount' "$(corpus_manifest "$corpus")")" \
    '.sampleCount == $samples and .failures == []
      and .speakerCountPolicy.mode == "automatic"
      and .diarization.modelID == $model
      and .diarization.speakerCountPolicy.mode == "automatic"
      and .diarization.useExclusiveReconciliation == false
      and (.diarization.rawSpans | length > 0)
      and (.diarization.mappings | length > 0)
      and ((.diarization.mappings | length)
        == ([.alignment.chunks[].rawItems[]] | length))
      and (.diarization.overlapRanges | type) == "array"
      and (.diarization.configuration | type) == "object"
      and .diarization.validationDiagnostics == []
      and ([.diarization.mappings[].alignmentItemIndex] | sort)
        == [range(0; ([.alignment.chunks[].rawItems[]] | length))]
      and ([.diarization.mappings[].attributionReason]
        | all(. == "longest-overlap" or . == "nearest-span-fallback"))
      and .translation.validationFailures == []' "$job/raw-asr.json" >/dev/null
  grep -F "[diarizer-engine][$engine] renameConsistency=true" \
    "$directory/$engine.log" >/dev/null
  for name in japanese-transcript.txt english-translation-transcript.txt \
    english-subtitles.vtt english-subtitles.srt raw-asr.json manifest.json; do
    [[ -s "$job/$name" ]]
  done
}

diagnose_failure() {
  local corpus="$1" engine="$2" directory="$ARTIFACTS/$1" log classification raw stage
  local preparation_log inventory repository expected observed runtime_identity runtime_revision
  local build=false source=false inputs=false references=false artifacts=false evidence=false
  local preparation=false revision=false inventory_valid=false runtime_pin=false inventory_hash=''
  log="$directory/$engine-infrastructure-diagnostics.log"
  if xcrun swift build >"$log" 2>&1; then build=true; fi
  if verify_frozen_input "$corpus" >>"$log" 2>&1; then
    source=true
    inputs=true
    references=true
  fi

  preparation_log="$directory/$engine-model-preparation-rerun.log"
  if env WHISPERASR_RUN_DIARIZER_PREPARATION=1 \
      WHISPERASR_DIARIZER_PREPARATION_ENGINE="$engine" \
      WHISPERASR_DIARIZER_PREPARATION_MODEL_CACHE="$(model_cache "$engine")" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testDiarizerPreparationWhenOptedIn \
        >"$preparation_log" 2>&1 \
      && grep -F "[diarizer-preparation][$engine] retained=true" \
        "$preparation_log" >/dev/null; then
    preparation=true
  fi

  runtime_identity="$(engine_value "$engine" runtimeIdentity)"
  runtime_revision="$(engine_value "$engine" runtimeRevision)"
  if jq -e --arg identity "$runtime_identity" --arg revision "$runtime_revision" \
      '.pins[] | select(.identity == $identity and .state.revision == $revision)' \
      Package.resolved >>"$log" 2>&1; then
    runtime_pin=true
  fi
  repository="$(engine_value "$engine" remoteRepository)"
  if [[ -z "$repository" ]]; then
    revision=true
  else
    expected="$(engine_value "$engine" remoteRevision)"
    if observed="$(git ls-remote "https://huggingface.co/$repository" HEAD \
        | awk 'NR == 1 {print $1}')" && [[ "$observed" == "$expected" ]]; then
      revision=true
    fi
    printf '%s\n' "${observed:-unavailable}" \
      >"$directory/$engine-revision-diagnostic.txt"
  fi

  inventory="$directory/$engine-diagnostic-model-cache-manifest.json"
  if python3 Scripts/report_speakerkit_precision.py \
      --inventory-cache "$(model_cache "$engine")" --inventory-output "$inventory" \
      >>"$log" 2>&1 \
      && jq -e '.files | length > 0
        and any(.size > 0)
        and all(.size >= 0 and (.sha256 | type == "string" and length == 64))' \
        "$inventory" >>"$log" 2>&1; then
    inventory_valid=true
    inventory_hash="$(shasum -a 256 "$inventory" | awk '{print $1}')"
  fi

  artifacts=true
  while IFS= read -r candidate; do
    if ! jq empty "$candidate" >>"$log" 2>&1; then artifacts=false; fi
  done < <(find "$directory/jobs" -name '*.json' -type f)
  if python3 Scripts/report_fluid_audio_offline.py --self-test >>"$log" 2>&1 \
      && jq empty "$directory/run-meta.json" "$ARTIFACTS/controls.json" \
        >>"$log" 2>&1 \
      && [[ "$(jq -cS .executionImplementationSHA256 "$directory/run-meta.json")" \
        == "$(implementation_hashes | jq -cS .)" ]]; then
    evidence=true
  fi
  if [[ "$build" != true ]]; then classification=runner-build
  elif [[ "$source" != true || "$inputs" != true || "$references" != true ]]; then classification=runner-input-reference
  elif [[ "$preparation" != true || "$runtime_pin" != true \
      || "$revision" != true || "$inventory_valid" != true ]]; then classification=model-preparation
  elif [[ "$artifacts" != true || "$evidence" != true ]]; then classification=runner-evidence
  else classification=application-runtime; fi
  raw="$(find "$directory/jobs" -name raw-asr.json -type f -print -quit)"
  stage=unknown
  [[ -z "$raw" ]] || stage="$(jq -r '.failures[-1].stage // "unknown"' "$raw")"
  jq -n --arg classification "$classification" --arg stage "$stage" --arg engine "$engine" \
    --argjson build "$build" --argjson source "$source" --argjson inputs "$inputs" \
    --arg preparationLog "$preparation_log" --arg inventory "$inventory" \
    --arg inventoryHash "$inventory_hash" \
    --argjson references "$references" --argjson artifacts "$artifacts" \
    --argjson evidence "$evidence" --argjson preparation "$preparation" \
    --argjson revision "$revision" --argjson runtimePin "$runtime_pin" \
    --argjson inventoryValid "$inventory_valid" \
    '{classification:$classification,candidateAttribution:"withheld",engine:$engine,
      failingStage:$stage,runnerBuild:$build,sourceIntegrity:$source,inputJSON:$inputs,
      referenceJSON:$references,artifactJSON:$artifacts,evidenceControls:$evidence,
      modelPreparationRerun:$preparation,modelPreparationLog:$preparationLog,
      runtimeRevisionPin:$runtimePin,remoteModelRevision:$revision,
      modelInventory:{path:$inventory,sha256:$inventoryHash,valid:$inventoryValid}}' \
    >"$directory/$engine-infrastructure-diagnostics.json"
  echo "Run failed; diagnostic attribution retained at $directory" >&2
}

run_variant() {
  local corpus="$1" engine="$2" directory="$ARTIFACTS/$1" job
  job="$directory/jobs/$(job_id "$corpus" "$engine")"
  verify_frozen_input "$corpus"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' \
      "$job/manifest.json" >/dev/null 2>&1; then
    echo "Reusing completed $engine run: $corpus"
    check_variant "$corpus" "$engine"
    return
  fi
  if [[ -e "$job" ]]; then
    echo "Incomplete run retained at $job; refusing to overwrite it." >&2
    return 1
  fi
  verify_remote_model_revision "$corpus" "$engine" before
  if ! run_logged "$directory/$engine.log" env \
      WHISPERASR_RUN_DIARIZER_ENGINE_EXPERIMENT=1 \
      WHISPERASR_DIARIZER_ENGINE_EVIDENCE="$(materialized_evidence "$corpus")" \
      WHISPERASR_DIARIZER_ENGINE_SOURCE="$(source_path "$corpus")" \
      WHISPERASR_DIARIZER_ENGINE_OUTPUT="$directory/jobs" \
      WHISPERASR_DIARIZER_ENGINE_JOB_ID="$(job_id "$corpus" "$engine")" \
      WHISPERASR_DIARIZER_ENGINE="$engine" \
      WHISPERASR_DIARIZER_ENGINE_MODEL_CACHE="$(model_cache "$engine")" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testFrozenDiarizerEngineWhenOptedIn; then
    diagnose_failure "$corpus" "$engine"
    return 1
  fi
  verify_remote_model_revision "$corpus" "$engine" after
  check_variant "$corpus" "$engine"
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
  local corpus="$1" directory="$ARTIFACTS/$1" uncertainty engine job scorer
  local artifacts='{}' logs='{}' scorers='{}' inventories='{}' inventory hash split
  local cancellation='null' cancellation_manifest cancellation_raw cancellation_log
  uncertainty="$(jq -r .referenceAnnotations.uncertainty "$directory/run-meta.json")"
  split="$(corpus_value "$corpus" split)"
  for engine in "${ENGINES[@]}"; do
    job="$directory/jobs/$(job_id "$corpus" "$engine")"
    scorer="$directory/$engine-scorer-input.json.gz"
    python3 Scripts/report_fluid_audio_offline.py --make-scorer-input \
      --manifest "$(corpus_manifest "$corpus")" --raw "$job/raw-asr.json" \
      --output "$scorer" --corpus "$corpus" --engine "$engine" \
      --reference-uncertainty "$uncertainty"
    artifacts="$(jq -c --arg engine "$engine" --argjson value "$(artifact_hashes "$job")" \
      '. + {($engine):$value}' <<<"$artifacts")"
    logs="$(jq -c --arg engine "$engine" \
      --arg value "$(shasum -a 256 "$directory/$engine.log" | awk '{print $1}')" \
      '. + {($engine):$value}' <<<"$logs")"
    scorers="$(jq -c --arg engine "$engine" \
      --arg value "$(gzip -dc "$scorer" | shasum -a 256 | awk '{print $1}')" \
      '. + {($engine):$value}' <<<"$scorers")"
    inventory="$ARTIFACTS/$engine-model-cache-manifest.json"
    python3 Scripts/report_speakerkit_precision.py \
      --inventory-cache "$(model_cache "$engine")" --inventory-output "$inventory"
    hash="$(shasum -a 256 "$inventory" | awk '{print $1}')"
    inventories="$(jq -c --arg engine "$engine" \
      --arg path "$EVIDENCE_ROOT/$split-$engine-model-cache-manifest.json" --arg hash "$hash" \
      '. + {($engine):{path:$path,sha256:$hash}}' <<<"$inventories")"
  done
  if [[ "$split" == development ]]; then
    cancellation_manifest="$ROOT/$EVIDENCE_ROOT/development-fluid-audio-cancellation-manifest.json"
    cancellation_raw="$ROOT/$EVIDENCE_ROOT/development-fluid-audio-cancellation-raw-asr.json.gz"
    cancellation_log="$ROOT/$EVIDENCE_ROOT/development-fluid-audio-cancellation.log"
    cancellation="$(jq -cn \
      --arg jobID "$(cancellation_job_id "$corpus")" \
      --arg manifestPath "$EVIDENCE_ROOT/development-fluid-audio-cancellation-manifest.json" \
      --arg manifestHash "$(shasum -a 256 "$cancellation_manifest" | awk '{print $1}')" \
      --arg rawPath "$EVIDENCE_ROOT/development-fluid-audio-cancellation-raw-asr.json.gz" \
      --arg rawHash "$(gzip -dc "$cancellation_raw" | shasum -a 256 | awk '{print $1}')" \
      --arg logPath "$EVIDENCE_ROOT/development-fluid-audio-cancellation.log" \
      --arg logHash "$(shasum -a 256 "$cancellation_log" | awk '{print $1}')" \
      '{jobID:$jobID,manifestPath:$manifestPath,manifestSHA256:$manifestHash,
        rawASRPath:$rawPath,rawASRContentSHA256:$rawHash,
        logPath:$logPath,logSHA256:$logHash}')"
  elif [[ -f "$ARTIFACTS/qudu2fx3ncc/run-meta.json" ]]; then
    cancellation="$(jq -c '.fluidAudioCancellationEvidence' \
      "$ARTIFACTS/qudu2fx3ncc/run-meta.json")"
  fi
  jq --argjson artifacts "$artifacts" --argjson logs "$logs" \
    --argjson scorers "$scorers" --argjson inventories "$inventories" \
    --argjson cancellation "$cancellation" \
    --argjson reviewed "$(implementation_hashes)" \
    --arg controlHash "$(shasum -a 256 "$ROOT/$EVIDENCE_ROOT/controls.json" | awk '{print $1}')" \
    --arg before "$(cat "$directory/fluid-audio-offline-revision-before.txt")" \
    --arg after "$(cat "$directory/fluid-audio-offline-revision-after.txt")" \
    '. + {controlEvidenceSHA256:$controlHash,
      artifactSHA256:$artifacts,runLogSHA256:$logs,
      scorerInputContentSHA256:$scorers,modelInventories:$inventories,
      fluidAudioRemoteRevision:{before:$before,after:$after},
      renameConsistency:{
        speakerkit:true,"fluid-audio-offline":true},
      reviewedImplementationSHA256:$reviewed}
      + (if $cancellation == null then {} else {
        fluidAudioCancellationEvidence:$cancellation} end)' \
    "$directory/run-meta.json" >"$directory/run-meta.updated.json"
  mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
}

snapshot_runs() {
  local corpus="$1" split directory="$ARTIFACTS/$1" engine job
  split="$(corpus_value "$corpus" split)"
  for engine in "${ENGINES[@]}"; do
    job="$directory/jobs/$(job_id "$corpus" "$engine")"
    gzip -n -c "$job/raw-asr.json" >"$ROOT/$EVIDENCE_ROOT/$split-$engine-raw-asr.json.gz"
    cp "$job/manifest.json" "$ROOT/$EVIDENCE_ROOT/$split-$engine-manifest.json"
    cp "$directory/$engine.log" "$ROOT/$EVIDENCE_ROOT/$split-$engine.log"
    cp "$directory/$engine-scorer-input.json.gz" \
      "$ROOT/$EVIDENCE_ROOT/$split-$engine-scorer-input.json.gz"
    cp "$ARTIFACTS/$engine-model-cache-manifest.json" \
      "$ROOT/$EVIDENCE_ROOT/$split-$engine-model-cache-manifest.json"
  done
  cp "$directory/run-meta.json" "$ROOT/$EVIDENCE_ROOT/$split-run-meta.json"
  cp "$directory/fluid-audio-offline-revision-before.txt" \
    "$ROOT/$EVIDENCE_ROOT/$split-fluid-audio-revision-before.txt"
  cp "$directory/fluid-audio-offline-revision-after.txt" \
    "$ROOT/$EVIDENCE_ROOT/$split-fluid-audio-revision-after.txt"
}

run_corpus() {
  local corpus="$1" directory="$ARTIFACTS/$1"
  verify_frozen_input "$corpus"
  [[ -f "$directory/run-meta.json" ]] || write_metadata "$corpus"
  for engine in "${ENGINES[@]}"; do run_variant "$corpus" "$engine"; done
  if [[ "$(corpus_value "$corpus" role)" == development ]]; then
    run_fluid_cancellation "$corpus"
  fi
  finalize_metadata "$corpus"
  snapshot_runs "$corpus"
}

if [[ "$MODE" == development ]]; then
  [[ ! -e "$DEVELOPMENT_REPORT" && ! -e "$DEVELOPMENT_FREEZE" ]] || {
    echo "Retained development decision already exists; refusing to overwrite it." >&2
    exit 1
  }
  run_controls
  run_corpus qudu2fx3ncc
  python3 Scripts/report_fluid_audio_offline.py "$ARTIFACTS" \
    --json "$DEVELOPMENT_REPORT" --markdown "$REPORT_MD"
  shasum -a 256 "$DEVELOPMENT_REPORT" | awk '{print $1}' >"$DEVELOPMENT_FREEZE"
  jq '{candidateEligible:.development.candidateEligible,decision}' "$DEVELOPMENT_REPORT"
  exit 0
fi

[[ -f "$DEVELOPMENT_REPORT" && -f "$DEVELOPMENT_FREEZE" ]] || {
  echo "Run the development comparison first." >&2
  exit 1
}
[[ "$(shasum -a 256 "$DEVELOPMENT_REPORT" | awk '{print $1}')" \
  == "$(cat "$DEVELOPMENT_FREEZE")" ]] || {
  echo "Frozen development decision hash mismatch." >&2
  exit 1
}
jq -e '.development.candidateEligible == true and .holdoutRun == false' \
  "$DEVELOPMENT_REPORT" >/dev/null || {
  echo "FluidAudio did not pass DEV; untouched holdout remains closed." >&2
  exit 1
}
run_corpus md62mmdz0m
python3 Scripts/report_fluid_audio_offline.py "$ARTIFACTS" \
  --development-report "$DEVELOPMENT_REPORT" \
  --json "$FINAL_REPORT" --markdown "$REPORT_MD"
jq '{promote,decision}' "$FINAL_REPORT"
