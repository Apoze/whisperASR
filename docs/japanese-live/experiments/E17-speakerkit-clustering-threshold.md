# E17 — SpeakerKit clustering threshold

Only `clusterDistanceThreshold` changes across 0.45, 0.50, 0.55 and 0.60. SpeakerKit W8A16/W8A16, Auto speaker count, non-exclusive reconciliation, principal attribution, ASR, alignment, glossary and translation remain frozen.

| Corpus | Threshold | DER | JER | Speaker JA error | Count error | Dup. | Overlap P/R/F1 | Runtime | Peak memory |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qudu2fx3ncc (development) | 0.45 | 100.45% | 79.17% | 89.42% | 5 | 0 | 11.4/18.3/14.1% | 16.95s | 641 MiB |
| qudu2fx3ncc (development) | 0.50 | 100.39% | 79.10% | 89.11% | 5 | 0 | 11.4/18.6/14.2% | 15.43s | 722 MiB |
| qudu2fx3ncc (development) | 0.55 | 98.92% | 76.21% | 87.59% | 4 | 0 | 13.8/22.7/17.2% | 14.07s | 728 MiB |
| qudu2fx3ncc (development) | 0.60 | 108.46% | 84.75% | 91.76% | 6 | 0 | 12.6/21.7/15.9% | 12.79s | 722 MiB |
| md62mmdz0m (holdout default) | 0.60 | 58.91% | 52.28% | 59.82% | 0 | 0 | 0.7/11.7/1.3% | 8.31s | 701 MiB |
| md62mmdz0m (holdout selected) | 0.55 | 58.71% | 52.45% | 59.37% | 0 | 0 | 0.7/11.7/1.4% | 11.51s | 690 MiB |

**Decision:** do not promote; untouched holdout did not confirm every gate.

Selection is lexicographic on speaker-attributed Japanese error, JER, DER, speaker-count error and threshold, after strict gain and every veto gate. Reference pseudo-speakers, uncertainty, exact scorer inputs, raw spans, mappings, settings, manifests and logs are retained under `docs/japanese-live/experiments/evidence/E17/`.
