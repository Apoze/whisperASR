# E21 — DictationTranscriber et vocabulaire japonais

Date : 2026-08-02T18:18:43Z. Machine : MacBook Pro, macOS 26.5.2 (25F84). Locale : `ja-JP`. Commit de base : `a52d2b805c4d0c2d14accf135574bbdd8bb6a3df`, arbre prototype modifié. Run : `e21-dictation-20260802T180122Z`.

## Verdict

Arrêt du prototype : aucune configuration Dictation ne franchit simultanément les portes lexicales, CER et live. Aucun changement produit.

| Configuration | F1 lexical final | CER holdout | Δ CER | Couverture | Premier texte p50 / p95 / pire | Révisions | PCM | Tail | Erreurs | Retenue |
|---|---:|---:|---:|---:|---:|---:|---|---|---:|---|
| speech-control | 0,000 | 41,75 % | +0,00 pt | 98,36 % | 883 / 1 952 / 3 003 ms | 678 | complet | perdu | 0 | non |
| dictation-context-general | 0,000 | 76,38 % | +34,63 pt | 61,54 % | 889 / 4 137 / 6 048 ms | 115 | complet | perdu | 0 | non |
| dictation-context-vspo | 0,000 | 74,60 % | +32,85 pt | 63,16 % | 928 / 3 933 / 4 128 ms | 108 | complet | perdu | 0 | non |
| dictation-custom-general | 0,000 | 79,94 % | +38,19 pt | 55,77 % | 1 019 / 4 021 / 6 031 ms | 90 | complet | perdu | 0 | non |
| dictation-custom-vspo | 0,000 | 77,35 % | +35,60 pt | 59,65 % | 997 / 3 838 / 4 030 ms | 111 | complet | perdu | 0 | non |

## Protocole

- 39 replays ciblés E5 et 10 holdouts, même PCM certifié, blocs de 100 ms et finalisation progressive toutes les 1,5 s.
- Contrôle `SpeechTranscriber` sans hints ; `DictationTranscriber` avec `AnalysisContext` ; `DictationTranscriber` avec `SFSpeechLanguageModel` local.
- Modèles personnalisés : termes canoniques courts, 20 occurrences par terme et cinq prononciations X-SAMPA ciblées.
- Portes : F1 final strictement supérieur au contrôle du même profil, CER ≤ +2 points, couverture ≥ 95 %, premier texte p50 ≤ 1 s, p95 ≤ 1,8 s, pire ≤ 3 s, PCM complet et dernière parole présente.

## Actifs

- `SpeechTranscriber` et `DictationTranscriber` supportent réellement `ja-JP` sur ce Mac.
- Les actifs Dictation étaient absents puis ont été installés ; 72 phonèmes japonais sont exposés.
- Les deux modèles personnalisés et les cinq prononciations ont été compilés sans erreur d’actif.

## Preuves

- Résultats bruts : [`artifacts/E21-dictation-vocabulary.json`](artifacts/E21-dictation-vocabulary.json), SHA-256 `98290091aad1918a874aa87f14df8509de5276840eaec1f61bb48dc9fe65ed2d`.
- Le JSON contient tous les événements, textes, plages PCM, temps de réception, actifs et erreurs.
