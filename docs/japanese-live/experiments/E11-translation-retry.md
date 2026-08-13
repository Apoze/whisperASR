# E11 — Selective translation retry

Ticket #52 retries only units rejected by the frozen E10 validator. Attempt B removes neighbours, metadata, aliases, and non-critical terms.

| Split | Units | Retries | Retry rate | Terminal hard | Terminal suspect | COMET | chrF++ | Runtime | Added runtime | Peak memory |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| development | 313 | 3 | 0.96% | 0 | 1 | 0.4829 | 45.68 | 470.2 s | 9.9 s | 6.54 GiB |
| holdout | 273 | 0 | 0.00% | 0 | 0 | 0.5856 | 50.19 | 388.4 s | 0.0 s | 6.50 GiB |

## Raw artifacts

- `.build/benchmarks/direct-translation/development/direct-protocol.json`
- `.build/benchmarks/translation-integrity/development.json`
- `.build/benchmarks/translation-retry/development/retry.json`
- `.build/benchmarks/direct-translation/holdout/direct-protocol.json`
- `.build/benchmarks/translation-integrity/holdout.json`
- `.build/benchmarks/translation-retry/holdout/retry.json`

Promotion gates pass.
