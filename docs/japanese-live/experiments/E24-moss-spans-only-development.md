# E24 — MOSS spans-only on full DEV (#98)

MOSS was evaluated only as a source of diarization spans and anonymous labels.
The existing principal-attribution seam keeps one label per frozen Qwen
alignment item, records raw overlap separately, and never duplicates text.
Audio, Qwen, segmentation, alignment, translation, glossary, exports and
references were frozen. The holdout and UI remained closed.

## Run boundary

The approved command was run with the pinned #97 q8/Metal runner and model:

```bash
BENCHMARK_SLOT_GRANTED=98 bash Scripts/run_moss_spans_experiment.sh run
```

Preflight passed the build, runner, DEV input and E22 reference checks. The
canonical 957.208 s WAV matched SHA-256
`494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2`.
The frozen E22 raw evidence matched
`6060f830c8c3b8febb186c540e992f3d70375a674adb4d48087f77e1ce97c2b2`.

The candidate then failed after 14.355 s on `MTL0` with
`kIOGPUCommandBufferCallbackErrorOutOfMemory`, before emitting any token or
span. Exit was 1 without forced termination. Peak process footprint was
3,010,628,296 bytes, minimum sampled available memory 2,656,157,696 bytes, and
swap increased by 811,728,896 bytes.

Two earlier pre-candidate harness failures were diagnosed separately: the CLI
help probe treated the runner's documented exit 2 as a mismatch, and the first
audio downmix differed from E22. The probe was made exit-code independent and
the exact E22 canonicalization was reused. Neither failure reached MOSS.

## Quality result

| Question | Full DEV result |
|---|---|
| Credible MOSS spans | No candidate spans; not assessable |
| Correct / incorrect / unattributed content | Not assessable; no Qwen item received a MOSS label |
| Representative full-DEV examples | None; raw output is empty |
| Speaker count or identity mapping | Not assessable |
| Raw overlap | Not assessable |
| DER / JER / overlap F1 | Not computed; reporting zero would be false |
| Text duplication | No candidate to score; not evidence of success |

The only positive MOSS evidence remains #97's bounded 52 s DEV smoke: ordered,
bounded spans, 1.302 GB peak and clean Metal exits. Its observed excerpts
included `S01` at 0.29–5.25 s and `S02` at 5.27–6.79 s in the opening sample,
and `S01` at 0.00–1.88 s followed by `S02` at 1.88–3.42 s in the overlap sample.
Those observations prove execution and parseability only, not reference-based
speaker correctness or full-recording identity stability.

The official model is documented as one-pass long-form inference with speaker
labels relative to the input. The pinned port sequentially encodes 30 s audio
chunks but concatenates all features into one decoder context; it exposes no
documented bounded-memory streaming mode with stable recording-wide identity
and no applicable q8/Metal memory setting. External chunking would create
independent speaker namespaces and change the evaluated variable. Details and
primary sources are in
[`E24-moss-runtime-long-form-research.md`](E24-moss-runtime-long-form-research.md).

**Decision: NO-GO matériel pour MOSS spans-only sur le DEV complet de cette
machine.** This is not a negative quality result: quality could not be measured.
Issue #99 is not authorized because no complete candidate mapping exists. A new
heavy run requires explicit approval plus materially different hardware or an
upstream runtime that preserves global speaker identity with bounded memory.

Raw committed evidence is under
`docs/japanese-live/experiments/evidence/E24-moss-spans-only/`; the complete
local artifacts remain under `.build/benchmarks/moss-spans-98/`.
