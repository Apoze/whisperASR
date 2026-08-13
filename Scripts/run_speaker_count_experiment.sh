#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FROZEN_ROOT="${WHISPERASR_FROZEN_REPO_ROOT:-/Users/maz/Documents/projets/whisperASR}"
ARTIFACTS="${WHISPERASR_SPEAKER_COUNT_ROOT:-$ROOT/.build/benchmarks/speaker-count}"
MODEL_CACHE="$ARTIFACTS/model-cache"
MODE="${1:-development}"
BASE_COMMIT="72fabb14eb29268be7a1f959d52d8dd156138867"
REPORT_JSON="$ARTIFACTS/report.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E17-speaker-count.md"
EVIDENCE_ROOT="docs/japanese-live/experiments/evidence/E17"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

case "$MODE" in
  development|final) ;;
  *) echo "usage: $0 [development|final]" >&2; exit 2 ;;
esac
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls" "$MODEL_CACHE"

run_logged() {
  local log="$1"
  shift
  if "$@" >"$log" 2>&1; then tail -n 40 "$log"; return 0; fi
  tail -n 80 "$log"
  return 1
}

baseline_evidence() {
  case "$1" in
    qudu2fx3ncc) echo "$FROZEN_ROOT/.build/benchmarks/principal-speaker-attribution/development-pass2/24714AB0-F273-44A3-9828-67B54766070D/raw-asr.json" ;;
    md62mmdz0m) echo "$FROZEN_ROOT/.build/benchmarks/principal-speaker-attribution/holdout/88088247-41D7-4780-94F1-7EC7630DD312/raw-asr.json" ;;
  esac
}

e06_directory() { echo "$FROZEN_ROOT/.build/benchmarks/high-quality/offline-acceptance/qwen-ja/$1"; }
source_path() { jq -er .sourcePath "$(e06_directory "$1")/run-meta.json"; }
corpus_manifest() { echo "$ROOT/docs/japanese-live/corpora/$1/manifest.json"; }
expected_count() { [[ "$1" == qudu2fx3ncc ]] && echo 12 || echo 3; }
prior_auto() {
  [[ "$1" == qudu2fx3ncc ]] \
    && echo "$ROOT/docs/japanese-live/experiments/evidence/E16/development-quantized-raw-asr.json.gz" \
    || echo "$ROOT/docs/japanese-live/experiments/evidence/E16/holdout-quantized-raw-asr.json.gz"
}
job_id() {
  if [[ "$1" == qudu2fx3ncc ]]; then
    [[ "$2" == automatic ]] && echo 59000001-0000-4000-8000-000000000001 \
      || echo 59000001-0000-4000-8000-000000000002
  else
    [[ "$2" == automatic ]] && echo 59000002-0000-4000-8000-000000000001 \
      || echo 59000002-0000-4000-8000-000000000002
  fi
}

verify_frozen_input() {
  local corpus="$1" source manifest evidence
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  evidence="$(baseline_evidence "$corpus")"
  [[ -f "$source" && -f "$manifest" && -f "$evidence" && -f "$(prior_auto "$corpus")" ]]
  [[ "$(shasum -a 256 "$source" | awk '{print $1}')" \
    == "$(jq -er .sourceSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]]
  [[ "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    == "$(jq -er .manifestSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]]
  jq -e --argjson samples "$(jq '.fixture.sampleCount' "$manifest")" \
    '.sampleCount == $samples and .model.backend == "qwen-ja"
      and (.rawASR | length > 0) and (.alignment.mergedCues | length > 0)' \
    "$evidence" >/dev/null
}

run_controls() {
  run_logged "$ARTIFACTS/controls/build-route.log" xcrun swift test \
    --filter HighQualityAcceptanceTests/testFrozenExpectedSpeakerCountWhenOptedIn
  run_logged "$ARTIFACTS/controls/light-tests.log" xcrun swift test --skip-build \
    --filter 'HighQualityJobTests|HeavyweightModelGateTests|LiveCaptionTests/testTranslationOnlyPrimarySegmentsDropMissingTranslations|LiveCaptionTests/testClearlyNonEnglishTranslationIsRejected|QwenPseudoLiveCoordinatorTests/testPseudoLiveEngineNeverRequestsAppleSpeech|LocalDiarizationShadowTests/testUnpromotedDiarizationCannotInfluenceSubtitleBoundaries'
  python3 Scripts/report_speaker_count.py --self-test
  jq -n '{buildAndJobTests:true,cancellationTests:true,memoryGateTests:true,
    translationTests:true,liveTests:true,artifactReporterSelfTest:true}' \
    >"$ARTIFACTS/controls.json"
}

implementation_hashes() {
  local result='{}' path digest
  for path in Sources/HighQualityJob.swift Sources/HighQualityJobView.swift \
    Sources/HighQualitySpeakerKitRuntime.swift Tests/HighQualityAcceptanceTests.swift \
    Tests/HighQualityJobTests.swift Scripts/run_speaker_count_experiment.sh \
    Scripts/report_speaker_count.py Scripts/report_exclusive_reconciliation.py; do
    digest="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    result="$(jq -c --arg path "$path" --arg digest "$digest" '. + {($path):$digest}' <<<"$result")"
  done
  echo "$result"
}

unchanged_hashes() {
  local result='{}' path base candidate
  for path in Sources/AppleLiveServices.swift Sources/HighQualityForcedAlignerRuntime.swift \
    Sources/HighQualityJobView.swift Sources/HighQualityTranslationIntegrity.swift \
    Sources/LocalMLXTranslator.swift Sources/QwenPseudoLiveCoordinator.swift \
    Sources/TranslationService.swift Sources/AppState.swift Sources/LiveRecoveryStore.swift \
    Sources/LocalCaptionPipeline.swift Sources/LocalDiarizationShadow.swift \
    Sources/RecordingView.swift; do
    base="$(git show "$BASE_COMMIT:$path" | shasum -a 256 | awk '{print $1}')"
    candidate="$(shasum -a 256 "$ROOT/$path" | awk '{print $1}')"
    result="$(jq -c --arg path "$path" --arg base "$base" --arg candidate "$candidate" \
      '. + {($path):{baseSHA256:$base,candidateSHA256:$candidate}}' <<<"$result")"
  done
  echo "$result"
}

write_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" source manifest role implementation unchanged
  source="$(source_path "$corpus")"
  manifest="$(corpus_manifest "$corpus")"
  role="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo untouched-holdout)"
  implementation="$(implementation_hashes)"
  unchanged="$(unchanged_hashes)"
  mkdir -p "$directory/jobs"
  jq -n \
    --arg corpus "$corpus" --arg role "$role" \
    --arg source "$source" --arg sourceHash "$(shasum -a 256 "$source" | awk '{print $1}')" \
    --arg manifest "docs/japanese-live/corpora/$corpus/manifest.json" \
    --arg manifestHash "$(shasum -a 256 "$manifest" | awk '{print $1}')" \
    --arg evidence "$(baseline_evidence "$corpus")" \
    --arg evidenceHash "$(shasum -a 256 "$(baseline_evidence "$corpus")" | awk '{print $1}')" \
    --arg prior "docs/japanese-live/experiments/evidence/E16/$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)-quantized-raw-asr.json.gz" \
    --arg priorHash "$(shasum -a 256 "$(prior_auto "$corpus")" | awk '{print $1}')" \
    --arg baselineJob "$(job_id "$corpus" automatic)" \
    --arg candidateJob "$(job_id "$corpus" expected)" \
    --arg baseCommit "$BASE_COMMIT" --argjson count "$(expected_count "$corpus")" \
    --argjson implementation "$implementation" --argjson unchanged "$unchanged" \
    '{schemaVersion:1,experiment:"E17-speaker-count",corpusID:$corpus,corpusRole:$role,
      sourcePath:$source,sourceSHA256:$sourceHash,corpusManifestPath:$manifest,
      corpusManifestSHA256:$manifestHash,frozenUpstreamEvidencePath:$evidence,
      frozenUpstreamEvidenceSHA256:$evidenceHash,priorAutoEvidencePath:$prior,
      priorAutoEvidenceSHA256:$priorHash,expectedSpeakerCount:$count,
      expectedCountProvenance:(if $corpus=="qudu2fx3ncc" then
        "12 unique acoustic identities; SPEAKER_13 is the declared group/overlap pseudo-Speaker"
        else "3 unique named Speakers in the authoritative annotations" end),
      jobs:{baseline:$baselineJob,candidate:$candidateJob},baseCommit:$baseCommit,
      settings:{baseline:{precision:"quantized",useExclusiveReconciliation:false,
        principalAttribution:"longest-overlap-stable-label-span",speakerCountPolicy:"automatic",
        numberOfSpeakers:null,clusterDistanceThreshold:null,fullRedundancy:true},
        candidate:{precision:"quantized",useExclusiveReconciliation:false,
        principalAttribution:"longest-overlap-stable-label-span",speakerCountPolicy:"expected",
        numberOfSpeakers:$count,clusterDistanceThreshold:null,fullRedundancy:true}},
      failurePolicy:{candidateAttribution:"withheld until build, source, input, artifact, model-load and memory-release controls pass"},
      executionImplementationSHA256:$implementation,reviewedImplementationSHA256:$implementation,
      unchangedImplementations:$unchanged}' >"$directory/run-meta.json"
}

artifact_hashes() {
  local job="$1" result='{}' name digest
  for name in japanese-transcript.txt english-translation-transcript.txt \
    english-subtitles.vtt english-subtitles.srt raw-asr.json manifest.json; do
    digest="$(shasum -a 256 "$job/$name" | awk '{print $1}')"
    result="$(jq -c --arg name "$name" --arg digest "$digest" '. + {($name):$digest}' <<<"$result")"
  done
  echo "$result"
}

finalize_metadata() {
  local corpus="$1" directory="$ARTIFACTS/$1" baseline candidate implementation
  baseline="$(artifact_hashes "$directory/jobs/$(job_id "$corpus" automatic)")"
  candidate="$(artifact_hashes "$directory/jobs/$(job_id "$corpus" expected)")"
  implementation="$(implementation_hashes)"
  jq --argjson baseline "$baseline" --argjson candidate "$candidate" \
    --argjson implementation "$implementation" \
    '. + {artifactSHA256:{baseline:$baseline,candidate:$candidate},
      reviewedImplementationSHA256:$implementation}' "$directory/run-meta.json" \
    >"$directory/run-meta.updated.json"
  mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
}

check_variant() {
  local corpus="$1" mode="$2" directory="$ARTIFACTS/$1" job expected
  job="$directory/jobs/$(job_id "$corpus" "$mode")"
  expected="$(expected_count "$corpus")"
  jq -e '.status == "completed" and .failures == []' "$job/manifest.json" >/dev/null
  if [[ "$mode" == automatic ]]; then
    jq -e '.speakerCountPolicy.mode == "automatic" and (.speakerCountPolicy.expectedCount == null)
      and .diarization.speakerCountPolicy.mode == "automatic"' "$job/raw-asr.json" >/dev/null
  else
    jq -e --argjson expected "$expected" '.speakerCountPolicy.mode == "expected"
      and .speakerCountPolicy.expectedCount == $expected
      and .diarization.speakerCountPolicy.expectedCount == $expected' "$job/raw-asr.json" >/dev/null
  fi
  jq -e '.diarization.validationDiagnostics == [] and (.diarization.rawSpans|length)>0
    and (.diarization.mappings|length)>0 and .translation.validationFailures == []' \
    "$job/raw-asr.json" >/dev/null
}

diagnose_failure() {
  local corpus="$1" mode="$2" directory="$ARTIFACTS/$1" build=false source=false inputs=false artifacts=false classification
  if xcrun swift build >"$directory/$mode-infrastructure-diagnostics.log" 2>&1; then build=true; fi
  [[ "$(shasum -a 256 "$(source_path "$corpus")" | awk '{print $1}')" \
    == "$(jq -r .sourceSHA256 "$(e06_directory "$corpus")/run-meta.json")" ]] && source=true
  jq empty "$(baseline_evidence "$corpus")" "$(corpus_manifest "$corpus")" >/dev/null 2>&1 && inputs=true
  find "$directory/jobs" -name '*.json' -type f -exec jq empty {} + >/dev/null 2>&1 && artifacts=true
  if [[ "$build" != true ]]; then classification=runner-build
  elif [[ "$source" != true || "$inputs" != true ]]; then classification=runner-input
  elif [[ "$artifacts" != true ]]; then classification=runner-artifact
  else classification=application-runtime; fi
  jq -n --arg classification "$classification" --arg mode "$mode" --argjson build "$build" \
    --argjson source "$source" --argjson inputs "$inputs" --argjson artifacts "$artifacts" \
    '{classification:$classification,candidateAttribution:"withheld",mode:$mode,
      runnerBuild:$build,sourceIntegrity:$source,inputJSON:$inputs,artifactJSON:$artifacts}' \
    >"$directory/$mode-infrastructure-diagnostics.json"
}

run_variant() {
  local corpus="$1" mode="$2" directory="$ARTIFACTS/$1" job log
  job="$directory/jobs/$(job_id "$corpus" "$mode")"
  log="$directory/$mode.log"
  verify_frozen_input "$corpus"
  if [[ -f "$job/manifest.json" ]] && jq -e '.status == "completed"' "$job/manifest.json" >/dev/null; then
    check_variant "$corpus" "$mode"; return
  fi
  [[ ! -e "$job" ]] || { echo "Incomplete run retained at $job; refusing overwrite." >&2; return 1; }
  if ! run_logged "$log" env WHISPERASR_RUN_SPEAKER_COUNT_EXPERIMENT=1 \
      WHISPERASR_SPEAKER_COUNT_EVIDENCE="$(baseline_evidence "$corpus")" \
      WHISPERASR_SPEAKER_COUNT_SOURCE="$(source_path "$corpus")" \
      WHISPERASR_SPEAKER_COUNT_OUTPUT="$directory/jobs" \
      WHISPERASR_SPEAKER_COUNT_JOB_ID="$(job_id "$corpus" "$mode")" \
      WHISPERASR_SPEAKER_COUNT_MODE="$mode" \
      WHISPERASR_EXPECTED_SPEAKER_COUNT="$(expected_count "$corpus")" \
      WHISPERASR_SPEAKER_COUNT_MODEL_CACHE="$MODEL_CACHE" \
      xcrun swift test --skip-build \
        --filter HighQualityAcceptanceTests/testFrozenExpectedSpeakerCountWhenOptedIn; then
    diagnose_failure "$corpus" "$mode"; return 1
  fi
  check_variant "$corpus" "$mode"
}

snapshot() {
  local corpus="$1" split mode directory job evidence="$ROOT/$EVIDENCE_ROOT"
  split="$([[ "$corpus" == qudu2fx3ncc ]] && echo development || echo holdout)"
  directory="$ARTIFACTS/$corpus"
  mkdir -p "$evidence"
  for mode in automatic expected; do
    job="$directory/jobs/$(job_id "$corpus" "$mode")"
    gzip -n -c "$job/raw-asr.json" >"$evidence/$split-$mode-raw-asr.json.gz"
    cp "$job/manifest.json" "$evidence/$split-$mode-manifest.json"
    cp "$directory/$mode.log" "$evidence/$split-$mode.log"
    for name in japanese-transcript.txt english-translation-transcript.txt \
      english-subtitles.vtt english-subtitles.srt; do
      cp "$job/$name" "$evidence/$split-$mode-$name"
    done
  done
  cp "$directory/run-meta.json" "$evidence/$split-run-meta.json"
  cp "$ARTIFACTS/controls.json" "$evidence/controls.json"
  cp "$ARTIFACTS/controls/"*.log "$evidence/"
}

write_report() {
  python3 Scripts/report_speaker_count.py "$ARTIFACTS" --json "$REPORT_JSON" --markdown "$REPORT_MD"
  cp "$REPORT_JSON" "$ROOT/$EVIDENCE_ROOT/report.json"
}

run_corpus() {
  local corpus="$1" directory="$ARTIFACTS/$1"
  verify_frozen_input "$corpus"
  [[ -f "$directory/run-meta.json" ]] || write_metadata "$corpus"
  run_variant "$corpus" automatic
  run_variant "$corpus" expected
  finalize_metadata "$corpus"
  snapshot "$corpus"
  write_report
}

if [[ "$MODE" == development ]]; then
  run_controls
  run_corpus qudu2fx3ncc
  jq '{developmentPromotionEligible,decision}' "$REPORT_JSON"
  exit 0
fi

[[ -f "$REPORT_JSON" ]] || { echo "Run development first." >&2; exit 1; }
write_report
jq -e '.holdoutRun == false and .developmentPromotionEligible == true
  and ([.rows[] | select(.role == "development") | .gates[]] | all)' \
  "$REPORT_JSON" >/dev/null || {
  echo "Development failed; untouched holdout remains closed." >&2; exit 1;
}
cp "$REPORT_JSON" "$ROOT/$EVIDENCE_ROOT/pre-holdout-report.json"
jq -n \
  --arg report "$EVIDENCE_ROOT/pre-holdout-report.json" \
  --arg reportHash "$(shasum -a 256 "$REPORT_JSON" | awk '{print $1}')" \
  --arg scorerHash "$(shasum -a 256 Scripts/report_speaker_count.py | awk '{print $1}')" \
  --arg metricsHash "$(shasum -a 256 Scripts/report_exclusive_reconciliation.py | awk '{print $1}')" \
  --arg runnerHash "$(shasum -a 256 Scripts/run_speaker_count_experiment.sh | awk '{print $1}')" \
  '{schemaVersion:1,decision:"holdout-authorized",developmentReportPath:$report,
    developmentReportSHA256:$reportHash,
    scoringImplementationSHA256:{"Scripts/report_speaker_count.py":$scorerHash,
      "Scripts/report_exclusive_reconciliation.py":$metricsHash},
    runnerSHA256:$runnerHash}' >"$ROOT/$EVIDENCE_ROOT/pre-holdout-authorization.json"
run_corpus md62mmdz0m
jq '{promote,decision}' "$REPORT_JSON"
