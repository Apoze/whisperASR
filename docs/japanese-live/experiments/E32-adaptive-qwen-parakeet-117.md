# E32 — Adaptive Qwen → Parakeet ASR (#117)

**Décision : RETAIN-HIDDEN / NO-GO DEV.** Holdout fermé, Live et défaut inchangés.

- Commande autorisée : `BENCHMARK_SLOT_GRANTED=117 bash Scripts/run_adaptive_asr_117.sh full`.
- DEV figé `qudu2fx3ncc` : 169 segments acoustiques déterministes de 3–8 s, sans référence dans le détecteur ou le sélecteur.
- Qwen a traité les 169 segments en premier ; Parakeet a traité seulement les 26 segments suspects, après sortie complète de Qwen.
- Calibration séparée Qwen/Parakeet instable sur cinq blocs : le sélecteur de production s'abstient. Sélections Parakeet 0, fallback Qwen 169, veto d'intégrité 9.
- Japonais : 3278 → 2985 edits (+8,94 %), mais pertes critiques `1000` et `前に行かない`. Les portes stabilité, perte critique, variable figée et récupération utile sont rouges.
- Anglais : non exécuté. Les portes ASR DEV rouges imposent l'arrêt avant alignement/traduction ; aucune traduction ni donnée holdout n'a été ouverte.
- Temps ASR : Qwen segmenté 141,54 s, Parakeet incrémental 18,32 s, total 159,87 s ; incrément vs Qwen standard 33,89 s (1,269×).
- Pics : Qwen 7 314 019 080 octets (6,81 Gio), Parakeet 689 489 600 octets (0,64 Gio) ; swap inchangé, aucune terminaison forcée.
- Une erreur de mapping de références a été routée `harness`, corrigée avec un mapping indépendant par caractère, puis les bruts ASR DEV ont été réutilisés sous contrôle de hashes. La conclusion finale est routée `candidate`.
- Vérification : 16 tests ciblés, 0 échec, 2 lourds ignorés ; suite complète 480 tests, 0 échec, 64 opt-in ignorés.

La provenance compacte est dans `evidence/issue-117-adaptive-asr.json`. Les bruts sont conservés localement sous `.build/benchmarks/issue-117/` avec leurs SHA-256.
