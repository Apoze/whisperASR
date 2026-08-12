#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

MODE="${1:-preflight}"
BASE_COMMIT=a3112025b39bdf153695ccdc842191212fe3e738
ARTIFACTS="$ROOT/.build/benchmarks/issue-94"
DEV="$ARTIFACTS/development"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E28"
SOURCE="/Users/maz/Documents/videos/jap/1/Video1.webm"
ARCHIVE="/Users/maz/Documents/videos/jap/1/Video1_reference_transcript_and_translation.zip"
FROZEN="/Users/maz/Documents/projets/whisperASR"
PCM="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/audio-16k-mono.wav"
CHARACTERS="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/character-alignment.jsonl"
REFERENCE_CSV="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/reference.csv"
SPEAKER_MAP="$FROZEN/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/speaker-map.json"
MANIFEST="$ROOT/docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
E23="$ROOT/docs/japanese-live/experiments/evidence/E23/segments.json"
BASELINE_RAW="$ROOT/docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz"
BASELINE_ROOT="$FROZEN/.build/benchmarks/high-quality/offline-acceptance"
QWEN_JOB="$BASELINE_ROOT/qwen-ja/qudu2fx3ncc/jobs/44000001-0000-4000-8000-000000000001"
PARAKEET_JOB="$BASELINE_ROOT/parakeet-ja/qudu2fx3ncc/jobs/44000001-0000-4000-8000-000000000002"
QWEN_WEIGHT="/Users/maz/Library/Caches/qwen3-speech/models/ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit/model.safetensors"
PARAKEET_ROOT="/Users/maz/Library/Application Support/FluidAudio/Models/parakeet-ja"
ALIGNER_WEIGHT="/Users/maz/.cache/huggingface/hub/models--mlx-community--Qwen3-ForcedAligner-0.6B-4bit/snapshots/2f652af86ae0c73fe189b9429225c908ce4bf020/model.safetensors"
TRANSLATOR_ROOT="/Users/maz/.cache/huggingface/hub/models--mlx-community--translategemma-12b-it-4bit/snapshots/f3dcfd54df14672fbcf0731086fb47a797a943ae"
WORKER="$ROOT/.build/debug/WhisperASR"
PLAN="$ARTIFACTS/window-plan.json"
REUSE="$ARTIFACTS/reuse-diagnostic.json"
READY="$ARTIFACTS/READY_FOR_HEAVY_BENCHMARK.json"
STATE="$ARTIFACTS/heavy-run-state.json"
ASR_RUN="$DEV/asr-run.json"
SELECTION="$DEV/selection.json"
SELECTION_REPORT="$DEV/selection-report.json"
ASR_RUNTIME="$DEV/asr-runtime.json"
TRANSLATION_RUNTIME="$DEV/translation-runtime.json"
TRANSLATION_LOG="$DEV/translation.log"
TRANSLATION_OUTPUT="$DEV/translation"
JOB_ID=94000001-0000-4000-8000-000000000001
CANDIDATE="$TRANSLATION_OUTPUT/$JOB_ID"
FIXED_READY="$ARTIFACTS/READY_FOR_FIXED_DOWNSTREAM_REPLAY.json"
FINAL_REPORT="$EVIDENCE/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E28-adaptive-asr-qwen-parakeet.md"

case "$MODE" in preflight|development|resume|report|downstream-ready|verify-resume|fixed-downstream-ready|fixed-downstream-replay|verify-fixed-downstream-replay) ;;
  *) echo "usage: $0 [preflight|development|resume|report|downstream-ready|verify-resume|fixed-downstream-ready|fixed-downstream-replay|verify-fixed-downstream-replay]" >&2; exit 2 ;;
esac
if [[ "$MODE" == fixed-downstream-replay ]]; then
  TRANSLATION_RUNTIME="$DEV/fixed-translation-runtime.json"
  TRANSLATION_LOG="$DEV/fixed-translation.log"
  TRANSLATION_OUTPUT="$DEV/fixed-translation"
  JOB_ID=94000002-0000-4000-8000-000000000001
  CANDIDATE="$TRANSLATION_OUTPUT/$JOB_ID"
fi

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
  assert_hash "$SOURCE" b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1
  assert_hash "$ARCHIVE" 8f1c4ed3836d5e0f627448f9ecc44ab064d8750cb4464c8849eafabbba401474
  assert_hash "$PCM" 494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2
  assert_hash "$CHARACTERS" abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7
  assert_hash "$REFERENCE_CSV" df0bce85845cca243e0ed4ae3c5b885e519cc4f0aada9c6ddb1b169cb22f93ba
  assert_hash "$SPEAKER_MAP" 4e1326ac13fab5c76b07451600e6553c65e824b278a1b4c4ce7192e77a73497b
  assert_hash "$MANIFEST" a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b
  assert_hash "$E23" e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81
  assert_hash "$BASELINE_RAW" 1f5edc2fcb929c9abc2cb85256f326bbf2891a200ef66d1c1cb9a66a9c711ce8
  assert_hash "$QWEN_JOB/raw-asr.json" b7281fdd3226930a4dc59758eb5e192642747ad6f9d18d942b850288ad42a394
  assert_hash "$QWEN_JOB/manifest.json" 3f31b861f8a59ab5fbed35561d58c8921ce2d4c7a46f5a222a6ad4548109275a
  assert_hash "$PARAKEET_JOB/raw-asr.json" 2ab8678481b4ad22a08c015a2332c25e85309e0e327158e127a3bd3351611c6d
  assert_hash "$PARAKEET_JOB/manifest.json" 13d517d82f1fe704196bce102817282e0a929ec5b7c0eb93e635774c8232d7fa
  git merge-base --is-ancestor "$BASE_COMMIT" HEAD
  [[ "$MODE" == fixed-downstream-ready || "$MODE" == fixed-downstream-replay \
    || "$MODE" == verify-fixed-downstream-replay \
    || -z "$({ git diff --name-only "$BASE_COMMIT" -- Sources; \
    git ls-files --others --exclude-standard -- Sources; } | sort -u)" ]] || {
      echo "issue #94 must not change product Sources" >&2; return 1;
    }
}

verify_models() {
  assert_hash "$QWEN_WEIGHT" bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954
  assert_hash "$PARAKEET_ROOT/Encoder.mlmodelc/weights/weight.bin" 257685d3fdb578c5d6d7f0a5460c778f6104bcf2f264e4ae704b885c69ad6dda
  assert_hash "$PARAKEET_ROOT/Jointerv2.mlmodelc/weights/weight.bin" d6f24519c7c6959e8ec6fb078e8c05d912d292fcb57720c63fdc9291b1db122d
  assert_hash "$PARAKEET_ROOT/Preprocessor.mlmodelc/weights/weight.bin" 6512ba5d1acc3ffe6f322089c0ece5466f93c7ac77c267dd851a1fb517c637f9
  assert_hash "$PARAKEET_ROOT/Decoderv2.mlmodelc/weights/weight.bin" a56d792edf3b88e30466c0b992bb7e316fa743c90f8809c2be9d2ecb8ffbd48e
  assert_hash "$ALIGNER_WEIGHT" 630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c
  assert_hash "$TRANSLATOR_ROOT/model-00001-of-00002.safetensors" bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af
  assert_hash "$TRANSLATOR_ROOT/model-00002-of-00002.safetensors" c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89
}

build_and_probe() {
  mkdir -p "$ARTIFACTS/controls"
  xcrun swift build 2>&1 | tee "$ARTIFACTS/controls/build.log"
  xcrun swift test --filter \
    'AdaptiveASRExperimentTests|HighQualityASRWorkerTests/testEveryBackendRoundTripsOneTranscriptAndExits|HighQualityASRWorkerTests/testMalformedOutputFailsAndWorkerTerminates|HighQualityASRWorkerTests/testPreparationFailureTerminatesWithDiagnostics' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  [[ -f "$ROOT/.build/debug/mlx.metallib" ]] || bash Scripts/build_mlx_metallib.sh debug \
    2>&1 | tee "$ARTIFACTS/controls/mlx-metallib.log"
  [[ -x "$WORKER" ]]
  python3 Scripts/qwen_voice_music_harness.py run-command --timeout 5 \
    --log "$ARTIFACTS/controls/worker-probe.log" \
    --runtime "$ARTIFACTS/controls/worker-probe-runtime.json" -- \
    "$WORKER" --high-quality-asr-worker --probe
  grep -Fxq WHISPERASR_HIGH_QUALITY_ASR_WORKER_PROBE_OK \
    "$ARTIFACTS/controls/worker-probe.log"
}

prepare_light_evidence() {
  python3 Scripts/adaptive_asr_harness.py self-test
  python3 Scripts/adaptive_asr_harness.py plan --audio "$PCM" --output "$PLAN"
  python3 Scripts/adaptive_asr_harness.py diagnose-reuse \
    --qwen-raw "$QWEN_JOB/raw-asr.json" --qwen-manifest "$QWEN_JOB/manifest.json" \
    --parakeet-raw "$PARAKEET_JOB/raw-asr.json" \
    --parakeet-manifest "$PARAKEET_JOB/manifest.json" --output "$REUSE"
  jq -e '.holdoutOpened == false and (.windows | length) == 169
    and ([.windows[].durationSeconds] | max) <= 8' "$PLAN" >/dev/null
  ! grep -qi reference "$PLAN"
}

write_ready() {
  local free_disk total_ram
  free_disk="$(df -k "$ROOT" | awk 'NR==2 {printf "%.0f", $4 * 1024}')"
  total_ram="$(sysctl -n hw.memsize)"
  (( free_disk >= 20 * 1024 * 1024 * 1024 ))
  jq -n \
    --arg command 'BENCHMARK_SLOT_GRANTED=94 bash Scripts/run_adaptive_asr_experiment.sh development' \
    --arg resume 'BENCHMARK_SLOT_GRANTED=94 bash Scripts/run_adaptive_asr_experiment.sh resume' \
    --argjson freeDisk "$free_disk" --argjson totalRAM "$total_ram" \
    --arg harness "$(hash_file Scripts/adaptive_asr_harness.py)" \
    --arg runner "$(hash_file Scripts/run_adaptive_asr_experiment.sh)" \
    --arg tests "$(hash_file Tests/AdaptiveASRExperimentTests.swift)" \
    --arg binary "$(hash_file "$WORKER")" --arg plan "$(hash_file "$PLAN")" \
    '{status:"READY_FOR_HEAVY_BENCHMARK",ticket:94,heavyRunsLaunched:0,
      command:$command,resumeCommand:$resume,corpus:"qudu2fx3ncc",corpusRole:"development",
      holdoutOpened:false,recipe:{qwen:"standard-ja",spleeter:false,fireRed:false,
        hotwords:false,runtimeReference:false},
      windows:{count:169,minimumSeconds:3.02,maximumSeconds:8.0,
        commonAcousticTimeline:true},
      passes:["Qwen: 169 windows, one persistent worker",
        "Parakeet: same 169 windows, one persistent worker",
        "If Japanese gates pass: forced alignment",
        "If Japanese gates pass: one TranslateGemma translation"],
      estimate:{typicalMinutes:25,hardTimeoutMinutes:60,peakRAMGiB:14,
        incrementalDiskMiB:250,freeDiskBytes:$freeDisk,totalRAMBytes:$totalRAM},
      gates:["build and worker probe","frozen input/reference/model hashes",
        "short complete timeline","strict sequential lifecycle","stable LOBO calibration",
        "no added empty/duplicate/term-number-meaning loss","Japanese gain >=2%",
        "ASR cost <=5x Qwen","English not worse"],
      recovery:"Resume retained completed phases only; never rerun a failed heavy phase.",
      implementationSHA256:{"Scripts/adaptive_asr_harness.py":$harness,
        "Scripts/run_adaptive_asr_experiment.sh":$runner,
        "Tests/AdaptiveASRExperimentTests.swift":$tests,
        ".build/debug/WhisperASR":$binary,".build/benchmarks/issue-94/window-plan.json":$plan}}' \
    >"$READY"
}

verify_ready() {
  jq -e '.status == "READY_FOR_HEAVY_BENCHMARK" and .heavyRunsLaunched == 0
    and .holdoutOpened == false and .recipe.runtimeReference == false' "$READY" >/dev/null
  while IFS=$'\t' read -r path expected; do assert_hash "$ROOT/$path" "$expected"; done \
    < <(jq -r '.implementationSHA256 | to_entries[] | [.key,.value] | @tsv' "$READY")
}

verify_downstream_ready() {
  local ready="$ARTIFACTS/READY_FOR_DOWNSTREAM_RESUME.json"
  jq -e '.status == "READY_FOR_DOWNSTREAM_RESUME" and .ticket == 94
    and .holdoutOpened == false and .rerunASR == false' "$ready" >/dev/null
  while IFS=$'\t' read -r path expected; do assert_hash "$DEV/$path" "$expected"; done \
    < <(jq -r '.reuseSHA256 | to_entries[] | [.key,.value] | @tsv' "$ready")
  jq -e '.developmentEligibleJapanese == true and .holdoutOpened == false' \
    "$SELECTION" >/dev/null
}

verify_fixed_downstream_ready() {
  jq -e '.status == "READY_FOR_FIXED_DOWNSTREAM_REPLAY" and .ticket == 94
    and .holdoutOpened == false and .modelPasses.asr == 0
    and .modelPasses.alignment == 1 and .modelPasses.translation == 1' \
    "$FIXED_READY" >/dev/null
  assert_hash "$ARTIFACTS/READY_FOR_DOWNSTREAM_RESUME.json" \
    "$(jq -r .checkpointSHA256 "$FIXED_READY")"
  while IFS=$'\t' read -r path expected; do assert_hash "$DEV/$path" "$expected"; done \
    < <(jq -r '.reuseSHA256 | to_entries[] | [.key,.value] | @tsv' "$FIXED_READY")
  while IFS=$'\t' read -r path expected; do assert_hash "$ROOT/$path" "$expected"; done \
    < <(jq -r '.implementationSHA256 | to_entries[] | [.key,.value] | @tsv' "$FIXED_READY")
  while IFS=$'\t' read -r path expected; do assert_hash "$ROOT/$path" "$expected"; done \
    < <(jq -r '.diagnosticReplaySHA256 | to_entries[] | [.key,.value] | @tsv' "$FIXED_READY")
  while IFS=$'\t' read -r path expected; do assert_hash "$ROOT/$path" "$expected"; done \
    < <(jq -r '.pureReplaySHA256 | to_entries[] | [.key,.value] | @tsv' "$FIXED_READY")
  jq -e '.developmentEligibleJapanese == true and .holdoutOpened == false
    and .calibratedWeaknessMargin == 0.5
    and ([.windows[] | select(.selectedBackend == "qwen-ja")] | length) == 167
    and ([.windows[] | select(.selectedBackend == "parakeet-ja")] | length) == 2' \
    "$SELECTION" >/dev/null
}

set_phase() {
  local temporary="$STATE.tmp"
  jq --arg phase "$1" '.phase=$phase' "$STATE" >"$temporary"
  mv "$temporary" "$STATE"
}

run_asr() {
  [[ ! -e "$DEV/qwen-short-windows.json" && ! -e "$DEV/parakeet-short-windows.json" ]] || {
    echo "partial ASR evidence exists; the failed heavy phase will not be rerun" >&2; return 1;
  }
  set_phase asr-running
  WHISPERASR_RUN_ADAPTIVE_ASR_DEV=1 \
  WHISPERASR_ADAPTIVE_AUDIO="$PCM" WHISPERASR_ADAPTIVE_PLAN="$PLAN" \
  WHISPERASR_ADAPTIVE_ASR_OUTPUT="$ASR_RUN" \
  WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
    python3 Scripts/qwen_voice_music_harness.py run-command --timeout 1200 \
      --log "$DEV/asr.log" --runtime "$ASR_RUNTIME" -- \
      xcrun swift test --skip-build \
        --filter AdaptiveASRExperimentTests/testDevelopmentASRWhenOptedIn
  set_phase asr-completed
}

select_japanese() {
  python3 Scripts/adaptive_asr_harness.py select --plan "$PLAN" --run "$ASR_RUN" \
    --character-alignment "$CHARACTERS" --e23-segments "$E23" \
    --selection "$SELECTION" --report "$SELECTION_REPORT"
  set_phase selection-completed
}

run_translation() {
  [[ ! -e "$TRANSLATION_RUNTIME" && ! -e "$TRANSLATION_LOG" ]] || {
    echo "partial translation evidence exists; the failed heavy phase will not be rerun" >&2
    return 1
  }
  set_phase translation-running
  WHISPERASR_RUN_ADAPTIVE_TRANSLATION_DEV=1 \
  WHISPERASR_ADAPTIVE_AUDIO="$PCM" WHISPERASR_ADAPTIVE_SELECTION="$SELECTION" \
  WHISPERASR_ADAPTIVE_TRANSLATION_OUTPUT="$TRANSLATION_OUTPUT" \
  WHISPERASR_ADAPTIVE_TRANSLATION_JOB_ID="$JOB_ID" \
  WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
    python3 Scripts/qwen_voice_music_harness.py run-command --timeout 2400 \
      --log "$TRANSLATION_LOG" --runtime "$TRANSLATION_RUNTIME" -- \
      xcrun swift test --skip-build \
        --filter AdaptiveASRExperimentTests/testSingleDownstreamTranslationWhenOptedIn \
      || return $?
  set_phase translation-completed
}

make_report() {
  local arguments=(report --selection-report "$SELECTION_REPORT" --selection "$SELECTION"
    --run "$ASR_RUN" --reuse-diagnostic "$REUSE" --asr-runtime "$ASR_RUNTIME"
    --baseline-raw "$BASELINE_RAW" --manifest "$MANIFEST"
    --output "$FINAL_REPORT" --markdown "$REPORT_MD")
  if jq -e '.developmentEligibleJapanese == true' "$SELECTION" >/dev/null \
      && [[ -f "$CANDIDATE/manifest.json" ]]; then
    arguments+=(--candidate-raw "$CANDIDATE/raw-asr.json"
      --candidate-manifest "$CANDIDATE/manifest.json"
      --translation-runtime "$TRANSLATION_RUNTIME")
  fi
  mkdir -p "$EVIDENCE"
  python3 Scripts/adaptive_asr_harness.py "${arguments[@]}"
}

retain_evidence() {
  cp "$READY" "$PLAN" "$REUSE" "$ASR_RUN" "$SELECTION" "$SELECTION_REPORT" \
    "$ASR_RUNTIME" "$EVIDENCE/"
  cp "$DEV/qwen-short-windows.json" "$DEV/parakeet-short-windows.json" "$EVIDENCE/"
  gzip -c "$DEV/asr.log" >"$EVIDENCE/asr.log.gz"
  if [[ -f "$CANDIDATE/raw-asr.json" ]]; then
    gzip -c "$CANDIDATE/raw-asr.json" >"$EVIDENCE/candidate-raw-asr.json.gz"
    cp "$CANDIDATE/manifest.json" "$TRANSLATION_RUNTIME" "$EVIDENCE/"
    gzip -c "$DEV/translation.log" >"$EVIDENCE/translation.log.gz"
  fi
  write_evidence_ledger
}

write_downstream_ready() {
  local output="$ARTIFACTS/READY_FOR_DOWNSTREAM_RESUME.json"
  jq -n --arg command \
    'BENCHMARK_SLOT_GRANTED=94 bash Scripts/run_adaptive_asr_experiment.sh resume' \
    --arg asr "$(hash_file "$ASR_RUN")" --arg qwen "$(hash_file "$DEV/qwen-short-windows.json")" \
    --arg parakeet "$(hash_file "$DEV/parakeet-short-windows.json")" \
    --arg selection "$(hash_file "$SELECTION")" \
    '{status:"READY_FOR_DOWNSTREAM_RESUME",ticket:94,command:$command,
      holdoutOpened:false,rerunASR:false,
      reuseSHA256:{"asr-run.json":$asr,"qwen-short-windows.json":$qwen,
        "parakeet-short-windows.json":$parakeet,"selection.json":$selection},
      passes:["forced alignment on selected complete hypotheses",
        "one TranslateGemma translation"],strictlySequential:true}' >"$output"
  cp "$output" "$EVIDENCE/"
}

write_fixed_downstream_ready() {
  jq -n --arg command \
    'BENCHMARK_SLOT_GRANTED=94 bash Scripts/run_adaptive_asr_experiment.sh fixed-downstream-replay' \
    --arg checkpoint "$(hash_file "$ARTIFACTS/READY_FOR_DOWNSTREAM_RESUME.json")" \
    --arg asr "$(hash_file "$ASR_RUN")" \
    --arg qwen "$(hash_file "$DEV/qwen-short-windows.json")" \
    --arg parakeet "$(hash_file "$DEV/parakeet-short-windows.json")" \
    --arg selection "$(hash_file "$SELECTION")" \
    --arg aligner "$(hash_file Sources/HighQualityForcedAlignerRuntime.swift)" \
    --arg job "$(hash_file Sources/HighQualityJob.swift)" \
    --arg tests "$(hash_file Tests/HighQualityJobTests.swift)" \
    --arg runner "$(hash_file Scripts/run_adaptive_asr_experiment.sh)" \
    --arg binary "$(hash_file "$WORKER")" \
    --arg e27 "$(hash_file "$ROOT/docs/japanese-live/experiments/evidence/E27/corrected-resume-failure-raw-asr.json.gz")" \
    --arg e28 "$(hash_file "$EVIDENCE/candidate-raw-asr.json.gz")" \
    --arg replayE27 "$(hash_file "$EVIDENCE/fixed-replay-e27.log.gz")" \
    --arg replayE28 "$(hash_file "$EVIDENCE/fixed-replay-e28.log.gz")" \
    '{status:"READY_FOR_FIXED_DOWNSTREAM_REPLAY",ticket:94,command:$command,
      holdoutOpened:false,runtimeReference:false,rerunASR:false,
      selection:{fixedThreshold:0.5,qwen:167,parakeet:2},
      modelPasses:{asr:0,alignment:1,translation:1},strictlySequential:true,
      fix:{cueID:"cue-0295",text:"うん。",sourceAnchor:[950.62,957.2078125],
        rawPoint:957.18,policy:"single-zero-cue-asr-anchor-20cps",timingQuality:"coarse",
        preservesRawItems:true,validatorRelaxed:false},
      estimate:{alignmentSeconds:25,translationSeconds:950,totalMinutes:17,
        hardTimeoutMinutes:40,peakRAMGiB:10,incrementalDiskMiB:250,
        basis:"E28 alignment and E22 frozen TranslateGemma product run"},
      memory:{nativePressure:true,runawayGuard:true,cancellation:true,fixedReserveBytes:0},
      pureReplay:{modelsLoaded:0,e27:"fail-closed",e28:"cue-0295-valid"},
      pureReplaySHA256:{
        "docs/japanese-live/experiments/evidence/E28/fixed-replay-e27.log.gz":$replayE27,
        "docs/japanese-live/experiments/evidence/E28/fixed-replay-e28.log.gz":$replayE28},
      checkpointSHA256:$checkpoint,
      reuseSHA256:{"asr-run.json":$asr,"qwen-short-windows.json":$qwen,
        "parakeet-short-windows.json":$parakeet,"selection.json":$selection},
      diagnosticReplaySHA256:{
        "docs/japanese-live/experiments/evidence/E27/corrected-resume-failure-raw-asr.json.gz":$e27,
        "docs/japanese-live/experiments/evidence/E28/candidate-raw-asr.json.gz":$e28},
      implementationSHA256:{"Sources/HighQualityForcedAlignerRuntime.swift":$aligner,
        "Sources/HighQualityJob.swift":$job,"Tests/HighQualityJobTests.swift":$tests,
        "Scripts/run_adaptive_asr_experiment.sh":$runner,".build/debug/WhisperASR":$binary}}' \
    >"$FIXED_READY"
  cp "$FIXED_READY" "$EVIDENCE/"
  write_evidence_ledger
}

write_evidence_ledger() {
  : >"$EVIDENCE/sha256.tsv"
  for file in "$EVIDENCE"/*; do
    [[ "$file" == "$EVIDENCE/sha256.tsv" ]] || printf '%s\t%s\n' \
      "$(hash_file "$file")" "$(basename "$file")" >>"$EVIDENCE/sha256.tsv"
  done
}

retain_fixed_evidence() {
  cp "$FIXED_READY" "$EVIDENCE/"
  if [[ -f "$CANDIDATE/raw-asr.json" ]]; then
    gzip -c "$CANDIDATE/raw-asr.json" >"$EVIDENCE/fixed-candidate-raw-asr.json.gz"
  fi
  if [[ -f "$CANDIDATE/manifest.json" ]]; then
    cp "$CANDIDATE/manifest.json" "$EVIDENCE/fixed-manifest.json"
  fi
  if [[ -f "$TRANSLATION_RUNTIME" ]]; then
    cp "$TRANSLATION_RUNTIME" "$EVIDENCE/fixed-translation-runtime.json"
  fi
  if [[ -f "$TRANSLATION_LOG" ]]; then
    gzip -c "$TRANSLATION_LOG" >"$EVIDENCE/fixed-translation.log.gz"
  fi
  [[ ! -f "$DEV/fixed-downstream-failure.json" ]] || \
    cp "$DEV/fixed-downstream-failure.json" "$EVIDENCE/"
  write_evidence_ledger
}

record_fixed_downstream_failure() {
  local runtime manifest raw classification
  classification="${2:-}"
  runtime="$(jq -c . "$TRANSLATION_RUNTIME" 2>/dev/null || printf null)"
  manifest="$(jq -c . "$CANDIDATE/manifest.json" 2>/dev/null || printf null)"
  raw="$(jq -c '{failures,modelEvents,stageDurations,peakMemoryBytes,
    translationPresent:(.translation != null)}' "$CANDIDATE/raw-asr.json" \
    2>/dev/null || printf null)"
  jq -n --argjson commandStatus "$1" --arg classification "$classification" \
    --argjson runtime "$runtime" \
    --argjson manifest "$manifest" --argjson raw "$raw" \
    '{status:"failed",ticket:94,holdoutOpened:false,inputAndReferencePreflightPassed:true,
      classification:(if $classification != "" then $classification
        elif $manifest.status == "failed" then "candidate-pipeline-failure"
        elif $runtime != null then "runner-or-test-process-failure"
        else "runner-failure-before-runtime-evidence" end),
      commandStatus:$commandStatus,runtime:$runtime,manifest:$manifest,candidate:$raw}' \
    >"$DEV/fixed-downstream-failure.json"
}

fixed_downstream_replay() {
  [[ "${BENCHMARK_SLOT_GRANTED:-}" == 94 ]] || {
    echo "refusing heavy run without BENCHMARK_SLOT_GRANTED=94" >&2; return 2;
  }
  verify_inputs
  verify_models
  verify_fixed_downstream_ready
  [[ "$(jq -r .phase "$STATE")" == downstream-gate-red ]]
  if run_translation; then
    :
  else
    local status=$?
    set_phase fixed-downstream-gate-red
    record_fixed_downstream_failure "$status"
    retain_fixed_evidence
    return 1
  fi
  if [[ "$(jq -r '.status // empty' "$CANDIDATE/manifest.json" 2>/dev/null)" != completed ]]; then
    set_phase fixed-downstream-gate-red
    record_fixed_downstream_failure 1
    retain_fixed_evidence
    return 1
  fi
  if ! make_report; then
    set_phase fixed-report-red
    record_fixed_downstream_failure 1 reporter-failure
    retain_fixed_evidence
    return 1
  fi
  retain_fixed_evidence
  set_phase fixed-downstream-completed
}

development() {
  [[ "${BENCHMARK_SLOT_GRANTED:-}" == 94 ]] || {
    echo "refusing heavy run without BENCHMARK_SLOT_GRANTED=94" >&2; return 2;
  }
  verify_inputs
  verify_models
  mkdir -p "$DEV"
  if [[ "$MODE" == development ]]; then
    verify_ready
    [[ ! -e "$STATE" ]]
    jq -n '{ticket:94,globalBenchmark:1,phase:"created",holdoutOpened:false}' >"$STATE"
  else
    [[ -f "$STATE" ]]
    verify_downstream_ready
  fi
  if [[ ! -f "$ASR_RUN" ]]; then
    [[ "$(jq -r .phase "$STATE")" == created ]]
    run_asr
  fi
  [[ "$MODE" == resume ]] || select_japanese
  if jq -e '.developmentEligibleJapanese == true' "$SELECTION" >/dev/null \
      && [[ ! -f "$CANDIDATE/manifest.json" ]]; then
    if ! run_translation; then
      make_report
      retain_evidence
      set_phase downstream-gate-red
      return 1
    fi
  fi
  if [[ "$(jq -r '.status // empty' "$CANDIDATE/manifest.json" 2>/dev/null)" == failed ]]; then
    make_report
    retain_evidence
    set_phase downstream-gate-red
    return 1
  fi
  make_report
  retain_evidence
  set_phase completed
}

case "$MODE" in
  preflight)
    [[ ! -e "$STATE" ]]
    mkdir -p "$ARTIFACTS"
    verify_inputs
    verify_models
    prepare_light_evidence
    build_and_probe
    write_ready
    echo READY_FOR_HEAVY_BENCHMARK
    ;;
  development|resume) development ;;
  report)
    [[ -f "$STATE" && -f "$ASR_RUN" && -f "$SELECTION" ]]
    make_report
    retain_evidence
    if [[ "$(jq -r '.status // empty' "$CANDIDATE/manifest.json" 2>/dev/null)" == failed ]]; then
      set_phase downstream-gate-red
    fi
    ;;
  downstream-ready)
    [[ -f "$STATE" && -f "$ASR_RUN" ]]
    select_japanese
    jq -e '.developmentEligibleJapanese == true' "$SELECTION" >/dev/null
    make_report
    write_downstream_ready
    retain_evidence
    ;;
  verify-resume)
    verify_inputs
    verify_models
    verify_downstream_ready
    echo READY_FOR_DOWNSTREAM_RESUME_VALIDATED
    ;;
  fixed-downstream-ready)
    [[ -f "$STATE" && "$(jq -r .phase "$STATE")" == downstream-gate-red ]]
    verify_inputs
    verify_models
    verify_downstream_ready
    mkdir -p "$ARTIFACTS/controls"
    replay_root="$(mktemp -d)"
    gzip -dc "$ROOT/docs/japanese-live/experiments/evidence/E27/corrected-resume-failure-raw-asr.json.gz" \
      >"$replay_root/e27.json"
    gzip -dc "$EVIDENCE/candidate-raw-asr.json.gz" >"$replay_root/e28.json"
    WHISPERASR_FORCED_ALIGNMENT_EVIDENCE="$replay_root/e27.json" \
    WHISPERASR_FORCED_ALIGNMENT_EXPECTATION=fail-closed \
      xcrun swift test --filter \
        HighQualityJobTests/testForcedAlignmentFallbackReplayEvidenceWhenOptedIn \
        2>&1 | tee "$ARTIFACTS/controls/fixed-replay-e27.log"
    WHISPERASR_FORCED_ALIGNMENT_EVIDENCE="$replay_root/e28.json" \
    WHISPERASR_FORCED_ALIGNMENT_EXPECTATION=single-coarse-anchor \
      xcrun swift test --skip-build --filter \
        HighQualityJobTests/testForcedAlignmentFallbackReplayEvidenceWhenOptedIn \
        2>&1 | tee "$ARTIFACTS/controls/fixed-replay-e28.log"
    gzip -n -c "$ARTIFACTS/controls/fixed-replay-e27.log" \
      >"$EVIDENCE/fixed-replay-e27.log.gz"
    gzip -n -c "$ARTIFACTS/controls/fixed-replay-e28.log" \
      >"$EVIDENCE/fixed-replay-e28.log.gz"
    write_fixed_downstream_ready
    verify_fixed_downstream_ready
    echo READY_FOR_FIXED_DOWNSTREAM_REPLAY
    ;;
  verify-fixed-downstream-replay)
    verify_inputs
    verify_models
    verify_fixed_downstream_ready
    echo READY_FOR_FIXED_DOWNSTREAM_REPLAY_VALIDATED
    ;;
  fixed-downstream-replay) fixed_downstream_replay ;;
esac
