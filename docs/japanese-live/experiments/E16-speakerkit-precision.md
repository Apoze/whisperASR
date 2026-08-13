# E16 — SpeakerKit full-precision variants

Only SpeakerKit model precision changes: segmenter/embedder `W8A16/W8A16` becomes `W32A32/W16A16`. ASR, alignment, selected non-exclusive reconciliation, principal attribution, automatic speaker count, clustering defaults, full redundancy and translation stay fixed.

| Corpus | Precision | DER | JER | Speaker JA error | Count error | Overlap P/R/F1 | Runtime | Preparation | Peak memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| qudu2fx3ncc (development) | W8A16/W8A16 | 108.46% | 84.75% | 91.76% | 6 | 12.6/21.7/15.9% | 12.30s | 19.97s | 673 MiB |
| qudu2fx3ncc (development) | W32A32/W16A16 | 104.34% | 79.59% | 88.27% | 4 | 12.7/21.7/16.1% | 14.06s | 18.42s | 723 MiB |
| md62mmdz0m (untouched-holdout) | W8A16/W8A16 | 58.91% | 52.28% | 59.82% | 0 | 0.7/11.7/1.3% | 8.31s | 0.15s | 701 MiB |
| md62mmdz0m (untouched-holdout) | W32A32/W16A16 | 58.56% | 52.57% | 59.35% | 0 | 0.8/11.7/1.4% | 10.74s | 0.15s | 733 MiB |

**Decision:** do not promote; untouched holdout did not confirm every gate.

Raw runs, manifests, logs, model variants, revisions and hashes are retained under `docs/japanese-live/experiments/evidence/E16/`.
