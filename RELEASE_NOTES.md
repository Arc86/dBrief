## dBrief 1.3.0

This release is about **who** said what. dBrief now builds a private, on-device
library of voices so people you meet with are recognized by name across
recordings — not just diarized within one. Around that sits a new way to confirm
speaker names before analysis, much better speaker handling on long recordings,
AI that knows who's likely in the room, and a top-to-bottom visual refresh.

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

### Rename and reassign speakers, properly

- Click a speaker on any turn to **rename** them, **swap** two speakers who got mixed up, **move** a single turn or all of a person's turns to someone else, or mark **"this is me."** Renaming to a name that already exists swaps the two instead of losing anyone.

### A fresh look

- **A redesigned menu-bar popover, post-recording sheet, and About screen** with a cohesive brand palette, gradient accents, and glass surfaces.
- **A rebuilt transcript window** — Summary-first by default, a segmented Summary / Transcript switch, a resizable chat side panel that remembers its size, a who-spoke-when timeline above the player, grouped sidebar ("In Progress" / "This week" / "Earlier"), and tidy auto-hiding scrollbars.
- **Prefer it calmer?** A new **"Reduce neon accents"** toggle (Settings → General) swaps the glowing gradients and neon dark-mode backdrop for plain, flat colors.

### Other improvements

- **Vocabulary has its own tab.** Domain terms moved out of Transcription into a dedicated **Vocabulary** settings tab — a cleaner inline editor for the names and jargon dBrief should spell correctly.
- **Per-recording performance breakdown.** The Benchmark panel (Power User Mode) now lists recent transcriptions individually, each expandable into a step-by-step timeline (finalize, transcribe, diarize, AI, vocabulary, title) with a "slower than usual" flag.

### Fixes

- **No more false "Low RAM" warnings.** The Low RAM tag during processing now appears only under genuine, critical memory pressure instead of the routine warnings macOS raises on 16 GB Macs.
- **Transcript chat panel no longer overlaps the transcript** and can be dragged to resize.
