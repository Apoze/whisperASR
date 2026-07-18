#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
WHISPERASR_VERIFY_JAPANESE_CORPORA=1 \
  xcrun swift test \
    --filter JapaneseBenchmarkSupportTests/testLocalFixturesMatchVersionedManifestsWhenOptedIn
