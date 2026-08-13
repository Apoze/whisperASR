# E26 — Décision de promotion MOSS (#100)

La porte de promotion exige un gagnant MOSS figé sur le DEV complet avant tout
passage holdout. La décision #99 authentifiée contient `bestMOSS=null` et
`decision=no-admissible-candidate` : la porte est fermée.

**Aucun holdout n’a été ouvert et aucune métrique holdout n’existe.**
L’attribution correcte ou incorrecte, la parole non attribuée, la duplication,
l’overlap, la durée et la mémoire restent non évaluables. Le NO-GO vient de
l’OOM Metal #98 avant le premier token, pas d’une mesure de qualité inventée.

**Verdict : NO-PROMOTION.** Aucune option MOSS, aucun runtime et aucune valeur
par défaut ne sont ajoutés. SpeakerKit Standard reste le défaut; les contrôles
SpeakerKit indépendants de #75, le workflow Standard de #77 et Live sont
inchangés.

Le vérificateur réutilise la chaîne de preuves #98→#99, épingle ses hashes et
échoue fermé si une provenance, une autorisation ou le gagnant DEV est modifié :

```bash
python3 Scripts/report_moss_promotion.py --check
python3 Scripts/report_moss_promotion.py --self-test
git diff --exit-code 7988ead17293c0a8aad8dbc57a5b5ea1496745d1 -- Package.swift Sources Tests
```

Un passage holdout ne devient admissible qu’après une nouvelle preuve DEV
complète, avec une configuration MOSS gagnante figée avant ce passage.
