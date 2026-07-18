# L1 — Oracle fiable

## Dépendances

L0.

## Objectif

Évaluer séparément l'ASR japonaise, le pipeline produit exact et les changements de voix. Une coupure produit peut traverser un tour humain; aucun rapport ne la reconstruit en recopiant des tours entiers.

## Hors-périmètre

- Comparer la qualité ASR avec des traductions anglaises.
- Simuler des frontières produit sur les tours humains.
- Promouvoir un moteur ou une diarisation.

## Fichiers touchés

- `Tests/JapaneseBenchmarkSupport.swift`
- `Tests/JapaneseModelBakeoffTests.swift`
- `Tests/JapaneseEnglishFullBakeoffTests.swift`
- `Tests/JapaneseOfflineEvaluationTests.swift`
- `Tests/LocalPrototypeBenchmarkTests.swift`
- `Scripts/run_japanese_english_bakeoff.sh`
- `Scripts/run_local_benchmark.sh`
- `docs/japanese-live/README.md`
- `docs/japanese-live/lots/L01-oracle.md`

## Évaluations indépendantes

| Vérité mesurée | Suite | Entrée autoritaire | Sortie |
| --- | --- | --- | --- |
| ASR pure | `JapaneseModelBakeoffTests` | tours humains + même PCM | CER, suppressions, termes critiques |
| Pipeline produit | `JapaneseOfflineEvaluationTests` | vrais métriques/ranges de l'app + même PCM | previews, finals, frontières, couverture, CER continu |
| Changements de voix | `DiarizationBakeoffTests` | événements temporels annotés | précision, rappel, faux splits, latence |

`JapaneseEnglishFullBakeoffTests` produit le rapport bilingue de jugement sur frontières humaines. Chaque item montre le japonais source, masque les moteurs avec des alias pseudo-aléatoires déterministes dérivés du SHA et sépare fidélité de naturalité. Le script complet refuse un rapport sans Human→Apple et tous les candidats; il ne transforme pas l'anglais en vérité ASR.

Le faux oracle H/H–H/P–V/H–V/P a été supprimé. Il exigeait une occurrence unique de chaque tour, puis intersectait les frontières communes : les vraies coupures internes du produit étaient donc rejetées ou masquées.

`JapaneseBenchmarkSupport` centralise seulement décodage et invariants de corpus pour trois suites. Les règles de scoring et de promotion restent locales à chaque bakeoff.

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

Tests ciblés : validation du manifeste partagé, ordre aveugle reproductible, couverture 59 tours, alias de tous les candidats disponibles et compilation après suppression de l'ancien oracle.

Résultat du 18 juillet 2026 : 220 tests exécutés, 22 tests opt-in ignorés, 0 échec.

## Preuves

- Aucune occurrence `QualityOracle` ou `WHISPERASR_QUALITY_ORACLE_*` ne reste dans `Tests/` ou `Scripts/`.
- Le rapport ASR conserve les frontières humaines.
- Le rapport produit conserve les vraies plages métriques et le CER continu, sans mapping synthétique.
- Les rapports aveugles contiennent le japonais source et des champs distincts `fidelityScore1To5` et `subtitleNaturalnessScore1To5`; la clé séparée conserve l'identité réelle.

## Décision

L1 est accepté quand la suite complète est verte. L2 peut créer les manifestes v2; aucun résultat actuel ne peut promouvoir un moteur car les holdouts ne sont pas validés humainement.

## Rollback

Revenir au commit L0. Aucun fichier produit n'a été modifié.
