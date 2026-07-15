#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${1:-all}"

if [[ "$ENGINE" != "all" && "$ENGINE" != "whisper" && "$ENGINE" != "qwen" ]]; then
  echo "Usage: $0 [all|whisper|qwen]" >&2
  exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
"$ROOT/Scripts/prepare_japanese_bakeoff.sh"
xcrun swift test -c release \
  --filter JapaneseDirectModelSmokeTests/testWhisperLargeV3DirectWhenOptedIn
"$ROOT/Scripts/build_mlx_metallib.sh" release

if [[ "$ENGINE" == "all" || "$ENGINE" == "whisper" ]]; then
  WHISPERASR_WHISPER_LARGE_V3_DIRECT_SMOKE=1 \
    xcrun swift test -c release --skip-build \
      --filter JapaneseDirectModelSmokeTests/testWhisperLargeV3DirectWhenOptedIn
fi

if [[ "$ENGINE" == "all" || "$ENGINE" == "qwen" ]]; then
  WHISPERASR_QWEN_JA_EN_SMOKE=1 \
    xcrun swift test -c release --skip-build \
      --filter JapaneseDirectModelSmokeTests/testQwenJapaneseEnglishDirectWhenOptedIn
fi

echo "Reports: $ROOT/.build/benchmarks/*-direct-smoke.json"
