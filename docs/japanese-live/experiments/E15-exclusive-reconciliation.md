# E15 — Exclusive SpeakerKit reconciliation

One variable changes: `useExclusiveReconciliation=false` becomes `true`. ASR, alignment, SpeakerKit revision, clustering settings and principal-Speaker mapping stay fixed.

`SPEAKER_13` in the development reference is declared as group reactions/overlap, not as one acoustic identity. Overlap scores still use all explicit overlap annotations.

| Corpus | Mode | DER | JER | Speaker JA error | Count error | Dup. | Overlap P/R/F1 | Overlap FA | Activity FA | Runtime | Peak memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qudu2fx3ncc (development) | non-exclusive | 108.46% | 84.75% | 91.76% | 6 | 0 | 12.6/21.7/15.9% | 141.22s | 166.47s | 12.87s | 687 MiB |
| qudu2fx3ncc (development) | exclusive | 89.89% | 82.91% | 99.19% | 6 | 0 | 0.0/0.0/0.0% | 0.00s | 166.47s | 12.51s | 713 MiB |

Untouched holdout: not run.

**Decision:** do not promote; development gates or principal-Speaker gain failed.

Raw evidence:

Lossless raw snapshots, pinned settings and runner logs are checked in under `docs/japanese-live/experiments/evidence/E15/`.

- `qudu2fx3ncc` baseline `.build/benchmarks/principal-speaker-attribution/development-pass2/24714AB0-F273-44A3-9828-67B54766070D/raw-asr.json`; candidate `.build/benchmarks/exclusive-reconciliation/qudu2fx3ncc/jobs/57000001-0000-4000-8000-000000000001/raw-asr.json`.
