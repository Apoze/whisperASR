# Optimisation locale japonais → anglais

Ce dossier pilote les expériences sans mélanger mesures, décisions et code produit. Les WAV, outils externes et rapports générés restent sous `.build/benchmarks/japanese-live/`, donc hors Git.

## Graphe des lots

```text
L0 ─▶ L1 ─▶ L2 ─▶ L3 ─▶ L4 ─▶ L5 ─▶ L6 ─▶ L7 ─▶ L8 ─▶ L9 ─▶ L10
                                      └── L6A conditionnel ──▲
```

L0 à L3 conservent leurs résultats. L4 ajoute les deux vidéos longues fournies; L5 repart de ce PCM identique pour tous les candidats. Les sous-lots conditionnels ne sont créés qu'après échec mesuré de leur gate.

| Lot | Dépendances | État | Résultat attendu |
| --- | --- | --- | --- |
| [L0 — Baseline et pilotage](lots/L00-baseline.md) | aucune | terminé | mesures reproductibles et SLO figés |
| [L1 — Oracle fiable](lots/L01-oracle.md) | L0 | terminé | ASR, produit et voix évalués séparément |
| [L2 — Corpus holdout](lots/L02-corpus-holdout.md) | L1 | bloqué par revue humaine | trois holdouts validés humainement |
| [L3 — Bakeoff ASR](lots/L03-bakeoff-asr.md) | L1; L2 pour promouvoir | terminé, aucune promotion | quatre candidats comparés sur le même PCM |
| [L4 — Corpus vidéo et preuves](lots/L04-corpus-video.md) | L2, L3 | terminé | deux vidéos converties et épinglées |
| [L5 — Bakeoff japonais](lots/L05-bakeoff-japonais.md) | L4 | terminé, aucune promotion | huit ASR finales comparées; `whispermlx` arrêté après le stress pack |
| [L6 — Architectures live et anglais](lots/L06-live-anglais.md) | L5 | terminé, aucune promotion | Apple manque le p50; WhisperLiveKit est écarté |
| L6A — Alignement `whispermlx` | gate L6 | conditionnel | valeur propre de l'alignement japonais |
| [L7 — Firefox et décision](lots/L07-firefox-decision.md) | L5, L6 | terminé, aucune promotion | quatre replays Firefox; aucun gagnant produit |
| L8 — Intégration gagnante | L7 | non créé, gate non atteint | un seul moteur produit |
| L9 — Changements de voix | L8 | non démarré | frontières fiables, sans identité persistante |
| L10 — Nettoyage et endurance | lots retenus | non démarré | application minimale, stable et hors ligne |

## SLO et gates communs

- Preview anglaise : couverture ≥ 95 %, p50 ≤ 1 s, p95 ≤ 1,8 s, pire ≤ 3 s.
- Final anglais : p95 ≤ 1,5 s après la fin de parole, puis aucune révision prouvée par des indices append-only.
- Intégrité : PCM entièrement couvert, dernière parole validée humainement, aucun terme critique nouvellement omis et backlog final nul. Le rapprochement automatique de la dernière phrase reste une heuristique.
- Mémoire : moins de 10 Gio et au plus 20 % au-dessus du baseline L0.
- Promotion qualité : CER relatif amélioré d'au moins 10 % avec bootstrap apparié à 95 %, ou p95 preview gagné d'au moins 200 ms avec une dégradation CER ≤ 2 points; aucun holdout dégradé de plus de 2 points.

Les lignes `high` des deux vidéos fournies sont l'autorité du benchmark de développement. Leur statut reste `pending-human-review`, car les packs déclarent eux-mêmes une consolidation ASR/captions et des timings de caractères interpolés; `medium`, `low`, overlap et non-parole restent séparés dans les rapports.

La référence anglaise n'influence jamais le CER japonais. Un cas anglais réellement ambigu est exporté aveugle pour revue GPT Pro; il n'est pas transformé en score automatique local.

## Discipline

- Une fiche est créée seulement quand son lot démarre; elle contient dépendances, objectif, hors-périmètre, fichiers, tests, preuves, décision et rollback.
- Un commit Conventional Commit clôt chaque lot terminé.
- `ponytail` impose la solution minimale. `code-structure` autorise une extraction seulement quand au moins deux flux partagent réellement la même mécanique.
- Les rapports doivent contenir le commit, les SHA du corpus et du modèle, la configuration, la couverture PCM et les latences.
