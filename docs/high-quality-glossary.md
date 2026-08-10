# Bounded high-quality glossary

Catalog schema 2, version `2026-08-10`, contains 35 sourced entries across
anime, VTuber, gaming, and conversation. It prioritizes terms evidenced by the
Offline acceptance corpus plus reusable high-frequency terms; it is not a claim
of universal coverage.

Each entry stores the official Japanese form, kana/kanji/romanized variants
when applicable, one canonical English form, English aliases, domain/source
scope, ambiguity class, official provenance, verification date, and explicit
inclusion/exclusion rules. Sources are official franchise sites, VTuber rosters
and channels, game publishers/manuals, and Japan Foundation teaching material.

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

The historical `high-quality-glossary-development.json` measures 1.0 precision,
recall, F1, and glossary accuracy with 0.0 false-correction risk on
`qudu2fx3ncc`. Reproduce it with
`swift test --filter HighQualityGlossaryTests/testHistoricalDevelopmentReportRemainsDecodable`.
The frozen `md62mmdz0m` holdout has no applicable critical glossary
opportunity. Ticket #53 is therefore recorded but not promoted into the direct
TranslateGemma prompt; the existing retry protocol may use only applicable
hard canonical terms. See `japanese-live/experiments/E12-cue-local-glossary.md`.

Ticket #54 coverage and real-video diagnostics are in
`high-quality-glossary-e13.json`. The expanded entries have reference coverage
but no opportunity in the product ASR translation units; the E13 development
rerun is unchanged and holdout selection is empty, so the result remains
diagnostic and is not promoted.
