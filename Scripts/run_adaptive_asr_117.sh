#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/swift-module-cache"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

MODE="${1:-preflight}"
START_SECONDS=$SECONDS
HARD_TIMEOUT_SECONDS=13200
[[ "$MODE" == preflight || "$MODE" == full ]] || {
  echo "usage: $0 [preflight|full]" >&2
  exit 2
}
[[ "$MODE" == preflight || "${BENCHMARK_SLOT_GRANTED:-}" == 117 ]] || {
  echo "Refusing heavyweight #117 run without BENCHMARK_SLOT_GRANTED=117" >&2
  exit 2
}

BASE_COMMIT=75619a715d0cb6bfecc991e4855b7b229654d908
FROZEN=/Users/maz/Documents/projets/whisperASR
CORPUS_ROOT="$FROZEN/.build/benchmarks/japanese-live/corpora"
BASELINE_ROOT="$FROZEN/.build/benchmarks/high-quality/offline-acceptance/qwen-ja"
ARTIFACTS="$ROOT/.build/benchmarks/issue-117"
DEV="$ARTIFACTS/development"
HOLDOUT="$ARTIFACTS/holdout"
READY="$ARTIFACTS/READY_FOR_HEAVY_BENCHMARK.json"
STATE="$ARTIFACTS/state.json"
FINAL="$ARTIFACTS/final-report.json"
HARNESS_REPAIR="$ARTIFACTS/harness-repair.json"
WORKER="$ROOT/.build/debug/WhisperASR"
HARNESS="$ROOT/Scripts/adaptive_asr_117.py"
E23="$ROOT/docs/japanese-live/experiments/evidence/E23/segments.json"
CALIBRATION="$DEV/calibration.json"

manifest_for() { printf '%s/docs/japanese-live/corpora/%s/manifest.json\n' "$ROOT" "$1"; }
pcm_for() { printf '%s/%s/audio-16k-mono.wav\n' "$CORPUS_ROOT" "$1"; }
alignment_for() {
  [[ "$1" == qudu2fx3ncc ]] \
    && printf '%s/%s/character-alignment.jsonl\n' "$CORPUS_ROOT" "$1" \
    || printf '%s/%s/character-alignment.tsv\n' "$CORPUS_ROOT" "$1"
}
baseline_job() {
  [[ "$1" == qudu2fx3ncc ]] \
    && printf '%s/%s/jobs/44000001-0000-4000-8000-000000000001\n' "$BASELINE_ROOT" "$1" \
    || printf '%s/%s/jobs/44000002-0000-4000-8000-000000000001\n' "$BASELINE_ROOT" "$1"
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

write_failure() {
  local route="$1" phase="$2" message="$3"
  mkdir -p "$ARTIFACTS"
  jq -n --arg route "$route" --arg phase "$phase" --arg message "$message" \
    --argjson holdoutOpened "$([[ -f "$STATE" ]] && jq -r .holdoutOpened "$STATE" || echo false)" \
    '{ticket:117,status:"failed",route:$route,phase:$phase,message:$message,
      holdoutOpened:$holdoutOpened}' >"$ARTIFACTS/failure.json"
}

verify_development_inputs() {
  [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]
  command -v jq python3 shasum xcrun >/dev/null
  git merge-base --is-ancestor "$BASE_COMMIT" HEAD
  assert_hash "$(manifest_for qudu2fx3ncc)" \
    a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b
  assert_hash "$(pcm_for qudu2fx3ncc)" \
    494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2
  assert_hash "$(alignment_for qudu2fx3ncc)" \
    abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7
  assert_hash "$E23" e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81
  assert_hash "$(baseline_job qudu2fx3ncc)/raw-asr.json" \
    b7281fdd3226930a4dc59758eb5e192642747ad6f9d18d942b850288ad42a394
  assert_hash "$(baseline_job qudu2fx3ncc)/manifest.json" \
    3f31b861f8a59ab5fbed35561d58c8921ce2d4c7a46f5a222a6ad4548109275a
}

verify_holdout_inputs() {
  assert_hash "$(manifest_for md62mmdz0m)" \
    9e2c828804457100b5f517ae84e1709a7b502837e36154ec4e7c7b5dc635e3bc
  assert_hash "$(pcm_for md62mmdz0m)" \
    bde49d4cc67020d01ae042f2945baa61364cc34959e2211a964943e5c2064830
  assert_hash "$(alignment_for md62mmdz0m)" \
    446e7a00ad003b904e3de90786ef65f1829cc063217638535b134c084f2db925
  assert_hash "$(baseline_job md62mmdz0m)/raw-asr.json" \
    00b986ccb47e1da4e6532682ef8006086ad0dca8865459ba972fee297f3af5c1
  assert_hash "$(baseline_job md62mmdz0m)/manifest.json" \
    ab4b1c21e1fd02488502e31458271aa6bc85e92b665ff3bd52ea2000dc770411
}

verify_models() {
  assert_hash "/Users/maz/Library/Caches/qwen3-speech/models/ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit/model.safetensors" \
    bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954
  local parakeet="/Users/maz/Library/Application Support/FluidAudio/Models/parakeet-ja"
  assert_hash "$parakeet/Encoder.mlmodelc/weights/weight.bin" \
    257685d3fdb578c5d6d7f0a5460c778f6104bcf2f264e4ae704b885c69ad6dda
  assert_hash "$parakeet/Jointerv2.mlmodelc/weights/weight.bin" \
    d6f24519c7c6959e8ec6fb078e8c05d912d292fcb57720c63fdc9291b1db122d
  assert_hash "$parakeet/Preprocessor.mlmodelc/weights/weight.bin" \
    6512ba5d1acc3ffe6f322089c0ece5466f93c7ac77c267dd851a1fb517c637f9
  assert_hash "$parakeet/Decoderv2.mlmodelc/weights/weight.bin" \
    a56d792edf3b88e30466c0b992bb7e316fa743c90f8809c2be9d2ecb8ffbd48e
  assert_hash "/Users/maz/.cache/huggingface/hub/models--mlx-community--Qwen3-ForcedAligner-0.6B-4bit/snapshots/2f652af86ae0c73fe189b9429225c908ce4bf020/model.safetensors" \
    630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c
  local translator="/Users/maz/.cache/huggingface/hub/models--mlx-community--translategemma-12b-it-4bit/snapshots/f3dcfd54df14672fbcf0731086fb47a797a943ae"
  assert_hash "$translator/model-00001-of-00002.safetensors" \
    bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af
  assert_hash "$translator/model-00002-of-00002.safetensors" \
    c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89
}

prepare_controls() {
  mkdir -p "$ARTIFACTS/controls" "$DEV"
  python3 "$HARNESS" plan --audio "$(pcm_for qudu2fx3ncc)" \
    --manifest "$(manifest_for qudu2fx3ncc)" --role development \
    --output "$DEV/plan.json"
  xcrun swift build 2>&1 | tee "$ARTIFACTS/controls/build.log"
  env WHISPERASR_RUN_ADAPTIVE_117_PLAN=1 \
    WHISPERASR_ADAPTIVE_117_AUDIO="$(pcm_for qudu2fx3ncc)" \
    WHISPERASR_ADAPTIVE_117_PLAN="$DEV/plan.json" xcrun swift test --filter \
    'HighQualityAdaptiveASRTests|AdaptiveASR117BenchmarkTests|HighQualityASRWorkerTests/testJobManifestRetainsASRWorkerProvenanceAndPeakMemory|HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts|LiveCaptionTests/testAdaptiveIsTheDefaultAppleTranslationMode|LiveCaptionTests/testAppleTranslationModeReadinessRequirements' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  python3 "$HARNESS" self-test | tee "$ARTIFACTS/controls/harness.log"
  [[ -f "$ROOT/.build/debug/mlx.metallib" ]] || bash Scripts/build_mlx_metallib.sh debug
  [[ -x "$WORKER" ]]
  python3 Scripts/qwen_voice_music_harness.py run-command --timeout 5 \
    --log "$ARTIFACTS/controls/worker-probe.log" \
    --runtime "$ARTIFACTS/controls/worker-probe-runtime.json" -- \
    "$WORKER" --high-quality-asr-worker --probe
  grep -Fxq WHISPERASR_HIGH_QUALITY_ASR_WORKER_PROBE_OK \
    "$ARTIFACTS/controls/worker-probe.log"
  jq -e '.ticket == 117 and .corpusRole == "development" and .holdoutOpened == false
    and .algorithm.usesReference == false and (.segments | length) > 0
    and ([.segments[] | .endSample - .startSample] | max) <= 128000' \
    "$DEV/plan.json" >/dev/null
}

implementation_hashes() {
  local value='{}' path digest
  for path in Sources/HighQualityAdaptiveASR.swift Sources/HighQualityJob.swift \
    Tests/HighQualityAdaptiveASRTests.swift Tests/AdaptiveASR117BenchmarkTests.swift \
    Scripts/adaptive_asr_117.py Scripts/run_adaptive_asr_117.sh; do
    digest="$(hash_file "$ROOT/$path")"
    value="$(jq -c --arg path "$path" --arg digest "$digest" '. + {($path):$digest}' \
      <<<"$value")"
  done
  printf '%s\n' "$value"
}

write_ready() {
  local free_disk total_ram implementation
  free_disk="$(df -k "$ROOT" | awk 'NR==2 {printf "%.0f", $4 * 1024}')"
  total_ram="$(sysctl -n hw.memsize)"
  (( free_disk >= 20 * 1024 * 1024 * 1024 ))
  implementation="$(implementation_hashes)"
  jq -n \
    --arg command 'BENCHMARK_SLOT_GRANTED=117 bash Scripts/run_adaptive_asr_117.sh full' \
    --arg commit "$(git rev-parse HEAD)" --arg plan "$(hash_file "$DEV/plan.json")" \
    --arg binary "$(hash_file "$WORKER")" --argjson implementation "$implementation" \
    --argjson freeDisk "$free_disk" --argjson totalRAM "$total_ram" \
    '{status:"READY_FOR_HEAVY_BENCHMARK",ticket:117,heavyRunsLaunched:0,
      command:$command,baseCommit:"75619a715d0cb6bfecc991e4855b7b229654d908",
      workingCommit:$commit,corpora:{development:"qudu2fx3ncc",
        holdout:"md62mmdz0m",holdoutOpened:false},
      sequence:["DEV Qwen all short acoustic segments","DEV Parakeet suspect segments only",
        "freeze one DEV margin after separate backend calibration","DEV one alignment + translation",
        "open holdout only if every DEV gate passes","holdout same frozen policy",
        "holdout one alignment + translation"],
      estimate:{typicalMinutes:155,hardTimeoutMinutes:220,peakRAMGiB:14,
        incrementalDiskGiB:2,freeDiskBytes:$freeDisk,totalRAMBytes:$totalRAM},
      models:["Qwen3-ASR-1.7B-JA-MLX-8bit","Parakeet 0.6B JA CoreML",
        "Qwen3 ForcedAligner 0.6B 4bit","TranslateGemma 12B 4bit"],
      gates:["frozen hashes and raw provenance","runtime-only 3-8s detector",
        "Qwen first; Parakeet suspects only; strict worker serialization",
        "separate 5-block DEV calibration; one frozen margin",
        "complete hypotheses and integrity vetoes","DEV Japanese gain >=2%",
        "useful holdout recovery","bounded ASR cost <=5x Qwen",
        "peak workflow memory <=14 GiB",
        "one selected alignment and translation","English chrF++ non-regression on both"],
      implementationSHA256:$implementation,workerSHA256:$binary,developmentPlanSHA256:$plan}' \
    >"$READY"
}

verify_ready() {
  jq -e '.status == "READY_FOR_HEAVY_BENCHMARK" and .ticket == 117
    and .heavyRunsLaunched == 0 and .corpora.holdoutOpened == false' "$READY" >/dev/null
  [[ "$(hash_file "$DEV/plan.json")" == "$(jq -r .developmentPlanSHA256 "$READY")" ]]
  [[ "$(hash_file "$WORKER")" == "$(jq -r .workerSHA256 "$READY")" ]]
  local implementation_matches=true path expected
  while IFS=$'\t' read -r path expected; do
    [[ "$(hash_file "$ROOT/$path")" == "$expected" ]] || implementation_matches=false
  done < <(jq -r '.implementationSHA256 | to_entries[] | [.key,.value] | @tsv' "$READY")
  [[ "$implementation_matches" == true ]] && return 0
  [[ -f "$HARNESS_REPAIR" ]]
  jq -e '.ticket == 117 and .route == "harness"
    and .changedPaths == ["Scripts/adaptive_asr_117.py","Scripts/run_adaptive_asr_117.sh"]' \
    "$HARNESS_REPAIR" >/dev/null
  [[ "$(hash_file "$READY")" == "$(jq -r .readySHA256 "$HARNESS_REPAIR")" ]]
  [[ "$(hash_file "$DEV/run.json")" == "$(jq -r .developmentRunSHA256 "$HARNESS_REPAIR")" ]]
  while IFS=$'\t' read -r path expected; do
    [[ "$(hash_file "$ROOT/$path")" == "$expected" ]]
  done < <(jq -r '.implementationSHA256 | to_entries[] | [.key,.value] | @tsv' \
    "$HARNESS_REPAIR")
  for path in Sources/HighQualityAdaptiveASR.swift Sources/HighQualityJob.swift \
    Tests/HighQualityAdaptiveASRTests.swift Tests/AdaptiveASR117BenchmarkTests.swift; do
    [[ "$(hash_file "$ROOT/$path")" == \
      "$(jq -r --arg path "$path" '.implementationSHA256[$path]' "$READY")" ]]
  done
}

run_test() {
  local phase="$1" timeout="$2" log="$3" runtime="$4"
  shift 4
  local remaining=$((HARD_TIMEOUT_SECONDS - (SECONDS - START_SECONDS)))
  if (( remaining <= 0 )); then
    write_failure infrastructure "$phase" "heavy benchmark exceeded 220 minutes"
    return 1
  fi
  (( timeout <= remaining )) || timeout=$remaining
  if ! python3 Scripts/qwen_voice_music_harness.py run-command --timeout "$timeout" \
      --log "$log" --runtime "$runtime" -- "$@"; then
    write_failure infrastructure "$phase" "heavy test failed; inspect $log and $runtime"
    return 1
  fi
}

run_asr() {
  local split="$1" corpus="$2" directory="$3"
  if [[ -e "$directory/run.json" ]]; then
    [[ "$split" == development && -f "$HARNESS_REPAIR" ]] || {
      write_failure harness "$split-asr" "refusing unverified raw ASR reuse"
      return 1
    }
    echo "Reusing retained DEV raw ASR after verified harness repair"
    return 0
  fi
  mkdir -p "$directory"
  run_test "$split-asr" 2400 "$directory/asr.log" "$directory/asr-runtime.json" \
    env BENCHMARK_SLOT_GRANTED=117 WHISPERASR_RUN_ADAPTIVE_117_ASR=1 \
      WHISPERASR_ADAPTIVE_117_AUDIO="$(pcm_for "$corpus")" \
      WHISPERASR_ADAPTIVE_117_PLAN="$directory/plan.json" \
      WHISPERASR_ADAPTIVE_117_RUN="$directory/run.json" \
      WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
      xcrun swift test --skip-build \
        --filter AdaptiveASR117BenchmarkTests/testIssue117RawASRWhenOptedIn
}

run_downstream() {
  local split="$1" corpus="$2" directory="$3" job_id="$4"
  [[ ! -d "$directory/jobs/$job_id" ]] || {
    write_failure harness "$split-downstream" "refusing to overwrite retained downstream evidence"
    return 1
  }
  run_test "$split-downstream" 7200 "$directory/downstream.log" \
    "$directory/downstream-runtime.json" \
    env BENCHMARK_SLOT_GRANTED=117 WHISPERASR_RUN_ADAPTIVE_117_DOWNSTREAM=1 \
      WHISPERASR_ADAPTIVE_117_AUDIO="$(pcm_for "$corpus")" \
      WHISPERASR_ADAPTIVE_117_PLAN="$directory/plan.json" \
      WHISPERASR_ADAPTIVE_117_RUN="$directory/run.json" \
      WHISPERASR_ADAPTIVE_117_CALIBRATION="$CALIBRATION" \
      WHISPERASR_ADAPTIVE_117_OUTPUT="$directory/jobs" \
      WHISPERASR_ADAPTIVE_117_JOB_ID="$job_id" \
      WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
      xcrun swift test --skip-build \
        --filter AdaptiveASR117BenchmarkTests/testIssue117SelectedDownstreamWhenOptedIn
}

score_split() {
  local split="$1" corpus="$2" directory="$3" job_id="$4"
  if ! python3 "$HARNESS" score --split "$split" --plan "$directory/plan.json" \
      --run "$directory/run.json" --manifest "$(manifest_for "$corpus")" \
      --character-alignment "$(alignment_for "$corpus")" --e23 "$E23" \
      --baseline-raw "$(baseline_job "$corpus")/raw-asr.json" \
      --baseline-manifest "$(baseline_job "$corpus")/manifest.json" \
      --calibration "$CALIBRATION" \
      --candidate-raw "$directory/jobs/$job_id/raw-asr.json" \
      --candidate-manifest "$directory/jobs/$job_id/manifest.json" \
      --output "$directory/score.json"; then
    write_failure harness "$split-score" "scorer rejected retained evidence"
    return 1
  fi
}

preflight() {
  mkdir -p "$ARTIFACTS"
  if ! verify_development_inputs; then
    write_failure harness preflight-inputs "frozen input or baseline integrity failed"
    return 1
  fi
  if ! verify_models; then
    write_failure infrastructure preflight-models "pinned model weights are unavailable"
    return 1
  fi
  if ! prepare_controls; then
    write_failure infrastructure preflight-controls "build, light tests, or worker probe failed"
    return 1
  fi
  write_ready
  jq -n '{ticket:117,phase:"ready",holdoutOpened:false,heavyRunsLaunched:0}' >"$STATE"
  echo "READY_FOR_HEAVY_BENCHMARK #117"
  jq '{command,estimate,models,gates}' "$READY"
}

full() {
  if ! verify_development_inputs; then
    write_failure harness full-inputs "frozen input or baseline integrity changed"
    return 1
  fi
  if ! verify_models; then
    write_failure infrastructure full-models "pinned model weights are unavailable"
    return 1
  fi
  if ! verify_ready; then
    write_failure harness full-ready "implementation or preflight evidence changed"
    return 1
  fi
  jq '.phase="development-asr" | .heavyRunsLaunched=1' "$STATE" >"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  run_asr development qudu2fx3ncc "$DEV"
  if ! python3 "$HARNESS" calibrate --plan "$DEV/plan.json" --run "$DEV/run.json" \
      --manifest "$(manifest_for qudu2fx3ncc)" \
      --character-alignment "$(alignment_for qudu2fx3ncc)" --e23 "$E23" \
      --baseline-raw "$(baseline_job qudu2fx3ncc)/raw-asr.json" \
      --baseline-manifest "$(baseline_job qudu2fx3ncc)/manifest.json" \
      --calibration "$CALIBRATION" --report "$DEV/calibration-report.json"; then
    write_failure harness development-calibration "DEV calibration failed"
    return 1
  fi
  if ! jq -e '.decision == "DEV-JA-PASS" and ([.gates[]] | all)' \
      "$DEV/calibration-report.json" >/dev/null; then
    jq -n --slurpfile development "$DEV/calibration-report.json" \
      '{ticket:117,decision:"RETAIN-HIDDEN",holdoutOpened:false,
        route:"candidate",development:$development[0]}' >"$FINAL"
    jq '.phase="development-no-go"' "$STATE" >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
    return 0
  fi
  run_downstream development qudu2fx3ncc "$DEV" \
    11700001-0000-4000-8000-000000000001
  score_split development qudu2fx3ncc "$DEV" \
    11700001-0000-4000-8000-000000000001
  if ! jq -e '.decision == "PASS" and ([.gates[]] | all)' "$DEV/score.json" >/dev/null; then
    jq -n --slurpfile development "$DEV/score.json" \
      '{ticket:117,decision:"RETAIN-HIDDEN",holdoutOpened:false,
        route:"candidate",development:$development[0]}' >"$FINAL"
    jq '.phase="development-no-go"' "$STATE" >"$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
    return 0
  fi
  jq -n --arg calibrationSHA256 "$(hash_file "$CALIBRATION")" \
    --arg developmentSHA256 "$(hash_file "$DEV/score.json")" \
    --argjson implementation "$(implementation_hashes)" \
    '{ticket:117,status:"DEV-FROZEN-BEFORE-HOLDOUT",oneVariable:"minimumMargin",
      calibrationSHA256:$calibrationSHA256,developmentScoreSHA256:$developmentSHA256,
      implementationSHA256:$implementation}' >"$DEV/freeze.json"
  jq '.phase="holdout-opened" | .holdoutOpened=true' "$STATE" >"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  if ! verify_holdout_inputs; then
    write_failure harness holdout-inputs "frozen holdout integrity failed after opening"
    return 1
  fi
  mkdir -p "$HOLDOUT"
  python3 "$HARNESS" plan --audio "$(pcm_for md62mmdz0m)" \
    --manifest "$(manifest_for md62mmdz0m)" --role untouched-holdout \
    --output "$HOLDOUT/plan.json"
  run_asr holdout md62mmdz0m "$HOLDOUT"
  [[ "$(hash_file "$CALIBRATION")" == "$(jq -r .calibrationSHA256 "$DEV/freeze.json")" ]]
  run_downstream holdout md62mmdz0m "$HOLDOUT" \
    11700002-0000-4000-8000-000000000001
  score_split holdout md62mmdz0m "$HOLDOUT" \
    11700002-0000-4000-8000-000000000001
  python3 "$HARNESS" final --development "$DEV/score.json" \
    --holdout "$HOLDOUT/score.json" --output "$FINAL"
  jq '.phase="completed"' "$STATE" >"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

if [[ "$MODE" == preflight ]]; then preflight; else full; fi
