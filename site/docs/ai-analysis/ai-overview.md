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

In the post-recording sheet (the window that appears after you stop), you can toggle which outputs to generate. You can also set the defaults in **Settings → After recording → Default tasks**.

## Choosing an AI engine

Go to **Settings → AI analysis** and pick your **Engine**. dBrief offers four options:

| Engine | Where it runs | Requirements |
|---|---|---|
| **[Apple Intelligence](apple-intelligence.md)** | On your Mac | macOS 26+, Apple Silicon |
| **[Gemma 4 E4B Local](local-gemma.md)** | On your Mac | Apple Silicon + model download |
| **[Remote Endpoint](remote-endpoint.md)** | A cloud provider or your server | OpenAI-compatible server, or an Anthropic/OpenAI/Gemini/Groq/OpenRouter API key |
| **[Local CLI](local-cli.md)** | A command-line tool on your Mac | A CLI such as `claude`, `ollama`, or `llm` installed |

Not sure whether to run AI on your Mac or on a server? See [Local vs Remote AI](local-vs-remote.md) for the privacy, quality, and cost trade-offs.

## Processing order

AI analysis runs after transcription completes. The steps run sequentially: summary → action items → tags/sentiment → title generation → Markdown export → integrations.

## Long recordings

On-device analysis (Gemma and Apple Intelligence) reads the whole meeting, however long. When a transcript is too long for the model in one pass, dBrief works through it in parts, takes notes on each, and combines them, so decisions and action items from the middle of a long meeting aren't missed. While this runs, the processing step shows **Part n of m**. Long recordings take longer to analyse.

Remote endpoints receive the full transcript in one request, so a long meeting needs a model with a large enough context window — see [Remote AI Endpoint](remote-endpoint.md).

## Results language

By default, summaries and action items are written in the language of the transcript. To always get them in one language, set **Write results in** in the **Results language** card of **Settings → AI analysis** (**Same as transcript**, **English**, **Dutch**, or **Custom** with a two-letter language code). This card appears for on-device and Local CLI analysis. It's separate from the language dBrief's menus are shown in — see [Language & Accessibility](../reference/language-and-accessibility.md).

## Customising prompts

You can edit the prompts dBrief uses for each AI task in **Settings → AI analysis**: open the collapsed **Advanced** card at the end of the page and click **Edit…** next to a prompt. Profiles can also override prompts on a per-meeting basis — see [Meeting Profiles](../profiles/what-are-profiles.md).

Your custom Summary, Action Items, and Tags prompts are honored by **every** engine — the on-device Gemma and Local CLI engines follow them just like Remote Endpoint does, so the analysis matches your instructions no matter which backend you run.

## Turning AI off

If you only want transcripts, turn off **AI analysis** in **Settings → AI analysis**. Recordings are then transcribed only — no summary, action items, or tags — and the AI options are hidden from the post-recording sheet.

## Chatting with a transcript

Beyond the automatic outputs, you can ask follow-up questions about any recording. See [Transcript Chat](transcript-chat.md).
