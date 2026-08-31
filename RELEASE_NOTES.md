## dBrief 1.3.8

**Choose exactly which calendars dBrief listens to.** Calendar matching now respects a per-calendar allow-list, a tunable match window, and an option to see the whole day's meetings when picking manually.

### Calendar matching, your way

- **Pick which calendars count.** A new **Calendars** menu in **Settings → General → Calendar** lets you limit iCal matching to specific calendars — handy when work and personal calendars share a name. **All Calendars** stays the default and automatically covers calendars added later; an explicit selection never silently widens back to everything if one of your chosen calendars disappears.
- **Control how close a match has to be.** A new **Automatic match window** picker (0–60 minutes, default 15) decides how far a non-overlapping event's start time can be from the recording start and still auto-fill the meeting. Set it to **Only overlapping** for the strictest matching.
- **See the whole day when picking manually.** **Show all meetings from the recording day** expands the post-recording Meeting picker with every event on that calendar day — suggested matches first, then the rest chronologically, all-day events last — without changing what dBrief picks automatically.
- **All-day events are now labeled** in the Meeting picker instead of showing a confusing time range.

---

## dBrief 1.3.7

**Your voice library grew up, and one attendee is one person again.** The Voice Library tab becomes a searchable two-pane list with companies, and the participants list stops splitting names like "den Boer, Bart" into two people.

### Voice Library: search, companies, two panes

- **A proper master-detail layout.** **Settings → Voice Library** now has a searchable people list beside a detail pane — search by name or company, filter by company, sort, and collapse company groups. Everything you could do before (rename with merge-on-collision, merge, forget a person, delete a single voiceprint) works the same way.
- **Each person can carry a company**, and dBrief fills it in for you where it can: when a voice is enrolled, it matches the name against the meeting's calendar attendees and derives the company from their email domain. It only ever fills a blank — your own entry is never overwritten.
- **Fixes:** a company edit in progress is no longer discarded when the list reloads after a rename, merge, or voiceprint delete; a search that matches nothing now says so instead of showing a blank pane; and the people list no longer renders as a translucent panel against the settings window.

### One attendee is one person again

- **Names like "den Boer, Bart" stay whole.** Directory calendars (Exchange/Outlook) hand over attendee names surname-first, and dBrief was splitting each one into two participants — so a five-person meeting showed eight names, and the broken names carried into the AI summary, the speaker mapping, and your voice library. Each attendee is now one participant, shown naturally as "Bart den Boer".
- **Participant names are editable.** Click a name in the post-recording sheet to correct it in place — Return commits, Escape reverts. No more deleting the chip and retyping it.
- **The meeting's people are remembered.** Reopen a past recording, click a speaker label, and the names from that meeting now appear under **In this meeting**, above your voice library — instead of the library alone. Applies to recordings processed from this version onward.

---

## dBrief 1.3.6

**dBrief knows when your meeting ends — and shows you how long transcription has left.** This release closes the loop on call detection (it can now stop recording when the call wraps, not just start when it begins) and replaces the indeterminate "working…" spinner with a real progress bar and time estimate.

### Stop recording when the call ends

- **A new "When a call ends" option** in **Settings → General → Call Detection**: *Do nothing*, *Ask me* (the default), or *Stop automatically*. Leave a Zoom/Teams/Slack/Meet meeting and dBrief can wrap the recording for you — no more recordings that run for an hour after everyone's gone.
- **Scope it your way.** An **Apply to** picker chooses whether this acts only on recordings that a detected call started, or on any recording that's currently running.
- **It waits to be sure.** A short grace period ignores brief mic drops (mute, a device switch), so muting yourself never ends the recording — only actually leaving the meeting does.

### See how long transcription will take

- **A real progress bar with a time estimate.** The "Finalizing audio" and transcription steps now show determinate progress and an estimated time left, instead of an indeterminate spinner. Long recordings — where transcript segments arrive in late bursts — no longer leave the bar pinned near zero.

### Fixes

- **Re-transcribing now records its stats.** Transcribing an existing recording from History (or re-transcribing) properly measures its audio duration again, so the Benchmark panel shows the real ×realtime speed and "Avg. audio" instead of 0, and the lifetime "transcribed by dBrief" total advances.
- **The participants list can't push the buttons off-screen.** Linking a recording to a calendar event with a long attendee list used to grow the Participants box until the Skip / Queue / Process buttons dropped below the menu — the list now caps its height and scrolls internally.
- **A rare transcription hang is fixed.** A specific out-of-order message on the on-device ML pipe could leave a transcription waiting forever with no error; it now fails cleanly and recovers instead.

---

## dBrief 1.3.5

**Record your next meeting without waiting on the last one.** Back-to-back meetings used to be blocked — while a recording was still transcribing and analyzing, the Record button and hotkey were unavailable. Now capture and processing are fully independent, so you can start the next meeting the moment it begins.

### Record while a recording is still processing

- **The Record button and hotkey stay live during processing.** Hit ⌃⌥⌘R (or click Record) as soon as your next meeting starts, even while dBrief is still transcribing or summarizing the previous one.
- **Nothing gets lost.** If a new recording finishes while an earlier one is still being processed, it's automatically queued and drains on its own, one at a time, once the current job completes — no manual "Process Queue" needed.
- **Both show up clearly.** The transcript browser pins the live recording *and* the one being processed separately, and their live transcripts stay isolated so the new capture never bleeds into the earlier recording's view.

### Polished speaker review

- **The confirm-first speaker-review window sizes and scrolls better.** It fits its content more cleanly and scrolls comfortably when there are many speakers to confirm.

### Under the hood

- **Updated on-device ML and updater components.** FluidAudio, the MLX runtime, and Sparkle are all on newer releases — including a Sparkle fix that improves the update dialog for menu-bar apps like dBrief that run without a dock icon.

---

## dBrief 1.3.4

**Faster, lighter, and steadier.** This release is a top-to-bottom performance sweep — the same dBrief, using noticeably less CPU, GPU, and memory on the paths that do the most work. Nothing about how you use it changes; it just runs leaner. Plus a few worthwhile fixes.

### Faster transcription, especially on long recordings

- **Long recordings stop reloading the model.** A recording over 30 minutes is split into parts and transcribed piece by piece — which used to reload the Whisper (and diarization) models for *every* part. A 3-hour meeting reloaded them about six times. Now the models stay resident across all parts, so long recordings finish sooner.
- **Each part is decoded once.** The audio for each part is now decoded a single time and shared across transcription, diarization, and voiceprints, instead of being re-decoded two or three times.

### Much lower memory use

- **Waveforms stream instead of loading whole.** Drawing the audio waveform used to decode the entire file into memory at once — hundreds of megabytes for a 30-minute recording. It now streams in small blocks.
- **Webhook uploads stream from disk.** Sending audio to a webhook no longer holds the whole file in memory twice.
- **Leaner chat and history.** The transcript-chat cache is now capped, and recent-recording lists load off the main thread so the app stays responsive.

### Smoother, quieter UI

- **Playback no longer re-computes the transcript ten times a second.** Speaker turns are cached, so scrubbing and playing back a transcript is smooth even on long recordings.
- **Calmer live transcript and meters.** The live transcript stops re-merging every finalized line on each partial update, and the recording meter runs from a single source (peak level at 10 Hz, elapsed time at 1 Hz) instead of two overlapping loops.
- **Snappier chat rendering.** Streaming AI replies render as plain text while they arrive and format once they're done, instead of re-parsing Markdown on every token.
- **Less idle work.** The watched-folders poller no longer wakes every few seconds when the feature is off, and prompt-editor edits are batched instead of writing to disk on every keystroke.

### Fixes

- **A recorder resource is now released on stop.** The microphone-activity listener used for call detection wasn't being detached when recording stopped; it now is.
- **No more spurious "finalization error" on a silent mic track.** A recording with an empty microphone track (e.g. system-audio only) no longer surfaces a benign empty track as an error.
- **Speaker-review window no longer crashes on macOS 26.** The confirm-first speaker-review window could crash on macOS 26; that's fixed.

---

## dBrief 1.3.3

**Cleaner notes and titles you're in control of.** This release polishes how dBrief exports to Obsidian and how it handles the meeting title you type — plus your custom analysis prompts now reach the on-device engines too.

- **Obsidian-safe tags.** Tags are now sanitized into valid Obsidian hashtags before they're written to your notes — spaces and other invalid characters are normalized, so a tag like `Q3 planning` becomes a clickable `#q3-planning` instead of breaking the frontmatter or splitting into pieces.
- **Your title stays your title.** If you type (or keep) a custom meeting title in the post-recording sheet, dBrief no longer overwrites it with an AI-generated one during processing — even when the recording is queued and analyzed later. Leave the title on the default and AI titling works exactly as before.
- **Custom analysis prompts everywhere.** Your Summary / Action Items / Tags prompts (Settings → AI Analysis) are now honored by the on-device **Gemma** and **Local CLI** engines, not just Remote Endpoint — so the analysis follows your instructions no matter which AI backend you run.

---

## dBrief 1.3.2

**Fixes microphone and calendar access on the notarized build.** The first notarized release (1.3.1) ran under Apple's hardened runtime, which — unlike the older self-signed builds — gates a few privacy resources behind explicit entitlements. Those were missing, so **Microphone**, **Calendar**, and **Apple Reminders** couldn't be enabled no matter what you toggled in System Settings (Screen Recording and Speech were unaffected). 1.3.2 adds the required entitlements; grant the prompts as normal and they work. If you installed 1.3.1, update to 1.3.2 and allow Microphone/Calendar when asked.

---

## dBrief 1.3.1

**dBrief is now notarized by Apple.** Fresh downloads open with a normal double-click — no more "can't be opened" Gatekeeper warning and no `xattr` workaround. In-app updates (added in 1.3.0) carry the notarization through automatically, so you stay current without ever re-downloading. Everything else is identical to 1.3.0 below.

---

## dBrief 1.3.0

This release is about **who** said what. dBrief now builds a private, on-device
library of voices so people you meet with are recognized by name across
recordings — not just diarized within one. Around that sits a new way to confirm
speaker names before analysis, much better speaker handling on long recordings,
AI that knows who's likely in the room, spoken audio summaries you can listen to
hands-free, a top-to-bottom visual refresh, and in-app updates so you stay current
without re-downloading.

### Know who's talking — the Voice Library

- **Recognize people across recordings.** When diarization is on, dBrief extracts a private voiceprint for each speaker and remembers the ones you name. Next time that person turns up — in any recording — they're labelled automatically. It's all on-device: voiceprints live in a single local library, never leave your Mac, and are never uploaded.
- **It only acts when it's sure.** A voice is auto-labelled only when there's a confident match *and* the person is plausibly in the meeting (from your calendar or the participants you entered). When it isn't sure, it leaves a neutral "Speaker 1" rather than guess wrong.
- **Manage it in one place.** A new **Settings → Voice Library** tab lists everyone dBrief knows, with how many samples it has and when each was last heard — rename (with a merge offer if the name already exists), merge two people, or forget a person or an individual voiceprint.

### Confirm who's who before analysis

- **A new "confirm first" option.** Turn it on in **Settings → Transcription** and, after a recording is diarized, dBrief pauses to show a quick speaker-review window — one card per voice, each with a short audio snippet to play and suggested names from your library. Fix anything that's off, hit confirm, and the corrected names flow into the summary, action items, and exported note.
- Prefer the old behaviour? The default ("optimistic") still auto-labels confident matches and runs straight through without interrupting you.
- **Re-checking is just as easy.** Re-running speaker detection from the transcript window goes through the same confirm-first review, so you're always in control of the final names.

### Better speakers on long recordings

- **"Speaker 1" stays the same person throughout.** Recordings over 30 minutes are split into parts and transcribed separately — which used to mean each part numbered its speakers from scratch. dBrief now re-unifies them by voice, so one person keeps one identity (and one name) across the whole meeting.

### Smarter, name-aware AI

- **The AI knows who's likely in the room.** Participant names — from your calendar event or what you typed in — are now passed to the analysis, so summaries and action items spell people's names correctly and attribute points to the right person.

### Listen instead of read — Spoken Summary

- **Hear your meeting back.** A new **Spoken Summary** turns a recording's summary and action items into a short, natural narration you can play — great for catching up hands-free. Generate it from the transcript window's Summary tab; once saved it plays back instantly.
- **Two on-device voices.** Synthesis runs entirely on your Mac: **Kokoro** (fast, English) is the default, with multilingual **Qwen3** available. Pick the engine and voice in the new **Settings → Spoken Summary** tab, and audition it with **Preview voice** before committing.

### Rename and reassign speakers, properly

- Click a speaker on any turn to **rename** them, **swap** two speakers who got mixed up, **move** a single turn or all of a person's turns to someone else, or mark **"this is me."** Renaming to a name that already exists swaps the two instead of losing anyone.

### A fresh look

- **A redesigned menu-bar popover, post-recording sheet, and About screen** with a cohesive brand palette, gradient accents, and glass surfaces.
- **A rebuilt transcript window** — Summary-first by default, a segmented Summary / Transcript switch, a resizable chat side panel that remembers its size, a who-spoke-when timeline above the player, grouped sidebar ("In Progress" / "This week" / "Earlier"), and tidy auto-hiding scrollbars.
- **Prefer it calmer?** A new **"Reduce neon accents"** toggle (Settings → General) swaps the glowing gradients and neon dark-mode backdrop for plain, flat colors.

### Other improvements

- **In-app updates.** dBrief now updates itself with Sparkle — it checks for new versions (automatically, or via **Settings → General → Software update → Check Now**), then downloads, verifies, and installs them in place. No more re-downloading the DMG by hand. Updates are cryptographically signed (EdDSA), so only genuine dBrief releases install.
- **Vocabulary has its own tab.** Domain terms moved out of Transcription into a dedicated **Vocabulary** settings tab — a cleaner inline editor for the names and jargon dBrief should spell correctly.
- **Per-recording performance breakdown.** The Benchmark panel (Power User Mode) now lists recent transcriptions individually, each expandable into a step-by-step timeline (finalize, transcribe, diarize, AI, vocabulary, title) with a "slower than usual" flag.

### Fixes

- **No more false "Low RAM" warnings.** The Low RAM tag during processing now appears only under genuine, critical memory pressure instead of the routine warnings macOS raises on 16 GB Macs.
- **Transcript chat panel no longer overlaps the transcript** and can be dragged to resize.
