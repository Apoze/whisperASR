# Local English prototype dependency audit

Audit date: 2026-07-13. WhisperASR does not bundle or redistribute these
prototype weights. The application downloads them from their publishers only
after the user selects the corresponding engine.

| Component | Pinned revision / artifact | Declared license | Integrity control |
|---|---|---|---|
| `soniqo/speech-swift` | source snapshot `9c4bff5a8f0287a179b9a039da25ff9fa02553a3` | Apache-2.0 | Only Qwen, FireRedVAD and their shared support modules are vendored; provenance is recorded in `Vendor/SpeechSwiftPrototype/PROVENANCE.md` and transitives remain frozen in `Package.resolved` |
| Qwen3-ASR 1.7B MLX 8-bit | `e5450a26d1fd417c45fc9c405651ddc3180a27a6` | Apache-2.0 | Runtime refuses a changed Hugging Face revision |
| FireRedVAD Core ML | `1cb0565191fbdc630c2fe8f111ba31c392d05706` | MIT | Runtime refuses a changed Hugging Face revision |

The dependency lock currently pins, among others, MLX Swift 0.31.6 at
`0bb916c67f4b9e5c682cbe02a42c701c93ab5021` and Swift Transformers 1.3.3 at
`2fa33e1f5e7131a7fc64c28e6d161dcec0d24820`.
