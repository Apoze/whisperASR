#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$ROOT/.build/downloads/funasr-nano-int8"
RUNTIME="$ROOT/.build/runtimes/funasr-nano-int8"
MODELS="$ROOT/.build/models"
MODEL="$MODELS/sherpa-onnx-funasr-nano-int8-2025-12-30"
ARCHIVE="$DOWNLOADS/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2"
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2"
ARCHIVE_SHA="eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b"
SHERPA_WHEEL="sherpa_onnx-1.13.5-cp314-cp314-macosx_11_0_arm64.whl"
SHERPA_URL="https://files.pythonhosted.org/packages/84/9d/0cb152e3fd1aa5787ade99c4863cd8cf80d800b879e8ff47f8f99412af78/$SHERPA_WHEEL"
SHERPA_SHA="97471fe025fc1d655a1df2f4ffb5d3fe843c269f2016d5e1cca4b0d168a49169"
CORE_WHEEL="sherpa_onnx_core-1.13.5-py3-none-macosx_11_0_arm64.whl"
CORE_URL="https://files.pythonhosted.org/packages/91/54/b753e2dbd2b0f09aed2d2082f35c41606af9712457278ff99d13eaae92d3/$CORE_WHEEL"
CORE_SHA="899e88916efd96ee1eabc512e9ceaf2fdb711b20b2512cf40358b623e90b5ded"

[[ "${BENCHMARK_SLOT_GRANTED:-}" == "88" ]] || {
  echo "Benchmark slot #88 is required before downloading the runtime or weights." >&2
  exit 77
}
[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon arm64 is required." >&2; exit 1; }
[[ "$(python3 -c 'import platform; print(platform.python_version_tuple()[0]+platform.python_version_tuple()[1])')" == 314 ]] || {
  echo "Pinned sherpa wheel requires CPython 3.14." >&2
  exit 1
}

download() {
  local url="$1" destination="$2" expected="$3"
  if [[ ! -f "$destination" ]]; then curl -fL --retry 3 -o "$destination" "$url"; fi
  [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected" ]] || {
    echo "Hash mismatch: $destination" >&2
    exit 1
  }
}

mkdir -p "$DOWNLOADS" "$MODELS"
download "$SHERPA_URL" "$DOWNLOADS/$SHERPA_WHEEL" "$SHERPA_SHA"
download "$CORE_URL" "$DOWNLOADS/$CORE_WHEEL" "$CORE_SHA"
download "$ARCHIVE_URL" "$ARCHIVE" "$ARCHIVE_SHA"
[[ "$(stat -f %z "$ARCHIVE")" == 841730611 ]] || {
  echo "Unexpected model archive size." >&2
  exit 1
}

if [[ ! -d "$RUNTIME" ]]; then
  python3 -m venv "$RUNTIME"
fi
"$RUNTIME/bin/pip" install --no-deps --no-index \
  "$DOWNLOADS/$CORE_WHEEL" "$DOWNLOADS/$SHERPA_WHEEL"

if [[ ! -d "$MODEL" ]]; then
  temporary="$(mktemp -d "$MODELS/.funasr-extract.XXXXXX")"
  trap 'rm -rf "$temporary"' EXIT
  tar -xjf "$ARCHIVE" -C "$temporary"
  extracted="$temporary/sherpa-onnx-funasr-nano-int8-2025-12-30"
  [[ -d "$extracted" ]] || { echo "Unexpected model archive layout." >&2; exit 1; }
  mv "$extracted" "$MODEL"
fi

verify_weight() {
  local expected="$1" relative="$2" actual
  actual="$(shasum -a 256 "$MODEL/$relative" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "Hash mismatch: $MODEL/$relative" >&2
    exit 1
  }
  printf '%s  %s\n' "$actual" "$MODEL/$relative"
}

verify_weight a05d2816e284fcca29a5dccb2c14b9edeb638fd983a84cd4a447248889b6a408 embedding.int8.onnx
verify_weight d0246c823f2c34133ae0efee395d8a189c8f92643e3432f866939ee34d34492c encoder_adaptor.int8.onnx
verify_weight 7f0c5a508b41474b1b1ec1cdbdefafd2cf8b3642c6915a0a425265b7b7d2c960 llm.int8.onnx
verify_weight 8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5 Qwen3-0.6B/merges.txt
verify_weight aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4 Qwen3-0.6B/tokenizer.json
verify_weight ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910 Qwen3-0.6B/vocab.json

jq -n \
  --arg archiveURL "$ARCHIVE_URL" --arg archiveSHA256 "$ARCHIVE_SHA" \
  --argjson archiveBytes 841730611 --arg runtimeVersion 1.13.5 \
  --arg runtimeCommit 3dc7c569f31ca2cd4a20ed6f7db780327e6714c5 \
  --arg sherpaWheelSHA256 "$SHERPA_SHA" --arg coreWheelSHA256 "$CORE_SHA" \
  '{archiveURL:$archiveURL,archiveSHA256:$archiveSHA256,archiveBytes:$archiveBytes,
    upstreamCheckpointRevision:"unproven-by-exporter",runtimeVersion:$runtimeVersion,
    runtimeCommit:$runtimeCommit,runtimeWheelSHA256:{sherpaOnnx:$sherpaWheelSHA256,
    sherpaOnnxCore:$coreWheelSHA256}}' >"$MODEL/provenance.json"

"$RUNTIME/bin/python3" "$ROOT/Sources/Runtime/FunASRNanoWorker.py" --self-test
"$RUNTIME/bin/python3" -c \
  'import importlib.metadata,platform; assert platform.machine()=="arm64"; assert importlib.metadata.version("sherpa-onnx")=="1.13.5"; assert importlib.metadata.version("sherpa-onnx-core")=="1.13.5"'
