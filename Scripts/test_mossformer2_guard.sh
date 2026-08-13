#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/run_mossformer2_oracle_experiment.sh"

WARNING_CLEANUP_MEMORY=""
WARNING_CLEANUP_COUNT=0
pressure_guard_decision warning 1000 100
[[ "$PRESSURE_STOP_REASON" == native-pressure-warning ]] || exit 1
WARNING_CLEANUP_RETRY_ENABLED=true
pressure_guard_decision warning 1000 100
[[ -z "$PRESSURE_STOP_REASON" && "$WARNING_CLEANUP_MEMORY" == 1000 \
  && "$WARNING_CLEANUP_COUNT" == 1 ]] || exit 1
pressure_guard_decision normal 900 100
[[ -z "$PRESSURE_STOP_REASON" && -z "$WARNING_CLEANUP_MEMORY" ]] || exit 1
pressure_guard_decision warning 1000 100
pressure_guard_decision warning 900 100
[[ "$PRESSURE_STOP_REASON" == native-pressure-warning-persisted ]] || exit 1
WARNING_CONTINUES_WHILE_SAFE=true
WARNING_CLEANUP_MEMORY=""
pressure_guard_decision warning 1000 100
pressure_guard_decision warning 900 100
[[ -z "$PRESSURE_STOP_REASON" && "$WARNING_CLEANUP_COUNT" == 3 ]] || exit 1
pressure_guard_decision warning 1200 100
[[ "$PRESSURE_STOP_REASON" == post-warning-memory-growth ]] || exit 1
WARNING_CONTINUES_WHILE_SAFE=false
WARNING_CLEANUP_MEMORY=""
pressure_guard_decision warning 1000 100
pressure_guard_decision normal 1200 100
[[ "$PRESSURE_STOP_REASON" == post-warning-memory-growth ]] || exit 1
WARNING_CLEANUP_MEMORY=""
pressure_guard_decision critical 1000 100
[[ "$PRESSURE_STOP_REASON" == native-pressure-critical ]] || exit 1

RECOVERY_SAMPLE_DELAY_SECONDS=0
SHUTDOWN_GRACE_SECONDS=1
run_guarded "$TEMP/completed.json" "$TEMP/completed.log" 5 "" /bin/sleep 1
jq -e '.stopReason == "completed" and .exitStatus == 0 and
  .rawSamples.sha256 != null' "$TEMP/completed.json" >/dev/null

CATASTROPHIC_MEMORY_PERCENT=0
if run_guarded "$TEMP/stopped.json" "$TEMP/stopped.log" 5 "" /bin/sleep 30; then
  exit 1
fi
jq -e '.stopReason == "catastrophic-process-memory" and .exitStatus != 0 and
  .forcedTermination == false' "$TEMP/stopped.json" >/dev/null

CATASTROPHIC_MEMORY_PERCENT=90
RUNAWAY_GROWTH_PERCENT=0
RUNAWAY_WINDOW_SAMPLES=2
touch "$TEMP/model-loaded.json"
if run_guarded "$TEMP/runaway.json" "$TEMP/runaway.log" 5 \
  "$TEMP/model-loaded.json" /bin/sleep 30; then
  exit 1
fi
jq -e '.stopReason == "post-load-runaway" and
  .postLoadRunawayGuard.modelLoadedObserved == true' "$TEMP/runaway.json" >/dev/null

RUNAWAY_GROWTH_PERCENT=25
RUNAWAY_WINDOW_SAMPLES=30
RECOVERY_SAMPLE_DELAY_SECONDS=3
(
  trap cleanup_active_process EXIT
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM
  run_guarded "$TEMP/interrupted.json" "$TEMP/interrupted.log" 30 "" /usr/bin/true
) &
guard="$!"
sleep 1
kill -TERM "$guard"
wait "$guard" 2>/dev/null || true
jq -e '.stopReason == "runner-interrupted-TERM" and .exitStatus == 0' \
  "$TEMP/interrupted.json" >/dev/null

guard_sample=0
read_system_memory() {
  guard_sample=$((guard_sample + 1))
  SYSTEM_FREE=50
  SYSTEM_PRESSURE_RAW=1
  SYSTEM_PRESSURE_LEVEL=normal
  SYSTEM_SWAP_BYTES=0
  SYSTEM_PAGEOUTS=0
}
read_process_memory() {
  if ((guard_sample == 2)); then
    PROCESS_RSS_BYTES=$((100 * 1024 * 1024))
  else
    PROCESS_RSS_BYTES=$((8 * 1024 * 1024 * 1024))
  fi
  PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_RSS_BYTES"
}
RECOVERY_SAMPLE_DELAY_SECONDS=0
PAGEOUT_GUARD_FROM_PROCESS_START=true
RUNAWAY_WINDOW_SAMPLES=3
if ! run_guarded "$TEMP/initial-load.json" "$TEMP/initial-load.log" 10 "" /bin/sleep 4; then
  exit 1
fi
jq -e '.stopReason == "completed" and .postLoadRunawayGuard.modelLoadedObserved == false' \
  "$TEMP/initial-load.json" >/dev/null

guard_sample=0
read_system_memory() {
  guard_sample=$((guard_sample + 1))
  SYSTEM_FREE=50
  SYSTEM_PRESSURE_RAW=1
  SYSTEM_PRESSURE_LEVEL=normal
  SYSTEM_SWAP_BYTES=0
  SYSTEM_PAGEOUTS="$guard_sample"
}
read_process_memory() {
  PROCESS_RSS_BYTES="$((guard_sample * 200 * 1024 * 1024))"
  PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_RSS_BYTES"
}
RECOVERY_SAMPLE_DELAY_SECONDS=0
PAGEOUT_GUARD_FROM_PROCESS_START=true
RUNAWAY_WINDOW_SAMPLES=3
if run_guarded "$TEMP/pageout.json" "$TEMP/pageout.log" 10 "" /bin/sleep 30; then
  exit 1
fi
jq -e '.stopReason == "pageout-runaway" and .pageoutRunawayGuard.fromProcessStart == true' \
  "$TEMP/pageout.json" >/dev/null

guard_sample=0
read_system_memory() {
  guard_sample=$((guard_sample + 1))
  SYSTEM_FREE=50
  SYSTEM_PRESSURE_RAW=1
  SYSTEM_PRESSURE_LEVEL=normal
  SYSTEM_SWAP_BYTES=0
  SYSTEM_PAGEOUTS=0
}
read_process_memory() {
  if ((guard_sample <= 3)); then
    PROCESS_RSS_BYTES=$((1 * 1024 * 1024 * 1024))
  else
    PROCESS_RSS_BYTES=$((8 * 1024 * 1024 * 1024))
  fi
  PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_RSS_BYTES"
}
PAGEOUT_GUARD_FROM_PROCESS_START=false
touch "$TEMP/loaded-baseline.json"
if run_guarded "$TEMP/post-load-growth.json" "$TEMP/post-load-growth.log" 10 \
  "$TEMP/loaded-baseline.json" /bin/sleep 5; then
  exit 1
fi
jq -e '.stopReason == "post-load-runaway" and
  .postLoadRunawayGuard.modelLoadedObserved == true' "$TEMP/post-load-growth.json" >/dev/null
