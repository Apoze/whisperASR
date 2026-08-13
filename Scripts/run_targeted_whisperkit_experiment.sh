#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

MODE="${1:-preflight}"
BASE_COMMIT=c6c1c04606bff92c14cdebb16a299af5be35e716
RETEST_BASE=ad3d56feffec443e36af7adb68ce7fa9b3e4f32c
ARTIFACTS="$ROOT/.build/benchmarks/issue-95"
DEV="$ARTIFACTS/development"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E29"
READY_EVIDENCE="$EVIDENCE/READY_FOR_HEAVY_BENCHMARK.json"
RUNNER_INCIDENT="$EVIDENCE/retest-runner-incident.json"
ORCHESTRATOR_INCIDENT="$EVIDENCE/retest-orchestrator-sigterm.json"
INCIDENT_STATE="$EVIDENCE/retest-orchestrator-sigterm-state.json"
INCIDENT_LOG="$EVIDENCE/retest-orchestrator-sigterm.log"
E28="$ROOT/docs/japanese-live/experiments/evidence/E28"
FROZEN="/Users/maz/Documents/projets/whisperASR"
PCM="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/audio-16k-mono.wav"
CHARACTERS="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/character-alignment.jsonl"
REFERENCE_MANIFEST="$ROOT/docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
E23="$ROOT/docs/japanese-live/experiments/evidence/E23/segments.json"
BASELINE_RAW="$ROOT/docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz"
PLAN="$E28/window-plan.json"
ASR_RUN="$E28/asr-run.json"
BASE_SELECTION="$E28/selection.json"
ISSUE94_COMPLETION="$E28/targeted-translation-completion.json"
ISSUE94_REPORT="$E28/report.json"
MODEL_ROOT="/Users/maz/Library/Application Support/WhisperASR/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3"
ALIGNER_WEIGHT="/Users/maz/.cache/huggingface/hub/models--mlx-community--Qwen3-ForcedAligner-0.6B-4bit/snapshots/2f652af86ae0c73fe189b9429225c908ce4bf020/model.safetensors"
TRANSLATOR_ROOT="/Users/maz/.cache/huggingface/hub/models--mlx-community--translategemma-12b-it-4bit/snapshots/f3dcfd54df14672fbcf0731086fb47a797a943ae"
WORKER="$ROOT/.build/debug/WhisperASR"
TRIGGER_PLAN="$ARTIFACTS/trigger-plan.json"
TRIGGER_REPORT="$ARTIFACTS/trigger-report.json"
READY="$ARTIFACTS/READY_FOR_HEAVY_BENCHMARK.json"
STATE="$ARTIFACTS/heavy-run-state.json"
WHISPERKIT_RUN="$DEV/whisperkit-run.json"
WHISPERKIT_RUNTIME="$DEV/whisperkit-runtime.json"
SELECTION="$DEV/selection.json"
SELECTION_REPORT="$DEV/selection-report.json"
TRANSLATION_RUNTIME="$DEV/translation-runtime.json"
TRANSLATION_LOG="$DEV/translation.log"
TRANSLATION_OUTPUT="$DEV/translation"
JOB_ID=95000001-0000-4000-8000-000000000001
CANDIDATE="$TRANSLATION_OUTPUT/$JOB_ID"
FINAL_REPORT="$EVIDENCE/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E29-targeted-whisperkit.md"

case "$MODE" in self-test|preflight|verify-ready|development|report) ;;
  *) echo "usage: $0 [self-test|preflight|verify-ready|development|report]" >&2; exit 2 ;;
esac

require_benchmark_slot() {
  [[ "${BENCHMARK_SLOT_GRANTED:-}" == 95 \
    && "${BENCHMARK_SLOT_CONFIRMED_BY_USER:-}" == 95 ]] || {
    echo "explicit user-confirmed benchmark slot #95 required" >&2
    return 2
  }
}

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
assert_hash() {
  [[ -f "$1" ]] || { echo "missing input: $1" >&2; return 1; }
  local observed
  observed="$(hash_file "$1")"
  [[ "$observed" == "$2" ]] || {
    echo "hash mismatch: $1 ($observed != $2)" >&2
    return 1
  }
}

restore_scratch() {
  mkdir -p "$DEV"
  cp "$READY_EVIDENCE" "$READY"
  cp "$EVIDENCE/retest-trigger-plan.json" "$TRIGGER_PLAN"
  cp "$EVIDENCE/retest-trigger-report.json" "$TRIGGER_REPORT"
  cp "$EVIDENCE/whisperkit-run.json" "$WHISPERKIT_RUN"
  cp "$EVIDENCE/whisperkit-runtime.json" "$WHISPERKIT_RUNTIME"
  cp "$EVIDENCE/retest-selection.json" "$SELECTION"
  cp "$EVIDENCE/retest-selection-report.json" "$SELECTION_REPORT"
}

verify_inputs() {
  [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]
  command -v jq python3 shasum xcrun >/dev/null
  git merge-base --is-ancestor "$BASE_COMMIT" HEAD
  assert_hash "$PCM" 494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2
  assert_hash "$CHARACTERS" abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7
  assert_hash "$REFERENCE_MANIFEST" a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b
  assert_hash "$E23" e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81
  assert_hash "$BASELINE_RAW" 1f5edc2fcb929c9abc2cb85256f326bbf2891a200ef66d1c1cb9a66a9c711ce8
  assert_hash "$PLAN" 3bfa62a1e0ded143555c61f8a02e65501b8b72adf2dfa277527c2d8de4c4b1a8
  assert_hash "$ASR_RUN" c4ff5fa759801301806aaccf1fc3081b9522d5902518422c64ca875475eabc52
  assert_hash "$BASE_SELECTION" 4279b6e2a187f5c8c0695b79c085af8c42b0e8fc294fdc0c0e07fffec4521a2f
  assert_hash "$ISSUE94_COMPLETION" 1fa151af988750734445e708452e7cde17c3f57d2864fc266702bfd541d244a7
  assert_hash "$ISSUE94_REPORT" 25d38a79db2673a9baac37be0d376a70cfe0abbb74d8c35f4729696f248a4fee
  assert_hash "$EVIDENCE/whisperkit-run.json" e5903c6cde8d79b95f8cb375ceb3d867cd2ab3b07964e29bd4f39bfe450477d3
  assert_hash "$EVIDENCE/whisperkit-runtime.json" 404f631139a7ba47b23c5af6a275333d8b3d29adadcec8cc34fefc120739e11c
  assert_hash "$RUNNER_INCIDENT" 51220e4e5d53c2dffcd72881278f97af560c33f717464895d8d0d40c69f8d2bd
  assert_hash "$ORCHESTRATOR_INCIDENT" 9810ad8fec4e43b0eefe1be56f53a92092339d842c2574d19eb3a2a6f59ed1b0
  assert_hash "$INCIDENT_STATE" e93fdf8e9c483b782e3620300d55171449a0aff476cef706a098db0a7c67bcbc
  assert_hash "$INCIDENT_LOG" 1fb28a4386f423e9867aa2065ff7483e1b0471037774d0e6284aee92c657353d
  [[ -z "$({ git diff --name-only "$RETEST_BASE" -- Sources; \
    git ls-files --others --exclude-standard -- Sources; } | sort -u)" ]] || {
      echo "issue #95 retest must not change product Sources" >&2; return 1;
    }
}

verify_models() {
  assert_hash "$MODEL_ROOT/AudioEncoder.mlmodelc/weights/weight.bin" \
    eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457
  assert_hash "$MODEL_ROOT/MelSpectrogram.mlmodelc/weights/weight.bin" \
    97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87
  assert_hash "$MODEL_ROOT/TextDecoder.mlmodelc/weights/weight.bin" \
    680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55
  assert_hash "$ALIGNER_WEIGHT" 630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c
  assert_hash "$TRANSLATOR_ROOT/model-00001-of-00002.safetensors" \
    bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af
  assert_hash "$TRANSLATOR_ROOT/model-00002-of-00002.safetensors" \
    c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89
}

build_and_probe() {
  mkdir -p "$ARTIFACTS/controls"
  xcrun swift build --disable-sandbox 2>&1 | tee "$ARTIFACTS/controls/build.log"
  [[ -f "$ROOT/.build/debug/mlx.metallib" ]] || bash Scripts/build_mlx_metallib.sh debug \
    2>&1 | tee "$ARTIFACTS/controls/mlx-metallib.log"
  xcrun swift test --disable-sandbox --filter \
    'AdaptiveASRExperimentTests|HighQualityASRWorkerTests/testEveryBackendRoundTripsOneTranscriptAndExits|HighQualityASRWorkerTests/testMalformedOutputFailsAndWorkerTerminates|HighQualityASRWorkerTests/testPreparationFailureTerminatesWithDiagnostics' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  [[ -x "$WORKER" ]]
  python3 Scripts/qwen_voice_music_harness.py run-command --timeout 5 \
    --log "$ARTIFACTS/controls/worker-probe.log" \
    --runtime "$ARTIFACTS/controls/worker-probe-runtime.json" -- \
    "$WORKER" --high-quality-asr-worker --probe
  grep -Fxq WHISPERASR_HIGH_QUALITY_ASR_WORKER_PROBE_OK \
    "$ARTIFACTS/controls/worker-probe.log"
}

prepare_light_evidence() {
  mkdir -p "$ARTIFACTS" "$DEV" "$EVIDENCE"
  python3 Scripts/targeted_whisperkit_harness.py self-test
  python3 Scripts/targeted_whisperkit_harness.py analyze \
    --plan "$PLAN" --run "$ASR_RUN" --selection "$BASE_SELECTION" \
    --reference-manifest "$REFERENCE_MANIFEST" \
    --character-alignment "$CHARACTERS" --e23-segments "$E23" \
    --trigger-plan "$TRIGGER_PLAN" --report "$TRIGGER_REPORT"
  jq -e '.holdoutOpened == false and .heavyRunJustified == true
    and .triggerCount == 6 and .triggeredSeconds == 27.96
    and .calibration.threshold == 0.25
    and .referenceEvaluability.completeForEveryWindow == true
    and .referenceEvaluability.completeForEveryTriggeredWindow == true' \
    "$TRIGGER_REPORT" >/dev/null
  jq -e '.ticket == 95 and .holdoutOpened == false and (.windows | length) == 6
    and .rule.requiresBothSignals == true' "$TRIGGER_PLAN" >/dev/null
  ! grep -qi reference "$TRIGGER_PLAN"
  cp "$EVIDENCE/whisperkit-run.json" "$WHISPERKIT_RUN"
  cp "$EVIDENCE/whisperkit-runtime.json" "$WHISPERKIT_RUNTIME"
  select_candidate
  jq -e '.holdoutOpened == false' "$SELECTION" >/dev/null
}

write_ready() {
  local free_disk total_ram
  free_disk="$(df -k "$ROOT" | awk 'NR==2 {printf "%.0f", $4 * 1024}')"
  total_ram="$(sysctl -n hw.memsize 2>/dev/null || true)"
  if [[ -z "$total_ram" ]]; then
    total_ram="$(system_profiler SPHardwareDataType 2>/dev/null \
      | awk '/Memory:/ {printf "%.0f", $2 * 1024 * 1024 * 1024}')"
  fi
  (( free_disk >= 5 * 1024 * 1024 * 1024 ))
  jq -n \
    --arg command 'BENCHMARK_SLOT_GRANTED=95 BENCHMARK_SLOT_CONFIRMED_BY_USER=95 bash Scripts/run_targeted_whisperkit_experiment.sh development' \
    --argjson freeDisk "$free_disk" --argjson totalRAM "$total_ram" \
    --arg harness "$(hash_file Scripts/targeted_whisperkit_harness.py)" \
    --arg adaptive "$(hash_file Scripts/adaptive_asr_harness.py)" \
    --arg runner "$(hash_file Scripts/run_targeted_whisperkit_experiment.sh)" \
    --arg tests "$(hash_file Tests/AdaptiveASRExperimentTests.swift)" \
    --arg job "$(hash_file Sources/HighQualityJob.swift)" \
    --arg runtime "$(hash_file Sources/WhisperKitRuntime.swift)" \
    --arg workerSource "$(hash_file Sources/HighQualityASRWorker.swift)" \
    --arg binary "$(hash_file "$WORKER")" \
    --arg triggerPlan "$(hash_file "$TRIGGER_PLAN")" \
    --arg triggerReport "$(hash_file "$TRIGGER_REPORT")" \
    --arg selection "$(hash_file "$SELECTION")" \
    --arg selectionReport "$(hash_file "$SELECTION_REPORT")" \
    --arg whisperKitRun "$(hash_file "$WHISPERKIT_RUN")" \
    --arg referenceManifest "$(hash_file "$REFERENCE_MANIFEST")" \
    --arg runnerIncident "$(hash_file "$RUNNER_INCIDENT")" \
    --arg orchestratorIncident "$(hash_file "$ORCHESTRATOR_INCIDENT")" \
    --arg incidentState "$(hash_file "$INCIDENT_STATE")" \
    --arg incidentLog "$(hash_file "$INCIDENT_LOG")" \
    '{status:"READY_FOR_HEAVY_BENCHMARK",ticket:95,
      heavyCommandsLaunchedBeforeCheckpoint:2,completedHeavyRunsBeforeCheckpoint:0,
      userSlotGranted:false,incidentAcknowledgementRequired:true,
      command:$command,corpus:"qudu2fx3ncc",corpusRole:"development",
      holdoutOpened:false,runtimeReference:false,
      observedModelStarts:{qwen:0,parakeet:0,whisperKit:0,alignment:2,translation:2},
      retainedCompletedModelPasses:{qwen:0,parakeet:0,whisperKit:0,alignment:0,translation:0},
      plannedModelPasses:{qwen:0,parakeet:0,whisperKit:0,alignment:1,translation:1},
      reuse:{source:"frozen E28 + hash-verified E29 WhisperKit raw",
        whisperKitRunSHA256:$whisperKitRun},
      whisperKit:{windowCount:6,audioSeconds:27.96,rawReused:true},
      downstream:{condition:"Japanese gates passed",alignmentPasses:1,
        translationPasses:1,typicalMinutes:17,hardTimeoutMinutes:40,
        peakRAMGiB:11.1,incrementalDiskMiB:250},
      estimate:{freeDiskBytes:$freeDisk,totalRAMBytes:$totalRAM},
      gates:["frozen input/reference/model hashes","build, tests, runner probe",
        "raw trigger = disagreement AND independent Qwen weakness",
        "six targeted windows only","one complete hypothesis, no fusion",
        "block-calibrated selector, no bad override or critical loss",
        "Japanese comparison vs Qwen and #94","English comparison only after Japanese pass",
        "clean pressure, runaway, cancellation and worker lifecycle"],
      memory:{nativePressure:true,runawayGuard:true,cancellation:true,fixedReserveBytes:0},
      inputSHA256:{referenceManifest:$referenceManifest,whisperKitRun:$whisperKitRun,
        runnerIncident:$runnerIncident,orchestratorIncident:$orchestratorIncident,
        incidentState:$incidentState,incidentLog:$incidentLog,
        triggerPlan:$triggerPlan,triggerReport:$triggerReport,
        selection:$selection,selectionReport:$selectionReport},
      implementationSHA256:{harness:$harness,adaptiveHarness:$adaptive,runner:$runner,
        tests:$tests,job:$job,whisperKitRuntime:$runtime,workerSource:$workerSource,
        workerBinary:$binary,triggerPlan:$triggerPlan,triggerReport:$triggerReport}}' \
    >"$READY_EVIDENCE.tmp"
  mv "$READY_EVIDENCE.tmp" "$READY_EVIDENCE"
  cp "$TRIGGER_PLAN" "$EVIDENCE/retest-trigger-plan.json"
  cp "$TRIGGER_REPORT" "$EVIDENCE/retest-trigger-report.json"
  cp "$SELECTION" "$EVIDENCE/retest-selection.json"
  cp "$SELECTION_REPORT" "$EVIDENCE/retest-selection-report.json"
  restore_scratch
}

verify_ready() {
  jq -e '.status == "READY_FOR_HEAVY_BENCHMARK" and .ticket == 95
    and .heavyCommandsLaunchedBeforeCheckpoint == 2
    and .completedHeavyRunsBeforeCheckpoint == 0 and .holdoutOpened == false
    and .userSlotGranted == false and .incidentAcknowledgementRequired == true
    and .whisperKit.windowCount == 6 and .whisperKit.rawReused == true
    and .observedModelStarts == {qwen:0,parakeet:0,whisperKit:0,alignment:2,translation:2}
    and .retainedCompletedModelPasses == {qwen:0,parakeet:0,whisperKit:0,alignment:0,translation:0}
    and .plannedModelPasses == {qwen:0,parakeet:0,whisperKit:0,alignment:1,translation:1}
    and .memory.fixedReserveBytes == 0' "$READY" >/dev/null
  assert_hash Scripts/targeted_whisperkit_harness.py "$(jq -r .implementationSHA256.harness "$READY")"
  assert_hash Scripts/adaptive_asr_harness.py "$(jq -r .implementationSHA256.adaptiveHarness "$READY")"
  assert_hash Scripts/run_targeted_whisperkit_experiment.sh "$(jq -r .implementationSHA256.runner "$READY")"
  assert_hash Tests/AdaptiveASRExperimentTests.swift "$(jq -r .implementationSHA256.tests "$READY")"
  assert_hash Sources/HighQualityJob.swift "$(jq -r .implementationSHA256.job "$READY")"
  assert_hash Sources/WhisperKitRuntime.swift "$(jq -r .implementationSHA256.whisperKitRuntime "$READY")"
  assert_hash Sources/HighQualityASRWorker.swift "$(jq -r .implementationSHA256.workerSource "$READY")"
  assert_hash "$WORKER" "$(jq -r .implementationSHA256.workerBinary "$READY")"
  assert_hash "$TRIGGER_PLAN" "$(jq -r .implementationSHA256.triggerPlan "$READY")"
  assert_hash "$TRIGGER_REPORT" "$(jq -r .implementationSHA256.triggerReport "$READY")"
  assert_hash "$SELECTION" "$(jq -r .inputSHA256.selection "$READY")"
  assert_hash "$SELECTION_REPORT" "$(jq -r .inputSHA256.selectionReport "$READY")"
  assert_hash "$WHISPERKIT_RUN" "$(jq -r .inputSHA256.whisperKitRun "$READY")"
  assert_hash "$REFERENCE_MANIFEST" "$(jq -r .inputSHA256.referenceManifest "$READY")"
  assert_hash "$RUNNER_INCIDENT" "$(jq -r .inputSHA256.runnerIncident "$READY")"
  assert_hash "$ORCHESTRATOR_INCIDENT" "$(jq -r .inputSHA256.orchestratorIncident "$READY")"
  assert_hash "$INCIDENT_STATE" "$(jq -r .inputSHA256.incidentState "$READY")"
  assert_hash "$INCIDENT_LOG" "$(jq -r .inputSHA256.incidentLog "$READY")"
}

select_candidate() {
  python3 Scripts/targeted_whisperkit_harness.py select \
    --plan "$PLAN" --run "$ASR_RUN" --selection "$BASE_SELECTION" \
    --trigger-plan "$TRIGGER_PLAN" --trigger-report "$TRIGGER_REPORT" \
    --whisperkit-run "$WHISPERKIT_RUN" --reference-manifest "$REFERENCE_MANIFEST" \
    --character-alignment "$CHARACTERS" \
    --e23-segments "$E23" --output-selection "$SELECTION" \
    --output-report "$SELECTION_REPORT"
}

run_translation() {
  require_benchmark_slot
  [[ ! -e "$TRANSLATION_RUNTIME" && ! -e "$TRANSLATION_LOG" && ! -e "$CANDIDATE" ]] || {
    echo "downstream evidence already exists; refusing a second translation" >&2
    return 1
  }
  env WHISPERASR_RUN_ADAPTIVE_TRANSLATION_DEV=1 BENCHMARK_SLOT_GRANTED=95 \
    BENCHMARK_SLOT_CONFIRMED_BY_USER=95 \
    WHISPERASR_ADAPTIVE_AUDIO="$PCM" \
    WHISPERASR_ADAPTIVE_SELECTION="$SELECTION" \
    WHISPERASR_ADAPTIVE_TRANSLATION_OUTPUT="$TRANSLATION_OUTPUT" \
    WHISPERASR_ADAPTIVE_TRANSLATION_JOB_ID="$JOB_ID" \
    WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
    python3 Scripts/qwen_voice_music_harness.py run-command --timeout 2400 \
      --log "$TRANSLATION_LOG" --runtime "$TRANSLATION_RUNTIME" -- \
      xcrun swift test --disable-sandbox --skip-build \
        --filter AdaptiveASRExperimentTests/testSingleDownstreamTranslationWhenOptedIn
}

report() {
  local args=(
    Scripts/targeted_whisperkit_harness.py report
    --trigger-report "$TRIGGER_REPORT" --selection "$SELECTION"
    --selection-report "$SELECTION_REPORT" --whisperkit-run "$WHISPERKIT_RUN"
    --whisperkit-runtime "$WHISPERKIT_RUNTIME"
    --issue94-completion "$ISSUE94_COMPLETION" --issue94-report "$ISSUE94_REPORT"
    --output "$FINAL_REPORT" --markdown "$REPORT_MD"
  )
  local downstream_present=0 path
  for path in "$CANDIDATE/raw-asr.json" "$CANDIDATE/manifest.json" \
    "$TRANSLATION_RUNTIME"; do
    [[ ! -f "$path" ]] || downstream_present=$((downstream_present + 1))
  done
  if (( downstream_present == 3 )); then
    args+=(--baseline-raw "$BASELINE_RAW" --reference-manifest "$REFERENCE_MANIFEST"
      --candidate-raw "$CANDIDATE/raw-asr.json"
      --candidate-manifest "$CANDIDATE/manifest.json"
      --translation-runtime "$TRANSLATION_RUNTIME")
  elif (( downstream_present != 0 )); then
    echo "partial #95 English evidence is not reportable" >&2
    return 1
  fi
  python3 "${args[@]}"
}

write_evidence_ledger() {
  (cd "$EVIDENCE"
    for evidence_file in *; do
      [[ "$evidence_file" == sha256.tsv ]] || shasum -a 256 "$evidence_file"
    done | sort
  ) >"$EVIDENCE/sha256.tsv"
}

retain_failed_downstream() {
  cp "$STATE" "$EVIDENCE/retest-failed-downstream-state.json"
  [[ ! -f "$TRANSLATION_RUNTIME" ]] || \
    cp "$TRANSLATION_RUNTIME" "$EVIDENCE/retest-failed-downstream-runtime.json"
  [[ ! -f "$TRANSLATION_LOG" ]] || gzip -n -c "$TRANSLATION_LOG" \
    >"$EVIDENCE/retest-failed-downstream.log.gz"
  [[ ! -f "$CANDIDATE/manifest.json" ]] || \
    cp "$CANDIDATE/manifest.json" "$EVIDENCE/retest-failed-downstream-manifest.json"
  [[ ! -f "$CANDIDATE/raw-asr.json" ]] || gzip -n -c "$CANDIDATE/raw-asr.json" \
    >"$EVIDENCE/retest-failed-downstream-raw-asr.json.gz"
  write_evidence_ledger
}

failed_downstream_status() {
  if [[ -f "$TRANSLATION_RUNTIME" ]] \
    && jq -e '.timedOut == true' "$TRANSLATION_RUNTIME" >/dev/null; then
    echo NO_GO_RESOURCE
  elif [[ -f "$TRANSLATION_LOG" ]] \
    && grep -Eqi 'critical memory pressure|runaway|out of memory|resource exhausted' \
      "$TRANSLATION_LOG"; then
    echo NO_GO_RESOURCE
  elif [[ -f "$CANDIDATE/manifest.json" ]] \
    && jq -e '.. | objects | select(.level? == "critical")' \
      "$CANDIDATE/manifest.json" >/dev/null; then
    echo NO_GO_RESOURCE
  else
    echo FAILED_DOWNSTREAM_NO_RERUN
  fi
}

interrupt_downstream() {
  jq '.status="INTERRUPTED_DOWNSTREAM_NO_RERUN" | .benchmarkSlotReleased=true' \
    "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  retain_failed_downstream
  exit 143
}

retain_evidence() {
  cp "$SELECTION" "$EVIDENCE/retest-selection.json"
  cp "$SELECTION_REPORT" "$EVIDENCE/retest-selection-report.json"
  cp "$TRANSLATION_RUNTIME" "$EVIDENCE/retest-translation-runtime.json"
  cp "$CANDIDATE/manifest.json" "$EVIDENCE/retest-manifest.json"
  gzip -n -c "$CANDIDATE/raw-asr.json" >"$EVIDENCE/retest-candidate-raw-asr.json.gz"
  gzip -n -c "$TRANSLATION_LOG" >"$EVIDENCE/retest-translation.log.gz"
}

complete_evidence() {
  retain_evidence
  jq '.status="completed"' "$STATE" >"$STATE.tmp"
  cp "$STATE.tmp" "$EVIDENCE/retest-heavy-run-state.json"
  write_evidence_ledger
  mv "$STATE.tmp" "$STATE"
}

case "$MODE" in
  self-test)
    if BENCHMARK_SLOT_GRANTED= BENCHMARK_SLOT_CONFIRMED_BY_USER= \
      require_benchmark_slot 2>/dev/null; then
      echo "missing slot was accepted" >&2
      exit 1
    fi
    if BENCHMARK_SLOT_GRANTED=95 BENCHMARK_SLOT_CONFIRMED_BY_USER= \
      require_benchmark_slot 2>/dev/null; then
      echo "missing explicit user confirmation was accepted" >&2
      exit 1
    fi
    BENCHMARK_SLOT_GRANTED=95 BENCHMARK_SLOT_CONFIRMED_BY_USER=95 \
      require_benchmark_slot
    echo "run_targeted_whisperkit_experiment slot self-test: PASS"
    ;;
  preflight)
    if [[ -e "$STATE" ]]; then
      [[ "$(jq -r '.status // empty' "$STATE")" == completed ]] || {
        echo "incomplete benchmark state exists: $(jq -r '.status // "unknown"' "$STATE")" >&2
        exit 2
      }
      echo "EXPERIMENT_COMPLETED: see docs/japanese-live/experiments/E29-targeted-whisperkit.md"
      exit 0
    fi
    verify_inputs
    prepare_light_evidence
    if ! jq -e '.developmentEligibleJapanese == true' "$SELECTION" >/dev/null; then
      report
      cp "$TRIGGER_PLAN" "$EVIDENCE/retest-trigger-plan.json"
      cp "$TRIGGER_REPORT" "$EVIDENCE/retest-trigger-report.json"
      cp "$SELECTION" "$EVIDENCE/retest-selection.json"
      cp "$SELECTION_REPORT" "$EVIDENCE/retest-selection-report.json"
      echo "NO_GO_TARGETED_WHISPERKIT_JAPANESE"
      exit 0
    fi
    if ! jq -e '.heavyRunJustified == true' "$TRIGGER_REPORT" >/dev/null; then
      cp "$TRIGGER_PLAN" "$EVIDENCE/retest-trigger-plan.json"
      cp "$TRIGGER_REPORT" "$EVIDENCE/retest-trigger-report.json"
      echo "NO_RUN_REFERENCE_HARNESS: triggered windows lack complete DEV reference coverage"
      exit 0
    fi
    verify_models
    build_and_probe
    write_ready
    echo "READY_FOR_HEAVY_BENCHMARK"
    echo "Await explicit user acknowledgement of the two interrupted pre-slot attempts."
    echo "BENCHMARK_SLOT_GRANTED=95 BENCHMARK_SLOT_CONFIRMED_BY_USER=95 bash Scripts/run_targeted_whisperkit_experiment.sh development"
    ;;
  verify-ready)
    verify_inputs
    verify_models
    restore_scratch
    verify_ready
    echo "READY verified; no heavy model launched."
    ;;
  development)
    require_benchmark_slot
    verify_inputs
    verify_models
    restore_scratch
    verify_ready
    [[ ! -e "$STATE" && ! -e "$TRANSLATION_RUNTIME" && ! -e "$CANDIDATE" ]] || {
      echo "downstream evidence already exists; refusing a second benchmark" >&2; exit 2;
    }
    jq -n '{ticket:95,status:"downstream-running",heavyRunsLaunched:1,
      modelPassesCompleted:{qwen:0,parakeet:0,whisperKit:0,alignment:0,translation:0},
      plannedModelPasses:{qwen:0,parakeet:0,whisperKit:0,alignment:1,translation:1},
      reusedWhisperKitRaw:true,holdoutOpened:false}' >"$STATE"
    trap interrupt_downstream INT TERM
    if ! run_translation; then
      trap - INT TERM
      failure_status="$(failed_downstream_status)"
      jq --arg status "$failure_status" \
        '.status=$status | .benchmarkSlotReleased=true' \
        "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      retain_failed_downstream
      echo "$failure_status" >&2
      exit 1
    fi
    trap - INT TERM
    jq '.status="downstream-completed-report-running"
      | .modelPassesCompleted.alignment=1 | .modelPassesCompleted.translation=1
      | .benchmarkSlotReleased=true' \
      "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    if ! report; then
      jq '.status="FAILED_REPORT_NO_RERUN"' \
        "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      retain_failed_downstream
      exit 1
    fi
    complete_evidence
    ;;
  report)
    [[ "$(jq -r '.status // empty' "$STATE")" == downstream-completed-report-running
      && "$(jq -r .benchmarkSlotReleased "$STATE")" == true
      && -f "$CANDIDATE/raw-asr.json" && -f "$CANDIDATE/manifest.json"
      && -f "$TRANSLATION_RUNTIME" && -f "$TRANSLATION_LOG" ]]
    report
    complete_evidence
    ;;
esac
