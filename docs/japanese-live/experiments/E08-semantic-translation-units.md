# E08 — Semantic Japanese translation units

Ticket #49 changes one variable: TranslateGemma receives Japanese units built from final ASR and forced-alignment evidence instead of Speaker-derived fragments. The frozen policy uses terminal Japanese punctuation, pauses of at least 0.75 s, a 48-character maximum, and merges non-terminal fragments of at most 6 characters into the following unit. An explicit interjection allowlist prevents blind merging. SpeakerKit labels are attached only after translation.

ASR, alignment, diarization evidence, TranslateGemma model/revision/runtime, prompt protocol, glossary catalog/budget, generation settings, references, and scorers are unchanged from E06/E07. Context and glossary selection use the stable ASR turns, so changing diarization cannot change a translation request.

## Development — `qudu2fx3ncc`

| Candidate | Units | COMET | chrF++ | Runtime | Marker misses | Untranslated | Hallucination flags |
|---|---:|---:|---:|---:|---:|---:|---:|
| Speaker-derived | 396 | 0.4661 | 45.44 | 4,986 s | 61 | 1 | 11 |
| Semantic | 313 | 0.4819 | 45.67 | 4,979 s | 30 | 0 | 17 |

The selected development policy produced 18 short-fragment merges and preserved 3 standalone interjections. COMET improved by 0.0158 and chrF++ by 0.23 before the holdout run. The conservative hallucination diagnostic increased from 11 to 17 and remains recorded as a non-gating diagnostic.

Raw semantic artifact: `.build/benchmarks/semantic-translation/development-reviewed/2A743BB5-FC2A-4EC8-B9D1-474127ECD5D2/raw-asr.json`.

## Untouched holdout — `md62mmdz0m`

| Candidate | Units | COMET | chrF++ | Runtime | Marker misses | Untranslated | Hallucination flags |
|---|---:|---:|---:|---:|---:|---:|---:|
| Speaker-derived | 557 | 0.5013 | 29.18 | 2,993 s | 556 | 1 | 104 |
| Semantic | 273 | 0.5206 | 33.95 | 1,361 s | 273 | 0 | 107 |

The frozen candidate gains 0.0193 COMET and 4.77 chrF++ on holdout while cutting translation runtime by 55%. Structured response IDs pass for both candidates. The semantic artifact maps all 3,950 source fragments exactly once, preserves the complete Japanese string, and records 46 short-fragment merges plus 12 standalone interjections. Native marker misses and hallucination flags remain retained diagnostics; neither changes the validated one-to-one response mapping.

Raw semantic artifact: `.build/benchmarks/semantic-translation/holdout-reviewed/8FD31A4B-F61D-4A6E-99C9-6A127AA2EDF2/raw-asr.json`.

The holdout promotion gates pass: both translation metrics improve, no Japanese content is missing or duplicated, deterministic tests cover punctuation, pauses, size, short fragments, interjections, diarization changes, overlaps, timestamps, transcripts, WebVTT and SRT, and the unchanged Live regression suite passes. The semantic-unit path is promoted.
