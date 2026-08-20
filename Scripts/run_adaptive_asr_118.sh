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
HARD_TIMEOUT_SECONDS=18000
[[ "$MODE" == preflight || "$MODE" == full || "$MODE" == self-test ]] || {
  echo "usage: $0 [preflight|full|self-test]" >&2
  exit 2
}
[[ "$MODE" != full || "${BENCHMARK_SLOT_GRANTED:-}" == 118 ]] || {
  echo "Refusing heavyweight #118 run without BENCHMARK_SLOT_GRANTED=118" >&2
  exit 2
}

BASE_COMMIT=98f4ccd8bf6dcd1cb98e10554f9153074357debf
FROZEN=/Users/maz/Documents/projets/whisperASR
CORPUS_ROOT="$FROZEN/.build/benchmarks/japanese-live/corpora"
BASELINE_ROOT="$FROZEN/.build/benchmarks/high-quality/offline-acceptance/qwen-ja"
ARTIFACTS="$ROOT/.build/benchmarks/issue-118"
DEV="$ARTIFACTS/development"
HOLDOUT="$ARTIFACTS/holdout"
READY="$ARTIFACTS/READY_FOR_HEAVY_BENCHMARK.json"
PRODUCER="$ARTIFACTS/producer.json"
STATE="$ARTIFACTS/state.json"
FINAL="$ARTIFACTS/final-report.json"
ATTEMPT1="$ARTIFACTS/attempt-1"
WORKER="$ROOT/.build/debug/WhisperASR"
TEST_BUNDLE="$ROOT/.build/debug/WhisperASRPackageTests.xctest"
TEST_EXECUTABLE="$TEST_BUNDLE/Contents/MacOS/WhisperASRPackageTests"
TEST_RESOURCE="$TEST_BUNDLE/Contents/MacOS/mlx.metallib"
WORKER_RESOURCE="$ROOT/.build/debug/mlx.metallib"
BASE_HARNESS="$ROOT/Scripts/adaptive_asr_117.py"
HARNESS="$ROOT/Scripts/adaptive_asr_118.py"
E23="$ROOT/docs/japanese-live/experiments/evidence/E23/segments.json"
P_CALIBRATION="$DEV/parakeet-calibration.json"
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
checked_hash() {
  local value
  value="$(hash_file "$1")" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}
checked_realpath() {
  local value
  value="$(realpath "$1")" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}
checked_json_string() {
  local value
  value="$(jq -er --arg key "$2" \
    '.[$key] | select(type == "string" and length > 0)' "$1")" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}
verify_json_hash() {
  local observed expected
  observed="$(checked_hash "$1")" || return 1
  expected="$(checked_json_string "$2" "$3")" || return 1
  [[ "$observed" == "$expected" ]]
}
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
  local state_path="${4:-$STATE}" artifacts_path="${5:-$ARTIFACTS}"
  local holdout_opened=null state_provenance=missing
  if [[ -e "$state_path" ]]; then
    if holdout_opened="$(jq -er \
      'if (.holdoutOpened | type) == "boolean"
       then (.holdoutOpened | tostring) else error("invalid holdoutOpened") end' \
      "$state_path" 2>/dev/null)"; then
      [[ -n "$holdout_opened" ]] || return 1
      state_provenance=verified
    else
      holdout_opened=null
      state_provenance=invalid
    fi
  fi
  mkdir -p "$artifacts_path" || return 1
  jq -n --arg route "$route" --arg phase "$phase" --arg message "$message" \
    --arg stateProvenance "$state_provenance" \
    --argjson holdoutOpened "$holdout_opened" \
    '{ticket:118,status:"failed",route:$route,phase:$phase,message:$message,
      stateProvenance:$stateProvenance,
      holdoutOpened:$holdoutOpened}' >"$artifacts_path/failure.json" || return 1
}

verify_development_inputs() {
  [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || return 1
  command -v jq python3 realpath shasum xcrun >/dev/null || return 1
  git merge-base --is-ancestor "$BASE_COMMIT" HEAD || return 1
  assert_hash "$(manifest_for qudu2fx3ncc)" \
    a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b \
    || return 1
  assert_hash "$(pcm_for qudu2fx3ncc)" \
    494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2 \
    || return 1
  assert_hash "$(alignment_for qudu2fx3ncc)" \
    abfbd3f23d0f654a5b424b24e56890dfd23cae6805d804f4063e51852593f4a7 \
    || return 1
  assert_hash "$E23" e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81 \
    || return 1
  assert_hash "$(baseline_job qudu2fx3ncc)/raw-asr.json" \
    b7281fdd3226930a4dc59758eb5e192642747ad6f9d18d942b850288ad42a394 \
    || return 1
  assert_hash "$(baseline_job qudu2fx3ncc)/manifest.json" \
    3f31b861f8a59ab5fbed35561d58c8921ce2d4c7a46f5a222a6ad4548109275a \
    || return 1
}

verify_holdout_inputs() {
  assert_hash "$(manifest_for md62mmdz0m)" \
    9e2c828804457100b5f517ae84e1709a7b502837e36154ec4e7c7b5dc635e3bc \
    || return 1
  assert_hash "$(pcm_for md62mmdz0m)" \
    bde49d4cc67020d01ae042f2945baa61364cc34959e2211a964943e5c2064830 \
    || return 1
  assert_hash "$(alignment_for md62mmdz0m)" \
    446e7a00ad003b904e3de90786ef65f1829cc063217638535b134c084f2db925 \
    || return 1
  assert_hash "$(baseline_job md62mmdz0m)/raw-asr.json" \
    00b986ccb47e1da4e6532682ef8006086ad0dca8865459ba972fee297f3af5c1 \
    || return 1
  assert_hash "$(baseline_job md62mmdz0m)/manifest.json" \
    ab4b1c21e1fd02488502e31458271aa6bc85e92b665ff3bd52ea2000dc770411 \
    || return 1
}

verify_models() {
  assert_hash "/Users/maz/Library/Caches/qwen3-speech/models/ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit/model.safetensors" \
    bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954 \
    || return 1
  local parakeet="/Users/maz/Library/Application Support/FluidAudio/Models/parakeet-ja"
  assert_hash "$parakeet/Encoder.mlmodelc/weights/weight.bin" \
    257685d3fdb578c5d6d7f0a5460c778f6104bcf2f264e4ae704b885c69ad6dda \
    || return 1
  assert_hash "$parakeet/Jointerv2.mlmodelc/weights/weight.bin" \
    d6f24519c7c6959e8ec6fb078e8c05d912d292fcb57720c63fdc9291b1db122d \
    || return 1
  assert_hash "$parakeet/Preprocessor.mlmodelc/weights/weight.bin" \
    6512ba5d1acc3ffe6f322089c0ece5466f93c7ac77c267dd851a1fb517c637f9 \
    || return 1
  assert_hash "$parakeet/Decoderv2.mlmodelc/weights/weight.bin" \
    a56d792edf3b88e30466c0b992bb7e316fa743c90f8809c2be9d2ecb8ffbd48e \
    || return 1
  local whisper="/Users/maz/Library/Application Support/WhisperASR/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3"
  assert_hash "$whisper/AudioEncoder.mlmodelc/weights/weight.bin" \
    eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457 \
    || return 1
  assert_hash "$whisper/MelSpectrogram.mlmodelc/weights/weight.bin" \
    97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87 \
    || return 1
  assert_hash "$whisper/TextDecoder.mlmodelc/weights/weight.bin" \
    680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55 \
    || return 1
  assert_hash "/Users/maz/.cache/huggingface/hub/models--mlx-community--Qwen3-ForcedAligner-0.6B-4bit/snapshots/2f652af86ae0c73fe189b9429225c908ce4bf020/model.safetensors" \
    630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c \
    || return 1
  local translator="/Users/maz/.cache/huggingface/hub/models--mlx-community--translategemma-12b-it-4bit/snapshots/f3dcfd54df14672fbcf0731086fb47a797a943ae"
  assert_hash "$translator/model-00001-of-00002.safetensors" \
    bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af \
    || return 1
  assert_hash "$translator/model-00002-of-00002.safetensors" \
    c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89 \
    || return 1
}

implementation_hashes() {
  local value='{}' path digest
  for path in Sources/HighQualityASRWorker.swift Sources/HighQualityAdaptiveASR.swift \
    Sources/HighQualityJob.swift Tests/HighQualityASRWorkerTests.swift \
    Tests/HighQualityAdaptiveASRTests.swift Tests/AdaptiveASR117BenchmarkTests.swift \
    Scripts/adaptive_asr_117.py Scripts/adaptive_asr_118.py \
    Scripts/run_adaptive_asr_118.sh; do
    digest="$(hash_file "$ROOT/$path")" || return 1
    value="$(jq -c --arg path "$path" --arg digest "$digest" \
      '. + {($path):$digest}' <<<"$value")" || return 1
  done
  printf '%s\n' "$value"
}

test_artifact_evidence() {
  local executable="${1:-$TEST_EXECUTABLE}" resource="${2:-$TEST_RESOURCE}"
  local worker_resource="${3:-$WORKER_RESOURCE}"
  local executable_path executable_sha resource_path resource_sha
  local worker_resource_path worker_resource_sha
  [[ -x "$executable" && -f "$resource" && -f "$worker_resource" ]] || return 1
  executable_path="$(checked_realpath "$executable")" || return 1
  executable_sha="$(checked_hash "$executable")" || return 1
  resource_path="$(checked_realpath "$resource")" || return 1
  resource_sha="$(checked_hash "$resource")" || return 1
  worker_resource_path="$(checked_realpath "$worker_resource")" || return 1
  worker_resource_sha="$(checked_hash "$worker_resource")" || return 1
  jq -cn --arg executable "$executable_path" \
    --arg executableSHA "$executable_sha" \
    --arg resource "$resource_path" --arg resourceSHA "$resource_sha" \
    --arg workerResource "$worker_resource_path" \
    --arg workerResourceSHA "$worker_resource_sha" \
    '{schemaVersion:1,executable:{path:$executable,SHA256:$executableSHA},
      requiredResources:[{path:$resource,SHA256:$resourceSHA},
        {path:$workerResource,SHA256:$workerResourceSHA}]}'
}

producer_snapshot() {
  local ready="${1:-$READY}" worker="${2:-$WORKER}"
  local executable="${3:-$TEST_EXECUTABLE}" resource="${4:-$TEST_RESOURCE}"
  local worker_resource="${5:-$WORKER_RESOURCE}"
  local implementation="${6:-}" test_artifact ready_sha worker_sha
  if [[ -z "$implementation" ]]; then
    implementation="$(implementation_hashes)" || return 1
  fi
  [[ -n "$implementation" ]] || return 1
  [[ -f "$ready" && -x "$worker" ]] || return 1
  test_artifact="$(test_artifact_evidence "$executable" "$resource" "$worker_resource")" \
    || return 1
  ready_sha="$(checked_hash "$ready")" || return 1
  worker_sha="$(checked_hash "$worker")" || return 1
  jq -cn --arg ready "$ready_sha" --arg worker "$worker_sha" \
    --argjson implementation "$implementation" --argjson testArtifact "$test_artifact" \
    '{readySHA256:$ready,workerSHA256:$worker,
      implementationSHA256:$implementation,testArtifact:$testArtifact}'
}

write_raw_provenance() {
  local raw="$1" provenance="$2" producer="$3"
  local raw_sha
  [[ -f "$raw" && ! -e "$provenance" ]] || return 1
  [[ "$(producer_snapshot)" == "$producer" ]] || return 1
  raw_sha="$(checked_hash "$raw")" || return 1
  jq -n --arg raw "$raw_sha" --argjson producer "$producer" \
    '$producer + {schemaVersion:1,ticket:118,status:"recorded-at-execution",
      rawSHA256:$raw}' >"$provenance.tmp" || return 1
  mv "$provenance.tmp" "$provenance" || return 1
}

verify_raw_provenance() {
  local raw="$1" provenance="$2" producer raw_sha
  [[ -f "$raw" && -f "$provenance" ]] || return 1
  producer="$(producer_snapshot)" || return 1
  raw_sha="$(checked_hash "$raw")" || return 1
  if jq -e '.status == "reused-hash-compatible-from-attempt-1"' \
      "$provenance" >/dev/null; then
    local source_raw_sha source_provenance_sha
    verify_archived_development_base || return 1
    source_raw_sha="$(checked_hash "$ATTEMPT1/development/base-run.json")" || return 1
    source_provenance_sha="$(checked_hash \
      "$ATTEMPT1/development/base-run-provenance.json")" || return 1
    jq -e --arg raw "$raw_sha" --arg sourceRaw "$source_raw_sha" \
      --arg sourceProvenance "$source_provenance_sha" \
      --argjson producer "$producer" \
      '.schemaVersion == 1 and .ticket == 118
        and .status == "reused-hash-compatible-from-attempt-1"
        and .rawSHA256 == $raw and .sourceRawSHA256 == $sourceRaw
        and .sourceProvenanceSHA256 == $sourceProvenance
        and .readySHA256 == $producer.readySHA256
        and .workerSHA256 == $producer.workerSHA256
        and .implementationSHA256 == $producer.implementationSHA256
        and .testArtifact == $producer.testArtifact' "$provenance" >/dev/null
    return
  fi
  jq -e --arg raw "$raw_sha" --argjson producer "$producer" \
    '.schemaVersion == 1 and .ticket == 118 and .status == "recorded-at-execution"
      and .rawSHA256 == $raw and .readySHA256 == $producer.readySHA256
      and .workerSHA256 == $producer.workerSHA256
      and .implementationSHA256 == $producer.implementationSHA256
      and .testArtifact == $producer.testArtifact' "$provenance" >/dev/null
}

verify_archived_development_base() {
  local plan_sha raw_sha
  [[ -f "$ATTEMPT1/SHA256SUMS" ]] || return 1
  shasum -a 256 -c "$ATTEMPT1/SHA256SUMS" >/dev/null || return 1
  [[ "$(hash_file "$ATTEMPT1/development/plan.json")" \
    == "$(hash_file "$DEV/plan.json")" ]] || return 1
  [[ "$(hash_file "$ATTEMPT1/development/base-run.json")" \
    == b5ad7af5db17f8595edd78dcdd4668ec4ab2c2bdc0c5a82889798323d28ee577 ]] \
    || return 1
  local path expected
  for path in Sources/HighQualityAdaptiveASR.swift Sources/HighQualityJob.swift \
    Scripts/adaptive_asr_117.py; do
    expected="$(jq -r --arg path "$path" '.implementationSHA256[$path]' \
      "$ATTEMPT1/producer.json")"
    [[ "$(hash_file "$ROOT/$path")" == "$expected" ]] || return 1
  done
  plan_sha="$(checked_hash "$DEV/plan.json")" || return 1
  jq -e --arg plan "$plan_sha" \
    '.ticket == 117 and .status == "completed" and .corpusRole == "development"
      and .sourceSHA256 == "494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2"
      and .planSHA256 == $plan and .strictlySequential == true
      and (.windows | length) == 169 and (.errors | length) == 0
      and [.workers[].backend] == ["qwen-ja","parakeet-ja"]
      and ([.workers[] | .lifecycle.exitStatus == 0
        and .lifecycle.forcedTermination == false
        and .lifecycle.peakPhysicalFootprintBytes > 0] | all)
      and .workers[0].model.weightSHA256["model.safetensors"]
        == "bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954"
      and .workers[1].model.weightSHA256["Encoder.mlmodelc/weights/weight.bin"]
        == "257685d3fdb578c5d6d7f0a5460c778f6104bcf2f264e4ae704b885c69ad6dda"' \
    "$ATTEMPT1/development/base-run.json" >/dev/null
  raw_sha="$(checked_hash "$ATTEMPT1/development/base-run.json")" || return 1
  jq -e --arg raw "$raw_sha" \
    '.ticket == 118 and .status == "recorded-at-execution" and .rawSHA256 == $raw' \
    "$ATTEMPT1/development/base-run-provenance.json" >/dev/null
}

reuse_archived_development_base() {
  verify_archived_development_base || return 1
  local producer raw_sha source_raw_sha source_provenance_sha
  producer="$(producer_snapshot)" || return 1
  cp "$ATTEMPT1/development/base-run.json" "$DEV/base-run.json" || return 1
  cp "$ATTEMPT1/development/base-asr.log" "$DEV/base-asr.log" || return 1
  cp "$ATTEMPT1/development/base-asr-runtime.json" "$DEV/base-asr-runtime.json" \
    || return 1
  raw_sha="$(checked_hash "$DEV/base-run.json")" || return 1
  source_raw_sha="$(checked_hash "$ATTEMPT1/development/base-run.json")" || return 1
  source_provenance_sha="$(checked_hash \
    "$ATTEMPT1/development/base-run-provenance.json")" || return 1
  jq -n --arg raw "$raw_sha" \
    --arg sourceRaw "$source_raw_sha" \
    --arg sourceProvenance "$source_provenance_sha" \
    --argjson elapsedSeconds 175.817 --argjson producer "$producer" \
    '$producer + {schemaVersion:1,ticket:118,
      status:"reused-hash-compatible-from-attempt-1",rawSHA256:$raw,
      sourceRawSHA256:$sourceRaw,sourceProvenanceSHA256:$sourceProvenance,
      originalElapsedSeconds:$elapsedSeconds}' >"$DEV/base-run-provenance.json" \
    || return 1
  verify_raw_provenance "$DEV/base-run.json" "$DEV/base-run-provenance.json" || return 1
}

verify_ready() {
  jq -e '.status == "READY_FOR_HEAVY_BENCHMARK" and .ticket == 118
    and .heavyRunsLaunched == 0 and .corpora.holdoutOpened == false' "$READY" >/dev/null \
    || return 1
  [[ "$(hash_file "$DEV/plan.json")" == "$(jq -r .developmentPlanSHA256 "$READY")" ]] \
    || return 1
  [[ "$(hash_file "$WORKER")" == "$(jq -r .workerSHA256 "$READY")" ]] || return 1
  [[ -f "$PRODUCER" && "$(producer_snapshot)" == "$(jq -c . "$PRODUCER")" ]] \
    || return 1
}

run_heavy_test() {
  local phase="$1" timeout="$2" log="$3" runtime="$4"
  shift 4
  local expected remaining failed=0
  expected="$(jq -c . "$PRODUCER")" || return 1
  [[ "$(producer_snapshot)" == "$expected" ]] || {
    write_failure infrastructure "$phase-provenance-pre" "producer changed after READY"
    return 1
  }
  remaining=$((HARD_TIMEOUT_SECONDS - (SECONDS - START_SECONDS))) || return 1
  (( remaining > 0 )) || {
    write_failure infrastructure "$phase" "benchmark exceeded 300 minutes"
    return 1
  }
  (( timeout <= remaining )) || timeout=$remaining
  python3 Scripts/qwen_voice_music_harness.py run-command --timeout "$timeout" \
    --log "$log" --runtime "$runtime" -- "$@" || failed=$?
  [[ "$(producer_snapshot)" == "$expected" ]] || {
    write_failure infrastructure "$phase-provenance-post" "producer changed during run"
    return 1
  }
  (( failed == 0 )) || {
    write_failure infrastructure "$phase" "heavy test failed; inspect retained log/runtime"
    return 1
  }
}

provenance_self_test() {
  local test_root ready worker executable resource worker_resource implementation producer
  local production_implementation raw_sha
  production_implementation="$(implementation_hashes)" || return 1
  jq -e 'has("Sources/HighQualityASRWorker.swift")
    and has("Tests/HighQualityASRWorkerTests.swift")' \
    <<<"$production_implementation" >/dev/null || return 1
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/adaptive-asr-118-provenance.XXXXXX")" \
    || return 1
  ready="$test_root/ready"; worker="$test_root/worker"; executable="$test_root/xctest"
  resource="$test_root/test.metallib"; worker_resource="$test_root/worker.metallib"
  printf ready >"$ready" || return 1
  printf worker >"$worker" || return 1
  chmod +x "$worker" || return 1
  printf xctest >"$executable" || return 1
  chmod +x "$executable" || return 1
  printf test-resource >"$resource" || return 1
  printf worker-resource >"$worker_resource" || return 1
  implementation='{"Sources/HighQualityASRWorker.swift":"same","Tests/HighQualityASRWorkerTests.swift":"same"}'
  producer="$(producer_snapshot "$ready" "$worker" "$executable" "$resource" \
    "$worker_resource" "$implementation")" || return 1
  printf raw >"$test_root/raw" || return 1
  raw_sha="$(checked_hash "$test_root/raw")" || return 1
  jq -n --arg raw "$raw_sha" --argjson producer "$producer" \
    '$producer + {schemaVersion:1,ticket:118,status:"recorded-at-execution",
      rawSHA256:$raw}' >"$test_root/provenance" || return 1
  local verify_fixture
  verify_fixture() {
    local actual fixture_raw_sha
    actual="$(producer_snapshot "$ready" "$worker" "$executable" "$resource" \
      "$worker_resource" "$implementation")" || return 1
    fixture_raw_sha="$(checked_hash "$test_root/raw")" || return 1
    jq -e --arg raw "$fixture_raw_sha" --argjson producer "$actual" \
      '.rawSHA256 == $raw and .readySHA256 == $producer.readySHA256
        and .workerSHA256 == $producer.workerSHA256
        and .implementationSHA256 == $producer.implementationSHA256
        and .testArtifact == $producer.testArtifact' "$test_root/provenance" >/dev/null
  }
  verify_fixture || return 1
  printf changed >>"$executable" || return 1
  ! verify_fixture || return 1
  printf xctest >"$executable" || return 1
  printf changed >>"$resource" || return 1
  ! verify_fixture || return 1
  printf test-resource >"$resource" || return 1
  printf changed >>"$worker_resource" || return 1
  ! verify_fixture || return 1
  printf worker-resource >"$worker_resource" || return 1
  printf changed >>"$worker" || return 1
  ! verify_fixture || return 1
  printf worker >"$worker" || return 1
  printf changed >>"$ready" || return 1
  ! verify_fixture || return 1
  printf ready >"$ready" || return 1
  implementation='{"Sources/HighQualityASRWorker.swift":"changed","Tests/HighQualityASRWorkerTests.swift":"same"}'
  ! verify_fixture || return 1
  implementation='{"Sources/HighQualityASRWorker.swift":"same","Tests/HighQualityASRWorkerTests.swift":"same"}'
  printf changed >>"$test_root/raw" || return 1
  ! verify_fixture || return 1
  ! checked_hash "$test_root/missing" >/dev/null 2>&1 || return 1
  ! checked_realpath "$test_root/missing" >/dev/null 2>&1 || return 1
  ( hash_file() { :; }; ! checked_hash "$ready" ) || return 1
  ( realpath() { :; }; ! checked_realpath "$ready" ) || return 1
  rm -rf "$test_root" || return 1
  echo "issue-118 provenance self-test: PASS"
}

fail_closed_control_self_test() {
  local test_root marker
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/adaptive-asr-118-control.XXXXXX")" \
    || return 1
  nonfinal_failure() { return 1; }
  ready_fixture() {
    : || return 1
    nonfinal_failure || return 1
    printf ready >"$test_root/ready" || return 1
  }
  full_fixture() {
    printf started >"$test_root/full-started" || return 1
    nonfinal_failure || return 1
    printf downstream >"$test_root/downstream" || return 1
  }
  holdout_fixture() {
    printf dev >"$test_root/dev" || return 1
    nonfinal_failure || return 1
    printf holdout >"$test_root/holdout" || return 1
  }
  ! ready_fixture || return 1
  ! full_fixture || return 1
  ! holdout_fixture || return 1
  for marker in ready downstream holdout; do
    [[ ! -e "$test_root/$marker" ]] || return 1
  done
  printf 'not-json' >"$test_root/invalid-state.json" || return 1
  write_failure harness fixture "fixture failure" "$test_root/invalid-state.json" \
    "$test_root/invalid-state-failure" || return 1
  jq -e '.stateProvenance == "invalid" and .holdoutOpened == null' \
    "$test_root/invalid-state-failure/failure.json" >/dev/null || return 1
  printf '{"holdoutOpened":false}' >"$test_root/valid-state.json" || return 1
  write_failure harness fixture "fixture failure" "$test_root/valid-state.json" \
    "$test_root/valid-state-failure" || return 1
  jq -e '.stateProvenance == "verified" and .holdoutOpened == false' \
    "$test_root/valid-state-failure/failure.json" >/dev/null || return 1
  printf 'not-json' >"$test_root/invalid-freeze.json" || return 1
  ! verify_json_hash "$test_root/missing-calibration" \
    "$test_root/invalid-freeze.json" calibrationSHA256 >/dev/null 2>&1 || return 1
  printf calibration >"$test_root/calibration" || return 1
  ! verify_json_hash "$test_root/calibration" \
    "$test_root/invalid-freeze.json" calibrationSHA256 >/dev/null 2>&1 || return 1
  printf '{"calibrationSHA256":""}' >"$test_root/empty-freeze.json" || return 1
  ! verify_json_hash "$test_root/calibration" \
    "$test_root/empty-freeze.json" calibrationSHA256 >/dev/null 2>&1 || return 1
  rm -rf "$test_root" || return 1
  echo "issue-118 non-final control fail-closed self-test: PASS"
}

prepare_controls() {
  mkdir -p "$ARTIFACTS/controls" "$DEV" || return 1
  python3 "$BASE_HARNESS" plan --audio "$(pcm_for qudu2fx3ncc)" \
    --manifest "$(manifest_for qudu2fx3ncc)" --role development \
    --output "$DEV/plan.json" || return 1
  xcrun swift build 2>&1 | tee "$ARTIFACTS/controls/build.log" || return 1
  env WHISPERASR_RUN_ADAPTIVE_117_PLAN=1 \
    WHISPERASR_ADAPTIVE_117_AUDIO="$(pcm_for qudu2fx3ncc)" \
    WHISPERASR_ADAPTIVE_117_PLAN="$DEV/plan.json" xcrun swift test --filter \
    'HighQualityAdaptiveASRTests|AdaptiveASR117BenchmarkTests|HighQualityASRWorkerTests/testJobManifestRetainsASRWorkerProvenanceAndPeakMemory|HighQualityJobTests/testEveryOfflineBackendUsesTheSameJobInterfaceAndWritesCompleteArtifacts|LiveCaptionTests/testAdaptiveIsTheDefaultAppleTranslationMode|LiveCaptionTests/testAppleTranslationModeReadinessRequirements' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log" || return 1
  python3 "$HARNESS" self-test | tee "$ARTIFACTS/controls/harness.log" || return 1
  [[ -f "$WORKER_RESOURCE" ]] || bash Scripts/build_mlx_metallib.sh debug || return 1
  [[ -x "$WORKER" ]] || return 1
  python3 Scripts/qwen_voice_music_harness.py run-command --timeout 5 \
    --log "$ARTIFACTS/controls/worker-probe.log" \
    --runtime "$ARTIFACTS/controls/worker-probe-runtime.json" -- \
    "$WORKER" --high-quality-asr-worker --probe || return 1
  grep -Fxq WHISPERASR_HIGH_QUALITY_ASR_WORKER_PROBE_OK \
    "$ARTIFACTS/controls/worker-probe.log" || return 1
  jq -e '.ticket == 117 and .corpusRole == "development" and .holdoutOpened == false
    and .algorithm.usesReference == false and (.segments | length) > 0
    and ([.segments[] | .endSample - .startSample] | max) <= 128000' \
    "$DEV/plan.json" >/dev/null || return 1
}

write_ready() {
  local free_disk total_ram implementation test_artifact worker_sha commit_sha plan_sha
  free_disk="$(df -k "$ROOT" | awk 'NR==2 {printf "%.0f", $4 * 1024}')" \
    || return 1
  total_ram="$(sysctl -n hw.memsize)" || return 1
  (( free_disk >= 20 * 1024 * 1024 * 1024 )) || return 1
  implementation="$(implementation_hashes)" || return 1
  test_artifact="$(test_artifact_evidence)" || return 1
  worker_sha="$(checked_hash "$WORKER")" || return 1
  commit_sha="$(git rev-parse HEAD)" || return 1
  [[ -n "$commit_sha" ]] || return 1
  plan_sha="$(checked_hash "$DEV/plan.json")" || return 1
  jq -n \
    --arg command 'BENCHMARK_SLOT_GRANTED=118 bash Scripts/run_adaptive_asr_118.sh full' \
    --arg commit "$commit_sha" --arg plan "$plan_sha" \
    --arg workerSHA "$worker_sha" --argjson implementation "$implementation" \
    --argjson testArtifact "$test_artifact" --argjson freeDisk "$free_disk" \
    --argjson totalRAM "$total_ram" \
    '{status:"READY_FOR_HEAVY_BENCHMARK",ticket:118,heavyRunsLaunched:0,
      command:$command,baseCommit:"98f4ccd8bf6dcd1cb98e10554f9153074357debf",
      workingCommit:$commit,corpora:{development:"qudu2fx3ncc",
        holdout:"md62mmdz0m",holdoutOpened:false},
      sequence:["hash-verify and reuse the 175.817-second Qwen→Parakeet DEV control",
        "WhisperKit only on short unresolved material disagreements",
        "five-block DEV calibration and incremental Japanese gates",
        "one selected alignment and TranslateGemma translation",
        "open untouched holdout only after every DEV gate"],
      estimate:{devDecisionMinutes:8,typicalMinutesIfDownstreamRuns:175,
        hardTimeoutMinutes:300,
        peakASRRAMGiB:14,peakWorkflowRAMGiB:18,incrementalDiskGiB:3,
        freeDiskBytes:$freeDisk,totalRAMBytes:$totalRAM},
      resume:{reusesDevelopmentQwenParakeet:true,
        reusedControlSeconds:175.817,reusedControlSHA256:
          "b5ad7af5db17f8595edd78dcdd4668ec4ab2c2bdc0c5a82889798323d28ee577",
        nextHeavyStage:"DEV WhisperKit targeted segments only"},
      models:["Qwen3-ASR-1.7B-JA-MLX-8bit","Parakeet 0.6B JA CoreML",
        "WhisperKit large-v3 CoreML","Qwen3 ForcedAligner 0.6B 4bit",
        "TranslateGemma 12B 4bit"],
      gates:["runtime-only independent Qwen weakness plus material Qwen/Parakeet disagreement",
        "3-8 second complete hypotheses; no long-window #95 regression",
        "Qwen then Parakeet then WhisperKit; no worker overlap",
        "WhisperKit execution rate below 25%",
        "stable five-block DEV calibration and one frozen margin",
        "incremental Japanese gain >=1% over Qwen→Parakeet",
        "no new empty/duplicate turns or number/term/meaning loss",
        "ASR cost <=5x standard Qwen; ASR peak <=14 GiB",
        "one alignment and one translation; English chrF++ non-regression"],
      implementationSHA256:$implementation,workerSHA256:$workerSHA,
      testArtifact:$testArtifact,developmentPlanSHA256:$plan}' >"$READY.tmp" || return 1
  mv "$READY.tmp" "$READY" || return 1
}

run_base_asr() {
  local split="$1" corpus="$2" directory="$3" raw provenance producer
  raw="$directory/base-run.json"
  provenance="$directory/base-run-provenance.json"
  if [[ -e "$raw" ]]; then
    verify_raw_provenance "$raw" "$provenance" || {
      write_failure harness "$split-base-reuse" "base raw provenance differs"
      return 1
    }
    return 0
  fi
  if [[ "$split" == development ]]; then
    reuse_archived_development_base || {
      write_failure harness development-base-reuse \
        "archived Qwen→Parakeet control failed compatibility checks"
      return 1
    }
    echo "Reused hash-compatible DEV Qwen→Parakeet control (175.817 s)"
    return 0
  fi
  producer="$(producer_snapshot)" || return 1
  run_heavy_test "$split-base-asr" 3000 "$directory/base-asr.log" \
    "$directory/base-asr-runtime.json" env BENCHMARK_SLOT_GRANTED=118 \
      WHISPERASR_ADAPTIVE_117_BASE_FOR_118=1 WHISPERASR_RUN_ADAPTIVE_117_ASR=1 \
      WHISPERASR_ADAPTIVE_117_AUDIO="$(pcm_for "$corpus")" \
      WHISPERASR_ADAPTIVE_117_PLAN="$directory/plan.json" \
      WHISPERASR_ADAPTIVE_117_RUN="$raw" \
      WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
      xcrun swift test --skip-build \
        --filter AdaptiveASR117BenchmarkTests/testIssue117RawASRWhenOptedIn \
    || return 1
  write_raw_provenance "$raw" "$provenance" "$producer" || {
    write_failure harness "$split-base-provenance" "base producer changed"
    return 1
  }
}

run_whisperkit() {
  local split="$1" corpus="$2" directory="$3" raw provenance producer
  raw="$directory/run.json"
  provenance="$directory/run-provenance.json"
  if [[ -e "$raw" ]]; then
    verify_raw_provenance "$raw" "$provenance" || {
      write_failure harness "$split-whisperkit-reuse" "WhisperKit raw provenance differs"
      return 1
    }
    return 0
  fi
  producer="$(producer_snapshot)" || return 1
  run_heavy_test "$split-whisperkit" 1800 "$directory/whisperkit.log" \
    "$directory/whisperkit-runtime.json" env BENCHMARK_SLOT_GRANTED=118 \
      WHISPERASR_RUN_ADAPTIVE_118_WHISPERKIT=1 \
      WHISPERASR_ADAPTIVE_118_AUDIO="$(pcm_for "$corpus")" \
      WHISPERASR_ADAPTIVE_118_PLAN="$directory/plan.json" \
      WHISPERASR_ADAPTIVE_118_BASE_RUN="$directory/base-run.json" \
      WHISPERASR_ADAPTIVE_118_PARAKEET_CALIBRATION="$P_CALIBRATION" \
      WHISPERASR_ADAPTIVE_118_RUN="$raw" \
      WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
      xcrun swift test --skip-build \
        --filter AdaptiveASR117BenchmarkTests/testIssue118TargetedWhisperKitWhenOptedIn \
    || return 1
  write_raw_provenance "$raw" "$provenance" "$producer" || {
    write_failure harness "$split-whisperkit-provenance" "WhisperKit producer changed"
    return 1
  }
}

calibrate_parakeet_control() {
  python3 "$BASE_HARNESS" calibrate --plan "$DEV/plan.json" \
    --run "$DEV/base-run.json" --manifest "$(manifest_for qudu2fx3ncc)" \
    --character-alignment "$(alignment_for qudu2fx3ncc)" --e23 "$E23" \
    --baseline-raw "$(baseline_job qudu2fx3ncc)/raw-asr.json" \
    --baseline-manifest "$(baseline_job qudu2fx3ncc)/manifest.json" \
    --calibration "$P_CALIBRATION" --report "$DEV/parakeet-calibration-report.json" \
    || return 1
  jq -e '.stableAcrossBlocks == false and .parakeet.stable == false' \
    "$P_CALIBRATION" >/dev/null || return 1
}

calibrate_whisperkit() {
  python3 "$HARNESS" calibrate --plan "$DEV/plan.json" --run "$DEV/run.json" \
    --base-run "$DEV/base-run.json" --parakeet-calibration "$P_CALIBRATION" \
    --manifest "$(manifest_for qudu2fx3ncc)" \
    --character-alignment "$(alignment_for qudu2fx3ncc)" --e23 "$E23" \
    --baseline-manifest "$(baseline_job qudu2fx3ncc)/manifest.json" \
    --calibration "$CALIBRATION" --report "$DEV/calibration-report.json" || return 1
}

run_downstream() {
  local split="$1" corpus="$2" directory="$3" job_id="$4"
  [[ ! -d "$directory/jobs/$job_id" ]] || {
    write_failure harness "$split-downstream" "refusing to overwrite downstream evidence"
    return 1
  }
  run_heavy_test "$split-downstream" 9000 "$directory/downstream.log" \
    "$directory/downstream-runtime.json" env BENCHMARK_SLOT_GRANTED=118 \
      WHISPERASR_RUN_ADAPTIVE_118_DOWNSTREAM=1 \
      WHISPERASR_ADAPTIVE_118_AUDIO="$(pcm_for "$corpus")" \
      WHISPERASR_ADAPTIVE_118_PLAN="$directory/plan.json" \
      WHISPERASR_ADAPTIVE_118_RUN="$directory/run.json" \
      WHISPERASR_ADAPTIVE_118_CALIBRATION="$CALIBRATION" \
      WHISPERASR_ADAPTIVE_118_OUTPUT="$directory/jobs" \
      WHISPERASR_ADAPTIVE_118_JOB_ID="$job_id" \
      WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
      xcrun swift test --skip-build \
        --filter AdaptiveASR117BenchmarkTests/testIssue118SelectedDownstreamWhenOptedIn \
    || return 1
}

score_split() {
  local split="$1" corpus="$2" directory="$3" job_id="$4"
  python3 "$HARNESS" score --split "$split" --plan "$directory/plan.json" \
    --run "$directory/run.json" --base-run "$directory/base-run.json" \
    --parakeet-calibration "$P_CALIBRATION" --manifest "$(manifest_for "$corpus")" \
    --character-alignment "$(alignment_for "$corpus")" --e23 "$E23" \
    --baseline-raw "$(baseline_job "$corpus")/raw-asr.json" \
    --calibration "$CALIBRATION" \
    --candidate-raw "$directory/jobs/$job_id/raw-asr.json" \
    --candidate-manifest "$directory/jobs/$job_id/manifest.json" \
    --output "$directory/score.json" || return 1
}

preflight() {
  mkdir -p "$ARTIFACTS" || return 1
  if [[ -e "$DEV/base-run.json" || -e "$DEV/run.json" ]]; then
    write_failure harness preflight-existing-raw \
      "refusing to replace READY while historical DEV raw evidence exists"
    return 1
  fi
  verify_development_inputs || {
    write_failure harness preflight-inputs "frozen DEV inputs failed"
    return 1
  }
  verify_models || {
    write_failure infrastructure preflight-models "pinned model weights unavailable"
    return 1
  }
  prepare_controls || {
    write_failure infrastructure preflight-controls "light controls failed"
    return 1
  }
  verify_archived_development_base || {
    write_failure harness preflight-base-reuse \
      "archived Qwen→Parakeet control is not hash-compatible"
    return 1
  }
  write_ready || return 1
  producer_snapshot >"$PRODUCER" || return 1
  jq -n '{ticket:118,phase:"ready",holdoutOpened:false,heavyRunsLaunched:0}' >"$STATE" \
    || return 1
  echo "READY_FOR_HEAVY_BENCHMARK #118"
  jq '{command,estimate,models,gates}' "$READY" || return 1
}

full() {
  verify_development_inputs || {
    write_failure harness full-inputs "frozen DEV inputs changed"
    return 1
  }
  verify_models || {
    write_failure infrastructure full-models "pinned model weights unavailable"
    return 1
  }
  verify_ready || {
    write_failure harness full-ready "implementation or READY provenance changed"
    return 1
  }
  jq '.phase="development-asr" | .heavyRunsLaunched=1' "$STATE" >"$STATE.tmp" \
    || return 1
  mv "$STATE.tmp" "$STATE" || return 1
  run_base_asr development qudu2fx3ncc "$DEV" || return 1
  calibrate_parakeet_control || return 1
  if ! jq -e '.stableAcrossBlocks == true and .qwen.stable == true
      and .parakeet.stable == true and .whisperKit.stable == true' \
      "$P_CALIBRATION" >/dev/null; then
    jq -n '{ticket:118,decision:"RETAIN-HIDDEN",holdoutOpened:false,
      route:"candidate",development:{decision:"NO-GO-STOP-BEFORE-WHISPERKIT",
      reason:"no frozen stable product launch calibration"}}' >"$FINAL" || return 1
    jq '.phase="development-launch-calibration-no-go"' "$STATE" >"$STATE.tmp" \
      || return 1
    mv "$STATE.tmp" "$STATE" || return 1
    return 0
  fi
  run_whisperkit development qudu2fx3ncc "$DEV" || return 1
  calibrate_whisperkit || return 1
  if ! jq -e '.decision == "DEV-JA-PASS" and ([.gates[]] | all)' \
      "$DEV/calibration-report.json" >/dev/null; then
    jq -n --slurpfile development "$DEV/calibration-report.json" \
      '{ticket:118,decision:"RETAIN-HIDDEN",holdoutOpened:false,
        route:"candidate",development:$development[0]}' >"$FINAL" || return 1
    jq '.phase="development-ja-no-go"' "$STATE" >"$STATE.tmp" || return 1
    mv "$STATE.tmp" "$STATE" || return 1
    return 0
  fi
  run_downstream development qudu2fx3ncc "$DEV" \
    11800001-0000-4000-8000-000000000001 || return 1
  score_split development qudu2fx3ncc "$DEV" \
    11800001-0000-4000-8000-000000000001 || return 1
  if ! jq -e '.decision == "PASS" and ([.gates[]] | all)' "$DEV/score.json" >/dev/null; then
    jq -n --slurpfile development "$DEV/score.json" \
      '{ticket:118,decision:"RETAIN-HIDDEN",holdoutOpened:false,
        route:"candidate",development:$development[0]}' >"$FINAL" || return 1
    jq '.phase="development-downstream-no-go"' "$STATE" >"$STATE.tmp" || return 1
    mv "$STATE.tmp" "$STATE" || return 1
    return 0
  fi
  local calibration_sha p_calibration_sha development_sha implementation
  calibration_sha="$(checked_hash "$CALIBRATION")" || return 1
  p_calibration_sha="$(checked_hash "$P_CALIBRATION")" || return 1
  development_sha="$(checked_hash "$DEV/score.json")" || return 1
  implementation="$(implementation_hashes)" || return 1
  [[ -n "$implementation" ]] || return 1
  jq -n --arg calibrationSHA256 "$calibration_sha" \
    --arg pCalibrationSHA256 "$p_calibration_sha" \
    --arg developmentSHA256 "$development_sha" \
    --argjson implementation "$implementation" \
    '{ticket:118,status:"DEV-FROZEN-BEFORE-HOLDOUT",oneVariable:"WhisperKit third pass",
      calibrationSHA256:$calibrationSHA256,
      parakeetCalibrationSHA256:$pCalibrationSHA256,
      developmentScoreSHA256:$developmentSHA256,
      implementationSHA256:$implementation}' >"$DEV/freeze.json" || return 1
  jq '.phase="holdout-opened" | .holdoutOpened=true' "$STATE" >"$STATE.tmp" \
    || return 1
  mv "$STATE.tmp" "$STATE" || return 1
  verify_holdout_inputs || {
    write_failure harness holdout-inputs "frozen holdout integrity failed"
    return 1
  }
  mkdir -p "$HOLDOUT" || return 1
  python3 "$BASE_HARNESS" plan --audio "$(pcm_for md62mmdz0m)" \
    --manifest "$(manifest_for md62mmdz0m)" --role untouched-holdout \
    --output "$HOLDOUT/plan.json" || return 1
  run_base_asr holdout md62mmdz0m "$HOLDOUT" || return 1
  verify_json_hash "$P_CALIBRATION" "$DEV/freeze.json" \
    parakeetCalibrationSHA256 || return 1
  verify_json_hash "$CALIBRATION" "$DEV/freeze.json" calibrationSHA256 || return 1
  run_whisperkit holdout md62mmdz0m "$HOLDOUT" || return 1
  run_downstream holdout md62mmdz0m "$HOLDOUT" \
    11800002-0000-4000-8000-000000000001 || return 1
  score_split holdout md62mmdz0m "$HOLDOUT" \
    11800002-0000-4000-8000-000000000001 || return 1
  python3 "$HARNESS" final --development "$DEV/score.json" \
    --holdout "$HOLDOUT/score.json" --output "$FINAL" || return 1
  jq '.phase="completed"' "$STATE" >"$STATE.tmp" || return 1
  mv "$STATE.tmp" "$STATE" || return 1
}

if [[ "$MODE" == self-test ]]; then
  provenance_self_test || exit 1
  fail_closed_control_self_test || exit 1
elif [[ "$MODE" == preflight ]]; then
  preflight || exit 1
else
  full || exit 1
fi
