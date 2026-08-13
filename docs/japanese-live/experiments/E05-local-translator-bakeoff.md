# Local translator bakeoff — ticket #46

Both candidates used byte-identical frozen requests and canonical prompts through the native MLX Swift translation seam. Their model-native wrappers supplied equivalent translation control. All veto gates passed before the holdout was opened.

Pins: `mlx-community/translategemma-12b-it-4bit` @ `f3dcfd54df14672fbcf0731086fb47a797a943ae`; `mlx-community/Qwen3-14B-4bit` @ `a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4`. Runtime MLX Swift LM `3.31.4`.
Raw prompts, outputs, hashes, gates, timings, memory and diagnostics are retained under `.build/benchmarks/high-quality/translator-bakeoff/`.
Native cue-marker audit: 940/940 outputs passed.

| Corpus | Candidate | COMET | chrF++ | Glossary | Missing/dup/reordered/unknown | Untranslated | Suspected hallucination | Runtime | Peak memory |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| qudu2fx3ncc | translategemma-12b-it-4bit | 0.7746 | 55.35 | 25.0% | 0 | 1 | 0 | 2809.2s | 7.54 GiB |
| qudu2fx3ncc | qwen3-14b-4bit | 0.7589 | 53.08 | 25.0% | 0 | 3 | 0 | 1028.1s | 8.29 GiB |
| md62mmdz0m | translategemma-12b-it-4bit | 0.7455 | 57.35 | n/a | 0 | 0 | 0 | 2814.7s | 7.15 GiB |
| md62mmdz0m | qwen3-14b-4bit | 0.7312 | 55.41 | n/a | 0 | 3 | 0 | 1339.6s | 8.23 GiB |

Holdout paired chrF++ Qwen−TranslateGemma: -1.443 [95% -4.110, 1.114].
Holdout paired COMET Qwen−TranslateGemma: -0.0143 [95% -0.0272, -0.0020].
Product default: **translategemma-12b-it-4bit** because Qwen was not significantly better on the holdout.

These two videos validate only this initial workflow and do not prove universal translation superiority.
