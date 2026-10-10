# Transcript Chat

Ask follow-up questions about any recording in a conversational chat.

## What it is

Transcript Chat lets you have a back-and-forth conversation about a recording — "What did we decide about the budget?", "List every question the client asked", "Rewrite the summary as bullet points". dBrief gives the AI the transcript with speaker names and timestamps. When a recording is too long for the model, it sends an overview of the meeting plus the passages most relevant to your question instead; for questions that need every part ("list every action item"), use **Check the whole recording** under the answer.

## Opening the chat

Open a recording in the [transcript viewer](../history/transcript-viewer.md), then click **Ask dBrief AI** (with the sparkle icon) in the header. This opens a resizable side panel beside the summary or transcript; click it again (or the panel's **✕**) to close it. The panel remembers its width, and each recording keeps its own conversation.

Your conversation is **saved to disk** alongside the recording, so it's still there the next time you open dBrief — not just while the app is running. Clearing the chat (**Clear Chat** in the panel's **…** menu) removes the saved copy, and deleting a recording (or letting [auto-delete](../reference/file-locations.md) clean it up) removes its chat too.

While a recording is still in progress with [Live Transcription](../transcription/live-transcription.md) on, the chat also opens as a **side panel** next to the live transcript — and the conversation carries over to the finished recording when you stop.

## Example prompts

When you first open the chat you'll see one-tap example prompts to get you started:

- Summarize
- Action items
- Decisions
- Questions asked
- *What did … commit to?* for people in the meeting

Once a conversation is underway, a few follow-up prompts (such as **Key points**, **Open issues** and **Numbers & dates**) appear as a compact row just above the input box. You can also type any freeform question in the input field.

To keep a question you ask often, right-click it in the chat and choose **Save as Prompt**, or add it in **Settings → AI analysis → Chat prompts**. Saved prompts appear under **Your prompts** in a new chat.

## Which AI engine it uses

Transcript Chat uses your currently selected AI engine:

- **Gemma 4 E4B Local** — on-device, streams the response
- **Apple Intelligence** — on-device (macOS 26+, Apple Silicon)
- **Remote Endpoint** — your OpenAI-compatible server
- **Local CLI** — chat uses the engine you pick with **Chat uses** in the **Ask dBrief AI** card of **Settings → AI analysis**. Choose Apple Intelligence, Gemma 4 E4B Local, or a Remote Endpoint; the **Providers** card appears when you pick Remote Endpoint.

Responses stream in as they're generated, and the conversation keeps its full context across turns.

## Stop a response

Click the stop button (it replaces the send button) or press **Esc** while a reply is streaming to cancel generation without clearing the conversation. Repetitive or excessively long responses also stop automatically with a note explaining why.

## Privacy

With an on-device engine, the transcript and your questions never leave your Mac. With a remote endpoint, they're sent to whichever server you configured.
