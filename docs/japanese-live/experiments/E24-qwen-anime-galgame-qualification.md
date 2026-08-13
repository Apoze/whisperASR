# E24 — Qualification Qwen Anime/Galgame (#90)

Date : 2026-08-12. Qualification documentaire uniquement : aucun poids téléchargé, aucun runtime construit, aucun smoke ni benchmark exécuté. E22/E23 restent figés et le holdout fermé.

## Verdict

**NO-GO — non éligible pour l’intégration/distribution produit.**

Le candidat public correspondant à « Qwen Anime/Galgame » dans #90 est `jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame` ; l’issue ne donne toutefois pas d’identifiant de dépôt explicite. Le checkpoint est marqué `License: other`. Sa carte dit qu’il dérive de `Qwen/Qwen3-ASR-1.7B`, qu’il a été entraîné sur `litagin/Galgame_Speech_ASR_16kHz`, et qu’elle n’accorde aucun droit au-delà des licences du modèle amont et du dataset ([checkpoint épinglé](https://huggingface.co/jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame/blob/6db0efecd56d4a7e0003190a6bd4cac056d0f390/README.md#license-and-use)).

La carte primaire du dataset impose GPL-3.0 **et** une condition additionnelle : usage commercial interdit pour le dataset comme pour tout modèle entraîné dessus ; un usage commercial exige l’autorisation de tous les fournisseurs, et les modèles entraînés doivent être publiés en open source ([dataset épinglé, règles de licence](https://huggingface.co/datasets/litagin/Galgame_Speech_ASR_16kHz/blob/3fb86654222b3f0af0f7c332ae6a0ef9752a9451/README.md#L120-L131)). Elle précise aussi que les audios et transcriptions proviennent de jeux commerciaux via un dataset dérivé ([provenance](https://huggingface.co/datasets/litagin/Galgame_Speech_ASR_16kHz/blob/3fb86654222b3f0af0f7c332ae6a0ef9752a9451/README.md#L132-L160)).

Cette restriction est incompatible avec une dépendance produit distribuable sans autorisations externes. Le conflit entre l’étiquette GPL-3.0 et la restriction additionnelle rend en plus les conditions ambiguës ; chacun de ces deux constats échoue la porte absolue de #90.

## Révision, poids et runtime constatés sans téléchargement

- Checkpoint source épinglable : révision `6db0efecd56d4a7e0003190a6bd4cac056d0f390`, `model.safetensors` BF16 de 4 076 191 640 octets, SHA-256 `11e6833181be3107ad4384464ba656d3f2c8b773806fe6b7fc615e3eb01bd661`. Le dépôt totalise environ 12,2 Go parce qu’il inclut aussi `optimizer.pt` de 8,15 Go ; ces fichiers de reprise ne sont pas requis pour l’inférence ([arbre du checkpoint](https://huggingface.co/jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame/tree/6db0efecd56d4a7e0003190a6bd4cac056d0f390)).
- Runtime déclaré par l’auteur du checkpoint : le même stack d’inférence que Qwen3-ASR amont, donc `qwen-asr` avec backend Transformers ou vLLM ; l’exemple officiel est BF16/CUDA et non le runtime macOS 8-bit du produit ([carte du checkpoint](https://huggingface.co/jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame#inference), [runtime Qwen officiel](https://github.com/QwenLM/Qwen3-ASR#inference)).
Ces éléments sont informatifs seulement : aucune révision n’est approuvée et, conformément à la porte licence, aucune préparation 8-bit n’a été engagée.

## Preuves figées et contrôles légers

La capture structurée des métadonnées primaires, de la décision, de l’absence du cache candidat et des hashes figés est conservée dans `docs/japanese-live/experiments/evidence/E24/qualification.json` (SHA-256 `e90c4bf6af835ff3eb181a91670b34aa54a8b714820873b4e45b657e6685513f`). Les sources brutes épinglées sont archivées sous `evidence/E24/primary-sources/` : API checkpoint `57d71cd1…f405`, README checkpoint `aa1410c2…8ee0`, README dataset `c5c29a48…8021`. La métadonnée du checkpoint a été lue sans poids via `GET /api/models/.../revision/6db0efe...?blobs=true`.

- Build/runner : E22 reste le contrôle autoritaire. Le contrôle courant utilise le même `HighQualityASRWorker`; build chaud réussi en `5,23 s`, puis 10 tests worker en `2,574 s` : 8 réussis, 2 smokes lourds correctement ignorés faute de créneau, 0 échec. Log brut `evidence/E24/lightweight-controls.log`, SHA-256 `9b87533f…ac77`. Aucun worker candidat ni pipeline parallèle n’a été ajouté.
- Cache : le chemin Hugging Face attendu pour le checkpoint est absent ; aucun poids candidat n’était préexistant ou n’a été téléchargé.
- Input/référence DEV : manifeste `a13a80fe…c0b`, source `b61eaa57…696e1`, PCM `494577ab…8f2`, alignement caractères `abfbd3f2…f4a7`, brut E22 `1f5edc2f…1ce8` et segments E23 `e6f8024c…2f81`. Le holdout n’a pas été consulté.

Exemples japonais/anglais figés, uniquement pour rendre explicite la comparaison qui n’a pas été autorisée :

- `199` : « まだね、次の試合ありますから。 » ; référence anglaise « There is still another match coming up. » ; Standard « Yes, thank you very much. There's still another match coming up, so... » ; Anime/Galgame : **absent, licence bloquée**.
- `32` : « リーサルだー！ ドーーーン!!! » ; référence anglaise « It's lethal! BAAAM!!! » ; Standard vide ; Anime/Galgame : **absent, licence bloquée**.

Temps concrets réutilisés : diagnostic E23 `2,92 s`, ASR DEV Standard E22 `68,1 s`, preuve E22 totale `18 min 44 s`. Temps candidat : `0,00 s`; pic mémoire candidat : aucun processus lancé.

## Arrêt de l’expérience

La licence échoue avant toute attribution d’un défaut au candidat et avant toute modification de `HighQualityASRWorker`. Les contrôles légers ci-dessus excluent néanmoins un cache préexistant et figent le build/runner/input/référence sans exécuter le modèle. Aucun poids, runtime, smoke, DEV ou holdout n’est autorisé ; aucune demande `READY_FOR_HEAVY_BENCHMARK` n’est émise. Réouvrir uniquement avec une autorisation primaire explicite couvrant les poids dérivés, l’usage produit local et leur intégration/distribution.
