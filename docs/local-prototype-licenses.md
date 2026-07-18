# Local model dependency audit

Audit date: 2026-07-18. WhisperASR does not bundle or redistribute these
prototype weights. Product models are downloaded after user selection;
benchmark-only models remain under ignored build storage.

| Component | Pinned revision / artifact | Declared license | Integrity control |
|---|---|---|---|
| `soniqo/speech-swift` | source snapshot `9c4bff5a8f0287a179b9a039da25ff9fa02553a3` | Apache-2.0 | Only Qwen, FireRedVAD and their shared support modules are vendored; provenance is recorded in `Vendor/SpeechSwiftPrototype/PROVENANCE.md` and transitives remain frozen in `Package.resolved` |
| Qwen3-ASR 1.7B MLX 8-bit | `e5450a26d1fd417c45fc9c405651ddc3180a27a6` | Apache-2.0 | Runtime refuses a changed Hugging Face revision |
| Qwen3-ASR JA↔EN speech translation (`voiceping-ai`) | `1251c2a9066981cc303df075b18bd3bbde1d25d6` | Apache-2.0 | Benchmark-only test target; the snapshot is pinned and is not embedded in the app after failing the quality gate |
| FireRedVAD Core ML | `1cb0565191fbdc630c2fe8f111ba31c392d05706` | MIT | Runtime refuses a changed Hugging Face revision |
| Whisper Large v3 Turbo GGML | `5359861c739e955e79d9a303bcbc70fb988958b1`, SHA-256 `1fc70f…e2bc69` | MIT | Catalog URL uses the exact revision and verifies the complete model file |
| `mlx-audio` | `v0.4.5`, commit `04151c6abb74b886f879a4457ccdc96761f10102` | MIT | Managed environment is reproduced from the bundled `uv.lock`; the lock and the local UTF-8 patch are SHA-256 checked |
| Voxtral Realtime MLX Q4 (`iris-sfg`) | `12091661ce5f58788624fa49fad9ddbbf67cf063` | Apache-2.0 (declared by model card and upstream Mistral model) | Download is pinned to the exact Hugging Face revision |
| `uv` arm64 0.11.28 | release archive | MIT or Apache-2.0 | Archive is checked against SHA-256 `33540eb7…447232` before execution |
| `mlx-audio-swift` | 0.1.3, commit `d302a5c6080d2bb97bae38c7418f82abb76013b6` | MIT | Exact SwiftPM version |
| `swift-huggingface` | 0.9.0, commit `b721959445b617d0bf03910b2b4aced345fd93bf` | Apache-2.0 | Exact SwiftPM version |
| FluidAudio | 0.15.5, commit `19600a485baa4998812e4654b70d2bab8f2c9949` | Apache-2.0 | Exact SwiftPM version |
| Nemotron 3.5 ASR Streaming Multilingual Core ML | `1a41b75758b0337ff67db7d5408280aaaf23074e`; 1120 ms `a398b4…efae9`, 560 ms `ad9a4c…c340d` | OpenMDW-1.1 | Benchmark-only; fixed tree SHA rejects changed `main` downloads |
| LS-EEND Core ML | `125ed60504885cf1dbadacff8a0cececee04ef17` | MIT declared for the conversion; training datasets retain separate terms | Every downloaded model file is SHA-256 checked, including cached reuse |
| Cohere Transcribe MLX Q8 (`beshkenadze`) | `d1f843476f84846e6fe7aa58a6033f17882f0ec9` | Apache-2.0 declared, but community conversion provenance is incomplete | Prototype/local use only until conversion from the gated official upstream is reproduced or clarified |

The dependency lock currently pins, among others, MLX Swift 0.31.6 at
`0bb916c67f4b9e5c682cbe02a42c701c93ab5021` and Swift Transformers 1.3.3 at
`2fa33e1f5e7131a7fc64c28e6d161dcec0d24820`.

## Redistribution gates

- Local personal testing of all selected components is acceptable under their
  declared terms. This is not legal advice.
- Do not bundle or mirror the LS-EEND DIHARD3 weights until the DIHARD/LDC
  dataset-derived redistribution rights are clarified. Runtime download in
  opt-in shadow mode remains separate from the app bundle.
- Do not distribute the Cohere Q6 conversion (`license: other`). Do not bundle
  the Q8 community conversion until its provenance is clarified or the
  conversion is reproduced from `CohereLabs/cohere-transcribe-03-2026`.
- A direct Developer ID distribution must include MIT/Apache notices and all
  required attributions. Redistributing Nemotron also requires retaining the
  NVIDIA attribution and OpenMDW-1.1 notice. If Python or its locked packages are ever embedded,
  audit every package and include the Python Software Foundation license.
- The current helper downloads executable runtime code after installation, so
  it is not suitable for a Mac App Store build without a different packaging
  design. Developer ID notarization and Hardened Runtime must be validated for
  public distribution.
