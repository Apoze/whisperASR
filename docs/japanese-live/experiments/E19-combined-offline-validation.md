# E19 — Combined offline candidate

Only #55 `previous-accepted-v1` was independently eligible. #54, #56 and #57–#61 keep their recorded baseline/NO-GO behavior.

## Result

**NO-GO safety on development. No promotion.**

| Check | Result |
|---|---:|
| Real DEV physical footprint at stop | ~17.2 GiB |
| Real DEV system memory free | 8% |
| Bounded TranslateGemma smoke | stopped at 10.9 s, 0/8 cues |
| Smoke footprint peak | 6.61 GiB / 16 GiB ceiling |
| Smoke minimum system available | 7.45 GiB / 8 GiB reserve — FAIL |
| Smoke MLX generation peak | unavailable; generation never began |
| In-process post-unload memory | 6.72 GiB / 0.52 GiB handoff ceiling — FAIL |
| After xctest exit | 84% free |
| Holdout / COMET / Live gates | not run |

The first real DEV run was stopped when direct observation showed the true reserve was violated. A subsequent eight-cue, TranslateGemma-only smoke with the new 100 ms watchdog failed closed during model preparation. Unload was requested, but memory did not return under the safe handoff ceiling within five seconds, so the model gate correctly remained closed and did not claim Live could reacquire it.

The product change is limited to enforcing the real runtime memory reserve and telling the user to quit and reopen WhisperASR if release fails. No ASR, translation, diarization, speaker, overlap, or default candidate is promoted.

Raw evidence is retained in `docs/japanese-live/experiments/evidence/E19-safety-stop/`. The earlier COMET-path and derived-reference preflight failures are explicitly classified as infrastructure, not model quality.

Any future rerun remains fail-closed: SpeakerKit must strictly improve speaker-attributed Japanese error with zero invented overlap, and all four pinned revisions plus eight real weight hashes must match before promotion can be considered.

Two supplied videos were not scored in E19: development stopped on safety and the untouched channel-separated holdout stayed closed. This does not prove universal anime, VTuber, gaming, conversation, speaker, or overlap quality.
