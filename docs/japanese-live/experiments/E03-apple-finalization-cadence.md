# E03 — cadence de finalisation Apple Speech

Date : 2026-08-02. Machine : MacBook Pro M5 Pro 24 Gio, macOS 26.5.2. Source : commit `09b092b001e4d35cd193b9a5e3f4f7307d74821b`. Les quatre fenêtres stress correctives ont été rejouées à 1× avec Apple Speech et la preview Apple Translation.

## Décision

Conserver **1,5 s** (`24_000` échantillons) comme référence. Aucun changement produit n'est nécessaire.

- **1 s** améliore la p95 de preview de 353 à 447 ms, mais échoue deux fois la porte p50 (1,12 s > 1 s), dégrade le CER de plus de 2 points sur au moins deux fenêtres à chaque run et ne conserve la dernière parole que sur 1/4 puis 2/4 fenêtres.
- **0,75 s** échoue dès le premier run : couverture minimale 85,7 %, pire cas 4,63 s, une erreur Apple et régressions CER jusqu'à +9 points.

## Résultats

Latences en ms. Les CER sont ordonnés `qudu-fast-1`, `qudu-fast-2`, `md62-dialogue-1`, `md62-dialogue-2`.

| Cadence | Run | Premier texte p50 / p95 / pire | Couverture min. | Révisions | CER | Dernière parole | RSS max | CPU moyen brut |
|---|---:|---:|---:|---:|---|---:|---:|---:|
| 1,5 s | 1 | 1138 / 1631 / 4229 | 100 % | 296 | 55,01 / 27,17 / 40,56 / 46,56 % | 1/4 | 263,2 Mio | 0,0541 |
| 1 s | 1 | 1120 / 1184 / 1220 | 100 % | 290 | 56,93 / 31,32 / 48,48 / 47,62 % | 1/4 | 260,6 Mio | 0,0503 |
| 1 s | 2 | 1124 / 1278 / 1418 | 100 % | 297 | 58,64 / 30,19 / 47,79 / 48,15 % | 2/4 | 263,8 Mio | 0,0619 |
| 0,75 s | 1 | 875 / 1528 / 4632 | 85,7 % | 243 | 54,58 / 34,34 / 48,48 / 55,56 % | 2/4 | 273,5 Mio | 0,0485 |

Le PCM est complet et le thermique nominal sur les quatre runs. L'absence de dernière parole est déjà présente à 1,5 s et reste couverte par [E6 — régler FireRed sans perdre de parole](https://github.com/Apoze/whisperASR/issues/14) ; aucune cadence testée n'est donc promotable à ce stade.

L'énergie n'a pas été rejouée dans l'application : les deux cadences candidates étaient déjà éliminées par des portes strictes de latence, couverture, qualité ou intégrité. Une troisième répétition de 1 s et les répétitions de 0,75 s ont été arrêtées pour la même raison.

## Preuves

Les rapports bruts sont locaux dans :

- `.build/benchmarks/japanese-live/runs/e3-apple-finalize-1500-r1-20260802/live-replay.json`
- `.build/benchmarks/japanese-live/runs/e3-apple-finalize-1000-r1-20260802/live-replay.json`
- `.build/benchmarks/japanese-live/runs/e3-apple-finalize-1000-r2-20260802/live-replay.json`
- `.build/benchmarks/japanese-live/runs/e3-apple-finalize-750-r1-20260802/live-replay.json`

Les empreintes d'arbre correspondantes sont `68fbdf7f094082b12559f8e8c03a815a3f8eb5270becf957c4a386c7af95d2ef`, `685ff9e366fd0273ac235d159b8c4d73736d62f06cce96c581f9f738a9a59eaa` et `3b26980484525f57424de886735260caad8a31447bae0452194257f1a1ab6c16`.

Les runs candidats ont coexisté avec le benchmark d'endpointing parallèle, limité à un cœur logique. Le préflight indiquait 59 % de CPU idle et aucune alerte thermique. La décision repose sur des vetos absolus de couverture, p50, CER et dernière parole, pas sur une différence marginale de ressources.
