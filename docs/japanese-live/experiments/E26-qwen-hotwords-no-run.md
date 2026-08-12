# E26 — Hotwords Qwen inapplicables (#92)

**INAPPLICABLE / NO-RUN.** Qwen E22 reste le meilleur single-ASR DEV, mais son backend n’expose aucun hotword natif distinct d’un prompt. Le holdout reste fermé.

## Preuve de capacité

- Runtime officiel Qwen épinglé à `7c6daf77a2421100f5fb066495372c00129d39ff` : le scan des 830 lignes de l’API publique ne trouve aucun mécanisme dédié ; `context` devient le contenu du message `system`, puis passe dans le chat template ([source](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L448-L465), blob `d99b91512a5bbc1c15897d97752cfd86ea68d46e`).
- Port Swift local `Vendor/SpeechSwiftPrototype/Sources/Qwen3ASR/Qwen3ASR.swift` (`45855a1a1a5d7bd1cb35272192bccd9826d70547399c1dd217ffb1b6deb57dbd`) : le contexte est tokenisé entre `<|im_start|>system` et `<|im_end|>` sur les chemins unitaire et batch.
- Historique local `09b092b001e4d35cd193b9a5e3f4f7307d74821b` : les essais courts avaient déjà produit un prompt echo ; Qwen est depuis volontairement exécuté sans prompt.
- Le signal communautaire #106 reproduit ce même echo avec `context=hot_word`. La demande #157 d’un paramètre hotwords dédié a été fermée sans ajout d’API.

Il n’existe donc ni paramètre hotword dédié, ni score par terme, ni biais de logits séparé. Relancer `context` répéterait l’expérience prompt déjà rejetée.

## Conséquence expérimentale

- Aucun catalogue, budget encodé, sélection cue-locale ou règle de matching n’est fabriqué après l’échec de la porte de capacité.
- Aucun off/on, faux positif ou effet anglais candidat n’est mesuré ; ces champs restent absents, pas remplacés par des zéros.
- La baseline figée reste : termes 8/18 récupérés/perdus, nombres 6/11, sens 7/5.
- Aucune post-correction, UI, valeur Standard ou modification Live.

## Exécution et contrôles

- 0 modèle lancé ; temps candidat 0,00 s ; mémoire candidate non applicable ; holdout fermé.
- Xcode 26.6 (17F113), metallib `0d29caeba83e59e98a04cf822fdd684f5ef4b93210847a385124faf4d9353ab3`, 425 tests exécutés, 0 échec.
- Incidents runner consignés : 4 ; erreurs build : 0 ; erreurs modèle : 0. Une observation test non reproduite est conservée ; quatre relances consécutives sont vertes.
- Verdict classé `capability-inapplicable`, pas comme un échec d’exécution.

Reproduction : `python3 Scripts/report_qwen_hotwords_no_run.py`.
