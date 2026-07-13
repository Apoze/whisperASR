# speech-swift prototype snapshot

This directory contains only the source files needed by WhisperASR's remaining
local comparison prototypes. The retained upstream files are copied without
modification from:

- repository: `https://github.com/soniqo/speech-swift`
- commit: `9c4bff5a8f0287a179b9a039da25ff9fa02553a3`
- license: Apache-2.0 (see `LICENSE`)

The reduced package manifest intentionally excludes unrelated TTS, server,
benchmark, WhisperKit and `SpeechCore.xcframework` targets. MLX Swift 0.31.6
and Swift Transformers 1.3.3 remain exact external dependencies.

The root `Scripts/build_mlx_metallib.sh` is derived from the same pinned
upstream build script; it only adapts output discovery to WhisperASR's app and
test bundle names.
