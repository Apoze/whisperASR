#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIDEO="${1:-/Users/maz/Downloads/Easy Japanese 1 - Typical Japanese.mp4}"
ARCHIVE="${2:-/Users/maz/Downloads/transcription_japonaise_avec_locuteurs.zip}"
ENGLISH_ARCHIVE="${3:-/Users/maz/Downloads/english_transcript_with_speakers.zip}"
PARENT="$ROOT/.build/benchmarks/corpora"
TARGET="$PARENT/easy-japanese-1"
MANIFEST="$ROOT/docs/japanese-live/corpora/easy-japanese-1/manifest.json"
EXPECTED_VIDEO_SHA256="6b6fee800edaf8fe5ffea029f673b37e04b648cd24aaa779c1c53dc9446b2667"
EXPECTED_ARCHIVE_SHA256="1da9a9d3d2d41455eef067cee3a57d8c0ea7aca9c0a33291347e492a1ae238c1"
EXPECTED_ENGLISH_ARCHIVE_SHA256="721be7072dd9eca908a17099c077115e37b73851d8dcedce3c102ba23dbdc12f"
EXPECTED_ENGLISH_TURNS_SHA256="3efda22bbd72c109d1ba57b646bea68d76141060a5607ccaafcd397f3d0eeecb"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing input: $1" >&2
    exit 1
  fi
}

verify_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA-256 mismatch for $path" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

install_english_reference() {
  local target="$TARGET/english-turns.csv"
  if [[ -f "$target" ]] \
      && [[ "$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')" \
          == "$EXPECTED_ENGLISH_TURNS_SHA256" ]]; then
    return
  fi
  if [[ ! -f "$ENGLISH_ARCHIVE" ]]; then
    echo "Optional English reference not found: $ENGLISH_ARCHIVE"
    return
  fi
  verify_sha256 "$ENGLISH_ARCHIVE" "$EXPECTED_ENGLISH_ARCHIVE_SHA256"
  local work
  work="$(/usr/bin/mktemp -d "$PARENT/.easy-japanese-english.XXXXXX")"
  (
    trap '/bin/rm -rf "$work"' EXIT
    /usr/bin/ditto -x -k "$ENGLISH_ARCHIVE" "$work"
    verify_sha256 "$work/english_transcript_speaker_turns.csv" \
      "$EXPECTED_ENGLISH_TURNS_SHA256"
    /bin/cp "$work/english_transcript_speaker_turns.csv" "$target"
  )
}

/bin/mkdir -p "$PARENT"
if [[ "${WHISPERASR_REBUILD_JAPANESE_CORPUS:-0}" != "1" \
      && -f "$TARGET/audio-16k-mono.wav" \
      && -f "$MANIFEST" ]]; then
  stored_wav_sha="$(/usr/bin/jq -r '.fixture.sha256' "$MANIFEST")"
  actual_wav_sha="$(/usr/bin/shasum -a 256 "$TARGET/audio-16k-mono.wav" | /usr/bin/awk '{print $1}')"
  if [[ "$stored_wav_sha" == "$actual_wav_sha" ]]; then
    install_english_reference
    echo "Using existing canonical corpus: $TARGET"
    exit 0
  fi
fi

require_file "$VIDEO"
require_file "$ARCHIVE"
verify_sha256 "$VIDEO" "$EXPECTED_VIDEO_SHA256"
verify_sha256 "$ARCHIVE" "$EXPECTED_ARCHIVE_SHA256"

WORK="$(/usr/bin/mktemp -d "$PARENT/.easy-japanese-1.XXXXXX")"
EXTRACTED="$WORK/extracted"
ENGLISH_EXTRACTED="$WORK/english"
STAGING="$WORK/corpus"
BACKUP="$PARENT/.easy-japanese-1.backup.$$"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ ! -e "$TARGET" && -e "$BACKUP" ]]; then
    /bin/mv "$BACKUP" "$TARGET"
  fi
  /bin/rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$EXTRACTED" "$ENGLISH_EXTRACTED" "$STAGING"
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACTED"

/bin/cp "$EXTRACTED/transcription_japonaise_tours_de_parole.csv" "$STAGING/turns.csv"
/bin/cp "$EXTRACTED/transcription_japonaise_detaillee.csv" "$STAGING/detailed.csv"
/bin/cp "$EXTRACTED/transcription_japonaise_locuteurs.srt" "$STAGING/speakers.srt"
if [[ -f "$ENGLISH_ARCHIVE" ]]; then
  verify_sha256 "$ENGLISH_ARCHIVE" "$EXPECTED_ENGLISH_ARCHIVE_SHA256"
  /usr/bin/ditto -x -k "$ENGLISH_ARCHIVE" "$ENGLISH_EXTRACTED"
  /bin/cp "$ENGLISH_EXTRACTED/english_transcript_speaker_turns.csv" \
    "$STAGING/english-turns.csv"
  verify_sha256 "$STAGING/english-turns.csv" "$EXPECTED_ENGLISH_TURNS_SHA256"
fi

cd "$ROOT"
WHISPERASR_PREPARE_JAPANESE_CORPUS=1 \
WHISPERASR_JAPANESE_CORPUS_VIDEO="$VIDEO" \
WHISPERASR_JAPANESE_CORPUS_TRANSCRIPT_ARCHIVE="$ARCHIVE" \
WHISPERASR_JAPANESE_CORPUS_OUTPUT="$STAGING" \
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift test \
    --filter JapaneseModelBakeoffTests/testPrepareEasyJapaneseCorpusWhenOptedIn

for file in audio-16k-mono.wav turns.csv detailed.csv speakers.srt; do
  require_file "$STAGING/$file"
done

if [[ -e "$TARGET" ]]; then
  /bin/mv "$TARGET" "$BACKUP"
fi
if ! /bin/mv "$STAGING" "$TARGET"; then
  if [[ -e "$BACKUP" ]]; then
    /bin/mv "$BACKUP" "$TARGET"
  fi
  exit 1
fi
/bin/rm -rf "$BACKUP"

echo "Prepared corpus: $TARGET"
