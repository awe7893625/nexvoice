# Local models

NexVoice transcribes locally with [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper).
Any Whisper-architecture model published in MLX format works; set
`NEXVOICE_MLX_MODEL` to its Hugging Face repo id and restart the runtime.

## Default: Breeze ASR 25

`eoleedi/Breeze-ASR-25-mlx` — an MLX conversion of
[`MediaTek-Research/Breeze-ASR-25`](https://huggingface.co/MediaTek-Research/Breeze-ASR-25),
a Whisper-large-v2 fine-tune (Apache-2.0) for Taiwanese Mandarin and
Mandarin-English code-switching. 2.9 GB of weights.

## Why not whisper-large-v3-turbo

Turbo was the default until 2026-08-16. It is smaller (1.5 GB) and roughly 3×
faster, but on real Traditional Chinese dictation with English technical terms
it makes about twice as many errors.

Measured through the production path (`transcribe_wav`, identical initial
prompt and temperature ladder, only the model swapped) on two ~20 s recordings
whose transcripts already existed, so the reference text was not produced by
any model under test. CER = character error rate; repeated 3×, deterministic.

| Model | avg CER | 5 s clip, warm median | Weights |
| --- | ---: | ---: | ---: |
| `eoleedi/Breeze-ASR-25-mlx` (default) | **3.0%** | 1.09 s | 2.9 GB |
| `mlx-community/whisper-large-v3-turbo` | 6.0% | 0.32 s | 1.5 GB |
| `doggy8088/Breeze-ASR-26-MLX-8bit` | 6.4–10.4% | — | 1.5 GB |

Beyond the CER number, turbo silently drops words it treats as redundant
(「這些」,「裡面的」) and mis-decodes 智慧眼鏡 → 智慧眼睛, 終端機 → 終端畸.
Breeze keeps them. Breeze ASR **26** is newer but scored worse here — do not
assume the higher version number wins; measure before switching.

## The initial prompt was load-bearing, and no longer is

Removing the Traditional Chinese `STYLE_TAIL` primer is a useful control:

| Model | with prompt | without prompt |
| --- | ---: | ---: |
| Breeze ASR 25 | 3.0% | 3.0% |
| whisper-large-v3-turbo | 6.0% | 19.7%, and starts emitting simplified characters |

Turbo's Traditional Chinese output depended on that primer. Because the primer
shares a 2048-byte budget with the user's vocabulary list, a large enough
dictionary could crowd it out and silently regress the app to simplified
Chinese. Breeze does not rely on it.

## Known limitation the model cannot fix

Both models decode "Claude Code" as "cloud code": the acoustic evidence for an
ordinary English word beats a glossary hint, and adding the term to
`BASE_TERMS` was measured to have no effect. Fix it with a sounds-like
dictionary entry (phrase `Claude Code`, sounds-like `cloud code`), which
`LocalTranscriptPostprocessor` applies to the final transcript.

## Before a public release

The default is currently a third-party MLX conversion. Its `config.json`
matches Whisper large-v2 exactly (`n_audio_state` 1280, 32 encoder and 32
decoder layers, `n_vocab` 51865, `n_mels` 80), but a shipped default should not
depend on an individual's repository staying available. Convert from the
MediaTek upstream and pin that instead.

## Cloud path

The optional Groq path still requests `whisper-large-v3-turbo`; Groq does not
host Breeze. Cloud transcription stays opt-in and credential-gated.
