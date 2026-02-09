# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dBrief is a macOS menu bar app (SwiftUI `MenuBarExtra`) for recording microphone and system audio, then automatically transcribing and analyzing recordings with AI. It generates summaries, action items, tags, and sentiment, and can export Markdown notes into an Obsidian vault. Built as a Swift Package Manager executable (not an Xcode project).

## Build Commands

- **Build**: `swift build` (debug) or `swift build -c release`
- **Build app bundle**: `make app` (builds release, then assembles `dBrief.app/` with Info.plist and icons)
- **Run**: `swift run` or `.build/release/dBrief` after release build
- **Clean**: `make clean` or `swift package clean`

There are no tests in this project currently.

## Architecture

### App Lifecycle & Dependency Wiring

`DBriefApp` (`Sources/dBrief/App/DBriefApp.swift`) is the `@main` entry point. It creates a single `AppContext` instance that owns all shared state and services. Dependencies are passed to SwiftUI views via `.environment()`. The app runs as `LSUIElement` (no dock icon), presenting a `MenuBarExtra` window and a separate settings `WindowGroup`.

### Core Object Graph

- **AppContext** — root object, creates and wires everything at launch
- **AppState** (`@Observable`) — recording state machine (`idle → recording → paused → processing`), processing step progress, current recording data
- **AppSettings** (`@Observable`) — all user preferences persisted via `UserDefaults` and security-scoped bookmarks for folder paths
- **RecordingManager** — orchestrates the full record → transcribe → AI → markdown pipeline

### Audio Capture (`Sources/dBrief/Audio/`)

`AudioCaptureManager` handles two recording modes:
- **Mixed mode** (system audio + mic): uses `ScreenCaptureKit` for system audio via `SystemAudioCapture`, mic via `AVAudioEngine`, mixed through `AudioMixer`, written by `AudioFileWriter`
- **Mic-only mode**: falls back to plain `AVAudioEngine` input tap when screen recording permission is denied

**Important concurrency note**: Audio tap handlers must be created with `nonisolated static` methods to avoid inheriting `@MainActor` isolation, which would crash on the real-time audio thread. See `makeTapHandler()` and `makeMicTapHandler()` in `AudioCaptureManager`.

Output format is M4A (AAC) with WAV fallback if AAC encoding fails. Filenames follow the pattern `VoiceRecording_yyyy-MM-dd_HHmmss.m4a`.

### Transcription Engines (`Sources/dBrief/Services/`)

Three transcription backends selected via `AppSettings.transcriptionEngine`:
- **Apple Speech** (`LocalTranscriptionService`) — on-device `SFSpeechRecognizer`. Converts `.ogg`/`.opus` to WAV via ffmpeg before processing.
- **Local Whisper** (`LocalWhisperService`) — on-device via the `SwiftWhisper` package dependency
- **Remote Endpoint** (`TranscriptionService`) — supports both OpenAI-compatible `/v1/audio/transcriptions` and `whisper-asr-webservice` `/asr` format (auto-detected via `Endpoint.isWhisperASR`)

### AI Processing (`Sources/dBrief/Services/`)

Two AI backends selected via `AppSettings.useBuiltInAI`:
- **Apple Intelligence** (`LocalAIService`) — on-device via `FoundationModels` framework, guarded by `#if canImport(FoundationModels)` and `@available(macOS 26, *)`. Only available on Apple Silicon with macOS 26+.
- **Remote Endpoint** (`AIService`) — OpenAI-compatible `/v1/chat/completions`

AI tasks run sequentially after transcription: summary → action items → tags/sentiment → title generation → markdown export.

### Endpoint Model

`Endpoint` (in `Models/`) represents both transcription and AI server configs. The `isWhisperASR` computed property auto-detects whisper-asr-webservice endpoints by URL pattern and adjusts request format accordingly.

### Call Detection

`CallDetectionService` monitors for known meeting apps (Zoom, Teams, Slack, etc.) via `NSWorkspace` notifications and microphone activity via CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`. Can auto-start recording or show a popup prompt.

### Output

`MarkdownGenerator` produces Markdown files with YAML frontmatter (title, date, tags, duration, audio link, model info) and sections for transcription (with timestamps), summary, action items, and tags/sentiment. Outputs to either the transcription folder or an Obsidian vault folder.

## Key Patterns

- All UI and state classes are `@MainActor @Observable`. Services that do network/IO work are `actor`-isolated (`TranscriptionService`, `AIService`, `LocalAIService`, `LocalTranscriptionService`).
- Settings persistence uses `UserDefaults` with `didSet` observers on each property. Folder URLs use security-scoped bookmarks.
- The app links `ScreenCaptureKit` and `AVFoundation` frameworks via SPM linker settings (not Xcode build settings).
- The only external dependency is `SwiftWhisper` (v1.2.0+) which bundles whisper.cpp.

## Platform Requirements

- macOS 14+ (Swift 6.2, swift-tools-version: 6.2)
- Apple Intelligence features require macOS 26+ on Apple Silicon
- Bundle identifier: `com.dbrief.app`
