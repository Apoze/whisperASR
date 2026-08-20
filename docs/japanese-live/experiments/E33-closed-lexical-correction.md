# E33 — Correction lexicale fermée

Le candidat #119 est **NO-GO sur DEV**. Il n’est ni activé dans le pipeline,
ni proposé dans l’interface. Le mode Live, les réglages par défaut, l’ASR et la
traduction restent inchangés.

Une seule variable a été rejouée sur la sortie Qwen Standard E31 : après l’ASR,
remplacer uniquement une forme japonaise proche d’un terme de l’union fermée :
8 termes Project metadata, 0 terme source metadata et les termes cue-local
sélectionnés (6 IDs distincts, dont 4 déjà présents côté Project). Ces trois
origines restent séparées dans le freeze et l’audit. Le catalogue existant
fournit la forme canonique et sa provenance. La politique refuse les nombres
modifiés, les formes ambiguës, les concurrents proches et tout terme hors union.
Chaque décision conserve le texte avant/après, le terme, la forme reconnue, le
score et la raison.

| Résultat DEV | Valeur |
|---|---:|
| Cues modifiées | 3 |
| Corrections utiles confirmées | 0 |
| Fausses corrections | 2 |
| Non scorables (trou de référence) | 1 |
| Nombres perdus | 0 |
| Intégrité des termes critiques | Non scorée (0/3 changement annoté) |

Les deux erreurs sont concrètes : `甘い向か` et `赤いモカ` ressemblent au nom
`甘結もか`, mais les tours de référence parlent respectivement de `百鬼襲/豪鬼`
et de la Drive Gauge. La proximité phonétique et un scope Project correct ne
suffisent donc pas à autoriser une substitution sûre.

La porte `utiles > erronées` échoue. Conformément au protocole, TranslateGemma
12B n’a pas été chargé, la qualité anglaise n’a pas été mesurée et le holdout
`md62mmdz0m` est resté fermé. Les preuves brutes sont dans
[`evidence/E33`](evidence/E33/) ; le rapport est reproductible avec
`Scripts/report_lexical_correction_experiment.py`. Le reporter vérifie en mode
fail-closed les hashes gelés, la policy, les 307 IDs/timings, le texte corrigé
et l’appartenance de chaque candidat à l’union. Une promotion future exigera
des annotations indépendantes de termes critiques pour chaque changement ; une
liste `criticalTerms` vide reste explicitement `notScored`.

## Provenance d’exécution

- Base réellement jouée : commit `fd68b1a785abe8e0c6262d135910aea893b5f551` ;
  les SHA-256 exacts des quatre sources d’implémentation non committées sont
  gelés et vérifiés. Aucun commit futur n’est revendiqué.
- Entrée E31 réutilisée : Qwen JA
  `ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit` révision
  `7c70d18cb650655d32eafb952a74a49c6a3caad0`, poids
  `bdef075a…0954`. Le run-meta, le registre de modèles, le replay de reprise et
  le raw E31 sont liés par leurs hashes gzip et contenu.
- Couverture réutilisée et vérifiée : 15 315 325 échantillons PCM à 16 kHz
  (957,2078125 s) et les 307 tours complets ; 772,707 s appartiennent aux
  intervalles de tours.
- Traduction : `notRun`. Modèle, révision, poids et latence de traduction :
  `notApplicable`. Nouveau décodage PCM, alignement, diarisation, reflow, Live
  et holdout : `notApplicable`.
- Passe lexicale seule, build debug : médiane **960,62 ms**, p95
  **1 149,28 ms**, mesurée par `ContinuousClock` autour de `apply` uniquement,
  après 1 warm-up puis 5 itérations sérielles. Chaque itération retrouve les 3
  mêmes changements.
- Machine : MacBook Pro `Mac17,9`, Apple M5 Pro, 15 cœurs, 24 Gio, arm64,
  macOS 26.5.2 ; Xcode 26.6, Swift 6.3.3 et Python 3.14.6.

| Élément gelé | SHA-256 / identité |
|---|---|
| Base Git réellement exécutée | `fd68b1a785abe8e0c6262d135910aea893b5f551` |
| Glossaire / passe lexicale | `23f7506a…ada1` / `1dba580a…3d59` |
| Producteur de replay / reporter | `34bd4a19…8892` / `9731ce5d…8f52` |
| E31 run-meta / registre modèles / reprise | `b9760268…8f29` / `d199240e…5020` / `61b2f7d8…8cd` |
| E31 raw gzip / contenu décompressé | `bd0c6dca…9a1a` / `95b5089c…48c5` |
| Mesure brute de latence | `9ab70730…8d76` |
