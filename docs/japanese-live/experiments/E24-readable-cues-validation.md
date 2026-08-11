# E24 — Readable cues validation (#105)

**Decision: NO-GO on development. Do not expose Readable cues.**

The frozen E23 policy changed 0 cues from unreadable to readable: baseline and
candidate are both 107/307 (34.9%). The 200 remaining failures require rewritten
English or timing boundaries not supported by the source alignment. This fails
the development gate, so the holdout remains closed.

Evidence is inherited without rerunning a model:

- #104 endpoint: `94bf844`.
- E23 report SHA-256: `c88f2eef06ea9a3989f36fa5e5b05540cf78381964c6e77ee9069221129acd9b`.
- E23 summary SHA-256: `17335d940b4818bdae530ed7565b699f17947c1e4c23a1622e8ce25a4042aa26`.
- `python3 -m unittest Scripts/tests/test_readable_cues.py`: 4 tests, 0 failures.
- `swift test --filter HighQualityJobTests`: 44 tests, 2 skipped, 0 failures.
- `swift test --filter LiveCaptionTests/testAdaptiveIsTheDefaultAppleTranslationMode`:
  1 test, 0 failures.
- The full `LiveCaptionTests` run reached its first MLX-dependent test, then the
  installed Xcode failed to load its default `metallib`; `xcrun --find metallib`
  independently confirms that the developer tool is absent. This is a local
  Xcode installation failure, before any #105 product change exists.

The #105 diff from `94bf844` contains only this decision report. Therefore the
request, High-quality job, UI, manifest, evidence/export paths (WebVTT and SRT),
cancellation and Live code are byte-for-byte unchanged. No option, including a
hidden or default-off option, is added.
