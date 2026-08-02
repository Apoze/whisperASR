# E01 — baseline qwenApple

Date : 2026-08-02. Machine : MacBook Pro M5 Pro 24 Gio, macOS 26.5.2. Pipeline : `qwenApple`, Apple Translation `adaptive`, Firefox Nightly 155.0a1, lecture 1×. Source : commit `ec9c6257c3a500615954bbdbb6d533c9c3d78257`, arbre benchmark `2ac39a5d4d4d758e799a3e9dae81b4004922bd4a4ed83f960d11891318dda38b`.

## Résultat

Arrêt anticipé sur la porte d'intégrité : le cold et les trois runs warm ont tous reçu `invalidResponse` d'Apple Translation sur un final japonais Qwen. Le job fautif reste en tête de la FIFO et les phrases suivantes ne peuvent plus produire de final anglais. `qwenApple` ne peut donc pas servir de baseline promotable dans cet état.

| Régime | PCM avant arrêt | Phrases / finales manquantes | Preview | Premier texte p50 / p95 / pire | Final p50 / p95 / pire | RSS | Énergie | Thermique |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| cold | 285,7 s | 41 / 13 | 85,4 % | 957 / 3896 / 7064 ms | 1093 / 1870 / 1918 ms | 6,76 Gio | 58,9 J | nominal |
| warm 1 | 85,5 s | 8 / 4 | 100 % | 2151 / 3141 / 3141 ms | 1150 / 1938 / 1938 ms | 6,83 Gio | 16,5 J | nominal |
| warm 2 | 79,9 s | 8 / 4 | 100 % | 1515 / 2225 / 2225 ms | 1289 / 1658 / 1658 ms | 6,81 Gio | 13,4 J | nominal |
| warm 3 | 83,9 s | 8 / 3 | 100 % | 1722 / 2258 / 2258 ms | 1204 / 1467 / 1467 ms | 6,76 Gio | 13,5 J | nominal |

Même avant le veto d'intégrité, la preview warm dépasse la porte p95 de 1,8 s dans 3/3 runs et la finale dépasse 1,5 s dans 2/3 runs. L'effacement normalisé warm varie de 60,7 % à 75,2 %. Le RSS reste sous 10 Gio et le thermique reste nominal.

## Preuves

Les artefacts bruts, l'index et le rapport JSON sont dans `.build/benchmarks/japanese-live/e1-qwenapple-20260802/`. Le rapport est reproductible avec :

```bash
python3 Scripts/report_japanese_e1.py \
  --index .build/benchmarks/japanese-live/e1-qwenapple-20260802/index.json \
  --output .build/benchmarks/japanese-live/e1-qwenapple-20260802/report.json
```

Les replays complets et le second corpus ont été évités après 4/4 échecs : poursuivre aurait seulement accru la FIFO derrière un final définitivement retenu.

## Correctif de la FIFO

Les quatre plages PCM fautives ont été rejouées avec le modèle épinglé. Le décodage Qwen protégé par `noRepeatNgramSize = 3` a supprimé les boucles observées et Apple a accepté 4/4 sorties. Le produit conserve donc le décodage rapide normal et ne rejoue avec cette protection que lorsqu'une répétition pathologique est détectée.

Si une sortie reste invalide, la FIFO publie désormais `[Translation unavailable]`, conserve la source et l'audio, signale l'enregistrement comme échoué/réessayable, puis poursuit les phrases suivantes. Il n'y a ainsi ni omission silencieuse ni backlog final causé par cette erreur.
