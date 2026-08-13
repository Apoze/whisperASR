# L5 — Bakeoff japonais

Run `e4-asr-20260802T160000Z`, commit `09b092b001e4d35cd193b9a5e3f4f7307d74821b`, worktree modifié.
Réseau des moteurs Python : interdit par sandbox macOS.

Les scores restent exploratoires tant que les annotations ne sont pas validées humainement.

| Moteur | CER high | medium | overlap | p95 calcul ASR | RSS max | Vides high/diag | PCM vers ASR | Dernière parole | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| whisper-large-v3-turbo | 46.51 % | 38.79 % | 91.75 % | 1277 ms | 3.52 Gio | 0/0 | 100.0 % | oui | témoin retenu |
| kotoba-whisper-v2.0-q5 | 26.24 % | 33.33 % | 70.10 % | 1049 ms | 1.05 Gio | 0/0 | 100.0 % | oui | écarté L5 |
| qwen3-asr-1.7b | 25.96 % | 43.64 % | 76.29 % | 636 ms | 6.71 Gio | 0/0 | 100.0 % | oui | écarté L5 |
| parakeet-tdt-ja-coreml | 22.29 % | 44.85 % | 67.01 % | 76 ms | 3.39 Gio | 0/0 | 100.0 % | oui | écarté L5 |

Décisions mesurées :

- `whisper-large-v3-turbo` : gain CER inférieur au gate de 10 %; régression de plus de 2 points sur un corpus.
- `kotoba-whisper-v2.0-q5` : gain CER inférieur au gate de 10 %.
- `parakeet-tdt-ja-coreml` : gain CER inférieur au gate de 10 %.

Les termes critiques attendent la validation humaine. La preview et l’anglais appartiennent à L6.
