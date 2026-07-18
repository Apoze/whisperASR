#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAV="${WHISPERASR_VOXTRAL_BAKEOFF_WAV:-$ROOT/.build/benchmarks/canonical-firefox-16k-mono.wav}"
CORPUS="${WHISPERASR_JAPANESE_BAKEOFF_CORPUS:-$ROOT/.build/benchmarks/corpora/easy-japanese-1}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
xcrun swift test -c release \
  --filter VoxtralHelperRuntimeTests/testContinuousConfigurationsPinBothModelsAndSupportedDelays
"$ROOT/Scripts/build_mlx_metallib.sh" release

for specification in q4:960 q6:960 q6:1200 q6:2400; do
  variant="${specification%%:*}"
  delay="${specification##*:}"
  scope="${variant}-${delay}-full"
  maximum_first_delta=2500
  maximum_eligible_prefix=3000
  if [[ "$delay" == "2400" ]]; then
    # Quality ceiling only: keep measuring it while recording that it misses
    # the live target used by the other configurations.
    maximum_first_delta=5000
    maximum_eligible_prefix=5000
  fi

  WHISPERASR_VOXTRAL_STREAM_BENCHMARK_WAV="$WAV" \
  WHISPERASR_TRUE_SPEECH_START_SAMPLE=24000 \
  WHISPERASR_VOXTRAL_HELPER_VARIANT="$variant" \
  WHISPERASR_VOXTRAL_HELPER_DELAY_MS="$delay" \
  WHISPERASR_VOXTRAL_MAX_FIRST_DELTA_MS="$maximum_first_delta" \
  WHISPERASR_VOXTRAL_MAX_ELIGIBLE_PREFIX_MS="$maximum_eligible_prefix" \
    xcrun swift test -c release --skip-build \
      --filter LocalPrototypeBenchmarkTests/testVoxtralRawStreamingWhenOptedIn

  WHISPERASR_VOXTRAL_HELPER_ENDURANCE_WAV="$WAV" \
  WHISPERASR_TRUE_SPEECH_START_SAMPLE=24000 \
  WHISPERASR_VOXTRAL_ENDURANCE_REPLAY_COUNT=4 \
  WHISPERASR_VOXTRAL_HELPER_VARIANT="$variant" \
  WHISPERASR_VOXTRAL_HELPER_DELAY_MS="$delay" \
  WHISPERASR_VOXTRAL_MAX_FIRST_DELTA_MS="$maximum_first_delta" \
  WHISPERASR_VOXTRAL_MAX_ELIGIBLE_PREFIX_MS="$maximum_eligible_prefix" \
    xcrun swift test -c release --skip-build \
      --filter LocalPrototypeBenchmarkTests/testVoxtralContinuousHelperEnduranceWhenOptedIn

  WHISPERASR_JAPANESE_BAKEOFF=1 \
  WHISPERASR_JAPANESE_BAKEOFF_SCOPE="$scope" \
  WHISPERASR_JAPANESE_BAKEOFF_CORPUS="$CORPUS" \
  WHISPERASR_JAPANESE_BAKEOFF_ENGINES=voxtral-continuous \
  WHISPERASR_JAPANESE_BAKEOFF_APPLE=1 \
  WHISPERASR_VOXTRAL_HELPER_VARIANT="$variant" \
  WHISPERASR_VOXTRAL_HELPER_DELAY_MS="$delay" \
    xcrun swift test -c release --skip-build \
      --filter JapaneseModelBakeoffTests/testJapaneseASRBakeoffWhenOptedIn
done

WHISPERASR_VOXTRAL_AGGREGATE_BLIND=1 \
  xcrun swift test -c release --skip-build \
    --filter VoxtralConfigurationComparisonTests/testAggregateBlindConfigurationComparisonWhenOptedIn

echo "Reports: $ROOT/.build/benchmarks"
