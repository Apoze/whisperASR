# E24 — Fun-ASR-Nano int8 sur DEV (#88)

**NO-GO avant DEV complet.** Deux portes indépendantes échouent : aucune source primaire ne relie l'archive ONNX à une révision exacte du checkpoint FunAudioLLM, et le second segment figé de 14,1 s produit 245 tokens en répétant « 最低だな » 77 fois.

## Porte technique

- Archive sherpa exacte : `sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2`, 841 730 611 octets, SHA-256 `eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b`. Sa provenance amont exacte reste non prouvée ; elle ne doit pas être présentée comme la révision HF `272c…`.
- Runtime Apple Silicon : sherpa-onnx 1.13.5, commit `3dc7c569f31ca2cd4a20ed6f7db780327e6714c5`.
- Les six fichiers ONNX/tokenizer sont épinglés et vérifiés par SHA-256 ; hotwords et ITN désactivés. Le smoke conserve le découpage figé mais s'arrête avant l'alignement acoustique.

## Smoke

- Commande : `BENCHMARK_SLOT_GRANTED=88 bash Scripts/run_funasr_nano_experiment.sh smoke`.
- 30 s de l'entrée DEV figée, découpées par le chemin ancré existant en 15,84 s et 14,10 s.
- Temps : 11,63 s worker, dont 8,49 s de décodage ; pic 3 138 424 000 octets (2,92 Gio).
- Exit 0, aucune terminaison forcée, aucune transition de pression, swap inchangé à 2 712 993 792 octets.

Exemple japonais, référence : « 続いての大将戦ですが、甘結もか、そして立川。もかさん、頑張れ！ 頑張れ！立川も、プロとしての意地を見せます。 »

Fun-ASR : « え続いての対処性ですが甘いもかそして立川…立川もプロとしての意地を見せます。…最低だな最低だな… »

Exemple anglais figé : « Next up is the anchor match: Amayui Moka versus Tachikawa. Moka, you've got this! Go! Go! Tachikawa says he will show his pride as a pro. » Aucune sortie anglaise candidate n'a été produite : la porte ASR a arrêté l'expérience avant traduction.

Les deux erreurs antérieures sont classées séparément comme erreurs de harnais : metallib MLX absent, puis entrée non ancrée dépassant la capacité KV. Le smoke final utilise bien le chemin ancré du DEV.

Artefacts bruts et hashes : `docs/japanese-live/experiments/evidence/E24/`. Le holdout reste fermé ; UI, Live et valeur Standard inchangés.

Finalisation légère : 421 tests couverts avec le toolchain Xcode, 366 passés et 55 opt-in ignorés. Un test de terminaison hors #88, sensible au timing lorsqu'il est noyé dans la suite, a été validé séparément. Les 1 finding Standards et 4 findings Spec ont été corrigés ; aucun DEV/reporter spéculatif n'est conservé.
