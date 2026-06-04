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

## Backlog

### Bugs

- [ ] **Waveform not responding to system audio** — the waveform visualizer in both the popup window and the menu bar item only reacts to mic audio; system audio captured via ScreenCaptureKit is not feeding the peak/level meter. Likely the level tap is only wired to the `AVAudioEngine` mic path, not the `SystemAudioCapture` / `AudioMixer` output. Fix: derive waveform levels from the mixed output buffer in `AudioFileWriter` or `AudioMixer` rather than the raw mic tap.

- [ ] **Record/Stop button inconsistently red** — the button appears grey instead of red in some states. Likely a SwiftUI state observation issue or a conditional tint modifier that is not re-evaluated when recording state changes. Investigate `RecordingControlsView` button styling and ensure `.tint`/`.foregroundStyle` reacts to `AppState.recordingState`.

### Enhancements

- [ ] **Minimize floating mini-player / popup window** — recording popup window has no minimize/collapse control. Add a minimize button that collapses to a slim title-bar-only strip (or hides to menu bar) without stopping the recording.

- [ ] **VAD with remote transcription engines** — VAD (Voice Activity Detection) is currently gated to local engines (WhisperKit). Investigate whether VAD can be applied as a pre-processing step before uploading to remote endpoints: strip silent segments client-side, then send the trimmed audio. If feasible, expose the toggle for remote engines too.

- [ ] **Meeting end detection** — call detection service already monitors for meeting app launch (start). Add complementary end detection: fire when the meeting app quits or its audio device usage drops, triggering an auto-stop or a "meeting ended, stop recording?" prompt. Use the same `NSWorkspace` + CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` hooks already in `CallDetectionService`.

- [ ] **Lightning Whisper MLX transcription engine** — add `LightningWhisperMLXTranscriptionService` backed by [lightning-whisper-mlx](https://github.com/mustafaaljadery/lightning-whisper-mlx). Faster than standard MLX Whisper via batched mel spectrogram processing. Surface as a fourth local engine option alongside Apple Speech, WhisperKit, and Parakeet. Requires Python env or a Swift-callable wrapper; evaluate integration approach first.

- [ ] **Re-transcribe existing recording** — add a "Re-transcribe" action to `RecordingHistoryView` that re-runs the transcription (and optionally AI) pipeline on an already-finalized audio file. Useful when the wrong engine, language, or model was used. Should allow selecting engine, language, and model before re-running, then replace (or version) the existing transcript and markdown output.

- [x] **Calendar integration (Phase 1 — iCal)** — `CalendarService` actor + `CalendarMatcher` (pure, TDD); `Recording.calendarEvent`; pre-fills title/participants in `PostRecordingSheet`; injects agenda into AI prompts (Apple Intelligence, remote, MLX paths). Settings: Calendar permission row + toggle. `NSCalendarsFullAccessUsageDescription` added. Spec: `docs/superpowers/specs/2026-06-04-ical-calendar-integration-design.md`.

- [ ] **Calendar integration (Phase 2 — Outlook/Exchange)** — Microsoft Graph API (`/v1/me/events`), OAuth flow, account picker in Settings. Builds on the existing `CalendarService` + `CalendarMatcher` infrastructure from Phase 1.
