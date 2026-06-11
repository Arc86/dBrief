# Transcription Overview

Transcription converts your audio recording into text. dBrief offers four transcription engines.

## When transcription runs

Transcription runs automatically after you stop a recording (if you have **Transcribe** checked in the post-recording sheet). You can also re-run transcription on any past recording from the [Recording History](../history/recording-history.md).

## Choosing an engine

Go to **Settings → AI & Models → Transcription** and select your transcription engine.

## Engine comparison

| Engine | Where it runs | Setup required | Notes |
|---|---|---|---|
| **Apple Speech** | On your Mac | None | Works on any Mac. On macOS 26+ uses Apple's modern model — much better accuracy plus word-level timing in the transcript viewer; older macOS uses the classic recognizer (lower accuracy for technical content) |
| **Local Whisper** | On your Mac | Model download | Higher accuracy; choose from many model sizes; optional speaker diarization |
| **Parakeet (Local)** | On your Mac | Model download | Fast on-device transcription with optional speaker diarization; no language selection |
| **Remote Endpoint** | Your server | Server URL + optional API key | Best accuracy with large models; requires a running server |

The two on-device model engines (Local Whisper and Parakeet) run best on Apple Silicon. Each downloads its model on first use — see the individual pages for sizes and details.

## Speaker diarization (who said what)

When using **Local Whisper** or **Parakeet (Local)**, you can enable **Speaker diarization** in **Settings → AI & Models → Transcription**. dBrief then labels each segment with a speaker ("Speaker 1", "Speaker 2", …), which you can rename in the [transcript viewer](../history/transcript-viewer.md). Diarization adds processing time and extra memory, and is off by default. The **Deepgram** remote provider also returns speaker labels when diarization is on; Apple Speech and other remote endpoints don't support it.

## Cleanup

After transcription, dBrief always tidies the text — stripping stray markup and non-speech annotations (like `[BLANK_AUDIO]`) that speech models sometimes emit. Under **Settings → Transcription → Cleanup** you can also turn on **Remove filler words** (um, uh, …); it's off by default so meeting transcripts stay verbatim.

## Long recordings

Recordings longer than 30 minutes are automatically split into 30-minute chunks before transcription. Each chunk is transcribed separately and the results are combined. (Parakeet handles long files natively without chunking.)

## Transcription language

For Apple Speech, Local Whisper, and remote endpoints, you can set the input language in **Settings → AI & Models → Transcription**. Leave it on **Auto-detect** to let the engine figure it out, or pick a specific language. Parakeet ignores language selection — choose the v2 (English) or v3 (multilingual) model variant instead.

## Custom vocabulary

With **Power User Mode** enabled, a **Custom Vocabulary** field (Local Whisper and remote endpoints) lets you list proper nouns, acronyms, and domain terms — e.g. *Acme Corp, JIRA, Kubernetes* — to improve recognition. The same terms are also passed to the AI analysis step, so summaries and action items spell your proper nouns correctly too.
