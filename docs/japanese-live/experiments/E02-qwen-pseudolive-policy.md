# E02 — politique pseudo-live Qwen

Date : 2026-08-02. Machine : MacBook Pro M5 Pro 24 Gio, macOS 26.5.2. Firefox Nightly 155.0a1, lecture 1×. Prototype : branche `codex/issue-10-e2-qwen-preview`, commit `30c0a31`.

## Résultat

Les trois politiques ont été rejouées à cadence 1 s depuis le même PCM canonique de 1 min 45 s (`sha256:577080f97aa7be5d11a852e8855582f9aada22220a62bc9083150635f4abd00a`). Les valeurs sont en millisecondes.

| Politique | Couverture | Premier texte p50 / p95 / pire | Final p95 | Effacement normalisé | RSS | Intégrité |
|---|---:|---:|---:|---:|---:|---:|
| strict-latest | 100 % | 1349 / 2672 / 2672 | 1840 | 62,1 % | 7,03 Gio | oui |
| publish-if-useful | 100 % | 1269 / 2640 / 2640 | 1777 | 60,8 % | 7,00 Gio | oui |
| adaptive | 100 % | 1261 / 2247 / 2247 | 1425 | 65,8 % | 6,92 Gio | oui |

Toutes les captures sont PCM complètes, sans échantillon perdu, discontinuité, omission finale ni backlog résiduel. Le thermique reste nominal. La segmentation FireRed varie de 13 à 14 phrases selon le run, mais chaque dénominateur est couvert à 100 %.

## Verdict proposé

**Ne promouvoir aucune politique pseudo-live Qwen et conserver `qwenApple`.** Même la meilleure latence, `adaptive`, échoue aux portes premier texte p50 ≤ 1 s et p95 ≤ 1,8 s, tout en effaçant davantage que le meilleur run warm `qwenApple` (60,7 %). `strict-latest` et `publish-if-useful` échouent aussi la finale p95 ≤ 1,5 s.

Les cadences 2 s et 3 s sont arrêtées sans replay : le coordinateur ne peut lancer sa première inférence qu'après respectivement 2 s ou 3 s de phrase, avant même le coût ASR et traduction. Elles ne peuvent donc pas franchir la porte p50 ≤ 1 s après l'échec des trois variantes à 1 s.

Décision humaine : **validée par Apoze le 2026-08-02**. `qwenApple` reste le choix par défaut ; `adaptive` à 1 s reste seulement la meilleure variante pseudo-live expérimentale.

## Preuves

Les sessions et métriques brutes sont dans `.build/benchmarks/japanese-live/e2-prototype/exact-pcm/`. Le WAV canonique est dans `.build/benchmarks/japanese-live/e2-prototype/strict-latest-1s-nightly/`. Le rapport réutilise `Scripts/report_japanese_e1.py`; aucun outil de mesure supplémentaire n'a été ajouté.
