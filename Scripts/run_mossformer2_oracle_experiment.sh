#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-preflight}"
ARTIFACTS="${WHISPERASR_MOSSFORMER2_ROOT:-$ROOT/.build/benchmarks/mossformer2-oracle-102}"
PIXIT_ROOT="${WHISPERASR_PIXIT_EVIDENCE_ROOT:-/Users/maz/.codex/worktrees/8f26/whisperASR/.build/benchmarks/pixit-oracle-101}"
PLAN="$PIXIT_ROOT/plan.json"
PIXIT_PYTHON="$PIXIT_ROOT/python-3.11/bin/python"
VENV="$ARTIFACTS/python-3.11"
PYTHON="${WHISPERASR_MOSSFORMER2_PYTHON:-/opt/homebrew/bin/python3.11}"
CLEARVOICE="$ARTIFACTS/runtime/ClearerVoice-Studio"
RUNTIME_ROOT="$ARTIFACTS/runtime"
MODEL_DIR="$RUNTIME_ROOT/checkpoints/MossFormer2_SS_16K"
MODEL="$MODEL_DIR/last_best_checkpoint.pt"
WORKER="${WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE:-$ROOT/.build/debug/WhisperASR}"
CLEARVOICE_REVISION="6b3774dc79c46ae8bed2a4fa5f706f0ac8c75c61"
MODEL_REVISION="407cb030cd66340918ebb6c8cc63b18f8592cdbe"
MODEL_SHA256="00a3a48bda492db1e829b85dd443f8f43a43039a3e90f1a24962ea9caf14a11a"
MODEL_SIZE=670353271
MOSS_RSS_LIMIT_BYTES=8589934592
MIN_FREE_MEMORY_PERCENT=10
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swiftpm-module-cache}"
PHASE="startup"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

write_failure() {
  mkdir -p "$ARTIFACTS"
  jq -n --arg phase "$PHASE" --arg status "$1" \
    '{ticket:102,status:"failed",classification:$phase,detail:$status,
      candidateVerdict:"not-assigned",holdoutOpened:false}' \
    >"$ARTIFACTS/failure.json" 2>/dev/null || true
}

failure_artifact() {
  local status="$?"
  write_failure "exit-$status"
  exit "$status"
}
trap failure_artifact ERR

fail() {
  write_failure "$1"
  exit 1
}

terminate_tree() {
  local process="$1" child children
  children="$(pgrep -P "$process" 2>/dev/null || true)"
  for child in $children; do terminate_tree "$child"; done
  kill -TERM "$process" 2>/dev/null || true
}

kill_tree() {
  local process="$1" child children
  children="$(pgrep -P "$process" 2>/dev/null || true)"
  for child in $children; do kill_tree "$child"; done
  kill -KILL "$process" 2>/dev/null || true
}

run_guarded() {
  local safety="$1" log="$2" timeout_seconds="$3" rss_limit="$4"
  shift 4
  local started started_iso process reason="completed" peak_rss=0 min_free=100
  local elapsed rss_kb rss_bytes free status exited_iso
  started="$(date +%s)"
  started_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  "$@" >"$log" 2>&1 &
  process="$!"
  while kill -0 "$process" 2>/dev/null; do
    elapsed="$(($(date +%s) - started))"
    rss_kb="$(ps -o rss= -p "$process" | awk '{print $1 + 0}')"
    rss_bytes="$((rss_kb * 1024))"
    ((rss_bytes > peak_rss)) && peak_rss="$rss_bytes"
    free="$(/usr/bin/memory_pressure -Q | awk -F': |%' '/free percentage/ {print $2}')"
    if [[ -z "$free" ]]; then
      reason="memory-pressure-sampling-failed"
    elif ((free < min_free)); then
      min_free="$free"
    fi
    if [[ "$reason" == completed && "$rss_limit" != 0 ]] && ((rss_bytes > rss_limit)); then
      reason="rss-limit"
    fi
    if [[ "$reason" == completed ]] && ((free <= MIN_FREE_MEMORY_PERCENT)); then
      reason="memory-pressure"
    fi
    if [[ "$reason" == completed ]] && ((elapsed >= timeout_seconds)); then
      reason="timeout"
    fi
    if [[ "$reason" != completed ]]; then
      terminate_tree "$process"
      sleep 5
      kill_tree "$process"
      break
    fi
    sleep 1
  done
  set +e
  wait "$process"
  status="$?"
  set -e
  exited_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg startedAt "$started_iso" --arg exitedAt "$exited_iso" --arg reason "$reason" \
    --argjson elapsedSeconds "$(($(date +%s) - started))" \
    --argjson timeoutSeconds "$timeout_seconds" --argjson rssLimitBytes "$rss_limit" \
    --argjson peakResidentBytes "$peak_rss" --argjson minimumFreeMemoryPercent "$min_free" \
    --argjson exitStatus "$status" \
    '{startedAt:$startedAt,exitedAt:$exitedAt,elapsedSeconds:$elapsedSeconds,
      timeoutSeconds:$timeoutSeconds,rssLimitBytes:$rssLimitBytes,
      peakResidentBytes:$peakResidentBytes,minimumFreeMemoryPercent:$minimumFreeMemoryPercent,
      stopReason:$reason,exitStatus:$exitStatus}' >"$safety"
  [[ "$reason" == completed && "$status" == 0 ]]
}

case "$MODE" in preflight|smoke|development) ;; *)
  echo "usage: $0 [preflight|smoke|development]" >&2
  exit 2
esac
[[ "$MODE" == preflight || "${BENCHMARK_SLOT_GRANTED:-}" == 102 ]] || {
  echo "Refusing heavyweight #102 run without BENCHMARK_SLOT_GRANTED=102" >&2
  exit 2
}
cd "$ROOT"
mkdir -p "$ARTIFACTS" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

verify_pixit_inputs() {
  [[ -f "$PLAN" ]] || fail "missing-ticket-101-plan"
  [[ "$(sha256 "$PLAN")" == 7c8db9dd527302aa7d610621ce255ff702e50da8d11f806ea073e24ca8f9147c ]] \
    || fail "ticket-101-plan-hash"
  [[ "$(sha256 "$PIXIT_ROOT/smoke/report.json")" == 38f47e9eba4e0a9c6a36fa6dab248e6efaef8353c15d0848b374da96d9fdc24c ]] \
    || fail "ticket-101-smoke-report-hash"
  [[ "$(sha256 "$PIXIT_ROOT/development/report.json")" == a8b204189c300b73ea26a157bd5ffeb0ced700c7095277309a8f92472c57b9b9 ]] \
    || fail "ticket-101-development-report-hash"
  [[ "$(sha256 "$PIXIT_ROOT/smoke/separator/separator-evidence.json")" == 0b4ad0f5277936f28fa14c6d28abd488d915d39280f40208645897dec1a5ca5a ]] \
    || fail "ticket-101-smoke-separator-hash"
  [[ "$(sha256 "$PIXIT_ROOT/development/separator/separator-evidence.json")" == d34d404c85c74f7781ead048a70c9572810846e7f49964f1f1b4c3b9c23d5e35 ]] \
    || fail "ticket-101-development-separator-hash"
}

preflight() {
  PHASE="preflight"
  verify_pixit_inputs
  command -v jq >/dev/null || fail "missing-jq"
  command -v curl >/dev/null || fail "missing-curl"
  command -v pgrep >/dev/null || fail "missing-pgrep"
  [[ -x "$PYTHON" ]] || fail "missing-python-3.11"
  [[ -x "$PIXIT_PYTHON" ]] || fail "missing-ticket-101-python-runtime"
  "$PYTHON" Scripts/test_pixit_oracle.py
  "$PIXIT_PYTHON" Scripts/test_mossformer2_oracle.py
  bash -n Scripts/run_mossformer2_oracle_experiment.sh
  xcrun swift test --filter HighQualityAcceptanceTests/testPixITOracleQwenSourcesWhenOptedIn \
    2>&1 | tee "$ARTIFACTS/preflight-swift.log"
  bash Scripts/build_mlx_metallib.sh debug 2>&1 | tee "$ARTIFACTS/preflight-mlx.log"
  jq -n \
    --arg commit "$(git rev-parse HEAD)" \
    --arg planSHA256 "$(sha256 "$PLAN")" \
    --arg runnerSHA256 "$(sha256 Scripts/mossformer2_oracle.py)" \
    --arg scorerSHA256 "$(sha256 Scripts/pixit_oracle.py)" \
    --arg qwenSHA256 "$(sha256 Tests/HighQualityAcceptanceTests.swift)" \
    --arg mlxSHA256 "$(sha256 .build/debug/mlx.metallib)" \
    --arg priorProofSHA256 "$(sha256 docs/japanese-live/experiments/evidence/issue-102-no-run.json)" \
    '{schemaVersion:1,ticket:102,status:"READY_FOR_HEAVY_BENCHMARK",stage:"SMOKE",
      commit:$commit,scope:"development-oracle-only",planSHA256:$planSHA256,
      implementationSHA256:{runner:$runnerSHA256,sharedScorer:$scorerSHA256,qwen:$qwenSHA256},
      mlxMetallibSHA256:$mlxSHA256,priorProofSHA256:$priorProofSHA256,
      modelRunsLaunched:0,holdoutOpened:false}' >"$ARTIFACTS/preflight.json"
}

install_runtime() {
  PHASE="runtime-preparation"
  if [[ ! -x "$VENV/bin/python" ]]; then
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --disable-pip-version-check --upgrade \
      pip==24.2 setuptools==70.3.0 wheel==0.44.0
    "$VENV/bin/python" -m pip install --disable-pip-version-check \
      -r Scripts/mossformer2-oracle-requirements.txt
  fi
  if [[ ! -d "$CLEARVOICE/.git" ]]; then
    git clone --filter=blob:none --no-checkout \
      https://github.com/modelscope/ClearerVoice-Studio.git "$CLEARVOICE"
  fi
  git -C "$CLEARVOICE" cat-file -e "$CLEARVOICE_REVISION^{commit}" 2>/dev/null \
    || git -C "$CLEARVOICE" fetch origin "$CLEARVOICE_REVISION"
  git -C "$CLEARVOICE" checkout --detach "$CLEARVOICE_REVISION"
  [[ "$(git -C "$CLEARVOICE" rev-parse HEAD)" == "$CLEARVOICE_REVISION" ]] \
    || fail "clearvoice-revision"
  [[ -z "$(git -C "$CLEARVOICE" status --porcelain --untracked-files=no)" ]] \
    || fail "clearvoice-dirty"
  "$VENV/bin/python" -m pip install --disable-pip-version-check --no-deps \
    --editable "$CLEARVOICE/clearvoice"
  "$VENV/bin/python" -m pip freeze >"$ARTIFACTS/python-freeze.txt"
}

prepare_model() {
  PHASE="model-preparation"
  mkdir -p "$MODEL_DIR"
  if [[ ! -f "$MODEL_DIR/last_best_checkpoint" ]]; then
    curl -fL --retry 2 --max-time 60 \
      "https://huggingface.co/alibabasglab/MossFormer2_SS_16K/resolve/$MODEL_REVISION/last_best_checkpoint" \
      -o "$MODEL_DIR/last_best_checkpoint.part"
    [[ "$(sha256 "$MODEL_DIR/last_best_checkpoint.part")" == 315744c841441f8831cb2f896e06102b4d864776bf272febaa30c639c903e1c0 ]] \
      || fail "checkpoint-marker-hash"
    mv "$MODEL_DIR/last_best_checkpoint.part" "$MODEL_DIR/last_best_checkpoint"
  fi
  if [[ ! -f "$MODEL" ]]; then
    curl -fL --retry 2 --max-time 1200 \
      "https://huggingface.co/alibabasglab/MossFormer2_SS_16K/resolve/$MODEL_REVISION/last_best_checkpoint.pt" \
      -o "$MODEL.part"
    [[ "$(sha256 "$MODEL.part")" == "$MODEL_SHA256" ]] || fail "model-download-hash"
    mv "$MODEL.part" "$MODEL"
  fi
  [[ "$(stat -f %z "$MODEL")" == "$MODEL_SIZE" && "$(sha256 "$MODEL")" == "$MODEL_SHA256" ]] \
    || fail "model-cache-hash"
}

run_stage() {
  local stage="$1" window_id="${2:-}" directory="$ARTIFACTS/$stage"
  local pixit_separator="$PIXIT_ROOT/$stage/separator/separator-evidence.json"
  local pixit_report="$PIXIT_ROOT/$stage/report.json"
  local moss_timeout=1800 qwen_timeout=1200
  [[ "$stage" == smoke ]] && moss_timeout=600
  [[ ! -e "$directory" ]] || fail "$stage-artifacts-already-exist"
  mkdir -p "$directory"
  install_runtime
  prepare_model
  local window_args=()
  [[ -z "$window_id" ]] || window_args=(--window-id "$window_id")
  PHASE="mossformer2-$stage"
  run_guarded "$directory/moss-safety.json" "$directory/moss.log" \
    "$moss_timeout" "$MOSS_RSS_LIMIT_BYTES" \
    "$VENV/bin/python" Scripts/mossformer2_oracle.py separate \
      --plan "$PLAN" --pixit-separator "$pixit_separator" \
      --clearvoice-source "$CLEARVOICE" --runtime-root "$RUNTIME_ROOT" --model "$MODEL" \
      --output "$directory/separator" --stage "$stage" \
      ${window_args[@]+"${window_args[@]}"}
  cat "$directory/moss.log"
  PHASE="qwen-$stage"
  mkdir -p "$directory/qwen"
  run_guarded "$directory/qwen-safety.json" "$directory/qwen.log" \
    "$qwen_timeout" 0 env \
      WHISPERASR_RUN_PIXIT_ORACLE_QWEN=1 \
      WHISPERASR_PIXIT_SEPARATOR_EVIDENCE="$directory/separator/separator-evidence.json" \
      WHISPERASR_PIXIT_QWEN_EVIDENCE="$directory/qwen/evidence.json" \
      WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="$WORKER" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testPixITOracleQwenSourcesWhenOptedIn
  cat "$directory/qwen.log"
  PHASE="report-$stage"
  "$PYTHON" Scripts/mossformer2_oracle.py report \
    --plan "$PLAN" --separator "$directory/separator/separator-evidence.json" \
    --qwen "$directory/qwen/evidence.json" --stage "$stage" \
    --output "$directory/report.json"
  "$PYTHON" Scripts/mossformer2_oracle.py compare \
    --plan "$PLAN" --pixit-report "$pixit_report" --moss-report "$directory/report.json" \
    --moss-safety "$directory/moss-safety.json" --qwen-safety "$directory/qwen-safety.json" \
    --stage "$stage" --output "$directory/comparison.json"
}

case "$MODE" in
  preflight)
    rm -f "$ARTIFACTS/failure.json"
    preflight
    ;;
  smoke)
    preflight
    run_stage smoke window-02
    ;;
  development)
    [[ "$(jq -r '.decision.status' "$ARTIFACTS/smoke/comparison.json")" \
      == SMOKE_PASSED_READY_FOR_DEVELOPMENT ]] || fail "smoke-gate"
    run_stage development
    ;;
esac
