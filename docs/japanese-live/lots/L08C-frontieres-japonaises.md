# L8C — Frontières japonaises

## Dépendances

L8B3 au commit `5304bfc`.

## Objectif

Produire des clauses japonaises sûres pour Apple Translation sans perdre de
PCM ni transformer une preview instable en finale.

## Hors-périmètre

- Changer de moteur ASR ou de traducteur.
- Optimiser Q4/480 ou le throttle des previews.
- Ajouter une diarisation produit.

## Fichiers touchés

- `Sources/VoxtralClausePlanner.swift`
  - gate de calibration marqueur resserré de 240 à 200 ms ;
  - fallback 15 s testé puis retiré.
- `Sources/VoxtralMarkerCalibrationProof.swift`
  - preuve de validation alignée sur 200 ms.
- `Tests/VoxtralClausePlannerTests.swift`
  - assertion littérale du gate à 3 200 échantillons.
- `docs/japanese-live/README.md`.
- `docs/japanese-live/lots/L08C-hard-fallback-15s.patch`
  - patch exact du candidat rejeté, applicable sur `5304bfc`.

## Tests

- Candidat :
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter 'VoxtralClausePlannerTests|VoxtralMarkerCalibrationProofTests'`
  — 50 tests, 0 échec.
  Journal SHA-256 :
  `8e2d65c5185b040a28953a2cbcfefa6983bc665772e45a6658f30f2cb02e5783`.
- Après rollback : même commande — 49 tests, 0 échec.
- Suite complète : 256 tests, 0 échec, 29 opt-in ignorés.
- Build Release signé réussi.
- Deux captures Release réelles, Firefox 1× et ScreenCaptureKit.
- Validateur d'intégrité produit et attestation de l'oracle sur chaque run.
- Comparaison avec les deux runs L8B3 épinglés.

## Preuves

| Corpus | CER L8B3 | CER 15 s | Dégradées/min L8B3 | Dégradées/min 15 s | Preview p95 15 s | Final p95 15 s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `qudu2fx3ncc` | 61,96 % | 61,36 % | 2,63 | 2,01 | 6,71 s | 1,67 s |
| `md62mmdz0m` | 20,58 % | 20,90 % | 2,78 | 1,76 | 4,32 s | 1,62 s |

Le taux par minute utilise exclusivement la durée du fixture épinglé :
`fixture.sampleCount / 16 000 / 60`.

Les deux captures :

- ont un PCM complet, sans trou ni chevauchement ;
- couvrent heuristiquement la dernière référence à 100 % ;
- terminent avec un backlog nul ;
- utilisent le même helper avant et après la rotation ;
- restent sous 4,29 Gio de RSS.

Preuves locales :

- `.build/benchmarks/japanese-live/runs/l8c-firefox-voxtral-qudu-r1-20260728T164152Z/`
- `.build/benchmarks/japanese-live/runs/l8c-firefox-voxtral-md62-r1-20260728T180046Z/`
- `.build/benchmarks/japanese-live/runs/l8c-decision-20260728T182100Z/`

`comparison.json` contient les SHA des manifests de run, validations,
attestations, évaluations, sessions, métriques, manifests de corpus, modèle,
applications et arbres source. Son SHA-256 final est
`fa795a3ef2ce7b05299101fcf47bc70dae3aa0f2bf84ec42fd7e327b5cd9bfc7`.
Le patch candidat SHA-256
`9cae2e7d5884cdfe5e28839a719b9e57882cb528c814438fff2b4c2f491e7025`
reconstruit les trois fichiers du tree source enregistré
`0658709a74808005c9f16f8d6fbcb1eb86b747a4fcad521b51321e4070d0d639`.

Les références restent `pending-human-review`. Une revue bilingue exhaustive
des frontières serait encore nécessaire pour affirmer « zéro coupure
critique ». La couverture de la dernière référence est donc seulement un
diagnostic positif, mais le candidat est déjà rejeté par les gates automatiques.

## Décision

**Bloqué.** Attendre 15 secondes réduit les fallbacks, mais reste entre 1,76
et 2,01 coupures dégradées par minute au lieu de 0,1. La preview p95 régresse sur
les deux vidéos et le final reste supérieur à 1,5 seconde.

Le fallback 15 s est donc rejeté et le comportement produit L8B3 est restauré.
Les marqueurs Voxtral restent désactivés. Leur gate est conservé à 200 ms pour
empêcher une activation future sans preuve humaine suffisamment précise.

L8D ne démarre pas : son entrée dépend d'un L8C validé.

## Rollback

Le comportement du planner est déjà revenu à `5304bfc`. Pour annuler aussi le
durcissement sans effet produit, remettre le gate des marqueurs à 240 ms.
