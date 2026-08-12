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
MIN_FREE_MEMORY_PERCENT=10
CATASTROPHIC_MEMORY_PERCENT=90
DANGEROUS_SWAP_GROWTH_PERCENT=25
RUNAWAY_GROWTH_PERCENT=25
RUNAWAY_WINDOW_SAMPLES=30
SHUTDOWN_GRACE_SECONDS=15
RECOVERY_SAMPLE_DELAY_SECONDS=5
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/swiftpm-module-cache}"
PHASE="startup"
ACTIVE_PROCESS=""
INTERRUPTED_SIGNAL=""
GUARD_ACTIVE=false

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

process_running() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -o state= -p "$1" | tr -d ' ')"
  [[ -n "$state" && "$state" != Z* ]]
}

bytes_from_size() {
  local value="$1"
  case "$value" in
    *K) awk -v n="${value%K}" 'BEGIN {printf "%.0f", n * 1024}' ;;
    *M) awk -v n="${value%M}" 'BEGIN {printf "%.0f", n * 1048576}' ;;
    *G) awk -v n="${value%G}" 'BEGIN {printf "%.0f", n * 1073741824}' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

read_system_memory() {
  local output swap_value
  output="$(/usr/bin/memory_pressure -Q 2>&1)" || return 1
  SYSTEM_FREE="$(awk -F': |%' '/free percentage/ {print $2}' <<<"$output")"
  SYSTEM_PRESSURE_RAW="$(/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level)" || return 1
  if ((SYSTEM_PRESSURE_RAW & 4)); then
    SYSTEM_PRESSURE_LEVEL=critical
  elif ((SYSTEM_PRESSURE_RAW & 2)); then
    SYSTEM_PRESSURE_LEVEL=warning
  else
    SYSTEM_PRESSURE_LEVEL=normal
  fi
  output="$(/usr/sbin/sysctl -n vm.swapusage)" || return 1
  swap_value="$(awk -F'used = ' '{print $2}' <<<"$output" | awk '{print $1}')"
  SYSTEM_SWAP_BYTES="$(bytes_from_size "$swap_value")"
  SYSTEM_PAGEOUTS="$(/usr/bin/vm_stat | awk -F: '/^Pageouts/ {gsub(/[ .]/, "", $2); print $2}')"
  [[ "$SYSTEM_FREE" =~ ^[0-9]+$ && "$SYSTEM_PRESSURE_RAW" =~ ^[0-9]+$ \
    && "$SYSTEM_SWAP_BYTES" =~ ^[0-9]+$ && "$SYSTEM_PAGEOUTS" =~ ^[0-9]+$ ]]
}

read_process_memory() {
  local output rss_kb
  rss_kb="$(ps -o rss= -p "$1" | awk '{print $1 + 0}')"
  output="$(/usr/bin/footprint -f bytes --noCategories -p "$1" 2>&1)" || return 1
  PROCESS_RSS_BYTES="$((rss_kb * 1024))"
  PROCESS_FOOTPRINT_BYTES="$(awk '/phys_footprint:/ {print $(NF - 1); exit}' <<<"$output")"
  PROCESS_FOOTPRINT_PEAK_BYTES="$(awk '/phys_footprint_peak:/ {print $(NF - 1); exit}' <<<"$output")"
  [[ "$PROCESS_RSS_BYTES" =~ ^[0-9]+$ && "$PROCESS_FOOTPRINT_BYTES" =~ ^[0-9]+$ \
    && "$PROCESS_FOOTPRINT_PEAK_BYTES" =~ ^[0-9]+$ ]]
}

stop_process() {
  local process="$1" waited=0
  STOP_FORCED=false
  terminate_tree "$process"
  while process_running "$process" && ((waited < SHUTDOWN_GRACE_SECONDS)); do
    sleep 1 || true
    waited=$((waited + 1))
  done
  if process_running "$process"; then
    STOP_FORCED=true
    kill_tree "$process"
  fi
}

cleanup_active_process() {
  [[ -z "$ACTIVE_PROCESS" ]] || ! process_running "$ACTIVE_PROCESS" \
    || stop_process "$ACTIVE_PROCESS"
}

handle_signal() {
  INTERRUPTED_SIGNAL="$1"
  if [[ "$GUARD_ACTIVE" != true ]]; then
    trap - INT TERM
    [[ "$1" == INT ]] && exit 130
    exit 143
  fi
  trap '' INT TERM
  cleanup_active_process
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM
}

run_guarded() {
  local safety="$1" log="$2" timeout_seconds="$3" ready_file="$4"
  shift 4
  local samples="${safety%.json}.samples.jsonl"
  local started started_iso process reason="completed" peak_rss=0 peak_footprint=0
  local peak_reported_footprint=0 min_free=100 peak_swap_delta=0 current_memory=0
  local elapsed status exited_iso physical_memory catastrophic_limit dangerous_swap_limit model_loaded=false
  local stop_forced=false
  local before_free before_swap before_pageouts after_free after_swap after_pageouts
  local swap_delta pageout_delta samples_sha pressure_levels
  local runaway_history=()
  physical_memory="$(/usr/sbin/sysctl -n hw.memsize)"
  catastrophic_limit="$((physical_memory * CATASTROPHIC_MEMORY_PERCENT / 100))"
  dangerous_swap_limit="$((physical_memory * DANGEROUS_SWAP_GROWTH_PERCENT / 100))"
  read_system_memory || return 1
  before_free="$SYSTEM_FREE"
  before_swap="$SYSTEM_SWAP_BYTES"
  before_pageouts="$SYSTEM_PAGEOUTS"
  min_free="$before_free"
  : >"$samples"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pressure "$SYSTEM_PRESSURE_LEVEL" --argjson pressureRaw "$SYSTEM_PRESSURE_RAW" \
    --argjson free "$SYSTEM_FREE" --argjson swap "$SYSTEM_SWAP_BYTES" \
    --argjson pageouts "$SYSTEM_PAGEOUTS" \
    '{at:$at,phase:"before",nativePressureLevel:$pressure,nativePressureRaw:$pressureRaw,
      freeMemoryPercent:$free,swapUsedBytes:$swap,pageouts:$pageouts}' >>"$samples"
  started="$(date +%s)"
  started_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  INTERRUPTED_SIGNAL=""
  GUARD_ACTIVE=true
  "$@" >"$log" 2>&1 &
  process="$!"
  ACTIVE_PROCESS="$process"
  if [[ -n "$INTERRUPTED_SIGNAL" ]]; then
    stop_process "$process"
    stop_forced="$STOP_FORCED"
  fi
  while process_running "$process"; do
    elapsed="$(($(date +%s) - started))"
    if ! read_system_memory || ! read_process_memory "$process"; then
      process_running "$process" || break
      reason="safety-sampling-failed"
      stop_process "$process"
      stop_forced="$STOP_FORCED"
      break
    fi
    ((PROCESS_RSS_BYTES > peak_rss)) && peak_rss="$PROCESS_RSS_BYTES"
    ((PROCESS_FOOTPRINT_BYTES > peak_footprint)) && peak_footprint="$PROCESS_FOOTPRINT_BYTES"
    ((PROCESS_FOOTPRINT_PEAK_BYTES > peak_reported_footprint)) \
      && peak_reported_footprint="$PROCESS_FOOTPRINT_PEAK_BYTES"
    ((SYSTEM_FREE < min_free)) && min_free="$SYSTEM_FREE"
    swap_delta="$((SYSTEM_SWAP_BYTES - before_swap))"
    ((swap_delta > peak_swap_delta)) && peak_swap_delta="$swap_delta"
    pageout_delta="$((SYSTEM_PAGEOUTS - before_pageouts))"
    current_memory="$PROCESS_RSS_BYTES"
    ((PROCESS_FOOTPRINT_BYTES > current_memory)) && current_memory="$PROCESS_FOOTPRINT_BYTES"
    [[ -n "$ready_file" && -f "$ready_file" ]] && model_loaded=true
    if [[ "$model_loaded" == true ]]; then
      runaway_history+=("$current_memory")
      ((${#runaway_history[@]} <= RUNAWAY_WINDOW_SAMPLES)) \
        || runaway_history=("${runaway_history[@]:1}")
    fi
    jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg pressure "$SYSTEM_PRESSURE_LEVEL" --argjson pressureRaw "$SYSTEM_PRESSURE_RAW" \
      --argjson elapsed "$elapsed" --argjson pid "$process" \
      --argjson rss "$PROCESS_RSS_BYTES" --argjson footprint "$PROCESS_FOOTPRINT_BYTES" \
      --argjson footprintPeak "$PROCESS_FOOTPRINT_PEAK_BYTES" --argjson free "$SYSTEM_FREE" \
      --argjson swap "$SYSTEM_SWAP_BYTES" --argjson swapDelta "$swap_delta" \
      --argjson pageouts "$SYSTEM_PAGEOUTS" --argjson pageoutDelta "$pageout_delta" \
      --argjson modelLoaded "$model_loaded" \
      '{at:$at,phase:"running",elapsedSeconds:$elapsed,pid:$pid,residentBytes:$rss,
        physicalFootprintBytes:$footprint,reportedPeakPhysicalFootprintBytes:$footprintPeak,
        nativePressureLevel:$pressure,nativePressureRaw:$pressureRaw,
        freeMemoryPercent:$free,swapUsedBytes:$swap,swapUsedDeltaBytes:$swapDelta,
        pageouts:$pageouts,pageoutDelta:$pageoutDelta,modelLoaded:$modelLoaded}' >>"$samples"
    if [[ "$SYSTEM_PRESSURE_LEVEL" != normal ]]; then
      reason="native-pressure-$SYSTEM_PRESSURE_LEVEL"
    elif ((SYSTEM_FREE <= MIN_FREE_MEMORY_PERCENT)); then
      reason="free-memory-at-or-below-10-percent"
    elif ((current_memory >= catastrophic_limit)); then
      reason="catastrophic-process-memory"
    elif ((swap_delta >= dangerous_swap_limit)); then
      reason="dangerous-swap-growth"
    elif [[ "$model_loaded" == true ]] \
      && ((${#runaway_history[@]} == RUNAWAY_WINDOW_SAMPLES)) \
      && ((current_memory - runaway_history[0] >= physical_memory * RUNAWAY_GROWTH_PERCENT / 100)); then
      reason="post-load-runaway"
    fi
    if [[ "$reason" == completed ]] && ((elapsed >= timeout_seconds)); then
      reason="timeout"
    fi
    if [[ "$reason" != completed ]]; then
      stop_process "$process"
      stop_forced="$STOP_FORCED"
      break
    fi
    sleep 1 || true
  done
  status=0
  wait "$process" 2>/dev/null || status="$?"
  ACTIVE_PROCESS=""
  [[ -z "$INTERRUPTED_SIGNAL" || "$reason" != completed ]] \
    || reason="runner-interrupted-$INTERRUPTED_SIGNAL"
  sleep "$RECOVERY_SAMPLE_DELAY_SECONDS" || true
  if read_system_memory; then
    after_free="$SYSTEM_FREE"
    after_swap="$SYSTEM_SWAP_BYTES"
    after_pageouts="$SYSTEM_PAGEOUTS"
  else
    after_free="$min_free"
    after_swap="$before_swap"
    after_pageouts="$before_pageouts"
    [[ "$reason" != completed ]] || reason="post-exit-sampling-failed"
  fi
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pressure "$SYSTEM_PRESSURE_LEVEL" --argjson pressureRaw "$SYSTEM_PRESSURE_RAW" \
    --argjson free "$after_free" --argjson swap "$after_swap" \
    --argjson swapDelta "$((after_swap - before_swap))" --argjson pageouts "$after_pageouts" \
    --argjson pageoutDelta "$((after_pageouts - before_pageouts))" \
    '{at:$at,phase:"after",nativePressureLevel:$pressure,nativePressureRaw:$pressureRaw,
      freeMemoryPercent:$free,swapUsedBytes:$swap,swapUsedDeltaBytes:$swapDelta,
      pageouts:$pageouts,pageoutDelta:$pageoutDelta}' >>"$samples"
  exited_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  samples_sha="$(sha256 "$samples")"
  pressure_levels="$(jq -sc '[.[].nativePressureLevel] | unique' "$samples")"
  jq -n \
    --arg startedAt "$started_iso" --arg exitedAt "$exited_iso" --arg reason "$reason" \
    --argjson elapsedSeconds "$(($(date +%s) - started))" \
    --arg samplesPath "$samples" --arg samplesSHA256 "$samples_sha" \
    --argjson timeoutSeconds "$timeout_seconds" --argjson physicalMemoryBytes "$physical_memory" \
    --argjson catastrophicMemoryPercent "$CATASTROPHIC_MEMORY_PERCENT" \
    --argjson catastrophicMemoryBytes "$catastrophic_limit" \
    --argjson dangerousSwapGrowthPercent "$DANGEROUS_SWAP_GROWTH_PERCENT" \
    --argjson dangerousSwapGrowthBytes "$dangerous_swap_limit" \
    --argjson peakResidentBytes "$peak_rss" --argjson peakPhysicalFootprintBytes "$peak_footprint" \
    --argjson reportedPeakPhysicalFootprintBytes "$peak_reported_footprint" \
    --argjson minimumFreeMemoryPercent "$min_free" --argjson pressureLevels "$pressure_levels" \
    --argjson swapUsedBeforeBytes "$before_swap" --argjson peakSwapDeltaBytes "$peak_swap_delta" \
    --argjson swapUsedAfterBytes "$after_swap" --argjson pageoutsBefore "$before_pageouts" \
    --argjson pageoutsAfter "$after_pageouts" --argjson freeBefore "$before_free" \
    --argjson freeAfter "$after_free" --argjson modelLoaded "$model_loaded" \
    --argjson runawayGrowthPercent "$RUNAWAY_GROWTH_PERCENT" \
    --argjson runawayWindowSamples "$RUNAWAY_WINDOW_SAMPLES" \
    --argjson forcedTermination "$stop_forced" --argjson exitStatus "$status" \
    '{schemaVersion:2,startedAt:$startedAt,exitedAt:$exitedAt,elapsedSeconds:$elapsedSeconds,
      timeoutSeconds:$timeoutSeconds,stopReason:$reason,exitStatus:$exitStatus,
      forcedTermination:$forcedTermination,peakResidentBytes:$peakResidentBytes,
      peakPhysicalFootprintBytes:$peakPhysicalFootprintBytes,
      reportedPeakPhysicalFootprintBytes:$reportedPeakPhysicalFootprintBytes,
      minimumFreeMemoryPercent:$minimumFreeMemoryPercent,nativePressureLevels:$pressureLevels,
      catastrophicGuard:{physicalMemoryBytes:$physicalMemoryBytes,
        limitPercent:$catastrophicMemoryPercent,limitBytes:$catastrophicMemoryBytes},
      swapGrowthGuard:{limitPercentOfPhysicalMemory:$dangerousSwapGrowthPercent,
        limitBytes:$dangerousSwapGrowthBytes},
      postLoadRunawayGuard:{modelLoadedObserved:$modelLoaded,
        growthPercent:$runawayGrowthPercent,windowSamples:$runawayWindowSamples},
      systemBefore:{freeMemoryPercent:$freeBefore,swapUsedBytes:$swapUsedBeforeBytes,
        pageouts:$pageoutsBefore},
      systemAfter:{freeMemoryPercent:$freeAfter,swapUsedBytes:$swapUsedAfterBytes,
        swapDeltaBytes:($swapUsedAfterBytes-$swapUsedBeforeBytes),pageouts:$pageoutsAfter,
        pageoutDelta:($pageoutsAfter-$pageoutsBefore),
        recoveredFreeMemoryPercentagePoints:($freeAfter-$minimumFreeMemoryPercent)},
      peakSwapDeltaBytes:$peakSwapDeltaBytes,
      rawSamples:{path:$samplesPath,sha256:$samplesSHA256}}' >"$safety"
  if [[ -n "$INTERRUPTED_SIGNAL" && "$reason" == completed ]]; then
    reason="runner-interrupted-$INTERRUPTED_SIGNAL"
    jq --arg reason "$reason" '.stopReason = $reason' "$safety" >"$safety.part"
    mv "$safety.part" "$safety"
  fi
  GUARD_ACTIVE=false
  [[ -z "$INTERRUPTED_SIGNAL" && "$reason" == completed && "$status" == 0 ]]
}

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
  [[ -x /usr/bin/footprint && -x /usr/bin/memory_pressure && -x /usr/bin/vm_stat ]] \
    || fail "missing-native-memory-tools"
  [[ -x /usr/sbin/sysctl ]] || fail "missing-sysctl"
  [[ -x "$PYTHON" ]] || fail "missing-python-3.11"
  [[ -x "$PIXIT_PYTHON" ]] || fail "missing-ticket-101-python-runtime"
  "$PYTHON" Scripts/test_pixit_oracle.py
  "$PIXIT_PYTHON" Scripts/test_mossformer2_oracle.py
  bash -n Scripts/run_mossformer2_oracle_experiment.sh
  bash Scripts/test_mossformer2_guard.sh
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
    '{schemaVersion:1,ticket:102,status:"READY_FOR_HEAVY_BENCHMARK",stage:"SMOKE_RETRY",
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
  local stage="$1" window_id="${2:-}"
  local directory="$ARTIFACTS/$stage"
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
    "$moss_timeout" "$directory/separator/model-loaded.json" \
    "$VENV/bin/python" Scripts/mossformer2_oracle.py separate \
      --plan "$PLAN" --pixit-separator "$pixit_separator" \
      --clearvoice-source "$CLEARVOICE" --runtime-root "$RUNTIME_ROOT" --model "$MODEL" \
      --output "$directory/separator" --stage "$stage" \
      ${window_args[@]+"${window_args[@]}"}
  cat "$directory/moss.log"
  PHASE="qwen-$stage"
  mkdir -p "$directory/qwen"
  run_guarded "$directory/qwen-safety.json" "$directory/qwen.log" \
    "$qwen_timeout" "" env \
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

main() {
  case "$MODE" in preflight|smoke|development) ;; *)
    echo "usage: $0 [preflight|smoke|development]" >&2
    exit 2
  esac
  [[ "$MODE" == preflight || "${BENCHMARK_SLOT_GRANTED:-}" == 102 ]] || {
    echo "Refusing heavyweight #102 run without BENCHMARK_SLOT_GRANTED=102" >&2
    exit 2
  }
  trap failure_artifact ERR
  trap cleanup_active_process EXIT
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM
  cd "$ROOT"
  mkdir -p "$ARTIFACTS" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
  rm -f "$ARTIFACTS/failure.json"
  case "$MODE" in
    preflight)
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
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main
