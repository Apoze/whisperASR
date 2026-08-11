# Fun-ASR-Nano int8 — licence, poids et runtime Apple Silicon (#88)

Date : 2026-08-12
Périmètre : sources primaires uniquement ; aucun poids, binaire ou modèle téléchargé, aucun smoke exécuté.

## Verdict

**READY_FOR_LIGHT_RUNTIME_PREFLIGHT, pas READY_FOR_HEAVY_BENCHMARK.** Le modèle int8 et un runtime CPU macOS arm64 existent et sont épinglables par SHA-256. Deux réserves doivent rester visibles avant le smoke réel : l'archive ONNX ne publie pas la révision exacte du checkpoint FunAudioLLM dont elle dérive, et les timestamps FunASR de sherpa-onnx sont interpolés uniformément, pas alignés acoustiquement.

## Faits vérifiés

### Licence et révisions

- Le dépôt modèle [`FunAudioLLM/Fun-ASR-Nano-2512`](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512) déclare `Apache-2.0`. Révision HF observée et épinglable : [`272c57b82523ada6fd87095e955f8e29100979ab`](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512/tree/272c57b82523ada6fd87095e955f8e29100979ab). Son `model.pt` publié fait 1 971 149 431 octets et porte le SHA-256 `55ae0d2fee369f0f11cce0795f6927934ad17cf11b278a7e56a51272074160bb` dans les [métadonnées HF](https://huggingface.co/api/models/FunAudioLLM/Fun-ASR-Nano-2512?blobs=true).
- [`sherpa-onnx`](https://github.com/k2-fsa/sherpa-onnx) est sous [Apache-2.0](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.5/LICENSE). Runtime retenu : tag [`v1.13.5`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.5), commit `3dc7c569f31ca2cd4a20ed6f7db780327e6714c5`.
- Le convertisseur indiqué par la [documentation sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/funasr-nano/export.html), [`Wasser1462/FunASR-nano-onnx`](https://github.com/Wasser1462/FunASR-nano-onnx/tree/6823a8ed9f4a0393750d54d750051cf5a51a7fa9), n'a ni release ni licence déclarée. Il n'est pas nécessaire pour exécuter l'archive préexportée et son code ne doit pas être copié.

### Poids int8 exacts

Archive officielle : [`sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2`](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2).

- Taille compressée publiée par l'API GitHub : `841730611` octets.
- SHA-256 publié par GitHub : `eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b`.
- Contenu requis documenté : `encoder_adaptor.int8.onnx` (~227 Mio), `llm.int8.onnx` (~573 Mio), `embedding.int8.onnx` (~149 Mio), plus `Qwen3-0.6B/{merges.txt,tokenizer.json,vocab.json}` (~16 Mio). Total ONNX annoncé : ~948 Mio. Source : [liste officielle](https://k2-fsa.github.io/sherpa/onnx/funasr-nano/export.html).
- L'archive courante a été republiée le 2026-04-12 après le correctif [`#3493`](https://github.com/k2-fsa/sherpa-onnx/pull/3493), qui remplace le LLM int8 problématique par `llm_int8_compat` tout en gardant le nom `llm.int8.onnx`.
- GitHub publie le hash de l'archive, pas les hashes individuels des trois ONNX. Il faudra les calculer après téléchargement autorisé et les conserver dans la provenance du run.
- `int8` désigne ici une quantification dynamique des poids ONNX, pas un graphe entièrement entier : activations et opérations non quantifiées restent flottantes. Le variant `llm_int8_compat` actuel peut différer du script d'export public ; son signedness et ses types d'opérateurs ne sont pas certifiables sans inspection locale de l'ONNX.

**Limite de provenance :** aucune source officielle consultée ne relie cette archive à un commit précis du dépôt HF FunAudioLLM. Le SHA-256 de l'archive épingle donc exactement les bits évalués, mais la révision amont `272c…` ne doit pas être présentée comme leur source prouvée.

### Runtime macOS arm64 exécutable

Artefact minimal retenu : [`sherpa-onnx-v1.13.5-osx-arm64-shared-no-tts.tar.bz2`](https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.5/sherpa-onnx-v1.13.5-osx-arm64-shared-no-tts.tar.bz2), `17880704` octets, SHA-256 `77c46d0e7d383735b7dd9713313ddf764815e829503b0b917ff51ac31be2e897` (métadonnées de la [release v1.13.5](https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/v1.13.5)). Son nom cible explicitement `osx-arm64`, avec bibliothèques partagées, exécutables et TTS désactivé ; le préflight ci-dessous doit encore vérifier localement son architecture et ses dépendances.

Faits complémentaires :

- La documentation officielle supporte Apple Silicon et produit un exécutable dans `bin` ([build macOS](https://k2-fsa.github.io/sherpa/onnx/install/macos.html)).
- FunASR Nano est supporté depuis `v1.12.20`, l'API Swift depuis `v1.12.21`; `v1.13.5` inclut les corrections tokenizer, modèle int8 compatible et API Swift listées dans le [changelog](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.5/CHANGELOG.md).
- Le chemin est CPU sur macOS (`provider=cpu`). Les exemples FunASR officiels n'offrent que `cpu`/`cuda`; aucun gain Core ML/Metal n'est démontré pour ce backend ([exemple Python v1.13.5](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.5/python-api-examples/offline-funasr-nano-decode-files.py)).

Alternative pour le worker Python existant : installer exactement `sherpa-onnx==1.13.5`, `sherpa-onnx-bin==1.13.5` et `sherpa-onnx-core==1.13.5`. PyPI publie des wheels `macosx_11_0_arm64` pour Python 3.8 à 3.14 ([métadonnées officielles](https://pypi.org/pypi/sherpa-onnx/1.13.5/json)). Pour Python 3.14 :

| Wheel | Octets | SHA-256 |
|---|---:|---|
| `sherpa_onnx-1.13.5-cp314-cp314-macosx_11_0_arm64.whl` | 2 140 247 | `97471fe025fc1d655a1df2f4ffb5d3fe843c269f2016d5e1cca4b0d168a49169` |
| `sherpa_onnx_bin-1.13.5-py3-none-macosx_11_0_arm64.whl` | 12 161 262 | `adde004b9d4bd2df471b9df005bc5157e9cd4a335b17de5a73d3e7e0f21db7b4` |
| `sherpa_onnx_core-1.13.5-py3-none-macosx_11_0_arm64.whl` | 9 282 744 | `899e88916efd96ee1eabc512e9ceaf2fdb711b20b2512cf40358b623e90b5ded` |

## API et commande préparée

La voie la plus courte pour le worker est le CLI `bin/sherpa-onnx-offline`; sherpa fournit aussi une [API Swift FunASR](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.5/swift-api-examples/funasr-nano.swift), mais elle impose le même C API et les mêmes quatre chemins. Aucune pipeline parallèle n'est requise : le worker existant peut lancer ce CLI isolé et parser son JSON.

Préflight léger, sans modèle :

```bash
file bin/sherpa-onnx-offline
otool -L bin/sherpa-onnx-offline
bin/sherpa-onnx-offline --help | rg 'funasr-nano'
```

Commande de smoke préparée, **non exécutée** :

```bash
bin/sherpa-onnx-offline \
  --funasr-nano-encoder-adaptor="$MODEL/encoder_adaptor.int8.onnx" \
  --funasr-nano-llm="$MODEL/llm.int8.onnx" \
  --funasr-nano-embedding="$MODEL/embedding.int8.onnx" \
  --funasr-nano-tokenizer="$MODEL/Qwen3-0.6B" \
  --funasr-nano-language='日文' \
  --funasr-nano-itn=false \
  --funasr-nano-hotwords='' \
  --provider=cpu \
  --num-threads=2 \
  --debug=false \
  "$INPUT_WAV"
```

`language='日文'` fixe la tâche japonaise ; `itn=false` désactive la normalisation de texte interne ; la chaîne hotwords vide désactive les hotwords. Aucun VAD ni prétraitement additionnel n'est présent. Les autres paramètres restent aux valeurs officielles : système `You are a helpful assistant.`, tâche `语音转写…`, `max_new_tokens=512`, `temperature=1e-6`, `top_p=0.8`, `seed=42`. Les flags et defaults viennent du [config C++ v1.13.5](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.5/sherpa-onnx/csrc/offline-funasr-nano-model-config.cc).

## Incompatibilités et inférences

- **Fait : timestamps non acoustiques.** Le backend remplit `result.timestamps` en répartissant uniformément les tokens générés sur la durée audio effective ([source v1.13.5, bloc `Calculate timestamps`](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.5/sherpa-onnx/csrc/offline-recognizer-funasr-nano-impl.cc#L811-L835)). Ils ne prouvent donc ni début de mot ni frontière acoustique.
- **Inférence :** pour respecter #88, ces timestamps doivent être traités seulement comme sortie brute auditée. Les timestamps finaux doivent continuer à venir de la segmentation et de l'alignement figés du High-quality job, pas de cette interpolation.
- **Fait :** le modèle est non streaming dans sherpa-onnx; il convient au job offline et ne change pas Live.
- **Inférence :** le CPU Apple Silicon est techniquement éligible, mais ni temps réel, ni RSS, ni absence de runaway ne peuvent être conclus sans smoke réel. Le premier smoke doit donc rester court, isolé et soumis aux arrêts pression/temps de #88.
- **Impossibilité actuelle :** sans télécharger l'archive autorisée, il est impossible de vérifier son `README.md`, les hashes individuels et l'architecture réelle des ONNX. Ces contrôles doivent précéder tout chargement de modèle.

## Décision de passage

Passer au téléchargement contrôlé et au smoke uniquement après annonce `READY_FOR_HEAVY_BENCHMARK` contenant : les deux URLs ci-dessus, environ `0,84 Go` de téléchargement modèle, environ `1,0 Go` extrait plus `18 Mo` de runtime, la durée visée du smoke, la mémoire surveillée et les commandes de hash. Un échec d'architecture/runtime, de hash, de provenance ou de sortie intègre est un **NO-GO documenté**, pas un Candidate failure.
