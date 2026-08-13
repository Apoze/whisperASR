# Séparer localement les voix réellement superposées

Recherche du 11 août 2026 pour le ticket « Déterminer si la séparation locale des voix superposées peut améliorer le résultat ». Aucune inférence de modèle n'a été lancée.

## Décision

**Oui, une vraie séparation de sources mérite un prototype local, mais seulement sur les fenêtres d'overlap et avant toute attribution de locuteur.** La shortlist est :

1. **PixIT / ToTaToNet (`pyannote/speech-separation-ami-1.0`)** en premier : il produit conjointement activité des locuteurs et formes d'onde distinctes, traite du mono 16 kHz et jusqu'à trois voix par fenêtre. C'est le candidat le plus proche du besoin « transcrire chaque personne une fois ».
2. **MossFormer2_SS_16K** comme comparateur aveugle à deux voix : installation et inférence documentées, poids de 670 Mo, modèle unifié évalué sur parole propre, bruitée et audiovisuelle.
3. **SepFormer-WHAMR16K** uniquement comme petit témoin robuste bruit/réverbération : deux voix fixes, domaine anglais synthétique, environ 113 Mo de poids d'inférence.

Ne rien intégrer au produit avant un gain de texte japonais sur le développement puis sur le holdout. Aucun des trois projets ne fournit une voie Core ML ou MLX officielle : leurs voies documentées sont PyTorch CPU/CUDA. PyTorch sait utiliser le GPU Apple via MPS, mais la compatibilité opérateur et la vitesse de chaque candidat restent à mesurer sur ce Mac ([documentation MPS PyTorch](https://docs.pytorch.org/docs/stable/notes/mps.html), [documentation Apple](https://developer.apple.com/metal/pytorch/)).

## Ce que l'application fait aujourd'hui

| Étape | Question | État actuel |
|---|---|---|
| Détection d'overlap | « Y a-t-il au moins deux voix maintenant ? » | Déduite des spans SpeakerKit, très imprécise sur ce corpus. |
| Diarisation | « Qui parle quand ? » | SpeakerKit/FluidAudio produisent des spans et labels anonymes. |
| Séparation | « Quelle forme d'onde appartient à chaque voix ? » | **Absente.** |
| Transcription | « Que dit cette forme d'onde ? » | Qwen JA transcrit le mélange mono une seule fois. |

L'ancien défaut n'était donc pas une mauvaise séparation : E06 attachait le **même texte du mélange** à plusieurs spans qui se chevauchaient (379 unités dupliquées en développement, 557 sur holdout). [E07](../experiments/E07-principal-speaker-attribution.md) a ramené ce nombre à zéro en gardant un seul locuteur principal par unité. Le futur prototype doit au contraire créer des audios réellement différents, puis exécuter l'ASR indépendamment sur chacun.

Les essais déjà faits ne répondent pas à cette question :

- [E18](../experiments/E18-fluid-audio-offline.md) change seulement le moteur de diarisation ; FluidAudio n'a séparé aucune voix et a été nettement pire que SpeakerKit.
- [E22](../experiments/E22-standard-offline-validation.md) conserve zéro duplication de transcript, mais l'overlap reste très mauvais : développement, 25,50 s de référence contre 161,53 s prédites, dont 17,46 s manquées et 153,48 s inventées ; holdout, 1,77 s contre 92,77 s, dont 1,66 s manquées et 92,66 s inventées.
- [E05](../experiments/E05-local-translator-bakeoff.md) compare des traducteurs sur des requêtes figées ; il n'apporte aucune preuve sur la séparation acoustique.

Les annotations locales indiquent 24,78 s à deux voix et 1,00 s à quatre voix sur le développement ; le holdout contient 1,77 s à deux voix. PixIT plafonne donc encore à trois voix et les séparateurs à deux sorties ne peuvent pas résoudre la seconde à quatre voix.

## Candidats réellement testables

| Candidat | Ce qu'il produit | Limites pertinentes | Licence, poids, maturité Apple |
|---|---|---|---|
| **PixIT / ToTaToNet** | Diarisation + sources séparées, mono 16 kHz, fenêtres de 5 s, jusqu'à 3 voix ; la pipeline longue durée recolle les sources avec des embeddings. | Entraîné sur réunions AMI à micro distant, pas sur japonais/VTuber/musique ; modèle et pipeline soumis à acceptation Hugging Face ; plafond de 3 voix. | Modèle/pipeline MIT ; modèle ToTaToNet 1,28 Go, plus les dépendances et l'embedder ; PyTorch `pyannote.audio==3.3.2`, GPU documenté uniquement avec CUDA. [Modèle](https://huggingface.co/pyannote/separation-ami-1.0), [pipeline](https://huggingface.co/pyannote/speech-separation-ami-1.0), [code et papier](https://github.com/joonaskalda/PixIT). |
| **MossFormer2_SS_16K** | Deux formes d'onde depuis un mélange monaural 16 kHz. | Nombre fixé à 2 ; les deux sorties existent même avec une seule voix ; entraînement partiellement privé, donc domaine exact non auditable ; aucune identité stable entre fenêtres. | Modèle et dépôt affichés Apache-2.0 ; poids 670 Mo ; PyTorch, `pip install clearvoice`, aucune voie MPS/Core ML déclarée. Le dépôt officiel montre explicitement `num_spks = 2`. [Documentation](https://github.com/modelscope/ClearerVoice-Studio/blob/main/clearvoice/README.md), [modèle](https://huggingface.co/alibabasglab/MossFormer2_SS_16K), [fichiers](https://huggingface.co/alibabasglab/MossFormer2_SS_16K/tree/main). |
| **SepFormer-WHAMR16K** | Deux sources depuis un mélange mono 16 kHz, avec bruit et réverbération. | Deux voix fixes ; entraîné sur WHAMR!, dérivé de parole anglaise WSJ0 ; la carte décline toute garantie hors domaine. | Apache-2.0 ; environ 113 Mo de poids d'inférence (319 Mo si les états d'entraînement du dépôt sont comptés) ; API SpeechBrain prête, accélération officielle documentée avec CUDA seulement. [Carte et usage](https://huggingface.co/speechbrain/sepformer-whamr16k), [fichiers](https://huggingface.co/speechbrain/sepformer-whamr16k/tree/main). |

Les deux vidéos sources sont stéréo 48 kHz, mais pas des prises indépendantes par locuteur : l'audit `ffprobe` puis `L-R` donne un RMS de -45,57/-52,96 dB contre -25,94/-31,49 dB pour le signal médian. Les canaux sont donc très proches et le corpus normalisé est déjà mono 16 kHz. Un simple split gauche/droite ou ICA à deux canaux n'est pas une piste sérieuse ici.

## Pistes à ne pas benchmarker maintenant

- **Détection seule pyannote/segmentation-3.0** : elle sait détecter l'overlap, mais ne sépare rien. SpeakerKit testé ici est déjà un port Core ML du segmenter pyannote-v3, y compris en pleine précision ; rejouer la même famille ne répond pas au ticket ([modèle pyannote](https://huggingface.co/pyannote/segmentation-3.0), [poids SpeakerKit locaux](https://huggingface.co/argmaxinc/speakerkit-coreml/tree/main/speaker_segmenter/pyannote-v3)).
- **WeSep / SpEx+ et autres extractions guidées par embedding** : prometteurs lorsque l'on possède un extrait propre du locuteur cible, mais l'application ne connaît ni l'identité ni un enrollment fiable ; l'auto-enrollment dépendrait précisément de la diarisation aujourd'hui mauvaise. À reconsidérer seulement après une bonne attribution ([WeSep](https://github.com/wenet-e2e/wesep)).
- **EEND-SS et séparateurs à nombre inconnu** : la recherche couvre diarisation, comptage et séparation flexible, mais il n'existe pas ici de modèle préentraîné, packagé et vérifié sur Apple comparable aux trois candidats ci-dessus ; ce serait un projet de recherche/entraînement, pas un prototype minimal ([papier EEND-SS](https://arxiv.org/abs/2203.17068)).
- **Demucs, suppression de bruit ou séparation voix/musique** : utiles pour enlever accompagnement/bruit, pas pour reconstruire deux personnes qui parlent ensemble.
- **Indices audiovisuels** : `AV_MossFormer2_TSE_16K` exige un visage et des lèvres synchronisées pour chaque cible ([modèle](https://huggingface.co/alibabasglab/AV_MossFormer2_TSE_16K), [configuration](https://huggingface.co/spaces/alibabasglab/ClearVoice/blob/305b89d6890e8b42c962678d75b7be97a4d000a7/config/inference/AV_MossFormer2_TSE_16K.yaml)). Les vidéos locales montrent surtout jeu/concert, avatars VTuber et petites icônes statiques : les interlocuteurs ne possèdent pas tous une bouche réelle, visible et synchronisée. Cette voie n'est pas généralisable au produit.

## Expérience minimale proposée

1. **Développement seulement, overlap oracle** : découper les 25,50 s annotées avec 0,5 s de marge et garder exactement les mêmes fenêtres pour tous les candidats. Cela isole la séparation du détecteur SpeakerKit défaillant.
2. Pour chaque fenêtre, conserver le mélange mono comme témoin, séparer avec un seul candidat, puis lancer **le même Qwen JA** sur le mélange et sur chaque source. Aucun label SpeakerKit ne doit être injecté avant l'ASR.
3. Conserver formes d'onde, hashes, transcripts bruts, temps, mémoire, pression système et erreurs. Traiter les fenêtres séquentiellement et décharger le séparateur avant Qwen afin de respecter la règle d'un seul modèle lourd.
4. Mesurer d'abord : caractères japonais de référence récupérés/perdus dans l'overlap, insertions, CER oracle par permutation des sorties vers les locuteurs, fenêtres vides, et durée/mémoire. Ne traduire avec le 12B figé que le meilleur candidat japonais pour vérifier l'effet final EN.
5. **Veto duplication** par fenêtre : normaliser les transcripts ; rejeter si deux sorties non vides ont une similarité d'édition ≥ 0,80, ou si chacune ressemble au transcript du mélange à ≥ 0,80. Rejeter aussi toute sortie qui ne contient que bruit/silence ou toute paire qui augmente les insertions sans récupérer de caractères de référence. La similarité et les seuils doivent être enregistrés, jamais cachés par une attribution arbitraire.
6. N'ouvrir le holdout qu'après un gain DEV concret : davantage de paroles distinctes récupérées, aucune duplication, aucune perte hors overlap, coût supportable. Sur holdout, utiliser les 1,77 s annotées sans retoucher le choix ni les seuils.
7. Seulement si l'oracle passe, tester séparément la détection réelle. Une détection qui conserve les faux positifs E22 ferait tourner un séparateur à deux voix sur plus de 90 à 150 secondes sans overlap et fabriquerait mécaniquement des sources parasites.

Le premier verdict attendu est donc très simple : **PixIT récupère-t-il au moins une réplique japonaise distincte que Qwen perd sur le mélange, sans recopier ce mélange dans plusieurs sorties ?** Si non, arrêter toute intégration de séparation. Si oui, comparer MossFormer2, puis décider dans un ticket distinct comment déclencher et recoller les sources.
