#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIDEO="${WHISPERASR_STEREO_BAKEOFF_VIDEO:-/Users/maz/Downloads/Easy Japanese 1 - Typical Japanese.mp4}"
CORPUS="${WHISPERASR_STEREO_BAKEOFF_CORPUS:-$ROOT/.build/benchmarks/corpora/easy-japanese-1}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
"$ROOT/Scripts/prepare_japanese_bakeoff.sh" "$VIDEO"
xcrun swift test -c release --filter StereoChannelBakeoffTests/testStereoVariantMath
"$ROOT/Scripts/build_mlx_metallib.sh" release

WHISPERASR_STEREO_BAKEOFF=1 \
WHISPERASR_STEREO_BAKEOFF_VIDEO="$VIDEO" \
WHISPERASR_STEREO_BAKEOFF_CORPUS="$CORPUS" \
  xcrun swift test -c release --skip-build \
    --filter StereoChannelBakeoffTests/testDifficultPassageStereoBakeoffWhenOptedIn

echo "Report: $ROOT/.build/benchmarks/easy-japanese-1-stereo-bakeoff.json"
