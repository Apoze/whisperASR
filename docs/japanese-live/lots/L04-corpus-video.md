# L4 — Corpus vidéo et preuves

## Dépendances

L2 pour le schéma de corpus et L3 pour le support de benchmark partagé.

## Objectif

Transformer les deux vidéos réelles fournies en PCM canonique mono 16 kHz, épingler toutes les entrées par SHA-256 et conserver les références japonaises/anglaises sans mélanger score principal, diagnostics, overlap et non-parole.

## Hors-périmètre

- Exécuter ou promouvoir un moteur ASR.
- Modifier le chemin produit.
- Inventer des termes critiques non validés.
- Présenter les timings de caractères interpolés comme un alignement phonétique humain.

## Fichiers touchés

- `Scripts/prepare_japanese_video_corpora.py`
- `Tests/JapaneseBenchmarkSupport.swift`
- `Tests/JapaneseModelBakeoffTests.swift`
- `docs/japanese-live/README.md`
- `docs/japanese-live/corpora/qudu2fx3ncc/manifest.json`
- `docs/japanese-live/corpora/md62mmdz0m/manifest.json`
- `docs/japanese-live/lots/L04-corpus-video.md`

## Protocole

- Source locale : `/Users/maz/Documents/videos/jap/`.
- Conversion fixe avec FFmpeg 8.1.2 : première piste audio, downmix `0.5×L + 0.5×R`, resample SWR sans dithering, mono 16 000 Hz, PCM signé 16 bits, métadonnées supprimées et options bitexact.
- Les WAV et copies vérifiées des références restent sous `.build/benchmarks/japanese-live/corpora/<id>/`.
- Les manifests ne contiennent aucun chemin absolu.
- `high` est primaire; `medium` et `low` sont diagnostiques. La non-parole reste dans `negativeRanges`; le booléen `overlap` isole les tours chevauchés.
- Le CER primaire exclut les overlaps et retire les annotations éditoriales `［…］`, `(笑)` et `（笑）` avant normalisation.
- Les termes critiques restent vides : les packs n'en fournissent pas une validation explicite.

## Corpus et preuves

| Corpus | Durée PCM | Tours parlés | high / medium / low | overlap / non-parole | SHA-256 WAV |
| --- | ---: | ---: | ---: | ---: | --- |
| `qudu2fx3ncc` | 15:57,208 | 199 | 143 / 44 / 12 | 37 / 1 | `494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2` |
| `md62mmdz0m` | 14:46,120 | 271 | 179 / 89 / 3 | 2 / 2 | `bde49d4cc67020d01ae042f2945baa61364cc34959e2211a964943e5c2064830` |

Entrées épinglées :

- `qudu2fx3ncc` : vidéo `b61eaa…d696e1`, archive `8f1c4e…01474`, table bilingue `df0bce…f93ba`, alignement `abfbd3…3f4a7`.
- `md62mmdz0m` : vidéo `a0f913…798d`, archive `a95e73…aff86`, référence JSONL `c1f084…96df`, alignement `446e7a…b925`.

Les rapports complets sont `.build/benchmarks/japanese-live/corpora/<id>/preparation.json`; ils contiennent aussi le commit, l'état du worktree, le SHA du manifeste et la commande FFmpeg exacte.

Le dernier événement non parlé de `qudu2fx3ncc` dépassait le PCM décodé de 2,2 ms; seule sa fin a été bornée à la dernière frame. Aucun tour de parole n'a été modifié.

Les identifiants `SPEAKER_08` et `SPEAKER_13` de ce même pack restent des attributions incertaines/de groupe : L9 ne les utilisera pas comme vérité d'identité persistante. `SPEAKER_13` est classé overlap même sans seconde plage explicite.

## Tests

```sh
Scripts/prepare_japanese_video_corpora.py /Users/maz/Documents/videos/jap --rebuild
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter JapaneseBenchmarkSupportTests
Scripts/verify_japanese_corpora.sh
```

Résultat : 226 tests exécutés, 24 opt-in ignorés et 0 échec. Les manifests, SHA, formats PCM, copies de référence et bandes de confiance sont validés. La commande Swift nécessite `--disable-sandbox` uniquement dans le sandbox Codex local.

## Décision

L4 est terminé. Les deux corpus sont utilisables pour la shortlist exploratoire L5. Leur statut reste honnêtement `pending-human-review`; aucune promotion ne peut transformer les lignes ambiguës en vérité terrain.

## Rollback

Revenir au commit L3. Les WAV et rapports sont ignorés par Git et n'affectent pas l'application.
