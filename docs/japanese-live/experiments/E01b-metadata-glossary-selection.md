# E01b — sélection composée de glossaires depuis les métadonnées

Date : 2026-08-06. Base E1a : `f18312375a5def8eaf6b6a23903cf3a37328fb0f`. Mesure corrigée sur le commit propre `e81b67363c3b185249e5678d9eb2b160fb5d131c`, arbre source `2d760a2e0638407c5fe853f7bc450fdca4096bbc4fe88bd39fb98615d032b358`.

## Décision

La composition déterministe apporte un **gain diagnostique local** : 7 fragments améliorés, 0 neutre et 0 dégradé face à General, avec une distance d'édition de 256 à 224 sur les fragments touchés (-32). Conserver ce résultat pour la suite de la carte, sans Promotion : l'absence de `channelID` empêche toujours un holdout indépendant par chaîne.

Le sélecteur `e1b-v2` reçoit uniquement `videoID`, `channelID`, titre et labels de domaine. `videoID`, titre et labels sont requis; `channelID` ne décide pas la sélection. General est composé avec **tous** les profils reconnus, dans l'ordre fixe General, VTuber, Gaming, Conversation, Anime. Aucun transcript n'est fourni au sélecteur. Les métadonnées incomplètes ou sans label reconnu gardent le fallback General.

## Variable et résultats

Les glossaires E1a restent byte-identiques, SHA-256 `0db41097994b3b6d1c8c05b2c26a79971e6ac07db819f7fc1487aa98009c73f2`. ASR Qwen, VAD FireRed `0,40 / 350 / 500 ms`, traduction Apple et frontières utilisent le même replay E0 épinglé, SHA-256 `b9e06277edb6c23d9b969f06f160a0a587dcb867255d593e7c17a6c7342f4658`. Les sorties anglaises E0 restent identiques dans les deux bras; seule la composition déterministe appliquée au japonais change.

| Corpus | Composition | Alias | Fragments mieux / neutres / pires | Distance touchée |
|---|---|---:|---:|---:|
| `qudu2fx3ncc` | General + VTuber + Gaming | 4 | 3 / 0 / 0 | 118 → 110 |
| `md62mmdz0m` | General + VTuber + Conversation | 6 | 4 / 0 / 0 | 138 → 114 |

Les compositions ont 0 collision d'alias et couvrent les deux vidéos malgré `channelID = null`. Ce résultat mesure le benchmark local figé, pas une généralisation par chaîne.

## Diagnostic du banc

L'erreur Apple final de Conversation existait déjà dans E0 sur `qwen3-asr-1.7b:138`. Sa source `ちゃっかりウサギ…` est strictement identique dans General et la composition. Le probe E0 donne 3/3 contrôles sains et 3/3 rejets sur cette source Qwen répétitive; le contrôle d'attribution E1b repasse 3/3. La panne reste donc attribuée à la baseline E0, pas au sélecteur. Aucun nouvel échec critique n'apparaît.

## Artefacts et reproduction

Les 15 artefacts bruts occupent 57 Mio et incluent les deux PCM, leurs SHA, le replay E0 complet avec japonais/anglais/événements/frontières/erreurs/mémoire/thermique, les manifests, métadonnées et tags `ffprobe`, les 288 sorties appariées et la provenance Git. Ensemble SHA-256 : `a2ea482fe6ac45aa36e5c0a29230950f8fa7ebfde78098dd79b7fe4246e43313`.

```bash
WHISPERASR_E1B_QWEN=/Users/maz/Documents/projets/whisperASR-issue-26/.build/benchmarks/japanese-live/runs/e0-qwen-final-20260802T203033Z/live-replay.json \
WHISPERASR_E1B_PCM_ROOT=/Users/maz/Documents/projets/whisperASR-issue-26/.build/benchmarks/japanese-live/runs/e0-evidence-20260802T203033Z/raw-corpora \
Scripts/run_japanese_e1b_selector.sh
```

Artefacts locaux : `.build/benchmarks/japanese-live/runs/e1b-selector-20260806T125213Z/`. Aucun changement produit et aucun travail sur le ticket suivant.
