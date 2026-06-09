# Local Whisper

On-device transcription using OpenAI's Whisper model, running via WhisperKit. Runs best on Apple Silicon.

## What it is

Local Whisper uses WhisperKit to run a Whisper speech recognition model directly on your Mac using the Neural Engine. No audio leaves your device.

## First use: model download

The first time you use Local Whisper, dBrief downloads a model. The recommended default is **Whisper Large V3 Sep24** (~626 MB) — a fast, accurate, quantized model light enough for most Macs. Models are stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/WhisperKit/
```

You need a working internet connection for the initial download. After that, transcription works fully offline.

## Choosing a model

In **Settings → AI & Models → Transcription**, the selected model appears as a card showing its name, approximate memory use, and a **Recommended** badge on the suggested model. A one-line description under the card explains the trade-off, and the **ⓘ** button next to *Model* gives a plain-language overview. Smaller models (Tiny, Small) are faster and lighter; larger models are more accurate but need more memory. Open **Advanced** to switch where the model runs (compute units), enable **Show all models** to see every variant fetched from Hugging Face, refresh the list, or purge the cached model.

Use the **Download model** button to fetch a model ahead of time. Downloads show progress and can be cancelled. A green checkmark indicates a model is already on disk.

## Setup

1. Go to **Settings → AI & Models → Transcription**
2. Select **Local Whisper** as your transcription engine
3. Pick a model and click **Download model** (or just start a recording — dBrief downloads the model on demand)

## Speaker diarization

Turn on **Speaker diarization** in the same section to label who said what. dBrief downloads a separate speaker model on first use (stored under `LocalAIPlugin/SpeakerKit/`) and tags each segment with a speaker. See the [transcript viewer](../history/transcript-viewer.md) for renaming speakers.

You can also run speaker detection **after the fact** on an already-transcribed recording with the **Detect Speakers** button in the [transcript viewer](../history/transcript-viewer.md) — no need to re-transcribe.

## Deleting the model

To free up disk space, go to **Settings → AI & Models → Transcription** and use **Purge local WhisperKit model**. You can re-download it at any time.

## Accuracy

Local Whisper is significantly more accurate than Apple Speech, especially for:

- Technical vocabulary
- Multiple speakers
- Non-native accents

Larger models improve accuracy further at the cost of speed and memory.

## Privacy

Audio is processed entirely on-device.
