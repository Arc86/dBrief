# Transcript Viewer

A two-pane window for browsing your recordings, reading transcripts, following along with the audio, detecting speakers, and chatting about a recording.

## Opening it

There are two ways in:

- **Open Viewer** — click the **Open Viewer** button in the *Recent Recordings* header of the dBrief menu bar window. This opens the viewer with the full list of recordings.
- **Transcript action** — from [Recording History](recording-history.md), expand a recording and choose **Transcript**. The viewer opens with that recording already selected.

## Layout

- **Sidebar (left)** — lists your recordings, grouped into **In Progress** (a live recording, if any), **This week**, and a collapsible **Earlier** section. Select one to view it.
- **Detail (right)** — a **Summary / Transcript** switch in the toolbar, the selected content, a player bar, and the toolbar actions. Finished recordings open on **Summary** when there's an AI analysis to show, otherwise on the transcript.
- **Chat panel** — the assistant opens as a resizable panel on the right, beside whatever you're reading, and remembers its width.

## Reading the transcript

- Switch to **Transcript** in the toolbar to read the full text as a single, continuous list. Each speaker turn is labelled and consecutive segments from the same speaker are merged for easier reading.
- **Player bar** — play, pause, and scrub through the recording using the waveform. A slim **who-spoke-when timeline** above the controls shows how the speakers are distributed, and stays put as you switch between Summary and Transcript. The transcript highlights and auto-scrolls as it plays; click any line to jump the audio to that point.

## Detecting speakers

If a recording wasn't diarized during transcription — or you want to try again — click the **Detect Speakers** button (the people icon) in the toolbar. dBrief runs on-device speaker detection on the recording's audio and assigns speakers to the existing transcript, without re-transcribing.

- The first run downloads the speaker-detection model, which can take a while.
- Detecting speakers **replaces** any current speakers and custom names for that recording, so you'll confirm before it runs.
- Requires the recording's audio file to still be on disk.
- If you have a [Voice Library](voice-library.md), recognized people are labelled automatically; otherwise speakers come back as "Speaker 1", "Speaker 2", and so on for you to name.

## Confirming speakers before analysis

By default, dBrief labels confident voice matches and gets straight on with the AI analysis. If you'd rather check who's who first, switch the **speaker recognition mode** to *confirm first* in [Settings → Transcription](../transcription/transcription-overview.md).

In that mode, once a recording (or a re-run of **Detect Speakers**) has been diarized, dBrief pops up a short **speaker review**:

- One card per voice, each with a snippet you can **play** to hear who it is.
- Suggested names from your [Voice Library](voice-library.md) when there's a likely match.
- Edit any name, then **Confirm** — the corrected names flow into the summary, action items, and the exported note. **Cancel** keeps dBrief's best guess.

## Renaming speakers

Once a recording has speakers (from diarization at transcription time or from **Detect Speakers**), a row of coloured speaker chips appears above the transcript, and each turn shows a speaker label.

Click a turn's speaker label to open its menu. Everything is chosen from a list — no typing needed for the common cases:

- **Rename to** — pick a name from your post-recording participants, calendar attendees, or another speaker. The name applies to every turn from that speaker. If you pick a name that already belongs to another speaker, the two **swap** names — the quick fix for when diarization mixed up who's who, with no one lost. (Need a name that isn't listed? **Custom name…** lets you type one.)
- **Move this turn to** another speaker — and, when the speaker has more than this turn, **Move all "<name>" to** another speaker (which merges them).
- **This is me** — mark (or clear) which speaker is you.

Changes are saved alongside the recording and used everywhere, including the Markdown export. Naming a speaker also teaches your [Voice Library](voice-library.md), so the same person is recognized in future recordings.

If you entered participant names in the post-recording sheet, dBrief maps them to speakers in order automatically.

## Chatting about the recording

Click the **Chat** button (speech-bubble icon) in the toolbar to open the assistant as a side panel beside the transcript or summary; click it again to close it. The panel can be dragged wider or narrower and remembers its size. See [Transcript Chat](../ai-analysis/transcript-chat.md).

## Viewing and editing the AI analysis

The recording's AI output lives in the **Summary** view — choose **Summary** in the toolbar's view switch to see it, shown in cards for **Summary**, **Action Items**, and **Tags & Sentiment**, just like the menu bar shows after processing.

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
| **Summary / Transcript** | Switch the detail pane between the AI summary and the full transcript |
| **Chat** | Open or close the assistant side panel |
| **Search** | Find text in the transcript (⌘F); ⌘G / ⌘⇧G step matches |
| **Copy** | Copy the full transcript to the clipboard |
| **Detect Speakers** | Run on-device speaker detection on this recording |
| **Display** | Adjust the transcript font size and toggle speaker names |
| **Delete** | Remove the recording and its files |

## Where it's saved

Speaker names and the rich transcript are stored in a `.richtranscript.json` file next to the recording's Markdown export, so your edits persist between sessions. The AI analysis (summary, action items, tags, sentiment) is stored alongside it in an `.insights.json` file.
