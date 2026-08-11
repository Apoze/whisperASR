# E24 — ReazonSpeech K2 v2 int8 sur DEV (#89)

Verdict candidat : **SUSPENDU — RETRY REQUIRED**. Holdout fermé. Aucun troisième run lancé.

## Cause prouvée

- Raw Reazon local `今` : 15.96–35.52 s, valide.
- Anchor partagé : 15.88–35.52 s (19.64 s), valide et contenant le caractère.
- Sortie brute aligneur : `今` 15.88–15.88 s, durée zéro ; rejet fail-closed de `cue-0002`.
- Mais la timeline assemblée présente 7 retours aux fenêtres chevauchantes ; ces timestamps ne sont pas consommés par l'aligneur, mais invalident l'audit global demandé.
- Attribution finale impossible sur ce run : défaut de normalisation du raccord partagé. Correction minimale : borner chaque timestamp au début de son anchor et revalider fail-closed l'échange assemblé.

## Comparaison Qwen

- Japonais brut Reazon/Qwen : 135 / 4 396 caractères.
- CER Reazon/Qwen : 97.19% / 81.26%.
- Matériel récupéré/perdu vs Qwen : 0 / 3391.
- cue-0274 — réf. `かさんがね。まあ立川には悪いけど、ちょっと今回はもかさんの勝ちということで。またいろいろやる機会はあると` ; Qwen `モコさんがね、まあ勝ちには悪いけど、ちょっと今回はモコさんの勝ちということで、またねいろいろやる機会があると思うんで。` ; Reazon `` ; Δ -53.
- cue-0251-part-1 — réf. `ちゃん教えてる」みたいなのが3、4個あって。ちょっとやっぱ、コーチ` ; Qwen `絶対分ちゃん教えてるみたいなのが34個あってその見え隠れに結構やられたなって思ってちょっとやっぱコーチの優` ; Reazon `` ; Δ -49.
- cue-0238 — réf. `うち、人のゲームプレイ見て泣くの初めてなんだけど（笑）。え、マジですごい。ただただ、うまいっ` ; Qwen `うち、人のゲームプレイ見て泣くの初めてだったけど、マジで、すごいただただ上手いっていう、` ; Reazon `` ; Δ -43.

## Anglais

- Non produit : l'alignement fail-closed a arrêté le pipeline avant traduction.
- Baseline Qwen tour 1 — réf. `Next up is the anchor match: Amayui Moka versus Tachikawa.` ; sortie `Sweet Moka = Amayui Moka
The next target is Sweet Moka and Tachikawa.` ; Reazon : non produit.
- Baseline Qwen tour 2 — réf. `Moka, you've got this! Go! Go!` ; sortie `I'm here. "Moka, you can do it! Keep going! Keep going!"` ; Reazon : non produit.

## Temps, mémoire et preuves

- Stages : 0 min 40.3 s; ASR 22.140 s; alignement 12.182 s.
- ASR worker : 23.178 s, pic 1.29 Gio, exit 0, pression=[], swap Δ=0.
- Aligneur : 15.144 s, pic 2.83 Gio, exit 0, pression=[], swap Δ=0.
- Timestamps : 135 caractères, texte complet=True, bornés=True, globalement monotones=False.
- Hash manifeste : `502afe6e722f2096a95d8cd99db103ae6b7f5819f13591049c2dd415928125c5`.
- Hash raw ASR : `8a14395da852bf0ac9c840fa0574f83040239767792dbcaad644b0fd20b73fa2`.
- Hash raw gzip retenu : `62067494780c0cd80efca43cce50bfcd9fab826aef7f38069353af9f110a4402`.
- Hash log gzip retenu : `cf562d74433e742d26a7d8733802e306551c3024594b4297c8c3393100fff360`.

Hashes exacts de l'implémentation ayant exécuté le retry :

- `Sources/HighQualityASRWorker.swift` — `455c87399df2309e73030c47a3e51150be2e786b2faad999843ce12d63bae379`.
- `Sources/HighQualityJob.swift` — `b685d4b2cbb55efe88e4fddc17c54ad4d43e013acc6f6df81b8bbad561b9dc2f`.
- `Scripts/reazon_asr_worker.py` — `493982ef89ca519c8246251f11ac12ed57b09cb5210fbc121058a1b33ed219ff`.
- `Scripts/run_reazon_dev_experiment.sh` — `b66ebda1c0328faae0904e55b52a062d179fea478a09ac5776960558d12cf10b`.

Nouveau créneau requis, commande préparée mais non lancée :

```bash
BENCHMARK_SLOT_GRANTED=89 bash Scripts/run_reazon_dev_experiment.sh development
```
