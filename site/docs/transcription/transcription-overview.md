# Transcription Overview

Transcription converts your audio recording into text. dBrief offers four transcription engines.

## When transcription runs

Transcription runs automatically after you stop a recording (if **Transcribe audio** is checked in the post-recording sheet). You can also re-run transcription on any past recording from the [Recording History](../history/recording-history.md).

Want to watch the words appear *while* you record? Turn on [Live Transcription](live-transcription.md) for a real-time on-device preview (the accurate transcript is still produced by your chosen engine when you stop).

## Choosing an engine

Go to **Settings → Transcription**. In the **Engine** card, set **Where transcription runs** to **On this Mac** or **Remote service**.

For **On this Mac**, the card shows the current model. Click **Change model…** to open the model picker. **Quick pick** suggests a **Fastest**, **Recommended** and **Most accurate** model for your language and Mac; **All models** lists Apple Speech, every Parakeet variant and the Whisper models. For **Remote service**, add a provider in the **Providers** card.

## Engine comparison

| Engine | Where it runs | Setup required | Notes |
|---|---|---|---|
| **Apple Speech** | On your Mac | None | Works on any Mac. On macOS 26+ uses Apple's modern model — much better accuracy plus word-level timing in the transcript viewer; older macOS uses the classic recognizer (lower accuracy for technical content) |
| **Local Whisper** | On your Mac | Model download | Higher accuracy; choose from many model sizes; optional speaker diarization |
| **Parakeet (Local)** | On your Mac | Model download | Fast on-device transcription with optional speaker diarization; no language selection |
| **Remote Endpoint** | Your server | Server URL + optional API key | Best accuracy with large models; requires a running server |

The two on-device model engines (Local Whisper and Parakeet) run best on Apple Silicon. Each downloads its model on first use — see the individual pages for sizes and details.

## Speaker diarization (who said what)

When using **Local Whisper** or **Parakeet (Local)**, you can turn on **Identify speakers** in **Settings → Speakers**. dBrief then labels each segment with a speaker ("Speaker 1", "Speaker 2", …), which you can rename in the [transcript viewer](../history/transcript-viewer.md). Diarization adds processing time and extra memory, and is off by default. The **Deepgram** and **ElevenLabs Scribe** remote providers also return speaker labels when it's on; Apple Speech and other remote endpoints don't support it.

## Cleanup

After transcription, dBrief always tidies the text — stripping stray markup and non-speech annotations (like `[BLANK_AUDIO]` or `*music*`) that speech models sometimes emit.

**Drop silence hallucinations** (on by default) drops whole lines that exactly match a known filler phrase — the silence-hallucinations speech models love to invent, like "Thank you for watching", "Subscribe to the channel", or "♪". It only removes a segment when the *entire* line matches, so real speech that happens to contain one of these phrases is always kept. dBrief ships a curated, meeting-safe list of these phrases, and you can add your own (or reset back to the defaults) under **Settings → Transcription → Cleanup → Custom phrases**.

In the same place you can turn on **Remove filler words** (um, uh, …); it's off by default so meeting transcripts stay verbatim.

## Long recordings

Recordings longer than 30 minutes are automatically split into 30-minute chunks before transcription. Each chunk is transcribed separately and the results are combined. (Parakeet handles long files natively without chunking.)

## Transcription language

For Apple Speech, Local Whisper, and remote endpoints, you can set the input language in **Settings → Transcription → Language → Spoken language**. Leave it on **Auto-detect** to let the engine figure it out (with Apple Speech, **System language** uses your Mac's language), or pick a specific language. Parakeet ignores language selection — choose an English-only or multilingual [Parakeet variant](parakeet.md#model-variants) instead.

## Custom vocabulary

The **Settings → Vocabulary** page lets you list proper nouns, acronyms, and domain terms — e.g. *Acme Corp, JIRA, Kubernetes* — so they're spelled correctly. The same terms are also passed to the AI analysis step, so summaries and action items spell your proper nouns correctly too.

For **Local Whisper**, dBrief applies the vocabulary *after* transcription: once the audio is transcribed, your configured AI engine fixes the spelling and capitalization of these terms in the transcript. This is reliable and never drops audio. (Earlier versions fed the vocabulary to Whisper as a recognition prompt, which could make Whisper silently skip large parts of the audio — that approach has been removed, following OpenAI's own guidance to prefer post-processing.) Because the AI engine does the correction, the vocabulary fix needs an AI engine configured; if AI analysis is unavailable it's simply skipped.
