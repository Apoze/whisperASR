# TranslateGemma JA→EN : architecture de traduction fiable

Date de recherche : 2026-08-09  
Périmètre : sous-titres hors ligne, TranslateGemma 12B local, deux vidéos de référence disponibles. Aucun changement produit.

## Décision

La priorité n'est pas d'ajouter un second modèle de correction. Il faut d'abord :

1. **traduire des unités japonaises cohérentes, indépendantes des tours SpeakerKit** ;
2. **utiliser le format direct officiel de TranslateGemma** : le dernier message utilisateur contient seulement le japonais à traduire et la sortie contient seulement sa traduction ;
3. **valider chaque sortie de façon déterministe**, puis relancer uniquement les segments suspects sans contexte ;
4. **sélectionner un glossaire exhaustif au repos mais minuscule et pertinent par segment** ;
5. ne tester une métrique QE locale qu'ensuite, comme outil de classement et non comme correcteur.

Cette architecture reste compatible avec la contrainte d'un seul modèle lourd chargé à la fois.

## Preuve locale et cause principale

Le bakeoff sur les segments japonais de référence est sain : TranslateGemma obtient **COMET 0,7746 / 0,7455**, **chrF++ 55,35 / 57,35**, et les marqueurs sont retrouvés dans 940/940 sorties des deux candidats ([E05](../experiments/E05-local-translator-bakeoff.md)).

La chaîne complète chute fortement : avec Qwen JA, COMET tombe à **0,4661 / 0,5013** et TranslateGemma manque ses marqueurs natifs 61 fois sur la vidéo DEV et 556 fois sur le holdout ([E06](../experiments/E06-offline-high-quality-acceptance.md)). Ce contraste montre que TranslateGemma n'est pas seul en cause.

Le code et les artefacts bruts expliquent le mécanisme :

- [`speakerTurns`](../../../Sources/HighQualityJob.swift) remplace les phrases par les fragments issus des intersections SpeakerKit/alignement. Dans les artefacts E06, 216/396 tours Qwen DEV et 224/557 tours Qwen holdout ne dépassent pas deux caractères ; plusieurs héritent du même contexte voisin.
- [`contextText`](../../../Sources/LocalMLXTranslator.swift) place le locuteur, le contexte avant, le segment courant et le contexte après dans le champ `text` à traduire.
- si un marqueur manque, [`translationText`](../../../Sources/LocalMLXTranslator.swift) accepte actuellement **la réponse entière**. Les sorties brutes montrent alors le segment, la traduction du contexte répétée et parfois une introduction du modèle. L'artefact représentatif est `.build/benchmarks/high-quality/offline-acceptance/qwen-ja/md62mmdz0m/jobs/44000002-0000-4000-8000-000000000001/raw-asr.json`.

Conclusion : **SpeakerKit doit annoter les locuteurs, pas définir l'unité sémantique traduite**. Un vérificateur ajouté après la chaîne actuelle masquerait le symptôme sans corriger la fragmentation.

## Architecture cible, par priorité

### P0 — Découpler traduction et diarisation

- Construire les unités de traduction depuis le texte ASR/aligné : ponctuation, pauses et limite de taille, avec fusion des fragments trop courts.
- Traduire une unité cohérente une seule fois.
- Reporter ensuite ses mots/segments sur les timestamps et les labels SpeakerKit. Un changement de locuteur peut suggérer une frontière, mais ne doit pas couper une syllabe ou dupliquer du japonais.
- Pour la parole superposée, conserver les spans/labels comme métadonnées. Ne pas concaténer plusieurs fragments concurrents dans une fausse phrase.
- Ne conserver un segment de 1–2 caractères que s'il appartient à une liste fermée d'interjections autonomes ; les seuils exacts doivent être calibrés sur DEV.

Une approche deux passes — traduction sur des phrases avec davantage de contexte, puis réalignement vers les sous-titres temporels — est aussi la direction retenue par un système de sous-titrage IWSLT récent ([papier IWSLT 2026](https://aclanthology.org/2026.iwslt-1.7/)).

### P1 — Sortie directe, identité gérée par l'application

TranslateGemma documente un gabarit précis : rôles User/Assistant, un seul contenu texte par message, texte utilisateur réservé au texte à traduire, et sortie limitée à la traduction. Les prompts alternatifs et l'APE ne sont pas officiellement pris en charge ([model card officielle](https://huggingface.co/google/translategemma-12b-it)).

Pour chaque unité :

```text
application : cueID = cue-0042
TranslateGemma User.text : <japonais courant seulement>
TranslateGemma Assistant : <anglais seulement>
application : associe la sortie à cue-0042 et produit JSON/SRT/VTT
```

Il est inutile de demander au modèle de reproduire un ID, du JSON ou des marqueurs quand l'application lance une génération par unité. Si un mode expérimental conserve les marqueurs, **leur absence doit être un échec**, jamais l'autorisation de garder toute la réponse.

TranslateGemma accepte 2 000 tokens de contexte, mais son entraînement de traduction couvre surtout des phrases et blocs allant jusqu'à 512 tokens ([rapport technique officiel](https://arxiv.org/pdf/2601.09012)). La limite de 2 000 tokens ne justifie donc pas de remplir le prompt avec des voisins non ciblés.

### P2 — Contexte conversationnel sans le faire traduire

Le contexte reste utile pour les pronoms, l'ellipse et la cohérence lexicale, erreurs connues en traduction de sous-titres ([Voita et al., ACL 2019](https://aclanthology.org/P19-1116/)). Il faut toutefois le tester après P0/P1 :

1. baseline : japonais courant seul ;
2. candidat recommandé : un ou deux couples **JA→EN déjà validés** comme tours User/Assistant précédents, puis le japonais courant seul dans le dernier tour User ;
3. réinitialiser le contexte au changement de sujet/scène et ne jamais réutiliser une sortie rejetée ;
4. tester le contexte suivant seulement dans une seconde expérience, car il exige une première passe et peut propager ses erreurs.

Cette utilisation multi-tour respecte les types de rôles du gabarit, mais son gain doit être prouvé par A/B : la documentation ne promet pas une qualité documentaire. Les travaux de QE conversationnelle confirment aussi que le contexte incomplet ou erroné peut nuire, surtout sur les tours courts ([Vernikos et al., 2024](https://arxiv.org/pdf/2403.08314)).

## Validateur déterministe

Le validateur produit un verdict, des codes de raison et les preuves brutes. Il ne réécrit pas librement l'anglais avec des regex.

| Ordre | Contrôle | Verdict recommandé |
|---|---|---|
| 1 | Sortie vide, invalide, cue manquant/dupliqué/inconnu | Échec dur |
| 2 | Japonais résiduel : hiragana, katakana, demi-largeur ou idéogrammes CJK, hors allowlist explicite | Échec dur |
| 3 | Échafaudage : `SPEAKER_ID`, `CONTEXT_*`, marqueurs, bloc Markdown, préambule du type « here's the translation » | Échec dur |
| 4 | Terme source non ambigu présent mais canon/alias anglais absent ; ou terme critique inventé | Échec dur |
| 5 | Limite de tokens atteinte, phrases/trigrammes répétés, ratio de longueur pathologique | Échec dur |
| 6 | Même phrase anglaise répétée dans des sorties adjacentes dont les sources diffèrent | Suspect, relance ciblée |
| 7 | Fort recouvrement n-gramme avec la traduction d'un voisin, sans répétition correspondante en japonais | Suspect, relance ciblée |
| 8 | Plusieurs paragraphes/phrases pour une source minuscule | Suspect, relance ciblée |

Pour le japonais résiduel, analyser les scalaires Unicode (kana, kana demi-largeur, CJK et marques japonaises significatives), pas seulement `\p{Han}`. L'allowlist doit être vide par défaut et limitée à un nom de marque volontairement conservé. Les nombres et la ponctuation ne sont pas des erreurs.

Les seuils de longueur et de similarité doivent être appris sur DEV puis figés avant holdout. Un simple ratio n'est pas un veto universel : une traduction naturelle peut légitimement être plus longue.

## Relance sélective

1. **Tentative A** : prompt direct, avec le contexte A/B retenu et les seuls termes pertinents.
2. Si le validateur échoue : **tentative B uniquement pour ce segment**, prompt officiel minimal sans voisins et avec au plus les exemples canoniques ayant échoué.
3. Deux échecs durs : ne pas publier silencieusement le segment ; le marquer en échec dans le job et conserver les deux sorties.

Une relance identique à température 0 n'apporte rien. La seconde tentative doit retirer la cause probable : contexte, marqueur, métadonnées ou glossaire ambigu. Conserver pour chaque tentative : prompt natif, sortie native, hash du modèle, tokens, durée, code de rejet et choix final.

## Glossaire : exhaustif sans saturer le prompt

Le rapport TranslateGemma observe précisément une régression JA→EN liée aux entités nommées lors de l'évaluation humaine ([rapport technique](https://arxiv.org/pdf/2601.09012)). Le glossaire est donc prioritaire, mais sa taille sur disque et sa taille dans un prompt sont deux problèmes différents.

- **Catalogue local large et versionné** : nom japonais officiel, formes kana/kanji/romanisation, anglais canonique, aliases acceptables, domaine, chaîne/jeu/série, ambiguïté, source primaire, date de vérification.
- **Sources** : sites officiels des jeux/anime, pages officielles de personnages/objets/capacités, roster officiel d'agence VTuber et métadonnées de la chaîne. Les métadonnées servent à **sélectionner**, jamais comme paire de traduction identitaire.
- **Sélection par segment** : formes exactes dans la source, plus métadonnées pour lever une ambiguïté. Les aliases ASR approximatifs n'agissent que si la métadonnée confirme l'entité.
- **Prompt** : une seule cible canonique par forme japonaise. Les aliases anglais servent au validateur, pas comme plusieurs réponses Assistant contradictoires.
- **Budget initial à tester** : 8–12 entrées pertinentes et au plus 25 % des tokens d'entrée ; ce n'est pas une valeur produit avant validation.
- **Dureté** : noms propres et terminologie officiellement figée en règles dures ; expressions contextuelles comme `お疲れ様` en profil souple, car leur traduction dépend de la situation.
- **Cohérence vidéo** : après la première occurrence validée, conserver la variante choisie dans un petit registre par job.

Le catalogue actuel annonce lui-même sa couverture limitée à 16 termes et le prompt envoie le canon **et chaque alias** comme cibles distinctes ; il injecte aussi titre, chaîne et description sous forme `source→source` ([implémentation actuelle](../../../Sources/HighQualityGlossary.swift), [construction du prompt](../../../Sources/LocalMLXTranslator.swift)). E05 ne mesure que quatre opportunités et 25 % de respect : cette preuve est trop petite pour valider le glossaire.

## QE et auto-révision

| Option | Avis | Motif |
|---|---|---|
| Contrôles déterministes + relance ciblée | **À faire d'abord** | Local, explicable, faible coût, couvre les corruptions observées |
| MetricX-24 Hybrid Large, mode QE sans référence | **Candidat à benchmarker ensuite** | Apache-2.0, japonais pris en charge, famille utilisée comme signal d'entraînement de TranslateGemma ; modèle PyTorch/mT5 à charger après déchargement de TranslateGemma ([model card Google](https://huggingface.co/google/metricx-24-hybrid-large-v2p6-bfloat16)) |
| COMETKiwi | Recherche seulement | QE référence-free et japonais pris en charge, mais licence CC-BY-NC-SA-4.0 et accès soumis à conditions ([model card officielle](https://huggingface.co/Unbabel/wmt22-cometkiwi-da)) |
| XCOMET-XL | Ne pas intégrer | Localisation des erreurs intéressante, mais 3,5B, gated et CC-BY-NC-SA-4.0 ([model card officielle](https://huggingface.co/Unbabel/XCOMET-XL)) |
| TranslateGemma se critique puis se réécrit | **Dernier essai seulement** | APE non officiellement supporté ; la méthode TEaR peut aider de gros LLM, mais l'estimation faible hallucine et le gain publié du petit Mistral est minime, sans preuve japonaise ([TEaR, NAACL 2025](https://aclanthology.org/2025.findings-naacl.218/)) |

Une métrique QE **score** une traduction ; elle ne la nettoie pas. Le mode qualité maximale pourrait générer deux candidats seulement pour les segments suspects, décharger TranslateGemma, charger MetricX, puis choisir le candidat. Il faut calibrer son seuil avec les références locales et un jeu de corruptions injectées (contexte recopié, japonais résiduel, nom propre faux, répétition). Le projet COMET documente aussi le QE sans référence, le reranking MBR et les modèles contextuels, utiles comme protocole de comparaison ([dépôt officiel COMET](https://github.com/Unbabel/COMET)).

## Ordre des expériences

Chaque ligne change une seule variable, réutilise les artefacts ASR/alignement/diarisation figés, ouvre le holdout seulement après la porte DEV, et conserve les entrées/sorties natives.

1. **Segmentation** : tours SpeakerKit actuels vs unités sémantiques, même TranslateGemma/prompt.
2. **Prompt** : marqueurs/contextes actuels vs format direct officiel, mêmes unités.
3. **Contexte** : aucun vs un/deux tours bilingues validés précédents.
4. **Glossaire** : prompt actuel vs canon unique, pertinent par segment, sans identité de métadonnées.
5. **Validateur + relance** : une passe vs relance sélective.
6. **QE** : meilleur candidat précédent vs reranking MetricX sur segments suspects.
7. **Auto-révision TranslateGemma** : seulement si MetricX n'apporte pas assez.

## Portes de promotion

- zéro cue manquant, dupliqué, inconnu ou vide ;
- zéro japonais résiduel, échafaudage ou terme critique faux après relance ;
- diminution DEV puis holdout des copies de contexte/répétitions ;
- aucune insertion fausse de glossaire et meilleure exactitude sur les opportunités réelles ;
- aucune régression COMET holdout ; chrF++ reste secondaire, avec bootstrap apparié ;
- temps total, pic mémoire, taux de relance et temps par minute vidéo consignés ;
- diagnostic automatique séparé sur noms propres, pronoms/déixis, ellipses et cohérence lexicale.

Avec seulement deux vidéos, une promotion peut être validée pour ce corpus et ce workflow, pas comme preuve de perfection générale. Les références humaines peuvent aussi préférer une reformulation différente : COMET/chrF++ et des portes automatiques réduisent le risque, mais ne garantissent pas une traduction « parfaite ».

## Risques à éviter

- accepter toute la sortie quand la structure attendue manque ;
- traduire les fragments SpeakerKit comme des phrases autonomes ;
- mettre le contexte voisin dans le champ officiel `text` puis espérer qu'il ne sera pas traduit ;
- ajouter tous les termes du catalogue au prompt ;
- présenter plusieurs aliases comme plusieurs cibles d'entraînement ;
- corriger le sens avec des substitutions regex silencieuses ;
- utiliser COMETKiwi/XCOMET dans un produit sans résoudre leur licence ;
- lancer une seconde passe TranslateGemma sur tous les segments : coût doublé, preuve faible et risque de dégradation.

## Sources primaires

- Google, [TranslateGemma 12B IT — model card](https://huggingface.co/google/translategemma-12b-it).
- Google, [TranslateGemma Technical Report](https://arxiv.org/pdf/2601.09012).
- Voita et al., [When a Good Translation is Wrong in Context: Context-Aware Machine Translation Improves on Deixis, Ellipsis, and Lexical Cohesion](https://aclanthology.org/P19-1116/), ACL 2019.
- IWSLT 2026, [Sentence-aware long-context subtitling pipeline](https://aclanthology.org/2026.iwslt-1.7/).
- Vernikos et al., [Context-Aware Quality Estimation for Human Translation](https://arxiv.org/pdf/2403.08314), 2024.
- Google, [MetricX-24 Hybrid Large v2p6 — model card](https://huggingface.co/google/metricx-24-hybrid-large-v2p6-bfloat16).
- Unbabel, [COMET — dépôt officiel](https://github.com/Unbabel/COMET), [COMETKiwi](https://huggingface.co/Unbabel/wmt22-cometkiwi-da), [XCOMET-XL](https://huggingface.co/Unbabel/XCOMET-XL).
- Feng et al., [TEaR: Improving LLM-based Machine Translation with Systematic Self-Refinement](https://aclanthology.org/2025.findings-naacl.218/), NAACL 2025.
