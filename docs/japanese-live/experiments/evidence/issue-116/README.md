# Issue #116 — backend ASR evidence

Durable summary of the three real, sequential Standard ASR worker smokes run under benchmark slot `116`. The frozen 30-second audio SHA-256 is `d1c3ec3a01b00953f61f9956d1ec035cded04c831aebe7e29055ceb7ac5cb272`.

The original manifests and raw-ASR files are archived here byte-for-byte. Their hashes, exact command template, model revisions, weight hashes, lifecycle results, and compact field evidence are indexed by [`report.json`](report.json). The review correction reused those captured artifacts and did not run a model again.

| Backend | Native evidence | Absent evidence |
| --- | --- | --- |
| Qwen | none | timing, confidence, average log probability |
| Parakeet | overall confidence, token timing and token confidence | segment/word timing, average log probability |
| WhisperKit | segment/word timing, word confidence, average log probability | overall confidence, token timing, no-speech probability |

The raw files are [`Qwen`](qwen-ja-raw-asr.json), [`Parakeet`](parakeet-ja-raw-asr.json), and [`WhisperKit`](whisperkit-raw-asr.json); each corresponding manifest is linked from `report.json`.

WhisperKit `1.1.0` hardcodes `noSpeechProb` to zero with an upstream TODO. The immutable historical capture contains that upstream placeholder, while the reporter classifies it as `absent` and current persistence omits it. `speechDetected` is intentionally outside #116.
