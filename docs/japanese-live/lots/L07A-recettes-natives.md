# L7A — Recettes natives

## Dépendances

L7 au commit `5f99f65`. Les résultats L3, L5 et L6 restent des diagnostics, car plusieurs moteurs stateful ont été redémarrés sur des tours humains.

## Objectif

Figer une recette reproductible et adaptée au rôle réel de chaque candidat avant tout nouveau classement.

## Hors-périmètre

- Ajouter un moteur au produit.
- Modifier les gates qualité.
- Activer le full-MLX expérimental de SimulStreaming, l'alignement ou la diarisation.

## Fichiers touchés

- `docs/japanese-live/model-recipes.json`
- `Scripts/build_whisper_lib.sh`
- `Tests/JapaneseModelRecipeTests.swift`
- l'index et cette fiche

## Tests

- Le manifeste contient exactement les dix recettes prévues et les constantes produit FireRedVAD.
- Voxtral conserve une session par capture; Nemotron ne reset qu'après une fin VAD sûre.
- MLX direct est déterministe; `whispermlx` garde alignement et diarisation désactivés.
- WhisperLiveKit sépare SimulStreaming hybride et LocalAgreement MLX.
- La bibliothèque embarquée est whisper.cpp 1.8.3, Metal activé, CoreML absent.
- Le script de reconstruction épingle le commit exact de whisper.cpp.

## Preuves

Le manifeste L7A avait le SHA-256 `64e1b57d07bea60386f3d1605d6994ce559d08e70eefa6a2269ec76743e6c2be`. L7B l'étend sous une nouvelle empreinte pour épingler les assets FireRedVAD et tracer le calibrage de décodage; l'ancienne empreinte reste ici la preuve historique de L7A. Le test opt-in a vérifié les fichiers et arbres locaux de Whisper, Kotoba, Voxtral, Nemotron, Qwen, MLX et WhisperLiveKit. La suite standard passe : 239 tests, 26 opt-in ignorés, aucun échec.

## Décision

Terminé. L7B doit utiliser ces recettes et ne peut plus découper l'entrée sur les tours humains. Whisper.cpp est figé à 1.8.3/`2eeeba56…`; son fallback de température est désactivé. WhisperLiveKit utilise son VAC réel, des réponses différentielles bornées et sépare ses deux politiques. Le contrôle CoreML/ANE reste conditionnel, car la bibliothèque courante est Metal-only.

## Rollback

Revenir à `5f99f65`; aucun réglage produit ni modèle local n'est modifié.
