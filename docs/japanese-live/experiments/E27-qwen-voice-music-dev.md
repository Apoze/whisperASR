# E27 — Qwen + Spleeter vocals DEV (#93)

**Decision: NO-GO-stop-before-holdout.** Holdout fermé.

- Raw Qwen global : delta parole -31; termes/nombres/sens +0/+0/+0.
- Exemples raw récupérés : ['フルセット', 'ではなく', '仲良くな', 'おおや', 'すごい']; perdus : ['ちゃんいかが', 'してるけど', 'いい試合', 'ちなみに', 'んじゃ'].
- Termes candidat récupérés/perdus : ['立川']/['百鬼襲']; nombres : ['5', '2', '3', '1', '9000', '1000', '4']/['10000', '2800']; sens : ['チャンス', '次の試合', 'あります']/[].
- Fenêtres ciblées : diagnostic aligné non promotionnel (13/18), car l'alignement a échoué.
- Prétraitement : 9.6s; job inchangé : 133.8s.
- Anglais FINAL : absent (porte rouge).
- Portes : `{"cleanAudioByteIdentical": true, "cleanControlTextIdentical": false, "costNotRunaway": true, "developmentOnly": true, "finalEnglishPresent": false, "moreTargetSpeechRecoveredThanErased": false, "noNetNewTargetEmptiesOrDuplicates": false, "noTargetSpeechErased": false, "pipelineCompleted": false, "protectedScreamLaughterSoftVoiceNotWorse": false, "rawGlobalSpeechNotWorse": false, "rawGlobalTermsNumbersMeaningNotWorse": false, "rawOutputNotEmptyOrMoreDuplicated": true, "targetTermsNumbersMeaningNotWorse": false, "targetWindowScoreValid": false}`.

Les SHA des audio complets et montages avant/après sont conservés. Le raw JA candidat et le JA/EN baseline sont versionnés; aucun EN candidat n'a été produit.
