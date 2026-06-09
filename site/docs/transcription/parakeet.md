# Parakeet (Local)

On-device transcription using NVIDIA's Parakeet TDT model, running via the FluidAudio framework. Runs best on Apple Silicon.

## What it is

Parakeet is a fast, accurate on-device speech recognition model. Like Local Whisper, it runs entirely on your Mac — no audio leaves your device — but it handles long recordings natively without splitting them into chunks.

## Model variants

In **Settings → AI & Models → Transcription**, choose a variant:

| Variant | Languages | Notes |
|---|---|---|
| **Parakeet TDT 0.6B v2** | English only | Lightest |
| **Parakeet TDT 0.6B v3** | 25 European languages | Multilingual |

## First use: model download

The first time you use Parakeet, dBrief downloads the selected model (~1.5–1.8 GB). Models are stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/FluidAudio/
```

Use the **Download model** button to fetch it ahead of time, with progress and a cancel option. After download, transcription works fully offline.

## Limitations

- **No language picker** — the language is determined by which variant you choose (v2 English or v3 multilingual). The general language setting has no effect.
- **No speaker diarization** — Parakeet doesn't identify who said what. If you need speaker labels, use [Local Whisper](local-whisper.md) with diarization enabled.

## Setup

1. Go to **Settings → AI & Models → Transcription**
2. Select **Parakeet (Local)** as your transcription engine
3. Choose the v2 or v3 variant and click **Download model**

## Privacy

Audio is processed entirely on-device.
