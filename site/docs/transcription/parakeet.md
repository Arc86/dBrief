# Parakeet (Local)

On-device transcription using NVIDIA's Parakeet TDT model, running via the FluidAudio framework. Runs best on Apple Silicon.

## What it is

Parakeet is a fast, accurate on-device speech recognition model. Like Local Whisper, it runs entirely on your Mac — no audio leaves your device — but it handles long recordings natively without splitting them into chunks. It produces word-level timestamps, and can optionally label who said what.

## Speaker diarization

Turn on **Identify speakers** in **Settings → Speakers** to label who said what. After Parakeet transcribes, dBrief runs SpeakerKit on the same audio and assigns each word the speaker who was talking at that moment, then groups the transcript into speaker turns. This adds processing time and ~500 MB of memory, and downloads the SpeakerKit model on first use. Speaker labels flow into the transcript viewer, markdown export, and integrations, just like with Local Whisper. As with any recording, you can rename speakers afterward by clicking a speaker name in the transcript.

## Model variants

In **Settings → Transcription**, click **Change model…** on the model card and choose a variant:

| Variant | Languages | Download | Notes |
|---|---|---|---|
| **Parakeet TDT 0.6B v3** | 25 European languages | ~480 MB | Default |
| **Parakeet Ultra** | 25 European languages | ~630 MB | v3 retrained for accuracy: the most accurate Parakeet, at the same speed |
| **Parakeet Redux** | 25 European languages | ~220 MB | Smallest download. macOS 15 or later; the first use takes a few minutes to prepare |
| **Parakeet Phonon-2** | English only | ~360 MB | The fastest Parakeet, slightly less accurate than Ultra. macOS 15 or later |
| **Parakeet TDT 0.6B v2** | English only | Similar to v3 | The original English model |

Variants that need macOS 15 aren't offered on macOS 14; a recording set to one of them uses v3 instead.

## First use: model download

The first time you use Parakeet, dBrief downloads the selected model (see the table above for sizes). While transcribing, a model uses about 1.2–1.8 GB of memory. Models are stored at:

```
~/Library/Application Support/FluidAudio/Models/
```

Use the **Download model** button on the model card to fetch it ahead of time, with progress and a cancel option. To remove it later, click the **…** button on the card and choose **Remove downloaded model**. After download, transcription works fully offline.

A downloaded model stays on your Mac. When macOS is low on memory, dBrief unloads the model from memory but keeps the file, so the next transcription doesn't download it again.

## Limitations

- **No language picker** — the language is determined by which variant you choose (English-only v2 and Phonon-2, or multilingual v3, Ultra and Redux). The **Spoken language** setting is greyed out while Parakeet is selected.

## Setup

1. Go to **Settings → Transcription**
2. Set **Where transcription runs** to **On this Mac**
3. Click **Change model…**, choose a Parakeet variant and click **Use** with its name
4. Click **Download model**

## Privacy

Audio is processed entirely on-device.
