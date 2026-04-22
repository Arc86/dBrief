# dBrief — Open Items

## Done

- [x] Add 'Disable AI processing' toggle — skip all AI steps post-recording; show only transcription options in PostRecordingSheet
- [x] Remove unnecessary memory warnings — suppress when remote endpoints are in use and when AI processing is disabled
- [x] Fix audio quality — eliminate pitch shift (lazy 48 kHz FLAC capture), muddled DSP (remove afftdn, retuned loudnorm), last-segment truncation (drain before mixer stop)
- [x] Rewrite audio pipeline — dual-track capture (system.caf + mic.caf), ffmpeg amix to M4A master, AEC toggle; fixes pitch shift, silent mic, and low-volume system audio

## Pending

- [ ] **Distribution strategy** — research and decide: GitHub Releases with notarized .app bundle vs Homebrew cask vs direct binary download
- [ ] **Output folder audit** — verify transcription output naming, location consistency, and how recordings are organized over time
- [ ] **Old recordings management** — retention policy, auto-cleanup options, or archive UI for accumulated audio files
