#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
COMMIT="5874bdeeaddf968ab73e005eb287e1b597b0eb37"
BASE="$TOOLS/whisperlivekit/$COMMIT"
SOURCE="$BASE/source"
VENV="$BASE/venv"
UV="${WHISPERASR_UV:-/Users/maz/Library/Application Support/WhisperASR/Runtime/Tools/uv}"
PYTHON="${WHISPERASR_PYTHON312:-/Users/maz/Library/Application Support/WhisperASR/Runtime/Python/cpython-3.12.13-macos-aarch64-none/bin/python3.12}"
UV_CACHE_DIR="$TOOLS/uv-cache"
MLX_REVISION="a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
MLX_MODEL="$TOOLS/models/mlx-whisper-large-v3-turbo/$MLX_REVISION"
DECODER_DIR="$BASE/models/openai"
DECODER="$DECODER_DIR/large-v3-turbo.pt"
DECODER_URL="https://openaipublic.azureedge.net/main/whisper/models/aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a/large-v3-turbo.pt"
WARMUP="$BASE/models/warmup-ja.wav"
WARMUP_SOURCE="$ROOT/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/audio-16k-mono.wav"
FFMPEG="${WHISPERASR_FFMPEG:-/opt/homebrew/bin/ffmpeg}"

test -x "$UV"
test -x "$PYTHON"
test -f "$MLX_MODEL/config.json"
test -f "$MLX_MODEL/weights.safetensors"
test -x "$FFMPEG"
test "$(shasum -a 256 "$WARMUP_SOURCE" | cut -d ' ' -f 1)" = \
  "494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2"
mkdir -p "$BASE" "$DECODER_DIR"

if [[ ! -d "$SOURCE/.git" ]]; then
  git clone --filter=blob:none https://github.com/QuentinFuxa/WhisperLiveKit.git "$SOURCE"
  git -C "$SOURCE" checkout --detach "$COMMIT"
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT"
test "$(shasum -a 256 "$SOURCE/uv.lock" | cut -d ' ' -f 1)" = \
  "06750b16caa60432e7d1a9427cd2196e6bf926f20fc15d3c77cba78469e99ec1"

env UV_CACHE_DIR="$UV_CACHE_DIR" UV_PROJECT_ENVIRONMENT="$VENV" \
  "$UV" sync --project "$SOURCE" --python "$PYTHON" \
  --frozen --no-dev --extra mlx-whisper

if [[ ! -f "$DECODER" ]]; then
  /usr/bin/curl --fail --location --retry 3 \
    --output "$DECODER.partial" "$DECODER_URL"
  mv "$DECODER.partial" "$DECODER"
fi
test "$(shasum -a 256 "$DECODER" | cut -d ' ' -f 1)" = \
  "aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a"

if [[ ! -f "$WARMUP" ]]; then
  "$FFMPEG" -hide_banner -loglevel error -ss 715 -t 5 \
    -i "$WARMUP_SOURCE" -ar 16000 -ac 1 -c:a pcm_s16le -y "$WARMUP.partial.wav"
  mv "$WARMUP.partial.wav" "$WARMUP"
fi
test "$(shasum -a 256 "$WARMUP" | cut -d ' ' -f 1)" = \
  "82df6b6ad5cebc55f727443d4a1c5c4a11d2c26cb75ef43e9ee091b8b7029ae5"

env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" pip freeze --python "$VENV/bin/python" \
  > "$BASE/requirements-resolved.txt"
test "$($VENV/bin/wlk version | tr -d '\r')" = "WhisperLiveKit 0.2.24"

echo "WhisperLiveKit L6 ready at $BASE"
