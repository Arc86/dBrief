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
- **Mixed mode** (system audio + mic): uses `ScreenCaptureKit` for system audio via `SystemAudioCapture`, mic via `AVAudioEngine` through `MicrophoneCapture`, mixed through `AudioMixer`, written by `AudioFileWriter`
- **Mic-only mode**: falls back to plain `AVAudioEngine` input tap when screen recording permission is denied

**Important concurrency note**: Audio tap handlers must be created with `nonisolated static` methods to avoid inheriting `@MainActor` isolation, which would crash on the real-time audio thread. See `makeTapHandler()` and `makeMicTapHandler()` in `AudioCaptureManager`.

Output format is FLAC. Capture is 16 kHz mono.

### Recording Finalization (`Services/RecordingFinalizer.swift`)

After recording stops:
1. Normalizes meeting title (sanitizes special chars)
2. Creates dated folder structure (`Recordings/YYYY/MM`)
3. Transcodes FLAC via ffmpeg with DSP normalization and compression
4. Auto-segments files >30 minutes into 30-minute chunks
5. Writes JSON metadata with duration, warnings, and segment file names
6. Falls back to raw FLAC if ffmpeg is unavailable

Final file naming: `YYYY-MM-DD_HHMM_[meeting-title].flac`

### Transcription Engines (`Services/`)

Three transcription backends selected via `AppSettings.transcriptionEngine`:

| Engine | Class | Backend |
|--------|-------|---------|
| Apple Speech | `LocalTranscriptionService` | On-device `SFSpeechRecognizer`. Converts `.ogg`/`.opus` to WAV via ffmpeg. |
| Local Whisper | `WhisperKitTranscriptionService` (via `LocalAIPluginService`) | On-device CoreML Whisper (whisper-small) via the `WhisperKit` package. Downloads models to `AppSupport/dBrief/LocalAIPlugin/WhisperKit/`. |
| Remote Endpoint | `TranscriptionService` | Supports both OpenAI-compatible `/v1/audio/transcriptions` and `whisper-asr-webservice` `/asr` format (auto-detected via `Endpoint.isWhisperASR`). Handles chunked upload for large files via `AudioChunker`. |

The legacy `LocalWhisperService` (SwiftWhisper/whisper.cpp) has been removed. The `SwiftWhisper` package dependency has also been removed.

### AI Processing (`Services/`)

Three AI backends selected via `AppSettings.aiEngine`:

| Engine | Class | Backend |
|--------|-------|---------|
| Apple Intelligence | `LocalAIService` | On-device via `FoundationModels` framework. Guarded by `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. Only available on Apple Silicon with macOS 26+. |
| Qwen3 4B Local | `MLXInsightsService` (via `LocalAIPluginService`) | On-device `mlx-community/Qwen3-4B-Instruct-2507-4bit` via the `mlx-swift-lm` package. Downloads models to `AppSupport/dBrief/LocalAIPlugin/MLX/`. Supports streaming output. |
| Remote Endpoint | `AIService` | OpenAI-compatible `/v1/chat/completions` |

AI tasks run sequentially after transcription: summary → action items → tags/sentiment → title generation → markdown export.

### Local AI Plugin System (`Services/LocalAIPlugin*`)

The `LocalAIPluginService` actor orchestrates both WhisperKit and MLX models behind the `LocalAIPluginProtocol` interface:
- **AsyncMutex** serializes GPU-resident model access (prevents concurrent allocation)
- **State stream** (`AsyncStream<LocalAIPluginState>`) provides real-time UI feedback: `idle`, `downloading(progress, stage)`, `transcribing`, `analyzing`
- Methods: `transcribe()`, `analyzeTranscript()`, `analyzeTranscriptStream()`, `prepareModelsIfNeeded()`, `purgeModels()`

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

`CallDetectionService` monitors for known meeting apps (Zoom, Teams, Slack, Google Meet, etc.) via `NSWorkspace` notifications and microphone activity via CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. Can auto-start recording or show a popup prompt. Supports per-app blocklist.

### Integration Dispatch (`Services/IntegrationDispatchService.swift`)

Routes post-recording content to eight destinations, each with configurable field selection (audio, transcript, summary, tags, sentiment, action items, markdown):

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

Produces Markdown files with YAML frontmatter (title, date, tags, duration, audio link, model info) and sections for transcription (with timestamps), summary, action items, and tags/sentiment. Outputs to either the transcription folder or an Obsidian vault folder.

### Other Services

- **GlobalHotkeyService** — registers ⌘⇧R global hotkey for record/stop toggle
- **AudioPlayer** — playback control for past recordings
- **WebhookPayloadBuilder** — builds multipart/form-data payloads for webhook delivery
- **AudioChunker** — segments large audio files for chunked remote transcription

### UI Structure (`UI/`)

- **MenuBarView** (in `DBriefApp.swift`) — main menu bar popover with header, recording controls, history, and settings access
- **RecordingControlsView** — record/pause/resume/stop buttons
- **PostRecordingSheet** — post-recording options (transcribe, summary, action items, tags toggles; title edit)
- **TranscriptionProgressView** — step-by-step progress display during processing
- **RecordingHistoryView** — list of past recordings with replay/delete/export
- **OnboardingView** — initial setup wizard (permissions, engine selection, folder setup)
- **FloatingMiniPlayer** — floating window showing real-time peak levels during recording
- **CallDetectedPopup** / **CallDetectedOverlayController** — call detection prompt overlay
- **SettingsView** — tab-based settings window with tabs: General, Transcription, AI, Integrations, Profiles, Permissions, About

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | 0.9.4+ | CoreML-based on-device Whisper transcription |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 2.29.1+ | On-device Qwen3 4B LLM via MLX (Apple Silicon) |
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
- WhisperKit and MLX models are downloaded on-demand to `~/Library/Application Support/dBrief/LocalAIPlugin/` and can be purged from settings.
- Metal GPU support is auto-detected; the `make app` target copies `.metallib` files from the build or downloads prebuilt ones from the MLX releases.

## Platform Requirements

- macOS 14+ (Swift 6.2, swift-tools-version: 6.2)
- Apple Intelligence features require macOS 26+ on Apple Silicon
- MLX/Qwen features require Apple Silicon (Metal GPU)
- Bundle identifier: `com.dbrief.app`
