# E29 — WhisperKit ciblé DEV (#95)

**Décision : NO-GO_TARGETED_WHISPERKIT_ENGLISH.** Holdout fermé.

- Raw-only : 6/169 fenêtres (3.55%), 27.96s ; seuil faiblesse Qwen 0.25, folds [0.25, 0.25, 0.25, 0.0, 0.25].
- Diagnostic : la gate confondait le remplissage temporel des cues avec la complétude de la référence ; le manifest racine complet et l’alignement 199/199 rendent désormais les 6 fenêtres évaluables.
- Incident Metal séparé : une première commande aval autorisée a échoué en sandbox avant tout alignement/traduction (12.78s, signal xctest 6). Une seule reprise hors sandbox a été explicitement autorisée ; cet incident ne contribue pas au verdict qualité.
- Japonais : edits Qwen 3273, #94 3229, #95 3219 ; overrides WhisperKit 2, mauvais 0.
- Termes/nombres/sens récupérés : Qwen {'meaning': 6, 'numbers': 11, 'terms': 7}, #94 {'meaning': 6, 'numbers': 11, 'terms': 7}, #95 {'meaning': 6, 'numbers': 11, 'terms': 7} ; aucun changement produit.
- Surcoût ASR vs Qwen Standard : 144.29s ((#94 ASR 130.68s - Qwen 84.47s) + WhisperKit commande 98.07s ; worker 88.45s). Pic expérimental 11.04 Gio ; total #94 historique 650.16s.
- Anglais : Qwen 46.436, #94 45.875, #95 45.899 (Δ Qwen -0.537).
- Aval expérimental commun : 445.54s (alignement 26.06s, traduction 407.96s) ; ce temps n’est pas un surcoût produit propre à WhisperKit.
- Intégrité anglaise : 280 cues acceptés, aucun missing/duplicate/reorder/unknown. Les 280 nativeMarkerFailures sont diagnostiques : ce run fait une cue par requête et ses prompts natifs n’emploient pas les marqueurs CURRENT ; aucune perte d’intégrité observée.

## Overrides WhisperKit
- segment-0095 — référence « ない。 » ; base « parakeet-ja: ケージ使った技が使えない。 » ; WhisperKit « はいはいは難しい » ; edits 10→8 ; référence speech complète.
- segment-0127 — référence « やったー！や » ; base « qwen-ja: ええええええ。ほほほ。わあ。 » ; WhisperKit « やばすぎる » ; edits 16→8 ; référence speech complète.

Aucune UI, aucun changement Live/default, aucune ouverture holdout.
