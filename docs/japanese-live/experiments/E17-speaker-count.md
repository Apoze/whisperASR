# E17 — Known Speaker count versus Auto

Only `numberOfSpeakers` changes. Auto stays the product default; the explicit count is derived from the authoritative acoustic-Speaker annotations.

| Corpus | Mode | DER | JER | Speaker JA error | Unlabelled JA | Count error | Runtime | Peak memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| qudu2fx3ncc (development) | Auto | 108.46% | 84.75% | 91.76% | 2803 | 6 | 13.17s | 637 MiB |
| qudu2fx3ncc (development) | Expected 12 | 106.30% | 75.94% | 90.03% | 2825 | 0 | 13.20s | 711 MiB |
| md62mmdz0m (untouched-holdout) | Auto | 58.91% | 52.28% | 59.82% | 1005 | 0 | 8.17s | 678 MiB |
| md62mmdz0m (untouched-holdout) | Expected 3 | 58.91% | 52.28% | 59.82% | 1005 | 0 | 8.12s | 679 MiB |

Unlabelled JA is a separate attribution-coverage diagnostic. The spoken-content gate compares delivered Japanese after removing only `SPEAKER_NN:` prefixes.

**Decision:** do not ship explicit count; holdout did not confirm the gain.

The immutable #59 evidence is preserved under `docs/japanese-live/experiments/evidence/E17-speaker-count/`; paths embedded in those artifacts record their original run location.
