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
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-$HOME/Documents/videos/jap}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-$HOME/Documents/projets/whisperASR}"
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
  while IFS= read -r path; do
    value="$(jq -c --arg path "$path" --arg digest "$(sha256 "$ROOT/$path")" \
      '. + {($path):$digest}' <<<"$value")"
  done < <({ find Sources Tests -type f -name '*.swift' -print; printf '%s\n' \
    Package.swift Package.resolved \
    Scripts/run_final_offline_validation.sh \
    Scripts/report_final_offline_validation.py \
    Scripts/run_mossformer2_oracle_experiment.sh \
    Scripts/report_high_quality_acceptance.py \
    Scripts/report_japanese_l7d.py \
    Scripts/report_local_translator_bakeoff.py; } | sort -u)
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
       readableSubtitles:true,postActions:[]},
      {order:"lightweight",lane:"model-free-safe-options-combined",projectWorkflow:true,
       fixtureOnly:true,speakerLabels:true,readableSubtitles:true,
       test:"HighQualityJobTests/testSpeakerLabelsAndReadableSubtitlesRemainIndependentWhenCombined"}
    ],coverage:{translatorChoice:["12B","4B"],speakerLabels:[true,false],
      readableSubtitles:[false,true],savedProjectJob:[true],
      safeSupportedCombination:["speakerLabels + readableSubtitles"],
      dependencies:["Qwen JA","Forced Aligner","SpeakerKit","TranslateGemma","export"]},
    retainedWithoutRerun:{adaptiveASR:"RETAIN-HIDDEN / NO-GO DEV",
      targetedWhisperKit:"RETAIN-HIDDEN / NO-GO DEV",
      lexicalCorrection:"NO-GO DEV"},
    retainedDecisionLedger:"docs/japanese-live/experiments/evidence/issue-121/retained-decisions.json",
    rationale:"Two real jobs plus one model-free safe-options combination cover the risk-based matrix; exact retained decisions cover rejected candidates without reopening holdout."}' \
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
  local ledger="docs/japanese-live/experiments/evidence/issue-121/retained-decisions.json"
  while IFS=$'\t' read -r path expected; do
    [[ -f "$path" && "$(sha256 "$path")" == "$expected" ]] \
      || failure reference "Retained decision evidence changed: $path"
  done < <(jq -r '.decisions[] | .[] | select(type == "object" and has("path"))
    | [.path,.sha256] | @tsv' "$ledger")
  jq -e '.result == "RETAIN_HIDDEN_DEV_NO_GO"
    and .execution.holdoutOpened == false and .scope.adaptiveExposed == false
    and .scope.standardDefaultPreserved == true' \
    docs/japanese-live/experiments/evidence/issue-117-adaptive-asr.json >/dev/null \
    || failure reference "Adaptive ASR retained decision changed"
  jq -e '.result == "RETAIN_HIDDEN_DEV_NO_GO"
    and .execution.holdoutOpened == false and .scope.adaptiveExposed == false
    and .scope.standardDefaultPreserved == true' \
    docs/japanese-live/experiments/evidence/issue-118-targeted-whisperkit.json >/dev/null \
    || failure reference "Targeted WhisperKit retained decision changed"
  jq -e '.gates.developmentPassed == false and .gates.downstreamEnglishRun == false
    and .gates.holdoutOpened == false' \
    docs/japanese-live/experiments/evidence/E33/development-report.json >/dev/null \
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
  git diff --check || failure build "Worktree diff validation failed"
  git diff --binary >"$ARTIFACTS/worktree.patch"
  bash -n Scripts/run_final_offline_validation.sh \
    || failure build "Final validation runner syntax is invalid"
  python3 -m py_compile Scripts/report_final_offline_validation.py \
    || failure build "Final validation reporter does not compile"
  python3 Scripts/report_final_offline_validation.py --self-test \
    || failure test "Final validation reporter self-tests failed"
  if ! DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift build \
      2>&1 | tee "$ARTIFACTS/build.log"; then
    failure build "Swift build failed during preflight"
  fi
  if ! bash Scripts/build_mlx_metallib.sh debug \
      2>&1 | tee "$ARTIFACTS/metallib.log"; then
    failure build "MLX metallib build failed during preflight"
  fi
  run_test_and_verify "$ARTIFACTS/light-tests.log" "Selected tests" \
    xcrun swift test --skip-build --filter \
      'HighQualityAcceptanceTests/testFinalValidationWorkerSummaryIncludesPostTranslationSpeakerReanalysis|HighQualityAcceptanceTests/testRealFinalProjectWorkflowWhenOptedIn|HighQualityJobTests/testReadableSubtitleBetaControlsVisibilityAndSafeDefault|HighQualityJobTests/testProjectVoiceMemoryDefaultsOffAndStaysIsolatedAfterReopenAndRename|HighQualityJobTests/testProjectVoiceMemoryEndToEndUsesOnlyPublicProjectResultSeams|HighQualityJobTests/testSpeakerBetaControlsVisibilityAndSafeDefaults|HighQualityAdaptiveASRTests/testAdaptiveModeUsesShortAcousticSegmentsWithoutChangingTheDefault'
  run_test_and_verify "$ARTIFACTS/safe-options-combined.log" "Selected tests" \
    xcrun swift test --skip-build --filter \
      HighQualityJobTests/testSpeakerLabelsAndReadableSubtitlesRemainIndependentWhenCombined
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
  local safety_clean=0 manifest="" stage candidate_count=0 candidate
  jq -e '.stopReason == "completed" and .exitStatus == 0
    and .forcedTermination == false' "$directory/safety.json" >/dev/null \
    && safety_clean=1
  if ((status != 0 || safety_clean == 0)) || [[ ! -f "$directory/row-report.json" ]]; then
    if [[ -f "$directory/row-report.json" ]]; then
      candidate="$(jq -r .jobDirectory "$directory/row-report.json")/manifest.json"
      if [[ -f "$candidate" ]] && jq -e --arg source "$source" \
          --arg jobID "$(jq -r .jobID "$directory/row-report.json")" \
          '.source.path == $source and .jobID == $jobID' "$candidate" >/dev/null; then
        manifest="$candidate"
      fi
    else
      while IFS= read -r candidate; do
        if jq -e --arg source "$source" '.source.path == $source' "$candidate" >/dev/null; then
          manifest="$candidate"
          candidate_count=$((candidate_count + 1))
        fi
      done < <(find "$PROJECTS" -path '*/Jobs/*/manifest.json' -newer "$marker" -print | sort)
      ((candidate_count <= 1)) \
        || failure runner "Multiple new saved jobs match $lane; candidate attribution is ambiguous"
    fi
    if [[ -n "$manifest" ]]; then
      stage="$(jq -r '.failures[0].stage // empty' "$manifest")"
      [[ -z "$stage" ]] || failure candidate "Product candidate failed at $stage in $lane"
    fi
    ((safety_clean == 1)) \
      || failure runner "Safety/process gate did not complete cleanly for $lane"
    failure runner "XCTest/harness failed before an auditable $lane result"
  fi
  local job
  job="$(jq -r .jobDirectory "$directory/row-report.json")"
  [[ -f "$job/raw-asr.json" && -f "$job/manifest.json" ]] \
    || failure runner "Saved Project artifacts are missing for $lane"
  jq -e --arg source "$source" --arg jobID "$(jq -r .jobID "$directory/row-report.json")" \
    '.status == "completed" and .failures == [] and .projectID != null
      and .source.path == $source and .jobID == $jobID' \
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
  verify_hidden_decisions
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --development-freeze "$FREEZE"
  jq -e '.derivation.status == "computed-before-holdout"
    and .derivation.allFunctionalGatesPassed == true
    and all(.computedGates[]; . == true)' "$FREEZE" >/dev/null \
    || failure runner "Computed DEV freeze gates did not pass"
}

run_test_and_verify() {
  local log="$1" suite="$2" status=0 summary classification
  shift 2
  if "$@" 2>&1 | tee "$log"; then status=0; else status="$?"; fi
  summary="$(python3 Scripts/report_final_offline_validation.py \
    --classify-test-log "$log" --suite "$suite" 2>/dev/null || true)"
  classification="$(jq -r '.status // "notScored"' <<<"$summary")"
  if ((status != 0)) || [[ "$classification" != passed ]]; then
    [[ "$classification" != buildFailed ]] \
      || failure build "Build failed while running $suite; see $log"
    failure test "$suite did not pass (process=$status, parsed=$classification); see $log"
  fi
}

final_checks() {
  PHASE=final-tests
  run_test_and_verify "$ARTIFACTS/full-swift-test.log" "All tests" \
    xcrun swift test
  run_test_and_verify "$ARTIFACTS/live-tests.log" "Selected tests" \
    xcrun swift test --skip-build --filter LiveCaptionTests
  run_test_and_verify "$ARTIFACTS/safe-options-combined.log" "Selected tests" \
    xcrun swift test --skip-build --filter \
      HighQualityJobTests/testSpeakerLabelsAndReadableSubtitlesRemainIndependentWhenCombined
  PHASE=app-launch
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift run \
    >"$ARTIFACTS/app-launch.log" 2>&1 &
  local launcher_pid="$!" app_pid
  sleep 8
  app_pid="$(pgrep -f "$(basename "$ROOT")/.build/.*/WhisperASR$" | tail -1)"
  [[ -n "$app_pid" ]] || app_pid="$launcher_pid"
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
  local recovery_temp ready_temp
  [[ -f "$report" && -f "$READY" ]] \
    || failure runner "Retained DEV row and original READY are required"
  job="$(jq -r .jobDirectory "$report")"
  [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]] \
    || failure runner "Retained DEV raw artifacts are incomplete"
  jq -e '.status == "completed" and .translationModel.modelID
    == "mlx-community/translategemma-12b-it-4bit" and .speakerReanalysisCount == 1' \
    "$job/manifest.json" >/dev/null || failure candidate "Retained DEV product result is invalid"
  jq -e '.stopReason == "completed" and .exitStatus == 0
    and .forcedTermination == false' \
    "$ARTIFACTS/development/safety.json" >/dev/null \
    || failure runner "Retained DEV is not eligible for fail-closed recovery"
  assert_worker_exit "$job/raw-asr.json"
  if [[ ! -f "$FREEZE" ]]; then freeze_development; fi
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --verify-development-freeze "$FREEZE" >/dev/null \
    || failure runner "Retained DEV freeze schema, gates or artifact hashes are stale"
  original_ready_hash="$(sha256 "$READY")"
  recovery_temp="$(mktemp "$ARTIFACTS/.harness-recovery.XXXXXX")"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg originalReady "$original_ready_hash" \
    --arg manifest "$(sha256 "$job/manifest.json")" \
    --arg raw "$(sha256 "$job/raw-asr.json")" \
    --arg safety "$(sha256 "$ARTIFACTS/development/safety.json")" \
    --arg samples "$(sha256 "$ARTIFACTS/development/safety.samples.jsonl")" \
    --arg row "$(sha256 "$report")" \
    --arg freeze "$(sha256 "$FREEZE")" \
    --argjson producerImplementation "$(jq '.implementationSHA256' "$READY")" \
    --argjson resumedImplementation "$(implementation_hashes)" \
    '{schemaVersion:2,ticket:121,at:$at,classification:"clean-controller-resume",
      heavyDEVReused:true,heavyDEVRerun:false,holdoutOpened:false,
      strictFailClosedDevelopment:true,
      reason:"The DEV process exited zero and all computed post-action gates passed before controller resume.",
      fix:null,
      originalReadySHA256:$originalReady,
      developmentFreezeSHA256:$freeze,
      retainedArtifactsSHA256:{manifest:$manifest,rawEvidence:$raw,safety:$safety,
        safetySamples:$samples,rowReport:$row},
      producerImplementationSHA256:$producerImplementation,
      resumedImplementationSHA256:$resumedImplementation}' \
    >"$recovery_temp"
  mv "$recovery_temp" "$ARTIFACTS/harness-recovery.json"
  local freeze_hash="$(sha256 "$FREEZE")"
  if ! DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift build \
      2>&1 | tee "$ARTIFACTS/holdout-build.log"; then
    failure build "Swift build failed while preparing holdout resume"
  fi
  run_test_and_verify "$ARTIFACTS/holdout-light-tests.log" "Selected tests" \
    xcrun swift test --skip-build --filter \
      'HighQualityJobTests/testVoiceProfileAcceptsTheSemanticallyIdenticalReopenedEvidence|HighQualityJobTests/testProjectVoiceOperationsRejectStaleManifestAndEvidence|HighQualityJobTests/testProjectVoiceMemoryDefaultsOffAndStaysIsolatedAfterReopenAndRename|HighQualityJobTests/testReadableSubtitleBetaControlsVisibilityAndSafeDefault|HighQualityAdaptiveASRTests/testAdaptiveModeUsesShortAcousticSegmentsWithoutChangingTheDefault'
  python3 Scripts/report_final_offline_validation.py --self-test
  verify_models
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --verify-development-freeze "$FREEZE" >/dev/null \
    || failure runner "DEV freeze changed during holdout preparation"
  ready_temp="$(mktemp "$ARTIFACTS/.READY_FOR_HOLDOUT.XXXXXX")"
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
        strictFailClosedDevelopment:true,allPreviousWorkerPIDsExited:true,
        candidateFailuresSeparated:true},
      provenanceSHA256:{developmentFreeze:$freeze,harnessRecovery:$recovery,
        matrix:$matrix,inputs:$inputs,models:$models,worker:$worker,mlxMetallib:$metallib},
      implementationSHA256:$implementation}' >"$ready_temp"
  mv "$ready_temp" "$HOLDOUT_READY"
  echo "READY_FOR_HOLDOUT #121"
  jq '{command,estimate,order,gates}' "$HOLDOUT_READY"
}

verify_holdout_ready() {
  [[ -f "$HOLDOUT_READY" && -f "$FREEZE" ]] \
    || failure runner "Prepare the recovered holdout READY first"
  jq -e '.ticket == 121 and .status == "READY_FOR_HOLDOUT"
    and .heavyModelsLoaded == false and .DEVReused == true and .DEVRerun == false' \
    "$HOLDOUT_READY" >/dev/null || failure runner "Invalid recovered holdout READY"
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --verify-development-freeze "$FREEZE" >/dev/null \
    || failure runner "DEV freeze no longer matches recomputed gates and artifacts"
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
  final_checks
  PHASE=report
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --json "$ARTIFACTS/report.json" --markdown "$ARTIFACTS/report.md"
  jq -e '.functionalAcceptancePassed == true' "$ARTIFACTS/report.json" >/dev/null \
    || failure candidate "A final functional gate failed; raw artifacts are retained"
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
  final_checks
  PHASE=report
  python3 Scripts/report_final_offline_validation.py "$ARTIFACTS" \
    --json "$ARTIFACTS/report.json" --markdown "$ARTIFACTS/report.md"
  jq -e '.functionalAcceptancePassed == true' "$ARTIFACTS/report.json" >/dev/null \
    || failure candidate "A final functional gate failed; raw artifacts are retained"
  write_hashes
  rm -f "$ARTIFACTS/failure.json"
  echo "READY_FOR_REVIEW #121"
}

main_final_validation() {
  cd "$ROOT"
  trap on_error ERR
  case "$MODE" in
    preflight) preflight ;;
    full) full_run ;;
    prepare-holdout-resume) prepare_holdout_resume ;;
    resume-holdout) resume_holdout ;;
    *) echo "usage: $0 [preflight|full|prepare-holdout-resume|resume-holdout]" >&2; exit 2 ;;
  esac
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main_final_validation
