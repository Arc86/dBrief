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

Click a turn's speaker label to open the speaker picker. It lists everyone already in the transcript, anyone you entered in the post-recording sheet, and any calendar attendees. Select a person (or type a new name in "Add someone…") and dBrief will ask whether to reassign just that one turn or all turns currently attributed to that speaker. The result is saved alongside the recording and used everywhere, including the Markdown export.

If you entered participant names in the post-recording sheet, dBrief maps them to speakers in order automatically.

## Chatting about the recording

Click the **chat** button (speech-bubble icon) in the toolbar to switch the detail pane to a chat about the recording, and click it again to return to the transcript. See [Transcript Chat](../ai-analysis/transcript-chat.md).

## Viewing and editing the AI analysis

Click the **AI Analysis** button (chart icon) in the toolbar to switch the detail pane from the transcript to the recording's AI output, shown in three boxes — **Summary**, **Action Items**, and **Tags & Sentiment** — just like the menu bar shows after processing. Click it again to return to the transcript.

- **Copy** — the **Copy** button at the top of the panel copies the whole analysis as clean, formatted text, so you don't have to select it by hand.
- **Editing** — click **Edit** to change the summary, add or remove action items, or edit the tags, then click **Save** (or **Cancel** to discard). Sentiment is shown for reference but isn't editable.
- **Saving** updates the recording's saved analysis **and** rewrites the matching sections of the exported Markdown file in place — in your transcription folder or Obsidian vault — leaving the transcript and the rest of the note untouched. Other integrations (Apple Notes, Reminders, webhooks) are not re-sent, so editing won't create duplicates.

The AI analysis is saved automatically when a recording is processed. Recordings made before this feature was added show a "No saved analysis" message in the panel.

## Searching the transcript

Use the **search field** in the toolbar (or press **⌘F**) to find text in a long transcript. When the window is wide the search field shows in full; when it's narrow it collapses to a magnifying-glass button — click it to search.

- Every match is highlighted, and the match you're currently on is highlighted more strongly.
- The toolbar shows a **"3 of 12"** counter. Use the **up/down arrows** next to it — or **⌘G** (next) and **⌘⇧G** (previous), or **Return** for next — to jump between matches. Each jump scrolls the match into view.
- Search understands **regular expressions**, so `\baction\b` matches the whole word "action" only. Plain words work as you'd expect. An invalid pattern shows "Invalid pattern".
- Press **Esc** to close search and clear the highlights.

Search covers the transcript text of a finished recording. It isn't available for the live (in-progress) transcript or the Summary/Chat views.

## Toolbar actions

| Button | What it does |
|---|---|
| **AI Analysis** | Toggle between the transcript and the recording's editable AI analysis |
| **Chat** | Toggle between the transcript and a chat about the recording |
| **Search** | Find text in the transcript (⌘F); ⌘G / ⌘⇧G step matches |
| **Copy** | Copy the full transcript to the clipboard |
| **Detect Speakers** | Run on-device speaker detection on this recording |
| **Display** | Adjust the transcript font size and toggle speaker names |
| **Delete** | Remove the recording and its files |

## Where it's saved

Speaker names and the rich transcript are stored in a `.richtranscript.json` file next to the recording's Markdown export, so your edits persist between sessions. The AI analysis (summary, action items, tags, sentiment) is stored alongside it in an `.insights.json` file.
