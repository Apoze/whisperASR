# L7C — Deux vidéos complètes

## Dépendances

L7B au commit `4c30c4b`; recettes L7A SHA-256 `d4ed138de85c40fee4ae0340ceca39149fbc6e5331845377b4931dc5043f000a`.

## Objectif

Exécuter séquentiellement les onze recettes/pipelines ASR sur `qudu2fx3ncc` et `md62mmdz0m`, à 1×, avec le même PCM continu. Enregistrer séparément japonais, preview anglaise, final anglais, latence, RSS, CPU, thermique et backlog.

La matrice contient 22 sessions moteur : huit recettes dans le run principal — dont `whispermlx` long-form —, son second mode VAD-final, puis deux politiques WhisperLiveKit, le tout sur deux vidéos. Deux sessions Apple Speech communes et 470 traductions de contrôle sont mesurées à part.

## Hors-périmètre

- Classer définitivement les moteurs : réservé à L7D.
- Ajouter une dépendance ou un runtime au produit.
- Utiliser les tours humains comme frontières ASR.
- Tester Qwen 0.6B ou CoreML whisper.cpp : leurs gates d'entrée ne sont pas atteints. L'XCFramework épinglé ne contient pas l'asset CoreML exact.

## Fichiers touchés

- `Scripts/japanese_external_asr.py`
- `Scripts/run_japanese_l7c_replay.sh`
- `Scripts/aggregate_japanese_l7c.py`
- `Scripts/run_japanese_live_replay.sh`
- `Scripts/verify_japanese_corpora.sh`
- supports et suites sous `Tests/`

## Tests

- Préflight `whispermlx` VAD : quatre fenêtres × trois replays.
- Deux vidéos complètes pour chaque candidat, modèle chargé une fois.
- `whispermlx` long-form et VAD-final restent deux lignes distinctes.
- Voxtral garde une session par vidéo et utilise `VoxtralClausePlanner`.
- Nemotron publie ses partiels et ne reset qu'aux fins VAD sûres.
- Apple preview commune; finales Apple FIFO append-only avec trois essais maximum.
- WhisperLiveKit : rétention 1 200 s, timeout après EOF et watchdog backlog.
- Contrôle traducteur : 470 tours japonais humains → Apple highFidelity.
- RSS et CPU mesurés par session, y compris le helper Voxtral ou le processus Python.
- Runtime recalculé après chaque étape; toute dérive arrête le lot.

## Preuves

Les deux captures Firefox/ScreenCaptureKit de L7 prouvent le chemin réel et l'alignement avec le PCM canonique : `l7-firefox-turbo-qudu2fx3ncc-20260719T182555Z` et `l7-firefox-turbo-md62mmdz0m-20260719T190903Z`. L7C rejoue ce PCM identique à 1× afin qu'un changement de moteur ne change jamais l'entrée.

Le sandbox interdit le réseau distant aux processus ASR et XCTest mesurés. Il ne prouve pas qu'un service système Apple n'utilise jamais le réseau : la preuve physique hors connexion reste prévue en L10.

La preuve de clôture sera `l7c-aggregate-<stamp>/comparison.json`, accompagnée de `ja-asr.json`, `en-preview.json` et `en-final.json`. L'agrégateur recalcule aussi les SHA de la capture PCM, des métriques, de la vidéo, du modèle, de Firefox et de l'attestation de build historiques.

Les suites ciblées Release passent. La suite globale rencontre toujours le crash d'ordre MLX/Metal déjà connu dans `testAsyncDeadlineDoesNotWaitForNonCooperativeWork`; le test isolé passe immédiatement.

## Décision

Terminé au run `20260721T173540Z` : 22/22 sessions moteur, 2/2 previews Apple et 470/470 traductions humaines ont été tentées. Les erreurs qualité ont été conservées sans arrêter la matrice. SimulStreaming et LocalAgreement ont été interrompus uniquement après un backlog supérieur à 30 secondes pendant une minute, conformément au protocole.

Preuves de clôture : `.build/benchmarks/japanese-live/runs/l7c-aggregate-20260721T173540Z/`. La matrice est tentée intégralement mais non promotable : plusieurs moteurs perdent de la parole, dépassent les SLO ou échouent à traduire. Le classement appartient à L7D.

## Rollback

Revenir au commit L7B `4c30c4b`; les modèles et sorties sous `.build` restent hors Git.
