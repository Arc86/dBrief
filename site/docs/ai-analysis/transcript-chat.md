# Transcript Chat

Ask follow-up questions about any recording in a conversational chat.

## What it is

Transcript Chat lets you have a back-and-forth conversation about a recording — "What did we decide about the budget?", "List every question the client asked", "Rewrite the summary as bullet points". dBrief feeds the full transcript (and speaker labels, if any) to the AI as context for each question.

## Opening the chat

Open a recording in the [transcript viewer](../history/transcript-viewer.md) (the **View** / transcript action in [Recording History](../history/recording-history.md)). The chat panel is built into the viewer window.

## Quick templates

The chat offers one-tap templates to get you started, including:

- Bullet points
- Action items
- Key points
- Questions asked
- Improve grammar
- Generate FAQ
- Extract statistics
- Identify emotions

You can also type any freeform question.

## Which AI engine it uses

Transcript Chat uses your currently selected AI engine:

- **Gemma 4 E4B Local** — on-device, streams the response
- **Apple Intelligence** — on-device (macOS 26+, Apple Silicon)
- **Remote Endpoint** — your OpenAI-compatible server

Responses stream in as they're generated, and the conversation keeps its full context across turns.

## Privacy

With an on-device engine, the transcript and your questions never leave your Mac. With a remote endpoint, they're sent to whichever server you configured.
