# Transcript Chat (Ask dBrief AI)

Ask follow-up questions about any recording in a conversational chat.

## What it is

**Ask dBrief AI** lets you have a back-and-forth conversation about a recording — "What did we decide about the budget?", "List every question the client asked", "Rewrite the summary as bullet points". dBrief gives the AI the transcript with speaker names and timestamps, so answers can say who said what and when.

## Opening the chat

Open a recording in the [transcript viewer](../history/transcript-viewer.md), then click **Ask dBrief AI** (with the sparkle icon) in the header, or press **⇧⌘I**. This opens a side panel next to your summary or transcript, so your notes stay in view while you ask. Drag the panel's edge to the width you like; it remembers it. Click the button again, or the panel's **✕** (**Hide assistant**), to close it. Each recording keeps its own conversation.

Your conversation is **saved to disk** alongside the recording, so it's still there the next time you open dBrief. **Clear Chat…** in the panel's **…** menu removes it (dBrief asks first). Deleting a recording (or letting [auto-delete](../reference/file-locations.md) clean it up) removes its chat too.

While a recording is still in progress with [Live Transcription](../transcription/live-transcription.md) on, the chat also opens as a side panel next to the live transcript — and the conversation carries over to the finished recording when you stop.

The panel's text-size button (**Chat text size**) makes the conversation larger or smaller.

## Clickable timestamps

Answers cite moments in the meeting, like **[00:12:34]**. Click a timestamp to jump to that moment in the transcript and the audio player.

## Asking questions

When you first open the chat you'll see one-tap example prompts to get you started:

- Summarize
- Action items
- Decisions
- Questions asked
- *What did … commit to?* for people in the meeting

Once a conversation is underway, a few follow-up prompts (such as **Key points**, **Open issues** and **Numbers & dates**) appear as a compact row just above the input box. You can also type any question and press **Return**.

To ask by voice, click the microphone button (**Ask by voice**) in the input field. It uses macOS Dictation.

### Saved prompts

To keep a question you ask often, right-click it in the chat and choose **Save as Prompt**. Saved prompts appear under **Your prompts** when you start a new chat. Rename, edit, delete or add prompts in the **Chat prompts** card of **Settings → AI analysis**.

Right-click a question for **Copy** and **Edit Question** too.

## Putting answers to work

Each answer has buttons to copy it, read it aloud (with the voice from **Settings → Spoken summary**) and ask again. The share menu next to them lets you:

- **Add to Summary** — append the answer to the recording's summary
- **Add as Action Items…** — turn the answer's bullets into action items; pick which ones to add
- **Copy as Plain Text**, **Save as Markdown…** or **Save as Text…**

For the whole conversation, use the panel's **…** menu: **Copy Conversation**, **Save Conversation as Markdown…**, or **Add Conversation to Recording Note**.

## Long recordings

When a transcript is too long for the AI model to read in one go, Ask dBrief AI answers from an **overview of the whole meeting** (its saved notes) plus the **passages most relevant to your question**. This works on both Gemma and Apple Intelligence. The answer is marked "Answered from the most relevant parts of this long recording."

The first question about a long recording takes a little longer: dBrief prepares a search index of the transcript on your Mac (a one-time model download of about 480 MB) and saves it with the recording.

Some questions need every part of the meeting, such as "list every action item". For those, click **Check the whole recording** under the answer. dBrief then goes through the full transcript part by part and writes the answer from what it found. This takes a few minutes; the button shows an estimate for Gemma. Click stop to cancel it.

## Which AI engine it uses

Ask dBrief AI uses your currently selected AI engine:

- **Gemma 4 E4B Local** — on-device; follow-up questions are fast because it keeps the conversation warm
- **Apple Intelligence** — on-device (macOS 26+, Apple Silicon)
- **Remote Endpoint** — your OpenAI-compatible or Anthropic server
- **Local CLI** — chat uses the engine you pick with **Chat uses** in the **Ask dBrief AI** card of **Settings → AI analysis**. Choose Apple Intelligence, Gemma 4 E4B Local, or a Remote Endpoint; the **Providers** card appears when you pick Remote Endpoint.

Responses stream in as they're generated, and the conversation keeps its context across turns.

## Stop a response

Click the stop button (it replaces the send button) or press **Esc** while a reply is streaming to cancel generation without clearing the conversation. Repetitive or excessively long responses also stop automatically with a note explaining why. Scrolling up while an answer streams keeps your place; **Jump to latest message** takes you back down.

## Privacy

With an on-device engine, the transcript and your questions never leave your Mac. With a remote endpoint, they're sent to whichever server you configured.
