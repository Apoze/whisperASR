#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-preflight}"
BASE_COMMIT=d24a15546dc9d53e7b3ecffd093758bff28a0988
export WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="${WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE:-$ROOT/.build/debug/WhisperASR}"
ARTIFACTS="$ROOT/.build/benchmarks/issue-93"
ASSETS="$ARTIFACTS/assets"
RUNTIME_ARCHIVE="$ASSETS/sherpa-onnx-v1.13.5-osx-arm64-shared-no-tts.tar.bz2"
RUNTIME_ROOT="$ASSETS/sherpa-onnx-v1.13.5-osx-arm64-shared-no-tts"
SEPARATOR="$RUNTIME_ROOT/bin/sherpa-onnx-offline-source-separation"
SEPARATOR_SHA256=165cdcd3e4c10d633487fe4682d7dc3ad29fc6dbf11f8f93791cd35ab0d45910
MODEL_ROOT="$ASSETS/sherpa-onnx-spleeter-2stems-fp16"
PLAN="$ARTIFACTS/window-plan.json"
BASELINE_PCM="${WHISPERASR_ISSUE93_PCM:-/Users/maz/Documents/projets/whisperASR/.build/benchmarks/japanese-live/corpora/qudu2fx3ncc/audio-16k-mono.wav}"
SOURCE="${WHISPERASR_ISSUE93_SOURCE:-/Users/maz/Documents/videos/jap/1/Video1.webm}"
ARCHIVE="${WHISPERASR_ISSUE93_REFERENCE_ARCHIVE:-/Users/maz/Documents/videos/jap/1/Video1_reference_transcript_and_translation.zip}"
FROZEN_ROOT="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
AUDIO="$ARTIFACTS/audio"
JOB_ID=93000001-0000-4000-8000-000000000001
JOB_ROOT="$ARTIFACTS/development/jobs"
JOB="$JOB_ROOT/$JOB_ID"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E27"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/whisperasr-93-clang-cache}"

case "$MODE" in preflight|development|resume|report) ;; *) echo "usage: $0 [preflight|development|resume|report]" >&2; exit 2;; esac
if [[ "$MODE" == resume || "$MODE" == report ]]; then
  JOB_ID=93000002-0000-4000-8000-000000000001
  JOB_ROOT="$ARTIFACTS/corrected-resume/jobs"
  JOB="$JOB_ROOT/$JOB_ID"
fi
[[ "$MODE" != development || "${BENCHMARK_SLOT_GRANTED:-}" == 93 ]] || {
  echo "Refusing the only heavy #93 run without BENCHMARK_SLOT_GRANTED=93" >&2; exit 2;
}
[[ "$MODE" != resume || ("${BENCHMARK_SLOT_GRANTED:-}" == 93 \
  && "${BENCHMARK_RESUME_GRANTED:-}" == 93) ]] || {
  echo "Refusing corrected #93 resume without both benchmark grants." >&2; exit 2;
}
cd "$ROOT"
mkdir -p "$ARTIFACTS/controls" "$AUDIO"

hash() { shasum -a 256 "$1" | awk '{print $1}'; }
assert_hash() {
  [[ -f "$1" && "$(hash "$1")" == "$2" ]] || { echo "Hash mismatch or missing: $1" >&2; return 1; }
}
terminal_evidence_present() {
  [[ -e "$EVIDENCE/corrected-resume-diagnostic.json" ]]
}
verify_terminal_evidence() {
  jq -e '.ticket == 93 and .decision == "NO-GO-stop-before-holdout"
    and .scope.qwenPassesInResume == 1 and .scope.benchmarkSlotReleased == true' \
    "$EVIDENCE/corrected-resume-diagnostic.json" >/dev/null
  assert_hash "$EVIDENCE/corrected-resume-failure-raw-asr.json.gz" \
    dcf8b3d4cab5976010fbfcc44aa51b4c8ef06840674f8e89d9bf94d02d8e6eb8
  assert_hash "$EVIDENCE/corrected-resume-failure-manifest.json" \
    4fde91dcd092064bf4048ec93622b00990cd959f1cc772abdc364148a8548f6c
  assert_hash "$EVIDENCE/corrected-resume-failure-runtime.json" \
    322cc91d337396ed5aec21abf364234580d8fda5c33ee9fc75d44c74d982c5b8
}
download() {
  local output="$1" expected="$2" url="$3"
  if [[ -f "$output" ]] && [[ "$(hash "$output")" == "$expected" ]]; then return; fi
  curl --fail --location --retry 3 --output "$output.partial" "$url"
  assert_hash "$output.partial" "$expected"
  mv "$output.partial" "$output"
}

prepare_local_references() {
  local locator destination source
  while IFS= read -r locator; do
    destination="$ROOT/$locator"
    if [[ -e "$destination" || -L "$destination" ]]; then
      [[ -f "$destination" ]] || { echo "Broken frozen reference: $destination" >&2; return 1; }
      continue
    fi
    source="$FROZEN_ROOT/$locator"; [[ -f "$source" ]] || { echo "Missing frozen reference: $source" >&2; return 1; }
    mkdir -p "$(dirname "$destination")"; ln -s "$source" "$destination"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | .locator' \
    docs/japanese-live/corpora/qudu2fx3ncc/manifest.json)
}

verify_inputs() {
  [[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]]
  command -v curl jq ffmpeg xcrun >/dev/null
  assert_hash "$SOURCE" b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1
  assert_hash "$ARCHIVE" 8f1c4ed3836d5e0f627448f9ecc44ab064d8750cb4464c8849eafabbba401474
  assert_hash "$BASELINE_PCM" 494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2
  assert_hash docs/japanese-live/experiments/evidence/E23/segments.json e6f8024c83d8c30199065703a4abf1f0ca1dfcead13381d3168c659f88082f81
  assert_hash docs/japanese-live/experiments/evidence/E26/report.json a065bfcfcc9260660cb4fe00f4c788de37c428febd8f9067e77b69571aebd518
  jq -e '.eligible == true and .rejectedReleaseArchive.eligible == false' \
    docs/japanese-live/experiments/evidence/E27/candidate-provenance.json >/dev/null
  jq -e '.decision == "NO-RUN-fireRed-ineligible"' docs/japanese-live/experiments/evidence/E25/report.json >/dev/null
  jq -e '.decision == "INAPPLICABLE-NO-RUN-no-native-hotword-mechanism"' \
    docs/japanese-live/experiments/evidence/E26/report.json >/dev/null
  assert_hash Sources/WhisperASRApp.swift 7bfe07839dbbf7d8b1f3bf585ac7d461ab9e6fa3fa4fd19b6644c21c27fa5e57
  [[ -z "$({ git diff --name-only "$BASE_COMMIT" -- Sources; \
      git ls-files --others --exclude-standard -- Sources; } \
    | sort -u | grep -vFx Sources/WhisperASRApp.swift)" ]] || {
    echo "Unexpected product source changed; #93 permits only the worker probe entry point." >&2
    return 1
  }
  prepare_local_references
  while IFS=$'\t' read -r expected locator; do assert_hash "$ROOT/$locator" "$expected"; done \
    < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | [.sha256,.locator] | @tsv' \
      docs/japanese-live/corpora/qudu2fx3ncc/manifest.json)
}

verify_worker() {
  [[ -x "$WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE" ]] || {
    echo "Missing worker executable: $WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE" >&2; return 1;
  }
  if ! python3 Scripts/qwen_voice_music_harness.py run-command --timeout 5 \
    --log "$ARTIFACTS/controls/worker-probe.log" \
    --runtime "$ARTIFACTS/controls/worker-probe-runtime.json" -- \
    "$WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE" --high-quality-asr-worker --probe; then
    echo "Worker executable rejected --high-quality-asr-worker before any Spleeter/model run." >&2
    return 1
  fi
  grep -Fxq WHISPERASR_HIGH_QUALITY_ASR_WORKER_PROBE_OK \
    "$ARTIFACTS/controls/worker-probe.log"
}

verify_reusable_separation() {
  [[ -f "$ARTIFACTS/heavy-run-launched" ]]
  while IFS=$'\t' read -r expected relative; do
    assert_hash "$ROOT/$relative" "$expected"
  done < <(jq -r '.reusableArtifacts | to_entries[] | [.value,.key] | @tsv' \
    docs/japanese-live/experiments/evidence/E27/resume-lock.json)
  jq -e '.changedOutsideTargetSamples == 0 and .sampleCount == 15315325
    and all(.cleanControls[]; .byteIdentical == true)' "$AUDIO/audio-audit.json" >/dev/null
  grep -Fq 'input-wav='"$AUDIO/separator-input-16k-stereo.wav" "$AUDIO/separator.log"
  grep -Fq 'Done' "$AUDIO/separator.log"
}

prepare_assets() {
  mkdir -p "$ASSETS" "$MODEL_ROOT"
  download "$RUNTIME_ARCHIVE" 77c46d0e7d383735b7dd9713313ddf764815e829503b0b917ff51ac31be2e897 \
    https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/sherpa-onnx-v1.13.5-osx-arm64-shared-no-tts.tar.bz2
  if [[ ! -x "$SEPARATOR" ]]; then tar -xjf "$RUNTIME_ARCHIVE" -C "$ASSETS"; fi
  download "$MODEL_ROOT/vocals.fp16.onnx" 24cef84aedcd1fe87c0b743ef3370ad34dc1fabf6c9014d6128a75a538c7b668 \
    https://huggingface.co/csukuangfj/sherpa-onnx-spleeter-2stems-fp16/resolve/93ba771920ade509f8cbd6825b1a90856c797e08/vocals.fp16.onnx
  download "$MODEL_ROOT/accompaniment.fp16.onnx" d14cea55793cc531a5875f5f4da08207d1c5ab9292e8e0099a104eecb014fcc0 \
    https://huggingface.co/csukuangfj/sherpa-onnx-spleeter-2stems-fp16/resolve/93ba771920ade509f8cbd6825b1a90856c797e08/accompaniment.fp16.onnx
  assert_hash "$RUNTIME_ARCHIVE" 77c46d0e7d383735b7dd9713313ddf764815e829503b0b917ff51ac31be2e897
  assert_hash "$SEPARATOR" "$SEPARATOR_SHA256"
  assert_hash "$MODEL_ROOT/vocals.fp16.onnx" 24cef84aedcd1fe87c0b743ef3370ad34dc1fabf6c9014d6128a75a538c7b668
  assert_hash "$MODEL_ROOT/accompaniment.fp16.onnx" d14cea55793cc531a5875f5f4da08207d1c5ab9292e8e0099a104eecb014fcc0
  file "$SEPARATOR" | grep -q 'Mach-O 64-bit executable arm64'
  codesign --verify --verbose=4 "$SEPARATOR"
}

make_audio() {
  python3 Scripts/qwen_voice_music_harness.py plan --segments \
    docs/japanese-live/experiments/evidence/E23/segments.json --audio "$BASELINE_PCM" --output "$PLAN"
  python3 Scripts/qwen_voice_music_harness.py prepare --audio "$BASELINE_PCM" --plan "$PLAN" \
    --output "$AUDIO/separator-input-16k-stereo.wav"
  [[ ! -e "$ARTIFACTS/heavy-run-launched" ]] || {
    echo "The single #93 model run was already launched; rerun forbidden." >&2; return 1;
  }
  : >"$ARTIFACTS/heavy-run-launched"
  python3 Scripts/qwen_voice_music_harness.py separate --executable "$SEPARATOR" \
    --vocals-model "$MODEL_ROOT/vocals.fp16.onnx" \
    --accompaniment-model "$MODEL_ROOT/accompaniment.fp16.onnx" \
    --input "$AUDIO/separator-input-16k-stereo.wav" --output-vocals "$AUDIO/vocals.wav" \
    --output-accompaniment "$AUDIO/accompaniment.wav" --log "$AUDIO/separator.log" \
    --runtime "$AUDIO/separator-runtime.json"
  jq -e '.elapsedSeconds <= 1200' "$AUDIO/separator-runtime.json" >/dev/null || {
    echo "STOP: separator cost runaway; Qwen was not launched." >&2; return 1;
  }
  local montage_seconds; montage_seconds="$(jq -r '.separatorInputSampleCount/16000' "$PLAN")"
  ffmpeg -hide_banner -loglevel error -y -i "$AUDIO/vocals.wav" -af apad -t "$montage_seconds" -ac 1 -ar 16000 \
    -c:a pcm_s16le "$AUDIO/vocals-16k-mono.wav"
  python3 Scripts/qwen_voice_music_harness.py splice --audio "$BASELINE_PCM" \
    --processed "$AUDIO/vocals-16k-mono.wav" --plan "$PLAN" --output "$AUDIO/candidate.wav" \
    --audit "$AUDIO/audio-audit.json" --before-targets "$AUDIO/before-targets.wav" \
    --after-targets "$AUDIO/after-targets.wav" --before-controls "$AUDIO/before-clean-controls.wav" \
    --after-controls "$AUDIO/after-clean-controls.wav"
}

retain() {
  local prefix="${1:-candidate}" run_root="${2:-$ARTIFACTS/development}"
  mkdir -p "$EVIDENCE"
  for name in japanese-transcript.txt english-translation-transcript.txt english-subtitles.srt \
    english-subtitles.vtt manifest.json; do [[ -f "$JOB/$name" ]] && cp "$JOB/$name" "$EVIDENCE/$prefix-$name"; done
  [[ -f "$JOB/raw-asr.json" ]] && gzip -n -c "$JOB/raw-asr.json" >"$EVIDENCE/$prefix-raw-asr.json.gz"
  [[ -f "$run_root/run.log" ]] && gzip -n -c "$run_root/run.log" >"$EVIDENCE/$prefix-run.log.gz"
  [[ -f "$run_root/runtime.json" ]] && cp "$run_root/runtime.json" "$EVIDENCE/$prefix-runtime.json"
  cp docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-japanese-transcript.txt "$EVIDENCE/baseline-japanese-transcript.txt"
  cp docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-english-translation-transcript.txt "$EVIDENCE/baseline-english-translation-transcript.txt"
}

run_report() {
  local prefix=candidate raw="$JOB/raw-asr.json" manifest="$JOB/manifest.json"
  local candidate_english="$JOB/english-translation-transcript.txt" resume_runtime=()
  if [[ -f "$manifest" && "$(jq -r .status "$manifest")" != completed ]]; then
    prefix=corrected-resume-failure
  fi
  if [[ "$MODE" == report ]]; then
    prefix=corrected-resume-failure
    raw="$EVIDENCE/$prefix-raw-asr.json.gz"
    manifest="$EVIDENCE/$prefix-manifest.json"
    candidate_english="$EVIDENCE/$prefix-english-translation-transcript.txt"
  else
    retain "$prefix" "$([[ "$MODE" == resume ]] && echo "$ARTIFACTS/corrected-resume" || echo "$ARTIFACTS/development")"
  fi
  [[ "$MODE" != resume && "$MODE" != report ]] \
    || resume_runtime=(--resume-runtime "$EVIDENCE/$prefix-runtime.json")
  python3 Scripts/qwen_voice_music_harness.py report --plan "$PLAN" \
    --segments docs/japanese-live/experiments/evidence/E23/segments.json \
    --reference-csv .build/benchmarks/japanese-live/corpora/qudu2fx3ncc/reference.csv \
    --raw "$raw" --retained-raw "$EVIDENCE/$prefix-raw-asr.json.gz" \
    --baseline-raw docs/japanese-live/experiments/evidence/E22/qudu2fx3ncc-raw-asr.json.gz \
    --manifest "$manifest" --audit "$AUDIO/audio-audit.json" \
    --runtime "$AUDIO/separator-runtime.json" --output "$EVIDENCE/report.json" \
    --baseline-english "$EVIDENCE/baseline-english-translation-transcript.txt" \
    --candidate-english "$candidate_english" \
    "${resume_runtime[@]}" \
    --markdown docs/japanese-live/experiments/E27-qwen-voice-music-dev.md
}

run_preflight() {
  if terminal_evidence_present; then
    verify_terminal_evidence
    jq -n '{status:"BENCHMARK_EXHAUSTED_NO_RERUN",heavyRunsLaunched:1,
      spleeterPassesCompleted:1,correctedResumeQwenPassesCompleted:1,
      scope:{split:"DEV-only",holdoutOpened:false},command:null}'
    return
  fi
  verify_inputs
  bash -n Scripts/run_qwen_voice_music_experiment.sh
  python3 Scripts/qwen_voice_music_harness.py self-test
  python3 Scripts/qwen_voice_music_harness.py plan --segments \
    docs/japanese-live/experiments/evidence/E23/segments.json --audio "$BASELINE_PCM" --output "$PLAN"
  xcrun swift test --filter 'HeavyweightModelGateTests|HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  verify_worker
  if [[ -f "$ARTIFACTS/corrected-resume-launched" ]]; then
    verify_reusable_separation
    jq -n '{status:"BENCHMARK_EXHAUSTED_NO_RERUN",heavyRunsLaunched:1,
      spleeterPassesCompleted:1,correctedResumeQwenPassesCompleted:1,
      scope:{split:"DEV-only",holdoutOpened:false},command:null}' \
      >"$ARTIFACTS/benchmark-ready.json"
    jq . "$ARTIFACTS/benchmark-ready.json"
    return
  fi
  if [[ -f "$ARTIFACTS/heavy-run-launched" ]]; then
    verify_reusable_separation
    jq -n --arg command 'BENCHMARK_SLOT_GRANTED=93 BENCHMARK_RESUME_GRANTED=93 bash Scripts/run_qwen_voice_music_experiment.sh resume' \
      '{status:"READY_FOR_CORRECTED_ASR_RESUME",heavyRunsLaunched:1,spleeterPassesCompleted:1,
        correctedResumeQwenPasses:1,command:$command,
        scope:{split:"DEV-only",holdoutOpened:false,reusesPinnedSpleeterArtifacts:true},
        budget:{wallTimeMinutes:20,peakRAMGiB:18,incrementalDiskGiB:0.2}}' \
      >"$ARTIFACTS/benchmark-ready.json"
    jq . "$ARTIFACTS/benchmark-ready.json"
    return
  fi
  jq -n --arg command 'BENCHMARK_SLOT_GRANTED=93 bash Scripts/run_qwen_voice_music_experiment.sh development' \
    --argjson targets "$(jq '.targets|length' "$PLAN")" \
    --argjson targetSeconds "$(jq '.targetDurationSeconds' "$PLAN")" \
    '{status:"READY_FOR_HEAVY_BENCHMARK",heavyRunsLaunched:0,command:$command,
      scope:{split:"DEV-only",targets:$targets,targetSeconds:$targetSeconds,holdoutOpened:false,
        variable:"Spleeter-2stems-fp16 vocals samples inside E23 reference-free triggers only"},
      budget:{wallTimeMinutes:40,peakRAMGiB:18,incrementalDiskGiB:2},
      stop:{separatorSeconds:1200,totalSeconds:2400,speechErased:true,costRunaway:true}}' >"$ARTIFACTS/benchmark-ready.json"
  jq . "$ARTIFACTS/benchmark-ready.json"
}

run_development() {
  if terminal_evidence_present; then
    verify_terminal_evidence || echo "Terminal evidence is invalid; benchmark remains locked." >&2
    echo "#93 is terminal; another benchmark is forbidden." >&2
    return 1
  fi
  verify_inputs; verify_worker; prepare_assets
  [[ ! -e "$JOB" && ! -e "$ARTIFACTS/heavy-run-launched" ]] || {
    echo "The single #93 heavy run was already launched; retained evidence must be reported, never rerun." >&2; return 1;
  }
  make_audio
  assert_hash "$AUDIO/candidate.wav" 8df0e11d06510983dd66b3e0386c5562cf27a8c71bf3acfcf46eb6697b576411
  [[ -f .build/debug/mlx.metallib ]] || bash Scripts/build_mlx_metallib.sh debug
  mkdir -p "$JOB_ROOT" "$ARTIFACTS/development"
  local candidate_hash=8df0e11d06510983dd66b3e0386c5562cf27a8c71bf3acfcf46eb6697b576411
  if ! BENCHMARK_SLOT_GRANTED=93 WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE=1 \
    WHISPERASR_ACCEPTANCE_BACKEND=qwen-ja WHISPERASR_ACCEPTANCE_CORPUS=qudu2fx3ncc \
    WHISPERASR_ACCEPTANCE_SOURCE="$AUDIO/candidate.wav" \
    WHISPERASR_ACCEPTANCE_SOURCE_SHA256="$candidate_hash" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$ARCHIVE" WHISPERASR_ACCEPTANCE_JOB_ID="$JOB_ID" \
    WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$JOB_ROOT" WHISPERASR_ACCEPTANCE_TRANSLATION_CONTEXT=product-default \
      python3 Scripts/qwen_voice_music_harness.py run-command --timeout 2400 \
        --log "$ARTIFACTS/development/run.log" --runtime "$ARTIFACTS/development/runtime.json" -- \
        xcrun swift test --skip-build --filter HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn; then
    retain attempt-1-harness-failure "$ARTIFACTS/development"
    echo "Heavy run failed; raw evidence retained and rerun remains forbidden." >&2; return 1
  fi
  run_report
}

run_resume() {
  if terminal_evidence_present; then
    verify_terminal_evidence || echo "Terminal evidence is invalid; model pass remains locked." >&2
    echo "#93 is terminal; another model pass is forbidden." >&2
    return 1
  fi
  verify_inputs
  verify_worker
  verify_reusable_separation
  [[ ! -e "$JOB" && ! -e "$ARTIFACTS/corrected-resume-launched" ]] || {
    echo "Corrected #93 resume was already launched; no further model pass is allowed." >&2; return 1;
  }
  : >"$ARTIFACTS/corrected-resume-launched"
  mkdir -p "$JOB_ROOT" "$ARTIFACTS/corrected-resume"
  local candidate_hash=8df0e11d06510983dd66b3e0386c5562cf27a8c71bf3acfcf46eb6697b576411
  if ! BENCHMARK_SLOT_GRANTED=93 WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE=1 \
    WHISPERASR_ACCEPTANCE_BACKEND=qwen-ja WHISPERASR_ACCEPTANCE_CORPUS=qudu2fx3ncc \
    WHISPERASR_ACCEPTANCE_SOURCE="$AUDIO/candidate.wav" \
    WHISPERASR_ACCEPTANCE_SOURCE_SHA256="$candidate_hash" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$ARCHIVE" WHISPERASR_ACCEPTANCE_JOB_ID="$JOB_ID" \
    WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$JOB_ROOT" WHISPERASR_ACCEPTANCE_TRANSLATION_CONTEXT=product-default \
      python3 Scripts/qwen_voice_music_harness.py run-command --timeout 1200 \
        --log "$ARTIFACTS/corrected-resume/run.log" \
        --runtime "$ARTIFACTS/corrected-resume/runtime.json" -- \
        xcrun swift test --skip-build --filter HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn; then
    retain corrected-resume-failure "$ARTIFACTS/corrected-resume"
    run_report || true
    echo "Corrected resume failed; raw evidence retained and another pass is forbidden." >&2
    return 1
  fi
  retain candidate "$ARTIFACTS/corrected-resume"
  run_report
}

case "$MODE" in
  preflight) run_preflight;;
  development) run_development;;
  resume) run_resume;;
  report) verify_terminal_evidence; verify_inputs; verify_reusable_separation; run_report;;
esac
