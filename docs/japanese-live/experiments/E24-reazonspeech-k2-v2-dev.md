# E24 — ReazonSpeech K2 v2 int8 sur DEV (#89)

Décision : **NO-GO qualité**. Qwen reste la baseline. Holdout fermé. Aucune quatrième inférence ASR.

## FINAL_DEV

- Statut : `failed` — `Japanese ASR worker failed: invalid anchored transcription response`.
- ASR : 23.246 s ; pic 1.29 Gio ; exit 0 ; pression=[] ; swap Δ=0 octet.
- Le `raw-asr.json` FINAL_DEV ne contient que la dernière réponse interne (`うん`), mais les 55 réponses worker brutes ont été archivées.
- Leurs JSON canoniques sont identiques au retry 135 caractères : `1d705ce05614e4786555b942768a972a41f745df2da1e232682eea44674acd02`.

## Invariant numérique

- Le raw persistant à 135 caractères isole trois fins dépassant leur anchor d'un ULP ; ce sont des arrondis du raccord, pas des erreurs candidat :
- `っ` chunk 6 : 121.52000000000001 > 121.52 (Δ 1.421e-14 s).
- `在` chunk 25 : 476.82000000000005 > 476.82 (Δ 5.684e-14 s).
- `ん` chunk 43 : 793.4000000000001 > 793.4 (Δ 1.137e-13 s).
- Correction minimale : `sourceEnd = min(anchorEnd, globalEnd)` ; test fail-closed ajouté. Aucun changement de l'aligneur ni du contrat.

## Verdict qualité vs Qwen

- Japonais brut Reazon/Qwen : 135 / 4 396 caractères.
- CER Reazon/Qwen : 97.19% / 81.26%.
- Matériel récupéré/perdu vs Qwen : 0 / 3391.
- cue-0274 — réf. `かさんがね。まあ立川には悪いけど、ちょっと今回はもかさんの勝ちということで。またいろいろやる機会はあると` ; Qwen `モコさんがね、まあ勝ちには悪いけど、ちょっと今回はモコさんの勝ちということで、またねいろいろやる機会があると思うんで。` ; Reazon `` ; Δ -53.
- cue-0251-part-1 — réf. `ちゃん教えてる」みたいなのが3、4個あって。ちょっとやっぱ、コーチ` ; Qwen `絶対分ちゃん教えてるみたいなのが34個あってその見え隠れに結構やられたなって思ってちょっとやっぱコーチの優` ; Reazon `` ; Δ -49.
- cue-0238 — réf. `うち、人のゲームプレイ見て泣くの初めてなんだけど（笑）。え、マジですごい。ただただ、うまいっ` ; Qwen `うち、人のゲームプレイ見て泣くの初めてだったけど、マジで、すごいただただ上手いっていう、` ; Reazon `` ; Δ -43.

## Anglais et replay

- Anglais Reazon non produit ; pipeline arrêté avant alignement/traduction.
- Replay downstream : normalized-contract-pass-heavy-not-run — The persistent 135-character exchange passes complete, bounded, monotonic character timing after both anchor clamps. Heavy alignment and translation were not started outside the granted command.
- Baseline Qwen tour 1 — réf. `Next up is the anchor match: Amayui Moka versus Tachikawa.` ; sortie `Sweet Moka = Amayui Moka
The next target is Sweet Moka and Tachikawa.`.
- Baseline Qwen tour 2 — réf. `Moka, you've got this! Go! Go!` ; sortie `I'm here. "Moka, you can do it! Keep going! Keep going!"`.

## Preuves

- FINAL_DEV : 25.230 s de stages ; 26.554 s mur ; pic job 1.29 Gio.
- Hash manifeste FINAL_DEV : `088cec540bebcc5e73128c0f001ddcdef557c56147ab03982520a763d4e01f7d`.
- Hash raw FINAL_DEV : `a9d3590fcd55bcc1613ab30c7cb6400694faebffb14cff9b148c6952dffc738d`.
- Hash raw FINAL_DEV gzip : `c743553e4d9100d0cd995e056c133bbb0604ba250038a3b81c6d7d127b6d8bfd`.
- Hash log FINAL_DEV gzip : `310e29523a597671ec65f3be8f56544519d343cc356a019e181c1506fad2f944`.
- Hash signal 135 caractères : `62067494780c0cd80efca43cce50bfcd9fab826aef7f38069353af9f110a4402`.
- Hash protocole worker FINAL_DEV : `21dc4550518863f9946cfa1a8769603f6acef9406f25a3e69120bc2889c5abaf`.
- Hash protocole worker retry : `092f0f4680eb874a91bd68788edb13fe70da141b247dfe7cac140d64f24753d9`.
- Commit exécuté : `b5ee113edff79cc82d4de91d098a6bdb43fdba9c`.
- Exécuté `Sources/HighQualityASRWorker.swift` : `851ff7aacb590df73be1027100da375e61d61288ccdce89ff6dfd20b079157e8`.
- Exécuté `Sources/HighQualityJob.swift` : `c76e181834b2bba49887c677c7e31a5a397a891d0d48a4256c970b26281c192d`.
- Exécuté `Scripts/reazon_asr_worker.py` : `493982ef89ca519c8246251f11ac12ed57b09cb5210fbc121058a1b33ed219ff`.
- Exécuté `Scripts/run_reazon_dev_experiment.sh` : `5cfaf89f2c6cf4d03faba2662d7bb305a23d8ab75ab2154938f57f13859b491b`.
- Correctif post-run `Sources/HighQualityJob.swift` : `1a2a668bc3bb2a4d5bfa61f2387946757812af7e77e36745407cf1fa3296d495`.
- Correctif post-run `Tests/HighQualityJobTests.swift` : `0e9f80957434b38eaffe7924990fb1837e5627a40bbedad2b29b5be29d401a1c`.
