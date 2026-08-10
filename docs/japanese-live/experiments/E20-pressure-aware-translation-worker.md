# E20 — Pressure-aware TranslateGemma worker

Ticket #71 replaces the fixed offline 8 GiB admission reserve from E19 with
native macOS memory-pressure signals. TranslateGemma runs in a separate process;
normal process exit is the authoritative memory-release boundary. Warning pressure
clears MLX caches and stops new offline admissions. Critical pressure cancels the
request, terminates the worker, and returns an explicit recoverable error. Live mode
keeps its existing admission policy and never uses this worker.

The authorized DEV-only smoke translated eight unique cues in one persistent worker.
It completed in 27.433 s with exit status 0 and no forced termination. Peak physical
footprint was 10,663,466,936 bytes, minimum available memory was 5,657,083,904 bytes,
no pressure transition occurred, and swap stayed at 2,975,334,400 bytes. All eight
outputs were non-empty and finished normally. This bounded smoke validates process,
memory, and structural behavior; it is not a holdout quality benchmark.

Raw evidence and exact provenance are checked in under
`docs/japanese-live/experiments/evidence/E20-worker/`.
