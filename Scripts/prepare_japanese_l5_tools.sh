#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.build/benchmarks/japanese-live/tools"
UV="${WHISPERASR_UV:-/Users/maz/Library/Application Support/WhisperASR/Runtime/Tools/uv}"
PYTHON="${WHISPERASR_PYTHON312:-/Users/maz/Library/Application Support/WhisperASR/Runtime/Python/cpython-3.12.13-macos-aarch64-none/bin/python3.12}"
UV_CACHE_DIR="$TOOLS/uv-cache"
MLX_ENV="$TOOLS/mlx-whisper/0.4.3/venv"
WHISPERMLX_ENV="$TOOLS/whispermlx/v3.12.2/venv"
MLX_REVISION="a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
MLX_MODEL="$TOOLS/models/mlx-whisper-large-v3-turbo/$MLX_REVISION"
KOTOBA_REVISION="e3a0cf6a62b95911703cfb97d819292e058f12c3"
KOTOBA_MODEL="$TOOLS/models/kotoba-whisper-v2.0-ggml/$KOTOBA_REVISION"
SILERO_REVISION="7e30209a3e901f9842f81b225f3e93d8199902b1"
SILERO="$TOOLS/silero-vad/$SILERO_REVISION"
MLX_WHEEL="mlx-whisper @ https://files.pythonhosted.org/packages/22/b7/a35232812a2ccfffcb7614ba96a91338551a660a0e9815cee668bf5743f0/mlx_whisper-0.4.3-py3-none-any.whl#sha256=6b82b6597a994643a3e5496c7bc229a672e5ca308458455bfe276e76ae024489"
WHISPERMLX_WHEEL="whispermlx @ https://files.pythonhosted.org/packages/d5/ab/95403bec7ffdc4459698c4746a3f9df9dfc587caaeede80489cb5c6d0442/whispermlx-3.12.2-py3-none-any.whl#sha256=60845ff695168aeb3b8d8b1887481ffe02f5e11ec0426c706a9f7cd0a37917a4"

test -x "$UV"
test -x "$PYTHON"
mkdir -p "$TOOLS"

if [[ ! -x "$MLX_ENV/bin/python" ]]; then
  env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" venv --python "$PYTHON" "$MLX_ENV"
fi
env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" pip install \
  --python "$MLX_ENV/bin/python" --reinstall-package mlx-whisper "$MLX_WHEEL"

if [[ ! -x "$WHISPERMLX_ENV/bin/python" ]]; then
  env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" venv --python "$PYTHON" "$WHISPERMLX_ENV"
fi
# whispermlx 3.12.2 can otherwise resolve numba 0.53.1, which cannot run on its
# declared Python 3.12 range. Keep the smallest compatible override explicit.
env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" pip install \
  --python "$WHISPERMLX_ENV/bin/python" \
  --reinstall-package whispermlx --reinstall-package mlx-whisper \
  "$WHISPERMLX_WHEEL" "$MLX_WHEEL" 'numba==0.66.0' 'llvmlite==0.48.0'

env HF_HOME="$TOOLS/huggingface" "$MLX_ENV/bin/hf" download \
  mlx-community/whisper-large-v3-turbo \
  --revision "$MLX_REVISION" \
  --local-dir "$MLX_MODEL" \
  --max-workers 4
env HF_HOME="$TOOLS/huggingface" "$MLX_ENV/bin/hf" download \
  kotoba-tech/kotoba-whisper-v2.0-ggml \
  ggml-kotoba-whisper-v2.0-q5_0.bin \
  --revision "$KOTOBA_REVISION" \
  --local-dir "$KOTOBA_MODEL"

if [[ ! -d "$SILERO/.git" ]]; then
  git clone --depth 1 --branch v6.2.1 \
    https://github.com/snakers4/silero-vad.git "$SILERO"
fi
test "$(git -C "$SILERO" rev-parse HEAD)" = "$SILERO_REVISION"

test "$(shasum -a 256 "$MLX_MODEL/weights.safetensors" | cut -d ' ' -f 1)" = \
  "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"
test "$(shasum -a 256 "$KOTOBA_MODEL/ggml-kotoba-whisper-v2.0-q5_0.bin" | cut -d ' ' -f 1)" = \
  "4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"

env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" pip freeze --python "$MLX_ENV/bin/python" \
  > "$TOOLS/mlx-whisper/0.4.3/requirements-resolved.txt"
env UV_CACHE_DIR="$UV_CACHE_DIR" "$UV" pip freeze --python "$WHISPERMLX_ENV/bin/python" \
  > "$TOOLS/whispermlx/v3.12.2/requirements-resolved.txt"

echo "L5 tools are ready under $TOOLS"
