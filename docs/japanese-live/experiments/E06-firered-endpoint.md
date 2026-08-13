# E06 — endpoint FireRed

Date : 2026-08-02. Machine : MacBook Pro M5 Pro 24 Gio, macOS 26.5.2. Code : commit [`acd94d6`](https://github.com/Apoze/whisperASR/commit/acd94d6). FireRedVAD : `aufklarer/FireRedVAD-CoreML` à la révision `1cb0565191fbdc630c2fe8f111ba31c392d05706`.

## Résultat

La grille `{0,35; 0,40; 0,45}` × `{250; 350; 450 ms}` de silence × `{350; 500; 650 ms}` de post-roll a été rejouée avec les fenêtres FireRed exactes du produit sur les deux corpus de décision certifiés.

Seules trois configurations passent les veto : seuil `0,40`, post-roll `500 ms`, avec un silence de `250`, `350` ou `450 ms`. Elles produisent les mêmes 288 décisions, les mêmes frontières et la même pire p95 endpoint de `760 ms`. Le post-roll de `500 ms` domine ces trois silences ; changer le silence ne réduit donc pas la latence finale.

Les alternatives plus rapides sont éliminées avant le passage ASR/traduction :

| Configuration | Pire p95 endpoint | Veto par rapport à la baseline |
| --- | ---: | --- |
| `0,35 / 250–450 / 500 ms` | 650 ms | 2 nouvelles frontières dégradées |
| `0,40 / 450 / 350 ms` | 660 ms | 3 dernières moras, 22 frontières et 19 décisions supplémentaires |
| `0,40 / 250–350 / 350 ms` | 720 ms | 3 dernières moras, 50 frontières et 76 décisions supplémentaires |
| `0,45 / 250–450 / 500 ms` | 770 ms | 6 frontières et 9 décisions supplémentaires |

Décision : conserver la baseline `0,40 / 350 / 500 ms`. Aucun réglage FireRed testé ne réduit la p95 sans dégrader une porte d'intégrité ou de backlog. Les survivants étant strictement identiques à la baseline en audio et en décisions, Qwen final et Apple Translation reçoivent les mêmes entrées.

## Preuves

Le rapport brut reste dans `.build/benchmarks/japanese-live/e6-endpoint-grid/report.json` (SHA-256 `9a410e410ed0ce6adb55760212fa29eabf6a97599bc679ee5e26b8475a1b0753`). Il contient les 27 configurations, les deux corpus, les frontières, les dernières moras, les curseurs PCM, les décisions et les p95.

```bash
WHISPERASR_E6_ENDPOINT_GRID=1 \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --disable-sandbox \
  --filter JapaneseEndpointGridTests/testE6EndpointGridWhenOptedIn
```

Run certifiant : 3 088,933 s, 0 échec. Suite complète : 283 tests, 30 opt-in ignorés, 0 échec.
