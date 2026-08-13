# E4b — QwenJA pseudo-live sur les vidéos réelles

Date : 2026-08-06/07. Base demandée : `ba73ef9632c86e4cbc4744671bcfa1f87302b585`. Run : `23efe4c3bc44e1cdbaf1bbc01dde438615922eb8`, arbre source `a66feeea4647ee2248acdc0fb205292f6c0e45d79532fe661abc847f970cc205`.

## Décision

**Conserver `qwenApple` — résultat diagnostic.** `qwenPseudoLiveApple` améliore fortement la preview japonaise et anglaise, mais son gain de premier résultat anglais p95 est de 173 ms, sous la porte figée de 200 ms. La porte preview échoue aussi sur la latence et la couverture de tours ; la porte mémoire héritée L0 +20 % échoue pour les deux bras.

Le holdout indépendant par chaîne reste impossible avec les deux vidéos locales fournies. Aucun réglage après observation, aucune Promotion Anime et aucun changement produit.

## Protocole figé

- deux vidéos de `/Users/maz/Documents/videos/jap`, PCM 16 kHz mono, injection réelle 1× ;
- un passage cold puis trois warm par bras, huit sessions par bras ;
- contrôle `qwenApple`, candidat `qwenPseudoLiveApple` à 2 s ;
- `ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit` révision `7c70d18cb650655d32eafb952a74a49c6a3caad0` ;
- FireRed `0,40 / 350 / 500 ms`, glossaires `E1b-v2`, traduction Apple sans contexte ni profil ;
- références locales japonaises et anglaises uniquement, réseau sortant interdit.

## Résultats warm

| Mesure | `qwenApple` | `qwenPseudoLiveApple` |
|---|---:|---:|
| Preview JA CER / couverture | 57,7 % / 82,1 % | **45,2 % / 94,0 %** |
| Premier JA p50 / p95 / pire | **1 115 / 1 518 / 3 013 ms** | 2 193 / 2 383 / 6 219 ms |
| Preview EN chrF++ / couverture | 32,6 / **94,2 %** | **46,2** / 93,3 % |
| Premier EN p50 / p95 / pire | **1 558** / 2 575 / **5 072 ms** | 2 221 / **2 402** / 6 252 ms |
| Source age p50 / p95 / pire | **21 / 32 / 87 ms** | 228 / 507 / 1 695 ms |
| Stale / ticks coalescés | **0 / 0** | 65 / 15 |
| Final JA CER / EN chrF++ | 38,8 % / 48,3 | 38,8 % / 48,3 |
| Final p95 / couverture | 1 323 ms / 100 % | **1 149 ms** / 100 % |
| Backlog final max / fin | 2 / 0 | 2 / 0 |
| Retard injection max | **11 ms** | 37 ms |
| RSS max | **7,63 Gio** | 7,78 Gio |
| Thermique / intégrité | nominal / OK | nominal / OK |

Portes candidat : preview **échec**, final **passe**, intégrité **passe**, mémoire **échec**, thermique **passe**, backlog **passe**. Les deux bras ont zéro erreur enregistrée et XCTest termine sans échec.

Le runtime Core ML émet après chaque bras le même avertissement E5RT `ios17.slice_by_index: zero shape`. Il appartient au chemin FireRed/Core ML commun, après un test réussi, et n'est pas attribué au candidat.

## Artefacts

Run brut : `.build/benchmarks/japanese-live/runs/e4b-qwen-pseudolive-20260806T174818Z/` — 25 fichiers, 84 021 139 octets, ensemble SHA-256 `5d79f4915b7b55b9fa6f2b6160b77e0f584c3d64e27ac5f7b45f0dd73c832114`.

Les JSON bruts valent `149fed11974a8d4e5b61a093de7c333081ceeab638d83aa3885123a2a4b22c0b` (`qwenApple`) et `56988a706b49917a585684518c66e58a2026d5dad34fa70133c7b4d8ad1dda0e` (`qwenPseudoLiveApple`). Le reporter comptait initialement toutes les révisions EN comme premiers résultats ; son agrégation a été corrigée par `phraseKey`, puis le rapport a été régénéré sans rejouer les inférences.
