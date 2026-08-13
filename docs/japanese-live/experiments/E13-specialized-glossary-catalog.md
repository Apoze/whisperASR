# E13 — Sourced specialized glossary catalog

Ticket #54 changes only the versioned built-in catalog. Selector logic, prompt
protocol, semantic units, context, retry policy, model, and generation settings
remain frozen from E12.

The catalog grows from 16 to 35 entries. Each entry now records its official
Japanese form, kana/kanji/romanized variants when applicable, one canonical
English form, accepted aliases, domain and source scope, ambiguity class,
official provenance, explicit inclusion/exclusion rules, and verification date.

| Slice | Entries | Reference opportunities | Product opportunities | Status |
|---|---:|---:|---:|---|
| Anime | 8 | 0 | 0 | diagnostic only |
| VTuber | 6 | 4 | 1 | Amayui Moka only |
| Gaming | 13 | 7 | 0 | reference-only diagnostic |
| Conversation | 8 | 2 | 2 | soft guidance |

| Split | Opportunities | Canonical/alias accuracy | False insertions | Max prompt entries | Max token share | COMET | chrF++ |
|---|---:|---:|---:|---:|---:|---:|---:|
| development | 3 | 33% overall; 100% hard | 0 | 1 | 2.29% | 0.4829 | 45.68 |
| holdout | 0 | n/a | 0 | 0 | 0% | 0.5856 | 50.19 |

`docs/high-quality-glossary-e13.json` records the complete coverage and raw
artifact manifest. E13 selection evidence is checked in under
`docs/japanese-live/experiments/evidence/E13/`. A real TranslateGemma run
regenerated all three applicable development units through the product request
contract and matched the frozen direct outputs. No expanded entry is selected
in product ASR units, and holdout selection is empty, so corpus COMET and chrF++
remain the frozen E12 values. Reference-only slice coverage is diagnostic and
the catalog is not promoted.
