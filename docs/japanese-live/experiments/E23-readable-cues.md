# E23 — Readable cues on frozen E22 English (#104)

Budgets and aligned-boundary policy were frozen in commit `f3181b6` before this single DEV scoring run: 42 characters/line, 2 lines/cue, 1–7 seconds and 20 characters/second.

- Baseline: 107/307 readable cues (34.9%).
- Candidate: 107/307 readable cues (34.9%).
- Frozen source cues made fully readable: 0.
- Remaining impossible candidate cues without rewriting or unaligned time: 200.
- Scoring: 0.043s; peak runner memory 58.7 MiB; no model loaded.

## Concrete DEV examples

- None: E22 provides no aligned English boundary inside a source cue.

## Still impossible without rewriting

- `readable-unit-0001-01` (3.04s, 22.7 cps): “Sweet Moka = Amayui Moka The next target is Sweet Moka and Tachikawa.” — reading-speed.
- `readable-unit-0002-01` (0.48s, 18.7 cps): “I'm here.” — minimum-duration.
- `readable-unit-0005-01` (4.12s, 18.4 cps): “Someone in GTA was looking at people's faces. I really hope they get banned.” — length.

Exact normalized English and word order are identical. Speaker labels are metadata; matching Speaker-off SRT/VTT exports prove the same timing and text. The resegmenter contract accepts only text, timing and optional Speaker metadata; its 12B/4B compatibility is structural, not a second quality score. No option is promotable from this DEV result; holdout remains closed.
