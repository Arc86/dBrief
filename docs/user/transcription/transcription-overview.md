# Transcription Overview

Transcription converts your audio recording into text. dBrief offers three transcription engines.

## When transcription runs

Transcription runs automatically after you stop a recording (if you have **Transcribe** checked in the post-recording sheet). You can also re-run transcription on any past recording from the [Recording History](../history/recording-history.md).

## Choosing an engine

Go to **Settings → Recording** and select your transcription engine.

## Engine comparison

| Engine | Where it runs | Setup required | Notes |
|---|---|---|---|
| **Apple Speech** | On your Mac | None | Works on any Mac; lower accuracy for technical content |
| **Local Whisper** | On your Mac | Apple Silicon + model download | Higher accuracy; ~150 MB model download |
| **Remote Endpoint** | Your server | Server URL + optional API key | Best accuracy; requires a running server |

## Long recordings

Recordings longer than 30 minutes are automatically split into 30-minute chunks before transcription. Each chunk is transcribed separately and the results are combined.

## Transcription language

You can set the output language in **Settings → Recording**. Options include matching the transcript language or forcing English, Dutch, or a custom language code.
