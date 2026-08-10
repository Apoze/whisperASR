# E14 — Previous accepted conversational context

Ticket #55 changes only conversational history. The E12 direct interaction, semantic units, glossary, retry, validator, model, and generation settings remain frozen.

| Split | Policy | COMET baseline→context | chrF++ baseline→context | Pronoun chrF++ | Ellipsis chrF++ | Lexical inconsistencies | Hard failures | Runtime baseline→context | Input tokens baseline→context |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| development | previous-accepted-v1 | 0.4829→0.4869 | 45.68→45.57 | 38.66→37.77 (21) | 28.94→28.87 (14) | 1→1 (5) | 0 | 470.2→988.7 s | 26966→84764 |
| holdout | previous-accepted-v1 | 0.5856→0.5873 | 50.19→50.38 | 44.28→46.37 (36) | 32.29→26.19 (5) | 2→2 (2) | 0 | 388.4→871.8 s | 22838→75433 |

The 8-second reset threshold tied the 4-second candidate on development (8 resets) and retained three boundaries missed at 12 seconds. The policy was frozen before holdout.

Deterministic diagnostics pass for pronouns, ellipsis, lexical consistency, rejected turns, future exclusion, scene reset, and the context budget.

The context policy is promoted.

Two complete reference videos do not establish universal conversational quality.
