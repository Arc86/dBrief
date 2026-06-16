## dBrief 1.2.0

A feature release focused on getting more out of your recordings after the fact —
a drop-in transcription queue, searchable transcripts, persistent chat, and
audio that follows your devices automatically while recording.

**Highlights**

- **Watched Folders** — point dBrief at a folder and any audio file dropped in is automatically transcribed, analyzed, and exported through the normal pipeline. No recording needed; existing files in the folder are left alone, only new arrivals are processed. Configure in Settings → Watched Folders.
- **Transcript search** — a native macOS find field in the transcript window with case-insensitive regex, match highlighting, an "n of m" counter, and ⌘G / ⌘⇧G navigation that scrolls each hit into view.
- **Transcript chat that survives restarts** — your Q&A over a recording is now saved to disk alongside the audio, so reopening a recording brings the whole conversation back. Chat started during a live recording carries over to the finished transcript.
- **Audio follows your devices** — change input device or output route mid-recording and dBrief keeps capturing without stopping: a pinned device that disappears (AirPods dying) falls back to the system default, and echo cancellation re-gates itself when you move between speakers and headphones (fixing the "volume drops on earphones" issue).

**Improvements**

- **Ignored Segments** — common Whisper/YouTube silence hallucinations ("Thank you for watching", "Subscribe to the channel", "♪") are dropped from transcripts by default, with an editable list in Settings → Transcription → Cleanup.
- **Call-detection prompt auto-dismiss** — the detected-call popup can now dismiss itself after a configurable number of seconds (0 = never); any interaction cancels the timer.
- **Recording-indicator toggles** — independently hide the floating Mini Recording view and the elapsed-time text in the menu bar (leaving just the red record dot), in Settings → Recording.

**Fixes**

- The transcript viewer and menu-bar history now show the AI-generated title instead of the stale draft title after post-processing.
- Recording durations no longer show up blank in the history and browser (sidecar key mismatch).
