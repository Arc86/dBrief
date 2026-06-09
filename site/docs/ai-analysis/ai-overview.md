# AI Analysis Overview

After transcription, dBrief uses an AI model to analyse the transcript and generate useful outputs.

## What AI generates

| Output | Description |
|---|---|
| **Summary** | A short paragraph covering the main points of the meeting |
| **Action items** | A list of tasks and follow-ups mentioned in the conversation |
| **Tags** | Keywords extracted from the transcript |
| **Sentiment** | An overall tone reading (positive, neutral, negative) |
| **Title** | A generated title for the recording (used in the filename and Markdown header) |

## Choosing what to generate

In the post-recording sheet (the window that appears after you stop), you can toggle which outputs to generate. You can also configure defaults in **Settings → AI & Models**.

## Choosing an AI engine

Go to **Settings → AI & Models** and select your engine. dBrief offers three options:

| Engine | Where it runs | Requirements |
|---|---|---|
| **Apple Intelligence** | On your Mac | macOS 26+, Apple Silicon |
| **Gemma 4 E4B Local** | On your Mac | Apple Silicon + model download |
| **Remote Endpoint** | Your server | OpenAI-compatible server |

Not sure whether to run AI on your Mac or on a server? See [Local vs Remote AI](local-vs-remote.md) for the privacy, quality, and cost trade-offs.

## Processing order

AI analysis runs after transcription completes. The steps run sequentially: summary → action items → tags/sentiment → title generation → Markdown export → integrations.

## Customising prompts

You can edit the prompts dBrief uses for each AI task in **Settings → AI & Models** (requires Power User Mode). Profiles can also override prompts on a per-meeting basis — see [Meeting Profiles](../profiles/what-are-profiles.md).

## Turning AI off

If you only want transcripts, turn off **Enable AI processing** in **Settings → AI & Models → AI Analysis**. Recordings are then transcribed only — no summary, action items, or tags — and the AI options are hidden from the post-recording sheet.

## Chatting with a transcript

Beyond the automatic outputs, you can ask follow-up questions about any recording. See [Transcript Chat](transcript-chat.md).
