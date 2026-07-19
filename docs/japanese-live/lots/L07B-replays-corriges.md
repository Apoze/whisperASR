# L7B — Replays corrigés

## Dépendances

L7A au commit `b0e1f04`. L7B utilise le manifeste correctif SHA-256 `d4ed138de85c40fee4ae0340ceca39149fbc6e5331845377b4931dc5043f000a`, qui ajoute les SHA FireRedVAD et une calibration de décodage sur un extrait dev séparé.

## Objectif

Rejouer trois fois les quatre fenêtres difficiles continues avec chaque recette native, sans utiliser les tours humains comme frontières ASR.

## Hors-périmètre

- Les deux vidéos complètes, réservées à L7C.
- Ajouter un moteur au produit.
- Utiliser les références pour découper l'audio.

## Fichiers touchés

- `Scripts/japanese_external_asr.py`
- `Scripts/run_japanese_l7b_replay.sh`
- `Scripts/run_japanese_live_replay.sh`
- `Scripts/aggregate_japanese_l7b.py`
- `Scripts/source_tree_provenance.py`
- `Scripts/runtime_provenance.py`
- `Sources/LocalEnglishModels.swift`
- `Sources/TranscriptionService.swift`
- les supports et suites de benchmark japonais sous `Tests/`
- `docs/japanese-live/model-recipes.json`

## Tests

- Une session continue par fenêtre pour Voxtral et WhisperLiveKit.
- FireRedVAD produit partagé pour les moteurs à finales par phrase.
- Trois replays identiques, modèle chargé une fois, exécution séquentielle.
- Couverture PCM, dernière parole, CER continu, latence, RTF, RSS et backlog enregistrés.

## Preuves

Les smoke tests corrigés prouvent déjà la couverture PCM complète de Voxtral et des deux politiques WhisperLiveKit. La preuve de clôture sera `l7b-aggregate-<stamp>/comparison.json`, qui exige les 120 clés uniques, les mêmes SHA corpus/recette/sources et le réseau bloqué.

## Décision

En validation. Aucun candidat ne passe à L7C avant une matrice `matrixAttempted=true`; `matrixComplete` reste séparé pour ne pas masquer les échecs réels des moteurs.

## Rollback

Revenir à `b0e1f04`; les sorties sous `.build` sont ignorées par Git.
