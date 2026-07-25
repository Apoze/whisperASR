# L8A — Diagnostic Voxtral fiable

## Dépendances

L7D au commit `e51d150`. La décision utilisateur retient Voxtral Q4/960 comme
direction de développement malgré l'absence de promotion automatique.

## Objectif

Rejouer les deux vidéos réelles sans changer le comportement produit et
séparer les erreurs de l'ASR, des frontières et d'Apple Translation.

## Hors-périmètre

- Récupérer la dernière parole.
- Modifier les frontières, le délai Voxtral ou la cadence des previews.
- Ajouter un moteur, une dépendance ou une abstraction produit.

## Fichiers touchés

- Le harness Voxtral existant dans `Tests/JapaneseModelBakeoffTests.swift`.
- Un test opt-in de diagnostic Apple si les quatre niveaux ne peuvent pas être
  dérivés du rapport existant.
- `docs/japanese-live/README.md` et cette fiche.

## Tests

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
/usr/bin/python3 Scripts/report_voxtral_l8a.py --self-test
WHISPERASR_L8A_STAMP=20260725T134600Z Scripts/run_voxtral_l8a.sh
```

La suite standard passe : 253 tests, 29 opt-in ignorés, aucun échec. Les deux
replays Q4/960 complets et le diagnostic à quatre niveaux se terminent sans
échec de test.

## Preuves

- Rapport simple :
  `.build/benchmarks/japanese-live/runs/l8a-voxtral-diagnostic-20260725T134600Z/report-fr.md`.
- Baseline L7C SHA-256 :
  `647a4ac4985d3ff95ba3df288c98da9a20971a6b72fd9a7d95d949a59c9e6b8d`.
- Rapport natif SHA-256 :
  `3ba48d6851cee09c466bbd61b455c7ff275b57c50610d43ea9e918c6ef40a6be`.
- Diagnostic Apple SHA-256 :
  `44f565df2dccbf3c7a95ff01e1cdc046b55c0441f20e62c22e768d9adf3f0792`.
- Comparaison SHA-256 :
  `c820c89c1dd8ea5364e8479bb28f500e3a55324dc5cde6c9a4688678a6e84d2d`.
- Générateur du rapport SHA-256 :
  `151c1777b70b4f2d009d9ed42b80b49d295eaecad34d51f629c92b4c475d23e1`.
- Source mesurée : commit `e51d150`, arbre
  `287ccf0be9cea9b1c38dc9318c4bfdd8da397ada1fecd80714632e67f98baf9e`,
  recette
  `d4ed138de85c40fee4ae0340ceca39149fbc6e5331845377b4931dc5043f000a`.
- CER reproduit exactement : 82,0 % sur `qudu2fx3ncc`, 19,3 % sur
  `md62mmdz0m`.
- PCM accusé à 100 %, backlog final nul, thermique nominal.
- RSS agrégé maximal : 6,01 Gio sur `qudu`, 4,41 Gio sur `md62`.
- Preview source Voxtral p95 : 6,28 s sur `qudu`, 3,88 s sur `md62`;
  Apple lowLatency p95 : 74,7 ms et 65,2 ms.
- Finalisation source après la dernière parole : 2,47 s sur `qudu`, 7,88 s
  sur `md62`. Les finales Apple acceptées restent à environ 1,04 s au p95.
- Apple highFidelity séparé : japonais humain/frontières humaines, couverture
  100 %, p95 94,7 ms, chrF++ diagnostic 53,8.

Les contre-revues subagents protocole, exactitude et simplicité, après lecture
de `ponytail` et `code-structure`, ne trouvent plus de blocage.

## Décision

Gate L8A passé.

Sur `qudu`, la dernière parole VAD finit à l'échantillon `15 282 880`, mais le
dernier delta Voxtral s'arrête à `13 120 000`, soit environ 135,2 secondes de
timeline contenant de la parole sans nouveau texte. Le helper accuse pourtant
le PCM complet.
Sur `md62`, le dernier delta (`14 062 080`) couvre la dernière parole
(`14 059 040`).

La cause de la dernière phrase absente est donc Voxtral/finalisation, pas la
capture ni Apple Translation. La latence de preview vient elle aussi presque
entièrement de Voxtral. L8B peut utiliser cet écart mesuré comme gate d'entrée.
Les 74 frontières forcées dégradées observées confirment aussi le besoin de L8C
après la récupération de fin.

Le découpage diagnostique distribue temporellement les caractères après le
replay et compare chaque sortie complète à la référence anglaise du corpus,
utilisée une seule fois. Il conserve exactement les caractères utiles :
`7 986` pour le japonais humain et `6 109` pour Voxtral, quelle que soit la
frontière. Cette approximation ne pilote jamais l'ASR.

## Rollback

Supprimer les champs de diagnostic ajoutés au rapport et restaurer l'index.
Les preuves sous `.build` restent régénérables et ignorées par Git.
