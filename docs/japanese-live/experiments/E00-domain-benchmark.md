# E00 — taxonomie et benchmark par domaine

Date : 2026-08-02. Machine : macOS 26.5.2 (25F84), Swift 6.3.3. Baseline mesurée sur le commit propre `7b1578e404b1f13c86413d09dd5029f299816493`, arbre source `bc01f4dad7c4fcdae64674625898817fc682a1eaa67ec2eb430ff33a5c566f09`.

## Décision

Le benchmark E0 est figé et reproductible avec `Scripts/run_japanese_e0.sh`. Il mesure le pipeline `qwenApple` fixé par la carte : FireRed `0,40 / 350 / 500 ms`, preview Apple Speech sans hints, final Qwen 1.7B puis glossaire VSPO déterministe et Apple highFidelity.

Il est autoritaire seulement comme diagnostic VTuber × Gaming / Conversation. Il ne peut pas promouvoir Anime : aucune référence Anime locale n'existe. Les références ne donnent pas non plus l'identité des chaînes, donc un holdout indépendant par chaîne n'est pas prouvable.

L'unité appariée est la vidéo complète, avec les mêmes tours fournis pour chaque candidat. Les résultats `high` hors overlap sont primaires; `medium/low`, overlap, anglais, négations, nombres et réponses courtes restent diagnostiques. Aucun retuning n'est permis après ouverture d'une vidéo.

## Corpus et baseline

| Domaine | Corpus | Tours | CER japonais primaire | chrF++ final | Preview p95 | Final p95 |
|---|---|---:|---:|---:|---:|---:|
| VTuber × Gaming | `qudu2fx3ncc` | 199 | 60,5–72,1 % | 46,3 | 1 637 ms | 1 801 ms |
| VTuber × Conversation | `md62mmdz0m` | 271 | 24,7–26,0 % | 50,4 | 1 634 ms | 1 385 ms |
| Anime | aucun | 0 | n/a | n/a | n/a | n/a |

Global : CER primaire 38,7–44,1 %, preview p50/p95/pire `1 141 / 1 637 / 4 244 ms`, final p95 `1 487 ms`, chrF++ final 52,9. Le glossaire a modifié 0/288 fragments; textes ASR brut, corrigé et final sont conservés séparément. Les termes critiques restent non scorables car les manifests en contiennent zéro.

## Taxonomie automatique

| Erreur | Signal | Condition d'attribution |
|---|---|---|
| `asr-substitution` | substitutions du traceback CER | PCM, référence et frontières valides |
| `asr-deletion` | suppressions ou final vocal vide | endpoint et fin audio valides |
| `asr-insertion` | insertions certaines et ambiguës de frontière séparées | timing de référence valide |
| `translation-lexical` | chrF++ global et réponses courtes | référence anglaise fournie; diagnostic seulement |
| `translation-polarity-or-number` | rappel des négations et nombres | source japonaise correcte |
| `preview-missing-or-late` | couverture, p50, p95, pire | horloge et source du runner valides |
| `tail-or-pcm-loss` | curseurs PCM, dernière parole, FIFO, backlog final | provenance build/entrée valide |
| `runtime-resource` | RSS, CPU, thermique, backlog, erreurs | reproduction sur contrôle du même build |

Les erreurs primaires dominantes sont 906 insertions, 681 substitutions et 245 suppressions. Gaming porte 694 insertions contre 212 en Conversation : le domaine bruyant est nettement le principal risque ASR.

## Gates et causes racines

| Gate | Résultat | Cause racine |
|---|---|---|
| Preview | échec | Apple Speech fournit la source à `1 122 / 1 617 / 4 222 ms` p50/p95/pire; Apple lowLatency n'ajoute que `21 / 31 / 46 ms`. La latence vient donc de la jambe Apple Speech, pas de la traduction. |
| Final | échec | Sur Gaming, Qwen atteint 8,27 s de calcul par fragment et 8,33 s de backlog; sa source est déjà à 1 509 ms p95 avant les ~261 ms p95 d'Apple highFidelity. |
| Mémoire | échec | Le process Qwen/MLX atteint 9,62 Go (8,96 Gio), soit 2,30× le baseline L0 et au-dessus de sa marge +20 %. Le replay Apple seul culmine à 0,27 Go; le thermique reste nominal. |
| Intégrité | échec | PCM complet, dernière parole présente et backlog final nul sur 2/2 vidéos. Un fragment Conversation Qwen bruité déclenche toutefois une traduction Apple répétitive rejetée, créant un trou de continuité final. |

Le fragment fautif contient des variantes répétées de `ちゃっかりうさぎ`. Sur sessions Apple fraîches, le voisin sain passe 3/3; le fragment fautif produit 3/3 exactement la même queue anglaise répétée huit fois, rejetée par `SubtitleRepetitionDetector`. Ce n'est ni un incident Apple transitoire ni une perte PCM : c'est une interaction déterministe source Qwen corrompue → dégénérescence Apple final.

## Échecs de runner diagnostiqués

Aucun de ces échecs n'a été attribué au candidat :

1. `e0-evidence-20260802T201041Z` : vérificateur global demandant les anciens corpus absents du worktree propre; préflight restreint aux deux corpus E0.
2. `e0-evidence-20260802T201928Z` : audit global demandant des modèles historiques hors périmètre; E0 vérifie directement les SHA Qwen et FireRed.
3. `e0-evidence-20260802T202109Z` : calibration `easy-japanese-1` chargée sans condition alors que Qwen ne la consomme pas; préparation rendue conditionnelle aux moteurs concernés.
4. `e0-evidence-20260802T203033Z/apple-replay.log` : choix du port via le Python WhisperLiveKit pour un run Apple-only; allocation déplacée vers `/usr/bin/python3`.

Le probe causal complet est conservé dans `e0-evidence-20260802T203033Z/apple-final-probe.log`.

## Artefacts et reproduction

- Rapport : `.build/benchmarks/japanese-live/runs/e0-decision-final-20260802T203033Z/`.
- Qwen : `.build/benchmarks/japanese-live/runs/e0-qwen-final-20260802T203033Z/`.
- Apple : `.build/benchmarks/japanese-live/runs/e0-apple-preview-20260802T203033Z/`.
- Échecs bruts : les quatre dossiers `e0-evidence-*` cités ci-dessus.
- Ensemble brut : 65 fichiers, SHA-256 `bac6b8b6ecaaecd60307d39cae0aa6dfe279ff3884f4d8e3fbe3731a066a8cc5`.

```bash
Scripts/run_japanese_e0.sh
```

Le runner refuse un worktree sale, vérifie tous les SHA, bloque le réseau externe, conserve les corpus et sorties brutes, puis génère `benchmark.json`, `report-fr.md` et `artifact-manifest.json`.
