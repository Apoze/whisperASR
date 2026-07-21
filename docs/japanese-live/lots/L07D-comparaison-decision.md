# L7D — Comparaison et décision

## Dépendances

L7C au commit `abe7e50`; agrégat `l7c-aggregate-20260721T173540Z`, comparaison SHA-256 `e75cd2dd0d35ca252007491ec848597b0829c7cb6126d37427f6141733a0e31a`.

## Objectif

Comparer séparément le japonais, la preview anglaise, le final anglais, la latence et les ressources des onze pipelines réellement tentés. Désigner le meilleur résultat observé sans transformer les diagnostics automatiques en jugement humain.

## Hors-périmètre

- Intégrer un moteur au produit ou ajouter une dépendance.
- Déclencher Qwen 0.6B, l'alignement L6A ou un arbitrage GPT Pro sans gate d'entrée.
- Présenter chrF++ comme une vérité bilingue.
- Promouvoir avec des références `pending-human-review`.

## Fichiers touchés

- `Scripts/report_japanese_l7d.py`
- `docs/japanese-live/README.md`
- `docs/japanese-live/lots/L07C-deux-videos-completes.md`
- cette fiche

## Tests

```text
/usr/bin/python3 -m py_compile Scripts/report_japanese_l7d.py
/usr/bin/python3 Scripts/report_japanese_l7d.py --self-test
/usr/bin/python3 Scripts/report_japanese_l7d.py \
  --aggregate .build/benchmarks/japanese-live/runs/l7c-aggregate-20260721T173540Z \
  --source-root . \
  --output .build/benchmarks/japanese-live/runs/l7d-decision-20260721T173540Z
```

Le rapport est généré deux fois puis comparé octet par octet. Le scoring utilise uniquement la bibliothèque standard : chrF++ diagnostic, couverture temporelle, négations, nombres et réponses courtes. Le JSON conserve aussi révisions de preview, réécritures de préfixe confirmé, stabilité des finals, CPU et thermique. Les noms restent non scorables car les manifestes ne contiennent aucun `criticalTerms`.

Audit `ponytail`/`code-structure` : aucun paquet ajouté, aucun runtime produit, aucune abstraction partagée créée pour ce flux unique. La dernière review subagent L7D n'a pas pu démarrer à cause d'un hook Codex local manquant (`campaignctl.py`); l'audit main agent et les contrôles déterministes ci-dessus ne trouvent aucun blocage.

## Preuves

- Rapport simple : `.build/benchmarks/japanese-live/runs/l7d-decision-20260721T173540Z/report-fr.md`.
- Données détaillées : `.build/benchmarks/japanese-live/runs/l7d-decision-20260721T173540Z/comparison-l7d.json`.
- Japonais humain vers Apple highFidelity : 470/470 tours, couverture 100 %, p95 97 ms, chrF++ diagnostic 52,3.
- Apple preview commune : p50 1,14 s, p95 1,64 s, pire 5,74 s.

## Décision

Aucun pipeline ne passe tous les gates; L8 reste bloqué.

Le meilleur final observé est `Kotoba Whisper v2.0 Q5 → Apple highFidelity` : CER groupé 45,9 %, dernière parole présente sur les deux vidéos, RSS 1,39 Gio et backlog final nul. Son final p95 de 1,75 s dépasse toutefois le SLO de 1,5 s.

Voxtral Q4/960 reste le meilleur sur `md62mmdz0m` avec 19,3 % de CER et un final p95 proche de 1,01 s, mais il perd la dernière parole de `qudu2fx3ncc`, n'en traduit plus la fin et dépasse le budget mémoire relatif. Il n'est pas promotable.

Architecture de développement recommandée : `Apple Speech lowLatency preview → Kotoba Q5 final → Apple highFidelity final`. Ce n'est pas une décision d'intégration tant que les deux juges bilingues n'ont pas validé les références et que les SLO preview/final ne sont pas atteints.

## Rollback

Supprimer le script et cette fiche, puis restaurer l'index et la décision L7C. Les preuves sous `.build` sont ignorées par Git et peuvent être régénérées depuis l'agrégat L7C.
