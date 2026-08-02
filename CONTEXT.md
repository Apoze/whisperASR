# Live Japanese Captions

This context covers local Japanese-to-English live captions and the evidence used to choose their production configuration.

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
The two supplied full-video Japanese/English reference transcripts, accepted as authoritative by the repository owner. Other versioned corpora remain diagnostic and cannot promote a pipeline.
_Avoid_: Every versioned corpus, pending human review
