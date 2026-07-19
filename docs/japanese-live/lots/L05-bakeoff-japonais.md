# L5 — Bakeoff japonais

## Dépendances

L4. Les références restent `pending-human-review`; L5 peut établir une shortlist, pas promouvoir un moteur produit.

## Objectif

Comparer huit moteurs japonais, séquentiellement, sur le même stress pack réel de 92 tours provenant de `qudu2fx3ncc` et `md62mmdz0m`.

## Hors-périmètre

- Modifier `Package.swift` ou le produit.
- Mesurer la preview ou la traduction anglaise, réservées à L6.
- Activer l'alignement ou la diarisation `whispermlx`.
- Tester Qwen 0.6B avant que le 1.7B gagne en qualité mais rate les ressources.

## Fichiers touchés

- `Tests/JapaneseModelBakeoffTests.swift`
- `Scripts/japanese_external_asr.py`
- `Scripts/prepare_japanese_l5_tools.sh`
- `Scripts/run_japanese_l5_bakeoff.sh`
- `docs/japanese-live/README.md`
- `docs/japanese-live/lots/L05-bakeoff-japonais.md`

## Protocole

Ordre fixe : Whisper Turbo, `mlx-whisper` Turbo, Voxtral Q4/960, Nemotron 1120, Nemotron 560, Kotoba v2.0 Q5, Qwen3-ASR 1.7B, puis `whispermlx` 3.12.2.

Stress pack non modifiable :

- `qudu2fx3ncc` : tours 147–183 et 193–199;
- `md62mmdz0m` : tours 149–187 et 265–273;
- 58 `high` non-overlap, 19 `medium`, 2 `low`, 13 overlap.

Les deux flux Python partagent seulement un adaptateur JSON de benchmark. Ils gardent des environnements séparés sous `.build`. `whispermlx` utilise Silero v6.2.1 local, sans alignement ni diarisation. Les deux chemins MLX sont préchauffés comme les moteurs natifs et utilisent les mêmes options de décodage `mlx-whisper`.

## Pins

| Élément | Révision/version | SHA vérifié |
| --- | --- | --- |
| `mlx-whisper` | 0.4.3 | URL wheel avec hash `6b82b659…4489` imposé |
| MLX Whisper Turbo | `a4aaeec0…6fb` | poids `951ed3fc…f8a6` |
| Kotoba Q5 | `e3a0cf6a…2c3` | poids `4a3b9219…3658` |
| Qwen3-ASR 1.7B | `e5450a26…27a6` | poids `bf304b00…c13c` |
| `whispermlx` | 3.12.2 / `37816743…651` | URL wheel avec hash `60845ff6…17a4` imposé |
| Silero VAD | v6.2.1 / `7e30209a…02b1` | checkout Git exact |

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --filter JapaneseModelBakeoffTests/testL5StressPackIsFixedAndBandSeparated
Scripts/run_japanese_l5_bakeoff.sh
WHISPERASR_OFFLINE=1 Scripts/run_japanese_l5_bakeoff.sh
```

## Preuves

- Smoke `mlx-whisper` hors ligne : `.build/benchmarks/japanese-live/runs/l5-smoke-mlx-whisper/`.
- Smoke `whispermlx` + Silero hors ligne : `.build/benchmarks/japanese-live/runs/l5-smoke-whispermlx/`.
- Run exploratoire des huit moteurs : `.build/benchmarks/japanese-live/runs/l5-stress-exploratory/` — 736 sorties, aucune erreur d'exécution.
- Recontrôle MLX audité, réseau interdit : `.build/benchmarks/japanese-live/runs/l5-smoke-audited-mlx-response.json`.
- Recontrôle `whispermlx` audité, réseau interdit : `.build/benchmarks/japanese-live/runs/l5-smoke-audited-whispermlx-response.json`.
- Preuve finale propre et hors ligne : `.build/benchmarks/japanese-live/runs/l5-final-offline/`.

## Décision

Whisper Turbo reste le témoin. Kotoba Q5 est le challenger le plus proche (CER high exploratoire 26,24 % contre 26,70 %), mais son gain n'atteint pas le gate de 10 %. Qwen atteint 27,06 % avec 6,63 Gio. Voxtral et Nemotron ajoutent des tours `high` vides; MLX direct atteint 47,06 % et un p95 batch de 4,87 s.

`whispermlx` est arrêté après le stress pack : CER 32,39 %, 6 tours `high` vides, 12 vides diagnostiques et p95 batch de 2,91 s. Silero transmet 72,5 % du PCM au décodeur; ce ratio reste diagnostique, car un VAD peut retirer du silence. Ce n'est pas une preuve de streaming ni un candidat L6A. Aucun runtime produit n'est ajouté. Les termes critiques et toute promotion restent bloqués par la revue humaine.

## Rollback

Revenir au commit L4. Supprimer les outils ignorés sous `.build/benchmarks/japanese-live/tools/`; aucun fichier produit n'est affecté.
