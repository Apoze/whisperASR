#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAV="${1:-$ROOT/.build/benchmarks/canonical-firefox-16k-mono.wav}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# This sample-level annotation belongs to the canonical Firefox fixture. For
# another WAV, provide WHISPERASR_TRUE_SPEECH_START_SAMPLE explicitly.
if [[ -z "${WHISPERASR_TRUE_SPEECH_START_SAMPLE:-}" && "$WAV" == "$ROOT/.build/benchmarks/canonical-firefox-16k-mono.wav" ]]; then
  export WHISPERASR_TRUE_SPEECH_START_SAMPLE=24000
fi

cd "$ROOT"
# Create each test bundle before copying MLX's runtime Metal library into it.
# The selected unit test does not invoke MLX and is intentionally cheap.
xcrun swift test --filter LiveCaptionTests/testEachPrototypeLoadsOnlyItsRequiredModels
"$ROOT/Scripts/build_mlx_metallib.sh" debug
WHISPERASR_MODEL_SMOKE=1 WHISPERASR_BENCHMARK_WAV="$WAV" xcrun swift test \
  --skip-build \
  --filter LocalPrototypeBenchmarkTests/testVoxtralCohereSmokeWhenOptedIn
WHISPERASR_VOXTRAL_DELAY_MS=960 WHISPERASR_BENCHMARK_WAV="$WAV" xcrun swift test \
  --skip-build \
  --filter LocalPrototypeBenchmarkTests/testCanonicalQualityBenchmarkWhenOptedIn

# Optional four-rung oracle. Candidate JSON may be `{ "corpusID": "…",
# "turns": [...] }` or a bare turn array; absent candidates remain explicit in
# scaffold reports. The complete gate must never silently skip the oracle.
if [[ "${WHISPERASR_QUALITY_ORACLE_REQUIRE_COMPLETE:-0}" == "1" && -z "${WHISPERASR_QUALITY_ORACLE_MANIFEST:-}" ]]; then
  echo "WHISPERASR_QUALITY_ORACLE_REQUIRE_COMPLETE=1 requires WHISPERASR_QUALITY_ORACLE_MANIFEST" >&2
  exit 1
fi
if [[ -n "${WHISPERASR_QUALITY_ORACLE_MANIFEST:-}" ]]; then
  xcrun swift test --skip-build \
    --filter LocalPrototypeBenchmarkTests/testJapaneseEnglishQualityOracleWhenOptedIn
fi

xcrun swift test -c release \
  --filter LiveCaptionTests/testEachPrototypeLoadsOnlyItsRequiredModels
"$ROOT/Scripts/build_mlx_metallib.sh" release
WHISPERASR_TRUE_SPEECH_START_SAMPLE="${WHISPERASR_TRUE_SPEECH_START_SAMPLE:-}" \
  WHISPERASR_VOXTRAL_HELPER_ENDURANCE_WAV="$WAV" \
  xcrun swift test -c release --skip-build \
  --filter LocalPrototypeBenchmarkTests/testVoxtralContinuousHelperEnduranceWhenOptedIn

# Speaker splitting remains shadow-only until independent 20-point calibration
# and validation splits pass the pinned runtime/model/transcript proof.
if [[ -n "${WHISPERASR_VOXTRAL_MARKER_CALIBRATION_PROOF:-}" ]]; then
  xcrun swift test -c release --skip-build \
    --filter LocalPrototypeBenchmarkTests/testVoxtralMarkerCalibrationWhenOptedIn
fi
if [[ -n "${WHISPERASR_DIARIZATION_BENCHMARK_WAV:-}" ]]; then
  DIARIZATION_CANDIDATES="${WHISPERASR_DIARIZATION_CANDIDATES:-ls-eend-dihard3-step100 sortformer-fast-v2.1-fp16}"
  if [[ "${WHISPERASR_TEST_SORTFORMER_BALANCED:-0}" == "1" ]]; then
    DIARIZATION_CANDIDATES="$DIARIZATION_CANDIDATES sortformer-balanced-v2.1-fp16"
  fi
  for candidate in $DIARIZATION_CANDIDATES; do
    WHISPERASR_DIARIZATION_CANDIDATE="$candidate" \
      WHISPERASR_DIARIZATION_REPLAY_COUNT="${WHISPERASR_DIARIZATION_REPLAY_COUNT:-4}" \
      xcrun swift test -c release --skip-build \
      --filter DiarizationBakeoffTests/testOptInReplay
  done
fi
WHISPERASR_BENCHMARK_VARIANT=release WHISPERASR_VOXTRAL_DELAY_MS=960 \
  WHISPERASR_REALTIME_ENGINE=voxtralCohereApple WHISPERASR_REALTIME_BENCHMARK_WAV="$WAV" \
  xcrun swift test -c release --skip-build \
  --filter LocalPrototypeBenchmarkTests/testVoxtralRealtimeBacklogWhenOptedIn

# Q6 is a conditional follow-up, not another default 2 GB download.
if [[ "${WHISPERASR_TEST_COHERE_Q6:-0}" == "1" ]]; then
  WHISPERASR_BENCHMARK_VARIANT=release WHISPERASR_VOXTRAL_DELAY_MS=960 \
    WHISPERASR_REALTIME_ENGINE=voxtralCohereApple WHISPERASR_COHERE_QUANTIZATION=q6 \
    WHISPERASR_REALTIME_BENCHMARK_WAV="$WAV" xcrun swift test -c release --skip-build \
    --filter LocalPrototypeBenchmarkTests/testVoxtralRealtimeBacklogWhenOptedIn
fi
