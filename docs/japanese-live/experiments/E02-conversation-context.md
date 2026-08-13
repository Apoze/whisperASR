# E02 — contexte conversationnel sur les finales

Date : 2026-08-06. Base : `codex/issue-28-metadata-glossary-selection` au commit `18f4dd5`. Run propre : commit `37fe5b779cb9a77c19cee4012d5865d405ccedaf`, arbre source `d8fdee83c0f111fe930072205c11416d55749c07ed365be07318a3071924dbb4`.

## Décision

**Preuve insuffisante : ne pas retenir le contexte des deux finales précédentes.** Sur les sorties Qwen, les 267 finales scoreables sont byte-identiques entre les deux bras. Le contexte n'améliore donc ni fidélité, ni cohérence, ni coréférence, ni tranche spécialisée, et ralentit la traduction finale dans les deux vidéos.

ASR Qwen, FireRed `0,40 / 350 / 500 ms` et composition E1b-v2 restent figés. Gaming utilise General + VTuber + Gaming ; Conversation utilise General + VTuber + Conversation. Aucun changement produit et aucun travail sur le ticket suivant.

## Protocole figé

Le cadrage reprend les 288 frontières finales E0. Le japonais et l'anglais de référence sont distribués temporellement sur ces frontières avant toute sortie Qwen. Dix-neuf finales sans japonais de référence restent dans les artefacts mais sont exclues du gel ; 269 courants et 242 fenêtres complètes de trois finales restent scoreables côté référence.

Le bras contexte contient exactement les deux finales japonaises précédentes de la même vidéo, le séparateur numérique `[[314159265358979]]`, puis le courant. Seul le texte anglais après le séparateur est publié. Le gel référence n'a consulté aucun score et compte zéro échec d'extraction. Le protocole figé SHA-256 `51debf91e9e9ed469d097007902cd2a5c6b22e77d63c83265d772771b7334fc1` est ensuite réutilisé sans retuning sur les 288 courants et 284 fenêtres Qwen.

## Qualité automatique locale

| Phase | Corpus | Finals | Δ chrF++ fidélité | Δ chrF++ fenêtre de 3 | Δ rappel pronoms | Δ tranche spécialisée |
|---|---|---:|---:|---:|---:|---:|
| Référence | Gaming | 118 | -0,066 | -0,131 | 0,00 pt | 0,000 |
| Référence | Conversation | 124 | -0,017 | -0,017 | 0,00 pt | 0,000 |
| Qwen | Gaming | 134 | 0,000 | 0,000 | 0,00 pt | 0,000 |
| Qwen | Conversation | 133 | 0,000 | 0,000 | 0,00 pt | 0,000 |

Côté référence : 5 finales améliorées, 233 identiques et 4 dégradées ; delta moyen apparié par vidéo `-0,041` chrF++, bootstrap 95 % `[-0,066 ; -0,017]`. Côté Qwen : 267 identiques, zéro améliorée et zéro dégradée ; intervalle apparié `[0 ; 0]`. La tranche spécialisée couvre 46 finales de référence et 51 finales Qwen détectées automatiquement depuis les termes E1a locaux.

## Portes live

| Porte | Courant seul | Deux précédents + courant | Attribution |
|---|---|---|---|
| Preview | échec ; p50/p95/pire `1141 / 1637 / 4244 ms` | identique | baseline Apple Speech figée |
| Final Gaming p95 | échec ; `1675 ms` | échec ; `1759 ms` | contexte plus lent de 84 ms |
| Final Conversation p95 | `1277 ms` | `1346 ms` | contexte plus lent de 69 ms |
| Intégrité | échec | échec | ASR/PCM sain ; même panne Apple sur Qwen final 138 |
| Mémoire | échec ; `9 617 396 800 o` | identique | Qwen figé dépasse la limite `5 022 375 945 o` |
| Thermique | nominal | nominal | aucune dégradation |

Le replay live combine les arrivées finales E0 figées et les durées Apple mesurées en FIFO. La p95 globale passe de `1417` à `1500 ms`; le contexte crée jusqu'à `165 ms` de queue de traduction en Gaming.

## Diagnostic des pannes

- Qwen Conversation final 138 échoue dans les deux bras et sur 3/3 sessions Apple fraîches par bras : interaction déterministe de la source répétitive avec Apple, déjà présente dans E0, jamais attribuée au contexte.
- Les finales de référence Gaming 16/87 et Conversation 76 échouent aussi dans les deux bras et 3/3 sur sessions fraîches : mêmes interactions source-traduction, sans effet du contexte.
- Le premier build avait sélectionné les Command Line Tools sans XCTest ; épingler `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` rend la même boucle verte.
- Le premier run complet `e2-context-20260806T133959Z` a conservé ses sorties brutes mais son rapporteur supposait à tort que Swift encodait les optionnels `nil`. Le correctif `37fe5b7` traite leur absence ; le run final propre reproduit les mêmes résultats.

Aucun défaut de build, runner, entrée, référence, ASR, PCM ou frontière n'est attribué au contexte.

## Artefacts et reproduction

Le run final est `.build/benchmarks/japanese-live/runs/e2-context-20260806T134439Z/` : 23 fichiers, 65 999 157 octets, ensemble SHA-256 `f00409ba77ef1af7a290e5e8dddaecfb81c5953434cf01290a6f837657e77396`. Il contient PCM et SHA, commits, arbre source, runtime, métadonnées, glossaires, protocoles avant/après gel, japonais brut/général/E1b-v2, anglais brut et publié, événements live, frontières, erreurs, probes, mémoire, CPU, thermique et logs.

```bash
Scripts/run_japanese_e2_context.sh
```
