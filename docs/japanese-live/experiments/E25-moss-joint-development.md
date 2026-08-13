# E25 — MOSS conjoint sur DEV (#99)

La condition d’ouverture de #99 a été vérifiée contre les artefacts figés de
#98 au commit `ea0c312c4f1d2843120be02a251946fe112370db`. Elle est fermée :
#98 a produit `candidateOutputProduced=false`, `issue99Authorized=false` et un
`NO-GO matériel` après OOM Metal avant le premier token.

**MOSS conjoint n’a donc pas été exécuté.** Aucun modèle n’a été chargé et
aucune sortie, durée, mémoire ou métrique de qualité conjointe n’est rapportée.
Le texte, les spans, le raccord, la parole récupérée/perdue, l’attribution, la
duplication, les termes, nombres, sens et l’anglais restent non évaluables.

Le seul résultat positif reste le smoke borné #97, qui prouve l’exécution et la
forme de sortie sur 52 s, sans prouver la qualité ni une identité globale sur le
DEV complet. Le chunking externe reste inadmissible : les labels MOSS sont
relatifs à chaque entrée et aucun streaming officiel ne garantit leur identité
globale stable.

**Décision DEV figée : aucun candidat MOSS admissible.** Le holdout reste fermé;
Standard, Live, l’UI et les valeurs par défaut sont inchangés. Un nouveau run
exige une nouvelle autorisation et soit un matériel différent, soit un runtime
amont borné en mémoire qui conserve l’identité globale des locuteurs.

Le rapport déterministe est sous
`docs/japanese-live/experiments/evidence/E25-moss-joint/`. Il authentifie les
preuves #98 et échoue si leur provenance ou la décision commise change :

```bash
python3 Scripts/report_moss_joint.py --check
python3 Scripts/report_moss_joint.py --self-test
```
