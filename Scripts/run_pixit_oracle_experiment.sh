#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-preflight}"
ARTIFACTS="${WHISPERASR_PIXIT_ROOT:-$ROOT/.build/benchmarks/pixit-oracle-101}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
MANIFEST="$ROOT/docs/japanese-live/corpora/qudu2fx3ncc/manifest.json"
AUDIO="${WHISPERASR_PIXIT_DEV_AUDIO:-$FROZEN_REPO/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/audio-16k-mono.wav}"
SPEAKER_MAP="${WHISPERASR_PIXIT_DEV_SPEAKER_MAP:-$FROZEN_REPO/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/speaker-map.json}"
PLAN="$ARTIFACTS/plan.json"
VENV="$ARTIFACTS/python-3.11"
PYTHON="${WHISPERASR_PIXIT_PYTHON:-/opt/homebrew/bin/python3.11}"
WORKER="${WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE:-$ROOT/.build/debug/WhisperASR}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swiftpm-module-cache}"
PHASE="startup"

write_failure() {
  local status="$1"
  jq -n --arg phase "$PHASE" --argjson status "$status" \
    '{ticket:101,status:"failed",classification:$phase,exitStatus:$status,
      candidateVerdict:"not-assigned",holdoutOpened:false}' >"$ARTIFACTS/failure.json" 2>/dev/null || true
}

failure_artifact() {
  local status="$?"
  write_failure "$status"
  exit "$status"
}

fail() {
  write_failure 1
  exit 1
}
trap failure_artifact ERR

case "$MODE" in preflight|smoke|development) ;; *) echo "usage: $0 [preflight|smoke|development]" >&2; exit 2 ;; esac
[[ "$MODE" == preflight || "${BENCHMARK_SLOT_GRANTED:-}" == "101" ]] || {
  echo "Refusing heavyweight #101 run without BENCHMARK_SLOT_GRANTED=101" >&2
  exit 2
}
cd "$ROOT"
mkdir -p "$ARTIFACTS" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

preflight() {
  rm -f "$ARTIFACTS/failure.json"
  PHASE="input-and-reference"
  [[ -x "$PYTHON" && -f "$AUDIO" && -f "$SPEAKER_MAP" ]] || fail
  PHASE="runner"
  "$PYTHON" Scripts/test_pixit_oracle.py
  PHASE="input-and-reference"
  "$PYTHON" Scripts/pixit_oracle.py plan --manifest "$MANIFEST" --audio "$AUDIO" \
    --speaker-map "$SPEAKER_MAP" --output "$PLAN"
  PHASE="build"
  xcrun swift test --filter HighQualityAcceptanceTests/testPixITOracleQwenSourcesWhenOptedIn \
    2>&1 | tee "$ARTIFACTS/preflight-swift.log"
  bash Scripts/build_mlx_metallib.sh debug 2>&1 | tee "$ARTIFACTS/preflight-mlx.log"
  jq -n \
    --arg commit "$(git rev-parse HEAD)" \
    --arg base "$(git rev-parse codex/issue-86-frontier-base)" \
    --arg plan "$(shasum -a 256 "$PLAN" | awk '{print $1}')" \
    --arg speakerMap "$(shasum -a 256 "$SPEAKER_MAP" | awk '{print $1}')" \
    --arg runner "$(shasum -a 256 Scripts/pixit_oracle.py | awk '{print $1}')" \
    --arg qwen "$(shasum -a 256 Tests/HighQualityAcceptanceTests.swift | awk '{print $1}')" \
    --arg mlx "$(shasum -a 256 .build/debug/mlx.metallib | awk '{print $1}')" \
    --arg live "$(shasum -a 256 Sources/AppleLiveServices.swift | awk '{print $1}')" \
    '{ticket:101,scope:"development-oracle-only",commit:$commit,requiredBase:$base,
      planSHA256:$plan,speakerMapSHA256:$speakerMap,
      implementationSHA256:{"Scripts/pixit_oracle.py":$runner,
      "Tests/HighQualityAcceptanceTests.swift":$qwen},mlxMetallibSHA256:$mlx,
      liveImplementationSHA256:$live,
      lightTestsPassed:true,holdoutOpened:false}' >"$ARTIFACTS/preflight.json"
}

install_runtime() {
  PHASE="runtime-preparation"
  if [[ ! -x "$VENV/bin/python" ]]; then
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --disable-pip-version-check --upgrade \
      pip==24.2 setuptools==70.3.0 wheel==0.44.0
    "$VENV/bin/python" -m pip install --disable-pip-version-check \
      -r Scripts/pixit-oracle-requirements.txt
  fi
  "$VENV/bin/python" -m pip freeze >"$ARTIFACTS/python-freeze.txt"
}

run_stage() {
  local stage="$1" window_id="${2:-}" directory="$ARTIFACTS/$1"
  [[ -f "$ARTIFACTS/preflight.json" && -f "$PLAN" ]]
  install_runtime
  mkdir -p "$directory/separator" "$directory/qwen"
  local window_args=()
  [[ -z "$window_id" ]] || window_args=(--window-id "$window_id")
  PHASE="separator-runner"
  "$VENV/bin/python" Scripts/pixit_oracle.py separate \
    --plan "$PLAN" --output "$directory/separator" --cache "$ARTIFACTS/model-cache" \
    --stage "$stage" "${window_args[@]}" 2>&1 | tee "$directory/pixit.log"
  PHASE="qwen-runner"
  WHISPERASR_RUN_PIXIT_ORACLE_QWEN=1 \
  WHISPERASR_PIXIT_SEPARATOR_EVIDENCE="$directory/separator/separator-evidence.json" \
  WHISPERASR_PIXIT_QWEN_EVIDENCE="$directory/qwen/evidence.json" \
  WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testPixITOracleQwenSourcesWhenOptedIn \
      2>&1 | tee "$directory/qwen.log"
  PHASE="reporter"
  "$PYTHON" Scripts/pixit_oracle.py report \
    --plan "$PLAN" --separator "$directory/separator/separator-evidence.json" \
    --qwen "$directory/qwen/evidence.json" --stage "$stage" \
    --output "$directory/report.json"
}

case "$MODE" in
  preflight) preflight ;;
  smoke)
    preflight
    run_stage smoke window-02
    ;;
  development)
    jq -e '.gates.rawArtifactsVerified and .gates.workersSequential and
      .gates.developmentOnly and (.gates.holdoutOpened | not)' \
      "$ARTIFACTS/smoke/report.json" >/dev/null
    run_stage development
    ;;
esac
