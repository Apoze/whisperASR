# L3 — Bakeoff ASR

## Dépendances

L1. L2 est requis pour promouvoir un moteur, mais ses corpus ne sont pas encore validés humainement.

## Objectif

Comparer séquentiellement Whisper Large v3 Turbo, Voxtral Q4/960 et Nemotron Core ML 1120/560 sur les mêmes plages PCM réelles, avec provenance, CER apparié, suppressions, omissions, latence de calcul et mémoire observée.

## Hors-périmètre

- Ajouter un runtime Nemotron au produit.
- Présenter le temps de calcul offline comme une latence de preview anglaise.
- Promouvoir un moteur avec des corpus ou termes critiques non validés.
- Créer un pipeline hybride.

## Fichiers touchés

- `Sources/ModelCatalog.swift`
- `Tests/JapaneseBenchmarkSupport.swift`
- `Tests/JapaneseEnglishFullBakeoffTests.swift`
- `Tests/JapaneseModelBakeoffTests.swift`
- `Scripts/prepare_japanese_bakeoff.sh`
- `Scripts/run_japanese_bakeoff.sh`
- `Scripts/run_japanese_english_bakeoff.sh`
- `docs/local-prototype-licenses.md`
- `docs/japanese-live/README.md`
- `docs/japanese-live/lots/L03-bakeoff-asr.md`

## Protocole

- Ordre fixe : Whisper, Voxtral, Nemotron 1120, Nemotron 560; jamais deux moteurs en même temps.
- FluidAudio 0.15.5 est appelé directement en `ja-JP`. Le modèle est chargé une fois, puis réinitialisé pour chaque tour humain.
- Voxtral est obligatoirement Q4/960. Une liste de moteurs vide, inconnue, dupliquée ou hors ordre est refusée.
- Les rapports sont écrits dans `.build/benchmarks/japanese-live/<run-id>/` et contiennent commit, état du worktree, SHA manifeste/audio/modèle, licence, configuration, couverture d'entrée PCM, textes, timings et bootstrap apparié. Les APIs testées n'exposent pas de curseur PCM consommé/finalisé; le rapport le dit explicitement.
- Les SHA d'arbres sont calculés sur les chemins relatifs et le contenu de tous les fichiers visibles, dans un ordre déterministe.
- `WHISPERASR_OFFLINE=1` force FluidAudio ModelHub, Hugging Face et `uv` en mode offline avec les assets locaux. La preuve d'absence totale de trafic réseau reste réservée à L7.

## Entrées réelles épinglées

- Vidéo `Easy Japanese 1 - Typical Japanese.mp4` : SHA `6b6fee800edaf8fe5ffea029f673b37e04b648cd24aaa779c1c53dc9446b2667`.
- Japonais `transcription_japonaise_avec_locuteurs.zip` : SHA `1da9a9d3d2d41455eef067cee3a57d8c0ea7aca9c0a33291347e492a1ae238c1`.
- Anglais `english_transcript_with_speakers.zip` : SHA `721be7072dd9eca908a17099c077115e37b73851d8dcedce3c102ba23dbdc12f`; ses 59 tours sont alignés et vérifiés, mais ne scorent pas l'ASR.

Le WAV canonique dérivé de la vidéo est vérifié par SHA `64ee5d98f5db01497d6b13354a17d4d0ba43776ae31699d7c73bb8b0c019c07c`. La vidéo n'était plus présente au chemin Downloads indiqué lors de la clôture; une reconstruction complète demandera de la remettre, mais les runs utilisent bien son WAV canonique déjà produit.

## Résultats exploratoires

Corpus dev `easy-japanese-1`, 59 tours, exécution Release avec ModelHub et dépendances en mode offline, assets locaux :

| Moteur | CER haute confiance | Tours vides / 59 | p95 calcul ASR | RSS observée max |
| --- | ---: | ---: | ---: | ---: |
| Whisper Turbo | 27,83 % | 0 | 1 158 ms | 3,20 Go |
| Voxtral Q4/960 | 31,25 % | 11 | 7 138 ms | 3,83 Go |
| Nemotron 1120 | 34,33 % | 21 | 417 ms | 0,81 Go |
| Nemotron 560 | 36,47 % | 19 | 624 ms | 0,83 Go |

Les deux Nemotron perdent la dernière parole du corpus. Le bootstrap apparié face à Whisper donne une amélioration relative observée négative : Voxtral −12,31 %, Nemotron 1120 −23,38 %, Nemotron 560 −31,08 %. Aucun challenger ne passe la gate qualité.

Deux holdouts incomplets confirment le risque sans pouvoir promouvoir :

- Kikusasaizu, 14 tours non vérifiés : CER exploratoire 11,43 % Whisper, 8,57 % Voxtral, 23,43 % Nemotron 1120, 29,71 % Nemotron 560.
- Interview, 14 tours : CER haute confiance 15,38 % Whisper, 39,23 % Voxtral, 33,85 % Nemotron 1120, 32,31 % Nemotron 560. Whisper ne produit aucun tour vide; les autres en produisent quatre ou cinq.
- Okkei n'a encore aucun tour annoté exploitable : aucun score n'est inventé.

Ces p95 mesurent une transcription offline par tour et les RSS sont des relevés après chaque tour, pas des pics continus. Ils ne prouvent ni la preview anglaise, ni le final stable, ni le backlog produit.

## Preuves

- Rapport dev post-commit : `.build/benchmarks/japanese-live/l03-final-easy/`
- Rapport dialogue post-commit : `.build/benchmarks/japanese-live/l03-final-kikusasaizu/`
- Rapport voix rapides post-commit : `.build/benchmarks/japanese-live/l03-final-interview/`
- Whisper : révision `5359861c739e955e79d9a303bcbc70fb988958b1`, SHA `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
- Voxtral : révision `12091661ce5f58788624fa49fad9ddbbf67cf063`, arbre `178e8cd18ffe0e6788504cac1146bbc0c0eafb262acecd24aa63c0e863333d86`.
- Nemotron : révision observée `1a41b75758b0337ff67db7d5408280aaaf23074e`; arbres 1120 `a398b4fb9d1818395934191c7301571f6a958b8ad2a82e670029da38bd3efae9`, 560 `ad9a4c88796e765d60e304d36ae2688b914835447203f44af92056212cfc340d`.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter JapaneseModelBakeoffTests
WHISPERASR_OFFLINE=1 Scripts/run_japanese_bakeoff.sh full
```

Résultat de clôture : 225 tests exécutés, 24 tests opt-in ignorés, 0 échec. Le préflight SHA/audio des quatre corpus passe. Les trois bakeoffs ASR sont rejoués avec `WHISPERASR_OFFLINE=1` après le téléchargement initial et après le commit L3.

## Décision

Aucun challenger n'est promu. Nemotron est rapide mais perd trop de parole; Voxtral régresse en qualité et en temps de calcul sur le corpus dev. Le chemin produit existant reste inchangé, sans hybride. L4 ne démarre pas tant que L2, les termes critiques et les gates produit anglais ne sont pas établis.

## Rollback

Revenir au commit L2. Les modèles et rapports restent sous `.build/`, hors Git; aucun runtime produit Nemotron n'a été créé.
