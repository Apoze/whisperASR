# E04 — vrai streaming Qwen3-ASR officiel

Date : 2026-08-06. Base demandée : `codex/issue-30-domain-translation-profiles` au commit `fb5fc18`. Run propre : commit `9e151a19685e979ea004c0abf090331fdcfec8ab`, arbre source `225b2b560d24a3e5fe28474a6a9eb0e1ed2c949d677973a9a7377c7f483c7e1b`.

## Décision

**Preuve insuffisante.** Aucun candidat n'est promu.

Le [contrôle des sources officielles Qwen](../research/E04-qwen3-official-streaming.md) ferme deux prérequis :

1. le mode nommé streaming réinjecte tout `audio_accum` dans `model.generate` à chaque pas ; c'est un replay cumulatif, pas un état acoustique persistant ;
2. ce mode est limité à vLLM. Sur l'Apple M5 Pro arm64 local, `vllm==0.14.0` bascule en CPU puis échoue deux fois à compiler. Le paquet `qwen-asr` de contrôle se construit correctement.

Ce défaut de build appartient au backend, pas au modèle ni aux entrées. Aucun fork, port MLX ou correctif vLLM n'a été essayé.

Le complément `Qwen3-ASR-1.7B-JA` est aussi gelé comme comparaison conditionnelle : les mêmes poids exacts, non convertis et non modifiés, auraient dû alimenter offline et streaming. Le catalogue officiel de l'organisation Qwen, conservé avec le SHA-256 `8740c9d311e43dd98a5628bae101ae367e38ee49776357203cda86083252fe5f`, ne publie toutefois pas `Qwen/Qwen3-ASR-1.7B-JA`. Aucun poids homonyme non officiel n'est donc téléchargé ni testé ; les veto streaming réel et Apple Silicon auraient de toute façon arrêté l'expérience avant l'inférence.

## Pins officiels

| Élément | Pin |
|---|---|
| `QwenLM/Qwen3-ASR` | commit `7c6daf77a2421100f5fb066495372c00129d39ff`, archive SHA-256 `158145dd34d91528ebfe28bf7c9bf64fd3a792ec307f651f048b1da8c76dbb87` |
| `qwen-asr` / streaming | `0.0.6` / `vllm==0.14.0` |
| Poids principal | `Qwen/Qwen3-ASR-1.7B` révision `7278e1e70fe206f11671096ffdd38061171dd6e5` |
| Shard 1 | 4 220 320 824 octets, SHA-256 LFS `a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6` |
| Shard 2 | 478 200 688 octets, SHA-256 LFS `6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc` |
| Ensemble des poids | 4 698 521 512 octets, SHA-256 canonique `7bcd622e079c2a180365e6c1362e700677c4518063cd6a5ee9959a64b216994f` |

Les modes offline vLLM et streaming peuvent partager ces poids, `temperature=0`, `maxTokens=32`, langue japonaise et contexte vide. Le streaming ajoute obligatoirement `chunk=2 s`, rollback `2 chunks / 5 tokens` et un préfixe textuel : la configuration d'orchestration n'est donc pas littéralement identique.

## Protocole et portes

L'entrée E3 est copiée et revalidée : 31 fichiers, 66 364 610 octets, SHA-256 d'ensemble `463f654fbc4a6841c46c357204fccedb27e27a7793664c9ec4d3936d980ead0c`. Les deux PCM gardent leurs SHA `494577ab…` et `bde49d4c…`. FireRed reste `0,40 / 350 / 500 ms`, le glossaire `E1b-v2`, Apple Translation sans contexte ni profil.

La cadence prévue était 500 ms en temps réel, avec conservation de chaque sortie. Le veto intervient avant injection ; aucune sortie incrémentale n'existe.

| Porte | qwenApple gelé | Candidat officiel |
|---|---|---|
| Preview | échec | non évalué — veto prérequis |
| Final | échec | non évalué — veto prérequis |
| Mémoire | échec | non évalué — veto prérequis |
| Intégrité | échec | non évalué — veto prérequis |

Les comparaisons offline/streaming à variable unique — modèle Qwen officiel principal et variante `Qwen3-ASR-1.7B-JA` conditionnelle — ainsi que la baseline secondaire qwenApple sont non exécutées. VTuber, Gaming et Conversation restent mesurables uniquement côté références gelées ; Anime a zéro référence locale et reste non promotable.

## Artefacts et diagnostic runner

Run autoritaire : `.build/benchmarks/japanese-live/runs/e4-official-streaming-20260806T170900Z/`. Il contient 112 fichiers, 73 360 313 octets, SHA-256 d'ensemble `daac546b0a8d069b68091cacf19ec481386da7a488e7d4b4ebb4b98f9a2d9ea8` : entrée complète, sources Qwen, model cards, catalogue officiel, métadonnées LFS, versions machine, contrôle, deux logs vLLM et décision JSON.

Le run non autoritaire `e4-official-streaming-20260806T164844Z` a reproduit un défaut du runner : `xcode-select` pointait vers CommandLineTools. Le contrôle avec `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` passe ; le runner fixe désormais ce chemin. Cet incident n'est pas attribué au candidat.

```bash
WHISPERASR_E4_PYTHON=/chemin/vers/python3.12 Scripts/run_japanese_e4_streaming.sh
```

Aucun changement produit et aucun travail sur le ticket suivant.
