# E04 — vrai streaming Qwen3-ASR officiel

Date d'accès : 2026-08-06. Base du projet : `fb5fc18ba9ab7c1181e4e86ca299c3c3ef47aaf9`. Sources admises : uniquement le dépôt `QwenLM/Qwen3-ASR`, ses model cards `Qwen/*` et ses pages de releases officielles. Aucun fork, port MLX ou runtime tiers n'a été retenu.

## Décision

**Preuve insuffisante : ne pas lancer la comparaison E4.**

Deux prérequis échouent avant le benchmark :

1. L'API officielle est bien incrémentale du point de vue de l'appelant, mais elle réinjecte explicitement **tout l'audio accumulé depuis le début** dans un nouvel appel `model.generate` à chaque pas. C'est un replay cumulatif d'inférence, pas un runtime acoustique streaming qui conserve et prolonge un état encodeur/KV. Le gate « vrai streaming, pas découpage offline ou replay simulé » échoue.
2. Le streaming officiel est refusé hors backend vLLM. Les seules instructions officielles de ce chemin ciblent CUDA/NVIDIA ; aucune release, procédure, exécution ou validation officielle macOS arm64/Apple Silicon n'est fournie. Le gate « fonctionne réellement sur Apple Silicon » échoue.

Les mêmes poids et paramètres de sampling peuvent en revanche être utilisés par les deux méthodes du wrapper vLLM officiel. Ce point positif ne lève pas les deux blocages précédents.

Conséquence : aucun bras officiel offline/streaming, aucune baseline secondaire qwenApple, aucune Promotion et notamment aucune Promotion Anime ne doivent être produits pour ce ticket. L'entrée gelée `/Users/maz/Documents/projets/whisperASR-issue-30/.build/benchmarks/japanese-live/runs/e3-profiles-20260806T160109Z` et son manifest SHA `463f654fbc4a6841c46c357204fccedb27e27a7793664c9ec4d3936d980ead0c` restent inchangés ; ils doivent être copiés et validés dans les artefacts, sans injection PCM dans un candidat inadmissible.

## Gate 1 — nature du streaming officiel

La documentation Qwen annonce un modèle unique pour les modes offline et streaming, puis précise que le streaming du package est disponible seulement avec vLLM ([README figé, présentation et Streaming Inference](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/README.md#streaming-inference)). Cette appellation officielle ne suffit pas au critère plus strict du ticket ; l'implémentation fait foi :

- `ASRStreamingState` conserve un buffer PCM, `audio_accum`, le texte précédent et les paramètres de rollback ; aucun état acoustique du modèle n'y figure ([état officiel](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L77-L128)).
- La docstring dit explicitement que chaque chunk est ajouté à `audio_accum`, puis que **tout** l'audio vu jusque-là est réinjecté au modèle ([contrat de `streaming_transcribe`](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L657-L695)).
- Le code concatène le chunk, construit un préfixe textuel par rollback, passe `state.audio_accum` entier à `self.model.generate`, puis remplace l'hypothèse courante ([boucle officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L715-L765)). La finalisation réinjecte elle aussi l'audio cumulé entier ([finalisation officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L767-L830)).

Cause racine : le mode officiel est une orchestration incrémentale autour d'inférences cumulatives complètes. Transformer ce chemin en encodeur causal avec cache persistant demanderait un autre runtime ou une adaptation du modèle, tous deux interdits par le ticket.

Verdict du gate 1 : **échec — preuve insuffisante d'un vrai runtime streaming sans replay cumulatif.**

## Gate 2 — Apple Silicon

`init_streaming_state`, `streaming_transcribe` et `finish_streaming_transcribe` lèvent une erreur quand le backend n'est pas vLLM ([garde officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L584-L628)). Le package officiel fige `vllm==0.14.0`; son extra streaming est `qwen-asr[vllm]` ([`pyproject.toml`](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/pyproject.toml#L35-L39)).

Dans les seules instructions Qwen disponibles :

- l'installation vLLM utilise les index de wheels `cu129` ([installation officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/README.md#installation-1)) ;
- le choix de périphérique du démo est exclusivement documenté via `CUDA_VISIBLE_DEVICES` ([notes CUDA officielles](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/README.md#cuda-device-notes)) ;
- l'image officielle part de `nvidia/cuda:12.8.0-devel-ubuntu22.04` ([Dockerfile officiel](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/docker/Dockerfile-qwen3-asr-cu128#L1-L7)).

Le code Transformers contient une mention `mps`, limitée à un contournement d'`autocast` dans le backend offline ([source officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/core/transformers_backend/modeling_qwen3_asr.py#L819-L837)). Ce n'est ni un backend streaming MPS, ni une preuve d'exécution sur Apple Silicon.

Cause racine documentaire et technique : Qwen lie son streaming à vLLM, mais ne publie dans ce dépôt aucun chemin vLLM macOS arm64, artefact Apple, test Apple ou résultat d'exécution Apple. Avec les sources autorisées, il est impossible d'attester un fonctionnement réel.

Verdict du gate 2 : **échec — preuve insuffisante sur Apple Silicon.** Cela n'affirme pas que toute exécution future est impossible ; cela constate l'absence de chemin officiel vérifié au 2026-08-06.

### Autres surfaces officielles examinées

- Les nouvelles model cards Transformers natives `Qwen3-ASR-*-hf` revendiquent elles aussi le modèle unifié offline/streaming, mais leur rubrique d'usage ne fournit que des appels sur audio complet à `model.generate` et aucun état, protocole ou exemple incrémental ([model card 1.7B-hf figée](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf/blob/bcd2b5b7f32b480ab5790554cfa8347f246a14f3/README.md)). Elles ne constituent donc pas un runtime streaming Transformers/MPS officiel.
- Le README Qwen liste une API DashScope « Real-time » et une API « FileTrans » ([table officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/README.md#dashscope-api-usage)). Le dépôt ne publie pour ces services ni poids téléchargeables, ni révision commune, ni SHA permettant de prouver que les deux modes emploient exactement les mêmes poids. Un service distant ne prouve pas non plus l'exécution du runtime sur Apple Silicon. Ce chemin ne satisfait donc pas les gates 2 et 3.

### Checkpoint exact `Qwen3-ASR-1.7B-JA`

**Preuve insuffisante : aucun checkpoint officiel Qwen/QwenLM nommé `Qwen3-ASR-1.7B-JA` n'est publié au 2026-08-06.**

Les trois inventaires officiels concordent :

- le dépôt QwenLM annonce seulement `Qwen3-ASR-1.7B`, `Qwen3-ASR-0.6B` et `Qwen3-ForcedAligner-0.6B`, avec leurs variantes Transformers `-hf` ([modèles publiés](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/README.md#released-models-description-and-download)) ;
- la [collection officielle Qwen3-ASR](https://huggingface.co/collections/Qwen/qwen3-asr) contient exactement les deux ASR multilingues, leurs deux variantes `-hf`, les deux forced aligners et le démo ; aucun suffixe `-JA` ;
- la [recherche Hugging Face bornée au propriétaire officiel `Qwen`](https://huggingface.co/api/models?author=Qwen&search=Qwen3-ASR-1.7B-JA&full=true) renvoie une liste vide pour le nom exact.

Il n'existe donc, dans le périmètre de sources autorisé, ni model card officielle, ni révision, ni fichier de poids, ni taille, ni SHA à figer pour `Qwen3-ASR-1.7B-JA`. Le checkpoint multilingue `Qwen/Qwen3-ASR-1.7B` ne peut pas lui être substitué : ce serait changer les poids exacts demandés.

Le runtime officiel accepte techniquement une chaîne `model` générique : `Qwen3ASRModel.LLM` transmet ce chemin directement à `vllm.LLM`, charge le processor depuis le même chemin, puis les modes offline et dit streaming réutilisent ce même objet ([chargement officiel](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L226-L288)). Cela prouve la mécanique générique sans conversion pour un checkpoint compatible ; cela ne certifie pas un checkpoint absent des publications Qwen. Sans config, révision et SHA officiels de `Qwen3-ASR-1.7B-JA`, il est impossible de prouver que vLLM peut charger **ces mêmes poids** sans conversion et les utiliser dans les deux modes.

Verdict complémentaire : **échec — preuve insuffisante sur l'existence officielle et la compatibilité directe de `Qwen3-ASR-1.7B-JA`.** Les conclusions de replay cumulatif et d'absence de preuve Apple Silicon restent inchangées.

## Gate 3 — mêmes poids et paramètres

Ce gate passe seulement en principe sur une machine officiellement supportée :

- la model card annonce une inférence offline/streaming unifiée avec un seul modèle ([model card Qwen 0.6B figée](https://huggingface.co/Qwen/Qwen3-ASR-0.6B/blob/5eb144179a02acc5e5ba31e748d22b0cf3e303b0/README.md#overview)) ;
- `Qwen3ASRModel.LLM` charge une seule fois le chemin `model` et crée `SamplingParams(temperature=0.0, max_tokens=max_new_tokens)` ([initialisation vLLM officielle](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L226-L288)) ;
- le chemin offline vLLM et le chemin dit streaming appellent le même `self.model.generate` avec le même `self.sampling_params` ([offline](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L521-L537), [streaming](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/inference/qwen3_asr.py#L748-L754)).

Les réglages `chunk_size_sec`, `unfixed_chunk_num` et `unfixed_token_num`, ainsi que le préfixe textuel réinjecté, sont propres au mode streaming. Ils font partie de son algorithme officiel et n'ont pas d'équivalent offline. Les poids, le PCM source, la langue, le contexte, `temperature` et `max_tokens` peuvent être identiques ; la configuration d'orchestration ne peut pas être littéralement identique.

Verdict du gate 3 : **poids et paramètres de décodage identiques possibles, mais pas une expérience admissible tant que les gates 1 et 2 échouent.**

## Runtime et poids figés

Le dépôt officiel ne publie ni tag ni GitHub Release au 2026-08-06 ([releases officielles](https://github.com/QwenLM/Qwen3-ASR/releases), [tags officiels](https://github.com/QwenLM/Qwen3-ASR/tags)). Le seul pin logiciel officiel immuable utilisable est donc le commit :

| Composant | Pin vérifié |
| --- | --- |
| Dépôt `QwenLM/Qwen3-ASR` | `7c6daf77a2421100f5fb066495372c00129d39ff` |
| Version déclarée `qwen-asr` | `0.0.6` |
| Backend streaming | `vllm==0.14.0` |
| Dépendances explicitement figées | `transformers==4.57.6`, `accelerate==1.12.0`, `nagisa==0.2.11`, `soynlp==0.0.493` |

Ces valeurs viennent du [`pyproject.toml` au commit figé](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/pyproject.toml). Plusieurs autres dépendances y restent sans version ; `0.0.6` seul ne fige donc pas un environnement complet. Un futur réexamen devra partir du commit, résoudre l'environnement et en enregistrer le lock brut.

L'exemple streaming officiel choisit `Qwen/Qwen3-ASR-1.7B` ([exemple officiel figé](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/examples/example_qwen3_asr_vllm_streaming.py#L17-L105)). Les deux révisions de poids officielles compatibles avec l'API sont toutefois inventoriées pour rendre la recherche reproductible :

| Modèle Qwen officiel | Révision Hugging Face | Fichier de poids | Octets | SHA-256 LFS |
| --- | --- | --- | ---: | --- |
| `Qwen/Qwen3-ASR-0.6B` | `5eb144179a02acc5e5ba31e748d22b0cf3e303b0` | `model.safetensors` | 1 876 091 704 | `79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea` |
| `Qwen/Qwen3-ASR-1.7B` | `7278e1e70fe206f11671096ffdd38061171dd6e5` | `model-00001-of-00002.safetensors` | 4 220 320 824 | `a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6` |
| `Qwen/Qwen3-ASR-1.7B` | `7278e1e70fe206f11671096ffdd38061171dd6e5` | `model-00002-of-00002.safetensors` | 478 200 688 | `6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc` |

Les tailles, révisions et OID LFS sont exposés par les inventaires officiels du compte Qwen : [0.6B HTML](https://huggingface.co/Qwen/Qwen3-ASR-0.6B/tree/5eb144179a02acc5e5ba31e748d22b0cf3e303b0), [0.6B API](https://huggingface.co/api/models/Qwen/Qwen3-ASR-0.6B/tree/5eb144179a02acc5e5ba31e748d22b0cf3e303b0?recursive=true&expand=true), [1.7B HTML](https://huggingface.co/Qwen/Qwen3-ASR-1.7B/tree/7278e1e70fe206f11671096ffdd38061171dd6e5) et [1.7B API](https://huggingface.co/api/models/Qwen/Qwen3-ASR-1.7B/tree/7278e1e70fe206f11671096ffdd38061171dd6e5?recursive=true&expand=true). Comme aucun benchmark n'est admissible, aucun de ces deux modèles n'est promu ni déclaré poids expérimental E4.

## API PCM et sorties incrémentales

La surface officielle disponible est :

1. `init_streaming_state(context, language, unfixed_chunk_num, unfixed_token_num, chunk_size_sec)` ;
2. appels successifs à `streaming_transcribe(pcm16k, state)` avec un tableau mono 16 kHz `float32`, `float64` ou `int16` ;
3. lecture après chaque appel de `state.language` et `state.text` ;
4. `finish_streaming_transcribe(state)` pour vider la queue finale.

Le démo HTTP officiel transpose cette surface en `POST /api/start`, `POST /api/chunk?session_id=...` avec corps `application/octet-stream` en Float32 16 kHz, réponse JSON `{language,text}`, puis `POST /api/finish` ([endpoints officiels](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/cli/demo_streaming.py#L417-L469)). Son navigateur capture le microphone, rééchantillonne à 16 kHz et pousse des blocs de 500 ms, donc l'entrée micro suit naturellement le temps réel ([client officiel](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/qwen_asr/cli/demo_streaming.py#L268-L370)).

Limite décisive pour l'expérience demandée : l'exemple officiel sur fichier tranche le WAV en pas de 500/1000/2000/4000 ms mais les envoie dans une boucle sans attente de cadence réelle ([replay fichier officiel](https://github.com/QwenLM/Qwen3-ASR/blob/7c6daf77a2421100f5fb066495372c00129d39ff/examples/example_qwen3_asr_vllm_streaming.py#L64-L101)). Le démo ne journalise pas non plus toutes les hypothèses ni leurs horodatages ; il remplace le texte affiché. Injecter le PCM gelé à cadence réelle et conserver chaque réponse exigerait donc un runner de mesure autour de l'API. Ce runner ne corrigerait toutefois pas le replay cumulatif interne et ne doit pas être construit tant que les gates 1 et 2 restent fermés.

## Condition de réouverture

Réexaminer E4 seulement si Qwen/QwenLM publie officiellement les trois preuves suivantes :

1. un chemin streaming qui prolonge un état acoustique sans réinjecter tout l'audio depuis zéro ;
2. une release ou une procédure macOS arm64 testée par Qwen pour ce même chemin ;
3. des pins immuables du runtime et des poids permettant d'exécuter offline et streaming avec le même modèle et les mêmes paramètres de décodage.
