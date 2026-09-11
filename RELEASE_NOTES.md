## dBrief 1.4.2

### Settings usability

- Settings are grouped into App, Recording, Processing and Workflow. Find the shortcut and call detection under Recording, folders and retention under Storage, calendars under Integrations, and shared task choices under After Recording.
- Search settings with ⌘F using names, help terms or older labels. Search stays on your Mac and does not index saved values or credentials. Advanced results can reveal their controls without changing the saved advanced-settings preference.
- Profiles remain available outside advanced mode. Inherited values and relevant overrides are easier to see, and opening an editor does not change the profile selected for recording.
- Shared-default reset now requires confirmation. Inactive or unsupported options explain their behavior while retaining saved values.
- Vocabulary has visible Edit/Delete actions, explicit Save/Cancel and duplicate feedback. Native fields and switches have clearer accessible names, and failures provide expandable safe diagnostic details.

### Calendar linking

- **Link a saved recording to a calendar meeting after the fact** — pick from that day's meetings, ranked by likely match, even if no calendar event was found (or the wrong one was picked) when it was first recorded.
- Optionally update the recording's title and participants from the linked meeting, then re-run AI analysis so the summary, action items, and tags reflect the meeting's agenda and attendees.
- Previously exported notes and anything already sent to an integration are left untouched — linking a meeting never re-triggers those on its own.

### Spoken Summary

- **28 English Kokoro voices** (American and British, female and male) are now available and download-verified, instead of just the default voice.

### Fixes

- **Switching microphones is more reliable.** "System Default" now always resolves to an actual device instead of silently keeping a stale or disconnected one.
- **A recording that crashes mid-capture is no longer unreadable.** Audio is written in a format that stays decodable even if dBrief exits before the file is closed properly, instead of losing hundreds of MB to an incomplete file.
- **Recording action dialogs (calendar linking, reprocessing) now open in their own window** instead of being tied to the transient menu-bar popover, so they no longer disappear if the popover closes.
- **Local CLI AI analysis recovers from malformed JSON** — a one-time repair pass fixes broken quoting/escaping in the model's response instead of failing outright, and failures now explain exactly what was wrong (missing field, bad value, malformed syntax) instead of a raw JSON error.

---

## dBrief 1.4.1

### Transcript chat

- **Stop generating**, mid-response — a Stop control (also triggered by Esc) cancels a streaming reply immediately, without losing the rest of the conversation.
- **Runaway responses now cut themselves off.** A reply that starts repeating itself, or one that just keeps growing, stops on its own with a small note explaining why, instead of streaming forever.
- **The Local CLI chat fallback can now use a configured remote endpoint**, not just an on-device engine — the Endpoints section in Settings → AI Analysis appears whenever the fallback needs it.
- Removed a backend-specific reasoning-suppression flag for `gpt-oss` models that llama.cpp servers rejected; Groq/vLLM/Ollama backends are unaffected.
- Simplified Markdown and chat message rendering, with added test coverage for cancellation, repetition detection, and restoring a saved conversation exactly.

### Fixes

- **Retranscription now shows real progress** — a step name, progress bar, and detail line — instead of sitting on a generic "Processing…" banner.
- **The live transcript preview updates correctly during reprocessing and after it finishes**, rather than sometimes showing a stale staged copy of the recording.

---

## dBrief 1.4.0

**Nothing gets stuck, and nothing is final.** If processing is interrupted — a quit, a crash, a restart — dBrief now picks up where it left off instead of starting over. You can manage the processing queue directly, retry a single integration delivery without redoing the work, and reprocess a saved recording (retranscribe, redo the AI analysis, or redetect speakers) whenever the first pass wasn't quite right. Plus full-text search across your whole recording library, meeting profiles that can match themselves, and four security hardening fixes.

### Reprocess a recording after the fact

- **Retranscribe saved audio** from the transcript viewer or a recording's menu — fix the spoken language, or switch to a different transcription engine or model — without losing anything else attached to the recording.
- **Choose only the work you need.** Re-run AI analysis on the current transcript, or redetect speakers while keeping the transcript's words and timing untouched.
- **Nothing is lost until a replacement succeeds.** A reprocessing attempt is staged privately; if it stops or fails, it stays in Queue & Recovery with Resume and Discard, and you can restore the previous result.
- **Dependent results stay honest.** Redoing just the transcript marks any kept summary/action items as based on the old transcript. Reprocessing never automatically re-exports notes, re-sends integrations, or re-enrolls voices — that's always your call.

### Never lose your place again

- **Resume interrupted work from where it stopped.** If dBrief is interrupted mid-processing, it now picks back up from the last completed stage — audio finalizing, transcription, speaker detection, AI analysis, or Markdown export — instead of starting over.
- **Speaker-review decisions survive a restart.** If you use confirm-first speaker review, that step still happens on resume; it's never silently skipped.
- **Markdown export is safer.** The destination and content are saved before writing, so a name collision creates a new file or stops with a clear, retryable error instead of overwriting something else.
- **Stopping a job keeps its progress.** A stopped or failed recording stays put for you to resume — it doesn't restart on its own.

### A queue you can actually manage

- **Reorder, run, or remove queued recordings** — move an item up, down, or to the front; process one on its own; or drop it from the queue without deleting its audio.
- **Pause the queue, even across restarts.** The current job finishes first; ordering and pause state are remembered, and paused items wait for you to hit Process Queue.
- **One place for things that need attention.** Failed or interrupted processing and unfinished integration deliveries show up together, each with Resume, Integrations, or Dismiss.
- **Deleting a recording cleans up after itself** — its queue and recovery entries go too, while notes you've already exported or sent to an integration are left alone.

### Safer integration retries

- **Retry one destination at a time**, reusing its already-generated content — no need to retranscribe or rerun AI. A destination that already confirmed delivery won't be resent.
- **Uncertain sends ask first.** If a previous delivery's outcome is unclear, or you've changed the destination or its settings, dBrief checks with you before retrying.
- **No surprise sends after a crash recovery.** Recovery stops after generating the Markdown note — continuing on to Notion, webhooks, and the rest is always something you trigger yourself.

### Search your whole recording library

- **Full-text search across everything** — transcripts, titles, participants, speakers, tags, action items, owners, dates, and the app the call happened in.
- **Saved views** for Unfinished Actions, Failed Jobs, Queued/Interrupted, Recently Processed, and People I Met This Month.
- Action-item completion is remembered and reflected everywhere it's shown.

### Meeting profiles that match themselves

- **Profiles can match automatically** — by recording title, call app, calendar details, or attendee email domain — and the post-recording screen shows why a profile matched, with an easy manual override.
- **Choose what happens next, per profile:** stay on the review screen (still the default), process automatically, or queue automatically. Automatic actions give you a cancellable ten-second countdown first.

### See exactly what happened to a recording

- **A privacy receipt for every recording.** Open it from the recording's menu to see every processing and delivery step that actually ran — which provider handled it, what kind of data it touched, and the outcome.
- **It never includes the sensitive part.** Receipts record that a step happened, not your audio, transcript content, prompts, or credentials — and they say plainly when there's no evidence for a step, rather than assuming it stayed local.

### Security

- **Webhook credentials move to Keychain.** Authentication headers and tokens for webhook integrations are no longer stored in plain preferences.
- **Video-URL input is validated more strictly**, so a pasted link can no longer be interpreted as a command-line option by the YouTube/video downloader.
- **Retention cleanup only removes files dBrief created.** Auto-delete no longer risks deleting unrelated notes or files if you've pointed it at a shared folder.
- **Redirects can no longer carry your credentials to another server.** If a configured endpoint tries to redirect a request elsewhere, dBrief now rejects it instead of following it with your API key, recording, or transcript attached.

### Fixes

- **The waveform meter now reflects normal speech.** A proper decibel scale on both channels replaces one that looked nearly silent at typical mic levels.
- **No more clipped audio at the very end of a recording**, including when you stop mid-buffer or switch input devices.
- **Stopped recordings stay visible in Queue & Recovery**, instead of showing a "needs attention" badge for a recording you can no longer see or resume.
- **Smoother transcript-library sidebar** — filters fit properly, and background refreshes no longer cause a visible flicker.
- **Clearer processing previews.** You can see the finished transcript while AI analysis is still running, and the processing button now says exactly what it'll open.
- **More reliable YouTube/video transcription.** dBrief finds an installed Deno or Node runtime even when macOS launches it with a limited PATH (a supported runtime and yt-dlp are still required).

---

## dBrief 1.3.9

**Nothing is lost anymore, even if dBrief or your Mac doesn't shut down cleanly.** This release is about durability: an interrupted recording — a crash, a forced quit, a power loss — is now recovered into History automatically the next time dBrief launches, instead of leaving orphaned audio files behind.

### Recover interrupted recordings

- **A crashed or force-quit recording is no longer gone.** dBrief now checkpoints an in-progress capture to disk as it records. If the app (or the Mac) goes down mid-recording, the next launch finds it, finalizes the audio, and drops it straight into History — you'll see a dismissible banner confirming what was recovered.
- **If recovery can't finish** (e.g. the recording's storage location is disconnected), the raw capture stays safe on disk and the banner tells you so, with a **"Show recovery files"** button (Settings → About) to go find it directly.
- **A new "Export diagnostics…" button** in **Settings → About** builds a support report covering app/storage/recovery/recording-lifecycle events — never audio, transcripts, meeting titles, names, file paths, or credentials.

### Steadier finalization

- **ffmpeg failures during merge/transcode are handled more gracefully**, reducing spurious finalization errors on already-tricky recordings.

### Security

- **Remote endpoint API keys move to Keychain.** Transcription/AI endpoint credentials stored in plain UserDefaults are migrated to Keychain automatically and safely — a key is only cleared from the old location after its Keychain write is confirmed, so a transient failure can't lose a credential.

### Fixes

- **Permission guidance is more consistent.** Onboarding and Settings → Permissions now derive their "Request access" / "Open System Settings" prompts from one shared rule, so a denied permission always points you to the right next step.
- **About screen animations respect Reduce Motion.**

---

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
