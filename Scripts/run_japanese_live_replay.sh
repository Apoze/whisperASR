#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="5874bdeeaddf968ab73e005eb287e1b597b0eb37"
BASE="$ROOT/.build/benchmarks/japanese-live/tools/whisperlivekit/$COMMIT"
SOURCE="$BASE/source"
SERVER="$BASE/venv/bin/whisperlivekit-server"
MLX_REVISION="a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
MLX_MODEL="$ROOT/.build/benchmarks/japanese-live/tools/models/mlx-whisper-large-v3-turbo/$MLX_REVISION"
DECODER="$BASE/models/openai/large-v3-turbo.pt"
WARMUP="$BASE/models/warmup-ja.wav"
POLICY="${WHISPERASR_WLK_POLICY:-simulstreaming}"
MIN_CHUNK_SECONDS="${WHISPERASR_WLK_MIN_CHUNK_SECONDS:-0.1}"
REPLAY_SCOPE="${WHISPERASR_L6_SCOPE:-corrective}"
if [[ -n "${WHISPERASR_WLK_RETENTION_SECONDS:-}" ]]; then
  RETENTION_SECONDS="$WHISPERASR_WLK_RETENTION_SECONDS"
elif [[ "$REPLAY_SCOPE" == "full-video" ]]; then
  RETENTION_SECONDS=1200
else
  RETENTION_SECONDS=300
fi
case "$POLICY" in
  simulstreaming|localagreement) ;;
  *) echo "Unsupported WHISPERASR_WLK_POLICY: $POLICY" >&2; exit 2 ;;
esac
RUN_ID="${WHISPERASR_L6_RUN_ID:-l6-live-$POLICY-$(date -u +%Y%m%dT%H%M%SZ)}"
OUTPUT="$ROOT/.build/benchmarks/japanese-live/runs/$RUN_ID"
if [[ -n "${WHISPERASR_WLK_PORT:-}" ]]; then
  PORT="$WHISPERASR_WLK_PORT"
else
  PORT="$("$BASE/venv/bin/python" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
fi
SOURCES="${WHISPERASR_L6_SOURCES:-apple-speech,whisperlivekit}"
SANDBOX='(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(allow network-outbound (remote ip "localhost:*"))'

if [[ -e "$OUTPUT" ]]; then
  echo "Refusing to reuse an existing live replay directory: $OUTPUT" >&2
  exit 2
fi
mkdir -p "$OUTPUT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
/usr/bin/sandbox-exec -p "$SANDBOX" \
  xcrun swift test --disable-sandbox -c release --filter JapaneseLiveReplayTests

SERVER_PID=0

cleanup() {
  if [[ "$SERVER_PID" -gt 0 ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in {1..100}; do
      if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
      sleep 0.05
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ ",$SOURCES," == *,whisperlivekit,* ]]; then
  if /usr/bin/nc -G 1 -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    echo "Refusing to reuse an occupied WhisperLiveKit port: $PORT" >&2
    exit 2
  fi
  test -x "$SERVER"
  test "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT"
  test -z "$(git -C "$SOURCE" status --porcelain --untracked-files=normal)"
  test "$(shasum -a 256 "$SOURCE/uv.lock" | cut -d ' ' -f 1)" = \
    "06750b16caa60432e7d1a9427cd2196e6bf926f20fc15d3c77cba78469e99ec1"
  test "$(shasum -a 256 "$MLX_MODEL/weights.safetensors" | cut -d ' ' -f 1)" = \
    "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"
  test "$(shasum -a 256 "$MLX_MODEL/config.json" | cut -d ' ' -f 1)" = \
    "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"
  if [[ "$POLICY" == "simulstreaming" ]]; then
    test "$(shasum -a 256 "$DECODER" | cut -d ' ' -f 1)" = \
      "aff26ae408abcba5fbf8813c21e62b0941638c5f6eebfb145be0c9839262a19a"
  fi
  test "$(shasum -a 256 "$WARMUP" | cut -d ' ' -f 1)" = \
    "82df6b6ad5cebc55f727443d4a1c5c4a11d2c26cb75ef43e9ee091b8b7029ae5"

  SERVER_ARGS=(
    --host 127.0.0.1
    --port "$PORT"
    --language ja
    --pcm-input
    --warmup-file "$WARMUP"
    --min-chunk-size "$MIN_CHUNK_SECONDS"
    --vac-chunk-size 0.04
    --retention-seconds "$RETENTION_SECONDS"
    --log-level INFO
  )
  if [[ "$POLICY" == "simulstreaming" ]]; then
    SERVER_ARGS+=(
      --backend-policy simulstreaming
      --backend mlx-whisper
      --model large-v3-turbo
      --encoder-model-path "$MLX_MODEL"
      --decoder-model-path "$DECODER"
      --decoder beam
      --beams 1
      --frame-threshold 25
      --audio-max-len 30
      --audio-min-len 0
    )
  else
    SERVER_ARGS+=(
      --backend-policy localagreement
      --backend mlx-whisper
      --model large-v3-turbo
      --model_dir "$MLX_MODEL"
      --buffer_trimming segment
      --buffer_trimming_sec 15
    )
  fi

  HF_HUB_OFFLINE=1 \
  TRANSFORMERS_OFFLINE=1 \
  HF_HUB_DISABLE_TELEMETRY=1 \
  /usr/bin/sandbox-exec -p "$SANDBOX" \
    "$SERVER" "${SERVER_ARGS[@]}" \
    >"$OUTPUT/whisperlivekit.log" 2>&1 &
  SERVER_PID=$!

  READY=0
  for _ in {1..180}; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      break
    fi
    if /usr/bin/curl --silent --fail "http://127.0.0.1:$PORT/health" \
      | /usr/bin/jq -e '.status == "ok" and .ready == true' >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done
  if [[ "$READY" != "1" ]]; then
    tail -100 "$OUTPUT/whisperlivekit.log" >&2
    exit 2
  fi
fi

BENCHMARK_COMMIT="$(git rev-parse HEAD)"
BENCHMARK_DIRTY=0
if [[ -n "$(git status --porcelain)" ]]; then
  BENCHMARK_DIRTY=1
fi

RUNNER=(
  /Applications/Xcode.app/Contents/Developer/usr/bin/xctest
  -XCTest WhisperASRTests.JapaneseLiveReplayTests/testStressSourcesWhenOptedIn
  "$ROOT/.build/release/WhisperASRPackageTests.xctest"
)
REMOTE_DENIED=1
RUNNER=(/usr/bin/sandbox-exec -p "$SANDBOX" "${RUNNER[@]}")

WHISPERASR_L6_LIVE_REPLAY=1 \
WHISPERASR_L6_RUN_ID="$RUN_ID" \
WHISPERASR_L6_REPLAY_COUNT="${WHISPERASR_L6_REPLAY_COUNT:-1}" \
WHISPERASR_L6_WINDOW_LIMIT="${WHISPERASR_L6_WINDOW_LIMIT:-1}" \
WHISPERASR_L6_SOURCES="$SOURCES" \
WHISPERASR_L6_SCOPE="$REPLAY_SCOPE" \
WHISPERASR_WLK_POLICY="$POLICY" \
WHISPERASR_WLK_RETENTION_SECONDS="$RETENTION_SECONDS" \
WHISPERASR_WLK_MIN_CHUNK_SECONDS="$MIN_CHUNK_SECONDS" \
WHISPERASR_WLK_URL="ws://127.0.0.1:$PORT/asr?language=ja&mode=diff" \
WHISPERASR_WLK_PID="$SERVER_PID" \
WHISPERASR_BENCHMARK_COMMIT="$BENCHMARK_COMMIT" \
WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256="${WHISPERASR_BENCHMARK_SOURCE_TREE_SHA256:-unknown}" \
WHISPERASR_BENCHMARK_RUNTIME_SHA256="${WHISPERASR_BENCHMARK_RUNTIME_SHA256:-unknown}" \
WHISPERASR_BENCHMARK_DIRTY="$BENCHMARK_DIRTY" \
WHISPERASR_REMOTE_NETWORK_DENIED="$REMOTE_DENIED" \
WHISPERASR_MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)" \
WHISPERASR_MACOS_BUILD="$(/usr/bin/sw_vers -buildVersion)" \
  "${RUNNER[@]}"

echo "Reports: $OUTPUT"
