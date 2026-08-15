# E32 — Readable English subtitle reflow (#120)

**Decision: GO for a default-off High-quality Bêta option. Live is unchanged.**

The E23/E24 budgets remain unchanged: 42 characters per line, 2 lines, 1–7
seconds and 20 CPS. E32 can now split at retained Japanese pause, punctuation
or source-cue timestamps from #116. English words and order never change.

| Split | Readable | >84 chars | >20 CPS | <1 s | >7 s |
|---|---:|---:|---:|---:|---:|
| DEV baseline | 119/307 | 37 | 156 | 74 | 11 |
| DEV candidate | 141/318 | 29 | 156 | 74 | 3 |
| Holdout baseline | 97/260 | 41 | 129 | 65 | 17 |
| Holdout candidate | 146/286 | 21 | 129 | 65 | 2 |

DEV rehabilitates 11 source cues; holdout rehabilitates 23. Every replacement
is a complete all-budget partition. The remaining 177 DEV and 140 holdout
sources stay unchanged and are audited as unresolved.

All exact gates pass: normalized English, word order, source timing coverage,
inter-cue gaps, Speaker metadata, Speaker on/off equivalence, zero new overlap,
and identical SRT/VTT timestamps. The exact tests took 0.411 s on DEV and
0.624 s on holdout (10.27 s and 2.15 s wall time). No model was loaded.

Cancellation is checked inside the partition DP, immediately before returning
its result, and at the High-quality export boundary. A deterministic late
cancellation on the final cue leaves the previous completed result unchanged.
The explicit Live gate enables the offline Bêta request while retaining the
original Live mode and adaptive Apple translation defaults; the source diff
contains only the three High-quality/readable-cue files.

The 12B retained evidence is quality-scored. The structural replay matrix
explicitly covers 12B and 4B, DEV and holdout, with Speaker both on and off.
The 4B translations are not quality-scored because their E31 validation
failures are upstream of this reflow.

This is a prospective revalidation, not a retroactive blind-holdout claim.
Commit `c44df8420e830f8014473b9e6135969c8439ceea` contains only the DEV proof
and frozen budgets (SHA-256
`dac12f6f75baf1702fa7a0e5c953135365f7b1625045e1c8dbb19a7ab82418a8`).
The exact holdout and Live replays were then run from that commit and their
raw logs archived. Full metrics, provenance, gates and routing are in
`evidence/E32-readable-cues/report.json`. Its contract binds implementation
commit `6f74780974264d08ad4382ce5c94ab44a7ea85f1`, the freeze parent and paths,
every JSON schema/key, source/test/harness blobs, replay inputs and archived
log hashes; silent drift fails the test suite.
