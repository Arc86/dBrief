# Transcript Viewer

A dedicated window for reading a recording's transcript, following along with the audio, and chatting about it.

## Opening it

From [Recording History](recording-history.md), expand a recording and choose the **Transcript** action. The viewer opens in its own window.

## What it shows

- **Speaker turns** — the transcript is grouped into cards by speaker turn, with timestamps. Consecutive segments from the same speaker are merged for easier reading.
- **Word-level timing** — when the engine provides word timestamps, the transcript stays in sync with playback.
- **Player bar** — play, pause, and seek through the recording; the transcript highlights as it plays.

## Renaming speakers

If [speaker diarization](../transcription/local-whisper.md) was used, each turn shows a coloured speaker badge ("Speaker 1", "Speaker 2", …). Click a badge to rename that speaker — for example to a real name. The new name is saved alongside the recording and used everywhere, including the Markdown export.

If you entered participant names in the post-recording sheet, dBrief maps them to speakers in order automatically.

## Chatting about the recording

The viewer includes a chat panel for asking follow-up questions about the recording. See [Transcript Chat](../ai-analysis/transcript-chat.md).

## Where it's saved

Speaker names and the rich transcript are stored in a `.richtranscript.json` file next to the recording's Markdown export, so your edits persist between sessions.
