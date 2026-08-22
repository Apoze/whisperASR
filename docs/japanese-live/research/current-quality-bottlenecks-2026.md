# Goulots d’étranglement actuels du workflow haute qualité

État analysé le 22 août 2026. Ce document conserve le diagnostic global du
pipeline local japonais vers anglais, les limites mesurées et les priorités
d’amélioration. Il ne constitue pas encore une spécification d’implémentation.

## Résumé

Les principaux freins ne sont pas tous au même endroit :

1. la qualité ASR japonaise varie fortement selon le domaine ;
2. la diarisation et la parole superposée restent faibles sur les contenus à
   nombreux interlocuteurs ;
3. le résultat n’est pas encore assez révisable sans relancer le job complet ;
4. le contexte de traduction et les informations du projet sont insuffisamment
   exploités ;
5. le corpus de validation est trop petit pour généraliser les décisions ;
6. TranslateGemma 12B domine très largement le temps de traitement.

Le VAD n’est pas le premier problème démontré sur les deux vidéos de référence.
Le meilleur gain attendu vient du trio **meilleur ASR, révision ciblée et
contexte projet correctement exploité**.

## Pipeline actuel

Le mode Haute qualité suit principalement ce chemin :

1. décodage et normalisation de l’audio en mono 16 kHz ;
2. transcription japonaise avec Qwen3 ASR ;
3. alignement temporel avec Qwen3 Forced Aligner ;
4. création d’unités sémantiques ;
5. analyse optionnelle des locuteurs avec SpeakerKit ;
6. sélection du glossaire ;
7. traduction locale cue par cue avec TranslateGemma 12B par défaut, ou 4B en
   bêta ;
8. validation déterministe et nouvelle tentative des unités rejetées ;
9. réorganisation optionnelle des sous-titres lisibles ;
10. génération des transcrits et exports SRT/VTT.

Les modèles lourds sont exécutés successivement. Cette politique protège la
mémoire du Mac et n’est pas un défaut du workflow.

## Goulots d’étranglement mesurés

| Priorité | Problème | Observation actuelle |
|---|---|---|
| 1 | Robustesse ASR | CER `79,48 %` sur la vidéo DEV difficile contre `25,91 %` sur le holdout final. Les noms, nombres, interjections et formulations expressives sont fragiles. |
| 2 | Locuteurs et overlap | Sur DEV, `13` locuteurs de référence contre `6` détectés, DER `105,47 %`, JER `85,92 %`, overlap F1 `8,6 %`. |
| 3 | Révision du résultat | Pas d’édition complète JA/EN ni de relance ASR ou traduction limitée à une cue ou une scène. |
| 4 | Contexte de traduction | Contexte court fondé sur les paires précédemment acceptées, sans compréhension globale de la scène ni identité confirmée systématique. |
| 5 | Lisibilité | Le reflow réduit les cues trop longues, mais ne réduit pas le nombre de cues dépassant le budget de caractères par seconde. |
| 6 | Temps | Sur les validations 12B intégrées, la traduction consomme environ `86–87 %` du temps total. |
| 7 | Validation scientifique | Les principales décisions reposent encore sur seulement deux vidéos de référence. |

## 1. ASR japonais

L’ASR est le premier goulot de qualité sémantique observé. Une traduction ne
peut pas restaurer de manière fiable une information absente ou incorrecte
dans le japonais reconnu. Les erreurs réelles incluent notamment :

- noms propres déformés ;
- nombres remplacés ou perdus ;
- tours très courts absorbés dans le contexte voisin ;
- omissions de termes importants ;
- longues hypothèses sans rapport avec une courte interjection de référence.

La différence importante entre DEV et holdout montre surtout un problème de
robustesse au domaine : voix expressives, jeu, bruit, musique et nombreuses
personnes sont nettement plus difficiles qu’une conversation plus propre.

### Multi-ASR déjà essayé

- Qwen puis Parakeet ciblé : 26 segments suspects traités, aucune hypothèse
  Parakeet retenue par le sélecteur final ; certaines éditions semblaient
  meilleures mais des informations critiques ont été perdues.
- WhisperKit ciblé : 13 segments ciblés, 10 hypothèses complètes, aucune
  sélection ; la meilleure projection rétrospective donnait 2 améliorations
  pour 3 dégradations.
- Les anciennes combinaisons globales de transcrits ont dégradé la traduction
  anglaise et augmenté les hallucinations.

La faiblesse actuelle n’est donc pas l’absence d’un troisième transcript,
mais l’absence d’un arbitre fiable capable d’utiliser l’audio et des confiances
calibrées. Donner plusieurs textes bruts à TranslateGemma ne lui permet pas de
savoir lequel correspond réellement à l’audio.

### Direction recommandée

- ne pas répéter les mêmes configurations Qwen, Parakeet et WhisperKit ;
- tester une famille ASR japonaise réellement différente et utilisable
  légalement dans l’application, ou une adaptation au domaine ;
- conserver les preuves acoustiques, timings et confiances propres à chaque
  moteur ;
- ne réactiver le multi-ASR qu’avec un sélecteur audio-conditionné et calibré
  sur un corpus plus large ;
- ajouter un diagnostic léger du signal : saturation, bruit, musique et
  différence réelle entre canaux.

## 2. VAD et découpage audio

Le diagnostic Qwen a compté `78/206` pertes proches des frontières, avec une
concentration de `1,10×`. Les portes prévues exigeaient au moins `60 %` des
pertes et une concentration de `1,5×`. Le remplacement du découpage par
FireRed était donc inéligible.

Les essais Live avec FireRed et Silero n’ont pas montré de remplacement
clairement supérieur sans perte de mora ou dégradation de frontière. Le VAD
reste utile pour le Live et certains futurs contenus bruités, mais il n’est pas
la priorité pour améliorer la qualité hors ligne actuelle.

L’application normalise aussi les sources en mono. Un traitement dépendant des
canaux pourrait aider lorsque les canaux sont réellement indépendants, mais les
deux vidéos actuelles ont des canaux presque identiques. Il ne faut donc pas
choisir arbitrairement le canal gauche ou droit ; il faut d’abord mesurer leur
indépendance.

## 3. Locuteurs, personnages et parole superposée

SpeakerKit reste insuffisant pour découvrir automatiquement de nombreuses voix
et attribuer correctement toute la parole. Les réglages de précision, nombre
exact et seuils de clustering ont déjà été explorés. Certains améliorent DEV,
mais les gains ne se reproduisent pas clairement sur le holdout.

Les alternatives testées n’ont pas résolu le problème :

- PixIT a techniquement fonctionné, mais a perdu davantage de tours qu’il n’en
  a récupéré ;
- FluidAudio a regroupé les voix de manière excessive ;
- plusieurs approches EEND/Sortformer ont inventé des changements ou de
  l’overlap ;
- MossFormer2 n’a pas produit de verdict qualité exploitable à cause de la
  pression mémoire.

Les améliorations pratiques déjà fiables sont :

- la réanalyse SpeakerKit seule en environ `17,8 s` sans refaire ASR et
  traduction ;
- l’éditeur de locuteurs ;
- les profils vocaux limités au projet, avec abstention en cas de doute.

Les profils actuels proposent surtout une identité après diarisation. Ils
n’améliorent pas encore la séparation, le nombre de clusters ou l’overlap.

### Direction recommandée

- conserver l’édition et la réanalyse comme filet de sécurité fiable ;
- utiliser progressivement les profils vocaux confirmés comme ancres
  conservatrices, jamais comme attribution forcée ;
- tester une nouvelle famille de diarisation plutôt que retoucher encore les
  mêmes seuils SpeakerKit ;
- transmettre à la traduction uniquement les identités confirmées ;
- laisser « interlocuteur inconnu » lorsque le score n’est pas suffisant.

## 4. Traduction et second passage de contrôle

Il n’existe pas aujourd’hui de second agent général qui relit toute la
traduction anglaise.

Le workflow contient bien une seconde passe, mais elle est limitée : des
contrôles déterministes recherchent les sorties vides, le japonais résiduel,
les répétitions, troncatures, instructions parasites, longueurs pathologiques
et violations critiques du glossaire. Les seules unités rejetées sont ensuite
retraduite par le même TranslateGemma.

Ce mécanisme détecte une sortie manifestement cassée. Il ne détecte pas
fiablement une phrase anglaise fluide mais sémantiquement fausse, un mauvais
pronom, une incohérence de scène ou une traduction naturelle qui a perdu une
information japonaise.

MetricX a été testé comme arbitre entre candidats sur deux unités DEV
suspectes. Il n’a effectué aucun remplacement, n’a pas ouvert le holdout et ne
réécrivait pas le texte. L’auto-révision complète de TranslateGemma n’a pas été
validée dans le produit.

### Expérience recommandée

Tester un réviseur **bilingue et sélectif** :

1. détecter des cues réellement suspectes ;
2. fournir le japonais, le brouillon anglais, le voisinage, le glossaire et les
   identités confirmées ;
3. demander de conserver ou corriger le brouillon ;
4. repasser les contrôles d’intégrité et comparer à une référence humaine.

Un second passage aveugle sur toute la vidéo n’est pas recommandé par défaut.
Il pourrait rendre une erreur ASR plus convaincante et presque doubler la
partie la plus lente du job. Une passe purement anglophone peut améliorer le
style, mais ne peut pas garantir la fidélité au japonais ; elle ne doit venir
qu’après verrouillage du sens.

## 5. Contexte et glossaire du projet

Le contexte conversationnel actuel conserve un petit nombre de paires JA/EN
précédemment acceptées et se réinitialise notamment après une pause. Son essai
a donné des gains mélangés : petites améliorations sur certaines métriques,
régressions sur d’autres tranches, et temps de traduction plus que doublé.

Un problème concret subsiste dans le câblage du projet :

- `HighQualityProjectScope` conserve les métadonnées et la sélection de
  glossaire ;
- `HighQualityGlossarySelector.select` accepte déjà `projectMetadata` et
  `preferredTermIDs` ;
- le job courant appelle le sélecteur uniquement avec la source et les tours.

Les préférences enregistrées dans le projet ne guident donc pas réellement la
sélection du glossaire pendant ce job. C’est une lacune fonctionnelle à traiter
avant de construire une nouvelle couche complexe de correction lexicale.

La prochaine évolution du contexte devrait utiliser les scènes ou sujets,
éventuellement un court regard vers les cues japonaises suivantes, le glossaire
du projet et les identités confirmées. Les labels SpeakerKit bruts ne doivent
pas influencer la traduction tant que leur fiabilité reste insuffisante.

## 6. Workflow de révision

Le plus grand manque fonctionnel est l’absence d’un résultat révisable par
étapes. L’utilisateur ne peut pas encore facilement :

- écouter en boucle une cue suspecte et voir les preuves associées ;
- corriger le japonais reconnu ;
- modifier la traduction anglaise ;
- comparer plusieurs hypothèses ASR ;
- relancer l’ASR sur une plage précise ;
- retraduire seulement une cue ou une scène ;
- retraduire après avoir confirmé ou corrigé un personnage ;
- régénérer tous les exports sans réexécuter les modèles inutiles.

Ce workflow apporterait un gain immédiat et fiable : une erreur locale ne
nécessiterait plus un nouveau traitement complet de 15 à 25 minutes. Il
permettrait également de collecter les corrections confirmées nécessaires pour
évaluer ou améliorer de futurs modèles.

L’interface devrait rendre visibles les avertissements utiles : faible
confiance ASR, alignement incomplet, parole non attribuée, traduction suspecte
et sous-titre trop rapide.

## 7. Sous-titres anglais

Le reflow bêta améliore les cues trop longues et celles dépassant sept secondes
sans changer les mots ni les timestamps source. Cette contrainte garantit
l’intégrité, mais explique pourquoi le nombre de cues au-dessus du budget de
caractères par seconde reste inchangé.

La suite doit distinguer deux opérations :

- redistribuer prudemment les limites temporelles en empruntant de l’espace aux
  pauses voisines ou en fusionnant certaines cues ;
- demander une traduction plus concise uniquement pour les cues encore
  impossibles à lire, avec contrôle de conservation du sens.

## 8. Informations vidéo aujourd’hui perdues

Pour une vidéo, l’application ne traite que l’audio. Elle n’exploite pas les
images, textes affichés, noms à l’écran, sous-titres incrustés ou changements de
scène. Sur des contenus VTuber, anime ou jeu, ces indices pourraient expliquer
une partie de l’écart avec un système multimodal.

Une expérimentation locale avec Vision/OCR pourrait fournir :

- noms et termes visibles au glossaire ;
- limites de scène pour le contexte ;
- indices sur un changement de sujet.

Ces indices doivent rester auditables et ne jamais remplacer silencieusement
une hypothèse ASR. La détection visuelle du locuteur actif n’est pas une
solution générale pour des avatars ou des interfaces de jeu.

## 9. Performance et architecture

Sur les validations intégrées 12B :

| Split | Total | ASR | Alignement | SpeakerKit | Traduction |
|---|---:|---:|---:|---:|---:|
| DEV | `16 min 46 s` | `1 min 24 s` | `33 s` | `19 s` | `14 min 28 s` |
| Holdout | `14 min 28 s` | `1 min 11 s` | `21 s` | `15 s` | `12 min 39 s` |

La traduction 12B est donc le goulot de performance. Le 4B est plus rapide et
plus léger, mais a produit plusieurs sorties invalides et une qualité globale
inférieure ; il doit rester une option bêta choisie par l’utilisateur.

`HighQualityJob.swift` concentre beaucoup de responsabilités, mais sa taille
n’est pas en elle-même une cause directe de mauvaise traduction. Une grande
refactorisation abstraite ne serait pas prioritaire. Une séparation devient
utile uniquement pour persister le résultat de chaque étape et permettre les
relances partielles décrites plus haut.

## 10. Limite du corpus de validation

Deux vidéos ne suffisent pas pour choisir durablement des modèles ou calibrer
un sélecteur multi-ASR. Les résultats DEV et holdout se contredisent déjà sur
plusieurs réglages SpeakerKit, ASR et contexte.

Le benchmark devrait couvrir au minimum :

- anime, VTuber, jeu, entretien propre et conversation bruitée ;
- musique, cris et parole superposée ;
- 1, 2, 3, 5, 10 personnes ou plus ;
- voix récurrentes entre plusieurs vidéos d’un même projet ;
- noms propres, nombres, termes critiques et courtes interjections ;
- références japonaises, anglaises, temporelles et de locuteurs vérifiées.

Cette extension est le principal préalable pour décider honnêtement si une
nouvelle solution améliore l’application sans surapprentissage sur les deux
vidéos actuelles.

## Ordre recommandé

### Priorité immédiate

1. étendre et annoter le benchmark ;
2. ajouter l’édition JA/EN et les relances ciblées ;
3. brancher réellement les métadonnées et glossaires des projets ;
4. afficher les cues nécessitant une vérification.

### Qualité des modèles

5. qualifier un nouvel ASR japonais ou une adaptation au domaine ;
6. ne rouvrir le multi-ASR qu’avec un arbitre audio-conditionné ;
7. évaluer une nouvelle famille de diarisation et l’ancrage conservateur par
   profils vocaux ;
8. tester le réviseur bilingue sélectif.

### Finition

9. améliorer le contexte par scène et les indices vidéo/OCR ;
10. résoudre les sous-titres trop rapides par timing puis traduction concise
    ciblée.

## Ce qu’il ne faut pas prioriser

- remplacer le VAD hors ligne sans nouvelle preuve de pertes aux frontières ;
- recommencer les mêmes essais Parakeet ou WhisperKit avec les mêmes réglages ;
- donner plusieurs transcrits bruts à TranslateGemma et lui demander de deviner
  lequel est correct ;
- ajouter une seconde traduction complète par défaut ;
- retoucher encore les seuils SpeakerKit déjà explorés ;
- lancer une grande refactorisation sans besoin lié aux relances partielles.

## Rapports sources

- [Validation finale #121](../experiments/evidence/issue-121/report.md)
- [Validation intégrée E31](../experiments/E31-integrated-final-validation.md)
- [Diagnostic des erreurs Qwen E23](../experiments/E23-qwen-error-diagnostic.md)
- [Qwen vers Parakeet adaptatif E32](../experiments/E32-adaptive-qwen-parakeet-117.md)
- [WhisperKit ciblé E33](../experiments/E33-targeted-whisperkit-118.md)
- [TranslateGemma 4B contre 12B E21](../experiments/E21-translategemma-4b-vs-12b.md)
- [Contexte conversationnel E14](../experiments/E14-previous-accepted-context.md)
- [MetricX E15](../experiments/E15-metricx-reranking.md)
- [Sous-titres lisibles E32](../experiments/E32-readable-cues.md)
- [Recherche multi-ASR v2](multi-asr-v2-calibrated-selection-2026.md)
- [Recherche diarisation](diarization-frontier-2026.md)
