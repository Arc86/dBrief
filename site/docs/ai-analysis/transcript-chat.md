# Transcript Chat

Ask follow-up questions about any recording in a conversational chat.

## What it is

Transcript Chat lets you have a back-and-forth conversation about a recording — "What did we decide about the budget?", "List every question the client asked", "Rewrite the summary as bullet points". dBrief feeds the full transcript (and speaker labels, if any) to the AI as context for each question.

## Opening the chat

Open a recording in the [transcript viewer](../history/transcript-viewer.md), then click the **chat** button (speech-bubble icon) in the toolbar. This swaps the detail pane from the transcript to the chat; click it again to switch back. The transcript stays loaded behind it, and each recording keeps its own conversation.

Your conversation is **saved to disk** alongside the recording, so it's still there the next time you open dBrief — not just while the app is running. Clearing the chat removes the saved copy, and deleting a recording (or letting [auto-delete](../reference/file-locations.md) clean it up) removes its chat too.

While a recording is still in progress with [Live Transcription](../transcription/live-transcription.md) on, the chat opens as a **side panel** next to the live transcript instead of replacing it — and the conversation carries over to the finished recording when you stop.

## Example prompts

When you first open the chat you'll see a set of one-tap example prompts to get you started, including:

- Bullet points
- Action items
- Key points
- Questions asked
- Improve grammar
- Generate FAQ
- Extract statistics
- Identify emotions

Once a conversation is underway, the same prompts stay available as a compact row just above the input box. You can also type any freeform question in the input field.

## Which AI engine it uses

Transcript Chat uses your currently selected AI engine:

- **Gemma 4 E4B Local** — on-device, streams the response
- **Apple Intelligence** — on-device (macOS 26+, Apple Silicon)
- **Remote Endpoint** — your OpenAI-compatible server

Responses stream in as they're generated, and the conversation keeps its full context across turns.

## Privacy

With an on-device engine, the transcript and your questions never leave your Mac. With a remote endpoint, they're sent to whichever server you configured.
