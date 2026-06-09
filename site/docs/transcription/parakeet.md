# Parakeet (Local)

On-device transcription using NVIDIA's Parakeet TDT model, running via the FluidAudio framework. Runs best on Apple Silicon.

## What it is

Parakeet is a fast, accurate on-device speech recognition model. Like Local Whisper, it runs entirely on your Mac — no audio leaves your device — but it handles long recordings natively without splitting them into chunks. It produces word-level timestamps, and can optionally label who said what.

## Speaker diarization

Turn on **Speaker diarization** in **Settings → AI & Models → Transcription** to label who said what. After Parakeet transcribes, dBrief runs SpeakerKit on the same audio and assigns each word the speaker who was talking at that moment, then groups the transcript into speaker turns. This adds processing time and ~500 MB of memory, and downloads the SpeakerKit model on first use. Speaker labels flow into the transcript viewer, markdown export, and integrations, just like with Local Whisper. As with any recording, you can rename speakers afterward by clicking a speaker badge.

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

## Setup

1. Go to **Settings → AI & Models → Transcription**
2. Select **Parakeet (Local)** as your transcription engine
3. Choose the v2 or v3 variant and click **Download model**

## Privacy

Audio is processed entirely on-device.
