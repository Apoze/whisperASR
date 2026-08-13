# ASR japonais local — pistes encore non essayées

Recherche du ticket #84. Audit arrêté au commit `4ef7dcf421771de17a4bfe65fbf8e399d4391fa7`. Aucun modèle n'a été téléchargé ou exécuté et aucun code produit n'a été modifié.

## Conclusion

Il reste trois candidats qui justifient un vrai bake-off, dans cet ordre :

1. **Fun-ASR-Nano-2512 int8 via sherpa-onnx**, meilleur pari généraliste nouveau : japonais explicite, hotwords natifs, paquet local de 948 Mo et API Swift/macOS arm64.
2. **Qwen3-ASR 1.7B JA Anime/Galgame**, meilleur pari pour la diction expressive anime/game, mais **prototype seulement tant que la licence du jeu de données n'est pas clarifiée**.
3. **ReazonSpeech K2 v2 int8 via sherpa-onnx**, meilleur contrôle japonais léger et mature : 159 M paramètres, environ 164 Mo de poids int8 et timestamps caractères.

Deux recettes doivent être isolées des changements de moteur : **segmentation offline FireRed au lieu du découpage énergétique fixe** et **prétraitement voix/musique seulement sur les fenêtres réellement bruitées**. Le fine-tune Kotoba v2.1 est un secours de faible priorité, pas un premier choix.

## Ce que les preuves locales disent réellement

Les erreurs dominantes ne forment pas un seul problème « modèle ASR » :

| Famille d'erreur | Preuve locale | Cible correcte |
|---|---|---|
| Parole supprimée / sortie vide | Nemotron perd la fin ; Voxtral, Nemotron et `whispermlx` ajoutent des tours vides ; E22 perd notamment `リーサルだー！ドーーーン!!!` | rappel acoustique, segmentation, robustesse expressive |
| Substitutions lexicales et noms propres | Les hints Apple et Dictation n'ont restauré aucun terme exact ; F1 lexical 0 | moteur avec hotwords réels, puis correction déterministe |
| Frontières / contexte trop courts | Le job offline partage un découpage énergétique de 20 s avec repli dur à 19 s et déduplication littérale | comparer le segmenter, pas changer le modèle en même temps |
| Bruit, musique, cris, voix simultanées | Les deux vidéos contiennent jeu/musique et parole expressive ; aucun moteur ASR unique ne résout la superposition | séparation voix/accompagnement ciblée, puis ASR inchangé |
| Désaccord entre moteurs | L'oracle multi-ASR montre de la complémentarité, mais ROVER réel ajoute huit sorties vides et dégrade l'anglais | ne pas refaire un vote caractères aveugle |

Les deux fichiers de référence sont stéréo Opus, mais un contrôle local des 60 premières secondes montre des canaux presque identiques : RMS gauche/droite `-30,61/-30,60 dB` et `-31,76/-31,76 dB`; le signal de différence tombe à `-50,0` et `-64,2 dB`. **Séparer simplement gauche/droite n'est donc pas une piste sérieuse sur ce corpus.**

## Déjà essayé — ne pas répéter à configuration identique

| Moteur ou recette | Résultat local concret | Décision |
|---|---|---|
| whisper.cpp Large-v3-Turbo Metal | L03 CER 27,83 %, 0 vide, p95 1 158 ms, RSS 3,20 Go ; L05 contrôle CER 26,70 % | témoin utile, pas un nouveau candidat |
| `mlx-whisper` Turbo | L05 CER 47,06 %, p95 4,87 s | ne pas répéter |
| WhisperKit Large-v3 | E06 holdout CER 35,09 %, COMET 0,4839, 2 705 s | garder comme option existante ; ne pas prétendre que le runtime seul améliore l'ASR |
| WhisperLiveKit SimulStreaming / LocalAgreement | couverture, backlog, latence ou mémoire hors portes | ne pas rouvrir sans changement amont démontré |
| Kotoba-Whisper v2.0 Q5 | L05 CER 26,24 % contre 26,70 % au contrôle, gain trop faible | ne pas refaire v2.0/Q5 ; seule v2.1 est nouvelle |
| Qwen3-ASR 1.7B JA MLX 8-bit | L05 CER 27,06 %, RSS 6,63 Go ; E04 trace locale CER 25,96 % ; E06 meilleur pipeline holdout CER 27,93 % / COMET 0,5013 | baseline principale |
| Qwen officiel « streaming » | le backend officiel rejoue l'audio accumulé ; vLLM ne construit pas sur macOS arm64 | ne pas refaire ce faux streaming |
| Qwen pseudo-live 2 s | preview meilleure, mais gain p95 premier anglais 173 ms (< porte 200 ms), mémoire hors porte, final identique | ne pas promouvoir |
| Parakeet JA CoreML | E04 trace locale CER 22,29 % mais IC apparié croise zéro ; E06 holdout CER 63,76 % / COMET 0,4598 | option rapide existante, pas preuve de supériorité finale |
| Voxtral Q4/960 | L03 CER 31,25 %, 11 vides, p95 7 138 ms ; frontières et rotations déjà explorées | ne pas répéter |
| Nemotron 3.5 ASR Streaming 0.6B CoreML, 1120/560 ms | L03 CER 34,33/36,47 %, 21/19 vides et fin perdue | ne pas répéter ; le nouveau paquet sherpa est le même modèle |
| `whispermlx` + Silero VAD | L05 CER 32,39 %, 72,5 % seulement du PCM atteint le décodeur, vides élevés | ne pas répéter cette intégration ; cela ne rejette pas FireRed comme segmenter offline isolé |
| Apple Speech hints, canonical+kana | F1 lexical 0, CER seulement −0,97 à −1,29 point | ne pas miser sur davantage de chaînes Apple |
| Apple Dictation + contexte / modèle personnalisé | F1 lexical 0, CER 74,60–79,94 %, couverture 55,77–63,16 % | abandonner |
| Médoïde + ROVER strict 2/3 Qwen/Parakeet/WhisperKit | DEV CER 86,83 → 79,64 %, mais IC inférieur −2,04 %, +8 vides, chrF++ 45,44 → 42,08, hallucinations 11 → 16, +527 s | rejeté ; ne pas refaire un vote caractères |
| Cohere/Granite prototypes | provenance ou qualité locale insuffisante, hallucinations/omissions | ne pas rouvrir inchangé |

Preuves suivies : [L03](../lots/L03-bakeoff-asr.md), [L05](../lots/L05-bakeoff-japonais.md), [E06](../experiments/E06-offline-high-quality-acceptance.md), [E22](../experiments/E22-standard-offline-validation.md), [recettes natives](../lots/L07A-recettes-natives.md), [frontières japonaises](../lots/L08C-frontieres-japonaises.md) et [état de l'art local antérieur](../research-live-ja-en-2026.md). Les résultats Apple E05/E21 et multi-ASR E20 ont aussi été vérifiés dans leur historique Git ; ils ne sont pas présents dans ce commit de base.

## Candidats réellement nouveaux

Les estimations mémoire ci-dessous sont des **budgets de préflight**, pas des mesures sur ce Mac.

| Priorité | Candidat | Japonais / licence | Chemin Apple Silicon local | Taille et budget prévisible | Maturité / erreur ciblée | Décision |
|---|---|---|---|---|---|---|
| P1 | Fun-ASR-Nano-2512 int8 | japonais explicite, Apache-2.0, 800 M | sherpa-onnx fournit macOS arm64, C/C++ et Swift ; CPU ONNX local | paquet 948 Mo ; réserver 2–4 Go RSS avant mesure | modèle officiel fin 2025, hotwords et accents ; aucune métrique japonaise officielle publiée | bake-off DEV prioritaire contre Qwen, mêmes fenêtres, hotwords **off** d'abord |
| P1 conditionnelle | Qwen3-ASR 1.7B JA Anime/Galgame | japonais ; base Apache-2.0 mais carte `license: other` et droits du dataset à vérifier | conversion MLX 8-bit à reproduire ou runtime C++/Metal communautaire ; pas de paquet natif officiel | BF16 2 B ; 8-bit attendu proche du Qwen actuel, donc plafond initial 8 Go RSS | carte : CER global 14,37 → 12,85 %, anime 10,91 → 7,99 %, Nekopara 28,03 → 22,76 %, mais JSUT/CV régressent | prototype DEV domaine seulement après feu vert licence ; jamais distribuer avant clarification |
| P2 | ReazonSpeech K2 v2 Zipformer int8 | japonais seul, Apache-2.0, 159,34 M, entraîné sur 35 000 h | paquet sherpa-onnx natif macOS/Swift, CPU | encodeur 148 Mo + décodeur/joiner ~5,4 Mo ; budget 1 Go RSS | mature, clips ≤ ~30 s, timestamps caractères ; RTF exemple officiel 0,054 | excellent contrôle japonais léger ; tester avant des modèles multilingues génériques |
| P3 | Kotoba-Whisper v2.1 | japonais, Apache-2.0 | runtime officiel Transformers ; conversion Core ML/whisper.cpp à qualifier | dépôt de poids ~3 Go ; budget similaire ou supérieur à Kotoba v2.0 | CER normalisé presque identique à v2.0 (9,3/8,4/11,3 contre 9,2/8,4/11,6), gain surtout ponctuation brute | seulement si les trois P1/P2 échouent |
| Surveiller | nouveau Reazon Zipformer base 2025 | japonais, Apache-2.0, 98,2 M | Transformers avec code custom ; pas d'export sherpa natif validé | poids ~393 Mo ; budget inconnu | carte officielle : bon short-form, mais long-form échoue sans VAD et reste nettement moins bon avec VAD | attendre un export ONNX officiel mature |
| Écarter maintenant | SenseVoiceSmall int8 | japonais, licence modèle spécifique | sherpa-onnx Swift/macOS existe | ~234 Mo | aucune preuve officielle convaincante en japonais face aux spécialistes, licence moins simple | pas prioritaire |
| Écarter maintenant | Omnilingual CTC 300M int8 | japonais parmi 1 600+ langues, Apache-2.0 | sherpa-onnx Swift/macOS | 348 Mo, ~2 Go VRAM annoncés pour le CTC 300M sur A100 | pas de résultat japonais ciblé ; largeur linguistique sans avantage local identifié | ne pas dépenser un run avant Reazon/Fun-ASR |
| Écarter | GLM-ASR-Nano | carte officielle anglais/chinois seulement | Transformers | 1,5 B | pas de japonais déclaré | hors besoin |

Sources primaires : [Fun-ASR Nano — carte officielle](https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512), [paquets Fun-ASR sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/funasr-nano/pretrained.html), [sherpa-onnx et plateformes/API](https://github.com/k2-fsa/sherpa-onnx), [ReazonSpeech K2 v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2), [paquet Reazon sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/zipformer-transducer-models.html#sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01-japanese), [fine-tune Qwen anime/game](https://huggingface.co/jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame), [Kotoba v2.1 et évaluations](https://github.com/kotoba-tech/kotoba-whisper), [Omnilingual CTC 300M](https://huggingface.co/facebook/omniASR-CTC-300M), [SenseVoice officiel](https://github.com/FunAudioLLM/SenseVoice).

## Recettes nouvelles à tester séparément

1. **Diagnostic frontières avant nouveau modèle.** À partir des artefacts Qwen existants, classer substitutions/insertions/suppressions selon leur distance aux frontières 20 s. Si les suppressions se concentrent à ±1 s, tester ensuite une seule variable : segmenter offline FireRed à PCM identique, Qwen inchangé. Le Silero défectueux de `whispermlx` ne doit pas servir de contrôle.
2. **Hotwords natifs, après le bake-off sans hints.** Si Fun-ASR ou Reazon passe le contrôle sans glossaire, comparer `off` à un petit glossaire issu uniquement des métadonnées DEV, avec score fixe et rapport faux positifs. Cela cible les noms propres ; Apple hints a échoué, mais sherpa expose un biaisage de décodage transducer et Fun-ASR accepte des hotwords.
3. **Voix contre musique, uniquement sur fenêtres difficiles.** sherpa-onnx expose Spleeter/UVR pour séparer `vocals` et accompagnement et GTCRN/DPDFNet pour débruiter. Tester d'abord Qwen inchangé sur un sous-ensemble DEV pré-déclaré avec musique/bruit, puis vérifier que le traitement n'efface pas cris, rires ou parole douce. Ne jamais l'appliquer par défaut sans gain holdout. Sources : [séparation](https://k2-fsa.github.io/sherpa/onnx/c-api/html/source_separation.html) et [débruitage](https://k2-fsa.github.io/sherpa/onnx/c-api/html/speech_enhancement.html).
4. **Ne pas séparer les canaux stéréo de ces deux vidéos.** Ils sont quasi dupliqués ; ce n'est pas une séparation de locuteurs gratuite.

## Protocole minimal recommandé

- Phase A, DEV seulement : Qwen figé contre Fun-ASR int8 puis Reazon int8, mêmes PCM/fenêtres, sans hotwords ni prétraitement. Exiger artefacts par fenêtre, CER apparié, suppressions, sorties vides, parole finale, temps transcription, RSS/swap et hashes.
- Phase B conditionnelle : fine-tune Qwen anime/game après validation licence, mêmes portes et analyse séparée anime/gaming/conversation.
- Phase C : une seule recette à la fois, dans cet ordre : FireRed offline, hotwords, voix/musique ciblée.
- Ouvrir le holdout vidéo/chaîne une seule fois pour le meilleur candidat DEV pré-déclaré. Promouvoir uniquement si le gain CER est robuste, sans hausse des vides/omissions, puis si la traduction et les sous-titres anglais ne régressent pas.
- Ne pas relancer Whisper, Kotoba v2.0, Nemotron, Voxtral, Apple hints/Dictation ou le ROVER strict : leurs échecs sont déjà expliqués et leurs artefacts existent.
