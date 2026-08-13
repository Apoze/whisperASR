# E07 — Principal Speaker attribution

Ticket #48 changes one variable: each aligned unit keeps only the SpeakerKit span with the longest temporal overlap; ties use the stable anonymous label then the sorted span index. ASR, forced alignment, raw SpeakerKit spans/model/revision/settings and overlap evidence are frozen from E06; the same deterministic translation stub is used for both replays.

## Development — `qudu2fx3ncc`

| Candidate | Duplicate aligned units | Speaker-attributed Japanese error | DER / JER | Runtime |
|---|---:|---:|---:|---:|
| E06 non-exclusive mappings | 379 | 98.43% | 105.47% / 85.92% | 5168 s real E06 context |
| Principal Speaker | 0 | 91.87% | 105.47% / 85.92% | 1.0 s frozen-seam replay |

Speaker-attributed Japanese error is pooled character edit distance after the existing optimal anonymous-label temporal permutation; unattributed aligned characters are reported separately and charged only through that edit distance. The candidate retains all 4,466 aligned units, including 2,803 units without a matching span. Raw spans and 289 overlap ranges are unchanged.

Raw candidate artifact: `.build/benchmarks/principal-speaker-attribution/development-pass2/24714AB0-F273-44A3-9828-67B54766070D/raw-asr.json`.

Development gates pass: duplication is zero, attributed error improves, recovered Japanese content is unchanged, and raw overlap evidence is retained. Holdout `md62mmdz0m` has not been replayed at this point.

## Untouched holdout — `md62mmdz0m`

| Candidate | Duplicate aligned units | Speaker-attributed Japanese error | DER / JER | Runtime |
|---|---:|---:|---:|---:|
| E06 non-exclusive mappings | 557 | 62.03% | 58.91% / 52.28% | 3116 s real E06 context |
| Principal Speaker | 0 | 59.82% | 58.91% / 52.28% | 0.45 s frozen-seam replay |

Raw candidate artifact: `.build/benchmarks/principal-speaker-attribution/holdout/88088247-41D7-4780-94F1-7EC7630DD312/raw-asr.json`.

The holdout confirms the development direction: duplication reaches zero and speaker-attributed Japanese error improves by 2.21 points while raw-span DER/JER and overlap evidence remain unchanged. Code review removed an equal double-charge of unattributed text from both baseline and candidate metrics without changing candidate settings. The repeated full suite passes (334 tests, 35 skipped, 0 failures), including unchanged translation and Live regressions; the candidate is promoted.
