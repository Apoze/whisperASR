# E12 — Canonical cue-local glossary

Ticket #53 changes only glossary selection. Semantic units, direct prompt,
validator, retry policy, model, generation settings, references, and context
remain frozen from E11.

| Split | Critical opportunities | Critical accuracy | False insertions | COMET | chrF++ | Hard failures | Suspects |
|---|---:|---:|---:|---:|---:|---:|---:|
| development | 1 | 100% | 0 | 0.4829 | 45.68 | 0 | 1 |
| holdout | 0 | n/a | 0 | 0.5856 | 50.19 | 0 | 0 |

Raw artifacts and the frozen budget are recorded in
`docs/high-quality-glossary-e12.json`; the referenced raw E9–E11 evidence is
checked in under `docs/japanese-live/experiments/evidence/E12/`. Development
and holdout selection artifacts there record current decisions, signals,
ambiguity, provenance, sizes, token shares, register, and per-cue validation
opportunities. Development trials over 8, 10, and 12 entries and 15%, 20%,
and 25% token-share ceilings
tied, so 12 entries and 25% were frozen before opening holdout. Exact
recognized Japanese is the strongest signal; metadata only disambiguates.
The direct product prompt is not promoted because the untouched holdout has
no applicable glossary opportunity and therefore cannot show a measurable
gain.
