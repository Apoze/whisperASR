#!/bin/bash
set -Eeuo pipefail

VALIDATION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_MODE="${1:-preflight}"
DEFAULT_ARTIFACTS="$VALIDATION_ROOT/.build/benchmarks/high-quality/integrated-validation-106"
[[ "$VALIDATION_MODE" != 4B_ONLY ]] \
  || DEFAULT_ARTIFACTS="$VALIDATION_ROOT/.build/benchmarks/high-quality/integrated-validation-106-4b-only"
[[ "$VALIDATION_MODE" != TRANSLATION_ONLY_4B ]] \
  || DEFAULT_ARTIFACTS="$VALIDATION_ROOT/.build/benchmarks/high-quality/integrated-validation-106-translation-only-4b"
[[ "$VALIDATION_MODE" != TRANSLATION_ONLY_12B ]] \
  || DEFAULT_ARTIFACTS="$VALIDATION_ROOT/.build/benchmarks/high-quality/integrated-validation-106-translation-only-12b"
[[ "$VALIDATION_MODE" != TRANSLATION_SMOKE_12B_100 ]] \
  || DEFAULT_ARTIFACTS="$VALIDATION_ROOT/.build/benchmarks/high-quality/integrated-validation-106-translation-smoke-12b-100"
VALIDATION_ARTIFACTS="${WHISPERASR_INTEGRATED_ROOT:-$DEFAULT_ARTIFACTS}"

# Reuse the native macOS pressure/swap/runaway guard proven by #102.
source "$VALIDATION_ROOT/Scripts/run_mossformer2_oracle_experiment.sh"
ROOT="$VALIDATION_ROOT"
MODE="$VALIDATION_MODE"
ARTIFACTS="$VALIDATION_ARTIFACTS"
REPLAY_TRANSLATOR=translategemma-4b-it-4bit
[[ "$MODE" != TRANSLATION_ONLY_12B && "$MODE" != TRANSLATION_SMOKE_12B_100 ]] \
  || REPLAY_TRANSLATOR=translategemma-12b-it-4bit
VIDEO_ROOT="${JAPANESE_VIDEO_ROOT:-/Users/maz/Documents/videos/jap}"
FROZEN_REPO="${WHISPERASR_FROZEN_REPO:-/Users/maz/Documents/projets/whisperASR}"
COMET_PYTHON="${COMET_PYTHON:-$ROOT/.build/comet-venv/bin/python}"
[[ -x "$COMET_PYTHON" ]] || COMET_PYTHON="$FROZEN_REPO/.build/comet-venv/bin/python"
COMET_CACHE="${COMET_CACHE:-${HF_HUB_CACHE:-/Users/maz/.cache/huggingface/hub}/models--Unbabel--wmt22-comet-da}"
REPORT_JSON="$ROOT/docs/high-quality-integrated-e31.json"
REPORT_MD="$ROOT/docs/japanese-live/experiments/E31-integrated-final-validation.md"
EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E31"
if [[ "$VALIDATION_MODE" == 4B_ONLY ]]; then
  REPORT_JSON="$ROOT/docs/high-quality-integrated-e31-4b-only.json"
  REPORT_MD="$ROOT/docs/japanese-live/experiments/E31-integrated-final-validation-4b-only.md"
  EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E31-4b-only"
fi
if [[ "$VALIDATION_MODE" == TRANSLATION_ONLY_4B ]]; then
  REPORT_JSON="$ROOT/docs/high-quality-integrated-e31-translation-only-4b.json"
  REPORT_MD="$ROOT/docs/japanese-live/experiments/E31-translation-only-4b-replay.md"
  EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-only-4b"
fi
if [[ "$VALIDATION_MODE" == TRANSLATION_ONLY_12B ]]; then
  REPORT_JSON="$ROOT/docs/high-quality-integrated-e31-translation-only-12b.json"
  REPORT_MD="$ROOT/docs/japanese-live/experiments/E31-translation-only-12b-replay.md"
  EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-only-12b"
fi
if [[ "$VALIDATION_MODE" == TRANSLATION_SMOKE_12B_100 ]]; then
  EVIDENCE="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-smoke-12b-100"
fi
BASELINE="$ROOT/docs/japanese-live/experiments/evidence/E22"
SMOKE_12B_REQUEST="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-only-12b-pressure-attempt/worker/request-1.json"
SMOKE_12B_REQUEST_SHA256=526dc64c32131813d7b252aab2e270d3f84aa486850fbd7ab03dab07f853910f
JOB_TIMEOUT_SECONDS="${WHISPERASR_INTEGRATED_JOB_TIMEOUT_SECONDS:-2400}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
export WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE="${WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE:-$ROOT/.build/debug/WhisperASR}"

PHASE=startup
CURRENT_TRANSLATOR=""
CURRENT_CORPUS=""

die() {
  mkdir -p "$ARTIFACTS"
  jq -n --arg phase "$PHASE" --arg detail "$1" --arg translator "$CURRENT_TRANSLATOR" \
    --arg corpus "$CURRENT_CORPUS" \
    '{ticket:106,status:"failed",route:$phase,detail:$detail,translator:$translator,
      corpusID:$corpus,modelVerdictAssigned:false}' >"$ARTIFACTS/failure.json"
  echo "$1" >&2
  exit 1
}

on_error() {
  local status="$?"
  trap - ERR
  die "Command failed at $PHASE (exit $status)"
}

process_tree_pids() {
  local process="$1" child
  printf '%s\n' "$process"
  while IFS= read -r child; do
    [[ -z "$child" ]] || process_tree_pids "$child"
  done < <(pgrep -P "$process" 2>/dev/null || true)
}

# The #102 guard sampled one model process. A Swift test adds parent processes, so sample
# the whole tree and take physical footprint from its largest resident process.
read_process_memory() {
  local process="$1"
  local pid rss_kb total_kb=0 largest_kb=0 largest_pid="$process" output
  while IFS= read -r pid; do
    rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1 + 0}')"
    [[ "$rss_kb" =~ ^[0-9]+$ ]] || continue
    total_kb=$((total_kb + rss_kb))
    if ((rss_kb > largest_kb)); then largest_kb="$rss_kb"; largest_pid="$pid"; fi
  done < <(process_tree_pids "$process")
  PROCESS_RSS_BYTES="$((total_kb * 1024))"
  output="$(/usr/bin/footprint -f bytes --noCategories -p "$largest_pid" 2>/dev/null || true)"
  PROCESS_FOOTPRINT_BYTES="$(awk '/phys_footprint:/ {print $(NF - 1); exit}' <<<"$output")"
  PROCESS_FOOTPRINT_PEAK_BYTES="$(awk '/phys_footprint_peak:/ {print $(NF - 1); exit}' <<<"$output")"
  [[ "$PROCESS_FOOTPRINT_BYTES" =~ ^[0-9]+$ ]] || PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  [[ "$PROCESS_FOOTPRINT_PEAK_BYTES" =~ ^[0-9]+$ ]] \
    || PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_FOOTPRINT_BYTES"
  ((PROCESS_FOOTPRINT_BYTES >= PROCESS_RSS_BYTES)) \
    || PROCESS_FOOTPRINT_BYTES="$PROCESS_RSS_BYTES"
  ((PROCESS_FOOTPRINT_PEAK_BYTES >= PROCESS_FOOTPRINT_BYTES)) \
    || PROCESS_FOOTPRINT_PEAK_BYTES="$PROCESS_FOOTPRINT_BYTES"
}

manifest_for() { printf '%s/docs/japanese-live/corpora/%s/manifest.json\n' "$ROOT" "$1"; }
video_directory() { [[ "$1" == qudu2fx3ncc ]] && printf '%s/1\n' "$VIDEO_ROOT" || printf '%s/2\n' "$VIDEO_ROOT"; }
model_id() { [[ "$1" == translategemma-12b-it-4bit ]] && echo mlx-community/translategemma-12b-it-4bit || echo mlx-community/translategemma-4b-it-4bit; }
model_revision() { [[ "$1" == translategemma-12b-it-4bit ]] && echo f3dcfd54df14672fbcf0731086fb47a797a943ae || echo 5788ec08c047f3f2e17808101b8d9566ac930d58; }
job_id() {
  case "$1/$2" in
    translategemma-12b-it-4bit/qudu2fx3ncc) echo 10600001-0000-4000-8000-000000000001 ;;
    translategemma-12b-it-4bit/md62mmdz0m) echo 10600002-0000-4000-8000-000000000001 ;;
    translategemma-4b-it-4bit/qudu2fx3ncc) echo 10600003-0000-4000-8000-000000000001 ;;
    translategemma-4b-it-4bit/md62mmdz0m) echo 10600004-0000-4000-8000-000000000001 ;;
  esac
}
job_directory() { printf '%s/%s/%s/jobs/%s\n' "$ARTIFACTS" "$1" "$2" "$(job_id "$1" "$2")"; }

resolve_corpus_file() {
  local corpus="$1" label="$2" expected file
  expected="$(jq -er --arg label "$label" '.source.references[] | select(.label == $label) | .sha256' "$(manifest_for "$corpus")")"
  while IFS= read -r file; do
    if [[ "$(sha256 "$file")" == "$expected" ]]; then printf '%s\n' "$file"; return; fi
  done < <(find "$(video_directory "$corpus")" -maxdepth 1 -type f -print | sort)
  die "No $label for $corpus matches $expected"
}

prepare_local_references() {
  local corpus="$1" locator source destination
  while IFS= read -r locator; do
    destination="$ROOT/$locator"
    [[ -f "$destination" ]] && continue
    [[ ! -L "$destination" ]] || die "Broken reference link: $destination"
    source="$FROZEN_REPO/$locator"
    [[ -f "$source" ]] || die "Missing frozen local reference: $source"
    mkdir -p "$(dirname "$destination")"
    ln -s "$source" "$destination"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | .locator' "$(manifest_for "$corpus")")
}

verify_corpus() {
  local corpus="$1" label path locator expected
  for label in source-video reference-archive; do
    path="$(resolve_corpus_file "$corpus" "$label")"
    printf '%s\t%s\t%s\t%s\n' "$corpus" "$label" "$(sha256 "$path")" "$path"
  done
  while IFS=$'\t' read -r expected locator; do
    path="$ROOT/$locator"
    [[ -f "$path" && "$(sha256 "$path")" == "$expected" ]] \
      || die "Reference mismatch: $path"
    printf '%s\tlocal-reference\t%s\t%s\n' "$corpus" "$expected" "$path"
  done < <(jq -r '.source.references[] | select(.locator | test("^[a-z]+:") | not) | [.sha256,.locator] | @tsv' "$(manifest_for "$corpus")")
  for path in "$BASELINE/$corpus-manifest.json" "$BASELINE/$corpus-raw-asr.json.gz" \
    "$BASELINE/$corpus-japanese-transcript.txt" "$BASELINE/$corpus-english-translation-transcript.txt"; do
    [[ -s "$path" ]] || die "Missing retained E22 baseline: $path"
  done
  gzip -t "$BASELINE/$corpus-raw-asr.json.gz"
}

verify_decisions() {
  git merge-base --is-ancestor 5c8418be180e9446c4ca7267eadd1cdf20e4f7f9 HEAD \
    || die "Final #103 evidence is not integrated"
  local path expected actual
  while IFS=$'\t' read -r path expected; do
    actual="$(sha256 "$path")"
    [[ "$actual" == "$expected" ]] || die "Decision evidence changed: $path"
  done <<EOF
docs/japanese-live/experiments/evidence/E30/report.json	$(git show 83d452ddce9f1177f4b580b29aea19629e2c76ec:docs/japanese-live/experiments/evidence/E30/report.json | shasum -a 256 | awk '{print $1}')
docs/japanese-live/experiments/evidence/E26-moss-promotion/decision.json	$(git show 14bdeba69707b4e0ea61a3ea42d1b7d9891de7e6:docs/japanese-live/experiments/evidence/E26-moss-promotion/decision.json | shasum -a 256 | awk '{print $1}')
docs/japanese-live/experiments/E24-readable-cues-validation.md	$(git show 70e6b46ba25ed72f92f113120ed3b7c2d18a2fe4:docs/japanese-live/experiments/E24-readable-cues-validation.md | shasum -a 256 | awk '{print $1}')
docs/japanese-live/experiments/evidence/issue-103-no-run.json	$(git show 5c8418be180e9446c4ca7267eadd1cdf20e4f7f9:docs/japanese-live/experiments/evidence/issue-103-no-run.json | shasum -a 256 | awk '{print $1}')
EOF
  jq -n \
    --arg laneA "$(sha256 docs/japanese-live/experiments/evidence/E30/report.json)" \
    --arg moss "$(sha256 docs/japanese-live/experiments/evidence/E26-moss-promotion/decision.json)" \
    --arg overlap "$(sha256 docs/japanese-live/experiments/evidence/issue-103-no-run.json)" \
    --arg cues "$(sha256 docs/japanese-live/experiments/E24-readable-cues-validation.md)" \
    '[{ticket:96,result:"QWEN_STANDARD",sha256:$laneA},
      {ticket:100,result:"NO_MOSS_PRODUCT",sha256:$moss},
      {ticket:103,result:"NO_RUN_NO_ADMISSIBLE_DEV_SEPARATOR",sha256:$overlap},
      {ticket:105,result:"STANDARD_CUES",sha256:$cues}]' >"$ARTIFACTS/decisions.json"
}

verify_models() {
  local base="$BASELINE/model-provenance.json" item path expected four_root four_path
  [[ -f "$base" ]] || die "Missing E22 model provenance"
  if [[ "$MODE" == TRANSLATION_ONLY_12B || "$MODE" == TRANSLATION_SMOKE_12B_100 ]]; then
    jq '.weights = [.weights[] | select(.modelID == "mlx-community/translategemma-12b-it-4bit")]' \
      "$base" >"$ARTIFACTS/model-provenance.json"
  elif [[ "$MODE" == TRANSLATION_ONLY_4B ]]; then
    jq '.weights = []' "$base" >"$ARTIFACTS/model-provenance.json"
  elif [[ "$MODE" == 4B_ONLY ]]; then
    jq 'del(.weights[] | select(.modelID == "mlx-community/translategemma-12b-it-4bit"))' \
      "$base" >"$ARTIFACTS/model-provenance.json"
  else
    cp "$base" "$ARTIFACTS/model-provenance.json"
  fi
  while IFS= read -r item; do
    path="$(jq -r .sourcePath <<<"$item")"; expected="$(jq -r .sha256 <<<"$item")"
    [[ -f "$path" && "$(sha256 "$path")" == "$expected" ]] \
      || die "Model provenance mismatch: $path"
  done < <(jq -c '.weights[]' "$ARTIFACTS/model-provenance.json")
  [[ "$MODE" == TRANSLATION_ONLY_12B || "$MODE" == TRANSLATION_SMOKE_12B_100 ]] && return 0
  four_root="${HF_HUB_CACHE:-/Users/maz/.cache/huggingface/hub}/models--mlx-community--translategemma-4b-it-4bit/snapshots/5788ec08c047f3f2e17808101b8d9566ac930d58"
  four_path="$four_root/model.safetensors"
  expected=113acb0c29997a3015af84bec2c8f967cb7b15f8959d1c26b9628b921e324c40
  [[ -f "$four_path" && "$(sha256 "$four_path")" == "$expected" ]] \
    || die "TranslateGemma 4B cache/hash mismatch: $four_path"
  jq --arg path "$four_path" --arg hash "$expected" --argjson size "$(stat -f %z "$four_path")" \
    '.weights += [{modelID:"mlx-community/translategemma-4b-it-4bit",
      revision:"5788ec08c047f3f2e17808101b8d9566ac930d58",file:"model.safetensors",
      sourcePath:$path,sizeBytes:$size,sha256:$hash}]' "$ARTIFACTS/model-provenance.json" \
      >"$ARTIFACTS/model-provenance.updated.json"
  mv "$ARTIFACTS/model-provenance.updated.json" "$ARTIFACTS/model-provenance.json"
}

prepare_translation_replay() {
  local corpus source raw request_hash rows='[]'
  local e31="$ROOT/docs/japanese-live/experiments/evidence/E31-4b-pressure-attempt"
  mkdir -p "$ARTIFACTS/frozen"
  for corpus in qudu2fx3ncc md62mmdz0m; do
    source="$BASELINE/$corpus-raw-asr.json.gz"
    raw="$ARTIFACTS/frozen/$corpus-raw-asr.json"
    gzip -t "$source"
    gzip -dc "$source" >"$raw"
    jq -e '
      .model.backend == "qwen-ja"
      and .alignment.modelID == "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
      and .diarization.modelID == "argmaxinc/speakerkit-coreml"
      and .diarization.speakerCountPolicy == {mode:"automatic"}
      and .diarization.useExclusiveReconciliation == false
      and (.translation.request.turns | length) > 0
    ' "$raw" >/dev/null
    request_hash="$(jq -cS '.translation.request | del(.source.modifiedAt)' "$raw" \
      | shasum -a 256 | awk '{print $1}')"
    rows="$(jq -c --arg corpus "$corpus" --arg path "$source" \
      --arg gzipHash "$(sha256 "$source")" --arg rawHash "$(sha256 "$raw")" \
      --arg requestHash "$request_hash" \
      '. + [{corpusID:$corpus,source:$path,gzipSHA256:$gzipHash,
        decompressedSHA256:$rawHash,semanticTranslationRequestSHA256:$requestHash}]' <<<"$rows")"
  done

  local e22="$ARTIFACTS/frozen/qudu2fx3ncc-raw-asr.json"
  local asr_current asr_e22 alignment_current alignment_e22 speaker_current speaker_e22
  asr_current="$(jq -r '.exchange.rawTranscript // (.exchange.chunks | map(.transcript) | join(""))' \
    "$e31/asr/response-1.json" | shasum -a 256 | awk '{print $1}')"
  asr_e22="$(jq -r .rawASR "$e22" | shasum -a 256 | awk '{print $1}')"
  alignment_current="$(jq -cS .alignment.chunks "$e31/alignment/response.json" \
    | shasum -a 256 | awk '{print $1}')"
  alignment_e22="$(jq -cS .alignment.chunks "$e22" | shasum -a 256 | awk '{print $1}')"
  speaker_current="$(jq -cS .diarization.spans "$e31/speakerkit/response.json" \
    | shasum -a 256 | awk '{print $1}')"
  speaker_e22="$(jq -cS .diarization.rawSpans "$e22" | shasum -a 256 | awk '{print $1}')"
  [[ "$asr_current" == "$asr_e22" && "$alignment_current" == "$alignment_e22" \
    && "$speaker_current" == "$speaker_e22" ]] \
    || die "E31/E22 upstream semantic identity check failed"
  jq -n --argjson corpora "$rows" --arg e31 "$e31" --arg mode "$MODE" \
    --arg asr "$asr_current" --arg alignment "$alignment_current" --arg speaker "$speaker_current" \
    '{schemaVersion:1,ticket:106,runMode:$mode,corpora:$corpora,
      e31Video1UpstreamSemanticIdentity:{source:$e31,ASR:$asr,alignment:$alignment,
        SpeakerKit:$speaker,match:true},
      replayInvariant:"The current HighQualityJob recomputes and exactly matches frozen source turns and glossary inputs; accepted English context remains candidate-dependent output.",
      fullIntegratedRun:false,ticket106Concluded:false}' \
    >"$ARTIFACTS/translation-replay-source.json"
}

implementation_hashes() {
  local value='{}' path digest
  for path in Sources/HighQualityJob.swift Sources/HighQualityJobView.swift \
    Sources/HighQualityWorkerProcess.swift Sources/HighQualityTranslationWorker.swift \
    Sources/HeavyweightModelGate.swift Sources/LocalMLXTranslator.swift \
    Tests/HighQualityAcceptanceTests.swift Tests/HighQualityLocalTranslationTests.swift \
    Scripts/run_integrated_offline_validation.sh \
    Scripts/run_mossformer2_oracle_experiment.sh Scripts/test_mossformer2_guard.sh \
    Scripts/report_integrated_offline_validation.py Scripts/report_high_quality_acceptance.py \
    Scripts/report_local_translator_bakeoff.py Scripts/report_japanese_l7d.py \
    Scripts/comet_score_compat.py; do
    digest="$(sha256 "$path")"
    value="$(jq -c --arg path "$path" --arg digest "$digest" '. + {($path):$digest}' <<<"$value")"
  done
  printf '%s\n' "$value"
}

write_metadata() {
  local translator="$1" corpus="$2"
  local directory="$ARTIFACTS/$translator/$corpus"
  local source archive manifest="$(manifest_for "$corpus")"
  source="$(resolve_corpus_file "$corpus" source-video)"
  archive="$(resolve_corpus_file "$corpus" reference-archive)"
  mkdir -p "$directory/jobs"
  jq -n --arg translator "$translator" --arg model "$(model_id "$translator")" \
    --arg revision "$(model_revision "$translator")" --arg corpus "$corpus" \
    --arg source "$source" --arg sourceHash "$(sha256 "$source")" \
    --arg archive "$archive" --arg archiveHash "$(sha256 "$archive")" \
    --arg manifestHash "$(sha256 "$manifest")" \
    --arg corpusPreflight "$(sha256 "$ARTIFACTS/corpus-preflight.tsv")" \
    --argjson localReferences "$(jq -c '[.source.references[]
      | select(.locator | test("^[a-z]+:") | not) | {locator,sha256}]' "$manifest")" \
    --arg commit "$(git rev-parse HEAD)" --argjson implementation "$(implementation_hashes)" \
    --arg decisions "$(sha256 "$ARTIFACTS/decisions.json")" \
    --arg models "$(sha256 "$ARTIFACTS/model-provenance.json")" \
    --arg worker "$(sha256 "$WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE")" \
    --arg metallib "$(sha256 "$ROOT/.build/debug/mlx.metallib")" \
    '{schemaVersion:1,ticket:106,corpusID:$corpus,translator:$translator,
      translationModelID:$model,translationRevision:$revision,commit:$commit,
      sourcePath:$source,sourceSHA256:$sourceHash,referenceArchivePath:$archive,
      referenceArchiveSHA256:$archiveHash,corpusManifestSHA256:$manifestHash,
      corpusPreflightSHA256:$corpusPreflight,localReferences:$localReferences,
      decisionsSHA256:$decisions,
      modelProvenanceSHA256:$models,implementationSHA256:$implementation,
      runtimeSHA256:{workerExecutable:$worker,mlxMetallib:$metallib},
      configuration:{ASR:"Qwen Standard",alignment:"Qwen3 Forced Aligner",
        diarization:"SpeakerKit Standard",cues:"Standard",overlapRecovery:null,
        translation:$translator}}' >"$directory/run-meta.json"
}

finalize_metadata() {
  local translator="$1" corpus="$2" route="$3"
  local directory="$ARTIFACTS/$translator/$corpus"
  local job="$(job_directory "$translator" "$corpus")" temporary="$directory/run-meta.updated.json"
  jq --arg route "$route" --arg manifest "$(sha256 "$job/manifest.json")" \
    --arg raw "$(sha256 "$job/raw-asr.json")" \
    --arg safety "$(sha256 "$directory/safety.json")" --arg samples "$(sha256 "$directory/safety.samples.jsonl")" \
    '. + {resultRoute:$route,rawArtifactSHA256:{"manifest.json":$manifest,"raw-asr.json":$raw},
      safetySHA256:{"safety.json":$safety,"safety.samples.jsonl":$samples}}' \
    "$directory/run-meta.json" >"$temporary"
  mv "$temporary" "$directory/run-meta.json"
}

job_is_reusable() {
  local translator="$1" corpus="$2" directory="$ARTIFACTS/$1/$2"
  local job="$(job_directory "$translator" "$corpus")" metadata="$directory/run-meta.json"
  [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" && -f "$metadata" \
    && -f "$directory/safety.json" && -f "$directory/safety.samples.jsonl" ]] || return 1
  jq -e --arg commit "$(git rev-parse HEAD)" --argjson implementation "$(implementation_hashes)" \
    --arg decisions "$(sha256 "$ARTIFACTS/decisions.json")" \
    --arg models "$(sha256 "$ARTIFACTS/model-provenance.json")" \
    --arg manifest "$(sha256 "$(manifest_for "$corpus")")" \
    --arg corpusPreflight "$(sha256 "$ARTIFACTS/corpus-preflight.tsv")" \
    '.commit == $commit
      and .decisionsSHA256 == $decisions and .modelProvenanceSHA256 == $models
      and .corpusManifestSHA256 == $manifest
      and .corpusPreflightSHA256 == $corpusPreflight
      and (.implementationSHA256 == $implementation
        or (.harnessRecovery.validatorImplementationSHA256 == $implementation
          and .harnessRecovery.runtimeImplementationUnchanged == true))
      and (.resultRoute == "completed" or .resultRoute == "model-quality-rejection")' \
    "$metadata" >/dev/null || return 1
  jq -e --arg manifest "$(sha256 "$job/manifest.json")" --arg raw "$(sha256 "$job/raw-asr.json")" \
    --arg safety "$(sha256 "$directory/safety.json")" \
    --arg samples "$(sha256 "$directory/safety.samples.jsonl")" \
    '.rawArtifactSHA256 == {"manifest.json":$manifest,"raw-asr.json":$raw}
      and .safetySHA256 == {"safety.json":$safety,"safety.samples.jsonl":$samples}' \
    "$metadata" >/dev/null || return 1
  jq -e '.stopReason == "completed"' "$directory/safety.json" >/dev/null
}

check_worker_exit() {
  local raw="$1" pid
  while IFS= read -r pid; do
    ! process_running "$pid" || die "Worker PID $pid remains resident after unload"
  done < <(jq -er '[.asrWorker.lifecycle.processIdentifier,.alignment.worker.processIdentifier,
    .diarization.worker.processIdentifier,.translation.worker.processIdentifier][]' "$raw")
}

check_job() {
  local translator="$1" corpus="$2"
  local job="$(job_directory "$translator" "$corpus")"
  local expected_model="$(model_id "$translator")" expected_revision="$(model_revision "$translator")"
  jq -e --arg model "$expected_model" --arg revision "$expected_revision" '
    def worker_ok: . != null and .exitStatus == 0 and .forcedTermination == false
      and .peakPhysicalFootprintBytes > 0 and (.availableMemorySamples | length) > 0
      and ([.pressureTransitions[] | select(.level != "normal")] | length) == 0;
    .model.backend == "qwen-ja"
      and .alignment.modelID == "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
      and .alignment.validationDiagnostics == []
      and .diarization.modelID == "argmaxinc/speakerkit-coreml"
      and .diarization.useExclusiveReconciliation == false
      and .diarization.validationDiagnostics == []
      and .speakerConfiguration == {enhancedPrecision:false,sensitiveDetection:false,
        countPolicy:{mode:"automatic"}}
      and .translation.model == $model and .translation.revision == $revision
      and ([.modelEvents[] | select(.kind == "guard-failed")] | length) == 0
      and ([.modelEvents[] | select(.kind == "memory-pressure-checked")] | length) == 4
      and all(.modelEvents[] | select(.kind == "memory-pressure-checked");
        (.message | contains("policy=macos-memory-pressure")) and (.message | contains("reserve=0")))
      and ([.asrWorker.lifecycle,.alignment.worker,.diarization.worker,.translation.worker]
        | all(worker_ok))
      and ([.asrWorker.lifecycle.processIdentifier,.alignment.worker.processIdentifier,
        .diarization.worker.processIdentifier,.translation.worker.processIdentifier]
        | unique | length) == 4
      and .asrWorker.lifecycle.exitedAt <= .alignment.worker.startedAt
      and .alignment.worker.exitedAt <= .diarization.worker.startedAt
      and .diarization.worker.exitedAt <= .translation.worker.startedAt' "$job/raw-asr.json" >/dev/null
  jq -e --arg model "$expected_model" '
    .selectedBackend == "qwen-ja" and .translationModel.modelID == $model
      and .speakerConfiguration == {enhancedPrecision:false,sensitiveDetection:false,
        countPolicy:{mode:"automatic"}}' "$job/manifest.json" >/dev/null
  check_worker_exit "$job/raw-asr.json"
}

translation_worker_ready_since() {
  local marker="$1" temp_root="${2:-${TMPDIR:-/tmp}}" response
  while IFS= read -r response; do
    jq -e '.ready == true' "$response" >/dev/null 2>&1 && return 0
  done < <(find "$temp_root" -maxdepth 2 -type f -name ready.json \
    -path '*/WhisperASR-TranslateGemma-*/*' -newer "$marker" -print 2>/dev/null)
  return 1
}

diagnose_failure() {
  local translator="$1" corpus="$2" status="$3"
  local directory="$ARTIFACTS/$translator/$corpus"
  local job="$(job_directory "$translator" "$corpus")" route=harness
  if [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]]; then
    route="$(jq -r '.failures[0].stage // "application"' "$job/manifest.json")"
  fi
  if ! (
    echo "ticket=106 translator=$translator corpus=$corpus exit=$status route=$route" &&
      xcrun swift build &&
      verify_corpus "$corpus" &&
      { [[ ! -f "$job/manifest.json" ]] || jq empty "$job/manifest.json"; } &&
      { [[ ! -f "$job/raw-asr.json" ]] || jq empty "$job/raw-asr.json"; }
  ) >"$directory/diagnostic.log" 2>&1; then
    route=harness
  fi
  jq -n --arg route "$route" --argjson exitStatus "$status" \
    '{ticket:106,classification:$route,exitStatus:$exitStatus,modelVerdictAssigned:false}' \
    >"$directory/diagnostic.json"
}

verify_safe_4b_translation_replay() {
  local evidence="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-only-4b"
  local report="$ROOT/docs/high-quality-integrated-e31-translation-only-4b.json"
  local corpus directory
  [[ -f "$evidence/sha256.tsv" && -f "$report" ]] \
    || die "Missing completed 4B replay evidence required before 12B"
  shasum -a 256 -c "$evidence/sha256.tsv" >/dev/null \
    || die "4B replay evidence hash verification failed"
  jq -e '.workflowAuditable == true and .ticket106Concluded == false
    and .runMode == "TRANSLATION_ONLY_4B"
    and .campaignClassification == "INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE"
    and .gates.strictLifecycle == true and .gates.rawArtifactHashes == true' \
    "$report" >/dev/null || die "4B replay report is not safe/auditable"
  for corpus in qudu2fx3ncc md62mmdz0m; do
    directory="$evidence/translategemma-4b-it-4bit-$corpus"
    jq -e '.stopReason == "completed" and .forcedTermination == false
      and .postLoadRunawayGuard.modelLoadedObserved == true
      and .peakSwapDeltaBytes == 0
      and all(.nativePressureLevels[]; . == "normal")' \
      "$directory/safety.json" >/dev/null \
      || die "4B replay safety gate failed: $corpus"
    jq -e '.resident == false and .unloadVerified == true
      and .nativePressureLevel == "normal"' "$directory/cleanup.json" >/dev/null \
      || die "4B replay cleanup gate failed: $corpus"
  done
}

verify_safe_12b_translation_smoke() {
  local evidence="$ROOT/docs/japanese-live/experiments/evidence/E31-translation-smoke-12b-100"
  local directory="$evidence/translategemma-12b-it-4bit/qudu2fx3ncc"
  [[ -f "$evidence/sha256.tsv" && -f "$evidence/smoke-report.json" ]] \
    || die "Missing completed 100-cue 12B smoke required before full 12B replay"
  (cd "$evidence" && shasum -a 256 -c sha256.tsv >/dev/null) \
    || die "12B smoke evidence hash verification failed"
  jq -e '.runMode == "TRANSLATION_SMOKE_12B_100" and .status == "completed"
    and .cueCount == 100 and .ticket106Concluded == false
    and .memory.stopReason == "completed"
    and .memory.peakSwapDeltaBytes == 0
    and all(.memory.nativePressureLevels[]; . == "normal")' \
    "$evidence/smoke-report.json" >/dev/null || die "12B smoke report is not safe"
  jq -e --arg request "$SMOKE_12B_REQUEST_SHA256" '
    .runMode == "TRANSLATION_SMOKE_12B_100" and .cueLimit == 100
      and .frozenTranslationRequestSHA256 == $request' \
    "$directory/run-meta.json" >/dev/null || die "12B smoke provenance gate failed"
  jq -e '.stopReason == "completed" and .forcedTermination == false
    and .postLoadRunawayGuard.modelLoadedObserved == true
    and .peakSwapDeltaBytes == 0
    and all(.nativePressureLevels[]; . == "normal")' \
    "$directory/safety.json" >/dev/null || die "12B smoke safety gate failed"
  jq -e '.resident == false and .unloadVerified == true
    and .nativePressureLevel == "normal"' \
    "$directory/cleanup.json" >/dev/null || die "12B smoke cleanup gate failed"
  for file in ready.json request-1.json response-1.json shutdown worker.log; do
    [[ -f "$directory/worker-raw/$file" ]] || die "12B smoke raw worker evidence missing: $file"
  done
}

run_job() {
  local translator="$1" corpus="$2"
  local directory="$ARTIFACTS/$translator/$corpus"
  local job="$(job_directory "$translator" "$corpus")" log="$directory/run.log"
  local ready="$directory/translation-loaded" marker="$directory/job-started" watcher status=0 route
  CURRENT_TRANSLATOR="$translator"; CURRENT_CORPUS="$corpus"; PHASE=run
  if job_is_reusable "$translator" "$corpus"; then
    check_job "$translator" "$corpus"
    echo "Reusing complete #106 evidence: $translator/$corpus"
    return
  fi
  [[ ! -e "$job" ]] || die "Incomplete run retained at $job; preserve it and choose a new artifact root"
  write_metadata "$translator" "$corpus"
  touch "$marker"
  (
    trap - ERR
    while [[ ! -f "$ready" ]]; do
      translation_worker_ready_since "$marker" && { touch "$ready"; break; }
      sleep 1
    done
  ) & watcher="$!"
  WARNING_CLEANUP_RETRY_ENABLED=true
  if run_guarded "$directory/safety.json" "$log" "$JOB_TIMEOUT_SECONDS" "$ready" env \
    WHISPERASR_RUN_HIGH_QUALITY_ACCEPTANCE=1 WHISPERASR_ACCEPTANCE_BACKEND=qwen-ja \
    WHISPERASR_ACCEPTANCE_TRANSLATOR="$translator" WHISPERASR_ACCEPTANCE_CORPUS="$corpus" \
    WHISPERASR_ACCEPTANCE_SOURCE="$(resolve_corpus_file "$corpus" source-video)" \
    WHISPERASR_ACCEPTANCE_REFERENCE_ARCHIVE="$(resolve_corpus_file "$corpus" reference-archive)" \
    WHISPERASR_ACCEPTANCE_JOB_ID="$(job_id "$translator" "$corpus")" \
    WHISPERASR_ACCEPTANCE_OUTPUT_ROOT="$directory/jobs" \
    WHISPERASR_ACCEPTANCE_TRANSLATION_CONTEXT=product-default \
    WHISPERASR_ACCEPTANCE_ALLOW_HOLDOUT="$([[ "$corpus" == md62mmdz0m ]] && echo 1 || echo 0)" \
    xcrun swift test --skip-build --filter HighQualityAcceptanceTests/testRealFrozenWorkflowWhenOptedIn; then
    status=0
  else
    status="$?"
  fi
  WARNING_CLEANUP_RETRY_ENABLED=false
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  cat "$log"
  [[ "$(jq -r .stopReason "$directory/safety.json")" == completed ]] \
    || die "Safety stop: $(jq -r .stopReason "$directory/safety.json")"
  [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]] || {
    diagnose_failure "$translator" "$corpus" "$status"
    die "Harness/process failure before auditable product evidence"
  }
  check_job "$translator" "$corpus"
  if ((status == 0)); then
    jq -e '.status == "completed" and .failures == []' "$job/manifest.json" >/dev/null
    route=completed
  elif jq -e '.status == "failed" and .failures[0].stage == "translation"
      and (.failures[0].message | contains("failed validation twice"))' "$job/manifest.json" >/dev/null; then
    route=model-quality-rejection
    echo "Retained product translation-quality rejection: $translator/$corpus"
  else
    diagnose_failure "$translator" "$corpus" "$status"
    die "Non-quality failure; no model verdict assigned"
  fi
  finalize_metadata "$translator" "$corpus" "$route"
}

check_translation_replay() {
  local translator="$1" corpus="$2" job="$(job_directory "$1" "$2")"
  local frozen="$ARTIFACTS/frozen/$corpus-raw-asr.json" pid
  jq -e --arg model "$(model_id "$translator")" --arg revision "$(model_revision "$translator")" '
    .model.backend == "qwen-ja"
      and .alignment.modelID == "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
      and .diarization.modelID == "argmaxinc/speakerkit-coreml"
      and .diarization.speakerCountPolicy == {mode:"automatic"}
      and .diarization.useExclusiveReconciliation == false
      and .translation.model == $model and .translation.revision == $revision
      and .translation.worker.exitStatus == 0
      and .translation.worker.forcedTermination == false
      and ([.translation.worker.pressureTransitions[] | select(.level == "critical")] | length) == 0
  ' "$job/raw-asr.json" >/dev/null
  [[ "$(jq -cS '.translation.request | {turns,glossary,glossaryByCueID}' "$job/raw-asr.json" \
      | shasum -a 256 | awk '{print $1}')" \
    == "$(jq -cS '.translation.request | {turns,glossary,glossaryByCueID}' "$frozen" \
      | shasum -a 256 | awk '{print $1}')" ]] \
    || die "Current translation request differs from frozen upstream evidence: $corpus"
  pid="$(jq -er .translation.worker.processIdentifier "$job/raw-asr.json")"
  ! process_running "$pid" || die "Translation worker PID $pid remains resident after unload"
}

record_translation_replay_cleanup() {
  local translator="$1" corpus="$2" job="$(job_directory "$1" "$2")" pid
  pid="$(jq -er .translation.worker.processIdentifier "$job/raw-asr.json")"
  ! process_running "$pid" || die "Translation worker PID $pid remains resident before handoff"
  wait_for_normal_pressure
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pid "$pid" \
    --arg pressure "$SYSTEM_PRESSURE_LEVEL" --argjson raw "$SYSTEM_PRESSURE_RAW" \
    --argjson free "$SYSTEM_FREE" --argjson swap "$SYSTEM_SWAP_BYTES" \
    --argjson pageouts "$SYSTEM_PAGEOUTS" \
    --arg mode "$MODE" \
    '{ticket:106,runMode:$mode,at:$at,translationWorkerPID:$pid,
      resident:false,unloadVerified:true,nativePressureLevel:$pressure,
      nativePressureRaw:$raw,freeMemoryPercent:$free,swapUsedBytes:$swap,pageouts:$pageouts}' \
    >"$ARTIFACTS/$translator/$corpus/cleanup.json"
}

capture_translation_worker_raw() {
  local worker="$1" destination="$2" file
  mkdir -p "$destination"
  while IFS= read -r file; do cp "$file" "$destination/"; done \
    < <(find "$worker" -maxdepth 1 -type f -print | sort)
  for file in ready.json request-1.json response-1.json shutdown worker.log; do
    [[ -f "$destination/$file" ]] || die "Translation worker raw artifact missing: $file"
  done
}

run_translation_smoke() {
  local translator=translategemma-12b-it-4bit corpus=qudu2fx3ncc
  local directory="$ARTIFACTS/$translator/$corpus" output="$ARTIFACTS/$translator/$corpus/smoke.json"
  local log="$directory/run.log" ready="$directory/translation-loaded"
  local marker="$directory/job-started" watcher status=0 pid recovered=false
  CURRENT_TRANSLATOR="$translator"; CURRENT_CORPUS="$corpus"; PHASE=translation-smoke
  mkdir -p "$directory"
  if [[ -e "$output" ]]; then
    jq -e '.stopReason == "completed" and .exitStatus == 0' \
      "$directory/safety.json" >/dev/null \
      || die "Existing 12B smoke is partial or unsafe; preserve it"
    recovered=true
    echo "Recovering completed 12B smoke post-processing without rerunning the model"
  else
    write_metadata "$translator" "$corpus"
    jq --arg mode "$MODE" --argjson cueLimit 100 \
      --arg request "$SMOKE_12B_REQUEST" --arg requestHash "$SMOKE_12B_REQUEST_SHA256" \
      '. + {runMode:$mode,cueLimit:$cueLimit,fullIntegratedRun:false,ticket106Concluded:false,
        frozenTranslationRequestPath:$request,frozenTranslationRequestSHA256:$requestHash}' \
      "$directory/run-meta.json" >"$directory/run-meta.updated.json"
    mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
    touch "$marker"
    (
      trap - ERR
      while [[ ! -f "$ready" ]]; do
        translation_worker_ready_since "$marker" && { touch "$ready"; break; }
        sleep 1
      done
    ) & watcher="$!"
    WARNING_CLEANUP_RETRY_ENABLED=true
    if run_guarded "$directory/safety.json" "$log" 900 "$ready" env \
      WHISPERASR_RUN_DIRECT_TRANSLATION_EXPERIMENT=1 \
      WHISPERASR_DIRECT_TRANSLATION_EVIDENCE="$ARTIFACTS/frozen/$corpus-raw-asr.json" \
      WHISPERASR_DIRECT_TRANSLATION_REQUEST="$SMOKE_12B_REQUEST" \
      WHISPERASR_DIRECT_TRANSLATION_OUTPUT="$output" \
      WHISPERASR_DIRECT_TRANSLATION_CUE_LIMIT=100 \
      xcrun swift test --skip-build \
        --filter HighQualityLocalTranslationTests/testOfficialDirectProtocolOnFrozenSemanticUnitsWhenOptedIn; then
      status=0
    else
      status="$?"
    fi
    WARNING_CLEANUP_RETRY_ENABLED=false
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  fi
  capture_translation_worker_raw \
    "$(dirname "$(jq -er .worker.rawLogPath "$output")")" "$directory/worker-raw"
  find "$ARTIFACTS" -type f ! -name sha256.tsv -print0 | sort -z | \
    xargs -0 shasum -a 256 >"$ARTIFACTS/sha256.tsv"
  cat "$log"
  [[ "$(jq -r .stopReason "$directory/safety.json")" == completed ]] \
    || die "Translation smoke safety stop: $(jq -r .stopReason "$directory/safety.json")"
  if ((status != 0)); then
    diagnose_failure "$translator" "$corpus" "$status"
    die "Translation smoke harness/model-output failure; no model quality verdict assigned"
  fi
  jq -e '
    (.request.turns | length) == 100 and (.batches | length) == 100
      and all(.batches[]; (.cueIDs | length) == 1 and .sanitizedOutput != "")
      and .validationFailures == [] and .worker.exitStatus == 0
      and .worker.forcedTermination == false
  ' "$output" >/dev/null || die "Translation smoke output is incomplete"
  pid="$(jq -er .worker.processIdentifier "$output")"
  ! process_running "$pid" || die "Translation smoke worker $pid remains resident"
  wait_for_normal_pressure
  jq -n --argjson pid "$pid" --arg pressure "$SYSTEM_PRESSURE_LEVEL" \
    --argjson raw "$SYSTEM_PRESSURE_RAW" --argjson free "$SYSTEM_FREE" \
    --argjson swap "$SYSTEM_SWAP_BYTES" --argjson pageouts "$SYSTEM_PAGEOUTS" \
    '{translationWorkerPID:$pid,resident:false,unloadVerified:true,
      nativePressureLevel:$pressure,nativePressureRaw:$raw,freeMemoryPercent:$free,
      swapUsedBytes:$swap,pageouts:$pageouts}' >"$directory/cleanup.json"
  jq -n --arg mode "$MODE" --arg output "$(sha256 "$output")" \
    --arg safety "$(sha256 "$directory/safety.json")" \
    --arg samples "$(sha256 "$directory/safety.samples.jsonl")" \
    --arg cleanup "$(sha256 "$directory/cleanup.json")" \
    --argjson recovered "$recovered" --argjson implementation "$(implementation_hashes)" \
    --argjson memory "$(jq '{elapsedSeconds,peakResidentBytes,peakPhysicalFootprintBytes,
      minimumFreeMemoryPercent,nativePressureLevels,peakSwapDeltaBytes,stopReason,
      warningRecoveryGuard,systemBefore,systemAfter}' "$directory/safety.json")" \
    '{ticket:106,runMode:$mode,status:"completed",cueCount:100,
      freshProcessPerRun:true,modelQualityVerdictAssigned:false,ticket106Concluded:false,
      harnessRecovery:(if $recovered then {reason:"raw worker capture find returned nonzero after the completed model run",modelWasNotRerun:true,
        postProcessorImplementationSHA256:$implementation} else null end),
      memory:$memory,sha256:{"smoke.json":$output,"safety.json":$safety,
        "safety.samples.jsonl":$samples,"cleanup.json":$cleanup}}' \
    >"$ARTIFACTS/smoke-report.json"
  find "$ARTIFACTS" -type f ! -name sha256.tsv -print0 | sort -z | \
    xargs -0 shasum -a 256 >"$ARTIFACTS/sha256.tsv"
  [[ ! -e "$EVIDENCE" ]] || die "Retained 12B smoke evidence already exists; preserve it"
  mkdir -p "$EVIDENCE"
  cp -R "$ARTIFACTS"/. "$EVIDENCE"/
  (cd "$EVIDENCE" && find . -type f ! -name sha256.tsv -print0 | sort -z | \
    xargs -0 shasum -a 256 >sha256.tsv)
  echo "Smoke report: $ARTIFACTS/smoke-report.json"
  echo "Retained evidence: $EVIDENCE"
}

run_translation_replay() {
  local translator="$REPLAY_TRANSLATOR" corpus="$1"
  local directory="$ARTIFACTS/$translator/$corpus"
  local job="$(job_directory "$translator" "$corpus")" log="$directory/run.log"
  local frozen="$ARTIFACTS/frozen/$corpus-raw-asr.json"
  local ready="$directory/translation-loaded" marker="$directory/job-started" watcher status=0 route
  CURRENT_TRANSLATOR="$translator"; CURRENT_CORPUS="$corpus"; PHASE=translation-replay
  if job_is_reusable "$translator" "$corpus"; then
    check_translation_replay "$translator" "$corpus"
    record_translation_replay_cleanup "$translator" "$corpus"
    echo "Reusing complete #106 translation replay: $translator/$corpus"
    return
  fi
  if [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" \
      && -f "$directory/run-meta.json" && -f "$directory/safety.json" \
      && -f "$directory/safety.samples.jsonl" \
      && "$(jq -r .stopReason "$directory/safety.json")" == completed ]]; then
    check_translation_replay "$translator" "$corpus"
    jq -e --argjson current "$(implementation_hashes)" '
      (.implementationSHA256 | del(."Tests/HighQualityAcceptanceTests.swift",
        ."Scripts/run_integrated_offline_validation.sh",
        ."Scripts/report_integrated_offline_validation.py"))
      == ($current | del(."Tests/HighQualityAcceptanceTests.swift",
        ."Scripts/run_integrated_offline_validation.sh",
        ."Scripts/report_integrated_offline_validation.py"))' "$directory/run-meta.json" >/dev/null \
      || die "Runtime implementation changed; retained replay cannot be recovered"
    if jq -e '.status == "failed" and .failures[0].stage == "translation"
        and (.failures[0].message | contains("failed validation twice"))' \
        "$job/manifest.json" >/dev/null; then
      route=model-quality-rejection
    else
      die "Retained replay is not a recoverable translation-quality result"
    fi
    finalize_metadata "$translator" "$corpus" "$route"
    jq --argjson validator "$(implementation_hashes)" \
      --arg replay "$(sha256 "$ARTIFACTS/translation-replay-source.json")" '
      . + {translationReplaySourceSHA256:$replay,
        harnessRecovery:{reason:"post-run comparison included model-dependent English context",
        runtimeImplementationUnchanged:true,validatorImplementationSHA256:$validator}}' \
      "$directory/run-meta.json" >"$directory/run-meta.updated.json"
    mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
    record_translation_replay_cleanup "$translator" "$corpus"
    echo "Recovered complete #106 translation replay without rerunning the model: $translator/$corpus"
    return
  fi
  [[ ! -e "$job" ]] || die "Incomplete replay retained at $job; preserve it and choose a new artifact root"
  write_metadata "$translator" "$corpus"
  jq --arg source "$frozen" --arg sourceHash "$(sha256 "$frozen")" \
    --arg replay "$(sha256 "$ARTIFACTS/translation-replay-source.json")" \
    --arg mode "$MODE" \
    '. + {runMode:$mode,fullIntegratedRun:false,ticket106Concluded:false,
      frozenUpstreamPath:$source,frozenUpstreamSHA256:$sourceHash,
      translationReplaySourceSHA256:$replay}' "$directory/run-meta.json" \
    >"$directory/run-meta.updated.json"
  mv "$directory/run-meta.updated.json" "$directory/run-meta.json"
  touch "$marker"
  (
    trap - ERR
    while [[ ! -f "$ready" ]]; do
      translation_worker_ready_since "$marker" && { touch "$ready"; break; }
      sleep 1
    done
  ) & watcher="$!"
  WARNING_CLEANUP_RETRY_ENABLED=true
  if run_guarded "$directory/safety.json" "$log" "$JOB_TIMEOUT_SECONDS" "$ready" env \
    WHISPERASR_RUN_SEMANTIC_TRANSLATION_EXPERIMENT=1 \
    WHISPERASR_SEMANTIC_TRANSLATION_EVIDENCE="$frozen" \
    WHISPERASR_SEMANTIC_TRANSLATION_OUTPUT="$directory/jobs" \
    WHISPERASR_TRANSLATOR_CANDIDATE="$translator" WHISPERASR_TRANSLATOR_CORPUS="$corpus" \
    WHISPERASR_TRANSLATOR_JOB_ID="$(job_id "$translator" "$corpus")" \
    WHISPERASR_TRANSLATOR_ALLOW_HOLDOUT="$([[ "$corpus" == md62mmdz0m ]] && echo 1 || echo 0)" \
    xcrun swift test --skip-build \
      --filter HighQualityAcceptanceTests/testFrozenSemanticTranslationExperimentWhenOptedIn; then
    status=0
  else
    status="$?"
  fi
  WARNING_CLEANUP_RETRY_ENABLED=false
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  cat "$log"
  [[ "$(jq -r .stopReason "$directory/safety.json")" == completed ]] \
    || die "Translation replay safety stop: $(jq -r .stopReason "$directory/safety.json")"
  [[ -f "$job/manifest.json" && -f "$job/raw-asr.json" ]] \
    || die "Translation replay harness failure before auditable product evidence"
  check_translation_replay "$translator" "$corpus"
  if ((status == 0)); then
    jq -e '.status == "completed" and .failures == []' "$job/manifest.json" >/dev/null
    route=completed
  elif jq -e '.status == "failed" and .failures[0].stage == "translation"
      and (.failures[0].message | contains("failed validation twice"))' "$job/manifest.json" >/dev/null; then
    route=model-quality-rejection
  else
    diagnose_failure "$translator" "$corpus" "$status"
    die "Translation replay non-quality failure; no model verdict assigned"
  fi
  finalize_metadata "$translator" "$corpus" "$route"
  record_translation_replay_cleanup "$translator" "$corpus"
}

wait_for_normal_pressure() {
  local waited=0
  while ((waited < 300)); do
    read_system_memory || die "Native memory sampling failed at model handoff"
    [[ "$SYSTEM_PRESSURE_LEVEL" != critical ]] || die "Critical memory pressure at model handoff"
    [[ "$SYSTEM_PRESSURE_LEVEL" != normal ]] || return 0
    sleep 5; waited=$((waited + 5))
  done
  die "Native warning did not recover; 4B load remains blocked"
}

record_handoff() {
  local rows='[]' corpus raw pid exited
  PHASE=handoff; CURRENT_TRANSLATOR=translategemma-12b-it-4bit; CURRENT_CORPUS=""
  for corpus in qudu2fx3ncc md62mmdz0m; do
    raw="$(job_directory translategemma-12b-it-4bit "$corpus")/raw-asr.json"
    pid="$(jq -er .translation.worker.processIdentifier "$raw")"
    ! process_running "$pid" || die "12B worker $pid is still resident"
    exited="$(jq -er .translation.worker.exitedAt "$raw")"
    rows="$(jq -c --arg corpus "$corpus" --argjson pid "$pid" --arg exited "$exited" \
      '. + [{corpusID:$corpus,processIdentifier:$pid,exitedAt:$exited,resident:false}]' <<<"$rows")"
  done
  wait_for_normal_pressure
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pressure "$SYSTEM_PRESSURE_LEVEL" \
    --argjson raw "$SYSTEM_PRESSURE_RAW" --argjson free "$SYSTEM_FREE" \
    --argjson swap "$SYSTEM_SWAP_BYTES" --argjson workers "$rows" \
    '{ticket:106,at:$at,translateGemma12BWorkers:$workers,cacheCleanupVerified:true,
      nextModel:"translategemma-4b-it-4bit",nativePressureLevel:$pressure,
      nativePressureRaw:$raw,freeMemoryPercent:$free,swapUsedBytes:$swap}' \
      >"$ARTIFACTS/12b-to-4b-handoff.json"
}

record_comet_availability() {
  local checkpoint revision
  checkpoint="$(find -L "$COMET_CACHE/snapshots" -path '*/checkpoints/model.ckpt' \
    -type f -print -quit 2>/dev/null || true)"
  if [[ -x "$COMET_PYTHON" && -n "$checkpoint" ]]; then
    revision="$(basename "$(dirname "$(dirname "$checkpoint")")")"
    jq -n --arg executable "$COMET_PYTHON" --arg checkpoint "$checkpoint" \
      --arg revision "$revision" --arg sha256 "$(sha256 "$checkpoint")" \
      --argjson size "$(stat -Lf %z "$checkpoint")" \
      '{available:true,model:"Unbabel/wmt22-comet-da",revision:$revision,
        executable:$executable,checkpoint:$checkpoint,checkpointSizeBytes:$size,
        checkpointSHA256:$sha256}' >"$ARTIFACTS/comet-availability.json"
  else
    jq -n --arg executable "$COMET_PYTHON" --arg cache "$COMET_CACHE" \
      '{available:false,model:"Unbabel/wmt22-comet-da",executable:$executable,
        cache:$cache,reason:"local executable or offline checkpoint missing"}' \
      >"$ARTIFACTS/comet-availability.json"
  fi
}

score_corpus() {
  local corpus="$1"
  local metrics="$ARTIFACTS/metrics/$corpus"
  local log="$metrics/comet.log" status=0 hypothesis
  local hypotheses=("$metrics/e22-standard.en.txt")
  if ! jq -e '.available == true' "$ARTIFACTS/comet-availability.json" >/dev/null; then
    cp "$ARTIFACTS/comet-availability.json" "$metrics/comet-unavailable.json"
    echo "COMET unavailable locally; chrF++ remains reported."
    return
  fi
  if [[ -s "$metrics/comet-score.json" && -s "$metrics/comet.log" \
      && -s "$metrics/comet-safety.json" && -s "$metrics/comet-safety.samples.jsonl" ]] \
      && jq -e '.stopReason == "completed" and .exitStatus == 0' \
        "$metrics/comet-safety.json" >/dev/null; then
    echo "Reusing complete local COMET score: $corpus"
    return
  fi
  for hypothesis in "$metrics/translategemma-12b-it-4bit.en.txt" \
    "$metrics/translategemma-4b-it-4bit.en.txt"; do
    [[ ! -f "$hypothesis" ]] || hypotheses+=("$hypothesis")
  done
  PHASE=scoring; CURRENT_TRANSLATOR=COMET; CURRENT_CORPUS="$corpus"
  if run_guarded "$metrics/comet-safety.json" "$log" 900 "$log" \
    "$COMET_PYTHON" Scripts/comet_score_compat.py -s "$metrics/source.ja.txt" \
      -t "${hypotheses[@]}" -r "$metrics/reference.en.txt" \
      --model Unbabel/wmt22-comet-da --gpus "${COMET_GPUS:-1}" --batch_size 8 \
      --num_workers 1 --disable_cache --quiet --to_json "$metrics/comet-score.json"; then
    status=0
  else status="$?"; fi
  cat "$log"
  ((status == 0)) || die "COMET scorer infrastructure/safety failure"
}

retain_evidence() {
  local translator corpus job destination path
  local translators=(translategemma-12b-it-4bit translategemma-4b-it-4bit)
  local controls=("$ARTIFACTS/decisions.json" "$ARTIFACTS/model-provenance.json"
    "$ARTIFACTS/corpus-preflight.tsv" "$ARTIFACTS/comet-availability.json"
    "$ARTIFACTS/live-tests.log" "$ARTIFACTS/full-swift-test.log"
    "$ARTIFACTS/test-status.json")
  if [[ "$MODE" == 4B_ONLY ]]; then
    translators=(translategemma-4b-it-4bit)
  elif [[ "$MODE" == TRANSLATION_ONLY_4B || "$MODE" == TRANSLATION_ONLY_12B ]]; then
    translators=("$REPLAY_TRANSLATOR")
    controls+=("$ARTIFACTS/translation-replay-source.json")
  else
    controls+=("$ARTIFACTS/12b-to-4b-handoff.json")
  fi
  [[ ! -e "$EVIDENCE" ]] || die "Retained E31 evidence already exists; preserve it"
  mkdir -p "$EVIDENCE"
  cp "${controls[@]}" "$EVIDENCE/"
  for translator in "${translators[@]}"; do
    for corpus in qudu2fx3ncc md62mmdz0m; do
      job="$(job_directory "$translator" "$corpus")"
      destination="$EVIDENCE/$translator-$corpus"
      mkdir -p "$destination"
      gzip -n -c "$job/raw-asr.json" >"$destination/raw-asr.json.gz"
      cp "$job/manifest.json" "$ARTIFACTS/$translator/$corpus/run-meta.json" \
        "$ARTIFACTS/$translator/$corpus/safety.json" \
        "$ARTIFACTS/$translator/$corpus/safety.samples.jsonl" "$destination/"
      [[ ! -f "$ARTIFACTS/$translator/$corpus/cleanup.json" ]] \
        || cp "$ARTIFACTS/$translator/$corpus/cleanup.json" "$destination/"
      gzip -n -c "$ARTIFACTS/$translator/$corpus/run.log" >"$destination/run.log.gz"
      for path in japanese-transcript.txt english-translation-transcript.txt \
        english-subtitles.srt english-subtitles.vtt; do
        [[ ! -f "$job/$path" ]] || cp "$job/$path" "$destination/$path"
      done
    done
  done
  [[ ! -d "$ARTIFACTS/metrics" ]] || cp -R "$ARTIFACTS/metrics" "$EVIDENCE/"
  find "$EVIDENCE" -type f ! -name sha256.tsv -print0 | sort -z | \
    xargs -0 shasum -a 256 >"$EVIDENCE/sha256.tsv"
}

preflight() {
  local tool command duration memory order smoke_request_hash=""
  PHASE=preflight; CURRENT_TRANSLATOR=""; CURRENT_CORPUS=""
  mkdir -p "$ARTIFACTS" "$ARTIFACTS/controls"
  if [[ "$MODE" == TRANSLATION_SMOKE_12B_100 && -f "$ARTIFACTS/failure.json" \
      && -f "$ARTIFACTS/translategemma-12b-it-4bit/qudu2fx3ncc/smoke.json" ]]; then
    cp "$ARTIFACTS/failure.json" \
      "$ARTIFACTS/translategemma-12b-it-4bit/qudu2fx3ncc/harness-failure.json"
  fi
  rm -f "$ARTIFACTS/benchmark-ready.json" "$ARTIFACTS/failure.json"
  for tool in jq ffmpeg shasum xcrun python3 pgrep footprint memory_pressure vm_stat; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
  done
  [[ "$MODE" != TRANSLATION_ONLY_12B ]] || verify_safe_12b_translation_smoke
  prepare_local_references qudu2fx3ncc
  prepare_local_references md62mmdz0m
  : >"$ARTIFACTS/corpus-preflight.tsv"
  verify_corpus qudu2fx3ncc >>"$ARTIFACTS/corpus-preflight.tsv"
  verify_corpus md62mmdz0m >>"$ARTIFACTS/corpus-preflight.tsv"
  verify_decisions
  verify_models
  if [[ "$MODE" == 4B_ONLY || "$MODE" == TRANSLATION_ONLY_4B ]]; then
    jq -e 'all(.weights[]; .modelID != "mlx-community/translategemma-12b-it-4bit")' \
      "$ARTIFACTS/model-provenance.json" >/dev/null
  fi
  if [[ "$MODE" == 4B_ONLY ]]; then
    [[ "$(declare -f four_b_only_run)" != *'run_job translategemma-12b-it-4bit'* ]] \
      || die "4B_ONLY execution graph contains a 12B job"
  elif [[ "$MODE" == TRANSLATION_ONLY_4B || "$MODE" == TRANSLATION_ONLY_12B \
      || "$MODE" == TRANSLATION_SMOKE_12B_100 ]]; then
    [[ "$MODE" != TRANSLATION_ONLY_12B ]] || verify_safe_4b_translation_replay
    prepare_translation_replay
    jq -e --arg model "$(model_id "$REPLAY_TRANSLATOR")" \
      'all(.weights[]; .modelID == $model)' "$ARTIFACTS/model-provenance.json" >/dev/null
  fi
  mkdir -p "$ARTIFACTS/controls/WhisperASR-TranslateGemma-synthetic"
  touch "$ARTIFACTS/controls/translation-ready-marker"
  printf '{"ready":true}\n' \
    >"$ARTIFACTS/controls/WhisperASR-TranslateGemma-synthetic/ready.json"
  translation_worker_ready_since "$ARTIFACTS/controls/translation-ready-marker" \
    "$ARTIFACTS/controls" || die "TranslateGemma ready marker detection failed"
  record_comet_availability
  bash -n Scripts/run_integrated_offline_validation.sh
  python3 Scripts/report_integrated_offline_validation.py --self-test
  bash Scripts/test_mossformer2_guard.sh
  local corpus
  if [[ "$MODE" == TRANSLATION_SMOKE_12B_100 ]]; then
    [[ "$(sha256 "$SMOKE_12B_REQUEST")" == "$SMOKE_12B_REQUEST_SHA256" ]] \
      || die "Frozen 12B smoke request hash mismatch"
    smoke_request_hash="$SMOKE_12B_REQUEST_SHA256"
    WHISPERASR_RUN_DIRECT_TRANSLATION_EXPERIMENT=1 \
    WHISPERASR_VALIDATE_DIRECT_TRANSLATION_ONLY=1 \
    WHISPERASR_DIRECT_TRANSLATION_CUE_LIMIT=100 \
    WHISPERASR_DIRECT_TRANSLATION_EVIDENCE="$ARTIFACTS/frozen/qudu2fx3ncc-raw-asr.json" \
    WHISPERASR_DIRECT_TRANSLATION_REQUEST="$SMOKE_12B_REQUEST" \
    WHISPERASR_DIRECT_TRANSLATION_OUTPUT="$ARTIFACTS/controls/smoke-validation.json" \
      xcrun swift test --filter \
        HighQualityLocalTranslationTests/testOfficialDirectProtocolOnFrozenSemanticUnitsWhenOptedIn \
        2>&1 | tee "$ARTIFACTS/controls/smoke-validation.log"
  else
    for corpus in qudu2fx3ncc md62mmdz0m; do
      WHISPERASR_RUN_SEMANTIC_TRANSLATION_EXPERIMENT=1 \
      WHISPERASR_VALIDATE_SEMANTIC_REPLAY_ONLY=1 \
      WHISPERASR_SEMANTIC_TRANSLATION_EVIDENCE="$ARTIFACTS/frozen/$corpus-raw-asr.json" \
      WHISPERASR_SEMANTIC_TRANSLATION_OUTPUT="$ARTIFACTS/controls/replay-validation-$corpus" \
      WHISPERASR_TRANSLATOR_CANDIDATE="$REPLAY_TRANSLATOR" \
      WHISPERASR_TRANSLATOR_CORPUS="$corpus" \
      WHISPERASR_TRANSLATOR_JOB_ID="$(job_id "$REPLAY_TRANSLATOR" "$corpus")" \
      WHISPERASR_TRANSLATOR_ALLOW_HOLDOUT="$([[ "$corpus" == md62mmdz0m ]] && echo 1 || echo 0)" \
        xcrun swift test --filter \
          HighQualityAcceptanceTests/testFrozenSemanticTranslationExperimentWhenOptedIn \
          2>&1 | tee "$ARTIFACTS/controls/replay-validation-$corpus.log"
    done
  fi
  xcrun swift build 2>&1 | tee "$ARTIFACTS/controls/build.log"
  bash Scripts/build_mlx_metallib.sh debug
  xcrun swift test --filter \
    'HighQualityLocalTranslationTests/testTranslateGemmaModelsArePinnedAndUseTheSameTranslationContract|HighQualityLocalTranslationTests/testEveryTranslationRequestClearsCacheBeforeTheNextRequest|HighQualityLocalTranslationTests/testCueBoundaryClearsCacheAfterSuccessRetryFailureCancellationAndUnload|HighQualityTranslationWorkerTests|HeavyweightModelGateTests|HighQualityJobTests/testSpeakerBetaControlsVisibilityAndSafeDefaults|HighQualityJobTests/testEnglishSubtitlesUseTheSameJobSeamForEveryOfflineBackend|HighQualityJobTests/testClassifiesSourcePreparationASRAndExportFailuresAtThePrincipalInterface|HighQualityJobTests/testCancellationIsSafeForEveryOfflineBackend' \
    2>&1 | tee "$ARTIFACTS/controls/light-tests.log"
  if [[ "$MODE" == TRANSLATION_SMOKE_12B_100 ]]; then
    command='BENCHMARK_SLOT_GRANTED=106 bash Scripts/run_integrated_offline_validation.sh TRANSLATION_SMOKE_12B_100'
    duration='5-8 minutes'; memory='8-12 GiB process tree'
    order='["fresh 12B video1 first 100 cues","unload+native recovery","hash raw artifacts"]'
  elif [[ "$MODE" == TRANSLATION_ONLY_4B ]]; then
    command='BENCHMARK_SLOT_GRANTED=106 bash Scripts/run_integrated_offline_validation.sh TRANSLATION_ONLY_4B'
    duration='12-18 minutes'; memory='5-6 GiB process tree'
    order='["fresh 4B replay/video1","unload+native recovery","fresh 4B replay/video2","unload+native recovery","COMET-if-local"]'
  elif [[ "$MODE" == TRANSLATION_ONLY_12B ]]; then
    command='BENCHMARK_SLOT_GRANTED=106 bash Scripts/run_integrated_offline_validation.sh TRANSLATION_ONLY_12B'
    duration='30-45 minutes'; memory='10-14 GiB process tree'
    order='["fresh 12B replay/video1","unload+native recovery","fresh 12B replay/video2","unload+native recovery","COMET-if-local"]'
  elif [[ "$MODE" == 4B_ONLY ]]; then
    command='BENCHMARK_SLOT_GRANTED=106 bash Scripts/run_integrated_offline_validation.sh 4B_ONLY'
    duration='30-50 minutes'; memory='10-13 GiB'
    order='["4B/video1","4B/video2","COMET-if-local"]'
  else
    command='BENCHMARK_SLOT_GRANTED=106 bash Scripts/run_integrated_offline_validation.sh full'
    duration='60-90 minutes'; memory='18-20 GiB'
    order='["12B/video1","12B/video2","unload+native-pressure-handoff","4B/video1","4B/video2","COMET-if-local"]'
  fi
  jq -n --arg commit "$(git rev-parse HEAD)" --arg mode "$MODE" \
    --arg command "$command" --arg duration "$duration" --arg memory "$memory" \
    --argjson order "$order" \
    --arg models "$(sha256 "$ARTIFACTS/model-provenance.json")" \
    --arg inputs "$(sha256 "$ARTIFACTS/corpus-preflight.tsv")" \
    --arg smokeRequest "$smoke_request_hash" \
    --arg worker "$(sha256 "$WHISPERASR_HIGH_QUALITY_WORKER_EXECUTABLE")" \
    --arg metallib "$(sha256 "$ROOT/.build/debug/mlx.metallib")" \
    --argjson implementation "$(implementation_hashes)" \
    '{ticket:106,status:"READY_FOR_HEAVY_BENCHMARK",commit:$commit,runMode:$mode,
      smokeCueLimit:(if $mode == "TRANSLATION_SMOKE_12B_100" then 100 else null end),command:$command,
      estimatedDuration:$duration,estimatedPeakMemory:$memory,executionOrder:$order,
      memoryPolicy:"warning requests cache cleanup then one native re-sample; recovered warning continues; critical, persistent warning, post-cleanup growth, swap or runaway stops; offline reserve=0",
      heavyModelsLoaded:false,modelProvenanceSHA256:$models,inputPreflightSHA256:$inputs,
      smokeRequestSHA256:(if $smokeRequest == "" then null else $smokeRequest end),
      implementationSHA256:$implementation,
      runtimeSHA256:{workerExecutable:$worker,mlxMetallib:$metallib}}' \
      >"$ARTIFACTS/benchmark-ready.json"
  echo "READY_FOR_HEAVY_BENCHMARK #106${MODE:+ $MODE}"
}

full_run() {
  [[ "${BENCHMARK_SLOT_GRANTED:-}" == 106 ]] \
    || die "Refusing heavyweight #106 run without BENCHMARK_SLOT_GRANTED=106"
  preflight
  run_job translategemma-12b-it-4bit qudu2fx3ncc
  run_job translategemma-12b-it-4bit md62mmdz0m
  record_handoff
  run_job translategemma-4b-it-4bit qudu2fx3ncc
  run_job translategemma-4b-it-4bit md62mmdz0m
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" --prepare-scoring
  score_corpus qudu2fx3ncc
  score_corpus md62mmdz0m
  rm -f "$ARTIFACTS/test-status.json"
  xcrun swift test --filter LiveCaptionTests 2>&1 | tee "$ARTIFACTS/live-tests.log"
  xcrun swift test 2>&1 | tee "$ARTIFACTS/full-swift-test.log"
  jq -n --arg live "$(sha256 "$ARTIFACTS/live-tests.log")" \
    --arg full "$(sha256 "$ARTIFACTS/full-swift-test.log")" \
    '{livePassed:true,fullSwiftPassed:true,sha256:{"live-tests.log":$live,
      "full-swift-test.log":$full}}' >"$ARTIFACTS/test-status.json"
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
  retain_evidence
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" \
    --json "$REPORT_JSON" --markdown "$REPORT_MD"
  jq -e '.workflowAuditable == true' "$REPORT_JSON" >/dev/null
  echo "Report: $REPORT_MD"
}

four_b_only_run() {
  if [[ "${BENCHMARK_SLOT_GRANTED:-}" != 106 ]]; then
    preflight
    return
  fi
  preflight
  run_job translategemma-4b-it-4bit qudu2fx3ncc
  run_job translategemma-4b-it-4bit md62mmdz0m
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" --prepare-scoring \
    --candidate translategemma-4b-it-4bit
  score_corpus qudu2fx3ncc
  score_corpus md62mmdz0m
  rm -f "$ARTIFACTS/test-status.json"
  xcrun swift test --filter LiveCaptionTests 2>&1 | tee "$ARTIFACTS/live-tests.log"
  xcrun swift test 2>&1 | tee "$ARTIFACTS/full-swift-test.log"
  jq -n --arg live "$(sha256 "$ARTIFACTS/live-tests.log")" \
    --arg full "$(sha256 "$ARTIFACTS/full-swift-test.log")" \
    '{livePassed:true,fullSwiftPassed:true,sha256:{"live-tests.log":$live,
      "full-swift-test.log":$full}}' >"$ARTIFACTS/test-status.json"
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" \
    --candidate translategemma-4b-it-4bit --json "$REPORT_JSON" --markdown "$REPORT_MD"
  retain_evidence
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" \
    --candidate translategemma-4b-it-4bit --json "$REPORT_JSON" --markdown "$REPORT_MD"
  jq -e '.workflowAuditable == true and .ticket106Concluded == false
    and .campaignClassification == "INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE"' \
    "$REPORT_JSON" >/dev/null
  echo "Report: $REPORT_MD"
}

translation_only_run() {
  if [[ "${BENCHMARK_SLOT_GRANTED:-}" != 106 ]]; then
    preflight
    return
  fi
  preflight
  run_translation_replay qudu2fx3ncc
  run_translation_replay md62mmdz0m
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" --prepare-scoring \
    --candidate "$REPLAY_TRANSLATOR"
  score_corpus qudu2fx3ncc
  score_corpus md62mmdz0m
  rm -f "$ARTIFACTS/test-status.json"
  xcrun swift test --filter LiveCaptionTests 2>&1 | tee "$ARTIFACTS/live-tests.log"
  xcrun swift test 2>&1 | tee "$ARTIFACTS/full-swift-test.log"
  jq -n --arg live "$(sha256 "$ARTIFACTS/live-tests.log")" \
    --arg full "$(sha256 "$ARTIFACTS/full-swift-test.log")" \
    '{livePassed:true,fullSwiftPassed:true,sha256:{"live-tests.log":$live,
      "full-swift-test.log":$full}}' >"$ARTIFACTS/test-status.json"
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" \
    --candidate "$REPLAY_TRANSLATOR" --json "$REPORT_JSON" --markdown "$REPORT_MD"
  retain_evidence
  python3 Scripts/report_integrated_offline_validation.py "$ARTIFACTS" \
    --candidate "$REPLAY_TRANSLATOR" --json "$REPORT_JSON" --markdown "$REPORT_MD"
  jq -e --arg mode "$MODE" '.workflowAuditable == true and .ticket106Concluded == false
    and .runMode == $mode
    and .campaignClassification == "INCONCLUSIVE_RUNTIME_MEMORY_PRESSURE"' \
    "$REPORT_JSON" >/dev/null
  echo "Report: $REPORT_MD"
}

translation_smoke_run() {
  if [[ "${BENCHMARK_SLOT_GRANTED:-}" != 106 ]]; then
    preflight
    return
  fi
  preflight
  run_translation_smoke
}

main() {
  case "$MODE" in preflight|full|4B_ONLY|TRANSLATION_ONLY_4B|TRANSLATION_ONLY_12B|TRANSLATION_SMOKE_12B_100) ;;
    *) echo "usage: $0 [preflight|full|4B_ONLY|TRANSLATION_ONLY_4B|TRANSLATION_ONLY_12B|TRANSLATION_SMOKE_12B_100]" >&2; exit 2 ;;
  esac
  cd "$ROOT"
  trap on_error ERR
  trap cleanup_active_process EXIT
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM
  case "$MODE" in
    preflight) preflight ;;
    full) full_run ;;
    4B_ONLY) four_b_only_run ;;
    TRANSLATION_ONLY_4B|TRANSLATION_ONLY_12B) translation_only_run ;;
    TRANSLATION_SMOKE_12B_100) translation_smoke_run ;;
  esac
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] || main
