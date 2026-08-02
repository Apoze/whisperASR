# Recherche 2026 — sous-titres japonais → anglais en direct sur macOS

Date : 2026-08-02
Périmètre : recherche et plan d'expériences uniquement. Aucun changement produit, essai audio ou téléchargement de modèle n'a été effectué.

## Résumé exécutif

Le meilleur chemin à court terme est de conserver la séparation actuelle entre une **preview jetable** et un **final stable qui reste seul propriétaire du PCM**. Cette architecture protège déjà les garanties les plus importantes : FIFO, absence de perte audio, ordre stable et possibilité de réessayer une traduction finale.

Les priorités recommandées sont :

1. **P0 — corpus de décision figé**. Seuls les deux transcrits bilingues vidéo fournis sont autoritaires, tels que livrés et acceptés par Apoze. Les autres corpus versionnés restent diagnostiques.
2. **P0 — comparer correctement les deux modes Qwen** :
   - `qwenApple` utilise **Apple Speech** pour la preview japonaise et Qwen seulement pour le final de phrase ;
   - `qwenPseudoLiveApple` n'utilise pas Apple Speech : il relance Qwen sur des snapshots cumulatifs de la phrase.
3. **P0 — traiter le régime “toujours stale” du pseudo-live Qwen avant de conclure sur sa qualité**. Si une inférence dure plus longtemps que la cadence, chaque snapshot terminé peut déjà avoir un successeur ; le résultat est alors rejeté, un snapshot plus long démarre, puis risque d'être rejeté à son tour. Le compteur `stalePreviewResults` observe le problème, mais le SLO de couverture doit aussi compter explicitement les phrases sans aucune preview publiée.
4. **P0 — faire une petite matrice de cadence et de finalisation**, pas un nouveau chantier de modèle : cadence Qwen 1/2/3 s, finalisation Apple 0,75/1/1,5 s, puis comparaison `qwenApple` contre `qwenPseudoLiveApple` sur le même PCM. La variante n'est retenue que si elle passe les portes existantes de qualité, latence, intégrité et mémoire.
5. **P1 — tester Parakeet japonais Core ML comme final ASR**, car FluidAudio est déjà une dépendance du dépôt et fournit un chemin local macOS crédible. Il s'agit d'un candidat de bake-off, pas d'une recommandation de remplacement : les chiffres publiés par l'auteur ne sont pas comparables au corpus du produit.
6. **P1 — stabiliser visuellement le pseudo-live par préfixe commun**, sans lui donner d'autorité sur le final. Un préfixe confirmé par deux snapshots et un suffixe visuellement volatil peuvent réduire le scintillement ; l'expérience doit mesurer les caractères effacés et l'âge du préfixe stable.
7. **P2 — ne porter le vrai streaming Qwen vers MLX/Swift que si un prototype isolé franchit un gain de preview p95 ≥ 200 ms sans régression de qualité**. Le streaming officiel Qwen est aujourd'hui documenté pour vLLM ; le runtime Swift embarqué est un décodeur batch et son cache interne ne constitue pas un état streaming réutilisable entre snapshots.

Conclusion pratique : **le candidat produit le moins risqué reste Apple Speech pour la preview, puis Qwen/Kotoba/Whisper Turbo pour le final et Apple Translation high-fidelity**. Voxtral reste utile comme axe expérimental, mais ses résultats locaux actuels sont trop variables et trop lents en preview pour redevenir le chemin principal.

## Méthode et niveaux de preuve

Le rapport sépare trois catégories :

- **Observation dépôt** : fait directement vérifié dans le code, les recettes ou les lots locaux.
- **Fait sourcé** : propriété déclarée par Apple, l'auteur d'un modèle, un dépôt officiel ou un article primaire.
- **Inférence** : recommandation à confirmer sur le corpus et le matériel du produit.

Les scores de cartes de modèles ne sont jamais comparés directement aux CER du dépôt : corpus, normalisation, matériel, précision numérique et méthode de découpe diffèrent. Les décisions produit doivent rester fondées sur un replay du même PCM et des références figées.

## État actuel vérifié

### Architecture produit

**Observation dépôt — preview et final**

- `qwenApple` : FireRedVAD délimite la phrase ; Apple Speech fournit la preview japonaise progressive ; Qwen redécode la phrase stable ; Apple Translation low-latency traduit la preview et high-fidelity traduit le final.
- `qwenPseudoLiveApple` : FireRedVAD et le final Qwen sont identiques, mais la preview Apple Speech est désactivée. Qwen retranscrit toute la phrase inachevée toutes les 1, 2 ou 3 secondes.
- `voxtralApple` et les hybrides Voxtral utilisent une session source continue ; la variante sûre actuelle effectue une rotation à 720 s sur une pause FireRed.
- La preview ne peut ni valider un final, ni libérer le PCM. Le FIFO final reste l'unique autorité stable.
- La traduction finale est append-only, ordonnée, retentée au plus trois fois pour les erreurs transitoires, et le PCM est conservé si elle échoue définitivement.

Références dépôt : [`Models.swift`](../../Sources/Models.swift), [`AppState.swift`](../../Sources/AppState.swift), [`QwenPseudoLiveCoordinator.swift`](../../Sources/QwenPseudoLiveCoordinator.swift), [`LocalCaptionPipeline.swift`](../../Sources/LocalCaptionPipeline.swift).

**Observation dépôt — endpointing**

- Audio 16 kHz mono.
- Pré-roll 250 ms, post-roll 500 ms, silence de décision 350 ms.
- Phrase minimale 1,5 s.
- Coupure forcée à 15 s avec recouvrement 800 ms.
- L'analyse VAD s'exécute sur une fenêtre roulante de 3 s environ toutes les 100 ms.
- Le FIFO traite les plus anciens segments en premier et ne relâche les échantillons qu'après acceptation du final.

**Observation dépôt — Apple**

- `SpeechAnalyzer` utilise `SpeechTranscriber` avec le preset `timeIndexedProgressiveTranscription`, la priorité `.userInitiated`, le maintien de modèle `.lingering` et `prepareToAnalyze`.
- Les résultats Apple portent `isFinal`, une plage audio et un temps de finalisation ; dans le pipeline local ils restent une preview jetable.
- L'alimentation Apple appelle périodiquement `finalizeAvailableAudio`, actuellement environ toutes les 1,5 s.
- Le contexte fournit au plus 100 termes canoniques du glossaire via `AnalysisContext.contextualStrings[.general]`.
- La traduction utilise deux sessions séparées : low-latency pour la preview, high-fidelity pour le final. Elles sont préparées et préchauffées ; les délais applicatifs sont de 2 s et 5 s.
- La preview traduite est latest-only, limitée à une mise à jour toutes les 500 ms sauf ponctuation ou premier résultat, et suspendue pendant une traduction finale.

Apple décrit `timeIndexedProgressiveTranscription` comme le preset qui combine résultats volatils rapides et plages temporelles. Apple précise aussi qu'un résultat volatil peut être remplacé, tandis qu'un résultat finalisé est immuable ; `finalize` demande la finalisation de l'audio disponible. ([SpeechTranscriber presets](https://developer.apple.com/documentation/speech/speechtranscriber/preset), [WWDC25 — SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer))

**Limite importante — contexte Apple**

Apple documente jusqu'à 100 chaînes contextuelles courtes, mais rattache explicitement ce comportement à `DictationTranscriber`. L'effet du même `AnalysisContext` avec `SpeechTranscriber`, utilisé ici, n'est donc pas garanti par la documentation publique. C'est une hypothèse à mesurer, pas un bénéfice acquis. ([AnalysisContext](https://developer.apple.com/documentation/speech/analysiscontext), [contextualStrings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings?changes=_1), [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber?changes=_1_9))

**Observation dépôt — anti-hallucination et contexte Qwen**

- Aucun prompt ni glossaire n'est envoyé au Qwen local, car des essais courts ont montré une répétition du prompt système.
- Les alias sont corrigés après ASR par remplacement déterministe, le profil de sujet étant prioritaire sur le profil général.
- La sortie anglaise vide, encore écrite en CJK ou contenant une longue boucle répétée est rejetée.
- Le modèle Qwen produit un maximum de 448 tokens par phrase ; le chemin est batch par phrase/snapshot.

### Résultats locaux utiles à la décision

**Observation dépôt — prototype anglais de 40 s**

| Pipeline | ASR | Traduction | RSS approx. | Lecture |
|---|---:|---:|---:|---|
| Whisper large-v3-turbo → Apple | 2 045 ms | 1 983 ms | 1,93 Go | 4 sous-titres cohérents, meilleur nom propre |
| FireRedVAD + Qwen 1.7B → Apple | 2 437 ms | 2 734 ms | 2,82 Go | médiane plus basse, p95 plus haute, nom erroné et fillers |
| Nemotron + Qwen → Apple | 3 260 ms | 2 631 ms | 2,70 Go | pas de gain d'endpoint ; surcoût continu |

Source dépôt : [`local-prototype-results.md`](../local-prototype-results.md).

**Observation dépôt — corpus japonais et live**

- L03 : Whisper Turbo obtient 27,83 % CER et une latence ASR p95 de 1 158 ms ; Voxtral obtient 31,25 % avec 11 sorties vides et une p95 de 7 138 ms ; Nemotron reste autour de 34–36 % avec 19–21 sorties vides. Aucune promotion.
- L05, 92 tours de stress : Kotoba Q5 atteint 26,24 % CER contre 26,70 % pour Turbo, gain trop faible pour la porte de 10 %. Qwen atteint 27,06 % avec 6,63 Gio. Les wrappers MLX testés sont plus mauvais ou plus lents.
- L06 : Apple Speech preview couvre 100 %, p50 1,131 s, p95 1,639 s, pire 2,744 s. Le prototype WLK hybride couvre 85,71 %, p50 2,207 s, p95 4,36 s, final seulement en fin de flux et 13,41 Gio ; rejeté.
- L07D : aucun pipeline ne passe toutes les portes. Kotoba Q5 → Apple high-fidelity est le meilleur final observé, mais sa p95 finale de 1,75 s dépasse la cible 1,5 s. La preview Apple commune atteint p50 1,14 s, p95 1,64 s, pire 5,74 s.
- L08A : la traduction Apple n'est pas le goulet du preview Voxtral ; elle ajoute environ 65–75 ms. La source Voxtral porte la latence et les pertes de fin.
- L08B/B2/B3 : le replay de queue textuel est dangereux ; une rotation de session à 720 s restaure la dernière phrase, mais le Q4/960 produit reste très variable selon la vidéo : CER 61,96 % / 20,58 %, preview p95 6,26 s / 3,44 s.
- L08C : les frontières forcées à 15 s dégradent la preview et restent largement au-dessus du taux d'erreur de frontière admissible ; changement rejeté et annulé.

Sources dépôt : [L03](lots/L03-bakeoff-asr.md), [L05](lots/L05-bakeoff-japonais.md), [L06](lots/L06-live-anglais.md), [L07D](lots/L07D-comparaison-decision.md), [L08A](lots/L08A-diagnostic-voxtral.md), [L08B](lots/L08B-recuperation-fin.md), [L08B2](lots/L08B2-rotation-experimentale.md), [L08B3](lots/L08B3-rotation-produit.md), [L08C](lots/L08C-frontieres-japonaises.md).

### Le défaut spécifique du pseudo-live Qwen

**Observation dépôt**

Le coordinateur garde une inférence en vol et un seul snapshot `pending`, toujours remplacé par le plus récent. À la fin d'une inférence, son résultat n'est accepté que si sa plage est encore exactement `latestRequestedRange`.

Conséquence déterministe :

1. Qwen démarre sur `[début, t1]`.
2. Si la cadence expire avant la fin du calcul, `[début, t2]` devient le dernier snapshot demandé.
3. Le résultat de `[début, t1]` est rejeté comme stale ; `[début, t2]` démarre.
4. Si une nouvelle cadence expire encore avant sa fin, `[début, t2]` sera lui aussi rejeté.

Les tests unitaires confirment le rejet intentionnel de résultats anciens et le coalescing vers la phrase complète la plus récente. Ils ne prouvent pas que le régime soutenu `temps d'inférence > cadence` publie une preview avant la fin de phrase. Référence dépôt : [`QwenPseudoLiveCoordinatorTests.swift`](../../Tests/QwenPseudoLiveCoordinatorTests.swift).

**Inférence**

Ce comportement protège contre une preview périmée, mais peut faire tomber la couverture publiée à zéro sur une phrase longue. Le compteur cumulatif de résultats stale ne suffit pas : il faut mesurer, par phrase, `premier snapshot éligible`, `premier snapshot accepté`, `nombre de snapshots terminés`, `nombre stale`, durée de la plus longue absence de preview et âge audio du résultat à publication.

L'expérience doit comparer au moins trois politiques :

- **strict latest** actuel ;
- **publish-if-useful** : accepter le résultat terminé si aucun résultat plus récent n'a encore été publié, tout en démarrant le pending ;
- **cadence adaptative** : ne planifier le prochain snapshot qu'après un délai dérivé du RTF récent, avec une borne de fraîcheur.

La seconde politique peut afficher un texte légèrement ancien ; elle n'est admissible que si son âge est visible dans la métrique, sa plage ne traverse aucun final, et son taux d'effacement reste sous la porte définie plus bas.

## Candidats ASR et compatibilité macOS

| Candidat | Fait sourcé / preuve japonaise | Streaming et timestamps | Intégration macOS locale | Licence / empreinte connue | Verdict |
|---|---|---|---|---|---|
| Apple `SpeechTranscriber` | Prévu pour la conversation normale ; preset progressif rapide et volatile | Vrai flux via `SpeechAnalyzer`, plages audio avec le preset actuel | Natif macOS 26 ; déjà intégré et préchauffé | Système Apple | **Garder comme baseline preview**. Les lots donnent la meilleure latence/coverage disponible, mais le pire cas reste hors SLO. |
| Apple `DictationTranscriber` | Apple documente biais contextuel, vocabulaire personnalisé, `farField`, `shortForm`, `atypicalSpeech` et finalisation fréquente | Streaming natif ; finalisation fréquente plus réactive mais potentiellement moins précise | Natif ; non intégré dans ce chemin | Système Apple | **P2 A/B ciblé**, uniquement si noms propres ou parole atypique dominent les erreurs. Pas un remplacement par défaut. ([documentation](https://developer.apple.com/documentation/speech/dictationtranscriber?changes=_1_9)) |
| Qwen3-ASR 1.7B JA MLX 8-bit actuel | Conversion du fine-tune japonais Neosophie ; la carte revendique noms propres et termes techniques mais ne publie ni corpus complet ni évaluation quantitative suffisante | Le produit l'utilise en batch ; pas de timestamp ; pseudo-live par retranscription cumulative | Déjà intégré en MLX Swift ; fichiers ≈ 2,46 Go | Apache-2.0 | **Garder comme final expérimental** et diagnostiquer le scheduler pseudo-live. La preuve locale prime. ([conversion](https://huggingface.co/ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit), [fine-tune](https://huggingface.co/neosophie/Qwen3-ASR-1.7B-JA)) |
| Qwen3-ASR officiel 0.6B / 1.7B | Modèles multilingues incluant le japonais ; offline et streaming unifiés dans l'architecture | Streaming officiel actuellement documenté avec vLLM ; pas de batch ni timestamps en mode streaming. Aligneur séparé 0.6B pour timestamps | Pas de port Swift/MLX streaming officiel identifié | Apache-2.0 | **P2 prototype de vrai streaming**, pas une migration immédiate. Les chiffres serveur/GPU ne prédisent pas un Mac. ([dépôt](https://github.com/QwenLM/Qwen3-ASR), [article](https://arxiv.org/abs/2601.21337)) |
| `mlx-qwen3-asr` communautaire 0.6B | Réutilise Qwen3-ASR ; aucune validation japonaise Mac suffisamment forte publiée | KV cache roulant, contexte borné, préfixe stable et retouche de queue annoncés ; timestamps via aligneur hors flux | Python/MLX Apple Silicon, donc helper et packaging supplémentaires | Apache-2.0 ; chiffres mémoire/performance auteur seulement | **P1 spike isolé de faisabilité**, avant tout port Swift. Arrêt immédiat s'il ne bat pas le pseudo-live sur le même PCM. ([dépôt du runtime](https://github.com/moona3k/mlx-qwen3-asr)) |
| Qwen3-ASR JA Anime/Galgame | La carte auteur rapporte CER in-domain 0,1285 contre 0,1437 pour le modèle de base, sur 800 clips / 4 108 s, avec légère régression JSUT/Common Voice | Batch ; aucun chemin produit MLX épinglé | Conversion et emballage à faire | Vérifier licence et provenance avant tout packaging | **P2 uniquement si le corpus utilisateur est réellement anime/jeu**. Sinon risque de sur-spécialisation. ([carte](https://huggingface.co/jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame)) |
| Whisper large-v3-turbo / whisper.cpp | Modèle multilingue optimisé depuis large-v3 ; OpenAI annonce un décodage plus rapide avec faible baisse de qualité | Fenêtres batch ; timestamps segment/mot disponibles ; streaming par fenêtres dans whisper.cpp | Déjà intégré avec Metal + Accelerate | MIT ; RSS local observé ≈ 3,2 Go dans L03 | **Conserver comme baseline robuste**. `condition_on_previous_text=false` est déjà le bon compromis anti-boucle documenté. ([modèle](https://huggingface.co/openai/whisper-large-v3-turbo), [implémentation](https://github.com/openai/whisper/blob/main/whisper/transcribe.py), [whisper.cpp](https://github.com/ggml-org/whisper.cpp)) |
| Kotoba Whisper v2 Q5 | Distillation japonaise de large-v3 ; carte auteur : CV8 9,2, JSUT 8,4, ReazonSpeech 11,6 ; entraînement annoncé sur ≈ 7,2 M clips ReazonSpeech | Architecture Whisper, timestamps possibles ; batch dans le produit | Recette whisper.cpp déjà testée | Apache-2.0 ; 756 M paramètres avant quantification | **Meilleur challenger final déjà observé**, mais ne promouvoir qu'après gain de latence ou qualité franchissant les portes. ([carte](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0), [dépôt](https://github.com/kotoba-tech/kotoba-whisper)) |
| NVIDIA Parakeet TDT-CTC 0.6B JA via FluidAudio | Modèle japonais avec ponctuation ; NVIDIA publie des CER japonaises, et FluidAudio rapporte 6,88 % de CER moyenne, 208,8 ms de latence moyenne et 28,9× temps réel sur JSUT/M2, mais il s'agit de mesures auteur | Le chemin FluidAudio est batch/fenêtre glissante de 15 s, pas un vrai flux stateful ; aucun timestamp n'est exposé par les cartes consultées | **Faible coût d'essai** : FluidAudio est déjà dépendance du dépôt ; modèle Core ML disponible | Modèle NVIDIA CC-BY-4.0 ; poids de l'encodeur ≈ 594 Mo par format Core ML | **P1 bake-off final prioritaire**. Vérifier attribution, empreinte complète, queue et exact corpus. ([NVIDIA](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja), [modèles FluidAudio](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), [Core ML](https://huggingface.co/FluidInference/parakeet-0.6b-ja-coreml)) |
| Voxtral Mini 4B Realtime | Modèle natif streaming, 13 langues ; article auteur à délai conditionné | Alignement audio/texte interne ; délais configurables dont 480 ms, mais pas de timestamps de sortie natifs documentés ; production officielle via vLLM | Le produit utilise une conversion communautaire MLX Q4/Q6, pas le runtime officiel | Apache-2.0 ; Q4 communautaire ≈ 2,51 Go, RSS produit 4–6 Go | **P1 expérience étroite Q4/480 vs Q4/960**, seulement si le runtime courant le permet. Les résultats locaux dominent les promesses agrégées. ([modèle officiel](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602), [article](https://arxiv.org/abs/2602.11298), [conversion produit](https://huggingface.co/iris-sfg/Voxtral-Mini-4B-Realtime-2602-4bit)) |
| Nemotron / Granite / Cohere locaux | Aucun avantage local suffisant ; Granite hallucine/omet, Nemotron coûte de la mémoire sans meilleur endpoint, provenance Cohere Q8 incomplète | Divers | Prototypes présents ou retirés | Licences/provenance variables | **Ne pas réouvrir sans nouvelle preuve primaire et gain attendu clair**. |
| Qwen direct japonais → anglais `voiceping-ai` | Carte auteur : traduction parole-à-parole via 1.7B, clips ≤ 30 s et évaluation subjective FLEURS | Batch | Intégration distincte | Apache-2.0 | **Ne pas recommander** : le bake-off local a déjà échoué et la preuve publiée est trop faible. ([carte](https://huggingface.co/voiceping-ai/qwen3-asr-ja-en-speech-translation/blob/main/README.md)) |

## Analyse des leviers

### 1. Vrai streaming, snapshots et cache

**Faits sourcés**

- Qwen3-ASR possède une architecture unifiée offline/streaming, mais son chemin streaming officiel public est exposé par vLLM. Le README précise les limitations de batch et timestamps en streaming. ([Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR))
- L'implémentation officielle conserve un état de flux plus riche qu'un simple KV cache : audio cumulé, contexte/préfixe, tokens non fixés et rollback de queue. Sa recette utilise des chunks de 2 s et garde les premiers chunks volatils. ([source officielle](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py))
- Voxtral Realtime est conçu pour le streaming natif et conditionne la sortie sur un délai cible ; les résultats publiés à 480 ms sont agrégés et ne constituent pas une validation japonaise sur Apple Silicon. ([article Voxtral](https://arxiv.org/abs/2602.11298))
- Whisper-Streaming formalise `LocalAgreement-n` : un préfixe est confirmé après accord de plusieurs décodages successifs. Le papier rapporte environ 3,3 s de latence moyenne sur son propre protocole. ([dépôt](https://github.com/ufal/whisper_streaming), [article](https://arxiv.org/abs/2307.14743))

**Observation dépôt**

- Le Qwen Swift embarqué possède un KV cache pendant une génération, mais aucun état public du produit ne réutilise ce cache entre deux snapshots.
- Le snapshot cumulatif est borné par la phrase de 15 s, coalescé latest-only et sérialisé.
- WLK/Whisper-Streaming a déjà échoué en couverture, latence, qualité et mémoire dans L06.

**Inférences recommandées**

1. Ne pas appeler le chemin actuel “streaming” : c'est une suite de redécodages batch cumulatifs.
2. Mesurer le RTF de chaque snapshot en fonction de l'âge de phrase. Si `durée_inférence / durée_audio` monte avec la phrase, augmenter la cadence ou abandonner la preview Qwen plus tôt.
3. Tester LocalAgreement-2 uniquement comme politique d'affichage sur les sorties Qwen déjà produites : plus long préfixe commun normalisé sur les graphèmes Unicode, suffixe volatil, final toujours autoritaire.
4. Ne pas porter un cache cross-snapshot sans prototype séparé : les positions audio, préfixes textuels, tokens non fixés et invalidation à la frontière font partie de l'état streaming officiel Qwen.
5. Le spike le plus court est le runtime communautaire `mlx-qwen3-asr` 0.6B dans un helper jetable. Il ne doit pas entrer dans le produit avant preuve japonaise, audit de packaging et reproductibilité ; en cas de succès, il sert à spécifier le port natif, pas à le présumer.

### 2. VAD et endpointing japonais

**Faits sourcés**

FireRedVAD est un petit modèle multilingue annoncé en modes streaming et non-streaming. Les auteurs publient un F1 de trame supérieur à Silero sur FLEURS-VAD102 ; ce score ne mesure ni les omissions de fin de phrase ni la latence de sous-titres du produit. ([dépôt](https://github.com/FireRedTeam/FireRedVAD), [article](https://arxiv.org/abs/2603.10420))

**Observation dépôt**

- FireRed Core ML est déjà le meilleur choix opérationnel : petit, local, seuil 0,4, lissage 5, fenêtres minimales parole/silence de 100 ms.
- Le post-roll 500 ms et le silence 350 ms donnent de bonnes garanties d'intégrité, mais participent mécaniquement à la latence finale.
- La tentative de frontière dure à 15 s a créé trop de coupures dégradées ; elle ne doit pas être réactivée sans nouveau signal.

**Inférence recommandée**

Faire une grille courte, sur annotations de parole exactes : seuil `{0,35; 0,40; 0,45}`, silence `{250; 350; 450 ms}`, post-roll `{350; 500; 650 ms}`. Éliminer d'abord toute configuration qui perd le dernier mot, coupe une mora, crée un backlog ou dépasse le taux de frontières dégradées. Parmi les survivantes seulement, choisir la meilleure p95 finale.

Ne pas ajouter Silero, WebRTC VAD ou un second endpoint neuronal sans gain mesuré. Si le profilage montre que la fenêtre roulante FireRed coûte trop d'énergie, comparer le mode streaming officiel FireRed à la conversion Core ML actuelle avant de changer de famille de VAD.

Apple expose aussi `SpeechDetector`, mais la documentation publique actuelle ne fournit pas une interface de frontières assez claire pour en faire l'autorité produit. Un spike peut vérifier les résultats réellement exposés sur les versions macOS ciblées et son coût lorsqu'il partage le même `SpeechAnalyzer`; FireRed reste autoritaire tant que les transitions et les tails ne sont pas prouvés. ([SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector))

### 3. Contexte, glossaire et termes rares

**Observation dépôt**

- Apple reçoit les 100 premiers termes canoniques.
- Qwen reste volontairement sans prompt.
- La correction post-ASR est déterministe, alias le plus long d'abord, avec priorité au profil de sujet.

**Inférences recommandées**

- Faire un A/B Apple `aucun contexte` / `termes canoniques` / `lectures kana` sur un sous-corpus de noms, lieux, produits et jargon. Mesurer rappel des termes, substitutions phonétiques et CER environnante.
- Ne jamais remplir les 100 places par fréquence arbitraire. Choisir un profil explicite lié au contenu capturé, stable pour tout le run.
- Ne pas envoyer le glossaire dans le prompt Qwen actuel : le dépôt possède déjà une preuve de prompt echo.
- Limiter les alias post-ASR aux remplacements exacts ou normalisés non ambigus. Tout remplacement sémantique ou génératif doit être évalué comme un autre modèle, avec risque d'hallucination.
- Envisager `DictationTranscriber` et son vocabulaire personnalisé seulement si l'A/B montre que `SpeechTranscriber` n'exploite pas réellement le contexte.

### 4. Apple Speech et Apple Translation

**Faits sourcés**

- Apple recommande `prepareToAnalyze` pour charger les actifs avant l'audio et expose une politique de rétention du modèle. Le dépôt suit déjà cette voie. ([SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer))
- Apple Translation s'exécute sur l'appareil. `lowLatency` vise la vitesse ; `highFidelity` vise une traduction plus fluide et peut retomber sur low-latency si Apple Intelligence n'est pas disponible. ([TranslationSession](https://developer.apple.com/documentation/translation/translationsession), [Strategy](https://developer.apple.com/documentation/translation/translationsession/strategy), [highFidelity](https://developer.apple.com/documentation/translation/translationsession/strategy/highfidelity?language=objc))
- L'API publique traduit une chaîne ou un lot de requêtes, mais ne documente pas de mémoire conversationnelle de traduction. ([batch translation](https://developer.apple.com/documentation/translation/translationsession/batchresponse))

**Inférences recommandées**

- Garder deux sessions séparées et préparées. Enregistrer dans chaque run le modèle de Mac, la version macOS, l'état des actifs, la stratégie demandée et la disponibilité Apple Intelligence ; sinon deux machines peuvent exécuter des chemins réels différents.
- Tester `finalizeAvailableAudio` à 0,75 / 1 / 1,5 s. Une cadence plus courte n'est retenue que si elle améliore le premier texte et la p95 sans augmenter les révisions, erreurs ou coût énergétique.
- Comparer, aux frontières FireRed seulement, `finalize(through:)` avec une limite audio explicite à l'appel actuel `finalize(through: nil)`. Le but est de synchroniser la demande de finalisation, sans transférer l'autorité de frontière à Apple.
- Ne pas batcher les phrases live pour “donner du contexte” : cela ajoute de l'attente et l'API ne promet aucune cohérence inter-requêtes. Le batching reste pertinent pour un export ou un retry hors chemin live.
- Pour la traduction, mesurer séparément latence Apple et latence source. L08A montre déjà que la preview Voxtral est limitée par l'ASR, pas par Apple Translation.

### 5. Robustesse, timeouts et anti-hallucination

**Observation dépôt — points forts**

- session et génération invalident les résultats tardifs ;
- preview latest-only et final FIFO ;
- validation anglaise, timeouts de traduction, retries bornés ;
- PCM conservé en cas d'échec final ;
- helper Voxtral isolé avec timeout et rotation sûre ;
- télémétrie de queue, ASR, traduction, stale/coalescing, mémoire et intégrité.

**Lacunes à mesurer avant correction**

- Un appel Qwen/MLX in-process long ne possède pas l'isolation d'un helper ; annuler une `Task` Swift ne garantit pas l'arrêt d'un calcul natif déjà lancé.
- La validation boucle/CJK intervient surtout sur l'anglais. Une boucle japonaise peut atteindre la traduction et devenir une phrase anglaise plausible.
- Le compteur stale Qwen est cumulatif, mais la couverture n'identifie pas directement une phrase qui n'a jamais publié de snapshot Qwen.

**Inférences recommandées**

1. Ajouter dans l'évaluation un validateur source **non destructif** : vide, répétition de caractères/n-grammes, débit de caractères invraisemblable, manque de recouvrement avec une plage VAD parlée. Une suspicion met le segment en quarantaine/retry ; elle ne libère jamais le PCM.
2. Calibrer chaque seuil sur le corpus. Un filtre japonais naïf peut confondre répétition expressive légitime et boucle de décodeur.
3. Mesurer un budget RTF par moteur et âge de phrase. Si le budget est dépassé, marquer la preview `degraded` et laisser le final FIFO continuer ; ne pas empiler les tâches.
4. Pour une vraie garantie de timeout dur, isoler le runtime dans un processus helper tuable. Un simple `withTimeout` autour d'un appel MLX synchrone ne suffit pas.
5. Après crash ou arrêt, rejouer uniquement le PCM stable récupéré, jamais un texte partiel comme vérité.

### 6. Longues sessions, mémoire, énergie et thermique

**Faits sourcés**

macOS expose `ProcessInfo.thermalState` (`nominal`, `fair`, `serious`, `critical`) et recommande de réduire l'usage de ressources lorsque l'état thermique monte. ([ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo), [ThermalState](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum?changes=_1__6))

**Observation dépôt**

- La session Voxtral à rotation 720 s restaure l'intégrité de fin, mais consomme encore environ 4–6 Go et reste lente/variable.
- Les chemins endpointés Qwen/Kotoba/Turbo limitent naturellement l'état ASR à une phrase, mais la queue de finals et le stockage PCM peuvent croître si le consommateur ralentit.
- La porte actuelle exige zéro backlog résiduel et moins de 10 Gio, avec au plus 20 % au-dessus de la baseline.

**Inférences recommandées**

- N'exécuter les soaks 30/60/120 min qu'après le passage des lots courts de qualité.
- Échantillonner toutes les 5 s : RSS, empreinte GPU si disponible, taille FIFO/PCM, âge du plus ancien job, RTF, énergie, `thermalState`, vitesse de ventilateur si mesurable de façon reproductible.
- Séparer les runs secteur/batterie et cold/warm ; ne jamais mélanger deux moteurs dans un même run de décision.
- À `serious`, dégrader d'abord la fréquence de preview et conserver le final ; à `critical`, signaler clairement la preview indisponible plutôt que de risquer un backlog ou une perte audio.
- Vérifier la stabilité des actifs Apple lors des changements de veille, casque, périphérique audio, locale et retour d'application en avant-plan.

### 7. Politique d'affichage

Apple recommande de rendre les sous-titres personnalisables et lisibles ; sur macOS la taille typographique par défaut recommandée est 13 pt, avec 10 pt minimum. Le W3C rappelle que les sous-titres doivent rester synchronisés et ne pas masquer l'information visuelle pertinente. ([Apple HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/), [W3C Captions/Subtitles](https://www.w3.org/WAI/media/av/captions/), [WCAG live captions](https://www.w3.org/WAI/WCAG21/Understanding/captions-live))

**Inférences recommandées**

- Une seule zone preview révisable, visuellement distincte (opacité ou libellé), sous des lignes finales immuables.
- Le final remplace la preview correspondante sans animation de déplacement brusque ; il ne réécrit jamais un final antérieur.
- Afficher un état court `Preview en retard` si aucun snapshot accepté n'arrive pendant le budget, sans masquer les finals.
- Éviter d'afficher les fillers isolés et les fragments d'un seul caractère sauf ponctuation japonaise terminale ou terme critique.
- Offrir taille, contraste, largeur et position configurables ; garder au plus deux lignes visibles par bloc, puis faire défiler les finals dans l'historique.
- Mesurer la lisibilité avec des utilisateurs bilingues : compréhension, révisions remarquées, texte manqué, gêne liée au scintillement. La CER seule ne mesure pas cette expérience.

## Mesure reproductible

### Corpus minimal

Utiliser exactement les deux vidéos complètes de L07C/L08. Les fenêtres de stress,
les 92 tours japonais, le lot de termes critiques et le holdout sont des
sous-ensembles figés de ces deux mêmes références, jamais d'autres corpus.

Les SHA-256, PCM 16 kHz, japonais, anglais, locuteurs, plages, bandes de
confiance et overlaps fournis restent inchangés. Aucun autre corpus ne peut
promouvoir une pipeline.

### Métriques ASR japonaises

- CER globale, puis insertions/substitutions/suppressions séparées ;
- CER par locuteur, bruit, débit, durée et type de frontière ;
- rappel/précision/F1 des termes critiques ;
- exactitude des nombres, négations, noms et dernière phrase ;
- taux vide, boucle, hallucination en silence et caractères hors japonais attendu ;
- intégrité : échantillons PCM continus, dernier échantillon de parole, queue finale nulle.

### Métriques traduction anglaise

- chrF++ et COMET uniquement comme diagnostics automatiques ; chrF travaille au niveau caractères/n-grammes, COMET est un estimateur appris et aucun des deux ne remplace le jugement humain. ([chrF++](https://aclanthology.org/W17-4770.pdf), [COMET](https://aclanthology.org/2020.emnlp-main.213/))
- revue bilingue MQM : exactitude, omission, ajout, terminologie, négation/nombre, fluidité et cohérence de segmentation. Une étude MQM montre l'intérêt d'une évaluation humaine experte et du contexte ; appliquer ici une procédure plus légère mais annotée. ([MQM/context](https://aclanthology.org/2021.tacl-1.87/))
- scores sacreBLEU/chrF avec signature de configuration enregistrée pour éviter les variantes silencieuses. ([SacreBLEU](https://github.com/mjpost/sacrebleu))

### Métriques live

- preview : couverture par phrase, temps parole→premier texte, p50/p95/pire, âge audio à publication ;
- pseudo-live : ticks demandés, coalescés, terminés, stale, acceptés ; phrases sans résultat accepté ;
- stabilité : caractères effacés / caractères émis, nombre de révisions, longueur et âge du préfixe stable, plus longue disparition ;
- final : fin de parole→rendu p50/p95/pire, temps ASR, queue, traduction et rendu séparés ;
- système : RTF par âge de phrase, RSS, thermique, énergie, débit PCM et backlog maximal/résiduel.

### Protocole

1. Figer commit, recettes, versions, révisions de modèles, matériel, macOS et alimentation.
2. Préparer un run cold et un run warm ; ne pas mélanger leurs résultats.
3. Rejouer le même PCM ; une seule pipeline à la fois.
4. Contrebalancer l'ordre des configurations ou attendre le retour thermique à `nominal`.
5. Faire trois répétitions pour les mesures de latence et de ressources ; les textes déterministes doivent rester identiques.
6. Conserver JSONL brut, logs de frontières, segments source/anglais, timelines et erreurs.
7. Calculer les écarts appariés et un bootstrap apparié à 95 %.
8. Régler sur le corpus de développement, décider une seule fois sur le holdout.

### Portes de promotion

Conserver les portes du dépôt :

- preview : couverture ≥ 95 %, p50 ≤ 1 s, p95 ≤ 1,8 s, pire ≤ 3 s ;
- final : p95 ≤ 1,5 s depuis la fin de parole, ordre stable append-only ;
- intégrité : PCM complet, dernière parole présente, zéro omission par rapport au transcrit de référence, backlog final nul ;
- ressources : < 10 Gio et ≤ 20 % au-dessus de la baseline ;
- promotion qualité : amélioration CER relative ≥ 10 % avec bootstrap 95 %, ou gain preview p95 ≥ 200 ms avec dégradation CER ≤ 2 points ; aucun holdout ne se dégrade de > 2 points.

Ajouter deux portes pour le pseudo-live :

- ≥ 95 % des phrases éligibles publient au moins une preview acceptée avant le final ;
- p95 des caractères effacés normalisés et pire durée sans preview ne régressent pas par rapport à Apple Speech. Le seuil absolu doit être fixé après mesure de la baseline, pas inventé a priori.

## Recommandations classées

| Priorité | Action | Impact attendu | Effort | Risque | Niveau de preuve | Porte de décision |
|---|---|---|---|---|---|---|
| P0 | Conserver les deux références vidéo fournies comme seul corpus de décision | Rend les comparaisons reproductibles | Aucun | Faible | Décision E0 + SHA/PCM vérifiés | Deux manifestes `complete`, préflight vert |
| P0 | Comparer `qwenApple` et `qwenPseudoLiveApple` sur même PCM, avec couverture acceptée par phrase | Sépare vraiment Apple preview de Qwen pseudo-live | Faible | Faible | Code vérifié + lots Apple | Portes preview, final, CER et intégrité existantes |
| P0 | Tester strict-latest / publish-if-useful / cadence adaptative pour Qwen | Évite le régime toujours stale | Moyen | Preview un peu plus ancienne ou instable | Défaut déterministe vérifié dans le coordinateur | ≥95 % de phrases avec preview ; gain p95 ≥200 ms ou meilleure stabilité sans >2 pts CER |
| P0 | Petite grille cadence Qwen 1/2/3 s et finalisation Apple 0,75/1/1,5 s | Gain de latence sans changer de modèle | Faible | Plus de calcul/révisions | Paramètres déjà présents + API Apple | Portes live et ressources |
| P0 | Instrumenter stabilité, âge et absence de preview | Évite une fausse “bonne p95” calculée seulement sur résultats publiés | Faible | Faible | Lacune de métrique observée | Aucun run de promotion sans dénominateur par phrase |
| P0 | Conserver preview jetable / final FIFO autoritaire | Protège PCM et stabilité | Aucun | Aucun | Architecture et tests dépôt | Invariant non négociable |
| P1 | Bake-off Parakeet JA Core ML comme final | Candidat local potentiellement rapide et léger | Moyen | Licence attribution, score non transférable, batch | Modèle officiel + FluidAudio auteur | Mêmes lots ; ≥10 % CER relatif ou latence finale conforme sans régression |
| P1 | Spike helper `mlx-qwen3-asr` 0.6B | Vérifie vite si un vrai cache streaming vaut un port Swift | Moyen | Runtime communautaire, Python, preuve JA absente | Implémentation primaire du runtime, pas preuve produit | Même PCM ; ≥200 ms p95 et qualité/stabilité conformes, sinon arrêt |
| P1 | LocalAgreement-2 d'affichage pour Qwen | Moins de scintillement | Moyen | Préfixe faux figé visuellement | Article primaire, WLK produit rejeté | Stabilité meilleure sans perte de couverture/latence |
| P1 | Grille FireRed seuil/silence/post-roll | Réduit éventuellement la p95 finale | Moyen | Omission de fin / mora coupée | FireRed primaire + lots locaux | Intégrité d'abord, latence ensuite |
| P1 | A/B contexte Apple off/canonique/kana | Meilleur rappel des noms et jargon | Moyen | Biais ou prononciation erronée | Documentation limitée à Dictation | Terme F1 meilleur, CER globale et holdout stables |
| P1 | Q4/480 vs Q4/960 Voxtral si supporté par le runtime courant | Teste le levier natif de délai | Moyen | Forte régression qualité / chauffe | Article officiel ; résultats produit faibles | Toutes les portes ; sinon arrêt de Voxtral |
| P1 | Soaks 30/60/120 min après qualification courte | Valide mémoire, thermique, rotation, queue | Moyen | Temps de test | L08B2/B3 + API thermique Apple | Zéro queue/tail perdu ; ressources conformes |
| P2 | Prototype vrai streaming Qwen Swift/MLX | Peut supprimer les redécodages | Élevé | Port incomplet, cache invalide, maintenance | Architecture officielle, runtime local non prouvé | Prototype isolé ≥200 ms p95, CER ≤+2 pts, mémoire conforme |
| P2 | `DictationTranscriber` + vocabulaire/custom hints | Peut aider noms/parole atypique | Moyen | Qualité générale moindre | Apple officiel | Sous-corpus ciblé gagnant sans régression globale |
| P2 | Spike `SpeechDetector` + `finalize(through:)` | Peut réduire travail ou mieux synchroniser Apple | Faible à moyen | API de frontières insuffisamment démontrée | Apple officiel | FireRed reste autoritaire ; aucun tail perdu |
| P2 | Fine-tune Qwen anime/jeu | Gain in-domain possible | Élevé | Sur-spécialisation, packaging | Carte auteur seulement | Domaine réel majoritaire + exact corpus gagnant |
| P2 | ForcedAligner Qwen pour timestamps finaux | Meilleure précision temporelle | Élevé | Modèle 0.6B supplémentaire et latence | Qwen officiel | Seulement si mesure utilisateur prouve un défaut de timing |

## Non-recommandations

- **Ne pas promouvoir Voxtral sur la base du papier ou du model card** : les lots produit montrent preview lente, omissions de queue et forte variance selon la vidéo.
- **Ne pas réactiver les frontières japonaises forcées L08C** : le taux de coupures dégradées et les latences ont déjà échoué.
- **Ne pas utiliser le replay textuel pour réparer la queue Voxtral** : L08B a créé des boucles massives sans récupérer sûrement la vraie fin.
- **Ne pas remettre WLK/SimulStreaming comme dépendance produit** : L06 a déjà échoué en couverture, latence, finalisation et mémoire. Seule l'idée de préfixe commun peut être testée localement.
- **Ne pas ajouter un LLM de post-correction dans le chemin live** : coût, latence et hallucination supplémentaires ; préférer des alias exacts et auditables.
- **Ne pas envoyer de hotwords/prompt à Qwen actuel** tant que le prompt echo n'est pas éliminé sur les phrases courtes.
- **Ne pas remplacer FireRed par un autre VAD** sans preuve exacte de meilleure intégrité et latence sur ce corpus.
- **Ne pas réouvrir Nemotron, Granite ou Cohere Q8** sans changement externe substantiel ; les preuves locales ou la provenance les disqualifient actuellement.
- **Ne pas promouvoir la traduction directe Qwen JA→EN VoicePing** : preuve auteur subjective et échec local déjà consigné.
- **Ne pas confondre Parakeet v3 multilingue européen avec le modèle japonais TDT-CTC séparé**.
- **Ne pas utiliser les chiffres GPU/vLLM Qwen ou Voxtral comme prédiction macOS**.
- **Ne pas masquer les erreurs par un filtre destructif** : toute sortie suspecte doit conserver le PCM et rester réessayable.

## Plan d'expériences proposé

### E0 — références

- Faire relire et signer les références de décision.
- Livrable : manifest SHA + statut humain + liste des termes critiques.
- Arrêt : aucun autre lot ne peut promouvoir un moteur si E0 n'est pas terminé.

### E1 — baseline instrumentée

- `qwenApple`, cadence Apple actuelle, même PCM, trois runs warm.
- Ajouter les métriques de stabilité et les dénominateurs par phrase.
- Livrable : distribution complète, pas seulement médiane/p95 des événements présents.

### E2 — pseudo-live Qwen scheduler

- Cadences 1/2/3 s × strict-latest/publish-if-useful/adaptative.
- Même modèle, même traduction, même VAD.
- Mesurer RTF par âge de phrase, stale, couverture, révisions, effacement et énergie.
- Arrêt anticipé si backlog, couverture <95 %, tail perdu ou RSS hors porte.

### E3 — finalisation Apple

- `finalizeAvailableAudio` 0,75/1/1,5 s sur `qwenApple` seulement.
- Mesurer premier lexical, preview p95, révisions, CPU/énergie et CER de preview.
- Ne changer le défaut que si le gain est reproductible et sans instabilité.

### E4 — final ASR

- Qwen 1.7B actuel, Kotoba Q5, Whisper Turbo, Parakeet JA Core ML.
- FireRed, Apple Translation high-fidelity, segmentation et PCM identiques.
- Décision sur CER appariée, termes critiques, p95 finale, RSS et backlog.

### E5 — contexte Apple

- Off / canonique / lectures kana, profils général et sujet testés séparément.
- Sous-corpus noms/jargon + holdout général.
- N'activer que le profil qui gagne sur terme F1 sans >2 points de CER sur le holdout.

### E6 — endpoint

- Grille FireRed courte définie plus haut.
- Annotations de début/fin parole, dernière mora et terme critique.
- Toute omission élimine immédiatement la configuration.

### E7 — Voxtral conditionnel

- Seulement si E1–E6 ne permettent pas les SLO.
- Q4/480 vs Q4/960, rotation 720 s inchangée, deux vidéos complètes.
- Arrêt si preview p95 >1,8 s sur le premier run ou si la dernière phrase manque.

### E7b — vrai streaming Qwen, conditionnel

- Seulement si E2 confirme que le redécodage cumulatif est le goulet.
- Helper isolé `mlx-qwen3-asr` 0.6B, chunks 2 s puis 1 s, même PCM.
- Comparer préfixe stable, rollback, tail, CER, p95, RSS et packaging.
- Aucun port Swift si le helper ne franchit pas les portes.

### E8 — endurance

- Le gagnant et la baseline, 30/60/120 min, secteur puis batterie.
- Changement de périphérique, veille/réveil, silence long, parole continue, fin pendant calcul.
- Vérifier tail, queue, reprise, thermique, RSS et lisibilité.

## Sources primaires principales

- Apple : [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber?changes=_1), [presets](https://developer.apple.com/documentation/speech/speechtranscriber/preset), [AnalysisContext](https://developer.apple.com/documentation/speech/analysiscontext), [TranslationSession](https://developer.apple.com/documentation/translation/translationsession), [Translation strategy](https://developer.apple.com/documentation/translation/translationsession/strategy), [ProcessInfo](https://developer.apple.com/documentation/foundation/processinfo).
- Qwen : [dépôt officiel](https://github.com/QwenLM/Qwen3-ASR), [article](https://arxiv.org/abs/2601.21337), [conversion produit](https://huggingface.co/ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit).
- Whisper/Kotoba : [Whisper](https://github.com/openai/whisper), [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [Kotoba Whisper v2](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0).
- Voxtral : [modèle officiel](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602), [article](https://arxiv.org/abs/2602.11298), [conversion MLX utilisée](https://huggingface.co/iris-sfg/Voxtral-Mini-4B-Realtime-2602-4bit).
- VAD : [FireRedVAD](https://github.com/FireRedTeam/FireRedVAD), [article](https://arxiv.org/abs/2603.10420).
- Streaming : [Whisper-Streaming](https://github.com/ufal/whisper_streaming), [LocalAgreement paper](https://arxiv.org/abs/2307.14743).
- Évaluation : [chrF++](https://aclanthology.org/W17-4770.pdf), [COMET](https://aclanthology.org/2020.emnlp-main.213/), [MQM/context](https://aclanthology.org/2021.tacl-1.87/), [SacreBLEU](https://github.com/mjpost/sacrebleu).

## Décision proposée

**Maintenir `qwenApple` comme baseline produit**, avec Apple Speech preview, Qwen final par phrase et Apple Translation. Ne promouvoir `qwenPseudoLiveApple`, Parakeet, Kotoba ou Voxtral qu'après passage des mêmes portes sur le même PCM.

Le premier chantier utile est E0→E2 : références validées, baseline instrumentée, puis diagnostic du scheduler pseudo-live. C'est le chemin le plus court pour savoir si Qwen peut réellement améliorer la preview ou si ses résultats sont simplement trop souvent stale pour être visibles.
