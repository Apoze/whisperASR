# Offline high-quality acceptance — ticket #44

Only HighQualityASRBackend changed; source, product seam, forced aligner, SpeakerKit, TranslateGemma, deliverables and implementation hashes were fixed.
Raw manifests, ASR/alignment/diarization/translation evidence, prompts, native outputs, hashes and diagnostics are retained under `.build/benchmarks/high-quality/offline-acceptance/`.

| Corpus | ASR | CER high | CER overall | COMET | chrF++ | Timing mean/median/p95 | DER / JER | Speakers ref/cand/error | Overlap P/R/F1 | Runtime | Peak |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qudu2fx3ncc | qwen-ja | 86.83% | 85.55% | 0.4661 | 45.44 | 513/290/1530 ms | 105.47% / 85.92% | 13/6/7 | 5.0/31.5/8.6% | 5168s | 8.36 GiB |
| md62mmdz0m | qwen-ja | 34.12% | 27.93% | 0.5013 | 29.18 | 390/243/1249 ms | 58.91% / 52.28% | 3/3/0 | 0.1/6.3/0.2% | 3116s | 8.30 GiB |
| qudu2fx3ncc | parakeet-ja | 80.08% | 63.53% | 0.4612 | 31.26 | 779/290/4952 ms | 105.47% / 85.92% | 13/6/7 | 5.0/31.5/8.6% | 1196s | 2.35 GiB |
| md62mmdz0m | parakeet-ja | 70.80% | 63.76% | 0.4598 | 35.39 | 496/277/1509 ms | 58.91% / 52.28% | 3/3/0 | 0.1/6.3/0.2% | 1660s | 2.35 GiB |
| qudu2fx3ncc | whisperkit | 75.65% | 64.90% | 0.4597 | 22.39 | 556/290/2510 ms | 105.47% / 85.92% | 13/6/7 | 5.0/31.5/8.6% | 2652s | 2.35 GiB |
| md62mmdz0m | whisperkit | 43.59% | 35.09% | 0.4839 | 31.32 | 467/248/1255 ms | 58.91% / 52.28% | 3/3/0 | 0.1/6.3/0.2% | 2705s | 2.35 GiB |

## English diagnostics

| Corpus | ASR | Glossary | Structured cue IDs | Native marker misses | Untranslated | Hallucination flags |
|---|---|---:|---:|---:|---:|---:|
| qudu2fx3ncc | qwen-ja | 0.0% (0/4) | PASS | 61 | 1 | 11 |
| md62mmdz0m | qwen-ja | n/a | PASS | 556 | 1 | 104 |
| qudu2fx3ncc | parakeet-ja | n/a | PASS | 188 | 0 | 67 |
| md62mmdz0m | parakeet-ja | n/a | PASS | 294 | 1 | 94 |
| qudu2fx3ncc | whisperkit | n/a | PASS | 231 | 0 | 78 |
| md62mmdz0m | whisperkit | n/a | PASS | 376 | 0 | 130 |

Native marker misses, untranslated cues and hallucination flags are retained diagnostics; the structured one-to-one cue-ID mapping is the veto gate.

All veto gates passed for all three selectable backends. Frozen `criticalTerms` opportunities: 0, therefore Japanese terminology accuracy is explicitly n/a.
Product default: **qwen-ja** by the predeclared holdout rule.

These two supplied videos validate the initial offline workflow only; they do not establish broad ASR superiority.
