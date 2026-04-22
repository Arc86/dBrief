
# dBrief

dBrief is a macOS menu bar app that records your meetings, transcribes them, and uses AI to generate summaries, action items, tags, and sentiment. Results can be exported as Markdown notes to Obsidian, Apple Notes, Notion, and more.

<img width="150" height="150" alt="dBrief-Icon" src="https://github.com/user-attachments/assets/f146265e-0871-4757-90a5-1eb1a7e37199" />

## Features

- **Menu bar app** — lives in the menu bar, no dock icon clutter
- **Floating mini player** — compact translucent overlay showing recording status, waveform, and controls
- **Global hotkey** — `Cmd+Shift+R` to start/stop recording from anywhere
- **Microphone + system audio** — captures both sides of a call via ScreenCaptureKit, with AEC on the mic engine (falls back to mic-only if screen recording permission is denied)
- **Four transcription engines** — Apple Speech (on-device), Local Whisper via WhisperKit (on-device), Parakeet TDT via FluidAudio (on-device), or any remote Whisper API
- **Three AI backends** — Apple Intelligence (on-device, macOS 26+), local Gemma 4 E4B via MLX (on-device), or any OpenAI-compatible endpoint
- **YouTube & video URL transcription** — paste any yt-dlp-supported URL to download and transcribe without recording
- **Interactive transcript viewer** — glass-styled window with speaker turn cards, word-level timestamps, and audio sync playback
- **Transcript chat** — ask questions about a recording using your configured AI engine
- **Post-recording pipeline** — automatic transcription, summary, action items, tags & sentiment extraction; AI processing can be disabled per-session
- **Meeting profiles** — save per-meeting configurations (Team Meeting, Sales Meeting, or custom) with their own prompts, engines, and output folders (power user mode)
- **Custom vocabulary** — guide Whisper with proper nouns and domain terms
- **Call detection** — detects meeting apps (Zoom, Teams, Slack, Google Meet, FaceTime, Discord, WebEx) and can auto-start recording
- **8 integrations** — Obsidian, Apple Notes, Apple Reminders, Notion, Evernote, Google Keep, OneNote, and Webhooks
- **Whisper-optimized capture** — 16 kHz mono FLAC with post-recording DSP finalization

## Requirements

- macOS 14+
- Apple Intelligence features require macOS 26+ on Apple Silicon
- Local Gemma 4 AI requires Apple Silicon (Metal GPU)
- YouTube transcription requires `yt-dlp` (`brew install yt-dlp`)

## Permissions

dBrief will request the following on first launch (managed in Settings > General):

| Permission | Purpose | Required? |
| ---------- | ------- | --------- |
| Microphone | Recording audio | Yes |
| Screen Recording | Capturing system audio (both sides of a call) | Recommended (mic-only without it) |
| Speech Recognition | Apple Speech transcription engine | Only if using Apple Speech |
| Notifications | Completion alerts when processing finishes | Optional |
| Reminders | Apple Reminders integration (action items) | Only if using Reminders integration |

## Getting Started

### Build & Run

```bash
# Build the app bundle and launch
make run

# Or build and open manually
make app
open dBrief.app
```

### First Launch

1. The onboarding wizard walks you through granting permissions and choosing your transcription engine.
2. Once set up, the dBrief icon appears in your menu bar.

### Recording a Meeting

1. Click the menu bar icon to open controls.
2. Click **Record** (or press `Cmd+Shift+R`) to start.
3. A floating mini player appears with duration, waveform, and pause/stop controls.
4. Stop the recording to open the post-processing sheet.
5. Choose which steps to run (transcription, summary, action items, tags), edit the meeting title if needed, then click **Process**.
6. Results appear in the progress view and are saved as Markdown.

### Transcribing a YouTube Video

1. Click the menu bar icon and select **YouTube URL...**.
2. Paste any yt-dlp-supported video URL.
3. dBrief downloads the audio and opens the standard post-processing sheet.

Requires `yt-dlp` (`brew install yt-dlp`).

### Other Actions

- **History** — revisit past recordings, open the transcript viewer, and re-run integrations
- **Transcribe File...** — process an existing audio file without recording
- **Settings** — configure engines, integrations, profiles, and permissions

## Settings

### General

- Permissions management (microphone, screen recording, speech recognition, notifications, reminders)
- Recording and transcription output folders
- Audio input device selection
- Show/hide dock icon
- Call detection with per-app enable/disable

### Recording

Four engines to choose from:

| Engine | Privacy | Requirements |
| ------ | ------- | ------------ |
| **Apple Speech** | Fully on-device | Speech Recognition permission |
| **Local Whisper** | Fully on-device | ~460 MB+ model download on first use (WhisperKit); dynamic model picker fetches available models from HuggingFace with memory estimates |
| **Parakeet TDT (Local)** | Fully on-device | ~600 MB model download (FluidAudio / CoreML); handles long files natively without segmentation; no language selection or diarization |
| **Remote Endpoint** | Network | A Whisper-compatible API server |

Additional options:

- Language selection (auto-detect or 15+ languages; not applicable to Parakeet)
- Custom vocabulary prompt for proper nouns and domain terms
- Speaker diarization via SpeakerKit (WhisperKit engine only)
- Chunked upload for large files sent to remote endpoints
- Remote endpoint management with connection testing

Remote endpoints support both formats:

- OpenAI-compatible `/v1/audio/transcriptions`
- `whisper-asr-webservice` `/asr` (auto-detected by URL)

### AI & Models

| Engine | Privacy | Requirements |
| ------ | ------- | ------------ |
| **Apple Intelligence** | Fully on-device | macOS 26+, Apple Silicon |
| **Gemma 4 E4B Local (MLX)** | Fully on-device | Apple Silicon, ~4 GB model download on first use |
| **Remote Endpoint** | Network | Any OpenAI-compatible chat completions server |

Additional options:

- **Enable AI processing** toggle — skip all AI steps (summary, action items, tags) for a session
- Output language selection (match transcript, English, Dutch, or custom ISO code)
- Customizable prompts for summary, action items, and tags/sentiment
- Model purge to reclaim disk space

### Profiles (Power User Mode)

Meeting profiles let you save different configurations for different meeting types:

- **Default** — your baseline settings
- **Team Meeting** — pre-configured prompts optimized for internal standups and planning
- **Sales Meeting** — pre-configured prompts for customer-facing meetings
- **Custom** — create your own with per-profile overrides for engine, endpoint, prompts, and output folders

Switch profiles from the Profiles tab. Each profile can override any combination of transcription engine, AI engine, endpoints, prompts, auto-processing toggles, and output folders. Anything not overridden falls back to your global settings.

Profiles can be exported and imported as JSON files for sharing across machines.

Enable Power User Mode in Settings > General to show the Profiles tab.

### Integrations

Each integration can be independently enabled and configured with field selection (choose which content to send: audio, transcript, summary, tags, sentiment, action items, markdown).

| Destination | Method | Setup |
| ----------- | ------ | ----- |
| **Obsidian** | Local Markdown files | Select vault folder |
| **Apple Notes** | AppleScript automation | Optional account/folder targeting |
| **Apple Reminders** | EventKit API | Select reminders list; creates one reminder per action item |
| **Notion** | REST API | API token + parent page or database ID |
| **Evernote** | REST API | API token + optional notebook |
| **Google Keep** | REST API | API token (enterprise/admin setup may be required) |
| **OneNote** | Microsoft Graph API | API token + optional section |
| **Webhook** | HTTP POST | URL + optional headers; supports multipart audio upload |

All integrations support connection testing from Settings > Integrations.

## Output Files

- **Recordings**: `~/Documents/dBrief/Recordings/YYYY/MM/YYYY-MM-DD_HHMM_[title].flac`
- **Transcriptions**: `~/Documents/dBrief/Transcriptions/` (Markdown with YAML frontmatter)
- **Rich transcripts**: `.richtranscript.json` sidecar alongside each Markdown file (word-level timings, speaker labels)
- **Obsidian**: Markdown saved into your selected vault folder

Markdown notes include YAML frontmatter (title, date, tags, duration, audio link, model info) and sections for transcription with timestamps, summary, action items, and tags/sentiment.

Recordings longer than 30 minutes are automatically segmented into 30-minute chunks for better transcription accuracy (except Parakeet, which handles long files natively).

## Troubleshooting

| Problem | Solution |
| ------- | -------- |
| No system audio captured | Grant Screen Recording permission in System Settings > Privacy & Security |
| Transcription fails | Check endpoint URL, model name, and API key in Settings > Recording |
| Local Whisper slow on first run | WhisperKit model assets are downloaded on first use; subsequent runs use the cache |
| AI steps fail | Verify the AI endpoint is reachable and supports `/v1/chat/completions` |
| No endpoint configured | Add one under Settings > Recording or Settings > AI & Models |
| Local models using too much disk | Purge downloaded models from Settings > AI & Models or Settings > Recording |
| Call detection not working | Ensure the app is not in the disabled list under Settings > General |
| YouTube transcription fails | Ensure yt-dlp is installed (`brew install yt-dlp`) and the URL is supported |
| Parakeet: no language or diarization | Parakeet TDT does not support language selection or speaker diarization |
