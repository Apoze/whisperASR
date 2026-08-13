# Japanese Captions

This context covers local Japanese-to-English live captions, high-quality offline processing and the evidence used to evaluate them.

## Language

**JA→EN pipeline**:
A complete capture-to-caption configuration evaluated end to end as one candidate.
_Avoid_: Engine, model

**Preview**:
Mutable, low-latency caption text that may be revised and is never authoritative for audio retention.
_Avoid_: Draft final

**Final**:
Immutable, ordered caption text whose processing alone authorizes release of its retained audio.
_Avoid_: Stable preview

**Promotion**:
The evidence-backed choice of a JA→EN pipeline after every veto gate passes on the declared reference corpus and machine; otherwise the current baseline remains selected.
_Avoid_: Best average score, shortlist

**Decision corpus**:
The two supplied full-video Japanese/English reference transcripts, accepted as authoritative without later human review. No other video or corpus may decide a promotion in this effort.
_Avoid_: Every versioned corpus, pending human review

**Domain slice**:
An overlapping evaluation view labelled by vertical (`Anime` or `VTuber`) and speech mode (`Gaming` or `Conversation`). A slice without local reference coverage cannot support a Promotion.
_Avoid_: Exclusive content category, pooled domain score

**Video/channel holdout**:
A complete Decision corpus video kept out of candidate tuning whose channel is also absent from the development fold. If the local corpus cannot provide that separation, the result is diagnostic rather than promotional.
_Avoid_: Random segment split, tuned test set

**Candidate failure**:
A failed gate attributed to the tested variable only after baseline controls exclude the build, application, runner, input and reference as the root cause.
_Avoid_: Any failed test, unexplained model failure

**Glossary budget**:
A predeclared ceiling on glossary entries, encoded size and runtime cost that preserves specialized-term coverage without increasing false deterministic corrections.
_Avoid_: Unlimited vocabulary list, shortest glossary

**High-quality job**:
One offline processing run over a source file or public YouTube URL that produces the user-selected transcript and subtitle deliverables without changing Live Japanese Captions.
_Avoid_: Live pipeline, second application

**Deliverable**:
A transcript or subtitle file explicitly requested by the user. Intermediate and raw evidence may be retained without becoming Deliverables.
_Avoid_: Every generated artifact, processing stage

**Subtitle cue**:
A timed display unit containing translated text and, when requested, a Speaker label.
_Avoid_: ASR segment, arbitrary text chunk

**Speaker label**:
A stable anonymous identifier for one inferred voice within a High-quality job; it does not assert a real-world identity.
_Avoid_: Speaker name, voice identity

**Offline acceptance corpus**:
The two supplied full-video references, including Japanese, English, timing and speaker evidence, used to compare offline candidates. Results on this corpus validate the initial feature only and do not establish general quality across all domains.
_Avoid_: Universal benchmark, Live promotion corpus
