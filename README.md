# dBrief

dBrief is a macOS menu bar app for recording microphone and system audio, then automatically transcribing and analyzing recordings with AI. It generates summaries, action items, tags, and sentiment, and can export Markdown notes directly into your Obsidian vault.

## Features

- **Menu bar app** — lives in the menu bar, no dock icon clutter
- **Floating mini player** — compact translucent overlay showing recording status, waveform, and controls
- **Global hotkey** — `⌘⇧R` to start/stop recording from anywhere
- **Microphone + system audio** — captures both via ScreenCaptureKit (falls back to mic-only if screen recording permission is denied)
- **Three transcription engines** — Apple Speech (on-device), Local Whisper (on-device, downloads once), or a remote Whisper API
- **Three AI backends** — Apple Intelligence (on-device, macOS 26+), local Qwen 2.5 (MLX), or any OpenAI-compatible endpoint
- **Post-recording pipeline** — transcription, summary, action items, tags & sentiment
- **Custom vocabulary** — guide Whisper with proper nouns and domain terms (works with both Local Whisper and remote endpoints)
- **Call detection** — detects meeting apps (Zoom, Teams, Slack, etc.) and can auto-start recording
- **Destination integrations** — Obsidian, Apple Notes, Apple Reminders, Notion, Evernote, Google Keep, OneNote, and Webhook
- **Configurable audio** — sample rate, bit rate, and input device selection

## Requirements

- macOS 14+
- Swift 6.2 toolchain (Xcode 16+)
- Apple Intelligence features require macOS 26+ on Apple Silicon

## Permissions

dBrief will request the following (managed in Settings > Permissions):

- **Microphone** — required for recording
- **Screen Recording** — required for capturing system audio; recording works in mic-only mode without it
- **Speech Recognition** — required for Apple Speech transcription engine
- **Notifications** — optional, used for completion alerts

## Build & Run

```bash
# Build release binary
swift build -c release

# Build app bundle and launch
make app
open dBrief.app

# Or run the binary directly
.build/release/dBrief
```

## Usage

1. Click the menu bar icon to open the controls.
2. Click **Record** (or press `⌘⇧R`) to start recording.
3. A floating mini player appears showing duration, waveform, and pause/stop controls.
4. Stop the recording to open the post-processing sheet.
5. Choose which steps to run (transcription, summary, action items, tags), then click **Process**.
6. Use the **History** view to revisit past recordings and their results.
7. Use **Transcribe File...** to process an existing audio file without recording.

## Settings

### General
- Recording and transcription output folders
- Audio quality (sample rate: 16–48 kHz, AAC bit rate: 64–256 kbps)
- Input device selection
- Call detection with per-app enable/disable (Zoom, Teams, Slack, Meet, FaceTime, Discord, WebEx, etc.)

### Permissions
- View and request microphone, screen recording, and speech recognition permissions
- Quick links to the relevant System Settings panes

### Transcription
Three engines to choose from:

| Engine | Privacy | Accuracy | Requirements |
|--------|---------|----------|-------------|
| **Apple Speech** | On-device | Good | Speech Recognition permission |
| **Local Whisper** | On-device | Strong | Downloads WhisperKit small artifacts (~460 MB class) on first use |
| **Remote Endpoint** | Network | Best | A Whisper API server |

- Language selection (auto-detect or 15+ languages)
- Custom vocabulary prompt for proper nouns and domain terms (Local Whisper and remote endpoints)
- Remote endpoint management with connection testing

Remote transcription endpoints support:
- OpenAI-compatible `/v1/audio/transcriptions`
- `whisper-asr-webservice` `/asr` servers

### AI
- **Apple Intelligence** — on-device processing (macOS 26+, Apple Silicon)
- **Qwen 2.5 local (MLX)** — on-device insights model downloaded from Hugging Face (`mlx-community/Qwen2.5-3B-Instruct-4bit`)
- **Remote endpoint** — any OpenAI-compatible `/v1/chat/completions` server
- Post-recording defaults (auto-transcribe, summary, action items, tags)
- Customizable prompts for each AI task
- Endpoint management with connection testing

### Integrations
- **Obsidian** — select a vault and default output folder; notes are saved as Markdown with YAML frontmatter
- **Apple Notes** — best-effort local automation via AppleScript; optional account/folder targeting
- **Apple Reminders** — sends extracted action items into your selected reminders list
- **Notion** — direct API send using token + parent target (`data_source_id` or `page_id`)
- **Evernote** — direct API send using token with optional notebook target
- **Google Keep** — direct API send using token (enterprise/admin setup may be required)
- **OneNote** — direct Microsoft Graph send using token with optional section target
- **Webhook** — POST selected fields (`audio`, `transcript`, `summary`, `tags`, `sentiment`, `actionItems`, `markdown`) to external automation (e.g. n8n)
- Each integration supports connection testing in Settings > Integrations

## Outputs

- **Recordings**: `~/Documents/dBrief/Recordings` (M4A, falls back to WAV if AAC fails)
- **Transcriptions**: `~/Documents/dBrief/Transcriptions` (Markdown)
- **Obsidian**: Markdown saved into the selected vault folder
- **Integrations**: enabled destinations receive output automatically after processing

Markdown notes include YAML frontmatter (title, date, tags, duration, audio link, model info) and sections for transcription (with timestamps), summary, action items, and tags/sentiment.

## Troubleshooting

- **No system audio**: grant Screen Recording permission in System Settings > Privacy & Security.
- **Transcription fails**: verify the endpoint URL, model name, and API key in Settings > Transcription.
- **Local Whisper slow on first run**: WhisperKit turbo assets are downloaded from Hugging Face on first use. Subsequent runs use the cached files.
- **AI steps fail**: ensure the AI endpoint is reachable and supports chat completions.
- **No endpoint configured**: add one under Settings > Transcription or Settings > AI.
