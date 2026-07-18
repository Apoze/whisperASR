# L2 — Corpus holdout

## Dépendances

L1.

## Objectif

Versionner quatre manifestes v2 sans chemin absolu, vérifier leurs WAV par SHA-256 et rendre impossible une promotion avant validation humaine.

## Hors-périmètre

- Inventer des plages PCM, locuteurs ou termes critiques absents des preuves.
- Déclarer une annotation `complete` sans signataire humain.
- Promouvoir un moteur ASR.

## Fichiers touchés

- `docs/japanese-live/corpora/*/manifest.json`
- `Tests/JapaneseBenchmarkSupport.swift`
- `Tests/DiarizationBakeoffTests.swift`
- `Tests/JapaneseModelBakeoffTests.swift`
- `Tests/JapaneseEnglishFullBakeoffTests.swift`
- `Tests/JapaneseOfflineEvaluationTests.swift`
- `Scripts/prepare_japanese_bakeoff.sh`
- `Scripts/verify_japanese_corpora.sh`
- `Scripts/run_japanese_bakeoff.sh`
- `Scripts/run_japanese_english_bakeoff.sh`
- `Scripts/run_japanese_offline_evaluation.sh`
- `Scripts/run_voxtral_configuration_bakeoff.sh`

## État des corpus

| Corpus | Usage | Contenu exploitable | État |
| --- | --- | --- | --- |
| `easy-japanese-1` | dev | 59 tours, 57 transitions | `pending-human-review` |
| `kikusasaizu-l1-1` | dialogue holdout | 14 tours bilingues et 13 transitions dérivées des captions | `pending-human-review` |
| `okkei-shun-1541-1711` | podcast holdout | 25 phrases en attente, aucun faux tour créé | `incomplete` |
| `interview-speakers-0245-0325` | changements de voix | 14 tours alignés et une transition indépendamment étayée | `incomplete` |

Chaque tour présent porte une plage PCM, un locuteur, le japonais, l'anglais facultatif, une confiance et `criticalTerms`. Les listes de termes critiques restent vides plutôt que d'enregistrer des heuristiques ambiguës comme vérité humaine.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter JapaneseBenchmarkSupportTests
Scripts/verify_japanese_corpora.sh
bash -n Scripts/prepare_japanese_bakeoff.sh Scripts/verify_japanese_corpora.sh Scripts/run_japanese_bakeoff.sh Scripts/run_japanese_english_bakeoff.sh Scripts/run_japanese_offline_evaluation.sh Scripts/run_voxtral_configuration_bakeoff.sh
```

Les quatre manifestes décodent avec le support partagé. Le test affirme qu'aucun n'est promotionnel. Le préflight local vérifie le SHA-256, l'en-tête audio et le nombre d'échantillons des quatre WAV. Le bakeoff voix consomme désormais les mêmes événements v2 que les autres évaluations.

Résultat du 18 juillet 2026 : 222 tests exécutés, 23 tests opt-in ignorés, 0 échec. Le préflight séparé des quatre WAV passe également.

## Preuves

- Easy : `64ee5d98f5db01497d6b13354a17d4d0ba43776ae31699d7c73bb8b0c019c07c`, 4 523 613 échantillons.
- Kikusasaizu : `768e2e9d7334d58419e9397885044a634f4a7aff7f7343904c5ab07b53b91e89`, 944 000 échantillons.
- Okkei : `b28b70bd19ff437df53c829f0c06674672effa3709435e5ac7bea46c4bfbfb5d`, 1 440 000 échantillons.
- Interview : `8394cb66fb693d9d9b3c50d47c42d6f34086850fc6d475681e4f999f478cf80a`, 640 000 échantillons.

## Décision

La structure L2 est prête, mais le résultat attendu n'est pas atteint : aucun corpus n'a de validation humaine formelle et deux holdouts sont incomplets. Toute mesure L3 reste exploratoire; L4 est bloqué.

Pour débloquer la gate, il faut faire relire le waveform, les plages, locuteurs et termes critiques, compléter Okkei et Interview, puis renseigner `reviewedBy`, `reviewNote` et `annotations.status=complete`.

## Rollback

Revenir au commit L1. Les WAV restent dans `.build/` et aucun fichier produit n'est modifié.
