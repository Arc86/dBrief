# DeBrief

DeBrief is a macOS menu bar app for recording microphone and system audio, then automatically transcribing and analyzing recordings. It can generate summaries, action items, tags, and sentiment, and export Markdown directly into your Obsidian vault.

## Features
- Menu bar recorder with pause/resume and a floating mini-player
- Global hotkey: `⌘⇧R` toggles recording
- Records microphone + system audio (falls back to mic-only if screen recording permission is denied)
- Post-recording pipeline: transcription, summary, action items, tags & sentiment
- Export Markdown notes with YAML frontmatter
- Call detection with optional auto-record for common meeting apps
- Obsidian integration for saving notes into a vault folder

## Requirements
- macOS 14+ (built with Swift 6.2)
- Xcode 16+ (or Swift toolchain that supports `swift-tools-version: 6.2`)
- Apple Intelligence features require macOS 26+ on Apple Silicon

## Permissions
DeBrief will request:
- Microphone access (required for recording)
- Screen recording access (required for capturing system audio)
- Notifications (optional, used for completion notifications)

If screen recording permission is not granted, recording continues in mic-only mode.

## Build & Run

### Build (CLI)
```bash
swift build -c release
```

### Build an app bundle
```bash
make app
open DeBrief.app
```

### Run the binary directly
```bash
.build/release/VoiceRecorder
```

## Usage
1. Click the menu bar icon to open the controls.
1. Click Record (or press `⌘⇧R`) to start.
1. Stop the recording to open the post-processing sheet.
1. Choose which steps to run, then click Process.
1. Use the History view to revisit past recordings.
1. Use “Transcribe File...” to process an existing audio file.

## Settings

### General
- Recording and transcription output folders
- Audio quality (sample rate and AAC bit rate)
- Call detection and per-app enable/disable list

### Transcription
- Engine: built-in Apple Speech Recognition or external endpoint
- Language selection and Whisper prompt for custom vocabulary
- Endpoint list with default selection and connection testing

External transcription endpoints support:
- OpenAI-compatible `/v1/audio/transcriptions`
- `whisper-asr-webservice` (`/asr`) servers

### AI
- Engine: built-in Apple Intelligence or external endpoint
- Default post-processing toggles
- Custom prompts for summary, action items, and tags
- Endpoint list with default selection and connection testing

External AI endpoints must support OpenAI-compatible `/v1/chat/completions`.

### Integrations
- Obsidian vault selection
- Default output folder inside the vault

## Outputs
- Recordings: `~/Documents/DeBrief/Recordings` by default
- Transcriptions/notes: `~/Documents/DeBrief/Transcriptions` by default
- Obsidian: Markdown saved into the selected vault folder

Markdown notes include:
- YAML frontmatter (title, date, tags, duration, audio file link, model info)
- Sections for transcription, summary, action items, and tags/sentiment

## Troubleshooting
- No system audio: grant Screen Recording permission in System Settings.
- Transcription fails: verify endpoint URL, model name, and API key.
- AI steps fail: ensure AI endpoint is reachable and supports chat completions.
- No endpoint configured: add one under Settings > Transcription or Settings > AI.

## Development Notes
- The app is a SwiftUI `MenuBarExtra`.
- Call detection is based on mic activity and known app bundle IDs.
- Recording filenames use `VoiceRecording_yyyy-MM-dd_HHmmss.m4a` (falls back to WAV if AAC fails).
