# E32 — Readable English subtitle reflow (#120)

**Decision: GO for a default-off High-quality Bêta option. Live is unchanged.**

The E23/E24 budgets remain unchanged: 42 characters per line, 2 lines, 1–7
seconds and 20 CPS. E32 can now split at retained Japanese pause, punctuation
or source-cue timestamps from #116. English words and order never change.

| Split | Readable | >84 chars | >20 CPS | <1 s | >7 s |
|---|---:|---:|---:|---:|---:|
| DEV baseline | 119/307 | 37 | 156 | 74 | 11 |
| DEV candidate | 141/318 | 29 | 156 | 74 | 3 |
| Holdout baseline | 97/260 | 41 | 129 | 65 | 17 |
| Holdout candidate | 146/286 | 21 | 129 | 65 | 2 |

DEV rehabilitates 11 source cues; holdout rehabilitates 23. Every replacement
is a complete all-budget partition. The remaining 177 DEV and 140 holdout
sources stay unchanged and are audited as unresolved.

All exact gates pass: normalized English, word order, source timing coverage,
inter-cue gaps, Speaker metadata, Speaker on/off equivalence, zero new overlap,
and identical SRT/VTT timestamps. Replay plus production export took 0.387 s
on DEV and 0.663 s on holdout. No model was loaded.

The 12B retained evidence is quality-scored. Both retained 4B corpora pass the
same structural reflow contract, but are not quality-scored because their E31
translations contain upstream validation failures.

Budgets were frozen before holdout in
`evidence/E32-readable-cues/budgets.json` (SHA-256 `0fb5d1d626b5780d7578a93513dd6901526122f510cb097f20ee4154ac749720`).
Full metrics, provenance, gates and infra/harness/candidate routing are in
`evidence/E32-readable-cues/report.json`.
