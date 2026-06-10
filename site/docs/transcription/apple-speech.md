# Apple Speech

On-device transcription using the speech recognition built into macOS.

## What it is

Apple Speech uses the speech recognition built into macOS. Transcription happens entirely on your Mac — no audio is sent anywhere.

dBrief automatically picks the best engine for your Mac:

- **macOS 26 or newer** — Apple's modern `SpeechAnalyzer`, with noticeably better long-form accuracy and word-level timing (so the transcript viewer can highlight along with playback). The first time you transcribe in a given language, macOS downloads a small language model — you'll see a brief **"Preparing language…"** step.
- **macOS 14–25** — the classic `SFSpeechRecognizer` recognizer.

This is automatic; there's a single **Apple Speech** option in Settings.

## Setup

No download or configuration needed. Grant **Speech Recognition** permission when prompted (or in **Settings → Permissions**).

## When to use it

- You want zero setup and are comfortable with moderate accuracy
- You don't have Apple Silicon and can't use Local Whisper
- You don't have a transcription server

## Accuracy

Apple Speech works well for clear speech in common languages — and is meaningfully more accurate on macOS 26 thanks to the newer model. It may still struggle with:

- Technical jargon and proper nouns
- Heavy accents
- Crosstalk (multiple speakers at once)

For higher accuracy, consider [Local Whisper](local-whisper.md) or a [Remote Endpoint](remote-endpoint.md).

## Privacy

Audio is processed entirely on-device.
