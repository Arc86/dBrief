# Transcript Viewer

A two-pane window for browsing your recordings, reading transcripts, following along with the audio, detecting speakers, and asking questions about a recording.

## Opening it

There are two ways in:

- **Recording library** — click the **Recording library** button in the dBrief menu bar window, or press **⌘L**. This opens the viewer with the full list of recordings.
- **Open** — from [Recording History](recording-history.md), expand a recording and choose **Open**, or right-click it and choose **Open**. The viewer opens with that recording already selected.

You can also right-click the dBrief menu bar icon and choose **Recording library**.

## Layout

- **Sidebar (left)** — saved views, a **Search recordings…** field, and your recordings. In **All Recordings**, they're grouped into **In Progress** (a live recording, if any), **This week**, and a collapsible **Earlier** section. Select one to view it.
- **Detail (right)** — the recording's title, four tabs (**Summary**, **Transcript**, **Actions**, and **Meeting Insights**, or **⌘1**–**⌘4**), and the commands for the open tab. Finished recordings open on **Summary** when there's an AI analysis to show, otherwise on **Transcript**.
- **Assistant panel** — **Ask dBrief AI** opens as a resizable panel on the right, beside whatever you're reading, and remembers its width.

## Reading the transcript

- Choose the **Transcript** tab to read the full text as a single, continuous list. Each speaker turn is labelled and consecutive segments from the same speaker are merged for easier reading.
- Paragraphs break at the end of a sentence, timecodes show hours for long meetings, and dates and times follow your Mac's 12/24-hour setting.
- **Player bar** — shown at the bottom of the viewer. Play, pause (or press **Space**), change the playback speed, and jump through the recording with the **speaker timeline**: it shows who spoke when, coloured by speaker. Click or drag it to jump; with the timeline focused, **←**/**→** skip a little. The transcript highlights and auto-scrolls as it plays; click any line to jump the audio to that point.

To read the notes or transcript full screen, open the [Focus Reader](focus-reader.md) (**⇧⌘F**).

## Detecting speakers

If a recording wasn't diarized during transcription — or you want to try again — open **Reprocess** and choose **Detect Speakers Again…**. dBrief runs on-device speaker detection on the recording's audio and assigns speakers to the existing transcript, without re-transcribing. See [Reprocessing a Recording](reprocessing.md).

- The first run downloads the speaker-detection model, which can take a while.
- Detecting speakers **replaces** any current speakers and custom names for that recording. The transcript words and timings are kept. You review this before clicking **Start**.
- Requires the recording's audio file to still be on disk.
- If you have a [Voice Library](voice-library.md), recognized people are labelled automatically; otherwise speakers come back as "Speaker 1", "Speaker 2", and so on for you to name.

## Confirming speakers before analysis

By default, dBrief labels confident voice matches and gets straight on with the AI analysis. If you'd rather check who's who first, go to **Settings → Speakers** and set **When a voice is recognised** to **Confirm first** (the default is **Optimistic**). See [Voice Library](voice-library.md).

In that mode, once a recording (or a **Detect Speakers Again…** run) has been diarized, dBrief opens a **Who's speaking?** window:

- The **Voices** list on the left shows each detected speaker and its status (**Needs a name**, **Suggested**, **Named**, **Kept unnamed**). It's hidden when there's only one voice.
- For the selected voice you see a quote of what they said, next to a play button that plays a short sample (**⌥Space**).
- **One name field** does everything: start typing to search the meeting's attendees and your [Voice Library](voice-library.md), or type a new name and choose **Use "*name*"**. The list is ranked by how closely each person's saved voice matches, with a badge for strong and possible matches. People **In this meeting** are marked.
- Use **↑**/**↓** and **Return** to assign a name without the mouse. Each answer moves you to the next voice that still needs one; **⌘↑**/**⌘↓** switch voices yourself.
- **Keep as Speaker N** leaves the voice unnamed.
- When you're done, click **Confirm speakers** (or press **Return** with the name field empty). The names flow into the summary, action items, and the exported note. **Cancel** keeps dBrief's best guess.

VoiceOver announces your progress through the voices.

Naming a speaker yourself, or keeping them unnamed, clears any identity the Voice Library had suggested for that voice.

## Renaming speakers

Once a recording has speakers (from diarization at transcription time or from **Detect Speakers Again…**), each turn in the transcript shows a speaker label. The **Speakers** card on the **Meeting Insights** tab lists each speaker too.

Click a speaker label to open its menu. Everything is chosen from a list — no typing needed for the common cases:

- **Rename to** — pick a name listed under **In this meeting** (your post-recording participants and calendar attendees) or **Voice library**. The name applies to every turn from that speaker. If you pick a name that already belongs to another speaker, the two **swap** names — the quick fix for when diarization mixed up who's who, with no one lost. (Need a name that isn't listed? **Custom name…** lets you type one. With no names to suggest, the menu shows **Rename…** instead.)
- **Move this turn to** another speaker — and, when the speaker has more than this turn, **Move all "*name*" to** another speaker (which merges them).
- **Save "*name*" voice to library** — adds an already-named speaker's voice to your [Voice Library](voice-library.md) without renaming.
- **This is me** — mark (or clear) which speaker is you.

You can do the same from the keyboard: **Recording ▸ Rename Speaker…** and **Recording ▸ This Is Me** act on the speaker who's playing (or the first one), and with VoiceOver each turn offers rename, move and "This is me" as actions.

Changes are saved alongside the recording and used everywhere, including the Markdown export. Naming a speaker also teaches your [Voice Library](voice-library.md), so the same person is recognized in future recordings. If the recording already has an AI analysis, dBrief offers to regenerate it with the new names.

If you entered participant names in the post-recording sheet, dBrief maps them to speakers in order automatically.

## Asking about the recording

Click **Ask dBrief AI** (sparkle icon) to open the assistant as a side panel beside the transcript or summary; click it again to close it. The panel can be dragged wider or narrower and remembers its size. The conversation is saved with the recording, so it's still there next time. See [Transcript Chat](../ai-analysis/transcript-chat.md).

## Viewing and editing the AI analysis

The recording's AI output is spread across three tabs:

- **Summary** — the meeting summary.
- **Actions** — action items grouped by owner. Tick one off to mark it done; the tab shows how many are unfinished. Placeholders such as "No action items identified" aren't shown or counted.
- **Meeting Insights** — recording details, participants, speakers, tags and sentiment, and processing details.

Working with it:

- **Copy** (**⇧⌘C**) — copies the content of the open tab as clean text, so you don't have to select it by hand.
- **Edit** — on the **Summary** tab, turns the summary into an editor right in the viewer: drag the handle beside a block to move it (or press **⌥⇧↑**/**⌥⇧↓**), type **/** for a menu of headings, lists and to-dos, and select text for a formatting toolbar. Click **Save** (or press **⌘S**) or **Cancel** (**Esc**). Unsaved edits survive switching to another recording and back. On **Actions** or **Meeting Insights**, **Edit** opens **Edit actions and tags**, where you add or remove action items and edit the tags. Sentiment is shown for reference but isn't editable.
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
| **Focus Reader** (two arrows) | Open the notes full screen in the [Focus Reader](focus-reader.md) (**⇧⌘F**) |
| **Display options** | Adjust the reading font, text size, and transcript density, and toggle speaker names. See [Appearance & Fonts](../reference/appearance.md) |
| **Privacy receipt** (lock-shield) | Review [processing and delivery evidence](../reference/privacy-receipts.md) |
| **Delete** (trash) | Remove the recording and its files |

The commands below them:

| Command | What it does |
|---|---|
| **Copy** | Copy the content of the open tab to the clipboard |
| **Edit** | Edit the summary, or the action items and tags (not on the Transcript tab) |
| **Reprocess** | Retranscribe, re-run AI analysis, detect speakers again, link a calendar meeting, or restore previous results |
| **Spoken Summary** | Generate or play an audio briefing (Summary tab only) |
| **Ask dBrief AI** | Open or close the assistant side panel |

## The Recording menu

While the viewer is open, the **Recording** menu in the menu bar works on the selected recording: **Play**/**Pause**, **Copy** the open tab (**⇧⌘C**), **Ask dBrief AI** (**⇧⌘I**), **Retranscribe…**, **Re-run AI Analysis…**, **Detect Speakers Again…**, **Rename Speaker…**, **This Is Me**, **Integrations…**, **Show in Finder** (**⇧⌘R**) and **Delete Recording…** (**⌘⌫**). While you're recording it also has **Pause Recording**/**Resume Recording** (**⌥⌘P**) and **Stop Recording** (**⌥⌘.**).

In the sidebar, **↑**/**↓** move between recordings and **Space** plays or pauses. Right-click a recording for **Open**, **Copy Notes**, **Show in Finder**, **Reprocess**, **Integrations…** and **Delete Recording…**. See [Keyboard Shortcuts](../reference/keyboard-shortcuts.md).

## Where it's saved

Speaker names and the rich transcript are stored in a `.richtranscript.json` file next to the recording's Markdown export, so your edits persist between sessions. The AI analysis (summary, action items, tags, sentiment) is stored alongside it in an `.insights.json` file.

## Search and reprocess the library

The sidebar's [library search and saved views](recording-history.md) help you find recordings across your whole collection. This is separate from **⌘F**, which searches within the open transcript.

Use **Reprocess** for [retranscription, AI analysis, or speaker detection](reprocessing.md), and the **Privacy receipt** icon in the viewer header to review [processing and delivery evidence](../reference/privacy-receipts.md).
