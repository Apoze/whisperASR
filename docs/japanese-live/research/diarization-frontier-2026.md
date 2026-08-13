# Frontière diarisation locale japonaise — issue #85

## Décision

Le prochain essai utile n'est **pas** un nouveau réglage SpeakerKit. Les essais locaux ont déjà couvert les leviers raisonnables de cette famille et montrent un défaut plus profond de segmentation, d'activité et de représentation des voix.

Priorité proposée :

1. **MOSS-Transcribe-Diarize 0.9B**, d'abord en candidat isolé via son port GGML, car c'est une famille réellement différente, multilingue avec japonais, qui produit conjointement texte, temps et locuteurs. C'est la meilleure combinaison actuelle de nouveauté, licence et plausibilité sur Apple Silicon.
2. **DiariZen Large-s80-v2**, seulement comme plafond de qualité expérimental : sa représentation WavLM et son clustering sont différents, ses résultats publics sont solides, mais ses poids interdisent l'usage commercial et son runtime Apple n'est pas démontré.
3. **VibeVoice-ASR**, seulement si MOSS échoue. La famille est pertinente, mais le modèle officiel est beaucoup plus lourd et les preuves publiées sont moins favorables que MOSS pour l'attribution locuteur.

Un run Python officiel de **pyannote Community-1** peut servir de contrôle de parité, pas de nouveau candidat : SpeakerKit et FluidAudio Offline exécutent déjà cette même famille en Core ML.

## Ce qui a déjà été essayé — ne pas recommencer

### E5 : LS-EEND et Sortformer

Le rapport historique [E5](https://github.com/Apoze/whisperASR/blob/26ab68ddde68d6d2c95130c13dcb470ae412548a/docs/japanese-live/experiments/E05-diarization.md) a testé, sans modifier le produit :

- LS-EEND DIHARD3 à 8 kHz, blocs de 100 ms, activation/désactivation `0,60/0,40`, dominance `0,65`, marge `0,25`, confirmation sur deux frames ;
- Sortformer v2.1 `fast` et `balanced` fp16, blocs de 100 ms, seuils du runtime FluidAudio, marge `0,10`, confirmation sur deux frames ;
- deux replays des deux vidéos, changement de locuteur et overlap évalués séparément.

| Candidat | F1 changement dev / holdout | F1 overlap dev / holdout | Effet final |
|---|---:|---:|---|
| LS-EEND | 0,145 / 0,288 | 0,245 / 0,001 | trop de changements et de chevauchements inventés |
| Sortformer fast | 0,077 / 0,452 | 0,214 / 0,001 | meilleur sur une vidéo seulement, overlap inutilisable |
| Sortformer balanced | 0,084 / 0,476 | 0,194 / 0,001 | même limite |

Les trois candidats ont produit `8,6–12,6` faux changements/minute et `14,5–28,0` secondes de faux overlap/minute sans overlap annoté. Ils passaient le temps réel, la timeline et le déterminisme : la cause de rejet était bien la qualité du signal, pas un build ou un runner. Le premier run Sortformer, invalide à cause d'un défaut de frames mel FluidAudio, avait été écarté puis rejoué avec le correctif amont.

### SpeakerKit : famille et réglages déjà couverts

Le produit utilise le modèle épinglé `argmaxinc/speakerkit-coreml@86ec9c9`, segmenter/embedder `W8A16/W8A16`, comptage automatique, clustering par défaut, sortie non exclusive et attribution principale. Le code local est dans [HighQualitySpeakerKitRuntime.swift](../../../Sources/HighQualitySpeakerKitRuntime.swift). Le projet Argmax confirme que SpeakerKit est un port Core ML de [pyannote v4 Community-1](https://github.com/argmaxinc/argmax-oss-swift#speakerkit).

Les tickets #43/#48/#57–#60 ont déjà couvert : conservation des spans/overlaps, attribution principale sans duplication, réconciliation exclusive, modèles pleine précision, nombre de locuteurs connu, et seuils de clustering `0,45/0,50/0,55/0,60`.

| Essai local | Gain observé | Pourquoi cela ne résout pas le résultat final |
|---|---|---|
| [Attribution principale](../experiments/E07-principal-speaker-attribution.md) | supprime 379 duplications dev et 557 holdout | change le raccord texte↔span, pas les mauvais spans bruts |
| [Exclusif](../experiments/E15-exclusive-reconciliation.md) | DER dev `108,46→89,89 %` | supprime tout overlap et dégrade l'erreur JA par locuteur `91,76→99,19 %` |
| [Pleine précision](../experiments/E16-speakerkit-precision.md) | dev nettement meilleur ; holdout DER `58,91→58,56 %` | holdout JER empire `52,28→52,57 %`, overlap reste ≈ `1,4 %` F1 |
| [Nombre connu](../experiments/E17-speaker-count.md) | dev retrouve 12 locuteurs et JER `84,75→75,94 %` | aucun changement sur le holdout, où Auto trouvait déjà 3/3 ; davantage de JA reste sans attribution sur dev |
| [Seuil 0,55](../experiments/E17-speakerkit-clustering-threshold.md) | dev DER `108,46→98,92 %` | holdout ne gagne que `0,20` point de DER, perd `0,17` point de JER et coûte `+3,20 s` |

Ces options peuvent rester bêta dans l'UI, mais un nouveau balayage de seuils serait une répétition, pas une nouvelle piste.

### FluidAudio Offline / VBx

[E18](../experiments/E18-fluid-audio-offline.md) a remplacé uniquement le moteur de diarisation, avec Qwen JA, alignement et traduction figés. Configuration exacte : seuil `0,60`, pas de segmentation `0,20`, batch embeddings `32`, embeddings hors overlap, sortie non exclusive, comptage automatique, Core ML `.all`, FBANK CPU.

FluidAudio a regroupé les 12 locuteurs de développement en **un seul** : DER `105,02 %`, JER `98,60 %`, erreur JA par locuteur `221,19 %`, overlap F1 `0 %`. Ce n'était pas un simple AHC ancien : FluidAudio documente une pipeline [Community-1, powerset + WeSpeaker + VBx](https://github.com/FluidInference/FluidAudio#offline-speaker-diarization-pipeline), et la version 0.15.5 testée inclut les correctifs déterministes VBx/K-Means et ré-embedding des spans sans vote. Un nouveau retuning FluidAudio n'est donc pas prioritaire.

## Diagnostic local compréhensible

La validation finale [E22](../experiments/E22-standard-offline-validation.md) donne :

| Vidéo | Locuteurs référence / trouvés | DER / JER | Overlap F1 | Ce que l'utilisateur voit |
|---|---:|---:|---:|---|
| développement | 13 / 6 | `105,47 / 85,92 %` | `8,6 %` | plusieurs personnes fusionnées ; labels souvent faux ; `153,5 s` de parole superposée inventée |
| holdout chaîne séparée | 3 / 3 | `58,91 / 52,28 %` | `0,2 %` | bon nombre de personnes, mais mauvais moments/identités ; `92,7 s` d'overlap inventé |

DER supérieur à 100 % est possible car faux alarmes, confusion et parole manquée s'additionnent. Ici, il signifie concrètement que les labels locuteur de la vidéo développement ne sont pas fiables. Le bon compte `3/3` du holdout ne suffit pas : la moitié environ de la couverture temporelle par identité reste erronée. La cause dominante est donc en amont de l'UI : activité/segmentation, embeddings et regroupement des voix, puis raccord aux unités japonaises. L'ASR imparfait aggrave le raccord, mais il n'explique pas les `92–153 s` d'overlap inventé par la diarisation.

La preuve comporte une limite importante : le holdout ne contient que `1,77 s` d'overlap autoritaire. Il peut rejeter un système qui invente de l'overlap, mais ne suffit pas à prouver une excellente détection de chevauchement généralisable.

## Nouvelles familles réellement pertinentes

### 1. MOSS-Transcribe-Diarize 0.9B — à tester en premier

[MOSS-Transcribe-Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) est un modèle conjoint `who/when/what` : encodeur de type Whisper Medium, décodeur Qwen3 0.6B, timestamps et labels `[S01]…` produits dans la même séquence. Il accepte jusqu'à 90 minutes, annonce plus de 50 langues et cite explicitement le japonais parmi les 14 langues de son évaluation MLC-SLM. Modèle `0,9B`, poids Apache-2.0, hotwords possibles.

Pourquoi c'est nouveau : il ne segmente pas puis ne clusterise pas des embeddings comme Community-1. Le contexte long et la génération conjointe peuvent conserver une identité à travers une émission entière et éviter une partie du mauvais raccord ASR↔diarisation.

Le port indépendant [moss-transcribe.cpp](https://github.com/mudler/moss-transcribe.cpp) est particulièrement pertinent pour ce Mac : C++/GGML, licence MIT, sorties vérifiées contre le runtime PyTorch, modèles q8 `942 Mo`, q5 `619 Mo`, q4 `511 Mo`, compilation Metal prévue par `MT_GGML_METAL`. Limites honnêtes : projet très récent, API C stable encore en roadmap, Metal compilable mais sans benchmark Apple publié, coût autoregressif qui augmente avec la durée.

Preuve publique : sur AISHELL-4, AliMeeting, Podcast et Movies, MOSS 0.9B publie des cpCER de `15,83 / 22,17 / 7,37 / 12,76`, contre `24,99 / 29,33 / 48,30 / 42,54` pour VibeVoice. Ce sont des corpus externes et surtout chinois/anglais : ils justifient l'essai, **pas** une promesse de qualité japonaise. Aucun DER japonais ni score d'overlap public n'est fourni.

### 2. DiariZen Large-s80-v2 — plafond recherche, non livrable

[DiariZen](https://github.com/BUTSpeechFIT/DiariZen) remplace la représentation pyannote par WavLM + Conformer/powerset, embeddings WeSpeaker et clustering global. Il accepte un nombre global inconnu de locuteurs et jusqu'à quatre voix simultanées dans ses fenêtres locales. Le checkpoint large-v2 pèse environ [278 Mo](https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md-v2/tree/main).

Sur huit benchmarks sans collar, sans adaptation par domaine et avec les mêmes hyperparamètres, le DER baisse face à pyannote 3.1 de `22,4→13,9`, `24,4→10,8`, `25,3→15,8`, `21,7→14,5`, etc. Cela rend crédible une meilleure segmentation/identité que SpeakerKit, sans garantir le cas VTuber japonais.

Blocages : code MIT mais **poids CC-BY-NC-4.0**, donc non intégrables dans une app commerciale ; environnement officiel PyTorch/CUDA 12.1, aucun runtime Core ML/MLX/MPS validé. Il sert à mesurer si une autre représentation acoustique peut résoudre le corpus, pas à être livré tel quel.

### 3. VibeVoice-ASR — recours, pas priorité

[VibeVoice-ASR](https://huggingface.co/microsoft/VibeVoice-ASR) est également conjoint, multilingue et long contexte, avec labels locuteur et timestamps. Licence MIT, mais le modèle officiel est `9B` BF16. Le runtime officiel [VibeASR.cpp](https://github.com/microsoft/VibeASR.cpp) propose une variante BitNet `1,58 Go` et mesure un RTF `0,42` sur Apple M4/20 s, au prix d'un décodeur réduit et de `+1–4` points absolus de WER sur les jeux publiés. Il ne publie pas de résultat japonais de diarisation pour cette variante. Comme MOSS est beaucoup plus petit et meilleur dans la comparaison publique cpCER de MOSS, VibeVoice est un plan B.

## Contrôles utiles, mais pas candidats produit

- **Pyannote Community-1 Python officiel** : contrôle ponctuel de parité. Il est local/offline, accepte nombre automatique ou contraint et fournit sortie overlap/exclusive ; la [release 4.0](https://github.com/pyannote/pyannote-audio/releases) confirme VBx. Mais c'est la même famille que SpeakerKit/FluidAudio. S'il réussit là où Core ML échoue, il faut diagnostiquer le port ; s'il échoue aussi, arrêter d'investir dans Community-1.
- **Segmentation japonaise CALLHOME** : le modèle officiel [fine-tuned CALLHOME JPN](https://huggingface.co/diarizers-community/speaker-segmentation-fine-tuned-callhome-jpn) publie DER `25,44→18,23`, mais les fausses alarmes montent `2,30→6,31`. C'est du téléphone japonais sur pyannote 3.1 ; le corpus actuel a déjà un grave excès d'activité. À garder seulement comme diagnostic ciblé si la parole manquée devient l'erreur dominante.
- **Audio-visuel / active speaker** : [AVA-AVD](https://arxiv.org/abs/2111.14448) est prometteur quand chaque voix possède un visage visible et synchronisé. L'audit des frames locales montre surtout gameplay, avatars statiques/petites vignettes et coéquipiers hors écran. Un signal visage ne peut donc pas attribuer la majorité des voix ; il ajouterait une dépendance au layout de chaque chaîne. Ne pas tester sur ce corpus.
- **NVIDIA Multitalker Parakeet** : checkpoint officiel anglais, CUDA/NeMo, environ 2,5 Go et exige déjà une diarisation en entrée. Il ne résout ni le japonais ni la cause racine.
- **Nouveau retuning LS-EEND/Sortformer/SpeakerKit/FluidAudio** : aucune raison de le répéter sans nouvelle architecture ou nouvelles annotations.

## Expériences suivantes, une variable à la fois

1. **MOSS-GGML faisabilité**, sans toucher au produit : modèle q8 épinglé, CLI et révision épinglés, courts extraits puis vidéo développement complète. Conserver sortie brute, commande, SHA-256, durée, RSS et backend CPU/Metal. Si le port échoue, rejouer un court extrait avec le runtime PyTorch officiel pour séparer défaut du port et défaut du modèle.
2. **MOSS spans-only** : extraire ses intervalles/labels, mais garder Qwen JA, alignement, traduction et règles de scoring figés. Mesurer DER/JER, compte, erreur JA par locuteur, JA non attribué, overlap P/R/F1 et faux overlap. C'est l'expérience diarisation à une variable.
3. **MOSS conjoint** : expérience séparée où le bundle ASR+locuteurs MOSS est la seule pipeline candidate. Ajouter CER/cpCER et intégrité du texte ; ne jamais mélanger ce résultat avec le test spans-only.
4. **Holdout vidéo/chaîne** uniquement si le développement gagne clairement, puis portes live/ressources même si le mode est offline. Aucun changement produit avant gain holdout.
5. **DiariZen** seulement si MOSS n'améliore pas les spans ou l'overlap. Même PCM et mêmes références, développement d'abord ; résultat de recherche non promouvable sous la licence actuelle.

Une amélioration doit être présentée comme un effet final : davantage de répliques sous le bon label, moins de texte japonais sans personne, et moins de chevauchements fictifs. Un petit gain DER isolé ne suffit pas si JER, attribution japonaise ou overlap empirent.

## Sources primaires

- [OpenMOSS — modèle et rapport](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize)
- [moss-transcribe.cpp — port GGML/Metal](https://github.com/mudler/moss-transcribe.cpp)
- [DiariZen — code, benchmarks et licences](https://github.com/BUTSpeechFIT/DiariZen)
- [Microsoft VibeVoice-ASR](https://github.com/microsoft/VibeVoice)
- [Pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
- [Argmax SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift#speakerkit)
- [FluidAudio Offline](https://github.com/FluidInference/FluidAudio#offline-speaker-diarization-pipeline)

