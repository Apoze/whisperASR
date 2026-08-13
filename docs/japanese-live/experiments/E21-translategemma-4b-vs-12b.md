# TranslateGemma 4B vs 12B — ticket #76

The two candidates received content-identical product inputs frozen after Qwen JA, forced alignment and Standard SpeakerKit. The source-file `modifiedAt` provenance timestamp is ignored by the equality gate; semantic units, context, glossary and generation settings are identical. ASR was not rerun. TranslateGemma 12B remains the default.

| Split | Model | Full job | Valid units | Comparable refs | COMET | chrF++ | Total | Translation | Units/s | Worker peak | Min available | Swap Δ | Exit | Retry rate |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| development | translategemma-12b-it-4bit | pass | 100.00% | 174 | 0.4844 | 46.50 | 7m 23.6s | 7m 22.9s | 0.707 | 12.17 GiB | 2.74 GiB | 995.3 MiB | PID out/0 | 0.96% |
| development | translategemma-4b-it-4bit | fail | 97.76% | 174 | 0.4870 | 43.26 | 5m 40.5s | 5m 39.9s | 0.921 | 6.74 GiB | 7.62 GiB | 0.0 MiB | PID out/0 | 7.03% |
| holdout | translategemma-12b-it-4bit | pass | 100.00% | 268 | 0.5854 | 50.12 | 6m 5.5s | 6m 4.9s | 0.748 | 11.13 GiB | 5.39 GiB | 0.0 MiB | PID out/0 | 0.00% |
| holdout | translategemma-4b-it-4bit | fail | 99.27% | 268 | 0.5769 | 47.31 | 4m 23.9s | 4m 23.3s | 1.037 | 5.14 GiB | 7.81 GiB | -24.0 MiB | PID out/0 | 3.66% |

## development

Paired chrF++ 4B−12B: -0.917 [95% -1.614, -0.241].
Paired COMET 4B−12B: 0.0026 [95% -0.0049, 0.0100].
chrF++ significantly favors 12B.
COMET does not establish a significant winner.
COMET scorer: MPS `Scripts/comet_score_compat.py --gpus 1 --num_workers 1`, 16.74s, peak footprint 5.69 GiB, swap Δ 0.0 MiB, free memory 77%→67%.

Integrity, glossary and subtitle checks:

- `translategemma-12b-it-4bit`: verdicts {'pass': 312, 'suspect': 1}; final reasons {'pathological-length': 1}; all rejected-attempt reasons {'critical-glossary-violation': 1, 'pathological-length': 3, 'control-scaffolding': 1}; retry rate 0.96%.
  - Per-unit attempt flags: empty-output=0.00%, residual-japanese=0.00%, control-scaffolding=0.32%, critical-glossary-violation=0.32%, truncated-output=0.00%, degenerate-repetition=0.00%, pathological-length=0.64%, copied-neighbour=0.00%
  - Glossary: 1/3 (33.3%), misses=['otsukaresama', 'yoroshiku-onegaishimasu']. English subtitles: exported cues=313, empty=0, invalid timing=144, malformed blocks=1, >84 chars=56, >20 chars/s=103, max chars/s=1237.5.
  - Resources: PID 43691 exited=True, pressure transitions=none, minimum available=2.74 GiB. Stages: preparing-alignment=0.0s, preparing-asr=0.0s, translating=442.9s, normalizing-source=0.0s, transcribing=0.0s, aligning=0.1s, diarizing=0.6s, preparing-diarization=0.0s, exporting=0.0s.
  - Raw: `.build/benchmarks/high-quality/translator-bakeoff/translategemma-12b-it-4bit/qudu2fx3ncc/jobs/68B337F1-C128-4261-98F8-CE5555020EFC/raw-asr.json`
- `translategemma-4b-it-4bit`: verdicts {'pass': 294, 'hard-failure': 7, 'suspect': 12}; final reasons {'residual-japanese': 5, 'pathological-length': 15, 'truncated-output': 3, 'degenerate-repetition': 2}; all rejected-attempt reasons {'critical-glossary-violation': 1, 'residual-japanese': 12, 'pathological-length': 32, 'truncated-output': 5, 'degenerate-repetition': 3}; retry rate 7.03%.
  - Per-unit attempt flags: empty-output=0.00%, residual-japanese=2.24%, control-scaffolding=0.00%, critical-glossary-violation=0.32%, truncated-output=0.96%, degenerate-repetition=0.64%, pathological-length=5.43%, copied-neighbour=0.00%
  - Glossary: 1/3 (33.3%), misses=['otsukaresama', 'yoroshiku-onegaishimasu']. English subtitles: not exported because the product integrity gate failed.
  - Resources: PID 43056 exited=True, pressure transitions=none, minimum available=7.62 GiB. Stages: preparing-diarization=0.0s, aligning=0.1s, translating=339.9s, preparing-asr=0.0s, diarizing=0.6s, transcribing=0.0s, normalizing-source=0.0s, preparing-alignment=0.0s.
  - Raw: `.build/benchmarks/high-quality/translator-bakeoff/translategemma-4b-it-4bit/qudu2fx3ncc/jobs/7AAC3E58-7FDB-41D8-B28D-9582ED13A546/raw-asr.json`

Representative differences:

- `185` — JA: そうですね、3つ先って強い方が勝つんですよ。 絶対に対応して勝て、
  - Reference: Well, in a first-to-three, the stronger player wins—absolutely. You have time to adapt and win.
  - 12B: That's right, in a three-game match, the stronger player usually wins. Absolutely, we must win by adapting.
  - 4B: That’s right, it’s much better to be three steps ahead. Absolutely address it and overcome it.
- `38` — JA: そうなんだよ。 すごい試合ですよ。 すごいよね。 すごいね。 すごい。 すごい、すごい。 スカッカーの時点で、あ、すごい、ス
  - Reference: It's incredible.
  - 12B: That's right. That was an incredible match. That's amazing. That's amazing. Amazing. Wow, wow. Wow, that's amazing.
  - 4B: That's what happened. This was an amazing game. That’s amazing, isn’t it? That's amazing. Amazing. Amazing!/Wow! As it stands, wow, it’s…
- `6` — JA: 最低だな。 私とクロスさんのパンツを覗いたから許せない。
  - Reference: Tachikawa peeked at my and Kuromu's underwear, you know. [laughs]
  - 12B: That's the absolute minimum. I can't forgive you for looking at my and Mr. Cross's underwear.
  - 4B: That's the lowest. Please don't show me my pants with Cross. I won't forgive you.
- `41` — JA: これ、すごいんだけど、完璧でした。
  - Reference: This is honestly moving me!
  - 12B: That was incredible, absolutely perfect.
  - 4B: This is amazing, but it was perfect.
- `87` — JA: よ、なんだ、上野世界にいるのって感じ、なんか後ろで腕組んで見てるの、なんかゲーセンでさ、ゲーム機 の後ろ見てるみたいな構図じゃない、わ、いいな、私、後ろでも見たい、ド ライブはリードしている、よ、な、し、お、あら、カマジ、
  - Reference: With him standing behind her with his arms crossed, doesn't it look like an arcade—like he's watching from behind the cabinet? That's so cool. I want to watch from back there too.
  - 12B: Oh, what's this? It feels like I'm at Ueno World, and there's someone standing behind, arms crossed, watching. It's like being at an arcade, looking at a game machine. "It's not a composition that feels like it's looking backward, but... that's lovely. I, too, want to see it from behind." The live performance is going well, isn't it? Wow, amazing!
  - 4B: Hey, it feels like I'm in a strange, almost surreal part of Ueno. There’s someone standing there, arms crossed, just watching. It’s like… a game center. This isn’t a composition that’s about looking over someone’s shoulder, you know? That’s really nice, I want to see them from behind too. This appears to be a fragmented and somewhat nonsensical expression, likely intended as a casual, emphatic statement. A possible interpretation, reflecting the feeling conveyed, would be:

“I’m really going all out, you know? Seriously, I’m giving it my all!”

(Note: Without further context, this is the most reasonable and natural English translation, prioritizing conveying the feeling of intense effort and enthusiasm.)
- `58` — JA: ランクしてるとね、でかいなって思う。 攻撘にコンボ刺されると超気持ちいいよ。
  - Reference: Yeah—when you're playing ranked, you really notice the difference.
  - 12B: It feels like they're really high up. Getting hit with a combo in a fighting game feels incredibly satisfying.
  - 4B: When you’re ranked, you start to feel really big, I think. When I get a strong, targeted attack followed by a combo, it feels incredibly satisfying.

Invalid product outputs (excluded from paired COMET/chrF++):

- `translategemma-4b-it-4bit` `unit-0029` (residual-japanese): る。
  - Output: It’s impossible to translate “る” alone. It’s a verb stem and needs context to be translated accurately. However, based on the limited information, here are a few possibilities depending on the surrounding text:

*   If it’s part of a verb conjugation: “is/are/will be/etc.” (depending on the full verb form)
*   If it’s part of a noun: “—ing” (indicating a continuous action)

Without more context, the best I can do is offer these possibilities.
- `translategemma-4b-it-4bit` `unit-0141` (residual-japanese): 達川、おしこみ、あっちで、ああ、ほら、リサルタ、あ、俺はリサールタ、そんな感じなんだ、強いな、や
  - Output: Datch川, let's go, over there, oh, look, Lisalta, ah, I'm Lisalta, it feels like this, it's really strong, yeah.
- `translategemma-4b-it-4bit` `unit-0219` (residual-japanese, truncated-output, pathological-length): めて、やる、やめる、やぶ、やむ、やん、やう、やく、やき、やけ、やこ、やか、やさ、やそ、やし、やす
  - Output: Here's the English translation of the provided Japanese words:

*   めて: First, to begin
*   やる: To do, to make, to carry out
*   やめる: To stop, to quit, to cease
*   やぶ: To tear, to rip
*   やむ: To stop, to end, to cease
*   やん: (particle) – Used to indicate a change in topic or emphasis; can also be used to soften a statement.
*   やう: To go, to move, to proceed
*   やく: To account for, to consider
- `translategemma-4b-it-4bit` `unit-0220` (residual-japanese, truncated-output, pathological-length): 、やせ、やつ、やと、やっと、やろ、やれ、やれる、やら、やられ、やられる、やな、やね、やの、やみ、
  - Output: These words are all colloquial Japanese terms related to diminutives, negation, and expressions of feeling. Here's a translation reflecting their nuances:

*   **やせ:** (diminutive) – thin, slight, frail
*   **やつ:** (diminutive) – a small amount, a bit, a little
*   **やと:** (diminutive/interjection) – (used to express surprise, doubt, or a questioning tone) – “Really?”, “Is that so?”, “You’re saying?”
*   **やっと:** (interjection) – finally, at last
*
- `translategemma-4b-it-4bit` `unit-0221` (residual-japanese): やも、やもう、やもし、やする、や来る、や来、やくる、や来た、や来て、や着、やに、やだ、やで、やて
  - Output: This appears to be a collection of forms of the verb "やる" (yaru – to do, to give, to perform). Here's a translation reflecting the various forms and their potential meanings:

“Yeah,” “Yeah,” “Yeah,” “Do,” “Come,” “Come,” “Came,” “Came,” “Wore,” “There,” “It is,” “Well,” “Hey.”
- `translategemma-4b-it-4bit` `unit-0222` (truncated-output, degenerate-repetition, pathological-length): 、やた、やった、やが、やぐ、やご、やよ、やゆ、やえ、やい、やお、やほ、やひ、やふ、やへ、やぺ、や
  - Output: These appear to be a list of Japanese onomatopoeic words. Here's a translation reflecting their sound and potential meaning:

*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-
*   Ya-

(These words represent various sounds and expressions, often used in informal speech and writing. Without context, a precise English equivalent is difficult
- `translategemma-4b-it-4bit` `unit-0224` (degenerate-repetition): やゅ、やょ、やぎ、やげ、やざ、やぜ、やず、やボタン押すで。
  - Output: Hey, hey, hey, hey, hey, hey, hey, and let's press the button.

## holdout

Paired chrF++ 4B−12B: -1.789 [95% -3.181, -0.384].
Paired COMET 4B−12B: -0.0085 [95% -0.0171, -0.0002].
chrF++ significantly favors 12B.
COMET significantly favors 12B.
COMET scorer: MPS `Scripts/comet_score_compat.py --gpus 1 --num_workers 1`, 18.91s, peak footprint 5.69 GiB, swap Δ 0.0 MiB, free memory 77%→67%.

Integrity, glossary and subtitle checks:

- `translategemma-12b-it-4bit`: verdicts {'pass': 273}; final reasons {}; all rejected-attempt reasons {}; retry rate 0.00%.
  - Per-unit attempt flags: empty-output=0.00%, residual-japanese=0.00%, control-scaffolding=0.00%, critical-glossary-violation=0.00%, truncated-output=0.00%, degenerate-repetition=0.00%, pathological-length=0.00%, copied-neighbour=0.00%
  - Glossary: not present. English subtitles: exported cues=273, empty=0, invalid timing=15, malformed blocks=1, >84 chars=46, >20 chars/s=161, max chars/s=425.0.
  - Resources: PID 45293 exited=True, pressure transitions=none, minimum available=5.39 GiB. Stages: diarizing=0.5s, preparing-asr=0.0s, transcribing=0.0s, exporting=0.0s, preparing-diarization=0.0s, aligning=0.0s, preparing-alignment=0.0s, translating=364.9s, normalizing-source=0.0s.
  - Raw: `.build/benchmarks/high-quality/translator-bakeoff/translategemma-12b-it-4bit/md62mmdz0m/jobs/F7C9230C-B366-456A-9108-7B48777E6911/raw-asr.json`
- `translategemma-4b-it-4bit`: verdicts {'pass': 265, 'hard-failure': 2, 'suspect': 6}; final reasons {'residual-japanese': 2, 'truncated-output': 1, 'pathological-length': 8}; all rejected-attempt reasons {'residual-japanese': 3, 'pathological-length': 18, 'truncated-output': 1}; retry rate 3.66%.
  - Per-unit attempt flags: empty-output=0.00%, residual-japanese=0.73%, control-scaffolding=0.00%, critical-glossary-violation=0.00%, truncated-output=0.37%, degenerate-repetition=0.00%, pathological-length=3.66%, copied-neighbour=0.00%
  - Glossary: not present. English subtitles: not exported because the product integrity gate failed.
  - Resources: PID 44867 exited=True, pressure transitions=none, minimum available=7.81 GiB. Stages: translating=263.3s, preparing-asr=0.0s, aligning=0.0s, normalizing-source=0.0s, transcribing=0.0s, diarizing=0.5s, preparing-diarization=0.0s, preparing-alignment=0.0s.
  - Raw: `.build/benchmarks/high-quality/translator-bakeoff/translategemma-4b-it-4bit/md62mmdz0m/jobs/FE5799DC-41A5-4AA4-9254-D495456C73E2/raw-asr.json`

Representative differences:

- `72` — JA: マジ？
  - Reference: Seriously?
  - 12B: Really?
  - 4B: Seriously?
- `32` — JA: サブアカやめてください。
  - Reference: Please stop using a smurf account.
  - 12B: Please stop using a secondary account.
  - 4B: Please don't go below zero.
- `224` — JA: やったよ。
  - Reference: I did.
  - 12B: Yes, I did.
  - 4B: Great! / It worked! / I did it!
- `197` — JA: これでいけるでしょ。
  - Reference: This should work.
  - 12B: That should be okay.
  - 4B: I think this should work, right?
- `194` — JA: 特にティッシュがなくて除菌シートですけど。
  - Reference: I don't have tissues nearby—only disinfecting wipes.
  - 12B: Especially because I don't have tissues, but I do have disinfecting wipes.
  - 4B: “We don’t have tissues, so we’re using hand sanitizing sheets instead.”
- `65` — JA: 私も割れてない。
  - Reference: Mine wasn't cracked either.
  - 12B: I'm not cracked either.
  - 4B: I haven’t broken it either.

Invalid product outputs (excluded from paired COMET/chrF++):

- `translategemma-4b-it-4bit` `unit-0007` (residual-japanese, truncated-output, pathological-length): ラこれおおシルバー
  - Output: This is a tricky one – “ラこれおおシルバー” is slang and likely requires context to fully understand. It’s difficult to translate literally and would sound very strange in English. However, based on common usage and slang, here are a few possible translations, depending on the intended meaning:

*   **(If referring to a specific object/thing):** “Seriously, this is really silver.” (Emphasizing the material)
*   **(If expressing disbelief/exasperation):** “Seriously, this is *way* silver.” (Highlighting the exaggeration)
*   **(More informal/col
- `translategemma-4b-it-4bit` `unit-0193` (residual-japanese, pathological-length): いじゃん。
  - Output: That depends on the context. “いじゃん” is a very informal and versatile word. It can convey a range of emotions and intentions, including:

*   **Agreement/Affirmation:** “Yeah,” “Okay,” “Right?”
*   **Emphasis/Exclamation:** “Seriously!” “You know?”
*   **A playful/teasing response:** “Come on!” “Really?”

Without more context, the best translation is: “Yeah,” “Okay,” or “Seriously?”

## Decision

Use 12B when a complete English deliverable is required: it alone completed both videos, significantly led chrF++ on DEV and holdout, and significantly led COMET on holdout.
- development: 4B was 23.3% faster and used 44.6% less peak worker memory, but failed 7/313 units and produced no English subtitle deliverable.
- holdout: 4B was 27.8% faster and used 53.8% less peak worker memory, but failed 2/273 units and produced no English subtitle deliverable.

The actual 12B SRT exports still have readability defects: DEV has 144 zero-duration cues and 1 malformed block; holdout has 15 zero-duration cues and 1 malformed block. Those timing/export limits prevent claiming production-ready subtitles from this two-video result.

Keep 4B selectable as the faster/lighter beta for constrained experimentation, with its full-job failure visible. Keep 12B as the product default; this benchmark changes no product selection.

## Provenance

Benchmark/scoring implementation hashes:

- `git-head`: `e248a12f9004c099ee234044d7b581d54b12f5c3`
- `worker-executable-at-benchmark`: `fdabfa73ea302ceec5b0220232e028e29a04a8cb7f31b3622fd1dc0274b997ed`
- `runner-at-benchmark`: `23c1c7c031c572af1b43b09e7589cafe587fca6fcf5efeeee8e3996b803901c6`
- `reporter-at-score-completion`: `b9b44f1cbb43d8acaee926ab5f6c4319fbfdf3a3b99d36b86eb72c233292a928`
- `acceptance-test-at-benchmark`: `ccbffcd43df896b8cdd94ea135bcec7775d5ef145705fde62c72b9aa57e5b5bd`
- `comet-wrapper`: `a960641d8ee345ee4026a2aca3f1ee966f38a2ca7bb61765eb514edd9828176b`
- `child-metallib`: `0d29caeba83e59e98a04cf822fdd684f5ef4b93210847a385124faf4d9353ab3`
- `final-reporter`: `8427b6de3048a223db5f317078c387581ad21028d2df0285ecdf60d47b2989d4`

The discarded DEV CPU COMET attempt produced no score and is retained under `.build/benchmarks/high-quality/translator-bakeoff/metrics/qudu2fx3ncc/rejected-cpu-comet/`; all reported COMET scores use MPS.

## Limits

E17 proves Standard SpeakerKit by pinned revision, automatic count and non-exclusive mode; its later-added configuration field is null.
Frozen E17 contains no conversation-context map, so context carry-over is not evaluated here.
Two frozen videos support workflow-specific recommendations, not universal translation superiority.

Raw prompts, outputs, retries, exports, model pins, process telemetry and scorer inputs are retained under `.build/benchmarks/high-quality/translator-bakeoff/`.
