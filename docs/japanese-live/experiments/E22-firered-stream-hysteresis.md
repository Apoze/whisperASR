# E22 — Stream-VAD et hystérésis ciblée

Prototype jetable de l'issue #22. Aucun défaut produit n'est modifié.

## Verdict

**conserver FireRed actuel 0,40 / 350 / 500 ms**

Aucun candidat ne passe les veto avec un gain endpoint net.

Suivi Silero : https://github.com/Apoze/whisperASR/issues/23.

## Résultats

| Candidat | Passe les veto | Pire p95 endpoint | Veto |
| --- | --- | ---: | --- |
| `hysteresis-0.40-0.25-post-350` | non | 620 ms | +51 décisions, +3 moras, +40 frontières |
| `hysteresis-0.40-0.25-post-500` | non | 780 ms | +3 frontières |
| `hysteresis-0.40-0.30-post-350` | non | 720 ms | +55 décisions, +3 moras, +43 frontières |
| `hysteresis-0.40-0.30-post-500` | non | 660 ms | +3 frontières |
| `hysteresis-0.40-0.35-post-350` | non | 720 ms | +65 décisions, +3 moras, +45 frontières |
| `hysteresis-0.40-0.35-post-500` | non | 650 ms | +1 frontière |
| `official-stream-vad-cache` | non | 590 ms | +13 frontières |

## Lecture

- Post-roll 350 ms : les trois sorties perdent 3 nouvelles moras et ajoutent 51 à 65 décisions.
- Post-roll 500 ms : la sortie 0,35 est la plus proche, mais dégrade encore 1 frontière.
- Stream-VAD : p95 590 ms et 29.8× moins de trames modèle, mais 13 nouvelles frontières.

## Limites

L'énergie est représentée par le temps CPU : `powermetrics` exige root. Ce proxy ne peut pas promouvoir un candidat. Les métriques brutes et décisions sont dans `artifacts/E22-firered-stream-hysteresis.json`.

## Rejouer

```bash
Scripts/run_issue22_firered_prototype.sh
```
