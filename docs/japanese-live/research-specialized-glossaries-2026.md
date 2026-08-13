# Recherche E1a — glossaires japonais spécialisés et bornés

Date : 2026-08-05. Base : `d91f9ff` (`codex/issue-26-e0-benchmark`). Périmètre : construction et bornage des glossaires Anime, VTuber, Gaming et Conversation. Aucun candidat ASR n'est évalué ici.

## Décision

Ne pas livrer un dictionnaire japonais général ni un catalogue Anime global. Conserver quatre inventaires de provenance, mais n'activer que `General + profil de sujet + overlay de la vidéo` :

- **VTuber** : roster officiel borné et overlay des personnes nommées dans la vidéo ;
- **Gaming** : jeux, personnages, systèmes et jargon présents dans le sujet local ;
- **Conversation** : produits, tests nommés et argot réellement ancrés dans la référence locale ;
- **Anime** : vide par défaut ; au plus 40 termes d'une œuvre choisie, issus de MADB puis du site officiel de l'œuvre, seulement après ajout d'une référence Anime locale.

Les formes ont quatre rôles distincts : `hint` (contexte de reconnaissance), `preserve` (variante légitime à reconnaître mais à ne jamais réécrire), `replace` (erreur ASR exacte prouvée localement), `exclude`. Le champ `aliases` actuel est réservé à `replace`, car `JapaneseGlossary.applying` réécrit chaque alias. Les surnoms et abréviations légitimes restent donc hors de ce champ.

Budgets maximaux : **80 termes actifs ordinaires + 20 termes d'overlay = 100**, **16 alias `replace`**, **16 Kio JSON UTF-8**, **p95 de correction ≤ 0,25 ms/tour**, **pire ≤ 1 ms/tour** et **zéro faux remplacement** sur les références locales. Ces seuils laissent la place à l'overlay tout en respectant la limite Apple de 100 phrases contextuelles.

E0 utilise Apple Speech sans hints produit. La limite de 100 prépare seulement un éventuel `DictationTranscriber` ; elle ne prouve aucun gain et les termes sans alias n'augmentent pas le coût de `JapaneseGlossary.applying`.

## Pare-feu de provenance

Chaque entrée future doit conserver :

```text
term_id, domain, canonical, reading, forms[], mode,
source_id, source_record_id, retrieved_at, derivation,
ambiguity, scope, local_anchor_ids[]
```

Les sources externes remplissent uniquement `canonical`, `reading`, `forms` et la provenance. **Couverture et collisions utilisent seulement L1–L4 ; les effets des corrections utilisent la sortie E0 locale L0 ; taille et runtime utilisent le code local L6. Aucune mesure ne vient d'une source externe.**

## Sources

### Références locales autoritaires pour les mesures

| ID | Source | SHA-256 / rôle |
|---|---|---|
| L0 | `/Users/maz/Documents/projets/whisperASR-issue-26/.build/benchmarks/japanese-live/runs/e0-qwen-final-20260802T203033Z/live-replay.json` | `b9e06277edb6c23d9b969f06f160a0a587dcb867255d593e7c17a6c7342f4658` ; fragments Qwen E0 bruts épinglés |
| L1 | `/Users/maz/Documents/videos/jap/1/QUdu2fx3NCc_reference_transcript_and_translation/QUdu2fx3NCc_bilingual_reference.csv` | `df0bce85845cca243e0ed4ae3c5b885e519cc4f0aada9c6ddb1b169cb22f93ba` ; VTuber × Gaming |
| L2 | `/Users/maz/Documents/videos/jap/1/QUdu2fx3NCc_reference_transcript_and_translation/README.txt` | `a38d674f9b82758d43e0c0725b569ab8f866af62c869901ecc9e88def4cbd30c` ; glossaire fourni |
| L3 | `/Users/maz/Documents/videos/jap/2/mD62MMDz0M_final_readable_transcript_pack/mD62MMDz0M_reference.jsonl` | `c1f08461fb393d40cc3e82dc22c3f3befd066b3dd091b6522547228db86996df` ; VTuber × Conversation |
| L4 | `/Users/maz/Documents/videos/jap/2/mD62MMDz0M_final_readable_transcript_pack/README.md` | `05609ae0058c70daa4d1fa59b55ed95f318b02563a18a6c2bf8371d98799bcb1` ; conventions culturelles et gaming fournies |
| L5 | `docs/japanese-live/experiments/E00-domain-benchmark.md` | `7d10293324d6d64c4bf2e19d538b06375fc44e6348a0e1fefa003f9fcbdb9052` ; baseline E0 |
| L6 | `Sources/JapaneseGlossary.swift` | `fac26d9fe8c9960179f8bf3e9cdf88b178c507072387d6b7490ebace64ed87eb` ; schéma et bibliothèque actuels |

Les manifests versionnés de L1/L3 ont respectivement les SHA `a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b` et `9e2c828804457100b5f517ae84e1709a7b502837e36154ec4e7c7b5dc635e3bc` et contiennent 470 tours. Les deux noms de fichiers vidéo sous `/Users/maz/Documents/videos/jap/{1,2}/` servent aussi de métadonnées locales pour les titres et participants.

### Sources primaires externes, construction seulement

| ID | Source primaire | Usage autorisé |
|---|---|---|
| E1 | [VSPO — membres](https://vspo.jp/member/), [VSPO! SHOWDOWN](https://event.vspo.jp/vspo-showdown-2025/) | graphies officielles du roster et de l'événement |
| E2 | [Neo-Porte — membres](https://neo-porte.jp/member/), [緋月ゆい](https://neo-porte.jp/member/hizuki-yui), [白雪レイド](https://neo-porte.jp/member/shirayuki-reid) | graphies officielles des deux invités |
| E3 | [Manuel officiel Street Fighter 6](https://game.capcom.com/manual/SF6/ja/switch2/top), [écran et Burnout](https://game.capcom.com/manual/SF6/ja/ps5/page/3/1), [commandes SF6 de 豪鬼](https://www.streetfighter.com/6/ja-jp/character/gouki/movelist) | noms du jeu, personnage, systèmes et `百鬼襲` |
| E4 | [Apex Legends](https://www.ea.com/ja/games/apex-legends/apex-legends), [ミラージュ](https://www.ea.com/ja/games/apex-legends/apex-legends/characters-hub/mirage), [guide des termes](https://help.ea.com/ja/articles/apex-legends/terms-guide/), [rangs](https://help.ea.com/ja/articles/apex-legends/ranked/) | titre, personnage et rangs officiels |
| E5 | [VCR GTA](https://vaultroom.shop/pages/vcr-gta), [VTuber最協決定戦](https://vtuber-saikyo.jp/), [Portal 2](https://store.steampowered.com/app/620/Portal_2/), [逆転裁判](https://www.capcom.co.jp/support/faq/full_platform_othersgames_gba_saiban.html) | noms d'événements et d'œuvres |
| E6 | [Apple — identification des iPhone](https://support.apple.com/ja-jp/108044), [iPhone XR](https://support.apple.com/ja-jp/111868) | noms complets des produits ; les lectures orales restent locales |
| E7 | [MADB LOD](https://mediag.bunka.go.jp/madb_lab/lod/), [mode d'emploi](https://mediag.bunka.go.jp/madb_lab/lod/howto/), [conditions](https://mediag.bunka.go.jp/madb_lab/user_terms/) | titres Anime/jeu, variantes et identifiants stables, avec attribution |
| E8 | [UniDic](https://clrd.ninjal.ac.jp/unidic/download.html), [CEJC](https://www2.ninjal.ac.jp/conversation/cejc.html) | contrôler lectures/homographes ; jamais importer le dictionnaire ni utiliser les fréquences pour noter |
| E9 | [Apple `contextualStrings`](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings) | phrases courtes d'un ou deux mots et maximum documenté de 100 |

Les pages Love Type confirment des libellés via des URLs de résultat, mais leur licence et leur accès automatisé ne sont pas assez clairs : aucun scraping. L3/L4 restent la provenance des libellés locaux.

## Inventaires proposés

### VTuber

Le profil statique contient exactement la marque plus les 32 membres JP publiés par E1, soit les 33 termes déjà présents dans L6 :

- `ぶいすぽっ！` (`ぶいすぽ`) ;
- `花芽すみれ` (`かが すみれ`), `花芽なずな` (`かが なずな`), `小雀とと` (`こがら とと`), `一ノ瀬うるは` (`いちのせ うるは`), `胡桃のあ` (`くるみ のあ`), `兎咲ミミ` (`とさき みみ`), `空澄セナ` (`あすみ せな`), `橘ひなの` (`たちばな ひなの`) ;
- `英リサ` (`はなぶさ りさ`), `如月れん` (`きさらぎ れん`), `神成きゅぴ` (`かみなり きゅぴ`), `八雲べに` (`やくも べに`), `藍沢エマ` (`あいざわ えま`), `紫宮るな` (`しのみや るな`), `猫汰つな` (`ねこた つな`), `白波らむね` (`しらなみ らむね`) ;
- `小森めと` (`こもり めと`), `夢野あかり` (`ゆめの あかり`), `夜乃くろむ` (`やの くろむ`), `紡木こかげ` (`つむぎ こかげ`), `千燈ゆうひ` (`せんどう ゆうひ`), `蝶屋はなび` (`ちょうや はなび`), `甘結もか` (`あまゆい もか`) ;
- `銀城サイネ` (`ぎんじょう さいね`), `龍巻ちせ` (`たつまき ちせ`), `青月レミア` (`あおつき れみあ`), `黒刃アリヤ` (`くろは ありや`), `地崎ジラ` (`じさき じら`), `美暮ナリン` (`みくれ なりん`), `ソラリリコ` (`そらり りこ`), `涼上エリス` (`すずかみ えりす`), `梅園ジュノ` (`うめぞの じゅの`).

E1 écrit parfois une espace entre nom et prénom ; sa suppression est une dérivation locale documentée, pas un alias de remplacement. L'overlay VTuber local ajoute `緋月ゆい` (`ひづき ゆい`) et `白雪レイド` (`しらゆき れいど`) depuis E2/L3. L'overlay Gaming ajoute séparément `立川` et `ボンちゃん` depuis L1.

`もか`, `もかさん`, `もかちゃん`, `甘結さん`, `くろむさん`, `蓮くん`, `エマ`, `エマたそ`, `たそまる`, `ゆいぴ`, `レイドさん` sont des formes `preserve`, jamais des `replace`.

### Gaming

| Groupe traçable | Termes canoniques / lectures | Provenance | Mode |
|---|---|---|---|
| Événements et œuvres | `VSPO! SHOWDOWN`, `VCR GTA`, `Portal 2`, `VTuber最協決定戦`, `逆転裁判` | E1, E5, L1/L2 | `hint` ; `V最` reste `preserve` |
| Street Fighter 6 | `ストリートファイター6`, `豪鬼` (`ごうき`), `百鬼襲` (`ひゃっきしゅう`) | E3, L1/L2 | `hint` |
| Systèmes SF6 | `ドライブゲージ`, `ドライブパリィ`, `ドライブインパクト`, `ドライブラッシュ`, `バーンアウト`, `モダンタイプ` | E3, L1/L2 | `hint` ; formes courtes `preserve` |
| Jargon combat | `リーサル`, `キルライン`, `2先`, `3先` | L1/L2 | `hint`, sans expansion sémantique |
| Apex | `エーペックスレジェンズ`, `ミラージュ`, `ルーキー`, `シルバー`, `レジェンド` | E4, L3/L4 | noms complets `hint`, rangs `preserve` |
| Jargon Apex | `安置外耐久`, `キーマウ` | L3/L4 uniquement | `preserve` |

`Apex Legends`, `APEX` et `エペ` sont trois surfaces légitimes ; aucune ne doit écraser les autres. Même règle pour `ドライブ`, `パリィ`, `インパクト`, `ラッシュ`, `モダン` et `V最`.

### Conversation

| Groupe traçable | Termes | Provenance | Mode |
|---|---|---|---|
| Produits | `iPhone XR`, `iPhone 17`, `iPhone 17 Pro`, `iPhone 17 Pro Max`, `iPhone 11 Pro`, `iPhone 15`, `iPhone X`, `iPhone 16`, `1TB` | E6, L3 | noms complets `hint`; `XR`, `X`, `15`, `16`, `17`, `Pro Max` `preserve` |
| Love Type | `ラブタイプ`, `最後の恋人`, `ちゃっかりうさぎ`, `隠れベイビー`, `ボス猫` | L3/L4 | `preserve` |
| Culture/argot | `清楚`, `バブバブ`, `ありよりのあり`, `サブアカ` | L3/L4 | `preserve` |

Les mots ordinaires (`ティッシュ`, `フィルター`, `マジ`, `ガチ`, nombres isolés) restent exclus : les ajouter ne résout aucun nom propre et augmente l'ambiguïté.

### Anime

Il n'existe aucune référence Anime locale, donc le profil actif reste vide et sa couverture est `n/a`. Pour une œuvre choisie, E7 peut fournir le titre canonique, ses variantes et un identifiant MADB ; le site officiel de l'œuvre doit ensuite fournir personnages, lieux et techniques. Limite : 1 titre, 20 personnages, 10 lieux/organisations et 9 techniques, soit 40 termes. Aucun de ces termes n'est promu ni noté avant l'ajout d'une référence Anime locale indépendante.

## Ambiguïtés, exclusions et faux remplacements

Une canonicalisation naïve de 19 formes légitimes (`もかさん`, `ゆいぴ`, `レイドさん`, `APEX`, `エペ`, `V最`, `モダン`, `ドライブ`, `パリィ`, `インパクト`, `ラッシュ`, `隠れ赤ちゃん`, etc.) modifierait **33/470 tours**, soit **38 remplacements**. Sur les seuls tours `high` hors overlap : **23 tours et 26 remplacements**. Comme L1/L3 sont autoritaires, tous sont des faux remplacements.

Le catalogue scoreable `docs/japanese-live/glossaries/e1a-candidates.json` retient seulement 8 alias `replace` observés dans L0 et soutenus par le tour local chevauchant :

- VTuber, 2 : `甘井隆`, `甘いボカ` → `甘結もか` ;
- Gaming, 2 : `リソール` → `リーサル`, `エペックス` → `APEX` ;
- Conversation, 4 : `iPhone10R` → `iPhone XR`, `17プロマックス` → `17 Pro Max`, `11プロ` → `11 Pro`, `1000テラバイト` → `1TB`.

Ils provoquent **0 collision et 0 modification sur les 470 tours L1/L3**. Cela établit seulement l'absence de faux positif dans les références fournies ; l'amélioration ou la dégradation du candidat reste mesurée sur L0 par le rapport E1a. `甘井もか`, `甘いモカ` et `スト6`, absents de L0, ainsi que `甘い儲か` et `甘いもんかわ`, sans cible dans le tour local chevauchant, restent en quarantaine ou en forme `preserve`. E0 rapporte que la bibliothèque alors active avait modifié 0/288 fragments.

Une nouvelle règle `replace` n'entre qu'avec : occurrence ASR brute locale, cible présente dans la référence locale, contexte non ambigu, zéro collision sur L1/L3 et conservation du texte brut à côté du texte corrigé. NFC et retrait des caractères de transport restent les seules normalisations automatiques générales de L6. La suppression d'une espace dans un nom complet officiel est une dérivation d'import restreinte à ce nom connu.

## Mesures locales

### Couverture de construction

L'inventaire cible a été annoté à partir des seules références L1–L4, puis recherché par variantes exactes les plus longues. C'est une mesure de complétude de l'inventaire, pas un score ASR ni une preuve d'amélioration.

| Domaine | Occurrences locales couvertes | `high` hors overlap | Limite |
|---|---:|---:|---|
| VTuber | 26/26 | 19/19 | seuls noms et surnoms présents dans les deux vidéos |
| Gaming | 66/66 | 41/41 | SF6, Apex, événements et rangs locaux |
| Conversation | 49/49 | 37/37 | produits, Love Type et argot locaux |
| Anime | n/a | n/a | aucune référence locale |
| Total mesurable | **141/141** | **97/97** | aucun terme externe absent du corpus n'est noté |

Les deux titres de fichiers locaux couvrent aussi **16/16** mentions ciblées d'événement, jeu, participant ou test nommé. E0 laisse toutefois tous les `criticalTerms` vides : le rappel de termes par candidat reste non scoré tant qu'une annotation locale indépendante n'est pas ajoutée.

### Taille encodée

Mesure avec le `JSONEncoder` de L6 : bibliothèque actuelle 49 termes = **4 738 octets** ; snapshot actif = **4 779 octets**. Une enveloppe synthétique de 80 termes et 16 alias encode un snapshot de **8 795 octets** ; 100 termes et 16 alias = **10 695 octets**. Le plafond de 16 Kio garde donc une marge mesurée.

### Coût runtime des remplacements

Microbenchmark du code Swift exact de L6 sur Apple M5 Pro, macOS 26.5.2, Swift 6.3.3, les 470 tours L1/L3, alias absents du texte. Chaque tour est exécuté 20 fois ; le tableau donne les quantiles des moyennes par tour :

| Alias `replace` | p50 par tour | p95 | pire |
|---:|---:|---:|---:|
| 2 | 10,53 µs | 30,70 µs | 85,49 µs |
| 16 | 59,94 µs | 183,95 µs | 521,39 µs |
| 100 | 355,72 µs | 1 111,40 µs | 3 179,92 µs |

Le coût vient des alias, pas des termes sans alias. La borne de 16 alias respecte les portes `0,25/1 ms` et évite de transformer le correcteur linéaire actuel en moteur de dictionnaire. Aucun nouveau parseur, trie ou dépendance n'est justifié avant dépassement mesuré de cette borne.

## Protocole de promotion

1. Geler l'inventaire et sa provenance avant d'ouvrir les sorties du candidat.
2. Annoter localement les occurrences critiques ; aucune source externe n'ajoute une occurrence de score.
3. Mesurer rappel exact, faux remplacements, taille JSON et runtime sur L1/L3, avec Anime `n/a`.
4. Rejeter toute règle qui modifie une variante légitime ou un tour sans paire ASR brut/référence.
5. Conserver ASR brut, texte corrigé, empreinte du glossaire et liste des règles déclenchées séparément.
