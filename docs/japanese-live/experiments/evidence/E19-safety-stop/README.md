# E19 safety stop

The first ticket #62 development run was stopped before holdout and before COMET because the real 8 GiB system reserve was not preserved.

Two earlier attempts stopped in preflight, before any model: the isolated worktree lacked its COMET venv, then its derived local-reference locators. `infrastructure-preflight.log` records the narrow verified fallbacks; neither event was classified as model quality.

At 13:54:54 +0200, 301 seconds after the real acceptance xctest launched, the single xctest process had a 17.2 GiB physical footprint (17.3 GiB peak) on a 24 GiB machine, while `memory_pressure` reported 8% free. The process and runner were stopped; free memory returned to 82%.

The frozen run of the same development video places TranslateGemma loading about 177 seconds after xctest launch. Qwen ASR, forced alignment, and SpeakerKit normally finish before that point. The observed 301-second sample therefore occurred during the TranslateGemma stage (preparation or generation). The 16.9 GiB IOAccelerator allocation was held by the single xctest process, but the retained process sample cannot prove that earlier in-process model allocations had all been released. This stage attribution is an inference from frozen timings because xctest buffered live stage output.

No `manifest.json` exists for the interrupted job: SIGINT terminated xctest before the job's catch/finalization path serialized it. The empty job directory is intentionally retained in the ignored benchmark workspace. `development-run-meta.json` and `development-run.log` are the raw metadata/log available from the stopped job.

Hashes of retained inputs:

- `corpus-preflight.tsv`: `a9673e06ed52b7f58da20ad049deb1db59d34d50eedfe7bc4567609943d3fb39`
- `controls.json`: `7bc67435f96c34fadd0874012caace14a8e6fbba8afe87b296c6f8f2bf9e62f4`
- `light-tests.log`: `f895d6ac9ea51b34fd07548f0b07d29ba66fc522a9eca241506c30c6587e224f`
- `real-cancellation.log`: `4e798d57db28038621ef3e0994d203d3913a73c68be1dd7e0c1fabeaddebeb63`
- `development-run-meta.json`: `c3959cb46fd335ec94a43b44e759ec549ba78db8a1df7586c81618866d896404`
- `development-run.log`: `1fb28a4386f423e9867aa2065ff7483e1b0471037774d0e6284aee92c657353d`

This is a runner/safety failure, not a model-quality result. Development quality was not scored, holdout stayed closed, and no product candidate was promoted.

## Bounded TranslateGemma smoke

After adding the runtime watchdog, an authorized development-only smoke requested the first eight frozen cues with `previous-accepted-v1` context. It stopped during model preparation after 10.9 seconds, before any cue completed. A per-cue MLX cache clear therefore had no supporting evidence and was not retained:

- process footprint: 7,098,193,728 bytes (below the 16 GiB process ceiling);
- system memory available: 7,995,981,824 bytes (below the 8 GiB reserve);
- MLX generation peak: unavailable because generation never started;
- unload was requested, but the in-process release check still measured 7,212,767,088 bytes after its five-second timeout, above the 558,875,440-byte handoff ceiling;
- process exit restored system free memory to 84%.

The watchdog therefore failed closed as designed, but in-process cleanup did not release memory quickly enough to hand the gate to Live. No full development rerun is admissible on this 24 GiB machine under the frozen 8 GiB reserve.

Retained smoke artifact SHA-256: `0bb40800bfc8f2e8a0254b8851d65671e382589ad0e46a08711bb5119763c3c8`.
Its legacy combined `failure` field duplicated the cleanup error. The original is unchanged; `translategemma-memory-smoke-classification.json` binds the raw artifact and XCTest log by SHA-256 and records the primary reserve violation separately from the cleanup/release failure.

The smoke ran from an uncommitted watchdog prototype and did not record its implementation hash. Later changes only made the gate more conservative (removing double-counted available-memory pages and making slot/holdout preconditions blocking). The smoke is sufficient evidence for this safety NO-GO, but it is not promotion-grade implementation provenance.

`model-weight-verification.json` records a post-run SHA-256 verification of the exact pinned revisions and eight weight files for the combined candidate. Future admissible runs regenerate and hash this manifest before scoring; the reporter rejects missing, extra, stale, or mismatched weights.
