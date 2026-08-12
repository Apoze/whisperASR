# E29 — WhisperKit ciblé DEV (#95)

**Décision : INCONCLUSIVE_REFERENCE_HARNESS_NO_DOWNSTREAM.** Holdout fermé.

- Raw-only : 6/169 fenêtres (3.55%), 27.96s ; seuil faiblesse Qwen 0.25, folds [0.25, 0.25, 0.25, 0.0, 0.25].
- Diagnostic : le preflight initial a manqué la couverture référence ; le preflight corrigé conclut désormais no-run avant WhisperKit. Aucun résultat modèle.
- Japonais : edits Qwen 3273, #94 3229, #95 provisoire 3219 ; overrides WhisperKit 2, mauvais indéterminés.
- Termes/nombres/sens récupérés : Qwen {'meaning': 6, 'numbers': 11, 'terms': 7}, #94 {'meaning': 6, 'numbers': 11, 'terms': 7}, #95 provisoire {'meaning': 6, 'numbers': 11, 'terms': 7} ; Qwen reste la Lane A produit.
- Coût #95 : WhisperKit commande 98.07s, worker 88.45s ; incrément total 98.07s ; pic 3.29 Gio ; Qwen seul 84.47s, #94 ASR 130.68s / total 650.16s.
- Anglais : non exécuté (Japanese impact is not evaluable with the partial DEV reference).
- Gate référence : échec ; les fenêtres proposées ne sont pas entièrement couvertes temporellement, donc le gain d’edits ne prouve pas un gain modèle.

## Overrides WhisperKit
- segment-0095 — référence « ない。 » ; base « parakeet-ja: ケージ使った技が使えない。 » ; WhisperKit « はいはいは難しい » ; edits provisoires 10→8 ; couverture référence 34.1%.
- segment-0127 — référence « やったー！や » ; base « qwen-ja: ええええええ。ほほほ。わあ。 » ; WhisperKit « やばすぎる » ; edits provisoires 16→8 ; couverture référence 40.5%.

Aucune UI, aucun changement Live/default, aucune ouverture holdout.
