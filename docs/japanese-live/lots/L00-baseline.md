# L0 — Baseline et pilotage

## Dépendances

Aucune.

## Objectif

Figer la machine, la toolchain, les preuves existantes et les gates avant toute comparaison de moteur.

## Hors-périmètre

- Modifier le pipeline produit.
- Déclarer un gagnant ASR.
- Assimiler les tests opt-in ignorés à des modèles réellement exécutés.

## Fichiers touchés

- `docs/japanese-live/README.md`
- `docs/japanese-live/lots/L00-baseline.md`

## Environnement figé

- HEAD d'entrée : `e53ae1266749f0c456947c106bd83ae0217f85dc`.
- Machine : MacBook Pro M5 Pro, macOS 26.5.2 (25F84).
- Toolchain : Xcode 26.6 (17F113), Apple Swift 6.3.3, cible `arm64-apple-macosx26.0`.
- FluidAudio : 0.15.5, révision `19600a485baa4998812e4654b70d2bab8f2c9949`.
- Voxtral Q4 : `iris-sfg/Voxtral-Mini-4B-Realtime-2602-4bit`, snapshot `12091661ce5f58788624fa49fad9ddbbf67cf063`.
- Patch runtime Voxtral : SHA-256 `67768e28e14087b79b7eae9960bf3e8719a64864b689949a312cb76177656efe`.

## Tests

Commande standard :

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

Résultat du 18 juillet 2026 : 224 tests exécutés, 23 tests opt-in ignorés, 0 échec.

## Preuves

Les preuves sont locales et ignorées par Git :

- Run preview : `.build/benchmarks/app-q4-960-canonical/`.
- Run final haute fidélité : `.build/benchmarks/app-q4-960-stable-canonical/`.
- Corpus canonique : SHA-256 `64ee5d98f5db01497d6b13354a17d4d0ba43776ae31699d7c73bb8b0c019c07c`.
- Manifeste canonique : SHA-256 `58c50cb447252bd08ad80f8a263dd08c3157454603d4b7f7b251593e4ecd5543`.
- Binaire mesuré : SHA-256 `d1c5a7429bbe1fcebab6dbbb9932499e0ab4109759c75f60e9a46279fa11639b`.

Baseline Voxtral Q4, délai 960 ms, transport 160 ms :

| Mesure | Valeur |
| --- | ---: |
| CER japonais produit exact | 22,7007 % (311 / 1 370 caractères) |
| Première preview par plage, p50 | 1 270,8 ms |
| Première preview par plage, p95 | 2 938,7 ms |
| Première preview par plage, pire | 5 615,8 ms |
| RSS combiné maximal | 4 185 313 288 octets (3,90 Gio) |
| Backlog helper maximal | 2 560 samples (160 ms) |
| Backlog helper final | 0 sample |
| PCM helper | 5 062 400 samples envoyés et acquittés; `pcmComplete=true` |

Le CER et les previews proviennent de deux runs de traduction différents sur le même corpus : le run `adaptive` mesure les previews et le run `highFidelityOnly` mesure le CER produit. Ce dernier ne contient aucune preview. Cette séparation est conservée au lieu de fabriquer un agrégat end-to-end. Le baseline dépasse le SLO preview et sert uniquement de témoin.

Limites de provenance : les captures précèdent le HEAD d'entrée et leurs sidecars ne stockent pas le commit Git, Xcode ni le matériel. Le hash du binaire est connu, mais ces mesures restent `diagnostic-only` et ne sont pas attribuées strictement à HEAD. `pcmComplete` prouve le transport intégral vers le helper, pas un sous-titre pour chaque sample; le silence final explique vraisemblablement l'écart avec le curseur anglais, sans le démontrer. La vraie latence fin-de-parole → final n'est pas disponible.

Enfin, Voxtral Q4/960 est la configuration de ce témoin, pas le profil d'une installation neuve : le moteur local neuf actuel est Whisper Turbo + Apple.

## Format obligatoire des futurs rapports

Chaque rapport doit fournir : commit et état du worktree, corpus et SHA-256, modèle/révision/SHA-256, configuration complète, samples attendus/envoyés/consommés/finalisés, couverture de la dernière parole, métriques p50/p95/pire, RSS maximal et backlog final.

## Décision

L0 est accepté. Les SLO de l'index sont désormais fixes. Le prochain changement autorisé est la correction de l'oracle L1; aucun changement de moteur produit n'est justifié par ce baseline.

## Rollback

Supprimer uniquement `docs/japanese-live/`. Aucun code produit, modèle ou rapport local n'a été modifié.
