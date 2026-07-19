#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L5_REPORT="${WHISPERASR_L5_REPORT:-$ROOT/.build/benchmarks/japanese-live/runs/l5-final-offline/ja-asr.json}"
RUN_ID="${WHISPERASR_L6_RUN_ID:-l6-apple-$(date -u +%Y%m%dT%H%M%SZ)}"

if [[ ! -f "$L5_REPORT" ]]; then
  echo "Missing L5 report: $L5_REPORT" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export WHISPERASR_MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
export WHISPERASR_MACOS_BUILD="$(/usr/bin/sw_vers -buildVersion)"
cd "$ROOT"
xcrun swift test -c release --filter JapaneseEnglishFullBakeoffTests

BENCHMARK_COMMIT="$(git rev-parse HEAD)"
BENCHMARK_DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then
  BENCHMARK_DIRTY=1
fi

RUNNER=(
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
  -XCTest WhisperASRTests.JapaneseEnglishFullBakeoffTests/testFullEnglishBakeoffWhenOptedIn
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"
)
export WHISPERASR_REMOTE_NETWORK_DENIED=1
RUNNER=(
  /usr/bin/sandbox-exec
  -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(allow network-outbound (remote ip "localhost:*"))'
  "${RUNNER[@]}"
)

WHISPERASR_L6_APPLE_BAKEOFF=1 \
WHISPERASR_L5_REPORT="$L5_REPORT" \
WHISPERASR_L6_RUN_ID="$RUN_ID" \
WHISPERASR_BENCHMARK_COMMIT="$BENCHMARK_COMMIT" \
WHISPERASR_BENCHMARK_DIRTY="$BENCHMARK_DIRTY" \
  "${RUNNER[@]}"

echo "Reports: $ROOT/.build/benchmarks/japanese-live/runs/$RUN_ID"
