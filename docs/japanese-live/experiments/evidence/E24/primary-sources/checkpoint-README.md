---
license: other
base_model: Qwen/Qwen3-ASR-1.7B
datasets:
- litagin/Galgame_Speech_ASR_16kHz
language:
- ja
pipeline_tag: automatic-speech-recognition
library_name: transformers
tags:
- qwen3-asr
- automatic-speech-recognition
- japanese
- galgame
- anime
- visual-novel
- full-finetune
---

# Qwen3-ASR-1.7B-JA-Anime-Galgame

This is a full fine-tuned checkpoint of [Qwen/Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) for Japanese galgame, visual novel, and anime-style speech recognition.

The model was fine-tuned on [litagin/Galgame_Speech_ASR_16kHz](https://huggingface.co/datasets/litagin/Galgame_Speech_ASR_16kHz), a large Japanese galgame speech ASR corpus. This repository includes both inference weights and training recovery files so that others can resume training or continue domain adaptation.

The current checkpoint is intended as a domain-tuned Japanese ASR model. A small external benchmark is included below, comparing this model against the upstream Qwen3-ASR base models on both game/anime-style audio and compact general Japanese ASR sanity sets.

## Intended Use

This model is intended for Japanese ASR in speech with galgame or anime-like delivery, including:

- visual novel and game voice transcription
- subtitle generation workflows
- Japanese character dialogue with expressive voice acting
- research on domain adaptation from general ASR models to anime-style speech

It is not yet validated as a general-purpose Japanese ASR model. For broad Japanese speech, compare against the original base model before production use.

## Training

- Base model: [Qwen/Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)
- Fine-tuning type: full SFT / full checkpoint fine-tune
- Training dataset: [litagin/Galgame_Speech_ASR_16kHz](https://huggingface.co/datasets/litagin/Galgame_Speech_ASR_16kHz)
- Checkpoint step: 29239
- Epoch: 1.0
- Last recorded internal eval loss: 0.1265 at step 29000

The eval loss above comes from the training run's internal evaluation split. It should not be treated as an external benchmark score.

## Evaluation

### Fixed 800-Clip Benchmark

The following numbers are from a fixed 800-clip Japanese ASR evaluation set sampled with seed `20260531`. The set contains 200 clips from each source:

| source | dataset | split | clips | duration |
|---|---|---|---:|---:|
| Nekopara | `grider-transwithai/nekopara-speech` | train | 200 | 991.0s |
| Anime Speech | `joujiboi/japanese-anime-speech` | train | 200 | 1053.5s |
| JSUT Basic5000 | `japanese-asr/ja_asr.jsut_basic5000` | test | 200 | 1067.4s |
| Common Voice 8.0 JA | `japanese-asr/ja_asr.common_voice_8_0` | test | 200 | 996.4s |

Total: 800 clips, 4108.3s audio, 17354 reference characters.

Metric: strict character error rate (CER) after removing whitespace and common Japanese/ASCII punctuation. `S`, `I`, and `D` are substitution, insertion, and deletion rates divided by reference characters. The same decoding and normalization were used for all models.

| model | rows | CER | S | I | D |
|---|---:|---:|---:|---:|---:|
| `Qwen/Qwen3-ASR-0.6B` | 800 | 0.1673 | 0.1025 | 0.0214 | 0.0434 |
| `jaykwok/Qwen3-ASR-0.6B-JA-Anime-Galgame` | 800 | 0.1438 | 0.0962 | 0.0228 | 0.0249 |
| `Qwen/Qwen3-ASR-1.7B` | 800 | 0.1437 | 0.0851 | 0.0169 | 0.0418 |
| `jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame` | 800 | 0.1285 | 0.0812 | 0.0231 | 0.0242 |

CER by source:

| model | Nekopara | Anime Speech | JSUT | Common Voice |
|---|---:|---:|---:|---:|
| `Qwen/Qwen3-ASR-0.6B` | 0.2900 | 0.1244 | 0.1297 | 0.1552 |
| `jaykwok/Qwen3-ASR-0.6B-JA-Anime-Galgame` | 0.2392 | 0.0811 | 0.1207 | 0.1568 |
| `Qwen/Qwen3-ASR-1.7B` | 0.2803 | 0.1091 | 0.0948 | 0.1269 |
| `jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame` | 0.2276 | 0.0799 | 0.0998 | 0.1312 |

For this 1.7B checkpoint, full SFT improves overall CER from 0.1437 to 0.1285, a 10.6% relative reduction. The largest improvement is deletion reduction, from 0.0418 to 0.0242. In-domain gains are stronger: Nekopara CER improves by 18.8% relative, and Anime Speech CER improves by 26.8% relative. JSUT and Common Voice are slightly worse than the 1.7B base in this small sample, so this checkpoint should still be treated primarily as a galgame/anime-domain model rather than a general Japanese ASR upgrade.

These numbers are a small reproducible sanity benchmark, not a comprehensive public leaderboard. Strict character CER can over-penalize kana/kanji variants, long-vowel spelling, expressive writing, and transcript style differences.

### Additional Evaluation Candidates

Recommended additional evaluation sets:

- [ntaquan0125/steinsgate-voice](https://huggingface.co/datasets/ntaquan0125/steinsgate-voice), a relatively small STEINS;GATE visual novel voice dataset with Japanese audio and text, if access and licensing are acceptable
- [grider-transwithai/nekopara-speech](https://huggingface.co/datasets/grider-transwithai/nekopara-speech), a public visual-novel/game voice dataset with Japanese transcriptions and character metadata
- [joujiboi/japanese-anime-speech](https://huggingface.co/datasets/joujiboi/japanese-anime-speech), a smaller anime/visual-novel ASR dataset than `japanese-anime-speech-v2`
- [makiligon/Blue-Archive-Japanese-Voicelines](https://huggingface.co/datasets/makiligon/Blue-Archive-Japanese-Voicelines), a small game voice-line collection; verify that usable transcripts are available before using it for CER
- [japanese-asr/ja_asr.common_voice_8_0](https://huggingface.co/datasets/japanese-asr/ja_asr.common_voice_8_0), a small general Japanese ASR sanity set
- [japanese-asr/ja_asr.jsut_basic5000](https://huggingface.co/datasets/japanese-asr/ja_asr.jsut_basic5000), a compact read-speech Japanese benchmark

For a larger follow-up benchmark, use a fixed sample instead of evaluating every available hour. A practical next pass would be:

| dataset | domain | suggested subset | reason |
|---|---|---:|---|
| `ntaquan0125/steinsgate-voice` | visual novel | 500-2000 clips | small, strongly in-domain, but check access/license first |
| `grider-transwithai/nekopara-speech` | visual novel/game voice | 500-2000 fixed random clips | relevant character voice with metadata; use the full distribution unless you need content filtering |
| `joujiboi/japanese-anime-speech` | anime/VN dialogue | 1000-3000 fixed random clips | broader anime-style speech; full set is larger, so sample first |
| `makiligon/Blue-Archive-Japanese-Voicelines` | game/anime voice lines | 500 clips if transcripts exist | very small download, but card/viewer metadata appears incomplete |
| `ja_asr.common_voice_8_0` | general Japanese | full or 1000 clips | quick out-of-domain sanity check |
| `ja_asr.jsut_basic5000` | read Japanese | full or 1000 clips | compact read-speech regression check |

Report CER plus substitution, insertion, and deletion rates, with the exact normalization and decoding settings.

## Repository Contents

This repository intentionally includes training recovery artifacts:

- `model.safetensors`
- tokenizer and processor files
- `optimizer.pt`
- `scheduler.pt`
- `rng_state.pth`
- `trainer_state.json`
- `training_args.bin`

For inference-only use, the optimizer and scheduler files are not required.

## Inference

Use the same inference stack as the upstream Qwen3-ASR models, replacing the model id with:

```text
jaykwok/Qwen3-ASR-1.7B-JA-Anime-Galgame
```

Refer to the upstream Qwen3-ASR documentation for the latest supported inference commands and runtime requirements.

## Limitations

- The model is specialized for galgame/anime-style Japanese speech and may be less reliable on news, meetings, lectures, or spontaneous conversation.
- The training data may contain adult or NSFW source material. Downstream users should account for domain and content bias.
- The published benchmark is small and should be treated as a sanity check rather than a full leaderboard result.
- Transcriptions may still contain hallucinations, punctuation differences, or style-specific handling of non-speech vocalizations.

## License and Use

The base model [Qwen/Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) is released under Apache-2.0.

This fine-tuned checkpoint was trained on [litagin/Galgame_Speech_ASR_16kHz](https://huggingface.co/datasets/litagin/Galgame_Speech_ASR_16kHz). Users must review and comply with the dataset license and upstream terms before redistribution, commercial use, or further fine-tuning. This model card does not grant rights beyond the upstream model and dataset licenses.
