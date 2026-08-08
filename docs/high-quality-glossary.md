# Bounded high-quality glossary

The built-in catalog is a 16-term seed: four entries each for anime, VTuber,
gaming, and conversation. It is intentionally not exhaustive. Source-specific
names, slang, new releases, and context-dependent translations may be absent.

Each entry stores Japanese forms, one canonical English form, English aliases,
an official provenance URL, and explicit inclusion/exclusion rules. The current
sources are official anime sites, VTuber organization/member sites, game
publishers, and Japan Foundation teaching material.

Source metadata may add up to eight exact bilingual pairs written as
`Japanese (Canonical English)`. Unpaired text is ignored: the app does not
guess romanization or translation from a name alone.

Selection is deterministic. Exact matches score title `8`, channel `6`,
description `4`, and recognized Japanese `2`; ties use the stable term ID.
Ambiguous short forms such as `エペ`, `ホロ`, and `進撃` require metadata
or their full Japanese form. Empty or unrelated metadata selects nothing.

The default budget is 12 entries, 2,048 encoded bytes, 35% of the actual
encoded translation batch, 512 scoring operations, and no unconfirmed
ambiguous relevance signal. Evidence retains every selected/rejected
decision, signals, provenance, encoded size, and budget reason. The raw ASR
text is never rewritten.

The checked-in `high-quality-glossary-development.json` measures 1.0 precision,
recall, F1, and glossary accuracy with 0.0 false-correction risk on
`qudu2fx3ncc`. Reproduce it with
`swift test --filter HighQualityGlossaryTests/testCheckedInDevelopmentReportMatchesQuduCorpus`.
The frozen
`md62mmdz0m` holdout must not be inspected while tuning terms, rules, weights,
or budgets.
