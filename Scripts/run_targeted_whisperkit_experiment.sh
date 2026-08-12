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
ARTIFACTS="$ROOT/.build/benchmarks/issue-95"
DEV="$ARTIFACTS/development"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E29"
E28="$ROOT/docs/japanese-live/experiments/evidence/E28"
FROZEN="/Users/maz/Documents/projets/whisperASR"
PCM="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/audio-16k-mono.wav"
CHARACTERS="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/character-alignment.jsonl"
E23="$ROOT/docs/japanese-live/experiments/evidence/E23/segments.json"
PLAN="$E28/window-plan.json"
ASR_RUN="$E28/asr-run.json"
BASE_SELECTION="$E28/selection.json"
ISSUE94_COMPLETION="$E28/targeted-translation-completion.json"
ISSUE94_REPORT="$E28/report.json"
MODEL_ROOT="/Users/maz/Library/Application Support/WhisperASR/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3"
WORKER="$ROOT/.build/debug/WhisperASR"
TRIGGER_PLAN="$ARTIFACTS/trigger-plan.json"
TRIGGER_REPORT="$ARTIFACTS/trigger-report.json"
READY="$ARTIFACTS/READY_FOR_HEAVY_BENCHMARK.json"
STATE="$ARTIFACTS/heavy-run-state.json"
WHISPERKIT_RUN="$DEV/whisperkit-run.json"
WHISPERKIT_RUNTIME="$DEV/whisperkit-runtime.json"
WHISPERKIT_LOG="$DEV/whisperkit.log"
SELECTION="$DEV/selection.json"
SELECTION_REPORT="$DEV/selection-report.json"
FINAL_REPORT="$EVIDENCE/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E29-targeted-whisperkit.md"

case "$MODE" in preflight|verify-ready|development|report) ;;
  *) echo "usage: $0 [preflight|verify-ready|development|report]" >&2; exit 2 ;;
esac

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

verify_inputs() {
  [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]
  command -v jq python3 shasum xcrun >/dev/null
  git merge-base --is-ancestor "$BASE_COMMIT" HEAD
  assert_hash "$PCM" 494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2
  assert_hash "$CHARACTERS" abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7
  assert_hash "$E23" e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81
  assert_hash "$PLAN" 3bfa62a1e0ded143555c61f8a02e65501b8b72adf2dfa277527c2d8de4c4b1a8
  assert_hash "$ASR_RUN" c4ff5fa759801301806aaccf1fc3081b9522d5902518422c64ca875475eabc52
  assert_hash "$BASE_SELECTION" 4279b6e2a187f5c8c0695b79c085af8c42b0e8fc294fdc0c0e07fffec4521a2f
  assert_hash "$ISSUE94_COMPLETION" 1fa151af988750734445e708452e7cde17c3f57d2864fc266702bfd541d244a7
  assert_hash "$ISSUE94_REPORT" 25d38a79db2673a9baac37be0d376a70cfe0abbb74d8c35f4729696f248a4fee
}

verify_models() {
  assert_hash "$MODEL_ROOT/AudioEncoder.mlmodelc/weights/weight.bin" \
    eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457
  assert_hash "$MODEL_ROOT/MelSpectrogram.mlmodelc/weights/weight.bin" \
    97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87
  assert_hash "$MODEL_ROOT/TextDecoder.mlmodelc/weights/weight.bin" \
    680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55
}

build_and_probe() {
  mkdir -p "$ARTIFACTS/controls"
  xcrun swift build --disable-sandbox 2>&1 | tee "$ARTIFACTS/controls/build.log"
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
    --character-alignment "$CHARACTERS" --e23-segments "$E23" \
    --trigger-plan "$TRIGGER_PLAN" --report "$TRIGGER_REPORT"
  jq -e '.holdoutOpened == false and .heavyRunJustified == false
    and .triggerCount == 6 and .triggeredSeconds == 27.96
    and .calibration.threshold == 0.25
    and .referenceEvaluability.completeForEveryTriggeredWindow == false' \
    "$TRIGGER_REPORT" >/dev/null
  jq -e '.ticket == 95 and .holdoutOpened == false and (.windows | length) == 6
    and .rule.requiresBothSignals == true' "$TRIGGER_PLAN" >/dev/null
  ! grep -qi reference "$TRIGGER_PLAN"
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
    --arg command 'BENCHMARK_SLOT_GRANTED=95 bash Scripts/run_targeted_whisperkit_experiment.sh development' \
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
    '{status:"READY_FOR_HEAVY_BENCHMARK",ticket:95,heavyRunsLaunched:0,
      command:$command,corpus:"qudu2fx3ncc",corpusRole:"development",
      holdoutOpened:false,runtimeReference:false,
      reuse:{qwenPasses:0,parakeetPasses:0,alignmentPassesBeforeJapaneseGate:0,
        translationPassesBeforeJapaneseGate:0,source:"frozen E28 checkpoints"},
      whisperKit:{windowCount:6,audioSeconds:27.96,modelAlreadyLocalGiB:2.9,
        typicalMinutes:2,hardTimeoutMinutes:10,peakRAMGiB:3,incrementalDiskMiB:20},
      conditionalDownstream:{condition:"Japanese gates pass",
        separateAuthorizationRequired:true,launchedByDevelopmentCommand:false,alignmentPasses:1,
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
      implementationSHA256:{harness:$harness,adaptiveHarness:$adaptive,runner:$runner,
        tests:$tests,job:$job,whisperKitRuntime:$runtime,workerSource:$workerSource,
        workerBinary:$binary,triggerPlan:$triggerPlan,triggerReport:$triggerReport}}' >"$READY"
  cp "$READY" "$TRIGGER_PLAN" "$TRIGGER_REPORT" "$EVIDENCE/"
}

verify_ready() {
  jq -e '.status == "READY_FOR_HEAVY_BENCHMARK" and .ticket == 95
    and .heavyRunsLaunched == 0 and .holdoutOpened == false
    and .whisperKit.windowCount == 6 and .memory.fixedReserveBytes == 0' "$READY" >/dev/null
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
}

run_whisperkit() {
  env WHISPERASR_RUN_TARGETED_WHISPERKIT_DEV=1 BENCHMARK_SLOT_GRANTED=95 \
    WHISPERASR_TARGETED_WHISPERKIT_AUDIO="$PCM" \
    WHISPERASR_TARGETED_WHISPERKIT_PLAN="$TRIGGER_PLAN" \
    WHISPERASR_TARGETED_WHISPERKIT_OUTPUT="$WHISPERKIT_RUN" \
    WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
    python3 Scripts/qwen_voice_music_harness.py run-command --timeout 600 \
      --log "$WHISPERKIT_LOG" --runtime "$WHISPERKIT_RUNTIME" -- \
      xcrun swift test --disable-sandbox --skip-build \
        --filter AdaptiveASRExperimentTests/testTargetedWhisperKitASRWhenOptedIn
}

select_candidate() {
  python3 Scripts/targeted_whisperkit_harness.py select \
    --plan "$PLAN" --run "$ASR_RUN" --selection "$BASE_SELECTION" \
    --trigger-plan "$TRIGGER_PLAN" --trigger-report "$TRIGGER_REPORT" \
    --whisperkit-run "$WHISPERKIT_RUN" --character-alignment "$CHARACTERS" \
    --e23-segments "$E23" --output-selection "$SELECTION" \
    --output-report "$SELECTION_REPORT"
}

report() {
  python3 Scripts/targeted_whisperkit_harness.py report \
    --trigger-report "$TRIGGER_REPORT" --selection "$SELECTION" \
    --selection-report "$SELECTION_REPORT" --whisperkit-run "$WHISPERKIT_RUN" \
    --whisperkit-runtime "$WHISPERKIT_RUNTIME" \
    --issue94-completion "$ISSUE94_COMPLETION" --issue94-report "$ISSUE94_REPORT" \
    --output "$FINAL_REPORT" --markdown "$REPORT_MD"
}

retain_evidence() {
  cp "$WHISPERKIT_RUN" "$WHISPERKIT_RUNTIME" "$SELECTION" "$SELECTION_REPORT" "$EVIDENCE/"
  gzip -c "$WHISPERKIT_LOG" >"$EVIDENCE/whisperkit.log.gz"
  (cd "$EVIDENCE"
    for evidence_file in *; do
      [[ "$evidence_file" == sha256.tsv ]] || shasum -a 256 "$evidence_file"
    done | sort
  ) >"$EVIDENCE/sha256.tsv"
}

case "$MODE" in
  preflight)
    if [[ -e "$STATE" ]]; then
      echo "EXPERIMENT_COMPLETED: see docs/japanese-live/experiments/E29-targeted-whisperkit.md"
      exit 0
    fi
    verify_inputs
    prepare_light_evidence
    if ! jq -e '.heavyRunJustified == true' "$TRIGGER_REPORT" >/dev/null; then
      cp "$TRIGGER_PLAN" "$TRIGGER_REPORT" "$EVIDENCE/"
      echo "NO_RUN_REFERENCE_HARNESS: triggered windows lack complete DEV reference coverage"
      exit 0
    fi
    verify_models
    build_and_probe
    write_ready
    echo "READY_FOR_HEAVY_BENCHMARK"
    echo "BENCHMARK_SLOT_GRANTED=95 bash Scripts/run_targeted_whisperkit_experiment.sh development"
    ;;
  verify-ready)
    verify_inputs
    verify_models
    verify_ready
    echo "READY verified; no heavy model launched."
    ;;
  development)
    [[ "${BENCHMARK_SLOT_GRANTED:-}" == 95 ]] || { echo "benchmark slot #95 required" >&2; exit 2; }
    verify_inputs
    verify_models
    verify_ready
    [[ ! -e "$STATE" && ! -e "$WHISPERKIT_RUN" ]] || {
      echo "heavy run evidence already exists; refusing a second benchmark" >&2; exit 2;
    }
    jq -n '{ticket:95,status:"running",heavyRunsLaunched:1,holdoutOpened:false}' >"$STATE"
    if ! run_whisperkit; then
      jq '.status="failed-whisperkit-no-rerun"' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      exit 1
    fi
    jq '.status="whisperkit-completed-analysis-running"
      | .benchmarkSlotReleased=true' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    select_candidate
    jq '.status="completed"' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    report
    cp "$STATE" "$EVIDENCE/"
    retain_evidence
    ;;
  report)
    [[ "$(jq -r .benchmarkSlotReleased "$STATE")" == true ]]
    report
    if jq -e '.developmentEligibleJapanese == false' "$SELECTION" >/dev/null; then
      jq '.status="completed"' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    fi
    cp "$STATE" "$EVIDENCE/"
    retain_evidence
    ;;
esac
