# E15 — MetricX reranking of suspect translations

Ticket #56 changes only selection between frozen candidates. MetricX runs reference-free after the TranslateGemma producer process has exited; it never rewrites text.

Checkpoint `google/metricx-24-hybrid-large-v2p6-bfloat16` @ `febb720e29a059df2e8af3ffd71dcdc9e0a24910` (Apache-2.0, 2.29 GiB).

Frozen margin: `1.0`; injected choice accuracy: 50.0%→87.5%.

| Split | Suspect units | Overrides | COMET baseline→MetricX | chrF++ baseline→MetricX | Runtime | Peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| development | 2 | 0 | 0.4869→0.4869 | 45.57→45.57 | 18.4 s | 5.04 GiB |

Decision: **no-go-development**.

Two videos and the small number of real suspect units limit this conclusion.
