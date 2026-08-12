# E28 — Adaptive ASR Qwen + Parakeet DEV (#94)

**Decision: NO-GO-downstream-forced-alignment-gate.** Holdout fermé.

- Fenêtres acoustiques communes : 169, max 8.00s ; aucune référence dans le plan ou le sélecteur.
- Choix : Parakeet 2, abstentions Qwen 167 ; calibration exacte stable=false, admissible=true (four-identical-thresholds-one-no-gain).
- Japonais : edits Qwen 3273, Parakeet 2618, oracle hypothèse complète 2385 ; Parakeet meilleur/égal/pire 99/21/49 fenêtres.
- Dimensions : terms 7 Qwen / 13 Parakeet, numbers 11 Qwen / 11 Parakeet, meaning 6 Qwen / 7 Parakeet.
- Vides 0→0 ; doublons 0→0.
- ASR : Qwen 84.5s, Parakeet 46.2s, total worker 130.7s, commande 140.1s; pics Qwen 8.86 Gio, Parakeet 0.64 Gio.
- Abstentions : causes exclusives {'insufficient-calibrated-margin': 123, 'insufficient-disagreement': 33, 'insufficient-disagreement+qwen-critical-token-lost': 1, 'qwen-critical-token-lost': 10} ; signaux chevauchants {'insufficient-calibrated-margin': 123, 'insufficient-disagreement': 34, 'qwen-critical-token-lost': 11} ; signaux runtime individuels, aucun veto global ni mapping.
- Mapping référence DEV : 3573/3573 caractères, 199 cues conservées, 0 non assigné, aucun entrelacement des locuteurs.

## Calibration par fold
- Holdout bloc 0 — seuil 0.5; train overrides 2 (1 bons/0 mauvais/1 neutres, gain 44); fold overrides 0 (0 bons/0 mauvais/0 neutres, gain 0).
- Holdout bloc 1 — seuil 0.5; train overrides 2 (1 bons/0 mauvais/1 neutres, gain 44); fold overrides 0 (0 bons/0 mauvais/0 neutres, gain 0).
- Holdout bloc 2 — seuil None; train overrides 0 (0 bons/0 mauvais/0 neutres, gain 0); fold overrides 0 (0 bons/0 mauvais/0 neutres, gain 0).
- Holdout bloc 3 — seuil 0.5; train overrides 1 (1 bons/0 mauvais/0 neutres, gain 44); fold overrides 1 (0 bons/0 mauvais/1 neutres, gain 0).
- Holdout bloc 4 — seuil 0.5; train overrides 2 (1 bons/0 mauvais/1 neutres, gain 44); fold overrides 0 (0 bons/0 mauvais/0 neutres, gain 0).
- Variance : {'heldoutNetEditGainMean': 0, 'heldoutNetEditGainPopulationVariance': 0, 'noGainFoldCount': 1, 'numericThresholdMean': 0.5, 'numericThresholdPopulationVariance': 0.0}.

## Contrôle règle fixe 0,5
- Bloc 0 — edits 740→740, overrides 0 (0 bons/0 mauvais/0 neutres), gain 0, critique {'meaning': {'lost': [], 'recovered': []}, 'numbers': {'lost': [], 'recovered': []}, 'terms': {'lost': [], 'recovered': []}}.
- Bloc 1 — edits 733→733, overrides 0 (0 bons/0 mauvais/0 neutres), gain 0, critique {'meaning': {'lost': [], 'recovered': []}, 'numbers': {'lost': [], 'recovered': []}, 'terms': {'lost': [], 'recovered': []}}.
- Bloc 2 — edits 716→672, overrides 1 (1 bons/0 mauvais/0 neutres), gain 44, critique {'meaning': {'lost': [], 'recovered': []}, 'numbers': {'lost': [], 'recovered': []}, 'terms': {'lost': [], 'recovered': []}}.
- Bloc 3 — edits 619→619, overrides 1 (0 bons/0 mauvais/1 neutres), gain 0, critique {'meaning': {'lost': [], 'recovered': []}, 'numbers': {'lost': [], 'recovered': []}, 'terms': {'lost': [], 'recovered': []}}.
- Bloc 4 — edits 465→465, overrides 0 (0 bons/0 mauvais/0 neutres), gain 0, critique {'meaning': {'lost': [], 'recovered': []}, 'numbers': {'lost': [], 'recovered': []}, 'terms': {'lost': [], 'recovered': []}}.
- Downstream : échec alignment — Alignment cue cue-0295 has invalid or non-monotonic timing.
- Cue nul : cue-0295 « うん。 » 957.18–957.18s, fenêtre 168 Qwen inchangée ; les deux overrides ne sont pas causaux.
- ForcedAligner : worker 24.4s, pic 2.56 Gio, sortie 0 puis gate rouge ; TranslateGemma non chargé.
- Commande downstream : 39.1s; pics job 2.56 Gio, modèle aligner 1.86 Gio.
- Total DEV commandes : 179.2s; workers modèles 155.1s; pic global 8.86 Gio, incrément downstream 2.56 Gio.
- Même classe que #93 (cue forced-aligner de durée nulle). Aucun replay sûr depuis ce raw : il faudrait inventer un timing ou recharger l’aligneur.
- Anglais : non exécuté ; impact des 44 edits japonais, chrF++ et COMET indisponibles.
- #95 : no-run: #94 has no eligible English candidate.

## Exemples japonais
- Parakeet meilleur, 539.88–543.16s — référence « ない。 » ; Qwen « はいはい、はい。はいあ、は、は。は、あ、あ。ははは、いや、はは。あ、いや。はあ、う、はあ。ああ、まあ、はや、はゆ、は難しい。ゲージ使ったわ。ズ、だ、しか使わ、ない、 » ; Parakeet « ケージ使った技が使えない。 » ; edits 54→10 ; runtime final parakeet-ja.
- Parakeet pire, 735.88–742.10s — référence « 感動しました！けど、普通に！マジで感動しました！マジで感動した！普通に涙出た。マジで感動した！普通に涙出た。ね、わかる！さ » ; Qwen « 感動しました。え、マジで感動した。普通に涙出た。え、わかる。 » ; Parakeet « ねえ分かる? » ; edits 31→50 ; runtime final qwen-ja.

Aucune UI, aucun changement Live/default, aucune ouverture holdout.
