# Transcript Viewer

A two-pane window for browsing your recordings, reading transcripts, following along with the audio, detecting speakers, and asking questions about a recording.

## Opening it

There are two ways in:

- **Recording library** — click the **Recording library** button in the dBrief menu bar window, or press **⌘L**. This opens the viewer with the full list of recordings.
- **Transcript action** — from [Recording History](recording-history.md), expand a recording and choose **Transcript**. The viewer opens with that recording already selected.

## Layout

- **Sidebar (left)** — saved views, a **Search recordings…** field, and your recordings. In **All Recordings**, they're grouped into **In Progress** (a live recording, if any), **This week**, and a collapsible **Earlier** section. Select one to view it.
- **Detail (right)** — the recording's title, four tabs (**Summary**, **Transcript**, **Actions**, and **Meeting Insights**), and the commands for the open tab. Finished recordings open on **Summary** when there's an AI analysis to show, otherwise on **Transcript**.
- **Assistant panel** — **Ask dBrief AI** opens as a resizable panel on the right, beside whatever you're reading, and remembers its width.

## Reading the transcript

- Choose the **Transcript** tab to read the full text as a single, continuous list. Each speaker turn is labelled and consecutive segments from the same speaker are merged for easier reading.
- **Player bar** — shown at the bottom of the **Transcript** tab. Play, pause, change the playback speed, and scrub through the recording using the **who-spoke-when timeline**, which is coloured by speaker. The transcript highlights and auto-scrolls as it plays; click any line to jump the audio to that point.

## Detecting speakers

If a recording wasn't diarized during transcription — or you want to try again — open **Re-process** and choose **Detect speakers again…**. dBrief runs on-device speaker detection on the recording's audio and assigns speakers to the existing transcript, without re-transcribing. See [Reprocessing a Recording](reprocessing.md).

- The first run downloads the speaker-detection model, which can take a while.
- Detecting speakers **replaces** any current speakers and custom names for that recording. The transcript words and timings are kept. You review this before clicking **Start**.
- Requires the recording's audio file to still be on disk.
- If you have a [Voice Library](voice-library.md), recognized people are labelled automatically; otherwise speakers come back as "Speaker 1", "Speaker 2", and so on for you to name.

## Confirming speakers before analysis

By default, dBrief labels confident voice matches and gets straight on with the AI analysis. If you'd rather check who's who first, go to **Settings → Speakers** and set **When a voice is recognised** to **Confirm first** (the default is **Optimistic**). See [Voice Library](voice-library.md).

In that mode, once a recording (or a **Detect speakers again…** run) has been diarized, dBrief opens a **Who's speaking?** review:

- The review lists the **detected speakers**. Choose one to review it, and play its voice sample to hear who it is.
- Name the voice from the **meeting participants** (the attendees of the matching calendar event), from your [Voice Library](voice-library.md), or with **Search meeting & library**, which finds people by name or company. Likely Voice Library matches are suggested.
- Not on either list? Choose **Enter a name manually**. Or choose **Keep as Speaker N** to leave the voice unnamed.
- A counter shows how many speakers you've reviewed. When you're done, click **Confirm speakers** — the names flow into the summary, action items, and the exported note. **Cancel** keeps dBrief's best guess.

Naming a speaker yourself, or keeping them unnamed, clears any identity the Voice Library had suggested for that voice.

## Renaming speakers

Once a recording has speakers (from diarization at transcription time or from **Detect speakers again…**), each turn in the transcript shows a speaker label. The **Speakers** card on the **Meeting Insights** tab lists each speaker too.

Click a speaker label to open its menu. Everything is chosen from a list — no typing needed for the common cases:

- **Rename to** — pick a name listed under **In this meeting** (your post-recording participants and calendar attendees) or **Voice library**. The name applies to every turn from that speaker. If you pick a name that already belongs to another speaker, the two **swap** names — the quick fix for when diarization mixed up who's who, with no one lost. (Need a name that isn't listed? **Custom name…** lets you type one. With no names to suggest, the menu shows **Rename…** instead.)
- **Move this turn to** another speaker — and, when the speaker has more than this turn, **Move all "*name*" to** another speaker (which merges them).
- **Save "*name*" voice to library** — adds an already-named speaker's voice to your [Voice Library](voice-library.md) without renaming.
- **This is me** — mark (or clear) which speaker is you.

Changes are saved alongside the recording and used everywhere, including the Markdown export. Naming a speaker also teaches your [Voice Library](voice-library.md), so the same person is recognized in future recordings. If the recording already has an AI analysis, dBrief offers to regenerate it with the new names.

If you entered participant names in the post-recording sheet, dBrief maps them to speakers in order automatically.

## Asking about the recording

Click **Ask dBrief AI** (sparkle icon) to open the assistant as a side panel beside the transcript or summary; click it again to close it. The panel can be dragged wider or narrower and remembers its size. The conversation is saved with the recording, so it's still there next time. See [Transcript Chat](../ai-analysis/transcript-chat.md).

## Viewing and editing the AI analysis

The recording's AI output is spread across three tabs:

- **Summary** — the meeting summary.
- **Actions** — action items grouped by owner. Tick one off to mark it done; the tab shows how many are unfinished.
- **Meeting Insights** — recording details, participants, speakers, tags and sentiment, and processing details.

Working with it:

- **Copy** — copies the content of the open tab as clean text, so you don't have to select it by hand.
- **Edit** — on the **Summary** tab, edits the summary in place; click **Save** (or press **⌘S**) or **Cancel**. On **Actions** or **Meeting Insights**, it opens **Edit actions and tags**, where you add or remove action items and edit the tags. Sentiment is shown for reference but isn't editable.
- **Saving** updates the recording's saved analysis **and** rewrites the matching sections of the exported Markdown file in place — in your transcription folder or Obsidian vault — leaving the transcript and the rest of the note untouched. Other integrations (Apple Notes, Reminders, webhooks) are not re-sent, so editing won't create duplicates.
- **Spoken Summary** — on the **Summary** tab, choose **Generate Spoken Summary** to turn the summary into a short audio briefing you can listen to. Once saved, use **Play Spoken Summary** or **Regenerate Spoken Summary**. See [Spoken Summary](../ai-analysis/spoken-summary.md).

The AI analysis is saved automatically when a recording is processed. Recordings without one show "No analysis yet", with a **Generate summary, actions, and tags** button.

## Searching the transcript

Use the **Search transcript** field at the top of the **Transcript** tab (or press **⌘F** from any tab) to find text in a long transcript.

- Every match is highlighted, and the match you're currently on is highlighted more strongly.
- The field shows a **"3 of 12"** counter. Use the **up/down arrows** next to it — or **⌘G** (next) and **⌘⇧G** (previous), or **Return** for next — to jump between matches. Each jump scrolls the match into view.
- Search understands **regular expressions**, so `\baction\b` matches the whole word "action" only. Plain words work as you'd expect. An invalid pattern shows "Invalid pattern".
- Press **Esc** to close search and clear the highlights.

Search covers the transcript text of a finished recording. It isn't available for the live (in-progress) transcript.

## Viewer controls

The icons next to the tabs:

| Icon | What it does |
|---|---|
| **Display options** | Adjust the font, text size, and transcript density, and toggle speaker names |
| **Privacy receipt** (lock-shield) | Review [processing and delivery evidence](../reference/privacy-receipts.md) |
| **Delete** (trash) | Remove the recording and its files |

The commands below them:

| Command | What it does |
|---|---|
| **Copy** | Copy the content of the open tab to the clipboard |
| **Edit** | Edit the summary, or the action items and tags (not on the Transcript tab) |
| **Re-process** | Retranscribe, re-run AI analysis, detect speakers again, link a calendar meeting, or restore previous results |
| **Spoken Summary** | Generate or play an audio briefing (Summary tab only) |
| **Ask dBrief AI** | Open or close the assistant side panel |

## Where it's saved

Speaker names and the rich transcript are stored in a `.richtranscript.json` file next to the recording's Markdown export, so your edits persist between sessions. The AI analysis (summary, action items, tags, sentiment) is stored alongside it in an `.insights.json` file.

## Search and reprocess the library

The sidebar's [library search and saved views](recording-history.md) help you find recordings across your whole collection. This is separate from **⌘F**, which searches within the open transcript.

Use **Re-process** for [retranscription, AI analysis, or speaker detection](reprocessing.md), and the **Privacy receipt** icon in the viewer header to review [processing and delivery evidence](../reference/privacy-receipts.md).
