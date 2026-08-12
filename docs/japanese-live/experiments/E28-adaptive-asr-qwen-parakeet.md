# E28 — Adaptive ASR Qwen + Parakeet DEV (#94)

**Decision: NO-GO-english-regression-stop-before-holdout.** Holdout fermé.

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
- Anglais : chrF++ 46.44→45.87 (-0.56) ; vides 7→7.
- Retry ciblé unit-0054 : « That's right, right, right, right, right. It's like a cutting line. » ; reason codes après correctif [], sortie propre=true.
- Complétude : 281 réutilisées + 1 retraduite = 282/282 ; aucune unité jamais générée.
- Retry : commande 21.4s, worker 8.7s, génération 2.3s; pics worker 6.82 Gio, exchange 6.44 Gio, minimum disponible 4.94 Gio, pression [], swap Δ 0 octets.
- Coût cumulé DEV : commandes 650.2s; workers modèles 600.0s; incrément retry 21.4s; pic global 11.04 Gio.
- Poids TranslateGemma vérifiés au preflight : ['bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af', 'c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89'] (le raw worker conserve son champ vide).
- Effet : +44 edits JA évités, mais chrF++ EN -0.56; COMET indisponible. #95 reste indépendant.

## Exemples japonais
- Parakeet meilleur, 539.88–543.16s — référence « ない。 » ; Qwen « はいはい、はい。はいあ、は、は。は、あ、あ。ははは、いや、はは。あ、いや。はあ、う、はあ。ああ、まあ、はや、はゆ、は難しい。ゲージ使ったわ。ズ、だ、しか使わ、ない、 » ; Parakeet « ケージ使った技が使えない。 » ; edits 54→10 ; runtime final parakeet-ja.
- Parakeet pire, 735.88–742.10s — référence « 感動しました！けど、普通に！マジで感動しました！マジで感動した！普通に涙出た。マジで感動した！普通に涙出た。ね、わかる！さ » ; Qwen « 感動しました。え、マジで感動した。普通に涙出た。え、わかる。 » ; Parakeet « ねえ分かる? » ; edits 31→50 ; runtime final qwen-ja.

## Exemples anglais
- override-scored segment-0095 — référence « It's a really bad state: you still take chip damage while guarding, you can't parry, and you can't use Drive Impact. » ; baseline « It's difficult to handle. I used my gauge. It's quite direct. If you can hit with guard, it's a big advantage. » ; candidat « It's not possible to use techniques that rely on a cage. ».
- override-unscored segment-0126 — référence « indisponible (non scoré) » ; baseline « Well, really? It ends like this. » ; candidat « Got it! ».

Aucune UI, aucun changement Live/default, aucune ouverture holdout.
