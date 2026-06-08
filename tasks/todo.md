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

- [x] **Waveform not responding to system audio** — the waveform visualizer in both the popup window and the menu bar item only reacts to mic audio; system audio captured via ScreenCaptureKit is not feeding the peak/level meter. Likely the level tap is only wired to the `AVAudioEngine` mic path, not the `SystemAudioCapture` / `AudioMixer` output. Fix: derive waveform levels from the mixed output buffer in `AudioFileWriter` or `AudioMixer` rather than the raw mic tap. _(Done: `ecd4ac1` — level meter reflects max(mic, system) in mixed mode.)_

- [x] **Record/Stop button inconsistently red** — the button appears grey instead of red in some states. Likely a SwiftUI state observation issue or a conditional tint modifier that is not re-evaluated when recording state changes. Investigate `RecordingControlsView` button styling and ensure `.tint`/`.foregroundStyle` reacts to `AppState.recordingState`. _(Done: `c8e470a` — force active control state so tint renders in menu bar extra.)_

### Enhancements

- [x] **Minimize floating mini-player / popup window** — recording popup window has no minimize/collapse control. Add a minimize button that collapses to a slim title-bar-only strip (or hides to menu bar) without stopping the recording. _(Done: `848364f` — collapse/expand toggle on floating mini-player.)_

- [ ] **VAD with remote transcription engines** — VAD (Voice Activity Detection) is currently gated to local engines (WhisperKit). Investigate whether VAD can be applied as a pre-processing step before uploading to remote endpoints: strip silent segments client-side, then send the trimmed audio. If feasible, expose the toggle for remote engines too.

- [ ] **Meeting end detection** — call detection service already monitors for meeting app launch (start). Add complementary end detection: fire when the meeting app quits or its audio device usage drops, triggering an auto-stop or a "meeting ended, stop recording?" prompt. Use the same `NSWorkspace` + CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` hooks already in `CallDetectionService`.

- [ ] **Lightning Whisper MLX transcription engine** — add `LightningWhisperMLXTranscriptionService` backed by [lightning-whisper-mlx](https://github.com/mustafaaljadery/lightning-whisper-mlx). Faster than standard MLX Whisper via batched mel spectrogram processing. Surface as a fourth local engine option alongside Apple Speech, WhisperKit, and Parakeet. Requires Python env or a Swift-callable wrapper; evaluate integration approach first.

- [ ] **Re-transcribe existing recording** — add a "Re-transcribe" action to `RecordingHistoryView` that re-runs the transcription (and optionally AI) pipeline on an already-finalized audio file. Useful when the wrong engine, language, or model was used. Should allow selecting engine, language, and model before re-running, then replace (or version) the existing transcript and markdown output.

- [x] **Calendar integration (Phase 1 — iCal)** — `CalendarService` actor + `CalendarMatcher` (pure, TDD); `Recording.calendarEvent`; pre-fills title/participants in `PostRecordingSheet`; injects agenda into AI prompts (Apple Intelligence, remote, MLX paths). Settings: Calendar permission row + toggle. `NSCalendarsFullAccessUsageDescription` added. Spec: `docs/superpowers/specs/2026-06-04-ical-calendar-integration-design.md`.

- [x] **Calendar integration (Phase 2 — Outlook/Exchange)** — Microsoft Graph API (`/v1/me/events`), OAuth flow, account picker in Settings. Builds on the existing `CalendarService` + `CalendarMatcher` infrastructure from Phase 1.

### Planned sub-projects (decomposed 2026-06-05; doing "Visibility toggles" first, rest deferred here)

- [x] **Model settings UX** — (a) explicit "Download model" button in Settings (Whisper/Parakeet/Gemma) with cached-state detection and cancelable inline progress; (b) "Need some help?" disclosure with a six-engine comparison. State on `RecordingManager.modelDownloads`; downloads cancel when a recording starts. Spec: `docs/superpowers/specs/2026-06-05-model-settings-ux-design.md`. _(Done: merged to main.)_

- [~] **Model selector redesign (transcription catalog, Phase 1)** — model-first card catalog (Default Model header, language picker, Recommended/Local/Cloud/Custom tabs, Speed/Accuracy ratings, per-card Download/Set-as-Default). **Implemented and reviewed but NOT merged to main — needs more work before shipping.** Code lives on branch `feature/transcription-model-catalog`. Design + plan docs on main: `docs/superpowers/specs/2026-06-05-transcription-model-catalog-design.md`, `docs/superpowers/plans/2026-06-05-transcription-model-catalog.md`. Phase 2 (cloud providers) and Phase 3 (AI Analysis page) still pending.

- [ ] **Diarization everywhere** — SpeakerKit/Pyannote runs on the audio independently of the ASR engine, so: (a) add speaker diarization to **Parakeet** output (FluidAudio is ASR-only — diarize the audio via SpeakerKit and align to Parakeet word timestamps), and (b) add an **after-the-fact** "re-detect speakers" action on existing recordings (same mechanism, triggered from history/viewer). Both merge via timestamp alignment into the existing `RichTranscript.speakerLabels`. Files: `ParakeetTranscriptionService.swift`, `WhisperKitTranscriptionService.swift` (diarization template, lines ~85-146), new after-the-fact service, `TranscriptStore`, `RecordingHistoryView`.

- [ ] **Transcript library + viewer redesign** — (a) add a menu-bar entry point to a browsable library of ALL past transcripts (today only reachable post-recording or via the 20-item history; no scan for `.richtranscript.json` exists yet); (b) redesign the viewer to remove redundant segment/turn duplication (the `.segments` picker mode is a dead stub — only merged turns render); (c) polish `TranscriptChatView` to a modern AI-chat appearance (currently plain system-color bubbles). Files: `TranscriptWindowView.swift`, `TranscriptChatView.swift`, `TranscriptDesignTokens.swift`, `MenuBarView` in `DBriefApp.swift`, `RecordingDiscovery`/`TranscriptStore`.

- [ ] **Voice library (cross-recording speaker recognition)** — persistent voice fingerprints so a recognized voice is auto-named in future recordings. **Needs a feasibility spike first**: SpeakerKit's public `diarize()` returns only segments; speaker **embeddings** appear to live in internal SpeakerKit types, not the public API. Spike must determine whether embeddings can be extracted (or a separate speaker-embedding model added) before this can be designed concretely. Depends on "Diarization everywhere". New `SpeakerLibraryStore` + matching (cosine similarity) if feasible.
