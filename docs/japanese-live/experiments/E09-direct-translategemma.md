# E09 — Official direct TranslateGemma interaction

Ticket #50 changes only the prompt protocol. Semantic units, model revision, glossary state, generation settings, references, and scorers are frozen from E08.

TranslateGemma stays pinned to revision `f3dcfd54df14672fbcf0731086fb47a797a943ae` with 256 output tokens, temperature 0, and thinking disabled.

## Development

| Protocol | Units | COMET | chrF++ | Marker misses | Marker/context contamination | Untranslated | Runtime |
|---|---:|---:|---:|---:|---:|---:|---:|
| existing-protocol | 313 | 0.4819 | 45.67 | 30 | 7 | 0 | 4979.5 s |
| direct-protocol | 313 | 0.4832 | 45.29 | n/a | 0 | 0 | 460.3 s |

Raw direct artifact: `.build/benchmarks/direct-translation/development/direct-protocol.json` (native prompts, tokens, outputs, timings, and model identity per unit).

## Holdout

| Protocol | Units | COMET | chrF++ | Marker misses | Marker/context contamination | Untranslated | Runtime |
|---|---:|---:|---:|---:|---:|---:|---:|
| existing-protocol | 273 | 0.5206 | 33.95 | 273 | 7 | 0 | 1360.6 s |
| direct-protocol | 273 | 0.5856 | 50.19 | n/a | 0 | 0 | 388.4 s |

Raw direct artifact: `.build/benchmarks/direct-translation/holdout/direct-protocol.json` (native prompts, tokens, outputs, timings, and model identity per unit).

The untouched holdout promotion gates pass; Live behavior remains covered by the unchanged full test suite.
