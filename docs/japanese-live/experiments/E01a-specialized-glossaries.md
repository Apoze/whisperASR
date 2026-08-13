# E01a — glossaires spécialisés exhaustifs mais bornés

Date : 2026-08-05. Base : `d91f9ff8fbe10f7d29fb444d781cafccb9158368`. Mesure Release sur le commit propre `d8813f910d2d1a55c360311bd6e4ae4ffbb27f82`.

## Décision

Conserver quatre profils séparés : Anime, VTuber, Gaming et Conversation. Un profil peut contenir au plus **80 termes ordinaires + 20 termes d’overlay**, **16 alias de remplacement** et **16 Kio JSON UTF-8**. Le correcteur doit rester sous **0,25 ms p95/tour**, **1 ms au pire** et ne produire **aucun faux remplacement** sur les références locales.

Anime reste vide : aucune référence Anime locale ne permet de construire ou noter un inventaire. Les catalogues généraux externes ne sont pas importés. Les candidats ne sont ni intégrés au produit ni promus par cette expérience.

## Provenance et séparation des rôles

Chaque terme de [`e1a-candidates.json`](../glossaries/e1a-candidates.json) conserve ses sources, son mode (`hint`, `replace`, `overlay`) et sa justification d’ambiguïté. Les sources officielles externes servent uniquement à construire et orthographier l’inventaire. La couverture et les effets des remplacements utilisent seulement les références locales `qudu2fx3ncc` et `md62mmdz0m`, ainsi que les sorties Qwen E0 épinglées. `externalSourcesUsedForScoring` vaut `false`.

La [recherche de construction](../research-specialized-glossaries-2026.md) couvre **141/141** occurrences locales ciblées, dont **97/97** annotations `high` hors overlap. Cette complétude de construction est distincte de la couverture du catalogue actif ci-dessous : les termes officiels absents des vidéos restent sourcés, mais ne reçoivent aucun score.

## Mesures locales

| Profil complet | Termes | Alias | Termes visibles localement | Occurrences | Corrections mieux / neutres / fausses | Taille JSON | Runtime Release p95, 288 fragments |
|---|---:|---:|---:|---:|---:|---:|---:|
| Anime | 0 | 0 | n/a | 0 | 0 / 0 / 0 | 55 o | 0,035 ms |
| VTuber | 42 | 2 | 5/42 (11,90 %) | 24 | 2 / 0 / 0 | 4 101 o | 2,120 ms |
| Gaming | 32 | 2 | 11/32 (34,38 %) | 22 | 2 / 0 / 0 | 3 138 o | 2,175 ms |
| Conversation | 19 | 4 | 13/19 (68,42 %) | 37 | 4 / 0 / 0 | 1 937 o | 3,263 ms |

Le maximum mesuré équivaut à environ **11,3 µs par fragment**. Le microbenchmark du code produit sur les 470 tours locaux donne, à la borne de 16 alias, **183,95 µs p95/tour** et **521,39 µs au pire**. Les deux portes runtime sont respectées.

Les huit alias retenus réduisent la distance d’édition locale sur chaque fragment touché. Les **24** formes ambiguës ou non confirmées sont exclues, sans collision d’alias incluse. Exemples : `パリ`, `後期`, `清掃`, `10` et `X` resteraient de faux remplacements globaux ; `バーバート` et `隠れ赤ちゃん` contredisent leur référence locale chevauchante.

## Reproduction

```bash
WHISPERASR_E1A_QWEN=/Users/maz/Documents/projets/whisperASR-issue-26/.build/benchmarks/japanese-live/runs/e0-qwen-final-20260802T203033Z/live-replay.json Scripts/run_japanese_e1a_glossaries.sh
```

Artefacts : `.build/benchmarks/japanese-live/runs/e1a-glossaries-20260805T172702Z/`, ensemble SHA-256 `4aa4bfdafb6e4918cfcd19e70d4482cd48a7a41778e1b61ffb6ffa60f9875b7e`.

- Candidats : `0db41097994b3b6d1c8c05b2c26a79971e6ac07db819f7fc1487aa98009c73f2`.
- Sorties Qwen E0 : `b9e06277edb6c23d9b969f06f160a0a587dcb867255d593e7c17a6c7342f4658`.
- Manifests locaux : `qudu2fx3ncc` `a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b`, `md62mmdz0m` `9e2c828804457100b5f517ae84e1709a7b502837e36154ec4e7c7b5dc635e3bc`.
