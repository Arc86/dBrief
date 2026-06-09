# Apple Speech

On-device transcription using the speech recognition built into macOS.

## What it is

Apple Speech uses the `SFSpeechRecognizer` framework built into macOS. Transcription happens entirely on your Mac — no audio is sent anywhere.

## Setup

No download or configuration needed. Grant **Speech Recognition** permission when prompted (or in **Settings → General → Permissions**).

## When to use it

- You want zero setup and are comfortable with moderate accuracy
- You don't have Apple Silicon and can't use Local Whisper
- You don't have a transcription server

## Accuracy

Apple Speech works well for clear speech in common languages. It may struggle with:

- Technical jargon and proper nouns
- Heavy accents
- Crosstalk (multiple speakers at once)

For higher accuracy, consider [Local Whisper](local-whisper.md) or a [Remote Endpoint](remote-endpoint.md).

## Privacy

Audio is processed entirely on-device.
