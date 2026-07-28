# L8B3 — Rotation Voxtral produit

## Dépendances

L8B2 au commit `1d52f3a`.

## Objectif

Renouveler la session Voxtral toutes les 720 secondes, à la première pause
FireRedVAD sûre, sans interrompre la capture ni perdre de PCM.

## Hors-périmètre

- Modifier les frontières de sous-titres ou Apple Translation.
- Ajouter un réglage utilisateur, un moteur ou une abstraction générique.
- Traiter la latence des previews, réservée à L8D.

## Fichiers touchés

- `Sources/AppState.swift`
  - rotation à partir de 720 s, uniquement sur une pause FireRedVAD ;
  - même processus helper, nouvelle session ASR ;
  - continuité des curseurs PCM et récupération unique inchangée ;
  - fermeture sûre si `Finish` arrive avant, pendant ou après la rotation.
- `Sources/LocalCaptionPipeline.swift`
  - télémétrie par session Voxtral.
- `Tests/LiveCaptionTests.swift`
- `Tests/LocalBenchmarkTelemetryTests.swift`
- `Tests/JapaneseOfflineEvaluationTests.swift`
- `Tests/JapaneseModelRecipeTests.swift`
- `Scripts/validate_voxtral_product_run.py`
- `docs/japanese-live/model-recipes.json`

## Tests

- Tests unitaires de la frontière de rotation et de la requalification d'une
  rotation concurrente avec `Finish`.
- Suite `JapaneseOfflineEvaluationTests`, dont validation du pipeline
  `voxtralApple` et de ses sessions contiguës.
- Deux captures Release réelles, Firefox 1× et ScreenCaptureKit :
  - `qudu2fx3ncc` ;
  - `md62mmdz0m`.
- Validateur standard-library :
  - SHA des sources avant/après le build et SHA du binaire ;
  - Firefox, vidéo, manifeste, recette, modèle et runtime épinglés ;
  - WAV float mono 16 kHz et nombre exact d'échantillons ;
  - aucune discontinuité PTS ;
  - même PID helper, ACK exact, backlog final nul ;
  - dernier tour annoté couvert par les curseurs produit.
- Attestation des résultats :
  - SHA du rapport d'évaluation ;
  - SHA de l'oracle Swift ;
  - SHA réel de l'arbre modèle Voxtral chargé.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`.
- `Scripts/build_release.sh`.

## Preuves

Les résultats automatiques restent diagnostiques car les références sont
`pending-human-review`.

| Corpus | Sessions | Rotation | Dernière parole | CER | Preview p95 | Final p95 | RSS max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `qudu2fx3ncc` | 2 | 721,18 s | 100 % | 61,96 % | 6,26 s | 1,57 s | 4,28 Gio |
| `md62mmdz0m` | 2 | 737,83 s | 100 % | 20,58 % | 3,44 s | 1,62 s | 4,27 Gio |

Dans les deux runs :

- `validation.json` est `passed` ;
- `evaluation-attestation.json` est `passed` ;
- l'arbre modèle chargé correspond au SHA épinglé
  `178e8cd18ffe0e6788504cac1146bbc0c0eafb262acecd24aa63c0e863333d86` ;
- le PID helper reste identique entre les sessions ;
- les plages de sessions sont contiguës et couvrent tout le PCM ;
- le premier ACK égale exactement la fin de rotation ;
- le dernier ACK égale exactement la fin du WAV ;
- les files de fin et le backlog helper sont nuls ;
- la rotation conserve au moins 500 ms après la dernière parole VAD.

Preuves locales :

- `.build/benchmarks/japanese-live/runs/l8b3-firefox-voxtral-qudu-r4-20260728T173000Z/`
- `.build/benchmarks/japanese-live/runs/l8b3-firefox-voxtral-md62-r1-20260728T175200Z/`

720 secondes est une cible, pas une coupure forcée. Sans pause sûre, la session
continue, même plus de 60 secondes après la cible. Cette attente protège les
paroles et ne bloque pas la capture.

## Décision

Retenu. La rotation produit évite les longues sessions Voxtral sans recharger
le modèle et sans perdre de PCM.

Ce lot ne valide pas encore l'application finale : la preview et le final
manquent les SLO. L8C traite les frontières japonaises, puis L8D la latence.

## Rollback

Retirer la boucle de rotation et revenir à une session Voxtral continue
unique ; le spool PCM reste l'autorité.
