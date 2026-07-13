#!/usr/bin/env bash
set -euo pipefail

# Derived from speech-swift commit 9c4bff5a8f0287a179b9a039da25ff9fa02553a3.
# Bare SwiftPM cannot compile MLX's Metal shaders, so build the one runtime
# resource shared by the app bundle and opt-in benchmark test bundle.

CONFIG="${1:-release}"
if [[ "$CONFIG" != "release" && "$CONFIG" != "debug" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
OUT_DIR="$BUILD_DIR/$CONFIG"
MLX_SWIFT_DIR="$BUILD_DIR/checkouts/mlx-swift"
KERNELS_DIR="$MLX_SWIFT_DIR/Source/Cmlx/mlx/mlx/backend/metal/kernels"
OUT_METALLIB="$OUT_DIR/mlx.metallib"
HASH_FILE="$OUT_DIR/.mlx.metallib.sha"

[[ -d "$OUT_DIR" ]] || { echo "error: run swift build -c $CONFIG first" >&2; exit 1; }
[[ -d "$KERNELS_DIR" ]] || { echo "error: MLX Metal kernels are missing" >&2; exit 1; }

CURRENT_HASH="$(find "$KERNELS_DIR" -type f \( -name '*.metal' -o -name '*.h' \) ! -name '*_nax.metal' | LC_ALL=C sort | xargs cat | shasum -a 256 | awk '{print $1}')"
if [[ ! -f "$OUT_METALLIB" || ! -f "$HASH_FILE" || "$(cat "$HASH_FILE")" != "$CURRENT_HASH" ]]; then
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metallib.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  AIR_FILES=()
  while IFS= read -r SOURCE; do
    RELATIVE="${SOURCE#"$KERNELS_DIR/"}"
    AIR="$TMP/$(printf '%s' "$RELATIVE" | shasum -a 256 | awk '{print substr($1,1,16)}').air"
    xcrun -sdk macosx metal \
      -x metal -Wall -Wextra -fno-fast-math \
      -Wno-c++17-extensions -Wno-c++20-extensions \
      -c "$SOURCE" -I"$KERNELS_DIR" -I"$MLX_SWIFT_DIR/Source/Cmlx/mlx" \
      -o "$AIR"
    AIR_FILES+=("$AIR")
  done < <(find "$KERNELS_DIR" -type f -name '*.metal' ! -name '*_nax.metal' | LC_ALL=C sort)
  [[ ${#AIR_FILES[@]} -gt 0 ]] || { echo "error: no MLX Metal sources found" >&2; exit 1; }
  xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$OUT_METALLIB"
  printf '%s' "$CURRENT_HASH" > "$HASH_FILE"
  echo "Built $OUT_METALLIB"
else
  echo "mlx.metallib is up to date"
fi

while IFS= read -r TEST_MACOS; do
  cp "$OUT_METALLIB" "$TEST_MACOS/mlx.metallib"
done < <(find "$BUILD_DIR" -type d -path "*/$CONFIG/*PackageTests.xctest/Contents/MacOS")
