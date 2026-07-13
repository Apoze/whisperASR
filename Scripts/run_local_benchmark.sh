#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAV="${1:-$ROOT/.build/benchmarks/canonical-firefox-16k-mono.wav}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
xcrun swift build
"$ROOT/Scripts/build_mlx_metallib.sh" debug
WHISPERASR_BENCHMARK_WAV="$WAV" xcrun swift test \
  --filter LocalPrototypeBenchmarkTests/testCanonicalQualityBenchmarkWhenOptedIn
