#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="$ROOT/.build/benchmarks/japanese-live/runs"
VIDEO_ROOT="${WHISPERASR_JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
APP_BINARY="$ROOT/WhisperASR.app/Contents/MacOS/WhisperASR"
FIREFOX_BINARY="/Applications/Firefox.app/Contents/MacOS/firefox"
BUILD_ATTESTATION="$ROOT/.build/benchmarks/japanese-live/tools/l7-app-build.json"
KOTOBA_MODEL="$ROOT/.build/benchmarks/japanese-live/tools/models/kotoba-whisper-v2.0-ggml/e3a0cf6a62b95911703cfb97d819292e058f12c3/ggml-kotoba-whisper-v2.0-q5_0.bin"
TURBO_MODEL="/Users/maz/Library/Application Support/WhisperASR/Models/ggml-large-v3-turbo.bin"

sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d ' ' -f 1
}

usage() {
  echo "Usage:" >&2
  echo "  $0 build" >&2
  echo "  $0 prepare <turbo|kotoba-q5> <qudu2fx3ncc|md62mmdz0m>" >&2
  echo "  $0 finalize <run-directory>" >&2
  echo "  $0 aggregate <four finalized run-directories>" >&2
  exit 2
}

require_clean_worktree() {
  local dirty
  dirty="$(git -C "$ROOT" status --porcelain)"
  [[ -z "$dirty" ]] || {
    echo "L7 requires a clean Git worktree." >&2
    echo "$dirty" >&2
    exit 1
  }
}

build_app() {
  require_clean_worktree
  /usr/bin/pgrep -x WhisperASR >/dev/null && {
    echo "Quit WhisperASR before building the attested L7 app." >&2
    exit 1
  }
  /usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    "$ROOT/Scripts/build_release.sh"
  [[ -f "$APP_BINARY" ]] || { echo "Release app binary was not produced." >&2; exit 1; }

  local commit timestamp destination temporary
  commit="$(git -C "$ROOT" rev-parse HEAD)"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  destination="$(dirname "$BUILD_ATTESTATION")"
  /bin/mkdir -p "$destination"
  temporary="$(/usr/bin/mktemp "$destination/.l7-app-build.XXXXXX")"
  /usr/bin/jq -n \
    --arg commit "$commit" \
    --arg builtAt "$timestamp" \
    --arg appFile "$APP_BINARY" \
    --arg appSHA256 "$(sha256 "$APP_BINARY")" \
    --arg macOS "$(/usr/bin/sw_vers -productVersion)" \
    --arg macOSBuild "$(/usr/bin/sw_vers -buildVersion)" \
    --arg swift "$(/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift --version | /usr/bin/head -1)" \
    '{
      schemaVersion: 1, git: {commit: $commit, dirty: false}, builtAt: $builtAt,
      application: {file: $appFile, sha256: $appSHA256},
      toolchain: {macOS: $macOS, macOSBuild: $macOSBuild, swift: $swift}
    }' > "$temporary"
  /bin/mv "$temporary" "$BUILD_ATTESTATION"
  echo "BUILD_ATTESTATION=$BUILD_ATTESTATION"
}

find_video() {
  local expected_sha="$1"
  local search_root="$2"
  local file
  while IFS= read -r file; do
    if [[ "$(sha256 "$file")" == "$expected_sha" ]]; then
      echo "$file"
      return 0
    fi
  done < <(/usr/bin/find "$search_root" -type f \( -name '*.webm' -o -name '*.mp4' \) -print)
  return 1
}

prepare_run() {
  local candidate="${1:-}"
  local corpus="${2:-}"
  case "$candidate" in
    turbo)
      local model="$TURBO_MODEL"
      local model_id="large-v3-turbo"
      local model_revision="5359861c739e955e79d9a303bcbc70fb988958b1"
      local expected_model_sha="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
      ;;
    kotoba-q5)
      local model="$KOTOBA_MODEL"
      local model_id="kotoba-tech/kotoba-whisper-v2.0-ggml"
      local model_revision="e3a0cf6a62b95911703cfb97d819292e058f12c3"
      local expected_model_sha="4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"
      ;;
    *) usage ;;
  esac
  case "$corpus" in
    qudu2fx3ncc) local video_search_root="$VIDEO_ROOT/1" ;;
    md62mmdz0m) local video_search_root="$VIDEO_ROOT/2" ;;
    *) usage ;;
  esac

  local manifest="$ROOT/docs/japanese-live/corpora/$corpus/manifest.json"
  for file in "$manifest" "$model" "$APP_BINARY" "$FIREFOX_BINARY" "$BUILD_ATTESTATION"; do
    [[ -f "$file" ]] || { echo "Missing required file: $file" >&2; exit 1; }
  done
  [[ -d "$video_search_root" ]] || { echo "Missing video directory: $video_search_root" >&2; exit 1; }
  [[ "$(sha256 "$model")" == "$expected_model_sha" ]] || {
    echo "Model SHA-256 does not match the pinned candidate." >&2
    exit 1
  }
  local expected_video_sha
  expected_video_sha="$(/usr/bin/jq -er '.source.references[] | select(.label == "source-video") | .sha256' "$manifest")"
  local video
  video="$(find_video "$expected_video_sha" "$video_search_root")" || {
    echo "No supplied video matches $expected_video_sha under $video_search_root" >&2
    exit 1
  }
  local fixture
  fixture="$ROOT/$(/usr/bin/jq -er '.fixture.path' "$manifest")"
  [[ -f "$fixture" ]] || { echo "Missing corpus fixture: $fixture" >&2; exit 1; }
  [[ "$(sha256 "$fixture")" == "$(/usr/bin/jq -er '.fixture.sha256' "$manifest")" ]] || {
    echo "Corpus fixture SHA-256 mismatch." >&2
    exit 1
  }

  cd "$ROOT"
  require_clean_worktree
  if /usr/bin/pgrep -x WhisperASR >/dev/null; then
    echo "Quit the existing WhisperASR process before preparing a candidate." >&2
    exit 1
  fi

  local commit
  commit="$(git rev-parse HEAD)"
  [[ "$(/usr/bin/jq -er '.git.commit' "$BUILD_ATTESTATION")" == "$commit" ]] || {
    echo "The L7 app attestation was built from another commit. Run '$0 build'." >&2
    exit 1
  }
  [[ "$(/usr/bin/jq -er '.application.sha256' "$BUILD_ATTESTATION")" == "$(sha256 "$APP_BINARY")" ]] || {
    echo "The current app binary differs from its L7 build attestation." >&2
    exit 1
  }
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local run="$RUNS/l7-firefox-$candidate-$corpus-$timestamp"
  /bin/mkdir -p "$run"

  local firefox_version
  firefox_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Firefox.app/Contents/Info.plist)"
  local app_sha firefox_sha manifest_sha fixture_sha build_attestation_sha
  app_sha="$(sha256 "$APP_BINARY")"
  firefox_sha="$(sha256 "$FIREFOX_BINARY")"
  manifest_sha="$(sha256 "$manifest")"
  fixture_sha="$(sha256 "$fixture")"
  build_attestation_sha="$(sha256 "$BUILD_ATTESTATION")"

  /usr/bin/jq -n \
    --arg status "prepared" \
    --arg commit "$commit" \
    --arg candidate "$candidate" \
    --arg modelID "$model_id" \
    --arg modelRevision "$model_revision" \
    --arg modelFile "$model" \
    --arg modelSHA256 "$expected_model_sha" \
    --arg corpusID "$corpus" \
    --arg manifestFile "$manifest" \
    --arg manifestSHA256 "$manifest_sha" \
    --arg annotationStatus "$(/usr/bin/jq -er '.annotations.status' "$manifest")" \
    --arg videoFile "$video" \
    --arg videoSHA256 "$expected_video_sha" \
    --arg fixtureFile "$fixture" \
    --arg fixtureSHA256 "$fixture_sha" \
    --arg appFile "$APP_BINARY" \
    --arg appSHA256 "$app_sha" \
    --arg buildAttestationFile "$BUILD_ATTESTATION" \
    --arg buildAttestationSHA256 "$build_attestation_sha" \
    --arg firefoxVersion "$firefox_version" \
    --arg firefoxFile "$FIREFOX_BINARY" \
    --arg firefoxSHA256 "$firefox_sha" \
    --arg preparedAt "$timestamp" \
    '{
      schemaVersion: 1,
      status: $status,
      decisionScope: "diagnostic-only",
      git: {commit: $commit, dirty: false},
      candidate: {
        id: $candidate, modelID: $modelID, revision: $modelRevision,
        file: $modelFile, sha256: $modelSHA256
      },
      corpus: {
        id: $corpusID, manifestFile: $manifestFile,
        manifestSHA256: $manifestSHA256, annotationStatus: $annotationStatus,
        fixtureFile: $fixtureFile, fixtureSHA256: $fixtureSHA256
      },
      source: {videoFile: $videoFile, videoSHA256: $videoSHA256},
      application: {
        file: $appFile, sha256: $appSHA256,
        buildAttestationFile: $buildAttestationFile,
        buildAttestationSHA256: $buildAttestationSHA256
      },
      captureApplication: {
        bundleID: "org.mozilla.firefox", version: $firefoxVersion,
        executableFile: $firefoxFile, executableSHA256: $firefoxSHA256
      },
      configuration: {
        pipeline: "whisperTurboApple", sourceLocale: "ja",
        translationMode: "adaptive", microphone: false,
        keepOriginalTranscript: true, realTimeReplayCount: 1
      },
      network: {
        scope: "not-isolated-in-L7",
        note: "Physical offline proof is reserved for L10; this run cannot prove Apple services offline."
      },
      preparedAt: $preparedAt
    }' > "$run/run-manifest.json"

  /usr/bin/defaults write com.whisperasr.app liveCaptionMode whisperEnglish
  /usr/bin/defaults write com.whisperasr.app localEnglishEngine whisperTurboApple
  /usr/bin/defaults write com.whisperasr.app localSourceLocale ja
  /usr/bin/defaults write com.whisperasr.app appleTranslationMode adaptive
  /usr/bin/defaults write com.whisperasr.app keepOriginalTranscript -bool true

  /usr/bin/open -n -F \
    --env WHISPERASR_BENCHMARK=1 \
    --env WHISPERASR_CAPTURE_CANONICAL=1 \
    --env WHISPERASR_BENCHMARK_OUTPUT_DIR="$run" \
    --env WHISPERASR_L7_WHISPER_CANDIDATE="$candidate" \
    --env WHISPERASR_KOTOBA_Q5_MODEL="$KOTOBA_MODEL" \
    --stdout "$run/application.log" \
    --stderr "$run/application.log" \
    "$ROOT/WhisperASR.app"
  local app_pid=""
  for _ in {1..50}; do
    app_pid="$(/usr/bin/pgrep -x WhisperASR || true)"
    [[ -n "$app_pid" ]] && break
    /bin/sleep 0.1
  done
  [[ -n "$app_pid" ]] || {
    echo "WhisperASR did not stay running after launch." >&2
    exit 1
  }
  echo "$app_pid" > "$run/application.pid"

  echo "RUN_DIRECTORY=$run"
  echo "VIDEO_FILE=$video"
  echo "APPLICATION_PID=$app_pid"
}

finalize_run() {
  local run="${1:-}"
  [[ -n "$run" ]] || usage
  [[ "$run" = /* ]] || run="$PWD/$run"
  [[ -f "$run/run-manifest.json" ]] || { echo "Missing run-manifest.json in $run" >&2; exit 1; }
  require_clean_worktree
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(/usr/bin/jq -er '.git.commit' "$run/run-manifest.json")" ]] || {
    echo "The current oracle commit differs from the captured app commit." >&2
    exit 1
  }

  local corpus manifest
  corpus="$(/usr/bin/jq -er '.corpus.id' "$run/run-manifest.json")"
  manifest="$ROOT/docs/japanese-live/corpora/$corpus/manifest.json"
  [[ -f "$manifest" ]] || { echo "Missing current corpus manifest: $manifest" >&2; exit 1; }
  [[ "$(sha256 "$manifest")" == "$(/usr/bin/jq -er '.corpus.manifestSHA256' "$run/run-manifest.json")" ]] || {
    echo "Corpus manifest changed after the Firefox run was prepared." >&2
    exit 1
  }
  local sessions
  sessions="$(/usr/bin/find "$run" -maxdepth 1 -type f -name '*-session.json' -print)"
  [[ "$(echo "$sessions" | /usr/bin/awk 'NF {count++} END {print count+0}')" == "1" ]] || {
    echo "Expected exactly one benchmark session sidecar in $run" >&2
    exit 1
  }
  local session="$sessions"
  local expected_candidate expected_model_id expected_model_revision expected_model_sha
  expected_candidate="$(/usr/bin/jq -er '.candidate.id' "$run/run-manifest.json")"
  expected_model_id="$(/usr/bin/jq -er '.candidate.modelID' "$run/run-manifest.json")"
  expected_model_revision="$(/usr/bin/jq -er '.candidate.revision' "$run/run-manifest.json")"
  expected_model_sha="$(/usr/bin/jq -er '.candidate.sha256' "$run/run-manifest.json")"
  /usr/bin/jq -e \
    --arg appSHA "$(/usr/bin/jq -er '.application.sha256' "$run/run-manifest.json")" \
    --arg candidate "$expected_candidate" \
    --arg modelID "$expected_model_id" \
    --arg revision "$expected_model_revision" \
    --arg modelFile "$(basename "$(/usr/bin/jq -er '.candidate.file' "$run/run-manifest.json")")" \
    --arg modelSHA "$expected_model_sha" \
    --arg engine "$(/usr/bin/jq -er '.configuration.pipeline' "$run/run-manifest.json")" \
    --arg translationMode "$(/usr/bin/jq -er '.configuration.translationMode' "$run/run-manifest.json")" \
    '.applicationExecutableSHA256 == $appSHA
      and .whisperCandidate == $candidate
      and .whisperModelID == $modelID
      and .whisperModelRevision == $revision
      and .whisperModelFile == $modelFile
      and .whisperModelSHA256 == $modelSHA
      and .summary.engine == $engine
      and .summary.translationMode == $translationMode' "$session" >/dev/null || {
    echo "Session provenance differs from the prepared app, model, or pipeline." >&2
    exit 1
  }
  "$ROOT/Scripts/run_japanese_offline_evaluation.sh" \
    "$session" "$manifest" "l7-evaluation"

  local metrics_name metrics full blind key
  metrics_name="$(/usr/bin/jq -er '.metricsFile' "$session")"
  metrics="$run/$metrics_name"
  full="$run/l7-evaluation-evaluation-full.json"
  blind="$run/l7-evaluation-evaluation-blind.json"
  key="$run/l7-evaluation-evaluation-key.json"
  for file in "$metrics" "$full" "$blind" "$key"; do
    [[ -f "$file" ]] || { echo "Missing finalized evidence: $file" >&2; exit 1; }
  done
  [[ "$(/usr/bin/jq -er '.blindSHA256' "$key")" == "$(sha256 "$blind")" ]] || {
    echo "Blind review key does not match its report." >&2
    exit 1
  }

  /usr/bin/jq '[.[] | select(.kind == "final") | {
    rangeStart, rangeEnd, speechEnd, sourceText, acceptedEnglish: .englishText,
    acceptedStart, stableThrough, committedThrough,
    asrMilliseconds, translationMilliseconds, speechEndToRenderedMilliseconds
  }]' "$metrics" > "$run/ja-asr.json"
  /usr/bin/jq '[.[] | select(.kind == "preview") | {
    rangeStart, rangeEnd, sourceText, englishText, revision,
    previewGeneration, isFirstEligibleInGeneration,
    previewLatencyMilliseconds, speechEndToRenderedMilliseconds
  }]' "$metrics" > "$run/en-preview.json"
  /usr/bin/jq '[.[] | select(.kind == "final") | {
    rangeStart, rangeEnd, sourceText, englishText,
    translationMilliseconds, speechEndToRenderedMilliseconds
  }]' "$metrics" > "$run/en-final.json"
  /usr/bin/jq '{
    status: "not-scored-in-L7",
    note: "Boundary kinds are recorded, but speaker changes are evaluated only in L9.",
    boundaries: [.[] | select(.kind == "final") | {
      atSample: .speechEnd, kind: .boundaryKind, degradation: .boundaryDegradation
    }]
  }' "$metrics" > "$run/speaker-boundaries.json"

  local candidate cer last_speech preview_coverage preview_p50 preview_p95 preview_worst final_p95 final_immutability rss runtime_slo
  candidate="$(/usr/bin/jq -r '.candidate.id' "$run/run-manifest.json")"
  /usr/bin/jq --arg candidate "$candidate" --arg corpus "$corpus" '
    {
      schemaVersion: 3,
      status: "diagnostic-only",
      candidate: $candidate,
      corpusID: $corpus,
      japanese: {
        primaryScope: "high-confidence-non-overlap",
        primaryCERLowerBoundPercent: ((.productionJapaneseCER.highConfidence.rateLowerBound * 10000 | round) / 100),
        primaryCERUpperBoundPercent: ((.productionJapaneseCER.highConfidence.rateUpperBound * 10000 | round) / 100),
        exactPrimaryCERAvailable: false,
        boundNote: .productionJapaneseCER.note,
        primaryReferenceCharacters: .productionJapaneseCER.highConfidence.referenceCharacterCount,
        primaryErrorLowerBound: (
          .productionJapaneseCER.highConfidence.substitutions
          + .productionJapaneseCER.highConfidence.deletions
          + .productionJapaneseCER.highConfidence.insertions
        ),
        primaryErrorUpperBound: (
          .productionJapaneseCER.highConfidence.substitutions
          + .productionJapaneseCER.highConfidence.deletions
          + .productionJapaneseCER.highConfidence.insertions
          + .productionJapaneseCER.ambiguousBoundaryInsertions
        ),
        overallDiagnosticCERPercent: ((.productionJapaneseCER.overall.rate * 10000 | round) / 100),
        lastSpeech: .lastSpeech,
        criticalTerms: "not-evaluable-none-annotated"
      },
      englishPreview: {
        coveragePercent: .runtime.slo.previewCoverage.percent,
        firstRevisionLatency: .runtime.previewFirstRevisionLatency,
        sloPass: (
          .runtime.slo.previewCoveragePass and .runtime.slo.previewP50Pass
          and .runtime.slo.previewP95Pass and .runtime.slo.previewWorstPass
        ),
        quality: "pending-bilingual-review"
      },
      englishFinal: {
        speechEndLatency: .runtime.finalSpeechEndToRendered,
        sloPass: (.runtime.slo.finalP95Pass and .runtime.slo.finalImmutabilityPass),
        immutability: .runtime.slo.finalImmutabilityEvidence,
        quality: "pending-bilingual-review"
      },
      resources: {
        maximumCombinedResidentBytes: .runtime.maximumCombinedResidentBytes,
        sampleIntervalMilliseconds: 250,
        note: "Observed periodic maximum, including FIFO and final translation drain."
      },
      runtimeSLOsPass: .runtime.slo.allRuntimeSLOsPass,
      japaneseIntegrityPass: false,
      japaneseIntegrityEvidence: "not-proven-pending-human-review",
      promotionBlockedBy: [
        "pending-human-review annotations",
        "no annotated critical terms",
        "two bilingual judges pending"
      ],
      verdict: (if .runtime.slo.allRuntimeSLOsPass
        then "Runtime SLOs pass, but quality promotion remains blocked."
        else "Runtime SLOs fail; no promotion."
      end)
    }' "$full" > "$run/comparison.json"
  cer="$(/usr/bin/jq -r '.japanese.primaryCERUpperBoundPercent' "$run/comparison.json")"
  last_speech="$(/usr/bin/jq -r '.japanese.lastSpeech.heuristicPresent' "$run/comparison.json")"
  preview_coverage="$(/usr/bin/jq -r '.englishPreview.coveragePercent' "$run/comparison.json")"
  preview_p50="$(/usr/bin/jq -r '.englishPreview.firstRevisionLatency.p50Milliseconds // "n/a"' "$run/comparison.json")"
  preview_p95="$(/usr/bin/jq -r '.englishPreview.firstRevisionLatency.p95Milliseconds // "n/a"' "$run/comparison.json")"
  preview_worst="$(/usr/bin/jq -r '.englishPreview.firstRevisionLatency.worstMilliseconds // "n/a"' "$run/comparison.json")"
  final_p95="$(/usr/bin/jq -r '.runtime.finalSpeechEndToRendered.p95Milliseconds // "n/a"' "$full")"
  final_immutability="$(/usr/bin/jq -r '.englishFinal.immutability' "$run/comparison.json")"
  rss="$(/usr/bin/jq -r '.runtime.maximumCombinedResidentBytes' "$full")"
  runtime_slo="$(/usr/bin/jq -r '.runtimeSLOsPass' "$run/comparison.json")"

  /bin/mkdir -p "$run/blind-review"
  /bin/cp "$blind" "$run/blind-review/"
  /bin/cp "$key" "$run/blind-review/"
  /usr/bin/printf '%s\n' \
    "# L7 — $candidate / $corpus" \
    "" \
    "- Statut : diagnostic uniquement." \
    "- CER japonais primaire (borne haute, high hors overlap) : $cer %." \
    "- Heuristique de dernière parole japonaise : $last_speech (pas une preuve de promotion)." \
    "- Preview anglaise : couverture $preview_coverage %, p50 $preview_p50 ms, p95 $preview_p95 ms, pire $preview_worst ms." \
    "- Final anglais : p95 $final_p95 ms; immutabilité $final_immutability." \
    "- SLO runtime complets : $runtime_slo." \
    "- Pic mémoire observé : $rss octets." \
    "- Qualité anglaise : en attente de deux juges bilingues." \
    "- Décision : aucune promotion avec les annotations actuelles." \
    > "$run/report-fr.md"

  local manifest_tmp
  manifest_tmp="$(/usr/bin/mktemp "$run/.run-manifest.XXXXXX")"
  /usr/bin/jq \
    --arg finalizedAt "$(date -u +%Y%m%dT%H%M%SZ)" \
    --arg sessionFile "$(basename "$session")" \
    --arg sessionSHA256 "$(sha256 "$session")" \
    --arg fullReportFile "$(basename "$full")" \
    --arg fullReportSHA256 "$(sha256 "$full")" \
    --arg comparisonSHA256 "$(sha256 "$run/comparison.json")" \
    --arg blindReportFile "$(basename "$blind")" \
    --arg blindReportSHA256 "$(sha256 "$blind")" \
    --arg keyReportFile "$(basename "$key")" \
    --arg keyReportSHA256 "$(sha256 "$key")" \
    '.status = "finalized" | .finalizedAt = $finalizedAt | .artifacts = {
      sessionFile: $sessionFile, sessionSHA256: $sessionSHA256,
      fullReportFile: $fullReportFile, fullReportSHA256: $fullReportSHA256,
      comparisonFile: "comparison.json", comparisonSHA256: $comparisonSHA256,
      blindReportFile: $blindReportFile, blindReportSHA256: $blindReportSHA256,
      keyReportFile: $keyReportFile, keyReportSHA256: $keyReportSHA256,
      reportFile: "report-fr.md"
    }' "$run/run-manifest.json" > "$manifest_tmp"
  /bin/mv "$manifest_tmp" "$run/run-manifest.json"
  echo "FINALIZED_RUN=$run"
}

aggregate_runs() {
  [[ "$#" == "4" ]] || usage
  local files=()
  local manifests=()
  require_clean_worktree
  local current_commit
  current_commit="$(git -C "$ROOT" rev-parse HEAD)"
  local run
  for run in "$@"; do
    [[ "$run" = /* ]] || run="$PWD/$run"
    [[ -f "$run/run-manifest.json" && -f "$run/comparison.json" ]] || {
      echo "Missing finalized L7 evidence in: $run" >&2
      exit 1
    }
    [[ "$(/usr/bin/jq -er '.status' "$run/run-manifest.json")" == "finalized" ]] || {
      echo "Run is not finalized: $run" >&2
      exit 1
    }
    [[ "$(/usr/bin/jq -er '.git.commit' "$run/run-manifest.json")" == "$current_commit" ]] || {
      echo "Run commit differs from the current aggregate oracle: $run" >&2
      exit 1
    }
    [[ "$(sha256 "$run/comparison.json")" == "$(/usr/bin/jq -er '.artifacts.comparisonSHA256' "$run/run-manifest.json")" ]] || {
      echo "Comparison evidence changed after finalization: $run" >&2
      exit 1
    }
    local session_file full_file
    session_file="$run/$(/usr/bin/jq -er '.artifacts.sessionFile' "$run/run-manifest.json")"
    full_file="$run/$(/usr/bin/jq -er '.artifacts.fullReportFile' "$run/run-manifest.json")"
    [[ "$(basename "$session_file")" == "$(/usr/bin/jq -er '.artifacts.sessionFile' "$run/run-manifest.json")"
      && -f "$session_file"
      && "$(sha256 "$session_file")" == "$(/usr/bin/jq -er '.artifacts.sessionSHA256' "$run/run-manifest.json")" ]] || {
      echo "Session evidence changed after finalization: $run" >&2
      exit 1
    }
    [[ "$(basename "$full_file")" == "$(/usr/bin/jq -er '.artifacts.fullReportFile' "$run/run-manifest.json")"
      && -f "$full_file"
      && "$(sha256 "$full_file")" == "$(/usr/bin/jq -er '.artifacts.fullReportSHA256' "$run/run-manifest.json")" ]] || {
      echo "Full evaluation evidence changed after finalization: $run" >&2
      exit 1
    }
    /usr/bin/jq -e --slurpfile comparison "$run/comparison.json" '
      .candidate.id == $comparison[0].candidate
        and .corpus.id == $comparison[0].corpusID
    ' "$run/run-manifest.json" >/dev/null || {
      echo "Comparison identity differs from its run manifest: $run" >&2
      exit 1
    }
    files+=("$run/comparison.json")
    manifests+=("$run/run-manifest.json")
  done

  local timestamp output
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  output="$RUNS/l7-firefox-aggregate-$timestamp"
  /bin/mkdir -p "$output"
  /usr/bin/jq -s '
    if (map(.git.commit) | unique | length) != 1
      or (map(.application.sha256) | unique | length) != 1
      or (map(.captureApplication.executableSHA256) | unique | length) != 1
      or (map(.configuration) | unique | length) != 1
      or ([.[] | select(.corpus.id == "qudu2fx3ncc")
            | [.corpus.manifestSHA256, .corpus.fixtureSHA256, .source.videoSHA256]] | unique | length) != 1
      or ([.[] | select(.corpus.id == "md62mmdz0m")
            | [.corpus.manifestSHA256, .corpus.fixtureSHA256, .source.videoSHA256]] | unique | length) != 1
    then error("The four runs do not share one attested app and matched corpus identities")
    else [ .[] | {
      candidate: .candidate.id,
      corpusID: .corpus.id,
      gitCommit: .git.commit,
      applicationSHA256: .application.sha256,
      manifestSHA256: .corpus.manifestSHA256,
      fixtureSHA256: .corpus.fixtureSHA256,
      videoSHA256: .source.videoSHA256,
      sessionSHA256: .artifacts.sessionSHA256,
      fullReportSHA256: .artifacts.fullReportSHA256,
      comparisonSHA256: .artifacts.comparisonSHA256
    } ] | sort_by(.candidate, .corpusID)
    end
  ' "${manifests[@]}" > "$output/inputs.json"
  /usr/bin/jq -s --arg inputsSHA256 "$(sha256 "$output/inputs.json")" '
    def candidate_summary($id):
      [ .[] | select(.candidate == $id) ] as $items
      | ($items | map(.japanese.primaryErrorUpperBound) | add) as $errors
      | ($items | map(.japanese.primaryReferenceCharacters) | add) as $reference
      | {
          candidate: $id,
          primaryErrorUpperBound: $errors,
          primaryReferenceCharacters: $reference,
          primaryCERUpperBoundPercent: (($errors / $reference * 10000 | round) / 100),
          allRuntimeSLOsPass: ($items | all(.runtimeSLOsPass)),
          maximumCombinedResidentBytes: ($items | map(.resources.maximumCombinedResidentBytes) | max),
          corpora: ($items | sort_by(.corpusID))
        };
    . as $runs
    | ($runs | map([.candidate, .corpusID] | join("/")) | sort) as $identities
    | if $identities != [
        "kotoba-q5/md62mmdz0m", "kotoba-q5/qudu2fx3ncc",
        "turbo/md62mmdz0m", "turbo/qudu2fx3ncc"
      ] then error("Expected exactly one finalized run for each candidate/corpus pair") else . end
    | candidate_summary("turbo") as $turbo
    | candidate_summary("kotoba-q5") as $kotoba
    | (($turbo.primaryCERUpperBoundPercent - $kotoba.primaryCERUpperBoundPercent)
        / $turbo.primaryCERUpperBoundPercent * 100) as $relativeImprovement
    | (["md62mmdz0m", "qudu2fx3ncc"] | map(
        . as $corpus
        | ($turbo.corpora[] | select(.corpusID == $corpus)) as $t
        | ($kotoba.corpora[] | select(.corpusID == $corpus)) as $k
        | {
            corpusID: $corpus,
            turboPrimaryCERUpperBoundPercent: $t.japanese.primaryCERUpperBoundPercent,
            kotobaPrimaryCERUpperBoundPercent: $k.japanese.primaryCERUpperBoundPercent,
            kotobaDeltaUpperBoundPoints: ($k.japanese.primaryCERUpperBoundPercent - $t.japanese.primaryCERUpperBoundPercent)
          }
      )) as $deltas
    | {
        schemaVersion: 2,
        status: "diagnostic-only",
        candidates: [$turbo, $kotoba],
        japaneseComparison: {
          diagnosticUpperBoundRelativeDeltaPercent: (($relativeImprovement * 100 | round) / 100),
          corpusDeltas: $deltas,
          qualityGate: "not-evaluable-from-CER-bounds",
          latencyAlternativeGate: "not-evaluable-preview-is-shared-and-quality-review-is-pending",
          pairedBootstrap95: "not-valid-until-long-form-annotations-are-human-reviewed",
          criticalOmissionGate: "not-evaluable-no-critical-terms-annotated"
        },
        englishPreviewQuality: "pending-two-bilingual-judges",
        englishFinalQuality: "pending-two-bilingual-judges",
        technicalLead: "none-gates-incomplete",
        provenance: {inputsFile: "inputs.json", inputsSHA256: $inputsSHA256},
        verdict: "No product winner can be promoted before human annotation and bilingual review gates are complete."
      }
  ' "${files[@]}" > "$output/comparison.json"

  /usr/bin/jq -r '
    (.candidates[] | select(.candidate == "turbo")) as $turbo
    | (.candidates[] | select(.candidate == "kotoba-q5")) as $kotoba
    | ($turbo.corpora[] | select(.corpusID == "md62mmdz0m")) as $turboMD
    | ($turbo.corpora[] | select(.corpusID == "qudu2fx3ncc")) as $turboQudu
    | ($kotoba.corpora[] | select(.corpusID == "md62mmdz0m")) as $kotobaMD
    | ($kotoba.corpora[] | select(.corpusID == "qudu2fx3ncc")) as $kotobaQudu
    | [
        "# L7 — comparaison Firefox agrégée",
        "",
        "Statut : diagnostic uniquement.",
        "",
        "| Pipeline / corpus | Japonais | Preview anglaise | Final anglais | Mémoire | Verdict |",
        "|---|---:|---|---|---:|---|",
        "| Turbo / md62mmdz0m | CER ≤ \($turboMD.japanese.primaryCERUpperBoundPercent) % | couverture \($turboMD.englishPreview.coveragePercent) %; p95 \($turboMD.englishPreview.firstRevisionLatency.p95Milliseconds) ms; qualité en attente | p95 \($turboMD.englishFinal.speechEndLatency.p95Milliseconds) ms; immutabilité \($turboMD.englishFinal.immutability // "non prouvée"); qualité en attente | \($turboMD.resources.maximumCombinedResidentBytes) octets | \($turboMD.verdict) |",
        "| Turbo / qudu2fx3ncc | CER ≤ \($turboQudu.japanese.primaryCERUpperBoundPercent) % | couverture \($turboQudu.englishPreview.coveragePercent) %; p95 \($turboQudu.englishPreview.firstRevisionLatency.p95Milliseconds) ms; qualité en attente | p95 \($turboQudu.englishFinal.speechEndLatency.p95Milliseconds) ms; immutabilité \($turboQudu.englishFinal.immutability // "non prouvée"); qualité en attente | \($turboQudu.resources.maximumCombinedResidentBytes) octets | \($turboQudu.verdict) |",
        "| Kotoba Q5 / md62mmdz0m | CER ≤ \($kotobaMD.japanese.primaryCERUpperBoundPercent) % | couverture \($kotobaMD.englishPreview.coveragePercent) %; p95 \($kotobaMD.englishPreview.firstRevisionLatency.p95Milliseconds) ms; qualité en attente | p95 \($kotobaMD.englishFinal.speechEndLatency.p95Milliseconds) ms; immutabilité \($kotobaMD.englishFinal.immutability // "non prouvée"); qualité en attente | \($kotobaMD.resources.maximumCombinedResidentBytes) octets | \($kotobaMD.verdict) |",
        "| Kotoba Q5 / qudu2fx3ncc | CER ≤ \($kotobaQudu.japanese.primaryCERUpperBoundPercent) % | couverture \($kotobaQudu.englishPreview.coveragePercent) %; p95 \($kotobaQudu.englishPreview.firstRevisionLatency.p95Milliseconds) ms; qualité en attente | p95 \($kotobaQudu.englishFinal.speechEndLatency.p95Milliseconds) ms; immutabilité \($kotobaQudu.englishFinal.immutability // "non prouvée"); qualité en attente | \($kotobaQudu.resources.maximumCombinedResidentBytes) octets | \($kotobaQudu.verdict) |",
        "",
        "- Écart relatif diagnostic des bornes hautes Kotoba : \(.japaneseComparison.diagnosticUpperBoundRelativeDeltaPercent) %.",
        "- La preview Apple est commune aux deux modèles; sa variation vient des replays, pas de Kotoba/Turbo.",
        "- La qualité anglaise preview/final attend deux juges bilingues.",
        "- Avantage technique : aucun, gates incomplets.",
        "- Décision : aucune promotion avant validation humaine et deux juges bilingues."
      ] | .[]
  ' "$output/comparison.json" > "$output/report-fr.md"
  echo "AGGREGATE_DIRECTORY=$output"
}

case "${1:-}" in
  build) shift; build_app "$@" ;;
  prepare) shift; prepare_run "$@" ;;
  finalize) shift; finalize_run "$@" ;;
  aggregate) shift; aggregate_runs "$@" ;;
  *) usage ;;
esac
