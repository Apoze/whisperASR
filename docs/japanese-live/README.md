# Optimisation locale japonais → anglais

Ce dossier pilote les expériences sans mélanger mesures, décisions et code produit. Les WAV et rapports générés restent sous `.build/benchmarks/japanese-live/<run-id>/`, donc hors Git.

## Graphe des lots

```text
L0 ─▶ L1 ─▶ L2 ─▶ L3 ─▶ L4 ─▶ L5 ─▶ L6 ─▶ L7
             └──── gate de promotion ────▲
```

L3 peut démarrer après L1, mais aucun moteur ne peut être promu avant la validation humaine de L2. Les sous-lots CAT et stéréo ne seront créés que si leur gate d'entrée échoue ou réussit comme prévu.

| Lot | Dépendances | État | Résultat attendu |
| --- | --- | --- | --- |
| [L0 — Baseline et pilotage](lots/L00-baseline.md) | aucune | terminé | mesures reproductibles et SLO figés |
| [L1 — Oracle fiable](lots/L01-oracle.md) | L0 | terminé | ASR, produit et voix évalués séparément |
| [L2 — Corpus holdout](lots/L02-corpus-holdout.md) | L1 | bloqué par revue humaine | trois holdouts validés humainement |
| L3 — Bakeoff ASR | L1; L2 pour promouvoir | suivant, exploratoire | candidats comparés sur le même PCM |
| L4 — Intégration du gagnant | L2, L3 | bloqué par gate | une seule ASR produit |
| L5 — Traduction | L4 | non démarré | Apple conservé ou CAT testé conditionnellement |
| L6 — Séparation des voix | L4, gate L5 | non démarré | coupures fiables, sans identité persistante |
| L7 — Simplification | lots retenus | non démarré | application minimale et endurante |

## SLO et gates communs

- Preview anglaise : couverture ≥ 95 %, p50 ≤ 1 s, p95 ≤ 1,8 s, pire ≤ 3 s.
- Final anglais : p95 ≤ 1,5 s après la fin de parole, puis aucune révision.
- Intégrité : PCM entièrement couvert, dernière parole présente, aucun terme critique nouvellement omis et backlog final nul.
- Mémoire : moins de 10 Gio et au plus 20 % au-dessus du baseline L0.
- Promotion qualité : CER relatif amélioré d'au moins 10 % avec bootstrap apparié à 95 %, ou p95 preview gagné d'au moins 200 ms avec une dégradation CER ≤ 2 points; aucun holdout dégradé de plus de 2 points.

Les résultats d'un holdout dont `annotations.status` n'est pas `complete` sont exploratoires. Deux juges bilingues sont requis pour toute promotion fondée sur la fidélité anglaise.

## Discipline

- Une fiche est créée seulement quand son lot démarre; elle contient dépendances, objectif, hors-périmètre, fichiers, tests, preuves, décision et rollback.
- Un commit Conventional Commit clôt chaque lot terminé.
- `ponytail` impose la solution minimale. `code-structure` autorise une extraction seulement quand au moins deux flux partagent réellement la même mécanique.
- Les rapports doivent contenir le commit, les SHA du corpus et du modèle, la configuration, la couverture PCM et les latences.
