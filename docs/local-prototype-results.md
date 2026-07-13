# Local English prototype result

Date: 2026-07-13. Corpus: 40 seconds of the same Firefox capture for every
engine, 16 kHz mono PCM, SHA-256
`c51b6fa61d0f769382efb4d23c21c9c35ddad2e5edaf046e03358bbcad740af8`.
The opt-in benchmark split it into two contiguous 20-second passages and kept
previews disabled.

| Pipeline | Passage 1 | Passage 2 | Resident memory observed |
|---|---:|---:|---:|
| Whisper Large v3 Turbo → Apple high fidelity | 2045 ms | 1983 ms | 1.93 GB |
| FireRedVAD + Qwen3-ASR 1.7B → Apple high fidelity | 2437 ms | 2734 ms | 2.82 GB |
| Nemotron + Qwen3-ASR 1.7B → Apple high fidelity (initial run) | 3260 ms | 2631 ms | 2.70 GB |
| Granite Speech 4.1 2B Q8 direct | 2186 ms | 1213 ms | 3.42 GB |

Granite failed the qualitative elimination rule. It hallucinated a different
topic in passage 1 and reduced passage 2 to “Thank you very much”, omitting the
dialogue. Its runtime, model option, and helper were therefore removed.

Turbo and Qwen both preserved the broad meaning. Turbo correctly recognized
the program name “Easy Japanese”; Qwen rendered it as “E.G. Japanese”.

The production loop was then tested on the same 40-second video window with
previews disabled. Both engines kept their real FIFO wait below 25 ms and
flushed the final phrase. Turbo produced four coherent subtitles, preserved the
presenter's name better, and emitted no filler-only lines. Qwen produced seven
subtitles, mistranscribed the name and emitted two spurious “Ah.” lines. Its
estimated median stable latency was lower (about 1.5 s versus 2.0 s), but its
p95 was higher (about 2.5 s versus 2.2 s).

Nemotron advanced none of the seven measured endpoints: every
`vadOnlyEndpointAt - endpointDetectedAt` value was zero. It therefore added
roughly 612 MB and continuous inference without improving this corpus. The
product pipeline was simplified to FireRedVAD → Qwen → Apple, while Turbo →
Apple remains the recommended default. Qwen stays available as an experimental
lower-median-latency mode; it did not beat Turbo on the quality-first decision
criteria.

Raw generated reports live under `.build/benchmarks` and are intentionally not
tracked by Git.
