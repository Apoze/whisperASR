# E33 — WhisperKit ciblé après Qwen → Parakeet (#118)

**Décision : RETAIN-HIDDEN / NO-GO DEV.** Holdout fermé, traduction non lancée, Live et défaut inchangés. La revue a en plus déclassé le run en preuve exploratoire : son ancien runner ne reproduisait pas exactement le prédicat produit, car la calibration était instable.

- Commande autorisée : `BENCHMARK_SLOT_GRANTED=118 bash Scripts/run_adaptive_asr_118.sh full`.
- DEV figé `qudu2fx3ncc` : 169 segments acoustiques déterministes de 3–8 s. Qwen s'exécute d'abord, puis Parakeet uniquement sur faiblesse indépendante, puis WhisperKit uniquement après désaccord matériel Qwen/Parakeet encore indécis.
- Le contrôle Qwen → Parakeet DEV réussi (175,817 s) a été réutilisé seulement après vérification intégrale de sa provenance et de ses hashes. Le rerun n'a relancé que WhisperKit et l'évaluation aval DEV.
- L'ancien runner a ciblé 13/169 segments (7,69 %) et produit 10 hypothèses complètes. Il a audité trois rejets candidat sur `segment-0116`, `segment-0167` et `segment-0168`, avec fallback Qwen sûr. La réponse brute de `segment-0167` est conservée : ses timestamps 29,32–29,62 s dépassent sa fenêtre de 5,32 s. Les réponses brutes de `segment-0116` et `segment-0168` ne sont plus disponibles ; leur preuve est explicitement limitée au rejet audité et leur cause temporelle exacte n'est pas réaffirmée.
- Le sélecteur calibré s'abstient : 0 sélection WhisperKit, 2985 edits avant et après WhisperKit, soit 0,00 % de gain. La meilleure projection observée aurait remplacé 5 segments pour 2 améliorations et 3 dégradations, soit -7 edits nets.
- La calibration séparée est instable sur cinq blocs. Les portes gain ≥ 1 %, récupération utile, calibration stable et marge unique figée sont rouges. Le holdout n'a donc pas été ouvert.
- Temps ASR du contrôle réutilisé : Qwen 139,44 s, Parakeet 19,14 s. WhisperKit ciblé : 79,83 s worker / 85,68 s mur. Pics mémoire : Qwen 7 122 539 680 octets, Parakeet 686 442 152 octets, WhisperKit 3 117 239 248 octets ; aucune terminaison forcée.
- Vérification locale après correction : 53 tests ciblés, 0 échec, 8 opt-in ignorés ; suite complète 497 tests, 0 échec, 66 opt-in ignorés ; contrôle Live 46 tests, 0 échec. Les self-tests du runner confirment aussi qu'un contrôle non final en échec bloque READY, l'aval et le holdout.

Le code corrigé utilise maintenant une raison structurée : timestamps/mapping candidat invalides → fallback audité ; schéma/protocole/transport → arrêt infrastructure. Une preuve temporelle vide, de couverture nulle ou sans mapping texte exploitable est inéligible. Le même prédicat produit — faiblesse Qwen, désaccord matériel, calibration stable et décision Qwen/Parakeet indécise — pilote le job et l'audit.

En cas d'arrêt infrastructure Parakeet ou WhisperKit, le job reste en échec, conserve le brut Qwen et l'audit partiel (route, erreur par segment et lifecycle disponible), puis bloque traduction et exports. Les hashes d'implémentation couvrent aussi le client worker et ses tests ; le self-test rejette leur mutation. Le READY historique reste inchangé pour préserver la provenance brute, tandis que tout nouveau READY utilisera ce ledger complet.

Le fallback est maintenant réservé aux trois raisons candidat structurées (timestamps, mapping ou hypothèse invalides). Toute erreur inconnue ou I/O, dont un échec `Data.write`, arrête le job comme infrastructure. Le validateur conserve aussi le contrat historique : bornes exigées pour les chunks, mais ordre de leurs débuts non imposé.

Le runner refuse désormais aussi les faux succès de provenance : un `state.json` illisible produit `holdoutOpened: null` avec provenance invalide, jamais `false` par défaut, et les comparaisons de calibration/freeze exigent deux valeurs calculées, valides et non vides avant égalité. Les self-tests couvrent explicitement le cas historique `"" == ""`.

La provenance compacte et le ledger SHA-256 figé sont dans `evidence/issue-118-targeted-whisperkit.json`. La seule réponse invalide encore restaurable est copiée sous `evidence/issue-118-invalid-responses/segment-0167-response.json` ; les artefacts historiques restent sous `.build/benchmarks/issue-118/`.
