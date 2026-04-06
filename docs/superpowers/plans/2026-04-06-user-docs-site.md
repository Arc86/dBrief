# dBrief User Documentation Site — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write all 27 pages of the dBrief end-user documentation site as Markdown files in `docs/user/`.

**Architecture:** Topic-first structure with a consistent page anatomy (one-line intro → context → steps/explanation → callouts). Friendly, second-person tone. No generator-specific syntax — plain Markdown compatible with Docusaurus, MkDocs, or VitePress.

**Tech Stack:** Markdown, stored in `docs/user/` within the dBrief repo.

---

## File Structure

Files to create:

```
docs/user/index.md
docs/user/getting-started/installation.md
docs/user/getting-started/quick-start.md
docs/user/getting-started/onboarding.md
docs/user/recording/recording-basics.md
docs/user/recording/audio-sources.md
docs/user/recording/call-detection.md
docs/user/recording/mini-player.md
docs/user/transcription/transcription-overview.md
docs/user/transcription/apple-speech.md
docs/user/transcription/local-whisper.md
docs/user/transcription/remote-endpoint.md
docs/user/ai-analysis/ai-overview.md
docs/user/ai-analysis/apple-intelligence.md
docs/user/ai-analysis/local-qwen.md
docs/user/ai-analysis/remote-endpoint.md
docs/user/integrations/integrations-overview.md
docs/user/integrations/apple-notes.md
docs/user/integrations/apple-reminders.md
docs/user/integrations/notion.md
docs/user/integrations/obsidian.md
docs/user/integrations/webhook.md
docs/user/integrations/other-integrations.md
docs/user/profiles/what-are-profiles.md
docs/user/profiles/using-profiles.md
docs/user/profiles/import-export.md
docs/user/history/recording-history.md
docs/user/reference/keyboard-shortcuts.md
docs/user/reference/file-locations.md
docs/user/reference/permissions.md
```

---

## Writing conventions (apply to every page)

- **Voice:** Second person ("you"), present tense
- **Sentences:** Short, active voice
- **No marketing language:** "powerful", "seamless", "game-changing" — banned
- **Constraints upfront:** State hardware/OS requirements at the top of any page that has them, in a `> **Requires:**` callout
- **Callout types:**
  - `> **Note:**` — important context
  - `> **Tip:**` — helpful but optional
  - `> **Requires:**` — hardware or OS prerequisite

---

## Task 1: Scaffold directory structure

**Files:**
- Create: `docs/user/` and all subdirectories

- [ ] **Step 1: Create directories**

```bash
mkdir -p docs/user/getting-started
mkdir -p docs/user/recording
mkdir -p docs/user/transcription
mkdir -p docs/user/ai-analysis
mkdir -p docs/user/integrations
mkdir -p docs/user/profiles
mkdir -p docs/user/history
mkdir -p docs/user/reference
```

- [ ] **Step 2: Verify structure**

```bash
find docs/user -type d
```

Expected output:
```
docs/user
docs/user/getting-started
docs/user/recording
docs/user/transcription
docs/user/ai-analysis
docs/user/integrations
docs/user/profiles
docs/user/history
docs/user/reference
```

- [ ] **Step 3: Commit**

```bash
git add docs/user
git commit -m "docs: scaffold user documentation directory structure"
```

---

## Task 2: Home page

**Files:**
- Create: `docs/user/index.md`

- [ ] **Step 1: Write `docs/user/index.md`**

```markdown
# dBrief

dBrief is a macOS menu bar app that records your meetings and calls, then automatically transcribes and analyses them with AI. You get a summary, action items, tags, and sentiment — saved to Markdown and sent wherever you want.

## Where to start

| | |
|---|---|
| **[Installation](getting-started/installation.md)** | Download the app and grant permissions |
| **[Quick Start](getting-started/quick-start.md)** | Make your first recording in 5 minutes |
| **[Transcription](transcription/transcription-overview.md)** | Choose how your recordings get transcribed |
| **[Integrations](integrations/integrations-overview.md)** | Send your notes to Notion, Obsidian, and more |
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/index.md
git commit -m "docs: add home page"
```

---

## Task 3: Getting Started — Installation

**Files:**
- Create: `docs/user/getting-started/installation.md`

- [ ] **Step 1: Write `docs/user/getting-started/installation.md`**

```markdown
# Installation

How to install dBrief and grant the permissions it needs to work.

> **Requires:** macOS 14 or later.

## Download

Download the latest release from the dBrief releases page and move `dBrief.app` to your `/Applications` folder.

## First launch

Double-click dBrief in Applications. Because dBrief is not yet distributed through the Mac App Store, macOS may show a security warning. To open it:

1. Open **System Settings → Privacy & Security**
2. Scroll down to the security section and click **Open Anyway**

The dBrief icon appears in your menu bar.

## Permissions

dBrief will ask for permissions as you use it. You can also review and grant them in **Settings → General → Permissions**.

| Permission | When it's needed |
|---|---|
| **Microphone** | Required for all recording |
| **Screen Recording** | Required for mixed audio (system sound + mic) |
| **Speech Recognition** | Required if you use the Apple Speech transcription engine |
| **Reminders** | Required if you use the Apple Reminders integration |

If you accidentally denied a permission, open **System Settings → Privacy & Security**, find the relevant section, and enable dBrief there.

## Uninstalling

Drag `dBrief.app` from `/Applications` to the Trash. Recordings and settings are stored separately — see [File Locations](../reference/file-locations.md) if you want to remove those too.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/getting-started/installation.md
git commit -m "docs: add installation page"
```

---

## Task 4: Getting Started — Quick Start

**Files:**
- Create: `docs/user/getting-started/quick-start.md`

- [ ] **Step 1: Write `docs/user/getting-started/quick-start.md`**

```markdown
# Quick Start

Make your first recording and get a transcript in under 5 minutes.

## What you need

- dBrief installed and open (the icon is in your menu bar)
- Microphone permission granted

## Step 1: Open dBrief

Click the dBrief icon in the menu bar. The main window appears.

## Step 2: Start recording

Click **Record**. dBrief starts capturing audio from your microphone.

> **Tip:** You can also press **⌘⇧R** anywhere on your Mac to start or stop recording without touching the menu bar.

A floating level meter appears on your screen while recording is active — this confirms audio is being captured.

## Step 3: Stop recording

Click **Stop** (or press **⌘⇧R** again). A sheet appears asking what you'd like to do next.

## Step 4: Transcribe

Make sure **Transcribe** is checked, then click **Done**. dBrief processes the audio and shows you the results.

## What you get

After processing, you'll see:

- **Transcript** — a time-stamped text version of the recording
- **Summary** — a short paragraph covering the main points
- **Action items** — a list of things to follow up on
- **Tags** — keywords extracted from the conversation

The results are also saved as a Markdown file. See [File Locations](../reference/file-locations.md) to find it.

## Next steps

- Change the transcription engine: [Transcription Overview](../transcription/transcription-overview.md)
- Send results to Notion, Obsidian, or elsewhere: [Integrations](../integrations/integrations-overview.md)
- Automatically start recording when a meeting app opens: [Call Detection](../recording/call-detection.md)
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/getting-started/quick-start.md
git commit -m "docs: add quick start page"
```

---

## Task 5: Getting Started — Onboarding

**Files:**
- Create: `docs/user/getting-started/onboarding.md`

- [ ] **Step 1: Write `docs/user/getting-started/onboarding.md`**

```markdown
# Onboarding Wizard

A walkthrough of the setup wizard that appears when you first launch dBrief.

## What the wizard covers

The onboarding wizard walks you through four steps:

### 1. Permissions

dBrief asks for Microphone access. This is required for all recording. You can grant Screen Recording and Speech Recognition here too — or skip them and grant them later.

### 2. Transcription engine

Choose how your recordings get converted to text:

- **Apple Speech** — on-device, no download, works on any Mac
- **Local Whisper** — on-device Whisper model, higher accuracy, requires Apple Silicon and a one-time model download
- **Remote Endpoint** — your own transcription server (OpenAI-compatible)

You can change this later in **Settings → Recording**.

### 3. AI engine

Choose how dBrief generates summaries and action items:

- **Apple Intelligence** — on-device, requires macOS 26+ on Apple Silicon
- **Qwen3 4B Local** — on-device LLM, requires Apple Silicon and a one-time model download
- **Remote Endpoint** — your own AI server (OpenAI-compatible)

You can change this later in **Settings → AI & Models**.

### 4. Output folder

Choose where dBrief saves your recordings and Markdown files. The default is `~/Documents/Recordings`. You can pick any folder you have write access to.

## Revisiting the wizard

You can't re-run the wizard, but every setting it covers is available in **Settings**. Open Settings from the dBrief menu bar window.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/getting-started/onboarding.md
git commit -m "docs: add onboarding wizard page"
```

---

## Task 6: Recording — Basics

**Files:**
- Create: `docs/user/recording/recording-basics.md`

- [ ] **Step 1: Write `docs/user/recording/recording-basics.md`**

```markdown
# Recording Basics

How to start, pause, resume, and stop a recording.

## Starting a recording

Click the dBrief icon in the menu bar, then click **Record**.

Or press **⌘⇧R** from anywhere on your Mac — you don't need to open dBrief first.

## Pausing and resuming

Click **Pause** to pause the recording. The timer stops and audio capture halts. Click **Resume** to continue from where you left off.

> **Note:** Pausing does not split the recording. When you stop, you get one file covering the whole session.

## Stopping a recording

Click **Stop** (or press **⌘⇧R**). A sheet appears where you can:

- Edit the recording title
- Choose what to process (transcribe, summarise, generate action items, tags)
- Select a meeting profile

Click **Done** to start processing, or **Discard** to delete the recording.

## Naming your recording

When you stop, you can give the recording a title. This becomes part of the filename:

```
2026-04-06_1430_team-standup.flac
```

Titles are sanitised automatically — special characters and spaces are replaced.

## What happens after you stop

1. The audio is transcoded and saved to your output folder
2. If the recording is longer than 30 minutes, it's split into 30-minute chunks automatically
3. Transcription runs (if enabled)
4. AI analysis runs (if enabled)
5. Results are saved as a Markdown file and sent to any integrations you've configured

## Settings

Recording settings are in **Settings → Recording**.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/recording/recording-basics.md
git commit -m "docs: add recording basics page"
```

---

## Task 7: Recording — Audio Sources

**Files:**
- Create: `docs/user/recording/audio-sources.md`

- [ ] **Step 1: Write `docs/user/recording/audio-sources.md`**

```markdown
# Audio Sources

dBrief can record from your microphone alone, or mix your microphone with system audio (the sound your Mac plays out loud).

## Mic-only mode

Records only your microphone input. Works with just the Microphone permission. Use this when:

- You're in a room with other people and you want to capture the conversation through your mic
- You don't have or don't want to grant Screen Recording permission

## Mixed mode (system audio + mic)

Records both your microphone and everything your Mac plays through its speakers — including remote participants on a call, shared audio in a meeting, or video playback.

> **Requires:** Screen Recording permission. macOS uses this permission to capture system audio.

Use this when:

- You're on a Zoom, Teams, or other remote call and want to capture what the other participants say
- You want to capture audio from a video or webinar

## Choosing your audio source

Open **Settings → Recording** and look for the audio source option. If you haven't granted Screen Recording permission, mixed mode is unavailable and dBrief falls back to mic-only automatically.

## Technical details

Recordings are captured at 16 kHz mono and saved as FLAC. This format is optimised for speech transcription.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/recording/audio-sources.md
git commit -m "docs: add audio sources page"
```

---

## Task 8: Recording — Call Detection

**Files:**
- Create: `docs/user/recording/call-detection.md`

- [ ] **Step 1: Write `docs/user/recording/call-detection.md`**

```markdown
# Call Detection

dBrief can watch for meeting apps and automatically prompt you to start recording — or start automatically without asking.

## Supported apps

dBrief detects the following apps when they launch:

- Zoom
- Microsoft Teams (classic and new)
- Slack
- Webex
- FaceTime
- Google Meet (in Chrome)

## How it works

When a supported app launches (or is already running when dBrief starts), dBrief checks whether your microphone is active. If it is, call detection fires.

## Response options

In **Settings → Recording**, you can choose what happens when a call is detected:

- **Ask me** — a small popup appears asking if you want to start recording. You can dismiss it if you don't want to record this call.
- **Start automatically** — dBrief starts recording immediately without asking.
- **Off** — call detection is disabled.

## Blocking specific apps

If you use an app in the supported list but don't want dBrief to react to it, add it to the blocklist in **Settings → Recording**. Blocked apps are ignored by call detection.

## Dismissing the popup

If you choose **Ask me**, the call detected popup appears as a small overlay. Click **Start Recording** to begin, or dismiss it to skip this call.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/recording/call-detection.md
git commit -m "docs: add call detection page"
```

---

## Task 9: Recording — Mini Player

**Files:**
- Create: `docs/user/recording/mini-player.md`

- [ ] **Step 1: Write `docs/user/recording/mini-player.md`**

```markdown
# Mini Player

While you're recording, dBrief shows a small floating window with a live audio level meter.

## What it shows

The mini player displays vertical level meter bars that move with your audio input in real time. This lets you confirm that dBrief is actually capturing sound — even if you've switched to a full-screen app.

A **REC** indicator is shown while recording is active. Audio source chips show which sources are being captured (mic, system audio, or both).

## Moving it

You can drag the mini player anywhere on your screen.

## Hiding it

Click the close button on the mini player to dismiss it. Recording continues in the background.

> **Note:** Hiding the mini player doesn't stop the recording.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/recording/mini-player.md
git commit -m "docs: add mini player page"
```

---

## Task 10: Transcription — Overview

**Files:**
- Create: `docs/user/transcription/transcription-overview.md`

- [ ] **Step 1: Write `docs/user/transcription/transcription-overview.md`**

```markdown
# Transcription Overview

Transcription converts your audio recording into text. dBrief offers three transcription engines.

## When transcription runs

Transcription runs automatically after you stop a recording (if you have **Transcribe** checked in the post-recording sheet). You can also re-run transcription on any past recording from the [Recording History](../history/recording-history.md).

## Choosing an engine

Go to **Settings → Recording** and select your transcription engine.

## Engine comparison

| Engine | Where it runs | Setup required | Notes |
|---|---|---|---|
| **Apple Speech** | On your Mac | None | Works on any Mac; lower accuracy for technical content |
| **Local Whisper** | On your Mac | Apple Silicon + model download | Higher accuracy; ~150 MB model download |
| **Remote Endpoint** | Your server | Server URL + optional API key | Best accuracy; requires a running server |

## Long recordings

Recordings longer than 30 minutes are automatically split into 30-minute chunks before transcription. Each chunk is transcribed separately and the results are combined.

## Transcription language

You can set the output language in **Settings → Recording**. Options include matching the transcript language or forcing English, Dutch, or a custom language code.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/transcription/transcription-overview.md
git commit -m "docs: add transcription overview page"
```

---

## Task 11: Transcription — Apple Speech

**Files:**
- Create: `docs/user/transcription/apple-speech.md`

- [ ] **Step 1: Write `docs/user/transcription/apple-speech.md`**

```markdown
# Apple Speech

On-device transcription using the speech recognition built into macOS.

## What it is

Apple Speech uses the `SFSpeechRecognizer` framework built into macOS. Transcription happens entirely on your Mac — no audio is sent anywhere.

## Setup

No download or configuration needed. Grant **Speech Recognition** permission when prompted (or in **Settings → General → Permissions**).

## When to use it

- You want zero setup and are comfortable with moderate accuracy
- You don't have Apple Silicon and can't use Local Whisper
- You don't have a transcription server

## Accuracy

Apple Speech works well for clear speech in common languages. It may struggle with:

- Technical jargon and proper nouns
- Heavy accents
- Crosstalk (multiple speakers at once)

For higher accuracy, consider [Local Whisper](local-whisper.md) or a [Remote Endpoint](remote-endpoint.md).

## Privacy

Audio is processed entirely on-device.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/transcription/apple-speech.md
git commit -m "docs: add Apple Speech transcription page"
```

---

## Task 12: Transcription — Local Whisper

**Files:**
- Create: `docs/user/transcription/local-whisper.md`

- [ ] **Step 1: Write `docs/user/transcription/local-whisper.md`**

```markdown
# Local Whisper

On-device transcription using OpenAI's Whisper model, running via WhisperKit on Apple Silicon.

> **Requires:** Mac with Apple Silicon (M1 or later).

## What it is

Local Whisper uses WhisperKit to run a Whisper speech recognition model directly on your Mac using the Neural Engine. No audio leaves your device.

## First use: model download

The first time you select Local Whisper, dBrief downloads the model (~150 MB). This happens once and the model is stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/WhisperKit/
```

You need a working internet connection for the initial download. After that, transcription works fully offline.

## Setup

1. Go to **Settings → Recording**
2. Select **Local Whisper** as your transcription engine
3. dBrief will prompt you to download the model if it isn't already on your Mac

## Deleting the model

To free up disk space, go to **Settings → AI & Models** and use the option to remove the Whisper model. You can re-download it at any time.

## Accuracy

Local Whisper is significantly more accurate than Apple Speech, especially for:

- Technical vocabulary
- Multiple speakers
- Non-native accents

## Privacy

Audio is processed entirely on-device.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/transcription/local-whisper.md
git commit -m "docs: add Local Whisper transcription page"
```

---

## Task 13: Transcription — Remote Endpoint

**Files:**
- Create: `docs/user/transcription/remote-endpoint.md`

- [ ] **Step 1: Write `docs/user/transcription/remote-endpoint.md`**

```markdown
# Remote Transcription Endpoint

Connect dBrief to your own transcription server for maximum accuracy and control.

## What it is

dBrief can send audio to any OpenAI-compatible `/v1/audio/transcriptions` endpoint, or to a [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice) instance. This lets you use larger Whisper models or cloud-hosted transcription services.

## Setting up an endpoint

1. Go to **Settings → Recording**
2. Under **Transcription Endpoint**, click **Add Endpoint**
3. Enter:
   - **Name** — a label for this endpoint (e.g. "Local Whisper Large")
   - **Base URL** — the server URL (e.g. `http://localhost:8080`)
   - **Model** — the model name (e.g. `whisper-1` or `large-v3`)
   - **API Key** — leave empty if your server doesn't require one

## Supported server formats

dBrief supports two server formats:

| Format | Endpoint path | Detection |
|---|---|---|
| OpenAI-compatible | `/v1/audio/transcriptions` | Default |
| whisper-asr-webservice | `/asr` | Auto-detected by URL pattern (port 8080 or 9000, or path contains `/asr`) |

dBrief auto-detects whisper-asr-webservice based on the URL — you don't need to configure this manually.

## Large files

For recordings that exceed typical size limits, dBrief automatically splits the audio into chunks and sends them sequentially, then combines the results.

## Privacy

Audio is sent to whichever server you configure. If you use a local server, audio stays on your network. If you use a cloud service, it is subject to that service's privacy policy.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/transcription/remote-endpoint.md
git commit -m "docs: add remote transcription endpoint page"
```

---

## Task 14: AI Analysis — Overview

**Files:**
- Create: `docs/user/ai-analysis/ai-overview.md`

- [ ] **Step 1: Write `docs/user/ai-analysis/ai-overview.md`**

```markdown
# AI Analysis Overview

After transcription, dBrief uses an AI model to analyse the transcript and generate useful outputs.

## What AI generates

| Output | Description |
|---|---|
| **Summary** | A short paragraph covering the main points of the meeting |
| **Action items** | A list of tasks and follow-ups mentioned in the conversation |
| **Tags** | Keywords extracted from the transcript |
| **Sentiment** | An overall tone reading (positive, neutral, negative) |
| **Title** | A generated title for the recording (used in the filename and Markdown header) |

## Choosing what to generate

In the post-recording sheet (the window that appears after you stop), you can toggle which outputs to generate. You can also configure defaults in **Settings → AI & Models**.

## Choosing an AI engine

Go to **Settings → AI & Models** and select your engine. dBrief offers three options:

| Engine | Where it runs | Requirements |
|---|---|---|
| **Apple Intelligence** | On your Mac | macOS 26+, Apple Silicon |
| **Qwen3 4B Local** | On your Mac | Apple Silicon + model download |
| **Remote Endpoint** | Your server | OpenAI-compatible server |

## Processing order

AI analysis runs after transcription completes. The steps run sequentially: summary → action items → tags/sentiment → title generation → Markdown export → integrations.

## Customising prompts

You can edit the prompts dBrief uses for each AI task in **Settings → AI & Models** (requires Power User Mode). Profiles can also override prompts on a per-meeting basis — see [Meeting Profiles](../profiles/what-are-profiles.md).
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/ai-analysis/ai-overview.md
git commit -m "docs: add AI analysis overview page"
```

---

## Task 15: AI Analysis — Apple Intelligence

**Files:**
- Create: `docs/user/ai-analysis/apple-intelligence.md`

- [ ] **Step 1: Write `docs/user/ai-analysis/apple-intelligence.md`**

```markdown
# Apple Intelligence

On-device AI analysis using Apple's Foundation Models framework.

> **Requires:** macOS 26 or later, Mac with Apple Silicon (M1 or later).

## What it is

Apple Intelligence uses the language model built into macOS 26 to generate summaries, action items, tags, and sentiment entirely on your Mac. No data leaves your device.

## Setup

No download or configuration needed. If your Mac meets the requirements, Apple Intelligence is available immediately in **Settings → AI & Models**.

If the option is greyed out, your Mac either doesn't have Apple Silicon or isn't running macOS 26.

## Privacy

All processing happens on-device. Your transcripts and recordings are never sent to Apple's servers.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/ai-analysis/apple-intelligence.md
git commit -m "docs: add Apple Intelligence AI page"
```

---

## Task 16: AI Analysis — Local Qwen

**Files:**
- Create: `docs/user/ai-analysis/local-qwen.md`

- [ ] **Step 1: Write `docs/user/ai-analysis/local-qwen.md`**

```markdown
# Qwen3 4B Local

On-device AI analysis using the Qwen3 4B language model, running via MLX on Apple Silicon.

> **Requires:** Mac with Apple Silicon (M1 or later).

## What it is

Qwen3 4B Local runs a 4-billion-parameter language model directly on your Mac using Apple's MLX framework and the Neural Engine. No data leaves your device.

## First use: model download

The first time you select Qwen3 4B Local, dBrief downloads the model (approximately 2–3 GB). This happens once and the model is stored at:

```
~/Library/Application Support/dBrief/LocalAIPlugin/MLX/
```

You need a working internet connection for the initial download. After that, analysis works fully offline.

## Setup

1. Go to **Settings → AI & Models**
2. Select **Qwen3 4B Local** as your AI engine
3. dBrief will prompt you to download the model if it isn't already present

## Streaming output

Results appear progressively as the model generates them — you'll see the summary build up word by word rather than waiting for the full response.

## Deleting the model

To free up disk space, go to **Settings → AI & Models** and use the option to remove the Qwen model. You can re-download it at any time.

## Privacy

All processing happens on-device. Your transcripts are never sent to any server.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/ai-analysis/local-qwen.md
git commit -m "docs: add Qwen3 4B local AI page"
```

---

## Task 17: AI Analysis — Remote Endpoint

**Files:**
- Create: `docs/user/ai-analysis/remote-endpoint.md`

- [ ] **Step 1: Write `docs/user/ai-analysis/remote-endpoint.md`**

```markdown
# Remote AI Endpoint

Connect dBrief to your own AI server for analysis.

## What it is

dBrief can send transcripts to any OpenAI-compatible `/v1/chat/completions` endpoint. This works with OpenAI's API, a local Ollama instance, or any other compatible server.

## Setting up an endpoint

1. Go to **Settings → AI & Models**
2. Under **AI Endpoint**, click **Add Endpoint**
3. Enter:
   - **Name** — a label for this endpoint (e.g. "GPT-4o" or "Local Ollama")
   - **Base URL** — the server URL (e.g. `https://api.openai.com` or `http://localhost:11434`)
   - **Model** — the model name (e.g. `gpt-4o` or `llama3`)
   - **API Key** — your API key, or leave empty for local servers that don't require one

## Privacy

Transcripts are sent to whichever server you configure. If you use OpenAI or another cloud provider, transcripts are subject to that provider's privacy policy. If you use a local server like Ollama, data stays on your machine.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/ai-analysis/remote-endpoint.md
git commit -m "docs: add remote AI endpoint page"
```

---

## Task 18: Integrations — Overview

**Files:**
- Create: `docs/user/integrations/integrations-overview.md`

- [ ] **Step 1: Write `docs/user/integrations/integrations-overview.md`**

```markdown
# Integrations Overview

Integrations send your recording outputs to external apps and services automatically after each recording is processed.

## Available integrations

| Integration | What it does |
|---|---|
| [Apple Notes](apple-notes.md) | Creates a note with your selected content |
| [Apple Reminders](apple-reminders.md) | Creates one reminder per action item |
| [Notion](notion.md) | Adds a page to a Notion database |
| [Obsidian](obsidian.md) | Writes a Markdown file to your vault |
| [Webhook](webhook.md) | HTTP POST to any URL |
| [Evernote, Google Keep, OneNote](other-integrations.md) | Sends content via each service's API |

## Field selection

For each integration, you choose which fields to send:

- Audio file
- Transcript
- Summary
- Action items
- Tags
- Sentiment
- Full Markdown export

Open the integration in **Settings → Integrations** and toggle the fields you want.

## Enabling integrations

Go to **Settings → Integrations**, find the integration you want, and enable it. Each integration has its own setup steps (API key, folder path, etc.) — see the individual pages for details.

## When integrations run

Integrations run at the end of the processing pipeline, after transcription and AI analysis are complete.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/integrations-overview.md
git commit -m "docs: add integrations overview page"
```

---

## Task 19: Integrations — Apple Notes

**Files:**
- Create: `docs/user/integrations/apple-notes.md`

- [ ] **Step 1: Write `docs/user/integrations/apple-notes.md`**

```markdown
# Apple Notes

Create a note in Apple Notes for each recording.

## Setup

1. Go to **Settings → Integrations**
2. Enable **Apple Notes**
3. Choose which fields to include in the note

No API key or account setup is needed — dBrief uses AppleScript to create notes in whichever Apple Notes account is active on your Mac.

## What gets sent

Choose from: transcript, summary, action items, tags, sentiment, and the full Markdown export.

## Where notes appear

Notes are created in the default Apple Notes account and folder. You can move them within Apple Notes after they're created.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/apple-notes.md
git commit -m "docs: add Apple Notes integration page"
```

---

## Task 20: Integrations — Apple Reminders

**Files:**
- Create: `docs/user/integrations/apple-reminders.md`

- [ ] **Step 1: Write `docs/user/integrations/apple-reminders.md`**

```markdown
# Apple Reminders

Create a reminder for each action item extracted from your recording.

## Setup

1. Go to **Settings → Integrations**
2. Enable **Apple Reminders**
3. Grant the **Reminders** permission when prompted (or in **Settings → General → Permissions**)

## How it works

After AI analysis generates action items, dBrief creates one reminder in Apple Reminders for each item. The reminders appear in your default reminders list.

> **Note:** This integration only makes sense if AI analysis is enabled and generating action items. If no action items are found in a recording, no reminders are created.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/apple-reminders.md
git commit -m "docs: add Apple Reminders integration page"
```

---

## Task 21: Integrations — Notion

**Files:**
- Create: `docs/user/integrations/notion.md`

- [ ] **Step 1: Write `docs/user/integrations/notion.md`**

```markdown
# Notion

Add a page to a Notion database for each recording.

## Setup

### 1. Create a Notion integration

1. Go to [https://www.notion.so/my-integrations](https://www.notion.so/my-integrations)
2. Click **New integration**
3. Give it a name (e.g. "dBrief") and select your workspace
4. Copy the **Internal Integration Token**

### 2. Share a database with the integration

1. Open the Notion database where you want dBrief to add pages
2. Click **...** → **Add connections** → find your integration and add it

### 3. Add the integration in dBrief

1. Go to **Settings → Integrations**
2. Enable **Notion**
3. Paste your integration token
4. Enter the database ID (the long string of characters in your database URL)
5. Choose which fields to include

## Finding your database ID

Open the database in Notion. The URL looks like:

```
https://www.notion.so/myworkspace/abc123def456...
```

The database ID is the part after the last `/` (and before any `?`).

## What gets sent

Choose from: transcript, summary, action items, tags, sentiment, and the full Markdown export. Each recording creates one page in the database.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/notion.md
git commit -m "docs: add Notion integration page"
```

---

## Task 22: Integrations — Obsidian

**Files:**
- Create: `docs/user/integrations/obsidian.md`

- [ ] **Step 1: Write `docs/user/integrations/obsidian.md`**

```markdown
# Obsidian

Write a Markdown file directly to your Obsidian vault after each recording.

## Setup

1. Go to **Settings → Integrations**
2. Enable **Obsidian**
3. Click **Choose Vault Folder** and select the folder inside your Obsidian vault where notes should be saved

No API key or Obsidian plugin is needed. dBrief writes files directly to disk.

## File format

Each recording produces a Markdown file with YAML frontmatter:

```yaml
---
title: Team Standup
date: 2026-04-06
tags: [engineering, standup]
duration: 12m 34s
audio: 2026-04-06_1430_team-standup.flac
---
```

Followed by sections for the transcript (with timestamps), summary, action items, and tags/sentiment.

## Filenames

Files are named by date and title:

```
2026-04-06_1430_team-standup.md
```

## What gets sent

The Obsidian integration always writes the full Markdown export. Field selection for other integrations doesn't affect what goes into the Obsidian file.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/obsidian.md
git commit -m "docs: add Obsidian integration page"
```

---

## Task 23: Integrations — Webhook

**Files:**
- Create: `docs/user/integrations/webhook.md`

- [ ] **Step 1: Write `docs/user/integrations/webhook.md`**

```markdown
# Webhook

Send an HTTP POST request to any URL after each recording.

## What it's for

Use the webhook integration to connect dBrief to any service that accepts HTTP requests — Zapier, Make (Integromat), a custom backend, or anything else.

## Setup

1. Go to **Settings → Integrations**
2. Enable **Webhook**
3. Enter your webhook URL
4. Choose which fields to include in the payload

## Payload format

dBrief sends the selected fields as a JSON body or multipart/form-data (if audio upload is enabled).

## Including the audio file

Enable **Include audio** in the webhook settings to attach the recording as a file upload. The request is sent as `multipart/form-data` when audio is included.

> **Note:** Audio files can be large (tens of MB for longer recordings). Make sure your webhook endpoint can handle the payload size.

## What gets sent

Choose from: transcript, summary, action items, tags, sentiment, the full Markdown export, and optionally the audio file.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/webhook.md
git commit -m "docs: add Webhook integration page"
```

---

## Task 24: Integrations — Other

**Files:**
- Create: `docs/user/integrations/other-integrations.md`

- [ ] **Step 1: Write `docs/user/integrations/other-integrations.md`**

```markdown
# Evernote, Google Keep, and Microsoft OneNote

dBrief can also send recordings to Evernote, Google Keep, and Microsoft OneNote.

---

## Evernote

### Setup

1. Go to **Settings → Integrations**
2. Enable **Evernote**
3. Enter your Evernote API token
4. Choose which fields to include

### What gets sent

Each recording creates one note in Evernote. Choose from: transcript, summary, action items, tags, sentiment, and the full Markdown export.

---

## Google Keep

### Setup

1. Go to **Settings → Integrations**
2. Enable **Google Keep**
3. Enter your Google API credentials
4. Choose which fields to include

### What gets sent

Each recording creates one note in Google Keep. Choose from: transcript, summary, action items, tags, sentiment, and the full Markdown export.

---

## Microsoft OneNote

### Setup

1. Go to **Settings → Integrations**
2. Enable **Microsoft OneNote**
3. Authenticate with your Microsoft account (dBrief uses the Microsoft Graph API)
4. Choose which fields to include

### What gets sent

Each recording creates one page in OneNote. Choose from: transcript, summary, action items, tags, sentiment, and the full Markdown export.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/integrations/other-integrations.md
git commit -m "docs: add Evernote, Google Keep, OneNote integration page"
```

---

## Task 25: Profiles

**Files:**
- Create: `docs/user/profiles/what-are-profiles.md`
- Create: `docs/user/profiles/using-profiles.md`
- Create: `docs/user/profiles/import-export.md`

- [ ] **Step 1: Write `docs/user/profiles/what-are-profiles.md`**

```markdown
# What Are Meeting Profiles?

Profiles let you save different configurations for different types of meetings and switch between them before you record.

> **Requires:** Power User Mode enabled in **Settings → General**.

## What a profile controls

A profile can override:

- **Transcription engine** — use a different engine for this meeting type
- **AI engine** — use a different model
- **Transcription and AI endpoints** — point to a different server
- **AI prompts** — customise what the AI focuses on
- **Output folder** — save to a different location

Any setting not overridden in a profile falls back to your global settings.

## Built-in profiles

dBrief includes three preset profiles to get you started:

| Profile | Description |
|---|---|
| **Default** | Your global settings — no overrides |
| **Team Meeting** | Optimised prompts for internal team meetings |
| **Sales Meeting** | Optimised prompts for sales calls and demos |

You can create additional custom profiles.

## Enabling profiles

Profiles are a power-user feature. Enable them by turning on **Power User Mode** in **Settings → General**. This adds a **Profiles** tab to Settings and a profile selector to the post-recording sheet.
```

- [ ] **Step 2: Write `docs/user/profiles/using-profiles.md`**

```markdown
# Using Profiles

How to select, edit, and switch between meeting profiles.

> **Requires:** Power User Mode enabled in **Settings → General**.

## Selecting a profile for a recording

When you stop a recording, the post-recording sheet shows a profile selector. Choose the profile that fits the meeting before clicking **Done**.

## Setting a default profile

In **Settings → Profiles**, you can set any profile as your default. The default is pre-selected in the post-recording sheet.

## Editing a profile

1. Go to **Settings → Profiles**
2. Select the profile you want to edit
3. Configure overrides — leave any setting blank to inherit from global settings

> **Note:** The Default profile cannot be deleted or renamed.

## Creating a custom profile

1. Go to **Settings → Profiles**
2. Click **Add Profile**
3. Give it a name and configure your overrides

## How overrides resolve

When a recording uses a profile, settings resolve in this order:
1. Profile override (if set)
2. Global app setting

So if a profile doesn't override the AI engine, the globally selected AI engine is used.
```

- [ ] **Step 3: Write `docs/user/profiles/import-export.md`**

```markdown
# Importing and Exporting Profiles

Share profiles between Macs or back them up to a file.

> **Requires:** Power User Mode enabled in **Settings → General**.

## Exporting profiles

1. Go to **Settings → Profiles**
2. Click **Export Profiles**
3. Choose a location to save the `.json` file

The export file contains all your custom profiles (not the built-in ones).

## Importing profiles

1. Go to **Settings → Profiles**
2. Click **Import Profiles**
3. Select the `.json` file

If an imported profile has the same name as an existing one, dBrief renames the imported version automatically (e.g. "Team Meeting 2") rather than overwriting.

## Use cases

- **New Mac setup** — export from your old Mac, import on the new one
- **Team sharing** — share a profiles file with colleagues who use dBrief
```

- [ ] **Step 4: Commit**

```bash
git add docs/user/profiles/
git commit -m "docs: add meeting profiles pages"
```

---

## Task 26: History

**Files:**
- Create: `docs/user/history/recording-history.md`

- [ ] **Step 1: Write `docs/user/history/recording-history.md`**

```markdown
# Recording History

The history list in the dBrief menu bar window shows your recent recordings.

## Viewing history

Click the dBrief menu bar icon to open the main window. Your recordings appear in the history list, sorted by most recent first. dBrief keeps up to 20 recordings in the list.

## Expanding a recording

Click a row to expand it. You'll see:

- **Duration** of the recording
- **Action chips** — quick actions you can take

## Action chips

| Chip | What it does |
|---|---|
| **Play** | Play back the recording audio |
| **View** | Open the transcript, summary, and AI results |
| **Export** | Open the Markdown file in Finder |
| **Re-run** | Run transcription or AI analysis again |
| **Delete** | Remove the recording and its files |

## Re-running transcription or AI analysis

If you want to change engines or settings and process a recording again, expand it and use **Re-run**. You can choose to re-run just transcription, just AI analysis, or both.

## The 20-item cap

The history list shows your 20 most recent recordings. Older entries are removed from the list automatically, but the actual recording files and Markdown exports remain in your output folder — they're not deleted.

See [File Locations](../reference/file-locations.md) to find your recordings on disk.
```

- [ ] **Step 2: Commit**

```bash
git add docs/user/history/recording-history.md
git commit -m "docs: add recording history page"
```

---

## Task 27: Reference pages

**Files:**
- Create: `docs/user/reference/keyboard-shortcuts.md`
- Create: `docs/user/reference/file-locations.md`
- Create: `docs/user/reference/permissions.md`

- [ ] **Step 1: Write `docs/user/reference/keyboard-shortcuts.md`**

```markdown
# Keyboard Shortcuts

## Global shortcuts

These shortcuts work anywhere on your Mac, even when dBrief is in the background.

| Shortcut | Action |
|---|---|
| **⌘⇧R** | Start or stop recording |

## Changing the shortcut

The global hotkey is not currently configurable. It is always **⌘⇧R**.
```

- [ ] **Step 2: Write `docs/user/reference/file-locations.md`**

```markdown
# File Locations

Where dBrief stores your recordings, exports, models, and settings.

## Recordings

Audio files are saved in dated subfolders inside your output folder (set during onboarding or in **Settings → Recording**):

```
~/Documents/Recordings/
└── 2026/
    └── 04/
        └── 2026-04-06_1430_team-standup.flac
```

You can change the output folder in **Settings → Recording**.

## Markdown exports

Markdown files are saved in the same dated subfolder as the audio file, unless you've configured an Obsidian vault folder — in which case they go there instead.

## AI models

Local AI models (Whisper and Qwen) are stored in Application Support:

```
~/Library/Application Support/dBrief/LocalAIPlugin/
├── WhisperKit/    ← Local Whisper model (~150 MB)
└── MLX/           ← Qwen3 4B model (~2–3 GB)
```

To remove models, use the options in **Settings → AI & Models**.

## Settings

App preferences are stored in `UserDefaults` under the `com.dbrief.app` domain. You can reset all settings by deleting this domain with `defaults delete com.dbrief.app` in Terminal — but this also resets your output folder path and engine choices.

## API keys and tokens

Integration tokens (Notion, Evernote, etc.) are stored securely in the macOS Keychain under `com.dbrief.app`.

## Uninstalling completely

To remove everything dBrief has written to your Mac:

1. Delete `dBrief.app` from `/Applications`
2. Delete `~/Library/Application Support/dBrief/`
3. Run `defaults delete com.dbrief.app` in Terminal
4. Open Keychain Access and delete any entries for `com.dbrief.app`
5. Optionally delete your recordings folder
```

- [ ] **Step 3: Write `docs/user/reference/permissions.md`**

```markdown
# Permissions

dBrief needs certain macOS permissions to work. Here's what each one is for and how to grant it if you declined it at first launch.

## Microphone

**Required for:** All recording.

If microphone access is denied, dBrief cannot record anything.

**To grant:** Open **System Settings → Privacy & Security → Microphone** and enable dBrief.

## Screen Recording

**Required for:** Mixed audio mode (capturing system sound alongside your mic).

Without this permission, dBrief can still record your microphone. It falls back to mic-only mode automatically.

**To grant:** Open **System Settings → Privacy & Security → Screen Recording** and enable dBrief. You may need to restart dBrief after granting this.

## Speech Recognition

**Required for:** The Apple Speech transcription engine.

Without this permission, Apple Speech is unavailable. Local Whisper and remote endpoints don't need it.

**To grant:** Open **System Settings → Privacy & Security → Speech Recognition** and enable dBrief.

## Reminders

**Required for:** The Apple Reminders integration.

**To grant:** Open **System Settings → Privacy & Security → Reminders** and enable dBrief.

---

> **Tip:** You can review all permissions from inside dBrief at **Settings → General**, where each permission shows its current status.
```

- [ ] **Step 4: Commit**

```bash
git add docs/user/reference/
git commit -m "docs: add reference pages (shortcuts, file locations, permissions)"
```

---

## Self-Review

After completing all tasks:

- [ ] **Spec coverage check:** Verify all 27 pages from the spec are present in `docs/user/`

```bash
find docs/user -name "*.md" | sort
```

Expected: 28 lines (27 pages + index.md).

- [ ] **Accuracy check:** Spot-check facts against source:
  - Known call apps match `Sources/dBrief/Services/CallDetectionService.swift`
  - Settings tab names match `Sources/dBrief/UI/SettingsView.swift`
  - Profiles tab visibility condition (Power User Mode) matches `Sources/dBrief/UI/SettingsView.swift:28`
  - Model storage paths match `CLAUDE.md`

- [ ] **Link check:** Verify all relative links between pages use correct paths (no broken `../` references)
