## dBrief 1.2.0

The biggest update since 1.0. This release is about what happens *around* the
recording — seeing the transcript as it's spoken, finding and chatting with it
afterwards, transcribing files you never recorded, and a redesigned window to
read it all in. Plus a redesigned settings layout and a handful of fixes for
issues that quietly cost you transcript text.

### See it as it's spoken — Live Transcription

- **Real-time transcript while you record.** Turn on Live Transcription (Settings → AI & Models → Transcription) and watch words appear as people talk, fully on-device via Apple Speech. Your mic is labelled "You" and system audio "Participant", so a call reads like a conversation.
- It's a *preview* that runs alongside your chosen engine — the authoritative transcript is still produced by Whisper/Parakeet/etc. when you stop, so you lose no accuracy.
- **Chat while it's still going.** During a live recording the AI chat opens as a side panel next to the growing transcript, and anything you ask carries over to the finished recording when transcription completes.
- One caveat worth knowing: the live preview transcribes a single language at a time (Apple's streaming recognizer can't auto-detect or code-switch), so mixed-language meetings are best read from the post-recording transcript.

### Do more with finished recordings

- **Search any transcript.** A native macOS find field in the transcript window with case-insensitive regex, match highlighting, an "n of m" counter, and ⌘G / ⌘⇧G to jump between hits — each one scrolled into view.
- **Chat that survives restarts.** Your Q&A over a recording is now saved to disk next to the audio, so reopening a recording weeks later brings the whole conversation back instead of a blank slate.
- **A redesigned transcript window.** The recording viewer was rebuilt with a clean document header and a glass UI, switching between **Summary**, the full **Transcript** (with speaker turns and word-level timestamps), an **AI Analysis** panel (editable summary / action items / tags), and **Chat** — all in one place.

### Transcribe files you never recorded — Watched Folders

- Point dBrief at a folder and any audio file dropped in is automatically transcribed, analyzed, and exported through the normal pipeline. No recording session needed.
- It's polite about it: files already sitting in the folder when you add it are left alone — only new arrivals get processed — and it never grabs a file that's still being copied. Configure in Settings → Watched Folders.

### Recording that adapts to you

- **Audio follows your devices.** Change input device or output route mid-recording and dBrief keeps capturing without stopping. A pinned device that disappears (AirPods dying) falls back to the system default so you never record silence, and echo cancellation re-gates itself when you move between speakers and headphones — fixing the "volume drops on earphones" problem.
- **Quieter recording indicators.** Independently hide the floating Mini Recording window and the elapsed-time text in the menu bar (leaving just the red dot), in Settings → Recording.
- **Call prompt that gets out of the way.** The "a call was detected" popup can now auto-dismiss after a number of seconds you choose (0 = never); any interaction cancels the timer.

### Smarter meeting matching

- **Better calendar matching.** When a recording ends, dBrief now ranks overlapping calendar events by how much they actually overlap the recording's true time span (instead of just "what's on now"), so a day-long personal block no longer wins over the 30-minute meeting it contains. You can also correct or clear the auto-picked meeting from a dropdown in the post-recording sheet.

### Cleaner transcripts

- **Ignored Segments.** Common Whisper/YouTube silence hallucinations — "Thank you for watching", "Subscribe to the channel", "♪" — are dropped automatically, with a fully editable list in Settings → Transcription → Cleanup.

### Profiles & Settings

- **Per-profile AI toggle** and an on-demand symbol grid for picking a profile icon.
- **Reorganized Settings.** General is grouped into intent-based sections, AI & Models settings share consistent wording, and a redesigned Benchmark panel shows a per-model speed leaderboard.

### Fixes

- **Custom vocabulary no longer eats your transcript.** Feeding domain terms to Whisper as a decoder prompt was silently blanking most of the audio (segments kept their timestamps but lost their text — up to ~90% gone). Vocabulary spelling now happens *after* transcription as safe, whole-word corrections, so your terms are still respected and the full transcript is preserved.
- **Correct titles after AI naming.** The transcript viewer and menu-bar history now show the AI-generated title instead of the stale draft title.
- **No more blank durations.** Recording lengths no longer show up empty in the history and browser.
