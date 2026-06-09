# Transcript Viewer

A two-pane window for browsing your recordings, reading transcripts, following along with the audio, detecting speakers, and chatting about a recording.

## Opening it

There are two ways in:

- **Open Viewer** — click the **Open Viewer** button in the *Recent Recordings* header of the dBrief menu bar window. This opens the viewer with the full list of recordings.
- **Transcript action** — from [Recording History](recording-history.md), expand a recording and choose **Transcript**. The viewer opens with that recording already selected.

## Layout

- **Sidebar (left)** — lists all your recordings with their date, duration, and status. Select one to view it.
- **Detail (right)** — the selected recording's transcript, a player bar, and the toolbar actions.

## Reading the transcript

- The transcript is shown as a single, continuous list. Each speaker turn is labelled and consecutive segments from the same speaker are merged for easier reading.
- **Player bar** — play, pause, and scrub through the recording using the waveform. The transcript highlights and auto-scrolls as it plays; click any line to jump the audio to that point.

## Detecting speakers

If a recording wasn't diarized during transcription — or you want to try again — click the **Detect Speakers** button (the people icon) in the toolbar. dBrief runs on-device speaker detection on the recording's audio and assigns speakers to the existing transcript, without re-transcribing.

- The first run downloads the speaker-detection model, which can take a while.
- Detecting speakers **replaces** any current speakers and custom names for that recording, so you'll confirm before it runs.
- Requires the recording's audio file to still be on disk.

## Renaming speakers

Once a recording has speakers (from diarization at transcription time or from **Detect Speakers**), a row of coloured speaker chips appears above the transcript, and each turn shows a speaker label.

Click a chip — or a turn's label — to rename that speaker, for example to a real name. The new name is saved alongside the recording and used everywhere, including the Markdown export.

If you entered participant names in the post-recording sheet, dBrief maps them to speakers in order automatically.

## Chatting about the recording

Click the **chat** button (speech-bubble icon) in the toolbar to switch the detail pane to a chat about the recording, and click it again to return to the transcript. See [Transcript Chat](../ai-analysis/transcript-chat.md).

## Toolbar actions

| Button | What it does |
|---|---|
| **Chat** | Toggle between the transcript and a chat about the recording |
| **Copy** | Copy the full transcript to the clipboard |
| **Detect Speakers** | Run on-device speaker detection on this recording |
| **Display** | Adjust the transcript font size and toggle speaker names |
| **Delete** | Remove the recording and its files |

## Where it's saved

Speaker names and the rich transcript are stored in a `.richtranscript.json` file next to the recording's Markdown export, so your edits persist between sessions.
