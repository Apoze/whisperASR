# E30 — Décision Lane A (#96)

**NO-GO option bêta ; HOLDOUT NO-RUN.** Qwen JA standard gagne DEV parce qu’aucun candidat distinct ne passe toutes les portes. Rejouer Qwen sur le holdout ne peut prouver aucun gain.

## Sélection figée

Règle automatique : admissibilité + référence complète + gain japonais + anglais final non régressif + aucune perte critique. Qwen standard est figé avant toute ouverture ; le holdout reste intact.

- Qwen : 1697 caractères récupérés, 1371 perdus/substitués, termes 8/18, nombres 6/11, sens 7/5 récupérés/perdus.
- #94 : edits JA 3273→3229 (+44), dimensions termes/nombres/sens 7/11/6 inchangées, mais chrF++ EN 46.436→45.875 (-0.561) : veto.
- #95 : edits provisoires 3229→3219, mais 1/6 références seulement est complète ; anglais non exécuté et conclusion modèle absente.

## Coûts et conséquences

| Piste | Temps / pic | Qualité concrète | Conséquence |
|---|---|---|---|
| Qwen standard | ASR 68,1 s ; preuve 1064/1124 s selon source ; 17,08 Gio | baseline DEV figée | winner Lane A, aucun gain à tester contre lui-même |
| Fun-ASR | worker 11,63 s ; 2,92 Gio | « 最低だな » ×77 au smoke | arrêt avant DEV/anglais |
| Reazon | worker 23,25 s ; 1,29 Gio | 135 caractères, CER 97,19 %, 0 récupéré/3391 perdus | NO-GO qualité après diagnostic ULP |
| Qwen Anime | 0 s ; aucun processus | licence non admissible | aucun poids/smoke/DEV |
| FireRed | 0 s ; aucun processus | pertes frontière non concentrées | no-run |
| Hotwords | 0 s ; aucun processus | aucune capacité distincte du prompt | no-run |
| Qwen + Spleeter | prétraitement 9,58 s ; job 133,78 s ; 9,61 Gio | parole −31, vides/duplication ajoutés, alignement rouge | aucun anglais |
| Qwen + Parakeet | commandes 650,16 s ; workers 600,00 s ; 11,04 Gio | JA +44, EN chrF++ −0,561 | holdout fermé |
| WhisperKit ciblé | 27,96 s ciblées ; worker 88,45 s ; 3,29 Gio | +10 edits provisoires vs #94, référence incomplète | inconclusif, retestable |

## Harness, holdout et produit

- L’ordre fail-closed est harness → build → input → référence → candidat. Les hashes E23–E29, les artefacts bruts et le build courant sont vérifiés avant la décision.
- L’écart historique de coût Qwen est conservé : E23 JSON indique 1064 s, E24 figé 1124 s ; aucune valeur n’est silencieusement remplacée.
- #95 reste retestable lorsque les six fenêtres suspectes auront des références temporelles complètes ; le preflight corrigé doit alors passer avant tout modèle.
- Aucun benchmark #96, aucun holdout, aucune option bêta/fantôme. `Sources/`, UI, requête, job, manifest, Deliverables, défaut Qwen et Live sont byte-identiques au commit de base.

- `swift run &` : build réussi puis sortie 0 attendue sur le verrou mono-instance ; l’instance WhisperASR existante est restée active.

Reproduction : `python3 Scripts/report_lane_a_decision.py --self-test && python3 Scripts/report_lane_a_decision.py`.
