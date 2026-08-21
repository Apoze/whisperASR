# Final offline validation — #121

| Lane | Translator | Speaker | Readable | CER | chrF++ | Runtime | Peak |
|---|---|---:|---:|---:|---:|---:|---:|
| development | translategemma-12b-it-4bit | True | False | 79.48% | 46.44 | 1393s | 7.61 GiB |
| holdout | translategemma-4b-it-4bit | False | True | 25.91% | 43.57 | 804s | 7.29 GiB |

## Provenance d’exécution

- development: corpus `b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1`; manifest `a13a80fed1c02ee9c79ff58d6d7c2bf7050a16733ced48c33121dc4d414b5c0b`; PCM 15315325/15315325 échantillons (100.000 %, PASS).
- holdout: corpus `a0f913830f4a9994ce366414f4f9abc6cf0e25f64ac15f4d9037c1673e68798d`; manifest `9e2c828804457100b5f517ae84e1709a7b502837e36154ec4e7c7b5dc635e3bc`; PCM 14177919/14177919 échantillons (100.000 %, PASS).
- development: commit exécuté `25cb84034d0cdaf2879659ae09f0dcf3f249cfa8`; patch `a8a77ddf623f8f7cb7910093448eb08ab18574946f90d1d4311ca74a4791692a`; patch exact vérifié.
- holdout: commit exécuté `25cb84034d0cdaf2879659ae09f0dcf3f249cfa8`; manifeste de diff `3cf6247f7bc1128e846d3f7e63fb90fe5fede50b2a5da755890259a0d82d15cc`; patch brut absent, manifeste dérivé fail-closed.
- `model-provenance.json`: `4e322ed71e2a76966999e5e37687ec9d7f4236d7d4e45e94f4fa75b47b52a03d` (verified).
- Poids `ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit` / `model.safetensors`: `bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954`.
- Poids `mlx-community/Qwen3-ForcedAligner-0.6B-4bit` / `model.safetensors`: `630bcfbaccf2635940bbe94ad5475fd60ee4f47259b62d36deff806d60bcf24c`.
- Poids `argmaxinc/speakerkit-coreml` / `segmenter/W8A16/weight.bin`: `75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4`.
- Poids `argmaxinc/speakerkit-coreml` / `embedder/W8A16/weight.bin`: `a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795`.
- Poids `argmaxinc/speakerkit-coreml` / `embedder-preprocessor/W8A16/weight.bin`: `5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89`.
- Poids `argmaxinc/speakerkit-coreml` / `clusterer/W32A32/weight.bin`: `a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced`.
- Poids `mlx-community/translategemma-12b-it-4bit` / `model-00001-of-00002.safetensors`: `bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af`.
- Poids `mlx-community/translategemma-12b-it-4bit` / `model-00002-of-00002.safetensors`: `c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89`.
- Poids `mlx-community/translategemma-4b-it-4bit` / `model.safetensors`: `113acb0c29997a3015af84bec2c8f967cb7b15f8959d1c26b9628b921e324c40`.

## ASR — exemples japonais réels référence ↔ hypothèse

- development:
  - 67 (370.0–375.0s): ref « うまっ。 »; hyp « さっきのさっきの。うまい。タローは画面端から出して。うまい。画面端からもやり返せ。うわー。画面端生かしたい。 ».
  - 23 (124.1–125.9s): ref « うまい。 »; hyp « 落ち着いて両足を取っておきます。オーマー。オーディカ長戦から前に詰めてくるところに残空解け。 ».
  - 108 (568.0–570.0s): ref « ま!? »; hyp « いや、これはVサイいないわ。 ».
  - Termes critiques: notScored — reference contains zero annotated critical-term opportunities.
  - Traductions de référence ↔ sortie:
    - JA « あ、もかちゃんが「リーサルのゲージはこのぐらいの長さ」みたいなこと言ってた。 »; EN ref « Oh, Moka said something like, “When the gauge is about this long, it's lethal.” »; EN hyp « The monkey… it’s definitely the final round with the lethal team. It feels like this will decide it, just those four of them. We need to make sure this doesn't happen again. And Moca, Lisa's... that troublesome Muka, Lisa's gauge is about this much. “It’s about this length, isn't it? Make sure you don't cut it past this line. Yes, yes, yes. This is the line you need to be careful with.” ».
    - JA « 「これはやったな」みたいな。 »; EN ref « Like, “She's got this.” »; EN hyp « “It’s about this length, isn't it? Make sure you don't cut it past this line. Yes, yes, yes. This is the line you need to be careful with.” “You can get them, so your positioning on the front line will become stronger. Yes, it’s really noticeable. It’s stopping.” ».
- holdout:
  - 72 (222.7–223.1s): ref « マジ？ »; hyp « しちゃったでも私もよく落とすけど画面までは割れないなマジあのフィルターは割れるけどあそうそうフィ ».
  - 251 (778.9–779.4s): ref « ふーん。 »; hyp « たわえ一途そのもう絶対にその人だけみたいなねマジで一途私一途だよふんふん ».
  - 235 (720.5–721.2s): ref « 赤ちゃん？ »; hyp « で、あ、ちゃんそんな赤ちゃんじゃなくてなんだっけ隠れ赤ちゃんみたいな私ボス猫と相性いいらしいえな ».
  - Termes critiques: notScored — reference contains zero annotated critical-term opportunities.
  - Traductions de référence ↔ sortie:
    - JA « やめて。適度にかみながらでええやん、それは。 »; EN ref « Stop. Just blow your nose every so often. »; EN hyp « “Ultimately, it’s just too much cleaning fluid. I’m just not sure – is this rainwater, or are we actually using a lot of cleaning fluid while rinsing? No, not really…” “It’s just dripping while I’m chewing… you know? It’s leaking so much – is it rainwater, or just a huge amount of leaking fluid?” ».
    - JA « まあ、私は男を立てるタイプなのかもしれん。 »; EN ref « Maybe I'm the type who supports a man and lets him shine. »; EN hyp « “I guess I’m the type of person who’s comfortable with someone who’s really intense/difficult, like a dominant male cat.” “I wonder what type of person my last boyfriend was… like, what was his personality like? He was really intense/serious.” ».

## Speaker (development)

- Locuteurs référence/candidat/écart: 13/6/7.
- DER/JER: 105.47% / 85.92%.
- Japonais non attribué: 1554 caractères; duplications: 0.
- Overlap précision/rappel/F1: 5.0% / 31.5% / 8.6%.
- Exemples d’attribution incorrecte:
  - 2 (4.0–9.0s): référence SPEAKER_08; candidats SPEAKER_03, SPEAKER_01; JA « もかさん、頑張れ！ 頑張れ！ ».
  - 4 (13.0–18.0s): référence SPEAKER_03; candidats SPEAKER_00, SPEAKER_01; JA « VCR GTAで人のパンツ覗いてきた人のことなんか、ボコボコにしてくれ。 ».

## Lisibilité des sous-titres

| Lane | Cues avant/après | Lisibles avant/après | >20 CPS | >84 caractères | <1s | >7s | Intégrité |
|---|---:|---:|---:|---:|---:|---:|---:|
| development | 307/307 | 119/119 | 156/156 | 37/37 | 74/74 | 11/11 | PASS |
| holdout | 260/283 | 104/148 | 121/121 | 38/19 | 65/65 | 17/2 | PASS |

## Vérifications légères et décisions

- full: passed, 616 tests, 0 échec(s).
- live: passed, 47 tests, 0 échec(s).
- safeCombinedOptions: passed, 1 tests, 0 échec(s).

### Attribution des échecs

- candidate: 0.
- build: 0.
- test: 0.
- runner: 2.
- input: 0.
- reference: 0.
- Freeze DEV strictement fail-closed: False.
- Limites historiques: historical freeze does not prove computed gates before holdout; historical DEV XCTest exit was 1, not zero; historical freeze lacks a complete passing computed gate set.
- TranslateGemma 4B: KEEP_BETA_SELECTABLE; off by default; no superiority claim across different holdout videos.
- Réanalyse Speaker-only: GO_SUPPORTED_RESULT_ACTION; reuses ASR/alignment/translation and completed in 17.756 seconds on DEV.
- Éditeur de locuteurs: GO_SUPPORTED_RESULT_ACTION; rename/reassign/merge/reset audit and regenerated export hashes verified.
- Décision produit globale: NO_DEFAULT_CHANGE; historical DEV freeze and critical-term reference coverage are insufficient for promotion.

## Portes

- bothRealSavedProjectJobsCompleted: PASS
- 12BThen4BProcessIsolated: PASS
- allWorkerLifecyclesExitedAndUnloaded: PASS
- noAdaptiveSelection: PASS
- noLexicalCorrectionSelection: PASS
- qwenFallbackPreserved: PASS
- structuredTranslationIntegrity: PASS
- subtitleTextTimingAndExportsIntegrity: PASS
- speakerReanalysisDoesNotRerunUpstream: PASS
- speakerEditorExportsMatchPersistedFiles: PASS
- voiceMemoryProjectIsolated: PASS
- retainedNoGoAndBetaDecisionsVerified: PASS
- safeOptionsCombinedTestPassed: PASS
- fullSwiftTestsPassed: PASS
- liveTestsPassed: PASS
- corpusAndPCMProvenanceVerified: PASS
- modelWeightHashesVerified: PASS
- executionCommitAndDiffProvenanceRecorded: PASS
- developmentFreezeStrictlyFailClosed: FAIL
- executionPatchProvenanceComplete: FAIL
- criticalASRTermsScored: FAIL

Two supplied videos validate integration behavior, not broad model superiority.
