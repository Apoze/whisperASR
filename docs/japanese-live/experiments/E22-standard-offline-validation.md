# E22 — Standard offline validation (#77)

Standard uses 12B and SpeakerKit defaults; 4B and the three SpeakerKit beta options remain selectable and independent.

| Split | COMET baseline→candidate | chrF++ baseline→candidate | CER | DER / JER | Speaker JA error | Speakers ref/cand | Overlap P/R/F1 | Retry | Runtime | Peak | Gates |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| development | 0.4661→0.5535 | 45.44→46.44 | 81.26% | 105.47% / 85.92% | 109.94% | 13/6 | 5.0/31.5/8.6% | 0.98% | 1064s | 17.08 GiB | PASS |
| untouched-channel-separated-holdout | 0.5013→0.6067 | 29.18→49.02 | 25.77% | 58.91% / 52.28% | 57.64% | 3/3 | 0.1/6.3/0.2% | 0.00% | 909s | 17.08 GiB | PASS |

## Performance and subtitle readability

- development: total 17m 44.0s; exporting=0m 0.1s, translating=15m 41.3s, preparing-alignment=0m 1.5s, diarizing=0m 12.7s, preparing-asr=0m 4.2s, preparing-diarization=0m 5.8s, normalizing-source=0m 1.9s, aligning=0m 29.0s, transcribing=1m 8.1s. SRT/VTT 307 cues; 59 >84 characters and 224 >20 chars/s; maximum-density cue `116` is 245.83 chars/s over 0.240s: “[SPEAKER_01] "Respond from the edge of the screen as well."”.
- untouched-channel-separated-holdout: total 15m 9.0s; preparing-alignment=0m 1.5s, transcribing=0m 55.1s, preparing-asr=0m 4.2s, aligning=0m 18.4s, normalizing-source=0m 1.6s, translating=13m 33.9s, diarizing=0m 8.3s, exporting=0m 0.1s, preparing-diarization=0m 5.8s. SRT/VTT 260 cues; 58 >84 characters and 175 >20 chars/s; maximum-density cue `92` is 237.50 chars/s over 0.080s: “[SPEAKER_02] "Huh?"”.

## development interpretations

- COMET: Δ +0.0874 — improved. Translation meaning changed; inspect recovered/lost speech examples below.
- chrFPlusPlus: Δ +1.0002 — improved. English wording/reference overlap changed; inspect cue examples below.
- DERPercent: Δ +0.0000 — unchanged. Speaker attribution changed with 6 candidate vs 13 reference speakers.
- JERPercent: Δ +0.0000 — unchanged. Per-speaker temporal coverage changed; lower is better.
- speakerAttributedJapaneseErrorPercent: Δ +11.5089 — regressed. 3286 Japanese character edits remain under mapped speaker identities.
- overlapF1Percent: Δ +0.0000 — unchanged. Overlap detection missed 17.455s and invented 153.483s.

Representative speech:

- recovered `199`: JA “まだね、次の試合ありますから。” → candidate “Yes, thank you very much. There's still another match coming up, so...” (reference “There is still another match coming up.”, baseline “Thank you very much.

(Still, we have the next match ahead of us.) Yes, thank you.
We'll try the next one.”, observed=true).
- lost `13`: JA “めっちゃ仲良くなってるやん。” → candidate “...or something like, "It's probably best if you do it," or "You should probably do it." They're getting along really well, aren't they?” (reference “They've become really close.”, baseline “It was something like, "It's definitely you, Ren, right?" or "It has to be you." We're really close. Speaker 03:
Me.”, observed=true).
- mistranslated `32`: JA “リーサルだー！ ドーーーン!!!” → candidate “” (reference “It's lethal! BAAAM!!!”, baseline “Yes. Yes. Yes.”, observed=true).

## untouched-channel-separated-holdout interpretations

- COMET: Δ +0.1054 — improved. Translation meaning changed; inspect recovered/lost speech examples below.
- chrFPlusPlus: Δ +19.8367 — improved. English wording/reference overlap changed; inspect cue examples below.
- DERPercent: Δ +0.0000 — unchanged. Speaker attribution changed with 3 candidate vs 3 reference speakers.
- JERPercent: Δ +0.0000 — unchanged. Per-speaker temporal coverage changed; lower is better.
- speakerAttributedJapaneseErrorPercent: Δ -4.3930 — improved. 2165 Japanese character edits remain under mapped speaker identities.
- overlapF1Percent: Δ +0.0000 — unchanged. Overlap detection missed 1.658s and invented 92.656s.

Representative speech:

- recovered `213`: JA “飛んでったの？” → candidate “"Did it fly away?"” (reference “Did it fly away?”, baseline “It's not flying. It's not flying. It's not flying.

Yes, it isn't.”, observed=true).
- lost `34`: JA “やば。” → candidate “” (reference “That's bad.”, baseline “"That's rough."”, observed=true).
- mistranslated `34`: JA “やば。” → candidate “” (reference “That's bad.”, baseline “"That's rough."”, observed=true).

**Decision: validated-standard-offline-workflow.**

Two complete supplied videos validate only this offline workflow; they do not prove universal anime, VTuber, gaming, conversation, speaker, or overlap quality.
