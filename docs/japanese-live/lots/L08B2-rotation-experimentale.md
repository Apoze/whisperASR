# L8B2 — Rotation expérimentale Voxtral

## Dépendances

L8B rejeté au commit `9f2cd13`.

## Objectif

Comparer des sessions Voxtral Q4/960 bornées à 4, 8 ou 12 minutes, fermées
uniquement sur une pause FireRedVAD sûre, sans overlap ni replay.

## Hors-périmètre

- Modifier le chemin produit avant la victoire d'une durée.
- Changer les frontières de sous-titres ou Apple Translation.
- Ajouter un moteur, une dépendance ou un réglage utilisateur.

## Fichiers touchés

- `Tests/JapaneseModelBakeoffTests.swift`
- `Scripts/run_voxtral_l8b2.sh`
- `Scripts/report_voxtral_l8b2.py`
- cette fiche et l'index global

## Tests

- Deux tests unitaires Release du découpage contigu et du transcript agrégé.
- Screening 240, 480 et 720 secondes sur les deux PCM complets à 1×.
- Deux replays supplémentaires du gagnant, soit trois résultats par corpus.
- Réseau sortant refusé, modèle préchargé une fois et moteurs séquentiels.

## Preuves

- Screening :
  - `runs/l8b2-voxtral-rotation-240s-20260728T082100Z`
  - `runs/l8b2-voxtral-rotation-480s-20260728T082100Z`
  - `runs/l8b2-voxtral-rotation-720s-20260728T074500Z`
- Confirmation : `runs/l8b2-voxtral-rotation-720s-2x-20260728T093300Z`
- Rapport : `runs/l8b2-final-20260728T104000Z`

| Rotation | CER pondéré | Dernière parole | Preview p95 max | Final p95 max | RSS max | Screening |
|---:|---:|---:|---:|---:|---:|---|
| 240 s | 40,19 % | 2/2 | 5,21 s | 1,39 s | 5,94 Gio | passé |
| 480 s | 48,58 % | 1/2 | 6,25 s | 1,39 s | 5,30 Gio | échoué |
| 720 s | 39,54 % | 6/6 | 6,31 s | 1,39 s | 5,98 Gio | passé |

Pour 720 secondes, le transcript final normalisé et les frontières sont
identiques sur les trois exécutions de chaque corpus. Les SHA par session et
l'absence de doublon exact aux coutures sont identiques sur les deux replays
instrumentés. Toutes les plages PCM sont contiguës et accusées, sans backlog
final. Le screening et les confirmations ont des SHA d'arbre source différents
car la télémétrie par session a été ajoutée entre les deux.

## Décision

**720 secondes retenues pour L8B3.** À moins d'un point de CER pondéré du
meilleur score, la durée la plus longue minimise les coutures. Elle restaure
la dernière phrase de `qudu2fx3ncc` et améliore son CER de 81,97 % à 64,34 %.

La preview reste hors SLO et sera traitée séparément. La promotion qualité
reste provisoire : les références sont `pending-human-review` et 13,66 s de
queue VAD de `qudu2fx3ncc` ne sont pas classées humainement.

## Rollback

Supprimer le harness et les scripts L8B2; aucun code produit ne doit avoir été
modifié par ce lot.
