# E04 — candidat ASR japonais final

Date : 2026-08-02. Machine : MacBook Pro M5 Pro 24 Gio, macOS 26.5.2. Run : `e4-asr-20260802T160000Z`, commit de base `09b092b001e4d35cd193b9a5e3f4f7307d74821b`, arbre benchmark modifié. Réseau interdit et modèles épinglés par révision et SHA-256.

## Résultat

Aucun challenger ne franchit la première porte de qualité appariée contre le final Qwen actuel. La porte étant un veto strict, le replay produit FireRed + Apple Translation n'a pas été lancé : il ne pouvait plus rendre un challenger promotable. `qwenApple` reste donc le final existant ; E04 ne promeut aucun nouvel ASR.

Le screening utilise les 92 tours fixes des deux références vidéo autoritaires, dont 58 tours high-confidence sans overlap. Chaque moteur reçoit exactement le même PCM.

| ASR | CER high | Gain relatif vs Qwen | IC bootstrap 95 % | p95 / pire ASR | RSS max | PCM / dernière parole |
|---|---:|---:|---:|---:|---:|---|
| Qwen 1.7B | 25,96 % | baseline | — | 636 / 1240 ms | 6,71 Gio | 100 % / oui |
| Kotoba Q5 | 26,24 % | −1,06 % | [−35,14 % ; 26,07 %] | 1049 / 1115 ms | 1,05 Gio | 100 % / oui |
| Whisper Turbo | 46,51 % | −79,15 % | [−273,48 % ; 13,18 %] | 1277 / 2517 ms | 3,52 Gio | 100 % / oui |
| Parakeet JA Core ML | **22,29 %** | **14,13 %** | **[−13,61 % ; 36,84 %]** | **76 / 95 ms** | 3,39 Gio | 100 % / oui |

Parakeet améliore le score agrégé sur les deux vidéos (−3,92 et −3,35 points de CER), mais la borne basse appariée reste sous le gain exigé de 10 %. Les références ne contiennent aucun terme critique annoté ; cette porte est donc non évaluable, sans effet sur l'arrêt puisque la qualité appariée a déjà échoué.

## Preuves

- `ja-asr.json` : SHA-256 `ffce2657d768e5e94ff9e6dc1bf2ba798b4c40e2890b9457404c943cba8ca2a8`.
- `comparison.json` : SHA-256 `ad11c9ef4317bcf9bfe934d36ffaf33cbdf274a308ca9039c292618b214409ff`.
- Artefacts bruts versionnés : `docs/japanese-live/experiments/evidence/E04-final-asr/`.
- Intégrité complète : `docs/japanese-live/experiments/evidence/E04-final-asr/sha256.tsv`.

Reproduction :

```bash
WHISPERASR_OFFLINE=1 Scripts/run_japanese_e4_bakeoff.sh
```
