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

Selection is deterministic and cue-local. Exact recognized Japanese scores
`16`, ahead of title `8`, channel `6`, and description `4`; ties use the stable
term ID. Metadata can disambiguate an exact ambiguous cue form but cannot add a
term by itself. Empty, unrelated, or conflicting metadata therefore selects
nothing for that cue.

Development-only trials covered 8, 10, and 12 entries and 15%, 20%, and 25%
input-token shares. They tied on the observed critical opportunity, so the
budget was frozen before holdout at 12 entries, 2,048 encoded bytes, an
estimated 25% of the 2K input-token budget (one token per non-ASCII scalar and
four ASCII bytes per token), 512 scoring operations, and no unconfirmed
ambiguous relevance signal. Evidence retains selected and rejected decisions,
cue IDs, signals, hard/soft guidance, provenance, encoded size, token share,
budget reason, and the per-job canonical terminology register. A canonical is
registered only after selection and then constrains later ambiguous
occurrences. The raw ASR text is never rewritten.

The checked-in `high-quality-glossary-development.json` measures 1.0 precision,
recall, F1, and glossary accuracy with 0.0 false-correction risk on
`qudu2fx3ncc`. Reproduce it with
`swift test --filter HighQualityGlossaryTests/testCheckedInDevelopmentReportMatchesQuduCorpus`.
The frozen `md62mmdz0m` holdout has no applicable critical glossary
opportunity. Ticket #53 is therefore recorded but not promoted into the direct
TranslateGemma prompt; the existing retry protocol may use only applicable
hard canonical terms. See `japanese-live/experiments/E12-cue-local-glossary.md`.
