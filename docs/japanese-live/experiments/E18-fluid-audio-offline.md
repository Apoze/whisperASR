# E18 — SpeakerKit versus FluidAudio Offline

Frozen Qwen JA ASR, alignment, translation, speaker-count policy, raw-overlap and complete deterministic principal-attribution rules; only the native diarization engine changes. Complete attribution is experiment-only and remains disabled in the product.

| Split | Engine | DER | JER | Speaker JA error | Count error | Dup. | Overlap P/R/F1 | Runtime | Peak memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| development | speakerkit | 108.46% | 84.75% | 150.70% | 6 | 0 | 12.6/21.7/15.9% | 12.90s | 710 MiB |
| development | fluid-audio-offline | 105.02% | 98.60% | 221.19% | 11 | 0 | 0.0/0.0/0.0% | 6.69s | 754 MiB |

Untouched holdout: not run.

**Decision:** keep SpeakerKit; FluidAudio did not pass development.

Raw evidence, exact scorer inputs, source snapshots, model inventories, remote revision checks, logs and failure diagnostics are retained under `docs/japanese-live/experiments/evidence/E18/`.
