# Combinaison multi-ASR japonaise locale : méthodes fiables

Date de recherche : 2026-08-10

Périmètre : Qwen JA, Parakeet JA et WhisperKit, traitement hors ligne local sur Apple Silicon. Aucune modification produit ni exécution de modèle.

## Verdict

La première méthode à expérimenter doit être un **consensus source contraint qui sélectionne une hypothèse ASR complète**, puis traduit ce japonais une seule fois :

1. découper l'audio en fenêtres communes avant les ASR ;
2. exécuter Qwen JA et Parakeet JA séquentiellement ;
3. ne solliciter WhisperKit que sur les fenêtres où les deux sorties normalisées divergent assez ;
4. avec trois sorties, choisir celle qui minimise sa somme de distances d'édition en caractères avec les deux autres — le **médoïde** — et départager de façon figée en faveur du meilleur ASR DEV ;
5. conserver les trois sorties, la matrice de distances et le choix comme preuves ;
6. envoyer seulement le japonais choisi à TranslateGemma.

Cette recommandation est une inférence prudente à partir du consensus/MBR : elle ne fabrique aucun caractère, ne nécessite ni confiance comparable ni nouveau modèle, et ne multiplie pas le coût de traduction. Elle doit encore battre le meilleur ASR unique sur DEV puis holdout. Avec seulement deux sorties, il n'existe pas de majorité : un désaccord reste un tie et ne justifie aucune « fusion ».

Une **ROVER en caractères, limitée aux positions ayant une majorité exacte de 2/3**, est le second candidat. Elle peut récupérer des fragments complémentaires, mais crée potentiellement une phrase qui n'existe dans aucune sortie. Elle ne doit être expérimentée que si le plafond oracle montre qu'une simple sélection de l'une des trois hypothèses laisse un gain important inaccessible.

## Pourquoi cette route

ROVER aligne plusieurs sorties par programmation dynamique, construit un réseau de confusions puis vote position par position ([papier original NIST](https://www.nist.gov/publications/post-processing-system-yield-reduced-word-error-rates-recognizer-output-voting-error)). La diversité est nécessaire : la théorie et les essais relient le gain de ROVER à la complémentarité des erreurs, pas au seul nombre de systèmes ([Audhkhasi et al., 2014](https://sail.usc.edu/publications/files/diverse_asr_ensemble_taslp2014.pdf)). Le plafond oracle et la diversité locale doivent donc être vérifiés avant toute fusion.

ROVER classique a trois faiblesses directement pertinentes ici :

- l'alignement est glouton et dépend de l'ordre des hypothèses ;
- une qualité moyenne globale peut masquer des qualités locales opposées ;
- les confidences internes de décodeurs différents sont biaisées et non comparables ([Jalalvand et al., 2017](https://arxiv.org/abs/1706.07238)).

Pour le japonais sans frontières de mots explicites, une ROVER « mot » ajouterait d'abord une décision de tokenisation. Le benchmark local utilise déjà le CER ; l'unité caractère est donc le point de départ le plus traçable. La normalisation doit servir à aligner et détecter l'accord, mais la sortie retenue doit rester l'original d'un ASR pour préserver kanji, ponctuation et graphie. Les variantes de graphie japonaises peuvent sinon gonfler artificiellement le CER sans changement de sens ([Lenient Evaluation of Japanese Speech Recognition](https://aclanthology.org/2023.cawl-1.8/)).

## Options évaluées

| Méthode | Fiabilité attendue | Coût local | Décision |
|---|---|---|---|
| Sélection du médoïde parmi 3 hypothèses complètes | Ne génère aucun nouveau texte ; exploite l'accord ; peut suivre deux systèmes corrélés qui ont tort | Distances d'édition CPU négligeables ; un troisième ASR seulement sur les désaccords | **Premier candidat** |
| ROVER caractère 2/3, fallback vers l'ASR de référence sur les ties | Chaque caractère vient d'un ASR, mais les raccords peuvent produire une phrase hybride invalide | CPU faible, aucun modèle supplémentaire | **Second candidat, seulement après preuve oracle** |
| ROVER pondérée par confiance | Peut départager les ties si les scores sont réellement calibrés | Calibration et conservation des scores par modèle | **Pas au premier essai** |
| Confusion Network Combination / lattices | Plus riche que trois sorties 1-best et compatible avec un décodage à risque minimal | Exige lattices, postérieurs et conversion entre tokenisations propres à chaque ASR | **Écarter dans l'état actuel** |
| Correcteur génératif N-best contraint | Peut apprendre les erreurs récurrentes et se limiter aux chemins ASR | Modèle de correction entraîné, N-best/lattices et décodage spécifique | **Immatûr pour ce corpus et ces interfaces** |
| Correcteur LLM libre sur plusieurs transcrits | Peut reformuler une sortie plausible sans preuve audio | Nouveau modèle ou usage non supporté de TranslateGemma ; risque d'omission/invention | **Rejeter** |
| Traduire toutes les hypothèses puis choisir l'anglais | Peut récupérer une meilleure traduction même si le meilleur JA n'a pas le plus faible CER | Traduction multipliée par 2–3 plus un arbitre cible | **Dernier recours sur les seuls désaccords** |

## Limites concrètes des interfaces actuelles

Les trois wrappers produit renvoient actuellement seulement un `String` : [Qwen](../../../Sources/LocalEnglishModels.swift), [Parakeet](../../../Sources/ParakeetRuntime.swift) et [WhisperKit](../../../Sources/WhisperKitRuntime.swift). Le job conserve une sortie 1-best et ses fenêtres, pas des N-best, lattices ou confiances comparables ([HighQualityJob](../../../Sources/HighQualityJob.swift)).

La CNC et la correction N-best ne sont donc pas de simples algorithmes à ajouter : elles imposeraient d'étendre chaque runtime, quand le fournisseur expose réellement ces données, puis de réconcilier leurs tokenisations. Le papier de correction N-best confirme que le décodage par lattice exige les probabilités internes à chaque pas et que le classement des N-best compte ([Ma et al., 2024](https://arxiv.org/pdf/2409.09554)). Il montre aussi des régressions zero-shot sur certaines sorties Whisper et des troncatures en décodage libre ; une correction générative n'est pas une sécurité universelle.

## Confidences : exigence avant toute pondération

Une probabilité Qwen, un score TDT Parakeet et un logprob WhisperKit n'ont ni la même unité ni la même calibration. Le papier ROVER hybride récent n'obtient son gain qu'après avoir remplacé la softmax CTC surconfiante et ajusté sa température aux scores de l'autre système ; la softmax brute n'apportait pas de gain significatif ([Parikh et al., 2024](https://aclanthology.org/2024.lrec-main.547.pdf)). La calibration par température est légère, mais elle doit être ajustée sur des exemples de validation dont la correction est connue ([Guo et al., 2017](https://proceedings.mlr.press/v70/guo17a.html)).

Si les scores sont exposés plus tard :

- calibrer **chaque modèle séparément** sur DEV, au niveau des caractères alignés ;
- mesurer ECE/Brier et la séparation correct/incorrect, pas seulement la moyenne ;
- figer températures et poids avant holdout ;
- ne jamais apprendre ces réglages sur le holdout ;
- conserver une voie non pondérée, car une seule vidéo DEV par domaine ne suffit pas à prouver une calibration générale.

Pour la première expérience, l'accord exact et la distance entre hypothèses sont donc plus sûrs que les confidences brutes.

## Traduction et sélection côté anglais

Des systèmes de traduction de parole ont déjà amélioré le résultat en traduisant plusieurs hypothèses ASR puis en les rescoring, mais au prix de traduire toutes les variantes ; une pseudo-lattice réduisait ce coût à 20 % de l'approche directe dans un système SMT ancien ([Zhang et al., IWSLT 2005](https://aclanthology.org/2005.iwslt-1.3.pdf)). Ce résultat établit la possibilité, pas son adéquation à TranslateGemma.

TranslateGemma garantit officiellement un gabarit où le dernier message contient **uniquement le texte à traduire**. La post-édition et les prompts alternatifs ne sont pas officiellement supportés ([model card Google](https://huggingface.co/google/translategemma-12b-it)). Il ne faut donc ni concaténer les transcrits, ni lui demander de corriger le japonais, ni lui faire choisir une option dans le même prompt.

La sélection de plusieurs traductions par COMET/MBR est documentée dans le [dépôt officiel COMET](https://github.com/Unbabel/COMET), mais elle ajoute un modèle de score et son coût est quadratique dans le nombre de candidats. Surtout, COMET peut surévaluer des erreurs de nombres et d'entités nommées lorsqu'il est optimisé comme arbitre ([Amrhein et Sennrich, 2022](https://aclanthology.org/2022.aacl-main.83/)). Avec les termes anime/VTuber/gaming, ce défaut touche précisément le contenu critique.

Conclusion cible : traduire une seule source choisie. Si cette stratégie échoue malgré un grand oracle source, tester plus tard deux traductions **uniquement sur les fenêtres suspectes**, avec contrôles déterministes des nombres/entités et une métrique de sélection distincte de la métrique d'évaluation.

## Coût et compatibilité Apple Silicon

Le sélecteur médoïde et ROVER caractère sont de simples alignements de chaînes : CPU, mémoire bornée par quelques hypothèses, aucune dépendance et aucun GPU requis. Les ASR peuvent rester séquentiels derrière la porte de modèle lourd existante : Qwen, déchargement, Parakeet, déchargement, puis WhisperKit seulement si nécessaire. La traduction reste unique.

Un mode qui exécute systématiquement les trois ASR reste local, mais son coût est la somme des trois passes. Le déclenchement sur désaccord ne doit être promu que si les artefacts montrent qu'il évite réellement une part importante de WhisperKit. Les politiques MLX permettent de borner l'admission par le working set recommandé du GPU sur mémoire unifiée ([documentation MLX Swift](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/Articles/wired-memory.md)), mais la fusion texte elle-même ne justifie aucun chargement MLX.

## Ordre de preuve recommandé

1. Mesurer, par fenêtre et par domaine, l'oracle « meilleur des trois », le médoïde, les accords 2/3 et les doubles erreurs corrélées.
2. Comparer le meilleur ASR unique au sélecteur médoïde, sans toucher à la traduction.
3. Seulement si le médoïde laisse un écart oracle utile, comparer la ROVER caractère stricte avec fallback.
4. Traduire une fois le meilleur japonais de chaque candidat et mesurer séparément `JA + EN` et `EN seulement`.
5. Mesurer le temps ajouté par ASR, le pourcentage de fenêtres déclenchant WhisperKit, le pic mémoire séquentiel et des exemples concrets récupérés/perdus.

Portes : aucun caractère absent des hypothèses sources, aucune fenêtre perdue/dupliquée, gain DEV puis holdout, termes/nombres non dégradés, et gain anglais réel — pas seulement CER. Le rapport local actuel rappelle que deux vidéos valident ce workflow, pas une supériorité générale ([E06](../experiments/E06-offline-high-quality-acceptance.md)).

## Sources primaires

- Fiscus, [Recognizer Output Voting Error Reduction](https://www.nist.gov/publications/post-processing-system-yield-reduced-word-error-rates-recognizer-output-voting-error), NIST, 1997.
- Audhkhasi et al., [Theoretical Analysis of Diversity in an Ensemble of Automatic Speech Recognition Systems](https://sail.usc.edu/publications/files/diverse_asr_ensemble_taslp2014.pdf), 2014.
- Jalalvand et al., [Automatic Quality Estimation for ASR System Combination](https://arxiv.org/abs/1706.07238), 2017.
- Parikh et al., [Ensembles of Hybrid and End-to-End Speech Recognition](https://aclanthology.org/2024.lrec-main.547/), 2024.
- Ma et al., [ASR Error Correction using Large Language Models](https://arxiv.org/pdf/2409.09554), 2024.
- Zhang et al., [Using Multiple Recognition Hypotheses to Improve Speech Translation](https://aclanthology.org/2005.iwslt-1.3/), IWSLT 2005.
- Google, [TranslateGemma model card](https://huggingface.co/google/translategemma-12b-it).
- Unbabel, [COMET](https://github.com/Unbabel/COMET).
- Amrhein et Sennrich, [Identifying Weaknesses in Machine Translation Metrics Through Minimum Bayes Risk Decoding](https://aclanthology.org/2022.aacl-main.83/), 2022.
- Google MLX, [Wired Memory Management](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/Articles/wired-memory.md).
