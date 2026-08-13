# E24 — MOSS long-form runtime research (#98)

Research date: 2026-08-12. Scope: official OpenMOSS sources and the pinned
`localai-org/moss-transcribe.cpp` port used by #97. No model was run for this
research and the holdout remained closed.

## Decision

**NO-GO on this machine for the complete DEV spans-only run.** The authorized
q8/Metal run failed from a Metal out-of-memory error before producing a span.
The audited runtimes expose neither documented incremental audio inference with
stable recording-wide speaker labels nor a documented q8/Metal memory setting
that makes the same full-recording inference smaller. No additional heavy run
is justified without a new authorization and a materially different hardware
or upstream-runtime capability.

This is a hardware/runtime NO-GO, not a negative quality result. The only
positive MOSS evidence remains #97's two bounded DEV excerpts.

## Why external chunking is not equivalent

OpenMOSS defines `[S01]`, `[S02]`, etc. as anonymous labels **relative to the
input audio**, not real identities. Its documented long-form mode is one-pass
inference, with a 128k context for inputs up to 90 minutes. Therefore, running
separate audio excerpts creates separate label namespaces; the official sources
give no rule or guarantee for reconciling `Sxx` across requests. That would no
longer be the requested spans-only substitution with one global speaker
identity space.

Sources:

- [Official model card: single-pass, up to 90 minutes](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize#model-card-for-openmoss-teammoss-transcribe-diarize)
- [Official model card: speaker labels are relative to the input audio](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize#output-format)
- [Technical report v7: 128k context and up to 90-minute inputs](https://arxiv.org/abs/2601.01554v7)

## Official Python path

The reference implementation is whole-input inference, not streaming audio:

1. `process_audio_info` loads each complete waveform.
2. `prepare_inputs` builds all input features and all audio placeholders.
3. `_chunk_audio` divides the waveform into 30 s encoder chunks, but
   `_audios_to_input_features` stacks every chunk and concatenates every feature
   batch before model execution.
4. `get_audio_features` runs the encoder on that full chunk tensor, concatenates
   the results per recording, and returns one audio feature sequence.
5. `generate_transcription` calls `model.generate` once for that sequence.

The `ProgressStreamer` in `inference_utils.py` only counts output tokens from
`generate(streamer=...)`; it is not an incremental audio-input API and does not
establish cross-request speaker identity.

Sources:

- [`inference_utils.py`: full waveform loading, input preparation and one `generate`](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize/blob/main/moss_transcribe_diarize/inference_utils.py)
- [`processing_moss_transcribe_diarize.py`: 30 s chunk stacking and concatenation](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize/blob/main/moss_transcribe_diarize/processing_moss_transcribe_diarize.py)
- [`modeling_moss_transcribe_diarize.py`: per-recording feature concatenation](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize/blob/main/moss_transcribe_diarize/modeling_moss_transcribe_diarize.py)

## Pinned q8/Metal port used by #97

The pinned port at
`190a569c13b4b247450f2fb3b2a431244e84833e` already performs the only
sequential step it implements: it encodes 30 s chunks one after another. It then
accumulates all encoder frames, applies the adaptor to the concatenation, fuses
one complete input sequence, allocates a decoder KV cache sized from the full
sequence plus `max_new`, and pre-fills the decoder in one call. This preserves a
single recording-wide context, but it is not bounded-memory streaming.

The transcribe CLI exposes only `--max-new` and output format. Lowering
`--max-new` can truncate the generated transcript; it is not an OOM remedy for
the full audio prefill. `MTD_THREADS` tunes CPU performance, and `MTD_DEVICE`
selects a backend; neither is documented as reducing memory for the pinned
Metal inference. The source contains an auto-detection helper for flash
attention with an option to disable it, but the pinned Qwen path always builds
eager attention and does not call that helper. There is no exposed prefill
chunk-size, KV-cache type, offload, or audio-stream state option.

Sources pinned to the evaluated revision:

- [`audio_encoder.cpp`: sequential 30 s encoding followed by full concatenation](https://github.com/localai-org/moss-transcribe.cpp/blob/190a569c13b4b247450f2fb3b2a431244e84833e/src/audio_encoder.cpp)
- [`transcribe.cpp`: one fused sequence and one global generation](https://github.com/localai-org/moss-transcribe.cpp/blob/190a569c13b4b247450f2fb3b2a431244e84833e/src/transcribe.cpp)
- [`qwen3_decoder.cpp`: full-sequence KV allocation and one-call prefill](https://github.com/localai-org/moss-transcribe.cpp/blob/190a569c13b4b247450f2fb3b2a431244e84833e/src/qwen3_decoder.cpp)
- [`qwen3.cpp`: eager attention materializes full score/softmax tensors](https://github.com/localai-org/moss-transcribe.cpp/blob/190a569c13b4b247450f2fb3b2a431244e84833e/src/qwen3.cpp)
- [`cli.cpp`: only `--max-new` and `--format` for transcription](https://github.com/localai-org/moss-transcribe.cpp/blob/190a569c13b4b247450f2fb3b2a431244e84833e/src/cli.cpp)
- [Pinned README: 30 s chunks are concatenated into one autoregressive stream](https://github.com/localai-org/moss-transcribe.cpp/blob/190a569c13b4b247450f2fb3b2a431244e84833e/README.md)

## Memory settings found, but not applicable

OpenMOSS documents SGLang Omni with `--mem-fraction-static 0.80`, but explicitly
targets CUDA 13. That setting controls a different serving runtime using the
official checkpoint, not the pinned q8/Metal port, so adopting it would change
the evaluated runtime/precision and cannot rescue this experiment unchanged.
The same official instructions still send one complete audio file per request.

The port documents smaller quantizations and CPU backend selection. Changing
q8 to another quantization changes the candidate, while switching to CPU has no
documented guarantee of lower peak memory for full DEV and would require a new
heavy run. Neither is a validated same-variable workaround.

Source: [official OpenMOSS SGLang/CUDA serving command](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize#serve-with-sglang-omni).

## Local evidence boundary

The authorized 957.208 s DEV candidate reached the pinned q8 model on `MTL0`
and failed after 14.355 s with
`kIOGPUCommandBufferCallbackErrorOutOfMemory`. It exited 1 without forced
termination or raw spans. Peak process footprint was 3,010,628,296 bytes;
minimum sampled available memory was 2,656,157,696 bytes; swap rose from
1,909,653,504 to 2,721,382,400 bytes. This diagnoses a candidate runtime OOM,
not a build, runner, input, or reference failure.

Raw local evidence retained under `.build/benchmarks/moss-spans-98/run/moss/`:

| Artifact | SHA-256 |
|---|---|
| `worker-evidence.json` | `061424b81ce2c5cedf2a4d5eba9c127a2f2b2e08a95eff5bc8b0f9d4c6f317fb` |
| `worker-stderr.log` | `4a1ea0b51c88735f68fe4adb736f50f28f4d2df3533bf8ac5ab1572e9bd0d826` |
| `full-development.wav` | `494577ab9ba0b9af05f1a872bf03afcfeda118c76ab299d40071893cb37e38f2` |

#97 remains the sole positive result: two DEV excerpts totaling 52 s completed
with ordered, bounded, serializable spans, 1.302 GB peak footprint, no memory
pressure and no swap increase. It proves bounded q8/Metal execution only; it
does not make the complete DEV spans credible.

Source: [`E23-moss-q8-metal-smoke.md`](E23-moss-q8-metal-smoke.md).

## Authorization consequence

`#99` is **not authorized** from this evidence. Complete DEV produced no
candidate spans, so content attribution, speaker mapping, overlap, DER, JER and
F1 cannot be evaluated. No quality conclusion should be inferred from the OOM
or from the two short #97 excerpts.
