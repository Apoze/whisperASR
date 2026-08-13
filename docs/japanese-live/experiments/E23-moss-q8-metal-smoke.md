# E23 — MOSS q8 / Metal smoke (#97)

This DEV-only smoke runs the pinned MOSS GGML port on two raw excerpts. It does
not read a reference, score quality, open the holdout, change Standard or Live,
or promote MOSS.

## Provenance

| Input | Pinned value |
|---|---|
| Port | `localai-org/moss-transcribe.cpp` @ `190a569c13b4b247450f2fb3b2a431244e84833e` (MIT) |
| ggml submodule | `eced84c86f8b012c752c016f7fe789adea168e1e` |
| Runner SHA-256 | `ccc542e611d9d7a65b1f05502d0628194f4d7053dbba25abb7a45f6f4941a807` |
| Model | `mudler/moss-transcribe.cpp-gguf` @ `54e4bbd17da3f84adf1c1bcf7791b9b9266f741e` (Apache-2.0) |
| Model file | `moss-transcribe-q8_0.gguf`, 986,881,024 bytes |
| Model SHA-256 | `ed6c35d0d527c5d03171c3eb448e2150a42c76a51e3e73aa821e351c3da8307c` |
| DEV source SHA-256 | `b61eaa577baf8d6b1d9406997ab79e7587fc97eff61b40e90fcd0c5bf5d696e1` |
| Build tool | local CMake 4.3.3 archive, SHA-256 `5221a13450c7a0219a2a0d1b6c9085eb06489721fafd8488ccebc1584175d2fb` |

Settings were `MTD_DEVICE=metal`, `MTD_THREADS=8`, q8_0, greedy raw text,
`max-new=4096`, and `GGML_METAL_NO_RESIDENCY=1`. The last setting uses ggml's
native switch to avoid a Metal residency-set teardown assertion observed on the
Apple M5 Pro; inference remains on `MTL0` and no fallback appears in either log.

## Results

Initial preparation took 2 min 37 s, including the pinned local build and model
download. The final cached preparation took 4 s.

| DEV excerpt | Audio | Raw spans | Inference | RTF | Peak footprint | Minimum available | Swap delta | Pressure | Exit |
|---|---:|---:|---:|---:|---:|---:|---:|---|---:|
| opening-multispeaker | 30 s | 10 | 4.63 s | 0.154 | 1.302 GB | 8.439 GB | 0 B | none | 0 |
| overlap-match | 22 s | 13 | 4.44 s | 0.202 | 1.302 GB | 8.134 GB | 0 B | none | 0 |

The two excerpts total 52 s of audio and 9.07 s of inference (RTF 0.174,
about 5.7x real time). Swap remained at 1,909,653,504 bytes. Every raw span is
serializable, ordered by start, non-empty, positive-duration, and bounded by its
excerpt.

Observed speech examples, without reference-based correctness claims:

- 0.29–5.25 s, S01: `続いての対象戦ですが、甘いモカそして立川来ました。`
- 5.27–6.79 s, S02: `モカさん頑張れ。`
- 0.00–1.88 s, S01: `すごいよね。`
- 1.88–3.42 s, S02: `えー！`

## Diagnosed failures

The first launch stopped before inference because CMake was absent. This was a
build-tooling failure, fixed with the pinned local archive above; nothing was
installed globally.

With default residency sets, both inferences produced complete raw output, then
ggml aborted during process teardown at `ggml-metal-device.m:622` because its
residency collection was still non-empty. The raw failure, exit 6, backtrace,
memory samples and hashes are retained. Disabling residency sets through ggml's
own environment seam produced the same raw-output hashes with clean exit 0.

The final XCTest initially reported a harness-only false negative because the
backend log is `backend: MTL0`, not the word `metal`. The validator now requires
the precise `MTL[0-9]+` form plus `use residency sets = false`; inference was not
rerun for this string-only correction. Final review also changed every candidate
gate from a non-blocking XCTest assertion to a throwing validation and writes
per-worker raw evidence before the gate, so invalid inputs or runtime evidence
can no longer produce a combined success bundle.

**Decision: GO for this bounded two-excerpt DEV smoke only.** The official
PyTorch control was not run because the diagnosed GGML runtime completed cleanly.
No holdout, full-DEV pass, UI, Standard value, or Live behavior was touched.

Raw evidence, failure evidence, build/cache provenance and test logs are under
`docs/japanese-live/experiments/evidence/E23-moss-q8-metal/`.
