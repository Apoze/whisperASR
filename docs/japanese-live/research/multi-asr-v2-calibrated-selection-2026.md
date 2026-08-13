# Multi-ASR japonais de deuxième génération

Date de recherche : 2026-08-11

Périmètre : traitement hors ligne local sur Apple Silicon, Qwen JA comme baseline, Parakeet JA et WhisperKit comme candidats. Aucun code produit, benchmark lourd, modèle ou réglage Live n'a été modifié.

## Verdict

La seule prochaine expérience assez mûre est une **sélection locale calibrée avec abstention** :

1. comparer des hypothèses complètes sur de courts segments acoustiques communs, et non sur les fenêtres ASR actuelles d'environ une minute ;
2. exécuter Qwen et Parakeet séquentiellement ;
3. ne déclencher WhisperKit que si Qwen est à la fois en désaccord et objectivement suspect ;
4. remplacer Qwen uniquement si une hypothèse complète obtient un avantage calibré supérieur à une marge figée ;
5. sinon, conserver Qwen ; ne jamais fusionner des caractères ;
6. traduire une seule fois le japonais finalement choisi et garder les portes anglaises décisives.

Cette méthode diffère réellement de l'essai rejeté : l'unité devient locale, le désaccord seul ne déclenche rien, la décision utilise le signal audio et les diagnostics propres à chaque ASR, et l'abstention protège la baseline.

Les méthodes audio-conditionnées et N-best restent scientifiquement prometteuses, mais elles exigent aujourd'hui un adaptateur de décodeur ou un modèle entraîné. Elles ne sont pas le prochain ticket d'implémentation.

## Pourquoi le premier essai a échoué

Les preuves de [Comparer les stratégies multi-ASR figées sur les vidéos réelles](https://github.com/Apoze/whisperASR/issues/64#issuecomment-5244908546), de son [artefact complet](https://github.com/Apoze/whisperASR/blob/e0a3cfd532b54157000a3cddd405bb6970dbbd65/docs/japanese-live/experiments/evidence/E20-multi-asr/decision.json) et de l'[audit oracle](https://github.com/Apoze/whisperASR/blob/fe9cffcc917f7e1d8d31e71577aa60eaf6fafe8d/docs/japanese-live/research-oracle-asr-ja-artifacts-2026-08-10.md) établissent ceci :

- 16 fenêtres communes de 58 à 65 secondes ; Qwen et Parakeet divergeaient sur **16/16**, donc WhisperKit a tourné partout ;
- médoïde : CER high/non-overlap 86,83 % → 79,91 %, mais gain relatif apparié 7,96 % et borne basse 95 % −2,52 % ;
- ROVER : CER 79,64 %, gain 8,27 % [−2,04 ; 16,48], huit tours de parole supplémentaires devenus vides ;
- anglais : chrF++ 45,44 → 42,08 et flags d'hallucination 11 → 16 ;
- pertes concrètes : `Three bars remain` devient vide, les HP de Gouki sont inversés, `Burnout` devient de la fatigue humaine et `VCR GTA…` est réduit à `か` ;
- coût ASR ajouté : **527,36 s** ; pic processus 18,42 Go, minimum disponible 2,70 Go et swap +3,33 Go, sans événement macOS warning/critical.

La cause racine est la décision, pas l'absence de diversité :

1. **granularité trop longue** : une source bonne localement peut être rejetée à cause du reste de la minute ;
2. **déclencheur non informatif** : toute différence de chaîne valait suspicion, donc 100 % des fenêtres ont lancé WhisperKit ;
3. **médoïde sans preuve audio** : deux hypothèses corrélées ou plus courtes peuvent être centrales tout en étant fausses ;
4. **fusion destructive** : le ROVER caractère a fabriqué des hybrides, puis le réalignement a produit des tours vides ;
5. **absence de score comparable et d'abstention** : rien ne prouvait qu'une alternative était meilleure que Qwen avant le remplacement.

L'oracle confirme néanmoins un signal exploitable : sur high/non-overlap, le meilleur choix après coup atteint 57,61 % CER en DEV contre 75,65 % pour le meilleur ASR unique, et 24,27 % sur holdout contre 34,12 %. Mais les trois ASR sont simultanément vides sur 32/111 tours DEV et 4/177 holdout : aucune combinaison ne peut recréer ces paroles.

## Ce que les interfaces permettent réellement

- Le produit conserve actuellement `rawTranscript` et des chunks texte dans [`HighQualityASRExchange`](../../../Sources/HighQualityJob.swift), sans confiance, N-best ni lattice. `chunkedASR` utilise des fenêtres proches de la limite de 60 s du forced aligner.
- Le wrapper Qwen local renvoie un `String`. Son décodeur peut faire un argmax ou un échantillonnage par température, mais ne renvoie ni score de chemin ni liste N-best ([source locale](../../../Vendor/SpeechSwiftPrototype/Sources/Qwen3ASR/Qwen3ASR.swift)). L'interface officielle Qwen renvoie elle aussi texte et timestamps, pas une lattice ([Qwen3-ASR officiel](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)).
- FluidAudio `0.15.5@19600a4` expose déjà pour Parakeet un `ASRResult.confidence` et des `tokenTimings`, mais le wrapper produit ne garde que `.text` ([types officiels](https://github.com/FluidInference/FluidAudio/blob/19600a485baa4998812e4654b70d2bab8f2c9949/Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift)). La confiance est la moyenne des softmax des tokens sélectionnés : elle doit être calibrée, jamais comparée brute à Qwen ou WhisperKit.
- WhisperKit `1.1.0@1e2a163` expose les log-probabilités du chemin retenu, `avgLogprob` et les probabilités de mots ([modèles officiels](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/Models.swift)). Dans cette version, `noSpeechProb` est encore fixé à zéro avec un `TODO`, et `BeamSearchTokenSampler` est explicitement non implémenté ([décodeur](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/TextDecoder.swift), [sampler](https://github.com/argmaxinc/WhisperKit/blob/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d/Sources/WhisperKit/Core/Text/TokenSampler.swift)). `topK` sert à l'échantillonnage d'un chemin, pas à exposer une liste N-best.

Conclusion d'interface : les confiances sélectionnées peuvent alimenter un sélecteur après calibration, mais une vraie confusion network ou un rescoring N-best inter-backends n'est pas disponible sans travail de décodeur.

## Shortlist

| Piste | Données requises | Faisabilité Apple Silicon | Hallucination | Coût attendu | Décision / réfutation minimale |
|---|---|---|---|---|---|
| **A. Sélection calibrée, segment court, abstention Qwen** | audio, hypothèses complètes alignées, diagnostics audio/texte, confiance Parakeet et WhisperKit calibrées sur DEV | Bonne : règles/statistique légère CPU ; modèles restent séquentiels | Faible : aucun nouveau caractère ; risque de choisir la mauvaise source | Parakeet observé +4,90 s sur DEV ; WhisperKit seulement sur la durée suspecte, à mesurer | **Prochain bake-off.** Abandon si la validation par blocs DEV ne bat pas Qwen, ajoute un tour vide ou ne préserve pas l'anglais |
| **B. Rescoring audio-conditionné d'un ensemble fermé** | score `P(texte|audio)` comparable pour chaque candidat complet | Partiellement bloquée : les wrappers ne scorent pas un texte arbitraire | Faible si le résultat reste l'une des hypothèses | Un passage de score par candidat suspect ; inconnu avant prototype | Sur 20 segments DEV très disputés, comparer le classement audio à l'oracle ; abandon si aucun avantage sur A |
| **C. N-best/lattice + correction contrainte** | vrais N-best avec scores ou lattice, tokenizer réconcilié, correcteur entraîné | Bloquée : Parakeet est greedy, beam WhisperKit non implémenté, Qwen ne renvoie qu'un chemin | Moyenne en libre, faible si sortie contrainte à un chemin | Plusieurs décodages et un modèle correcteur ; mémoire séquentielle obligatoire | D'abord 4 échantillons Qwen sur segments suspects : abandon si l'oracle N-best n'apporte pas un gain net avant tout correcteur |
| **D. Deux traductions puis sélection cible sur segments suspects** | deux sources JA, deux traductions 12B, contrôles d'intégrité, QE sans référence calibrée | Possible mais lourde ; MetricX a déjà été testé | Pas de texte nouveau par le juge, mais il peut choisir une erreur sémantique | Jusqu'à 2 traductions seulement sur le sous-ensemble suspect + juge | **Dernier recours EN uniquement.** Ne rouvrir que si A produit un vrai choix source et si le juge dépasse les contrôles déterministes |
| **E. Correcteur génératif japonais conservateur/audio-LLM** | milliers d'heures ou modèle prêt, phonèmes/audio, paires ASR-référence, entraînement | Pas mûr pour cette app native et ces deux vidéos | Élevée sans filtre ou contrainte | 7B+ et entraînement ; exemples publiés sur A100 | Surveiller un modèle japonais permissif et Apple-ready ; ne pas entraîner localement aujourd'hui |

## Expérience A à transmettre à la future spec

### Unité et décision

- Construire des segments communs **sans utiliser les références**, à partir des silences/VAD et des timings disponibles ; viser quelques secondes, avec maximum figé avant le run. Le papier de QE segmentaire montre précisément que les transcriptions longues masquent des qualités locales opposées et recommande des segments de quelques secondes ([Jalalvand et al., 2015](https://aclanthology.org/P15-1106.pdf)).
- Réaligner les hypothèses existantes sur ces bornes pour un premier diagnostic sans relancer d'ASR. Si les timings ne permettent pas une comparaison fiable, ce diagnostic doit s'arrêter et demander un artefact de score/timing, pas inventer un alignement texte.
- Le candidat est toujours une hypothèse **complète** de Qwen, Parakeet ou WhisperKit sur le segment. Aucune concaténation, aucun caractère voté.
- Qwen est le fallback. Une alternative ne peut gagner que si son avantage prédit dépasse une marge calibrée et si tous les veto passent.

### Signaux autorisés

- désaccord normalisé entre hypothèses ;
- couverture et monotonie du forced alignment, parole détectée mais transcript vide, caractères par seconde ;
- répétitions, compression et longueur anormale ;
- confiance/timing Parakeet et `avgLogprob`/probabilités de mots WhisperKit, **calibrés séparément** ;
- conservation des nombres, entités et termes critiques présents dans la baseline Qwen, comme veto de sécurité, pas comme preuve que Qwen est correct.

La softmax brute est insuffisante : dans un ensemble hybride publié, la confiance CTC brute était proche de 0,999 et n'améliorait pas significativement ROVER ; une confiance entropique mise à l'échelle a rendu les systèmes comparables et amélioré le WER ([Parikh et al., 2024](https://aclanthology.org/2024.lrec-main.547.pdf)). La température est un seul paramètre ajusté sur validation et n'altère pas la prédiction du modèle ([Guo et al., 2017](https://proceedings.mlr.press/v70/guo17a.html)). Avec une seule vidéo DEV, le sélecteur doit rester très petit et abstentionniste, avec validation par blocs temporels contigus ; un modèle complexe surapprendrait.

### Déclenchement et veto

1. Parakeet peut tourner sur tout le fichier : son coût observé est d'environ cinq secondes.
2. WhisperKit ne tourne que si Qwen/Parakeet divergent au-delà du seuil **et** qu'au moins un diagnostic indépendant classe Qwen comme suspect. Une simple différence de texte ne suffit jamais.
3. Conserver Qwen en cas de score manquant, égalité, marge insuffisante ou calibration instable.
4. Interdire un remplacement qui rend vide une zone de parole non vide, réduit fortement la couverture alignée, introduit une répétition pathologique, perd un nombre/terme critique sans corroboration ou échoue l'intégrité structurée.

### Protocole réfutable

1. **DEV fermé au holdout** : réutiliser d'abord les trois sorties et l'audio de Video1. Définir les segments sans référence, puis utiliser la référence uniquement pour les labels et scores externes.
2. **Validation par blocs** : calibrer et évaluer en leave-one-contiguous-block-out ; rapporter sélection correcte, abstentions, remplacements gagnés/perdus, CER et calibration (Brier/ECE). Figer ensuite seuils, marge et veto.
3. **Portes DEV existantes** : aucun tour de parole supplémentaire vide ; gain CER apparié robuste selon le protocole figé de la campagne ; aucune dégradation chrF++/intégrité/hallucination après une traduction unique ; exemples concrets ; temps et pression mémoire complets.
4. **Holdout une seule fois** : ouvrir Video2 seulement si toutes les portes DEV passent ; aucun réajustement après ouverture.
5. **Arrêt explicite** : si le sélecteur ne généralise pas entre blocs DEV, si ses gains viennent des bornes de référence ou si l'anglais régresse, rejeter le multi-ASR v2. Garder les trois ASR sélectionnables individuellement.

Le premier artefact doit comparer trois ablations, une variable à la fois : `Qwen`, `Qwen + Parakeet + sélecteur abstentionniste`, puis le même candidat avec WhisperKit ciblé. Ainsi, le coût réel de chaque source et sa contribution sont lisibles.

## Pourquoi les autres pistes attendent

### Audio-conditionné

L'idée est bonne : le texte seul ne peut pas savoir quelle homophonie a été prononcée. Mais les solutions publiées ne sont pas prêtes pour ce produit. Whispering LLaMA fusionne des représentations Whisper-Large, 15 hypothèses Whisper-Tiny et LLaMA ; l'entraînement publié dure 25 époques sur deux A100, et les auteurs signalent +394,76 % de durée d'entraînement et du surapprentissage ([Radhakrishnan et al., 2023](https://aclanthology.org/2023.emnlp-main.618.pdf)). UADF injecte aussi l'incertitude acoustique dans un correcteur entraîné ([Chen et al., ICLR 2024](https://openreview.net/forum?id=QqjFHyQwtF)). Il n'existe dans ces preuves ni poids japonais spécialisés ni runtime Swift/MLX prêt.

La version pragmatique à surveiller est plus sûre : scorer par l'audio un **ensemble fermé** d'hypothèses complètes. Elle ne génère rien, mais nécessite d'exposer un score conditionnel arbitraire dans Qwen ou WhisperKit. Tant que ce score manque, B est bloquée proprement.

### N-best et correction contrainte

N-best T5 démontre pourquoi une correction libre n'est pas acceptable : sur LibriSpeech, le correcteur 1-best dégrade le baseline, tandis que 5/10 hypothèses et un décodage limité aux N-best/lattice l'améliorent. La méthode combine explicitement score ASR acoustique et score du correcteur, et doit convertir les tokenizers de lattice ([Ma et al., 2023](https://arxiv.org/abs/2303.00456)). Ici ces N-best et scores n'existent pas. Quatre échantillons Qwen à température peuvent seulement mesurer un petit oracle ; ils ne constituent ni un beam N-best ni une lattice calibrée.

### Correction générative japonaise

Le meilleur signal primaire japonais est un avertissement. Sur 21 domaines, un correcteur 7B non filtré dégrade le CER moyen de 11,84 à 12,51 et modifie 43 % des sorties. Le filtrage conservateur réduit les corrections à 13,9 % et améliore 15/21 jeux, mais repose sur **8 000 heures** de parole transcrite et un fine-tuning LoRA 7B sur A100 ([Udagawa et al., 2024](https://aclanthology.org/2024.emnlp-industry.20.pdf)). Deux vidéos ne permettent pas d'entraîner ou valider ce système. Le principe utile est l'abstention et l'inférabilité acoustique, déjà reprises dans A.

### Sélection côté anglais

L'[expérience E15 MetricX](../experiments/E15-metricx-reranking.md), portée par [Decide MetricX reranking for suspect translations](https://github.com/Apoze/whisperASR/issues/56), couvre déjà cette famille : deux unités DEV suspectes, zéro override, aucune ouverture holdout, et le handoff mémoire séquentiel n'était pas prouvé. Réexécuter un autre juge textuel sans meilleur candidat source répéterait l'expérience.

COMET sait faire du MBR/reranking et COMETKiwi est sans référence ([dépôt officiel](https://github.com/Unbabel/COMET)), mais le modèle public est non commercial CC-BY-NC-SA et ignore l'audio ([licence officielle](https://huggingface.co/Unbabel/wmt22-cometkiwi-da-marian/blob/main/LICENSE)). Un résultat IWSLT récent montre en outre qu'il faut calibrer les quasi-égalités ; il porte sur EN→DE/ZH, pas JA→EN ([Shah et al., 2026](https://aclanthology.org/2026.iwslt-1.36/)). D reste donc un diagnostic EN-only, après A, jamais l'arbitre du transcript JA.

## Rejets explicites

- **Concaténation brute** de plusieurs transcrits dans TranslateGemma : aucune preuve audio, contexte contaminé, usage non supporté du traducteur.
- **Médoïde sur fenêtres longues** : déjà testée et non robuste.
- **Vote/ROVER non calibré** : déjà testé ; hybride destructif et huit tours vides.
- **Remplacement déclenché par tout désaccord** : a lancé WhisperKit sur 16/16 fenêtres.
- **Correction libre par TranslateGemma ou LLM** : peut produire une phrase plausible non dite ; les travaux japonais montrent l'overcorrection.
- **Confusion network inter-backends maintenant** : aucune lattice exposée, tokenizers incompatibles.
- **Juge anglais par défaut** : ne protège ni le japonais ni les informations acoustiques et répète E15.

## Recommandation finale

Créer un seul prochain ticket expérimental pour **A**, sans option UI ni modification produit : artefacts existants d'abord, segments acoustiques courts indépendants des références, scores conservés/calibrés, sélection de phrases complètes, Qwen par abstention, WhisperKit ciblé et traduction unique. B et C ne deviennent des tickets que si leur mini-oracle préalable prouve un potentiel et qu'un score/N-best est réellement exposable. D attend un candidat source qui passe A. E reste à surveiller.

## Sources primaires

- Jalalvand et al., [Driving ROVER with Segment-based ASR Quality Estimation](https://aclanthology.org/P15-1106.pdf), ACL 2015.
- Parikh et al., [Ensembles of Hybrid and End-to-End Speech Recognition](https://aclanthology.org/2024.lrec-main.547.pdf), LREC-COLING 2024.
- Guo et al., [On Calibration of Modern Neural Networks](https://proceedings.mlr.press/v70/guo17a.html), ICML 2017.
- Ma et al., [N-best T5: Robust ASR Error Correction using Multiple Input Hypotheses and Constrained Decoding Space](https://arxiv.org/abs/2303.00456), Interspeech 2023.
- Udagawa et al., [Robust ASR Error Correction with Conservative Data Filtering](https://aclanthology.org/2024.emnlp-industry.20/), EMNLP Industry 2024.
- Radhakrishnan et al., [Whispering LLaMA](https://aclanthology.org/2023.emnlp-main.618/), EMNLP 2023.
- Chen et al., [It's Never Too Late: Fusing Acoustic Information into Large Language Models for ASR](https://openreview.net/forum?id=QqjFHyQwtF), ICLR 2024.
- Li et al., [High-precision Voice Search Query Correction via Retrievable Speech-text Embeddings](https://arxiv.org/abs/2401.04235), ICASSP 2024.
- Unbabel, [COMET official repository](https://github.com/Unbabel/COMET).
- Qwen, [Qwen3-ASR official repository](https://github.com/QwenLM/Qwen3-ASR).
- Argmax, [WhisperKit pinned source](https://github.com/argmaxinc/WhisperKit/tree/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d).
- FluidInference, [FluidAudio pinned source](https://github.com/FluidInference/FluidAudio/tree/19600a485baa4998812e4654b70d2bab8f2c9949).
