---
language:
- ja
license: gpl-3.0
license_link: LICENSE.md
multilinguality:
- monolingual
pretty_name: Galgame_Speech_ASR_16kHz
size_categories:
- 1M<n<10M
task_categories:
- automatic-speech-recognition
tags:
- speech
- audio
- text
- japanese
- anime
- voice
- visual novel
- galgame
---

# Dataset Card for Galgame_Speech_ASR_16kHz 

> [!IMPORTANT]\
> The following rules (in [the original repository](https://huggingface.co/datasets/OOPPEENN/Galgame_Dataset)) must be followed:
> 
> 必须遵守GNU General Public License v3.0内的所有协议！  
> 附加：禁止商用，本数据集以及使用本数据集训练出来的**任何模型**都不得用于**任何商业行为**，如要用于商业用途，请找数据列表内的**所有厂商授权**（笑），因违反开源协议而出现的任何问题都与本人无关！
> 训练出来的模型**必须开源**，是否在README内引用本数据集由训练者自主决定，不做强制要求。
>
> **English**:
> You must comply with all the terms of the GNU General Public License v3.0!  
> Additional note: Commercial use is prohibited. This dataset and any model trained using this dataset cannot be used for any commercial purposes. If you wish to use it for commercial purposes, please obtain authorization from **all the providers listed in the dataset** (LOL). I bear no responsibility for any issues arising from violations of the open-source license!
> Models trained using this dataset **must be open-sourced**. Whether to cite this dataset in the README is left to the discretion of the user and is not mandatory.
>
> **日本語**:
> GNU General Public License v3.0 内のすべての規約を遵守する必要があります！  
> 追加事項：商用利用は禁止されています。本データセットおよび本データセットを使用して訓練された**いかなるモデル**も**商業行為には一切使用できません**。商用利用を希望する場合は、データセットリスト内の**すべての提供者の許可を取得してください**（笑）。オープンソースライセンス違反によって発生したいかなる問題も私は責任を負いません！
> このデータセットを使用して訓練されたモデルは**オープンソースにする必要があります**。README 内で本データセットを引用するかどうかは、ユーザーの自主的な判断に委ねられており、強制されません。

<!-- Provide a quick summary of the dataset. -->

- A Japanese speech dataset from Japanese visual novels (Galgames) intended for training ASR (Automatic Speech Recognition) models like Whisper.
- This dataset is a derivative work of [OOPPEENN/Galgame_Dataset](https://huggingface.co/datasets/OOPPEENN/Galgame_Dataset) (thanks to the original authors!), and modified the original dataset for ASR purpose (see [Modifications](#modifications))

### Changelog

- 2024-10-12: Removed 190 audio-text pairs such that
  - 🤗 Datasets cannot read for some reason (I don't know why...)
  - Audio files longer than 30.0 seconds (for ASR trainig it's usual to filter such audio)

  Resulting in 3,746,131 pairs and 5353.9 hours, and the number of files in each tar file may be smaller than 32768.

## Dataset Details

- **Size**:
  - **3,746,131** audio files (all with transcriptions)
  - **5353.9** total hours
  - 115 tar files totaling **100.16 GB**, with each tar file (except the last) containing about 32,768 audio-text pairs (OGG and TXT files), approximately 897 MB per tar file
- **Language**: Japanese
- **Format**:
  - [**WebDataset**](https://github.com/webdataset/webdataset) format (see [Dataset Structure](#dataset-structure))
  - **16kHz**, 16-bit, mono **OGG** files

### Dataset Description

- **Size**: 3,746,131 audio-text pairs, 5,353 hours, 100GB
- **Language**: Japanese
- **Format**: 16kHz, 16-bit, mono OGG

### Dataset Sources

All the audio files and transcriptions are from [OOPPEENN/Galgame_Dataset](https://huggingface.co/datasets/OOPPEENN/Galgame_Dataset). Many thanks to the original authors!

### Modifications

I modified the original dataset in the following ways:

- Resampled the audio files to 16kHz OGG format (with x0.9 volume to avoid clipping)
- Renamed all the files using a random SHA-256-like hash
- Excluded audio files which have several different transcriptions
- Normalized transcriptions and filtered audio files according to the results in the following ways (see [normalize_text_and_filter.py](normalize_text_and_filter.py) for the actual code):
  - Deleted `\t`, `―` (dash), and spaces (half-width or full-width), and normalized some letters and symbols (e.g., "え～？" → "えー?")
  - Converted full-width alphabets and numbers to half-width
  - Converted half-width katakana to full-width
  - Converted "……" (or more) and "ーー" to "…" and "ー" respectively (trying to avoid unnecessary repetitions)
  - Converted repetitions like "???" → "?" and "!?!?!?" → "!?" (repetitions of `!?♪♡`)
  - Converted repetitions of letters in `ッっあいうえおんぁぃぅぇぉゃゅょアイウエオンァィゥェォャュョ` with 3 or more repetitions to 2 repetitions (e.g., "あああっっっ" → "ああっっ")
  - Only allowed the following characters:
    - Japanese Hiragana, Katakana, Kanji
    - Alphabets (a-z, A-Z) and numbers (0-9)
    - Symbols: `。、!?…♪♡○`

## Uses

### Direct Use

- Fine-tuning ASR models like Whisper for the Japanese anime-like speech domain
- Benchmarking Japanese ASR models
- Training ASR models for the NSFW domain (aegi and chupa voices), which Whisper and other ASR models mostly cannot recognize

### Out-of-Scope Use

- Not suitable for TTS (Text-to-Speech) and VC (Voice Conversion) since the audio quality is low (16kHz)

## Dataset Structure

- This dataset is in [**WebDataset**](https://github.com/webdataset/webdataset) format.
- It consists of `galgame-speech-asr-16kHz-train-{000000..000114}.tar` files.
- Each tar file contains of audio (OGG) and text (TXT) files with the same name (SHA-256-like hash).
```
00000aa36e86ba49cb67fb886cce2c044c03dbb8ffddad4cb4e5f2da809e91ab.ogg
00000aa36e86ba49cb67fb886cce2c044c03dbb8ffddad4cb4e5f2da809e91ab.txt
00000fe59140c18655921cd316f03ae7a81a0708a2d81a15d9b7ae866c459840.ogg
00000fe59140c18655921cd316f03ae7a81a0708a2d81a15d9b7ae866c459840.txt
...
```

- Except for the last tar file, each tar file contains about 32768 audio-text pairs (OGG and TXT files), hence about 65536 files in total (the number may be smaller than 32768 since I removed some files after the initial upload).

- File names are randomly generated SHA-256 hashes, so the order of the files has no mean (e.g., the files coming from the same Galgame are not necessarily adjacent).

## How to Use

To load this dataset in the [🤗 Datasets](https://huggingface.co/docs/datasets/en/index) library, just use:

```python
from datasets import load_dataset

dataset = load_dataset("litagin/Galgame_Speech_ASR_16kHz", streaming=True)
```
Be sure to set `streaming=True` if you want to avoid downloading the whole dataset at once.

See [example.ipynb](example.ipynb) for a simple example of how to use the dataset in this way.

See [Webdataset](https://github.com/webdataset/webdataset) for more details on how to use the dataset in WebDataset format in, e.g., PyTorch.

## Dataset Creation

### Curation Rationale

- Wanted a large-scale Japanese audio-text pair ASR corpus in the anime-like speech domain by professional voice actors, with 100% accurate transcriptions!
- Personally, I have been frustrated with the inability of Whisper to recognize aegi and chupa voices in Galgames, so I wanted to train an ASR model that can recognize them!

## Bias, Risks, and Limitations

- The dataset is derived from (anime-like) Galgames, so the speech is quite different from usual utterances in daily life.
- The dataset contains NSFW audio (aegi and chupa) and lines, so it is not suitable for all audiences.
- The dataset is not suitable for TTS and VC since the audio quality is low (16kHz).
- There are more female voices than male voices in the dataset, which may introduce a gender bias in models trained on it.
