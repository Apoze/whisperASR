#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_STATE="$ROOT/.build/benchmarks/japanese-live/tools/swiftpm"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SWIFT_STATE/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$SWIFT_STATE/module-cache}"

cd "$ROOT"
mkdir -p \
  "$SWIFT_STATE/cache" \
  "$SWIFT_STATE/config" \
  "$SWIFT_STATE/security" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE"
WHISPERASR_VERIFY_JAPANESE_CORPORA=1 \
  xcrun swift test \
    --disable-sandbox \
    --cache-path "$SWIFT_STATE/cache" \
    --config-path "$SWIFT_STATE/config" \
    --security-path "$SWIFT_STATE/security" \
    --scratch-path "$ROOT/.build" \
    -c release \
    --filter JapaneseBenchmarkSupportTests/testLocalFixturesMatchVersionedManifestsWhenOptedIn
