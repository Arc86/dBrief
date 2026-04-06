# Local Whisper

On-device transcription using OpenAI's Whisper model, running via WhisperKit on Apple Silicon.

> **Requires:** Mac with Apple Silicon (M1 or later).

## What it is

Local Whisper uses WhisperKit to run a Whisper speech recognition model directly on your Mac using the Neural Engine. No audio leaves your device.

## First use: model download

The first time you select Local Whisper, dBrief downloads the model (~150 MB). This happens once and the model is stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/WhisperKit/
```

You need a working internet connection for the initial download. After that, transcription works fully offline.

## Setup

1. Go to **Settings → Recording**
2. Select **Local Whisper** as your transcription engine
3. dBrief will prompt you to download the model if it isn't already on your Mac

## Deleting the model

To free up disk space, go to **Settings → AI & Models** and use the option to remove the Whisper model. You can re-download it at any time.

## Accuracy

Local Whisper is significantly more accurate than Apple Speech, especially for:

- Technical vocabulary
- Multiple speakers
- Non-native accents

## Privacy

Audio is processed entirely on-device.
