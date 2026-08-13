# E03 — profils de traduction par domaine

Date : 2026-08-06. Base : `codex/issue-29-conversation-context` au commit `06a1bbc`. Run propre : commit `ebc1c4b5561ae2c19909315cb43648a83e0ac29f`, arbre source `6c06b94ffd70c9bb442b769224b54543b462ce69920aac43ee4c47595ffda749`.

## Décision

**Preuve insuffisante : ne retenir aucun profil de traduction par domaine.** L'[audit Apple](../research/E03-apple-translation-controls.md) ne trouve aucune API publique supportée pour imposer registre, style, domaine ou mapping terminologique à `TranslationSession`. `highFidelity` choisit une stratégie de modèle ; `skipsTranslation` laisse une plage inchangée mais ne lui assigne pas un rendu anglais.

Le prérequis échoue donc avant toute comparaison. Aucun profil Anime, VTuber, Gaming ou Conversation n'a été exécuté, aucun autre moteur ou prompt n'a été ajouté, et le glossaire japonais n'est pas devenu un post-correcteur anglais.

## Baseline figée et erreurs restantes

Qwen E0, FireRed `0,40 / 350 / 500 ms`, les compositions E1b-v2 et Apple highFidelity `current-only` restent byte-identiques. Le runner vérifie `sourceJapaneseMutationCount = 0` sur les sorties de référence et Qwen.

| Domaine | chrF++ final E0 | Réponses courtes | Négations | Nombres | Erreurs Apple E2 Qwen |
|---|---:|---:|---:|---:|---:|
| VTuber, multi-label | 52,95 | 16,42 sur 68 | 62/68 | 21/32 | 1 |
| Gaming | 46,29 | 10,95 sur 37 | 12/12 | 5/10 | 0 |
| Conversation | 50,42 | 22,96 sur 31 | 50/56 | 16/22 | 1 |
| Anime | n/a | n/a | n/a | n/a | n/a |

L'inventaire brut contient 269 finales scoreables depuis le japonais de référence et 271 depuis Qwen sans contexte. Il conserve 3 sorties Apple invalides côté référence et la sortie Qwen Conversation répétitive déjà diagnostiquée. Les signaux fragmentaires chrF, polarité, nombres, contractions et honorifiques restent diagnostiques : les frontières peuvent couper la référence et ils ne prouvent pas qu'un profil les corrigerait.

## Comparaisons arrêtées

Chaque bras prévu aurait contenu exactement `neutre + un profil`. Les quatre candidats ont produit zéro sortie : Anime faute de référence locale, les trois autres faute de mécanisme Apple supporté. Il n'y a donc aucune Promotion, notamment aucune Promotion Anime sans référence Anime.

## Artefacts et reproduction

Run : `.build/benchmarks/japanese-live/runs/e3-profiles-20260806T160109Z/`. Les 31 fichiers bruts occupent 66 364 610 octets, SHA-256 d'ensemble `463f654fbc4a6841c46c357204fccedb27e27a7793664c9ec4d3936d980ead0c`.

Ils incluent les deux PCM et leurs SHA, manifests, Qwen/FireRed, glossaires E1b-v2, japonais brut/général/sélectionné, anglais sans contexte et tentatives, événements live, frontières, erreurs, mémoire, thermique, interface Swift Apple, versions runtime, commit et état du worktree.

```bash
Scripts/run_japanese_e3_profiles.sh
```

Aucun changement produit et aucun travail sur le ticket suivant.
