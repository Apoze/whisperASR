# E23 — Diagnostic figé des erreurs Qwen (#87)

E22 est réutilisé sans relancer de modèle. Le holdout reste fermé ; aucun changement produit, UI, Live ou valeur Standard.

## Résultat

- 295 segments acoustiques DEV, tous ≤ 8.00 s, reliés au SHA audio `494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2`.
- Parole : 1697 caractères récupérés et 1371 perdus/substitués.
- Termes : 8 récupérés, 18 perdus. Nombres : 6 récupérés, 11 perdus.
- Sens déclarés : 7 récupérés, 5 perdus. Tours vides/dupliqués : 12/1.
- Voix/musique : 41 fenêtres DEV difficiles déclenchées automatiquement.
- FireRed : **ineligible-no-concentrated-boundary-loss** (78/206 pertes près des frontières, concentration 1.10×).

## Exemples concrets

- 415.98–422.38 s — référence : « そうそうそう。いろいろあるんですよね、4回投げるまでに。早めに吐いて、このあとのゲージを溜めながら。そう思わせて、実 » ; Qwen : « この後の成長とかそう思って実はただ投げるバケって。 ».
- 228.66–235.46 s — référence : « ど！さあ、ここで甘結もか、すでに1セット勝かっこいいんだけど。完璧でした。 » ; Qwen : « このままはオーディシャッカーの時点で3番手 ».
- 309.40–317.40 s — référence : « 000だったはず。その1000、でかいの？いや、でもランクしてるとね、でかいなって » ; Qwen : « 1万だったその線でかいのランクしてるとねでかいなって思 ».
- 531.62–534.58 s — référence : « ゲージ使った技が使えないってこと？よくなさそうなんですけど、ガードしててもダメージ » ; Qwen : « ガードしててもダメージ入っちゃう。 ».
- 742.40–750.16 s — référence : « ということで、これでVSPO!チーム全勝！ おめでとうございます！いや、すごい。すごい、 » ; Qwen : « さあということでこれでV選手え全勝すご ».
- Tour vide 179.00–185.00 s : « リーサルだー！ ドーーーン!!! ».

## Coût et provenance

- Diagnostic : 2.92 s, 0 modèle lancé.
- Preuve E22 réutilisée : 18 min 44 s au total, ASR 68.1 s, pic 17.08 Gio.
- Segments bruts : `docs/japanese-live/experiments/evidence/E23/segments.json`.

Commande : `python3 Scripts/report_qwen_error_diagnostic.py --source <Video1.webm> --audio <audio-16k-mono.wav> --character-alignment <character-alignment.jsonl> --segments-json docs/japanese-live/experiments/evidence/E23/segments.json --report-json docs/japanese-live/experiments/evidence/E23/report.json --markdown docs/japanese-live/experiments/E23-qwen-error-diagnostic.md`.

Le déclencheur voix/musique est seulement figé pour une expérience DEV future. Aucun traitement audio ni option n’est promu.
