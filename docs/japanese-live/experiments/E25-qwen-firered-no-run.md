# E25 — Sélection Qwen et no-run FireRed (#91)

**NO-RUN.** Qwen E22 reste la meilleure recette single-ASR DEV. Le holdout reste fermé ; aucun modèle, UI, Live ou défaut Standard n’est modifié.

## Sélection ASR

| Candidat | Verdict figé | Motif matériel |
|---|---|---|
| Fun-ASR Nano int8 | NO-GO | répétition « 最低だな » ×77 et provenance amont non prouvée |
| ReazonSpeech K2 v2 int8 | NO-GO | 0 récupéré, 3391 perdus face à Qwen |
| Qwen Anime/Galgame | NO-GO | licence non admissible ; aucun poids ni run |

Qwen est donc conservé par la règle de fallback du ticket, avec son modèle, ses poids et sa segmentation E22 inchangés.

## Porte FireRed

E23 compte 78/206 pertes près des frontières (37.9 %), pour une exposition de 34.4 % et une concentration de 1.10×. La porte exige 60 % et 1,5× : **ineligible-no-concentrated-boundary-loss**.

Conséquence : aucune frontière FireRed, aucun delta de trous/duplications, aucun ASR, alignement ou anglais candidat n’est produit. Ce sont des valeurs absentes, pas des métriques nulles inventées.

## Preuve DEV conservée

- Qwen : 1697 caractères récupérés, 1371 perdus/substitués ; 12 tours vides et 1 dupliqué.
- Termes 8/18 récupérés/perdus ; nombres 6/11 ; sens 7/5.
- 415.98–422.38 s — référence : « そうそうそう。いろいろあるんですよね、4回投げるまでに。早めに吐いて、このあとのゲージを溜めながら。そう思わせて、実 » ; Qwen : « この後の成長とかそう思って実はただ投げるバケって。 ».
- 228.66–235.46 s — référence : « ど！さあ、ここで甘結もか、すでに1セット勝かっこいいんだけど。完璧でした。 » ; Qwen : « このままはオーディシャッカーの時点で3番手 ».
- 309.40–317.40 s — référence : « 000だったはず。その1000、でかいの？いや、でもランクしてるとね、でかいなって » ; Qwen : « 1万だったその線でかいのランクしてるとねでかいなって思 ».
- 179.00–185.00 s — référence : « リーサルだー！ ドーーーン!!! » ; Qwen : «  ».

## Exécution et contrôles

- 0 modèle lancé ; temps FireRed 0,00 s ; mémoire FireRed non applicable ; pic Qwen E22 réutilisé 18339289016 octets.
- Les erreurs de harnais #88/#89 restent attribuées séparément des NO-GO candidats.
- Xcode 26.6, metallib vérifié (`0d29caeba83e59e98a04cf822fdd684f5ef4b93210847a385124faf4d9353ab3`), 425 tests, 56 opt-in ignorés, 0 échec.
- Entrée, audio, référence, poids Qwen, metallib et rapports sources sont réellement relus et vérifiés par SHA-256.
- Holdout fermé ; aucun changement produit, UI, défaut Standard ou Live.

Reproduction : `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Scripts/build_mlx_metallib.sh debug && python3 Scripts/report_firered_no_run.py`.
