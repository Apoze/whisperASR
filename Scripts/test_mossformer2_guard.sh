#!/bin/bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
source "$ROOT/Scripts/run_mossformer2_oracle_experiment.sh"

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
