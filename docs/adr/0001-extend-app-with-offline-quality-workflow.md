# Extend the app with an offline quality workflow

whisperASR will gain a separate high-quality offline workflow instead of a second application, reusing its media handling and export capabilities while leaving live-caption behaviour unchanged. Each job lets the user choose its Deliverables, speaker labelling and one of Qwen JA, Parakeet JA or WhisperKit; required internal stages such as translation, forced alignment and diarization are inferred from those choices, and raw evidence is retained for reproducible evaluation on the Offline acceptance corpus.
