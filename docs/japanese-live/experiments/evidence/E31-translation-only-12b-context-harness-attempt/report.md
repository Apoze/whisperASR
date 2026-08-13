# #106 — replay 12B non concluant (harnais)

Verdict : `INCONCLUSIVE_HARNESS_INPUT_MISMATCH`. Aucun verdict qualité 12B et ticket #106 non conclu.

Le harnais a rejoué les bons turns et glossaires, mais avec zéro contexte conversationnel. Les entrées figées et le produit utilisent `previous-accepted-v1` pour 307 cues vidéo 1 et 260 cues vidéo 2.

| Vidéo | Résultat observé | Traduction | RTF replay | Pic RSS / footprint | Pression / swap | Cleanup |
|---|---|---:|---:|---:|---|---|
| qudu2fx3ncc | arrêt intégrité unité 61, non comparable | 448.96 s | 0.469x | 2.86 / 6.95 GiB | normal / 0 B | worker sorti, unload vérifié, 75 % libre |
| md62mmdz0m | 260 cues produites, assertion contexte échouée | 398.82 s | 0.450x | 3.02 / 6.95 GiB | normal / -8 MiB | worker sorti, unload vérifié, 76 % libre |

chrF++ et COMET ne sont pas calculés : les requêtes ne sont pas scientifiquement comparables aux entrées figées. Un nouveau replay 12B exact est requis avant le dernier run intégré.
