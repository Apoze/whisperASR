# E23 — Silero VAD v6.2.1 Core ML

Prototype jetable de l'issue #23. Aucun défaut produit n'est modifié.

## Verdict

**conserver FireRed actuel 0,40 / 350 / 500 ms**

Silero ajoute 9 dernières moras perdues et 26 frontières dégradées. Sa pire p95 atteint 1258 ms, soit +498 ms face à FireRed.

## Résultats

| Candidat | Passe les veto | Pire p95 endpoint | Décisions reproductibles | Backlog |
| --- | --- | ---: | --- | ---: |
| `silero-v6.2.1-coreml-stream-32ms` | non | 1258 ms | oui | 0.000 ms |

Configuration : `VADIterator` v6.2.1 officiel (`0,50 → 0,35`, silence 100 ms, pad 30 ms), modèle Core ML 32 ms à états `h`/`c` explicites.

## Coût

Silero évalue 57605 trames par répétition, contre 5 484 930 évaluations répétées pour FireRed E22 (95.2× moins). La p95 calcul par tick est 0.359 ms, sans backlog ni alerte thermique. Le temps CPU reste un proxy non promotable sans `powermetrics`.

## Preuves

Les deux PCM E0, les annotations/veto E6, les décisions, probabilités brutes, durées de chaque trame et deux répétitions sont dans `artifacts/E23-silero-v6.2.1-coreml.json`.

## Rejouer

```bash
Scripts/run_issue23_silero_prototype.sh
```
