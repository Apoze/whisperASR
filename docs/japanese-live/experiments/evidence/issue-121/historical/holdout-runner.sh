#!/bin/bash
set -Eeuo pipefail

VALIDATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_MODE="${1:-preflight}"
VALIDATION_ARTIFACTS="${WHISPERASR_FINAL_VALIDATION_ROOT:-$VALIDATION_ROOT/.build/benchmarks/high-quality/final-validation-121}"

# Reuse the native macOS pressure guard already exercised by the offline campaign.
source "$VALIDATION_ROOT/Scripts/run_mossformer2_oracle_experiment.sh"
ROOT="$VALIDATION_ROOT"
MODE="$VALIDATION_MODE"
ARTIFACTS="$VALIDATION_ARTIFACTS"
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
PROJECTS="$ARTIFACTS/projects"
WORKER="$ROOT/.build/debug/WhisperASR"
READY="$ARTIFACTS/READY_FOR_HEAVY_BENCHMARK.json"
HOLDOUT_READY="$ARTIFACTS/READY_FOR_HOLDOUT.json"
FREEZE="$ARTIFACTS/development-freeze.json"
TIMEOUT_SECONDS="${WHISPERASR_FINAL_TIMEOUT_SECONDS:-2400}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swiftpm-module-cache}"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

# Warning pressure is telemetry, not a veto. Product cache cleanup owns warning recovery;
# critical pressure and the independent runaway/swap/catastrophic guards remain vetoes.
WARNING_RECOVERY_GROWTH_PERCENT=100
pressure_guard_decision() {
  local level="$1"
  PRESSURE_STOP_REASON=""
  if [[ "$level" == critical ]]; then
    PRESSURE_STOP_REASON="native-pressure-critical"
  elif [[ "$level" == warning ]]; then
    WARNING_CLEANUP_COUNT=$((WARNING_CLEANUP_COUNT + 1))
  fi
}

PHASE=startup
CURRENT_LANE=""
RUNNER_SUBSHELL="$BASH_SUBSHELL"

failure() {
  local classification="$1" detail="$2"
  mkdir -p "$ARTIFACTS"
  jq -n --arg phase "$PHASE" --arg lane "$CURRENT_LANE" \
    --arg classification "$classification" --arg detail "$detail" \
    '{ticket:121,status:"failed",phase:$phase,lane:$lane,
      classification:$classification,detail:$detail,candidateVerdictAssigned:false}' \
    >"$ARTIFACTS/failure.json"
  echo "$detail" >&2
  exit 1
}

on_error() {
  local status="$?"
  ((BASH_SUBSHELL == RUNNER_SUBSHELL)) || return "$status"
  trap - ERR
  failure runner "Command failed at $PHASE (exit $status)"
}

process_tree_pids() {
  local process="$1" child
  printf '%s\n' "$process"
  while IFS= read -r child; do
    [[ -z "$child" ]] || process_tree_pids "$child"
  done < <(pgrep -P "$process" 2>/dev/null || true)
}

# The guard's default sampler only sees its direct child. XCTest launches one worker per
# heavyweight stage, so audit the full process tree and retain the largest footprint.
read_process_memory() {
  local process="$1" pid rss_kb total_kb=0 largest_kb=0 largest_pid output
  largest_pid="$process"
  while IFS= read -r pid; do
    rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1 + 0}')"
    [[ "$rss_kb" =~ ^[0-9]+$ ]] || continue
    total_kb=$((total_kb + rss_kb))
    if ((rss_kb > largest_kb)); then largest_kb="$rss_kb"; largest_pid="$pid"; fi
  done < <(process_tree_pids "$process")
  PROCESS_RSS_BYTES="$((total_kb * 1024))"
  output="$(/usr/bin/footprint -f bytes --noCategories -p "$largest_pid" 2>/dev/null || true)"
  PROCESS_FOOTPRINT_BYTES="$(awk '/phys_footprint:/ {print $(NF - 1); exit}' <<<"$output")"
  PROCESS_FOOTPRINT_PEAK_BYTES="$(awk '/phys_footprint_peak:/ {print $(NF - 1); exit}' <<<"$output")"
  [[ "$PROCESS_FOOTPRINT_BYTES" =~ ^[0-9]+$ ]] || PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  [[ "$PROCESS_FOOTPRINT_PEAK_BYTES" =~ ^[0-9]+$ ]] \
    || PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_FOOTPRINT_BYTES"
  ((PROCESS_FOOTPRINT_BYTES >= PROCESS_RSS_BYTES)) \
    || PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  ((PROCESS_FOOTPRINT_PEAK_BYTES >= PROCESS_FOOTPRINT_BYTES)) \
    || PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_FOOTPRINT_BYTES"
}

manifest_for() { printf '%s/docs/japanese-live/corpora/%s/manifest.json\n' "$ROOT" "$1"; }
video_directory() { [[ "$1" == qudu2fx3ncc ]] && printf '%s/1\n' "$VIDEO_ROOT" || printf '%s/2\n' "$VIDEO_ROOT"; }

resolve_corpus_file() {
  local corpus="$1" label="$2" expected file
  expected="$(jq -er --arg label "$label" \
    '.source.references[] | select(.label == $label) | .sha256' "$(manifest_for "$corpus")")"
  while IFS= read -r file; do
    if [[ "$(sha256 "$file")" == "$expected" ]]; then
      printf '%s\n' "$file"
      return
    fi
  done < <(find "$(video_directory "$corpus")" -maxdepth 1 -type f -print | sort)
  return 1
}

materialize_local_references() {
  local corpus="$1" manifest locator expected source destination
  manifest="$(manifest_for "$corpus")"
  while IFS=$'\t' read -r locator expected; do
    destination="$ROOT/$locator"
    source="$FROZEN_REPO/$locator"
    if [[ ! -e "$destination" ]]; then
      [[ -f "$source" ]] || failure reference "Missing frozen local reference: $source"
      mkdir -p "$(dirname "$destination")"
      ln -s "$source" "$destination"
    fi
    [[ "$(sha256 "$destination")" == "$expected" ]] \
      || failure reference "Local reference hash mismatch: $locator"
  done < <(jq -r '.source.references[]
    | select(.locator | test("^[a-z]+:") | not) | [.locator,.sha256] | @tsv' "$manifest")
}

verify_corpus() {
  local corpus="$1" manifest source archive expected
  manifest="$(manifest_for "$corpus")"
  source="$(resolve_corpus_file "$corpus" source-video)" \
    || failure input "No source-video hash match for $corpus"
  archive="$(resolve_corpus_file "$corpus" reference-archive)" \
    || failure reference "No reference-archive hash match for $corpus"
  expected="$(jq -r '.source.references[] | select(.label=="source-video") | .sha256' "$manifest")"
  [[ "$(sha256 "$source")" == "$expected" ]] || failure input "Source hash mismatch for $corpus"
  expected="$(jq -r '.source.references[] | select(.label=="reference-archive") | .sha256' "$manifest")"
  [[ "$(sha256 "$archive")" == "$expected" ]] || failure reference "Archive hash mismatch for $corpus"
  materialize_local_references "$corpus"
  printf '%s\tsource-video\t%s\t%s\n' "$corpus" "$(sha256 "$source")" "$source"
  printf '%s\treference-archive\t%s\t%s\n' "$corpus" "$(sha256 "$archive")" "$archive"
  while IFS=$'\t' read -r locator expected; do
    printf '%s\tlocal-reference\t%s\t%s\n' "$corpus" "$expected" "$ROOT/$locator"
  done < <(jq -r '.source.references[]
    | select(.locator | test("^[a-z]+:") | not) | [.locator,.sha256] | @tsv' "$manifest")
}

implementation_hashes() {
  local value='{}' path
  for path in \
    Sources/HighQualityJob.swift Sources/HighQualityProject.swift \
    Sources/HighQualityJobView.swift Sources/HighQualitySpeakerKitRuntime.swift \
    Sources/HighQualityForcedAlignerRuntime.swift Sources/LocalMLXTranslator.swift \
    Sources/ReadableSubtitleReflow.swift Tests/HighQualityAcceptanceTests.swift \
    Scripts/run_final_offline_validation.sh Scripts/report_final_offline_validation.py; do
    value="$(jq -c --arg path "$path" --arg digest "$(sha256 "$ROOT/$path")" \
      '. + {($path):$digest}' <<<"$value")"
  done
  printf '%s\n' "$value"
}

write_matrix() {
  jq -n '{schemaVersion:1,ticket:121,strategy:"minimal risk-based pairwise",
    rows:[
      {order:1,lane:"development",corpusID:"qudu2fx3ncc",projectWorkflow:true,
       ASR:"qwen-ja",translator:"translategemma-12b-it-4bit",speakerLabels:true,
       readableSubtitles:false,postActions:["speaker-only reanalysis","speaker editor",
         "Project-local Voice memory isolation"]},
      {order:2,lane:"untouched-holdout",corpusID:"md62mmdz0m",projectWorkflow:true,
       ASR:"qwen-ja",translator:"translategemma-4b-it-4bit",speakerLabels:false,
       readableSubtitles:true,postActions:[]}
    ],coverage:{translatorChoice:["12B","4B"],speakerLabels:[true,false],
      readableSubtitles:[false,true],savedProjectJob:[true],
      dependencies:["Qwen JA","Forced Aligner","SpeakerKit","TranslateGemma","export"]},
    retainedWithoutRerun:{adaptiveASR:"RETAIN-HIDDEN / NO-GO DEV",
      targetedWhisperKit:"RETAIN-HIDDEN / NO-GO DEV",
      lexicalCorrection:"NO-GO DEV"},
    rationale:"Two full jobs cover the supported translator/speaker/readability interactions; exact retained decisions cover rejected candidates without reopening holdout."}' \
    >"$ARTIFACTS/matrix.json"
}

verify_models() {
  local provenance12="$ROOT/docs/japanese-live/experiments/evidence/E22/model-provenance.json"
  local provenance4="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-only-4b/model-provenance.json"
  jq -s '{schemaVersion:1,weights:(.[0].weights + .[1].weights)}' \
    "$provenance12" "$provenance4" >"$ARTIFACTS/model-provenance.json"
  while IFS=$'\t' read -r path expected; do
    [[ -f "$path" ]] || failure input "Missing pinned model file: $path"
    [[ "$(sha256 "$path")" == "$expected" ]] \
      || failure input "Pinned model hash mismatch: $path"
  done < <(jq -r '.weights[] | [.sourcePath,.sha256] | @tsv' "$ARTIFACTS/model-provenance.json")
}

verify_hidden_decisions() {
  grep -q 'RETAIN-HIDDEN / NO-GO DEV' \
    docs/japanese-live/experiments/E32-adaptive-qwen-parakeet-117.md \
    || failure reference "Adaptive ASR retained decision changed"
  grep -q 'RETAIN-HIDDEN / NO-GO DEV' \
    docs/japanese-live/experiments/E33-targeted-whisperkit-118.md \
    || failure reference "Targeted WhisperKit retained decision changed"
  grep -q 'NO-GO sur DEV' docs/japanese-live/experiments/E33-closed-lexical-correction.md \
    || failure reference "Closed lexical retained decision changed"
  ! rg -q 'adaptive|lexical' Sources/HighQualityJobView.swift \
    || failure build "A rejected candidate is exposed in the High-quality UI"
  jq -e '.decision == "GO_BETA_OPT_IN" and .defaultEnabled == false' \
    docs/japanese-live/experiments/evidence/issue-115/decision.json >/dev/null \
    || failure reference "Voice memory Bêta decision changed"
  jq -e '.decision == "GO-beta" and .gates.defaultOff == true' \
    docs/japanese-live/experiments/evidence/E32-readable-cues/report.json >/dev/null \
    || failure reference "Readable subtitle Bêta decision changed"
}

preflight() {
  PHASE=preflight
  command -v jq >/dev/null || failure runner "jq is required"
  command -v rg >/dev/null || failure runner "rg is required"
  command -v ffmpeg >/dev/null || failure runner "ffmpeg is required"
  [[ -x /usr/bin/footprint && -x /usr/bin/memory_pressure && -x /usr/bin/vm_stat ]] \
    || failure runner "Native macOS memory tools are unavailable"
  [[ ! -d "$PROJECTS" ]] || ! find "$PROJECTS" -path '*/Jobs/*/raw-asr.json' -print -quit \
    | grep -q . || failure runner "Preserve existing #121 raw jobs; use a new artifact root"
  mkdir -p "$ARTIFACTS" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
  rm -f "$ARTIFACTS/failure.json"
  write_matrix
  : >"$ARTIFACTS/input-preflight.tsv"
  verify_corpus qudu2fx3ncc >>"$ARTIFACTS/input-preflight.tsv"
  verify_corpus md62mmdz0m >>"$ARTIFACTS/input-preflight.tsv"
  verify_models
  verify_hidden_decisions
  git diff --check
  git diff --binary >"$ARTIFACTS/worktree.patch"
  bash -n Scripts/run_final_offline_validation.sh
  python3 -m py_compile Scripts/report_final_offline_validation.py
  python3 Scripts/report_final_offline_validation.py --self-test
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift build \
    2>&1 | tee "$ARTIFACTS/build.log"
  bash Scripts/build_mlx_metallib.sh debug \
    2>&1 | tee "$ARTIFACTS/metallib.log"
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift test --skip-build --filter \
    'HighQualityAcceptanceTests/testRealFinalProjectWorkflowWhenOptedIn|HighQualityJobTests/testReadableSubtitleBetaControlsVisibilityAndSafeDefault|HighQualityJobTests/testProjectVoiceMemoryDefaultsOffAndStaysIsolatedAfterReopenAndRename|HighQualityJobTests/testProjectVoiceMemoryEndToEndUsesOnlyPublicProjectResultSeams|HighQualityJobTests/testSpeakerBetaControlsVisibilityAndSafeDefaults|HighQualityAdaptiveASRTests/testAdaptiveModeUsesShortAcousticSegmentsWithoutChangingTheDefault' \
    2>&1 | tee "$ARTIFACTS/light-tests.log"
  [[ -x "$WORKER" ]] || failure build "WhisperASR worker was not built"
  jq -n --arg commit "$(git rev-parse HEAD)" \
    --arg command 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer BENCHMARK_SLOT_GRANTED=121 bash Scripts/run_final_offline_validation.sh full' \
    --arg matrix "$(sha256 "$ARTIFACTS/matrix.json")" \
    --arg inputs "$(sha256 "$ARTIFACTS/input-preflight.tsv")" \
    --arg models "$(sha256 "$ARTIFACTS/model-provenance.json")" \
    --arg patch "$(sha256 "$ARTIFACTS/worktree.patch")" \
    --arg worker "$(sha256 "$WORKER")" \
    --arg metallib "$(sha256 "$ROOT/.build/debug/mlx.metallib")" \
    --argjson implementation "$(implementation_hashes)" \
    '{ticket:121,status:"READY_FOR_HEAVY_BENCHMARK",baseCommit:$commit,
      command:$command,heavyModelsLoaded:false,
      estimate:{wallTime:"25-40 minutes",peakProcessTree:"10-14 GiB for 12B; 5-7 GiB for 4B",
        peakSystemMemory:"approximately 17-20 GiB on this 24 GiB Mac",
        additionalDisk:"under 1 GiB; all model weights already cached"},
      order:["DEV saved Project job: Qwen+aligner+SpeakerKit+12B",
        "speaker-only reanalysis/editor/Voice memory","freeze DEV",
        "prove every worker exited and pressure is not critical",
        "holdout saved Project job: Qwen+aligner+4B+Readable",
        "report, full tests, Live tests, app launch"],
      gates:{nativeCriticalStops:true,warningAloneStops:false,oneHeavyWorkerAtATime:true,
        unloadAndExitBeforeNext:true,holdoutRequiresImmutableDEVFreeze:true,
        candidateBuildRunnerInputReferenceFailuresSeparated:true},
      provenanceSHA256:{matrix:$matrix,inputs:$inputs,models:$models,
        uncommittedPatch:$patch,worker:$worker,mlxMetallib:$metallib},
      implementationSHA256:$implementation}' >"$READY"
  echo "READY_FOR_HEAVY_BENCHMARK #121"
  jq '{command,estimate,order,gates}' "$READY"
}

verify_ready() {
  [[ -f "$READY" ]] || failure runner "Run preflight before requesting the heavy slot"
  jq -e '.ticket == 121 and .status == "READY_FOR_HEAVY_BENCHMARK"
    and .heavyModelsLoaded == false' "$READY" >/dev/null \
    || failure runner "Invalid #121 READY artifact"
  [[ "$(sha256 "$ARTIFACTS/matrix.json")" == "$(jq -r .provenanceSHA256.matrix "$READY")" ]] \
    || failure runner "Matrix changed after READY"
  [[ "$(sha256 "$ARTIFACTS/input-preflight.tsv")" == "$(jq -r .provenanceSHA256.inputs "$READY")" ]] \
    || failure input "Inputs changed after READY"
  [[ "$(sha256 "$ARTIFACTS/model-provenance.json")" == "$(jq -r .provenanceSHA256.models "$READY")" ]] \
    || failure input "Model provenance changed after READY"
  [[ "$(sha256 "$WORKER")" == "$(jq -r .provenanceSHA256.worker "$READY")" ]] \
    || failure build "Worker changed after READY"
  [[ "$(sha256 "$ROOT/.build/debug/mlx.metallib")" == "$(jq -r .provenanceSHA256.mlxMetallib "$READY")" ]] \
    || failure build "MLX metallib changed after READY"
  [[ "$(jq -cS . <<<"$(implementation_hashes)")" \
      == "$(jq -cS .implementationSHA256 "$READY")" ]] \
    || failure build "Implementation changed after READY"
}

translation_worker_ready_since() {
  local marker="$1" response
  while IFS= read -r response; do
    jq -e '.ready == true' "$response" >/dev/null 2>&1 && return 0
  done < <(find "${TMPDIR:-/tmp}" -maxdepth 2 -type f -name ready.json \
    -path '*/WhisperASR-TranslateGemma-*/*' -newer "$marker" -print 2>/dev/null)
  return 1
}

assert_worker_exit() {
  local raw="$1" pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] || ! process_running "$pid" \
      || failure runner "Heavy worker $pid is still resident after its lane"
  done < <(jq -r '[.asrWorker.lifecycle.processIdentifier,
    .alignment.worker.processIdentifier,.diarization.worker.processIdentifier?,
    .translation.worker.processIdentifier,
    (.speakerReanalyses // [] | .[].diarization.worker.processIdentifier)]
    | flatten | .[] | select(. != null)' "$raw")
}

run_lane() {
  local lane="$1" corpus="$2" translator="$3" speakers="$4" readable="$5" actions="$6"
  local directory log marker ready watcher status=0 source archive role="$lane"
  directory="$ARTIFACTS/$lane"
  log="$directory/run.log"
  marker="$directory/process-started"
  ready="$directory/translation-loaded"
  [[ "$lane" != holdout ]] || role=untouched-holdout
  CURRENT_LANE="$lane"; PHASE="run-$lane"
  [[ ! -e "$directory/row-report.json" ]] \
    || failure runner "Preserve existing $lane evidence; use a new artifact root"
  mkdir -p "$directory"
  source="$(resolve_corpus_file "$corpus" source-video)" \
    || failure input "Source disappeared for $corpus"
  archive="$(resolve_corpus_file "$corpus" reference-archive)" \
    || failure reference "Reference archive disappeared for $corpus"
  touch "$marker"
  (
    trap - ERR
    while [[ ! -f "$ready" ]]; do
      translation_worker_ready_since "$marker" && { touch "$ready"; break; }
      sleep 1
    done
  ) & watcher="$!"
  WARNING_CLEANUP_RETRY_ENABLED=true
  WARNING_CONTINUES_WHILE_SAFE=true
  PAGEOUT_GUARD_FROM_PROCESS_START=true
  if run_guarded "$directory/safety.json" "$log" "$TIMEOUT_SECONDS" "$ready" env \
    DEVELOPER_DIR="$DEVELOPER_DIR" BENCHMARK_SLOT_GRANTED=121 \
    WHISPERASR_RUN_FINAL_PROJECT_VALIDATION=1 \
    WHISPERASR_FINAL_PROJECTS_ROOT="$PROJECTS" \
    WHISPERASR_FINAL_PROJECT_FOLDER="$VIDEO_ROOT" \
    WHISPERASR_FINAL_LANE="$role" WHISPERASR_FINAL_TRANSLATOR="$translator" \
    WHISPERASR_FINAL_SPEAKERS="$speakers" WHISPERASR_FINAL_READABLE="$readable" \
    WHISPERASR_FINAL_POST_SPEAKER_ACTIONS="$actions" \
    WHISPERASR_FINAL_ROW_REPORT="$directory/row-report.json" \
    WHISPERASR_ACCEPTANCE_CORPUS="$corpus" WHISPERASR_ACCEPTANCE_SOURCE="$source" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$archive" \
    WHISPERASR_ACCEPTANCE_ALLOW_HOLDOUT="$([[ "$lane" == holdout ]] && echo 1 || echo 0)" \
    WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testRealFinalProjectWorkflowWhenOptedIn; then
    status=0
  else
    status="$?"
  fi
  WARNING_CLEANUP_RETRY_ENABLED=false
  WARNING_CONTINUES_WHILE_SAFE=false
  PAGEOUT_GUARD_FROM_PROCESS_START=false
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  cat "$log"
  [[ "$(jq -r .stopReason "$directory/safety.json")" == completed ]] \
    || failure runner "Safety gate stopped $lane: $(jq -r .stopReason "$directory/safety.json")"
  if ((status != 0)) || [[ ! -f "$directory/row-report.json" ]]; then
    local manifest
    manifest="$(find "$PROJECTS" -path '*/Jobs/*/manifest.json' -print | sort | tail -1)"
    if [[ -n "$manifest" && -f "$manifest" ]]; then
      local stage
      stage="$(jq -r '.failures[0].stage // empty' "$manifest")"
      [[ -z "$stage" ]] || failure candidate "Product candidate failed at $stage in $lane"
    fi
    failure runner "XCTest/harness failed before an auditable $lane result"
  fi
  local job
  job="$(jq -r .jobDirectory "$directory/row-report.json")"
  [[ -f "$job/raw-asr.json" && -f "$job/manifest.json" ]] \
    || failure runner "Saved Project artifacts are missing for $lane"
  jq -e '.status == "completed" and .failures == [] and .projectID != null' \
    "$job/manifest.json" >/dev/null || failure candidate "Incomplete saved Project job in $lane"
  assert_worker_exit "$job/raw-asr.json"
  read_system_memory || failure runner "Post-lane memory sampling failed"
  [[ "$SYSTEM_PRESSURE_LEVEL" != critical ]] \
    || failure runner "Mac remains under critical memory pressure after $lane"
  jq -n --arg lane "$lane" --arg corpus "$corpus" --arg source "$source" \
    --arg sourceHash "$(sha256 "$source")" --arg archive "$archive" \
    --arg archiveHash "$(sha256 "$archive")" --arg job "$job" \
    --arg manifest "$(sha256 "$job/manifest.json")" --arg raw "$(sha256 "$job/raw-asr.json")" \
    --arg safety "$(sha256 "$directory/safety.json")" --arg report "$(sha256 "$directory/row-report.json")" \
    --argjson implementation "$(implementation_hashes)" \
    '{ticket:121,lane:$lane,corpusID:$corpus,source:{path:$source,sha256:$sourceHash},
      referenceArchive:{path:$archive,sha256:$archiveHash},jobDirectory:$job,
      rawArtifactSHA256:{manifest:$manifest,rawEvidence:$raw,rowReport:$report,safety:$safety},
      implementationSHA256:$implementation}' >"$directory/run-meta.json"
}

freeze_development() {
  PHASE=freeze-development
  [[ ! -e "$FREEZE" ]] || failure runner "DEV freeze already exists and will not be rewritten"
  local report="$ARTIFACTS/development/row-report.json" job
  job="$(jq -r .jobDirectory "$report")"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg matrix "$(sha256 "$ARTIFACTS/matrix.json")" \
    --arg ready "$(sha256 "$READY")" --arg manifest "$(sha256 "$job/manifest.json")" \
    --arg raw "$(sha256 "$job/raw-asr.json")" --arg report "$(sha256 "$report")" \
    --argjson configuration "$(jq '{translator,speakerLabels,readableSubtitles,
      adaptiveASRSelected}' "$report")" \
    '{schemaVersion:1,ticket:121,frozenAt:$at,matrixSHA256:$matrix,readySHA256:$ready,
      developmentArtifactsSHA256:{manifest:$manifest,rawEvidence:$raw,rowReport:$report},
      configuration:$configuration,
      immutableGates:{completedSavedProjectJob:true,structuredCueIDsExact:true,
        strictlySequentialWorkers:true,speakerOnlyUpstreamUnchanged:true,
        editorExportsAndAuditConsistent:true,voiceMemoryCrossProjectSuggestions:0,
        rejectedCandidatesRemainUnselected:true},
      qualityMetricsAreReportingOnly:true,
      productDefaultPromotionAuthorized:false}' >"$FREEZE"
}

final_checks() {
  PHASE=final-tests
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift test \
    2>&1 | tee "$ARTIFACTS/full-swift-test.log"
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift test --skip-build --filter LiveCaptionTests \
    2>&1 | tee "$ARTIFACTS/live-tests.log"
  PHASE=app-launch
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift run \
    >"$ARTIFACTS/app-launch.log" 2>&1 &
  local app_pid="$!"
  sleep 8
  process_running "$app_pid" || failure build "Application did not remain running after launch"
  jq -n --argjson pid "$app_pid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{launched:true,pid:$pid,at:$at}' >"$ARTIFACTS/app-launch.json"
}

write_hashes() {
  PHASE=hash-ledger
  (
    cd "$ARTIFACTS"
    find . -type f ! -name sha256.tsv -print0 | sort -z \
      | xargs -0 shasum -a 256 >sha256.tsv
  )
}

prepare_holdout_resume() {
  PHASE=prepare-holdout-resume
  local report="$ARTIFACTS/development/row-report.json" job original_ready_hash
  [[ -f "$report" && -f "$READY" ]] \
    || failure runner "Retained DEV row and original READY are required"
  job="$(jq -r .jobDirectory "$report")"
  [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]] \
    || failure runner "Retained DEV raw artifacts are incomplete"
  jq -e '.status == "completed" and .translationModel.modelID
    == "mlx-community/translategemma-12b-it-4bit" and .speakerReanalysisCount == 1' \
    "$job/manifest.json" >/dev/null || failure candidate "Retained DEV product result is invalid"
  jq -e '.stopReason == "completed" and .forcedTermination == false' \
    "$ARTIFACTS/development/safety.json" >/dev/null \
    || failure runner "Retained DEV safety result is invalid"
  assert_worker_exit "$job/raw-asr.json"
  original_ready_hash="$(sha256 "$READY")"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg originalReady "$original_ready_hash" \
    --arg manifest "$(sha256 "$job/manifest.json")" \
    --arg raw "$(sha256 "$job/raw-asr.json")" \
    --arg safety "$(sha256 "$ARTIFACTS/development/safety.json")" \
    --arg samples "$(sha256 "$ARTIFACTS/development/safety.samples.jsonl")" \
    --arg row "$(sha256 "$report")" \
    --argjson producerImplementation "$(jq '.implementationSHA256' "$READY")" \
    --argjson resumedImplementation "$(implementation_hashes)" \
    '{schemaVersion:1,ticket:121,at:$at,classification:"harness-integration-recovery",
      heavyDEVReused:true,heavyDEVRerun:false,holdoutOpened:false,
      reason:"The product job and Speaker-only run completed; validation then used an over-strict alignment equality and a stale in-memory result for Voice provenance.",
      fix:"Compare immutable alignment chunks/worker rather than speaker attachments; accept semantically identical decoded persisted evidence while retaining disk hash and stale-result rejection.",
      originalReadySHA256:$originalReady,
      retainedArtifactsSHA256:{manifest:$manifest,rawEvidence:$raw,safety:$safety,
        safetySamples:$samples,rowReport:$row},
      producerImplementationSHA256:$producerImplementation,
      resumedImplementationSHA256:$resumedImplementation}' \
    >"$ARTIFACTS/harness-recovery.json"
  if [[ ! -f "$FREEZE" ]]; then freeze_development; fi
  local freeze_hash="$(sha256 "$FREEZE")"
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift build \
    2>&1 | tee "$ARTIFACTS/holdout-build.log"
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift test --skip-build --filter \
    'HighQualityJobTests/testVoiceProfileAcceptsTheSemanticallyIdenticalReopenedEvidence|HighQualityJobTests/testProjectVoiceOperationsRejectStaleManifestAndEvidence|HighQualityJobTests/testProjectVoiceMemoryDefaultsOffAndStaysIsolatedAfterReopenAndRename|HighQualityJobTests/testReadableSubtitleBetaControlsVisibilityAndSafeDefault|HighQualityAdaptiveASRTests/testAdaptiveModeUsesShortAcousticSegmentsWithoutChangingTheDefault' \
    2>&1 | tee "$ARTIFACTS/holdout-light-tests.log"
  python3 Scripts/report_final_offline_validation.py --self-test
  verify_models
  jq -n --arg commit "$(git rev-parse HEAD)" \
    --arg command 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer BENCHMARK_SLOT_GRANTED=121 bash Scripts/run_final_offline_validation.sh resume-holdout' \
    --arg freeze "$freeze_hash" --arg recovery "$(sha256 "$ARTIFACTS/harness-recovery.json")" \
    --arg matrix "$(sha256 "$ARTIFACTS/matrix.json")" \
    --arg inputs "$(sha256 "$ARTIFACTS/input-preflight.tsv")" \
    --arg models "$(sha256 "$ARTIFACTS/model-provenance.json")" \
    --arg worker "$(sha256 "$WORKER")" \
    --arg metallib "$(sha256 "$ROOT/.build/debug/mlx.metallib")" \
    --argjson implementation "$(implementation_hashes)" \
    '{ticket:121,status:"READY_FOR_HOLDOUT",baseCommit:$commit,command:$command,
      heavyModelsLoaded:false,DEVReused:true,DEVRerun:false,
      estimate:{wallTime:"6-12 minutes plus final tests",peakProcessTree:"5-7 GiB",
        additionalDisk:"under 500 MiB"},
      order:["verify immutable DEV freeze and recovered hashes",
        "holdout saved Project job: Qwen+aligner+4B+Readable",
        "report, full tests, Live tests, app launch"],
      gates:{oneHeavyWorkerAtATime:true,warningAloneStops:false,
        criticalOrRunawayStops:true,DEVFreezeImmutable:true,
        allPreviousWorkerPIDsExited:true,candidateFailuresSeparated:true},
      provenanceSHA256:{developmentFreeze:$freeze,harnessRecovery:$recovery,
        matrix:$matrix,inputs:$inputs,models:$models,worker:$worker,mlxMetallib:$metallib},
      implementationSHA256:$implementation}' >"$HOLDOUT_READY"
  echo "READY_FOR_HOLDOUT #121"
  jq '{command,estimate,order,gates}' "$HOLDOUT_READY"
}

verify_holdout_ready() {
  [[ -f "$HOLDOUT_READY" && -f "$FREEZE" ]] \
    || failure runner "Prepare the recovered holdout READY first"
  jq -e '.ticket == 121 and .status == "READY_FOR_HOLDOUT"
    and .heavyModelsLoaded == false and .DEVReused == true and .DEVRerun == false' \
    "$HOLDOUT_READY" >/dev/null || failure runner "Invalid recovered holdout READY"
  [[ "$(sha256 "$FREEZE")" == "$(jq -r .provenanceSHA256.developmentFreeze "$HOLDOUT_READY")" ]] \
    || failure runner "DEV freeze changed before holdout"
  [[ "$(sha256 "$ARTIFACTS/harness-recovery.json")" \
      == "$(jq -r .provenanceSHA256.harnessRecovery "$HOLDOUT_READY")" ]] \
    || failure runner "Harness recovery changed before holdout"
  [[ "$(sha256 "$WORKER")" == "$(jq -r .provenanceSHA256.worker "$HOLDOUT_READY")" ]] \
    || failure build "Worker changed before recovered holdout"
  [[ "$(jq -cS . <<<"$(implementation_hashes)")" \
      == "$(jq -cS .implementationSHA256 "$HOLDOUT_READY")" ]] \
    || failure build "Implementation changed before recovered holdout"
}

resume_holdout() {
  [[ "${BENCHMARK_SLOT_GRANTED:-}" == 121 ]] \
    || failure runner "Refusing heavy #121 holdout without BENCHMARK_SLOT_GRANTED=121"
  verify_holdout_ready
  trap on_error ERR
  trap cleanup_active_process EXIT
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM
  local freeze_hash="$(sha256 "$FREEZE")"
  run_lane holdout md62mmdz0m translategemma-4b-it-4bit 0 1 0
  [[ "$(sha256 "$FREEZE")" == "$freeze_hash" ]] \
    || failure runner "DEV freeze changed after holdout opened"
  PHASE=report
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --json "$ARTIFACTS/report.json" --markdown "$ARTIFACTS/report.md"
  jq -e 'all(.gates[]; . == true)' "$ARTIFACTS/report.json" >/dev/null \
    || failure candidate "A final product acceptance gate failed; raw artifacts are retained"
  final_checks
  write_hashes
  rm -f "$ARTIFACTS/failure.json"
  echo "READY_FOR_REVIEW #121"
}

full_run() {
  [[ "${BENCHMARK_SLOT_GRANTED:-}" == 121 ]] \
    || failure runner "Refusing heavy #121 run without BENCHMARK_SLOT_GRANTED=121"
  verify_ready
  trap on_error ERR
  trap cleanup_active_process EXIT
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM
  run_lane development qudu2fx3ncc translategemma-12b-it-4bit 1 0 1
  freeze_development
  local freeze_hash="$(sha256 "$FREEZE")"
  run_lane holdout md62mmdz0m translategemma-4b-it-4bit 0 1 0
  [[ "$(sha256 "$FREEZE")" == "$freeze_hash" ]] \
    || failure runner "DEV freeze changed after holdout opened"
  PHASE=report
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --json "$ARTIFACTS/report.json" --markdown "$ARTIFACTS/report.md"
  jq -e 'all(.gates[]; . == true)' "$ARTIFACTS/report.json" >/dev/null \
    || failure candidate "A final product acceptance gate failed; raw artifacts are retained"
  final_checks
  write_hashes
  rm -f "$ARTIFACTS/failure.json"
  echo "READY_FOR_REVIEW #121"
}

main_final_validation() {
  cd "$ROOT"
  case "$MODE" in
    preflight) preflight ;;
    full) full_run ;;
    prepare-holdout-resume) prepare_holdout_resume ;;
    resume-holdout) resume_holdout ;;
    *) echo "usage: $0 [preflight|full|prepare-holdout-resume|resume-holdout]" >&2; exit 2 ;;
  esac
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main_final_validation
