# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dBrief is a macOS menu bar app (SwiftUI `MenuBarExtra`) for recording microphone and system audio, then automatically transcribing and analyzing recordings with AI. It generates summaries, action items, tags, and sentiment, and can export results to Markdown notes, Obsidian vaults, and eight integration destinations. Built as a Swift Package Manager executable (not an Xcode project).

## Build Commands

- **Build**: `swift build` (debug) or `swift build -c release`
- **Build app bundle**: `make app` (builds release, then assembles `dBrief.app/` with Info.plist, icons, and Metal shaders)
- **Run**: `swift run` or `make run` (builds and launches the app bundle)
- **Clean**: `make clean` or `swift package clean`
- **Run tests**: `swift test`

## Tests

Tests live in `Tests/dBriefTests/` and use the `swift-testing` framework (v0.6.0+):

- **ProfileBehaviorTests.swift** — Meeting profile overrides, import/export, default profile protection
- **WhisperPipelineTests.swift** — Recording finalization, title normalization, segment merging, file discovery
- **RichTranscriptBuilderTests.swift** — Word timestamp propagation, speaker ID propagation, filler word defaults
- **WhisperModelInfoTests.swift** — Model name parsing, memory estimation, turbo/quantized variants, sort ordering

## Architecture

### App Lifecycle & Dependency Wiring

`DBriefApp` (`Sources/dBrief/App/DBriefApp.swift`) is the `@main` entry point. It creates a single `AppContext` instance that owns all shared state and services. Dependencies are passed to SwiftUI views via `.environment()`. The app runs as `LSUIElement` (no dock icon by default), presenting a `MenuBarExtra` window and a separate settings `WindowGroup`.

### Core Object Graph

- **AppContext** — root object, creates and wires everything at launch; owns all services below
- **AppState** (`@Observable`) — recording state machine (`idle → recording → paused → processing`), processing step progress, current recording data, call detection state
- **AppSettings** (`@Observable`) — all user preferences persisted via `UserDefaults` with `didSet` observers; folder URLs use security-scoped bookmarks; integration tokens stored in Keychain via `KeychainHelper`. Split across extension files: `AppSettings+EffectiveSettings.swift` (profile-resolved computed properties), `AppSettings+Profiles.swift` (profile CRUD, import/export, factories), `AppSettings+Persistence.swift` (bookmark/endpoint/integration/profile persistence helpers)
- **RecordingManager** — orchestrates the full record → finalize → transcribe → AI → markdown → integration dispatch pipeline

### Source Layout

```
Sources/dBrief/
├── App/            # Entry point, AppContext, AppState, AppSettings (+ extension files)
├── Audio/          # Audio capture, mixing, file writing
├── Models/         # Data types: Endpoint, Recording, MeetingProfile, Integrations, etc.
├── Services/       # Business logic: transcription, AI, recording, integrations
├── UI/             # All SwiftUI views (menu bar, settings tabs, onboarding, overlays)
├── Utilities/      # Extensions, helpers (Keychain, multipart form, Obsidian formatting)
├── Resources/      # Info.plist, icons, fonts, third-party integration icons
└── Images/         # (excluded from target)
```

### Audio Capture (`Audio/`)

`AudioCaptureManager` handles two recording modes:
- **Mixed mode** (system audio + mic): uses `ScreenCaptureKit` for system audio via `SystemAudioCapture`, mic via `AVAudioEngine` through `MicrophoneCapture`. The two sources are captured to **separate per-track CAF/LPCM files** (`*.system.caf`, `*.mic.caf`) and mixed at finalization, not in real time.
- **Mic-only mode**: falls back to plain `AVAudioEngine` input tap when screen recording permission is denied (no system CAF is written).

**Important concurrency note**: Audio tap handlers must be created with `nonisolated static` methods to avoid inheriting `@MainActor` isolation, which would crash on the real-time audio thread. See `makeTapHandler()` and `makeMicTapHandler()` in `AudioCaptureManager`.

The recording mode is chosen automatically by permission (mixed when Screen Recording is granted, mic-only otherwise) — there is no user-facing source toggle. Capture is per-track CAF/LPCM; the finalized master is **M4A/AAC (~96 kbps, 48 kHz stereo)**. The audio source toggle (mic vs. mixed) is not exposed in Settings; the **Settings → Recording** tab exposes input device, an acoustic echo cancellation toggle (`acousticEchoCancellation`), and a read-only Audio Quality summary (Power User Mode).

### Recording Finalization (`Services/RecordingFinalizer.swift`)

`finalize(tracks:…)` takes the separate captured CAF tracks (`CapturedTracks`) and, after recording stops:
1. Normalizes meeting title (sanitizes special chars)
2. Creates dated folder structure (`Recordings/YYYY/MM`)
3. Merges + transcodes the per-track CAFs to an M4A/AAC master via ffmpeg, applying DSP per track (mic: 80 Hz HPF, sidechain duck vs. system, -16 LUFS loudnorm; system: 40 Hz HPF, 12 kHz LPF; mix: `amix` normalize). Acoustic echo cancellation (`echoSuppressionEnabled`) ducks mic against the system reference.
4. Auto-segments files >30 minutes into 30-minute chunks (`_partNN.m4a`)
5. Writes JSON metadata sidecar with duration, warnings, and segment file names
6. If ffmpeg is unavailable (or merge fails), falls back to promoting a raw CAF track to the master path (no AAC encode); segmentation is then skipped

Final file naming: `YYYY-MM-DD_HHMM_[meeting-title].m4a`

### Transcription Engines (`Services/`)

Four transcription backends selected via `AppSettings.transcriptionEngine`:

| Engine | Class | Backend |
|--------|-------|---------|
| Apple Speech | `LocalTranscriptionService` | On-device `SFSpeechRecognizer`. Converts `.ogg`/`.opus` to WAV via ffmpeg. |
| Local Whisper | `WhisperKitTranscriptionService` (via `LocalAIPluginService`) | On-device CoreML Whisper via the `WhisperKit` package (0.18.0). Loads audio natively (FLAC/WAV/M4A via AVFoundation — no ffmpeg needed). Uses WhisperKit's per-component compute defaults (mel→GPU, encoder→ANE, decoder→ANE). VAD chunking enabled. Downloads models to `AppSupport/dBrief/LocalAIPlugin/WhisperKit/`. Supports progressive segment streaming via `segmentDiscoveryCallback`. Dynamic model picker fetches available models from HuggingFace at runtime with memory estimates; falls back to curated offline list. Optional SpeakerKit diarization. |
| Parakeet TDT (Local) | `ParakeetTranscriptionService` (via `FluidAudio` framework) | On-device CoreML nvidia/parakeet-tdt-0.6b (v2 or v3). Downloads models from `argmaxinc/parakeetkit-coreml`. Handles long files natively (no segmentation). Does **not** support language selection or diarization. Reports download/load progress via the same `AsyncStream<LocalAIPluginState>` pattern as `LocalAIPluginService`. |
| Remote Endpoint | `TranscriptionService` | Supports both OpenAI-compatible `/v1/audio/transcriptions` and `whisper-asr-webservice` `/asr` format (auto-detected via `Endpoint.isWhisperASR`). Handles chunked upload for large files via `AudioChunker`. |

### AI Processing (`Services/`)

Three AI backends selected via `AppSettings.aiEngine`:

| Engine | Class | Backend |
|--------|-------|---------|
| Apple Intelligence | `LocalAIService` | On-device via `FoundationModels` framework. Guarded by `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. Only available on Apple Silicon with macOS 26+. |
| Gemma 4 E4B Local | `MLXInsightsService` (via `LocalAIPluginService`) | On-device `mlx-community/gemma-4-e4b-4bit` via `mlx-swift-lm` 3.x. Downloads models to `AppSupport/dBrief/LocalAIPlugin/MLX/`. Supports streaming output. Uses KV cache quantization (`kvBits: 8`). Strips `<think>…</think>` blocks before JSON parsing (model uses thinking mode). **Note**: the enum case is historically named `AIEngine.qwenLocal` (UI display name "Gemma 4 E4B Local") — it now loads Gemma, not Qwen. |
| Remote Endpoint | `AIService` | OpenAI-compatible `/v1/chat/completions` |

AI tasks run sequentially after transcription: summary → action items → tags/sentiment → title generation → markdown export. All AI steps can be skipped via `AppSettings.aiProcessingEnabled = false`.

### Local AI Plugin System (`Services/LocalAIPlugin*`)

The `LocalAIPluginService` actor orchestrates WhisperKit, SpeakerKit, and MLX models behind the `LocalAIPluginProtocol` interface:
- **AsyncMutex** serializes GPU-resident model access (prevents concurrent allocation)
- **State stream** (`AsyncStream<LocalAIPluginState>`) provides real-time UI feedback: `idle`, `downloading(progress, stage)`, `transcribing`, `newSegments(...)`, `diarizing`, `analyzing`
- **Download stages**: `.whisperModel` (downloading from HuggingFace), `.whisperModelLoading` (cached model loading into CoreML), `.llmModel`, `.speakerKitModel`
- Methods: `transcribe()`, `analyzeTranscript()`, `analyzeTranscriptStream()`, `prepareModelsIfNeeded()`, `purgeModels()`, `purgeSpeakerKitModel()`

### Endpoint Model (`Models/Endpoint.swift`)

`Endpoint` represents both transcription and AI server configs (`id`, `name`, `baseURL`, `modelName`, `apiKey`). The `isWhisperASR` computed property auto-detects whisper-asr-webservice endpoints by URL pattern (contains `/asr`, port 8080 or 9000) and adjusts request format accordingly.

### Meeting Profiles (`Models/MeetingProfile.swift`)

Profile system for per-meeting configuration overrides:
- **Presets**: `default`, `teamMeeting`, `salesMeeting`, `custom` — each with pre-configured prompts
- **Overrides**: nullable fields for transcription engine, AI engine, endpoints, prompts, output folders
- **Resolution order**: profile override → active profile setting → global app default
- **Export/import**: versioned `ProfilesExportEnvelope` with conflict renaming on import
- Effective settings accessed via `AppSettings.effectiveTranscriptionEngine`, `effectiveAIEngine`, etc.

### Call Detection (`Services/CallDetectionService.swift`)

`CallDetectionService` monitors for known meeting apps (`knownCallApps`: Zoom, Teams classic/new, Slack, Webex, FaceTime, Google Meet) via `NSWorkspace` notifications and microphone activity via CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. Can auto-start recording (`autoRecordCalls`) or show a popup prompt. Per-app enable/disable via `AppSettings.disabledCallApps`. Configured in **Settings → General → Call Detection**.

### Calendar Integration (`Services/CalendarService.swift`, `OutlookCalendarService.swift`)

On recording start, `RecordingManager` looks up the matching calendar event to pre-fill the meeting title, participants (used as diarization speaker names), and agenda context for AI prompts. Two sources behind `AppSettings.calendarSource` (`CalendarSource`: `.disabled`/`.iCal`/`.outlook`):
- **iCal** — `CalendarService.findCurrentEvent()` via EventKit (`EKEventStore`), needs Calendar permission
- **Outlook** — `OutlookCalendarService.findCurrentEvent()` via Microsoft Graph; auth through `MicrosoftAuthService` (OAuth2, Keychain-stored). The Outlook option only appears when `MicrosoftAuthService.isConfigured` (a real Azure client ID is compiled in, not the placeholder).

Both search a ±2h window and pick the best candidate via `CalendarMatcher.selectBestMatch()`. `AppSettings.effectiveCalendarSource` coerces `.outlook` → `.disabled` when Outlook isn't configured, so a stale selection never renders sign-in UI. Configured in **Settings → General → Calendar**.

### Integration Dispatch (`Services/IntegrationDispatchService.swift`)

Routes post-recording content to eight implemented destinations, each with configurable field selection (audio, transcript, summary, tags, sentiment, action items, markdown). **`IntegrationDestination.available` is the source of truth for which are exposed** — currently only Obsidian, Apple Notes, Apple Reminders, and Webhook. The others (Notion, Evernote, Google Keep, OneNote) are implemented but hidden from the Settings UI and skipped by dispatch until verified.

| Destination | Method |
|-------------|--------|
| Apple Notes | AppleScript |
| Apple Reminders | EventKit API (`EKEventStore`) — creates reminder per action item |
| Notion | REST API (v2022-06-28) |
| Evernote | REST API |
| Google Keep | REST API |
| Microsoft OneNote | Microsoft Graph API (v1.0) |
| Obsidian | Local filesystem (Markdown files in vault folder) |
| Webhook | Custom HTTP POST with optional multipart audio upload |

Integration tokens are stored securely via `KeychainHelper`.

### Markdown Output (`Services/MarkdownGenerator.swift`)

Produces Markdown files with YAML frontmatter (title, date, tags, duration, audio link, model info, speaker count) and sections for transcription (with timestamps and speaker labels), summary, action items, and tags/sentiment. Speaker labels resolved through `RichTranscript.speakerLabels` — displays custom display names when available, falls back to raw speaker IDs. Outputs to either the transcription folder or an Obsidian vault folder.

### Speaker Diarization (`Services/WhisperKitTranscriptionService.swift`)

Optional SpeakerKit integration (Pyannote v4 models) for identifying who said what:

- Enabled via `AppSettings.diarizationEnabled` toggle in Settings → Recording
- Runs sequentially after WhisperKit transcription (not parallel — both compete for GPU/ANE)
- `SpeakerKit(PyannoteConfig)` initialized on-demand, models downloaded to `AppSupport/dBrief/LocalAIPlugin/SpeakerKit/`
- Results merged via `diarResult.addSpeakerInfo(to: wkResults, strategy: SpeakerInfoStrategy.subsegment)`
- Speaker IDs ("Speaker 1", "Speaker 2") stored in `TranscriptionResult.Segment.speaker` and `Word.speaker`
- **Participant mapping**: Users enter comma-separated names in `PostRecordingSheet`; `RichTranscriptBuilder.build(from:participants:)` maps names to speakers by ordinal (first speaker = first name)
- **Post-hoc rename**: Clicking a speaker badge in `TranscriptSegmentRow` opens a rename popover that updates `SpeakerLabel.displayName` in the `RichTranscript`, persisted via `TranscriptStore`
- Display names resolved through `RichTranscript.speakerLabels` in both transcript viewer badges and markdown output

**Important**: WhisperKit's `TranscriptionResult` class conflicts with dBrief's `TranscriptionResult` struct (same name, different modules). The `WhisperKit` module name also collides with the `WhisperKit` class. As a result, diarization code that uses both types must be inlined within `transcribe()` where `wkResults` type is inferred — it cannot be extracted into separate functions with explicit type annotations. Use `dBrief.TranscriptionResult` to qualify our type.

### Live Transcript Streaming

Progressive transcript output during WhisperKit transcription:
- WhisperKit's `segmentDiscoveryCallback` fires each time a ~30-second audio chunk is decoded
- Segments converted to `LiveTranscriptSegment` structs and pushed via `LocalAIPluginState.newSegments(...)`
- `RecordingManager` appends to `AppState.liveTranscriptSegments` (cleared on each new transcription)
- `LiveTranscriptView` (`UI/LiveTranscriptView.swift`) displays segments in a popup window with timestamps and auto-scroll
- "Live Transcript" button appears in `TranscriptionProgressView` once segments start arriving
- Separate `WindowGroup(id: "live-transcript")` scene in `DBriefApp`

### YouTube / Video URL Transcription (`Services/YouTubeDownloadService.swift`)

`YouTubeDownloadService` lets any yt-dlp-supported URL be transcribed without recording:

- Locates the `yt-dlp` binary (PATH or Homebrew prefix), fetches the video title, and downloads best-quality audio as 16 kHz mono m4a via ffmpeg post-processor
- `RecordingManager.loadYouTubeAudio()` sets `finalizedAudioURL` directly (skips `RecordingFinalizer`) and opens `PostRecordingSheet`
- `YouTubeURLInputView` is an inline SwiftUI panel in the menu bar with URL field, progress indicator, error display, and a yt-dlp install hint
- Requires `yt-dlp` (`brew install yt-dlp`)

### Transcript Chat (`Services/TranscriptChatService.swift`)

`TranscriptChatService` (`@MainActor @Observable`) provides conversational Q&A over a recording:

- Holds a `[ChatMessage]` array and an `isStreaming` flag
- Routes to Apple Intelligence, MLX (streaming), or remote endpoint based on `AppSettings.aiEngine`
- Builds a system prompt from the full transcript text and speaker labels; each user turn appends context
- `TranscriptChatView` renders the conversation with a command-palette layout and glass styling, embedded as a panel in `TranscriptWindowView`

### Rich Transcript Viewer

Glass-styled transcript window with word-level timestamps and audio sync:

- **`TranscriptWindowView`** — root window; hosts `TranscriptSidePanel` (segment list) and `TranscriptChatView`
- **`TranscriptPlayerBar`** — frosted-glass audio controls with seek and playback sync
- **`SpeakerTurnCard`** — card per speaker turn, merges consecutive same-speaker segments
- **`SpeakerPillView`** — colored speaker badge, tap to rename
- **`TranscriptDesignTokens`** — shared color/spacing constants for the glass UI system
- Persisted via `TranscriptStore` which writes `.richtranscript.json` sidecar files alongside Markdown output
- Opened from `ResultsView` and `RecordingHistoryView`; hosted in a separate `WindowGroup(id: "transcript")` scene

### Other Services

- **GlobalHotkeyService** — registers a user-configurable global hotkey (default ⌃⌥⌘R) for record/stop toggle via Carbon Event Manager. The hotkey is stored as a `RecordHotkey` (`Models/RecordHotkey.swift`) and edited with `ShortcutRecorderView` in **Settings → General → Shortcuts**; `update()` re-registers on change
- **AudioPlayer** — playback control for past recordings
- **WebhookPayloadBuilder** — builds multipart/form-data payloads for webhook delivery
- **AudioChunker** — segments large audio files for chunked remote transcription

### UI Structure (`UI/`)

- **MenuBarView** (in `DBriefApp.swift`) — main menu bar popover with header, recording controls, history, YouTube URL input, and settings access
- **RecordingControlsView** — record/pause/resume/stop buttons
- **PostRecordingSheet** — post-recording options (transcribe, summary/AI toggles; title edit; participants input for diarization); AI options hidden when `aiProcessingEnabled` is false
- **TranscriptionProgressView** — step-by-step progress display during processing with download progress bar and "Live Transcript" popup button
- **LiveTranscriptView** — popup window showing progressive transcript segments as they arrive during transcription
- **RecordingHistoryView** — list of past recordings with action chips; opens transcript viewer
- **OnboardingView** — initial setup wizard (permissions, engine selection, folder setup)
- **FloatingMiniPlayer** — floating window showing real-time peak levels during recording
- **CallDetectedPopup** / **CallDetectedOverlayController** — call detection prompt overlay
- **YouTubeURLInputView** — inline panel in the menu bar for YouTube/video URL input
- **SettingsView** — sidebar-based settings window with tabs:
  - **General** — appearance/power-user toggle, record shortcut (`ShortcutRecorderView`), output folders, call detection, calendar source (iCal/Outlook), and permissions (mic, screen recording, calendar)
  - **Recording** (`SettingsRecordingTab`) — audio input device, acoustic echo cancellation, and a read-only Audio Quality summary (Power User Mode)
  - **AI & Models** (`SettingsAIModelsTab`) — two sub-tabs: **Transcription** (`SettingsTranscriptionTab`: engine, Whisper/Parakeet model picker + `ModelDownloadButton`, diarization, language, custom vocabulary, endpoints, chunking) and **AI Analysis** (`SettingsAITab`: AI engine, Gemma model download, prompts, AI processing toggle, output language, endpoints)
  - **Integrations** (`SettingsIntegrationsTab`) — only `IntegrationDestination.available` destinations
  - **Profiles** (`SettingsProfilesTab`) — hidden unless `powerUserMode` is enabled

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | 0.18.0+ | CoreML-based on-device Whisper transcription (products: `WhisperKit`, `SpeakerKit`) |
| [FluidAudio](https://github.com/argmaxinc/FluidAudio) | — | CoreML-based Parakeet TDT transcription (`AsrManager`) |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.x | On-device Gemma 4 E4B LLM via MLX (Apple Silicon) |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | — | Tokenizer support for MLX (explicit dependency since mlx-swift-lm 3.x) |
| [swift-testing](https://github.com/apple/swift-testing) | 0.6.0+ | Testing framework |

### Linked System Frameworks

`ScreenCaptureKit`, `AVFoundation`, `EventKit`, `Security` — linked via SPM `linkerSettings` (not Xcode build settings).

## Key Patterns

- All UI and state classes are `@MainActor @Observable`. Services that do async work are `actor`-isolated (`TranscriptionService`, `AIService`, `LocalAIPluginService`, `MLXInsightsService`, `WhisperKitTranscriptionService`, `IntegrationDispatchService`, `RecordingFinalizer`).
- Logging uses centralized `Logger` extensions defined in `Logger+Extensions.swift` (e.g. `Logger.audio`, `Logger.recording`, `Logger.ai`). New files should use these static loggers rather than creating ad-hoc `Logger(subsystem:category:)` instances.
- Models are `Sendable` structs/enums for safe cross-isolation passing.
- Settings persistence uses `UserDefaults` with `didSet` observers on each property. Folder URLs use security-scoped bookmarks. Sensitive tokens use `KeychainHelper`.
- The app links system frameworks via SPM linker settings (not Xcode build settings).
- Audio tap handlers use `nonisolated static` factory methods to avoid `@MainActor` isolation on the real-time audio thread.
- WhisperKit, SpeakerKit, and MLX models are downloaded on-demand to `~/Library/Application Support/dBrief/LocalAIPlugin/` and can be purged from settings.
- **WhisperKit type collision**: The `WhisperKit` module and `WhisperKit` class share the same name, making `WhisperKit.TranscriptionResult` ambiguous. Use `dBrief.TranscriptionResult` to refer to our type; keep WhisperKit result types inferred (never name them explicitly in function signatures). Import with `@preconcurrency import WhisperKit` for Sendable suppression.
- Metal GPU support is auto-detected; the `make app` target copies `.metallib` files from the build or downloads prebuilt ones from the MLX releases.

## Platform Requirements

- macOS 14+ (Swift 6.2, swift-tools-version: 6.2)
- Apple Intelligence features require macOS 26+ on Apple Silicon
- MLX/Gemma 4 features require Apple Silicon (Metal GPU)
- YouTube transcription requires `yt-dlp` (`brew install yt-dlp`)
- Bundle identifier: `com.dbrief.app`
