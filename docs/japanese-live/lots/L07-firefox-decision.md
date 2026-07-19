# L7 — Firefox et décision

## Dépendances

L5 au commit `25ffa22` et L6 au commit `a7921fc`. Les références restent `pending-human-review`; L7 peut diagnostiquer et écarter, pas promouvoir la qualité.

## Objectif

Comparer Whisper Turbo et Kotoba Q5 dans le vrai flux `Firefox → ScreenCaptureKit → spool PCM → FireRedVAD → ASR → Apple preview/final`, sur les deux vidéos complètes fournies.

## Hors-périmètre

- Ajouter Kotoba aux options produit ou créer un runtime générique.
- Rejouer les moteurs déjà écartés.
- Présenter Apple Speech comme un avantage propre au modèle final : la preview est commune.
- Promouvoir un moteur avant validation humaine des corpus et réussite des SLO.

## Périmètre concret

- Un override du chemin Whisper, refusé hors `WHISPERASR_BENCHMARK=1`, permet au même binaire de charger le Q5 Kotoba épinglé.
- Quatre captures séquentielles à vitesse réelle : deux modèles × deux vidéos, soit environ 61,4 minutes. Microphone désactivé, profil japonais → anglais `adaptive` identique.
- Computer Use pilote Firefox, `Start Recording`, `Finish Recording`, la fermeture et le redémarrage de l'application.
- Un replay par couple modèle/corpus donne une décision technique provisoire, pas une promotion statistique. Les trois replays du stress pack restent obligatoires pour toute promotion ultérieure.
- Le binaire Release est construit une fois et attesté avec commit et SHA avant toute capture. Le sidecar fournit PTS ScreenCaptureKit, gaps/overlaps/restarts, origine de latence, FIFO, curseurs acceptés, erreurs finales, RSS toutes les 250 ms, modèle épinglé, WAV canonique et SHA du binaire. Le manifeste ajoute vidéo et identité Firefox.

## Fichiers touchés

- `Sources/AppState.swift`
- `Sources/AudioRecorder.swift`
- `Sources/LocalCaptionPipeline.swift`
- `Sources/ModelCatalog.swift`
- `Tests/LiveCaptionTests.swift`
- `Tests/AudioRecorderReliabilityTests.swift`
- `Tests/LocalBenchmarkTelemetryTests.swift`
- `Scripts/run_japanese_firefox_bakeoff.sh`
- `Scripts/run_japanese_offline_evaluation.sh`
- `Tests/JapaneseOfflineEvaluationTests.swift`
- cette fiche et l'index global

## Tests

- L'override Kotoba est inaccessible hors benchmark, refuse un candidat inconnu et valide le SHA épinglé.
- Le préchargement et les finales utilisent exactement la même sélection de modèle.
- L'évaluation Firefox accepte les deux manifestes v2 sans nombre de tours codé en dur.
- Chaque capture exige un spool PCM complet, zéro gap/overlap/restart PTS, FIFO et file de traduction vides, aucune erreur finale, et les curseurs japonais/anglais au-delà de la dernière annotation. Les drops M4A sont rapportés séparément : ils ne prouvent pas le PCM.
- Le moteur de session, le mode `adaptive` et le moteur de chaque métrique doivent correspondre au manifeste. Les futures captures ajoutent un index final séquentiel et refusent toute réécriture d'un sous-titre final.
- Latences preview/final, bornes du CER japonais primaire, dernière parole, RSS et erreurs sont séparés par modèle et corpus. L'agrégat refuse toute entrée modifiée et exige les quatre couples avec le même commit, binaire, Firefox et corpus épinglés.
- Mémoire : pic périodique ≤ 5 022 375 945 octets et < 10 Gio. Preview : couverture ≥ 95 %, p50 ≤ 1 s, p95 ≤ 1,8 s, pire ≤ 3 s. Final : p95 ≤ 1,5 s depuis la vraie fin de parole.
- Le CER primaire reste publié comme intervalle, jamais comme score exact : les insertions situées entre bandes ne peuvent pas être attribuées honnêtement. Le rapport reste forcé à `diagnostic-only` tant que les annotations, termes critiques, bootstrap apparié et deux juges bilingues manquent.

## Preuves

Sous `.build/benchmarks/japanese-live/runs/l7-firefox-<modèle>-<corpus>-<date>/` : manifeste, sidecar, métriques JSON/CSV, WAV ScreenCaptureKit, rapport japonais et revue anglaise aveugle. L'attestation du binaire vit sous `tools/l7-app-build.json`; le rapport agrégé possède son propre dossier daté.

Les quatre captures ont été produites au commit `ba62dc5`, avec le binaire `d2595262…c91147` et Firefox 152.0.6 `697e40e0…db2b9`. L'agrégat attesté est `.build/benchmarks/japanese-live/runs/l7-firefox-aggregate-20260719T194608Z/`; son entrée possède le SHA `007fb052…5c9a8b`.

La preuve sans réseau physique reste L10. L7 indique honnêtement que la vérification de révision et les services Apple peuvent utiliser le réseau. Les captures actuelles précèdent l'index final séquentiel : leur immutabilité est donc `non prouvée`, jamais supposée vraie.

## Décision

| Pipeline / corpus | Japonais | Preview anglaise | Final anglais | Pic mémoire |
|---|---:|---|---|---:|
| Turbo / `md62mmdz0m` | CER ≤ 28,61 % | couverture 45,20 %; p95 2,73 s | p95 2,57 s; qualité en attente | 3,61 Go |
| Kotoba Q5 / `md62mmdz0m` | CER ≤ 33,81 % | couverture 44,07 %; p95 2,84 s | p95 2,52 s; qualité en attente | 1,41 Go |
| Turbo / `qudu2fx3ncc` | CER ≤ 69,55 % | couverture 51,35 %; p95 2,28 s | p95 2,37 s; qualité en attente | 3,30 Go |
| Kotoba Q5 / `qudu2fx3ncc` | CER ≤ 50,92 % | couverture 55,86 %; p95 2,98 s | p95 2,21 s; qualité en attente | 1,05 Go |

Kotoba obtient une borne CER globale de 40,50 %, contre 44,62 % pour Turbo, soit 9,23 % d'amélioration relative. Ce résultat manque le gate de 10 %, s'inverse sur `md62mmdz0m`, n'a ni bootstrap valide ni termes critiques validés, et les deux pipelines ratent les SLO preview/final.

La preview Apple est commune aux deux candidats. Sa qualité et celle du final restent en attente de deux juges bilingues; aucune préférence anglaise n'est déduite des latences.

Verdict : aucune promotion et aucun gagnant produit. L8 n'est pas créé; le profil de développement reste Turbo sans ajouter Kotoba au produit.

## Rollback

Revenir au commit L6 `a7921fc`; les captures restent ignorées sous `.build`.
