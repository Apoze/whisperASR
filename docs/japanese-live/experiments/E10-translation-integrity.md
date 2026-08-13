# E10 — Deterministic translation-integrity verdicts

Ticket #51 adds an evidence-only shadow validator. It never changes or rejects a published Deliverable.

## Frozen development thresholds

Version `translation-integrity-dev-v1` was calibrated on the 313 E09 development units and frozen before processing holdout.

| Minimum length ratio | Maximum length ratio | Copied-output similarity | Corresponding-source ceiling |
|---:|---:|---:|---:|
| 0.50 | 6.00 | 0.80 | 0.20 |

## Injected corruptions

| True detections | False positives | False negatives | All reason codes covered |
|---:|---:|---:|:---:|
| 12 | 0 | 0 | yes |

Valid fixtures cover short, long, named-entity, and mixed-punctuation translations. Japanese residue fixtures cover hiragana, katakana, half-width kana, and CJK; the explicit allowlist is empty unless supplied by the caller.

## Real-video shadow counts

| Corpus | Units | Pass | Suspect | Hard failure | Glossary opportunities |
|---|---:|---:|---:|---:|---:|
| development | 313 | 310 | 1 | 2 | 3 |
| holdout | 273 | 273 | 0 | 0 | 0 |

| Reason | Development | Holdout |
|---|---:|---:|
| `control-scaffolding` | 1 | 0 |
| `copied-neighbour` | 0 | 0 |
| `critical-glossary-violation` | 1 | 0 |
| `degenerate-repetition` | 0 | 0 |
| `empty-output` | 0 | 0 |
| `pathological-length` | 2 | 0 |
| `residual-japanese` | 0 | 0 |
| `truncated-output` | 0 | 0 |

## Raw artifacts

- `.build/benchmarks/translation-integrity/fixtures.json`
- `.build/benchmarks/translation-integrity/development.json`
- `.build/benchmarks/direct-translation/development/direct-protocol.json`
- `.build/benchmarks/translation-integrity/holdout.json`
- `.build/benchmarks/direct-translation/holdout/direct-protocol.json`

No retry, semantic rewrite, truncation, or product rejection behavior is introduced.
