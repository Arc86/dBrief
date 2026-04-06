# dBrief User Documentation Site — Design Spec

**Date:** 2026-04-06
**Status:** Approved

## Overview

A multi-page end-user documentation site for dBrief, a macOS menu bar app for recording, transcribing, and AI-analysing meetings. The docs cover everything from first install through advanced features. Tone is friendly and approachable (think Notion, Bear). All pages will be written before launch.

---

## Audience

End users of dBrief: people who have downloaded or plan to download the app. Not developers or contributors (the existing CLAUDE.md covers that). Readers range from first-time users following the getting-started flow to returning users looking up a specific feature.

---

## Format

A multi-page docs site stored in `docs/user/` in the repo. Files are Markdown, compatible with static site generators such as Docusaurus, MkDocs, or VitePress. No specific generator is prescribed — the Markdown content is the deliverable.

---

## Site Structure

```
docs/user/
├── index.md
├── getting-started/
│   ├── installation.md
│   ├── quick-start.md
│   └── onboarding.md
├── recording/
│   ├── recording-basics.md
│   ├── audio-sources.md
│   ├── call-detection.md
│   └── mini-player.md
├── transcription/
│   ├── transcription-overview.md
│   ├── apple-speech.md
│   ├── local-whisper.md
│   └── remote-endpoint.md
├── ai-analysis/
│   ├── ai-overview.md
│   ├── apple-intelligence.md
│   ├── local-qwen.md
│   └── remote-endpoint.md
├── integrations/
│   ├── integrations-overview.md
│   ├── apple-notes.md
│   ├── apple-reminders.md
│   ├── notion.md
│   ├── obsidian.md
│   ├── webhook.md
│   └── other-integrations.md
├── profiles/
│   ├── what-are-profiles.md
│   ├── using-profiles.md
│   └── import-export.md
├── history/
│   └── recording-history.md
└── reference/
    ├── keyboard-shortcuts.md
    ├── file-locations.md
    └── permissions.md
```

Total: 27 pages.

---

## Page Anatomy

Every page follows this structure:

1. **One-line intro** — what this page covers, in plain language
2. **When you'd use this** — brief context (omitted on procedural pages where it's obvious)
3. **Steps or explanation** — numbered steps for how-to pages; prose + callouts for concept pages
4. **Callout boxes** — used sparingly: "Tip", "Note", "Requires" (e.g. hardware/OS constraints)

No FAQ dumps at page bottoms. Questions live inline with the content they answer.

---

## Writing Style

- **Voice:** Second person ("you"), present tense
- **Sentences:** Short, active voice
- **Tone:** Friendly, direct — no marketing language ("powerful", "seamless", "game-changing")
- **Constraints:** Stated plainly and upfront (e.g. "Local Whisper requires Apple Silicon and downloads a ~150 MB model on first use")
- **Callout types:**
  - `> **Note:**` — important context
  - `> **Tip:**` — helpful but optional
  - `> **Requires:**` — hardware or OS prerequisite

---

## Home Page (`index.md`)

- 2–3 sentence intro: what dBrief is and what it does
- Four core journey cards: **Set up → Record → Transcribe & Analyse → Send Somewhere**
- No feature list, no screenshots — pure orientation

---

## Page Content Plan

### `getting-started/installation.md`
Where to download dBrief, how to move it to Applications, first-launch permissions prompt (mic, screen recording, speech recognition). Common first-run issues.

### `getting-started/quick-start.md`
Make your first recording in under 5 minutes. Click the menu bar icon → choose audio source → hit Record → stop → transcribe. Shows the result. Links to deeper pages.

### `getting-started/onboarding.md`
Walkthrough of the setup wizard shown on first launch: permission grants, engine selection, output folder choice.

### `recording/recording-basics.md`
Starting, pausing, resuming, and stopping a recording. The global hotkey (⌘⇧R). Naming recordings. What happens after you hit Stop.

### `recording/audio-sources.md`
Mic-only vs. mixed mode (system audio + mic). When to use each. What "mixed mode" requires (Screen Recording permission). Capture format (16 kHz mono FLAC).

### `recording/call-detection.md`
How dBrief detects Zoom, Teams, Slack, Google Meet, and other apps. Auto-start vs. prompt. The blocklist for apps you don't want to trigger detection.

### `recording/mini-player.md`
The floating level meter window that appears during recording. What the peak bars show. How to dismiss it.

### `transcription/transcription-overview.md`
What transcription is, when it runs (after recording stops or on-demand from history), and how to choose an engine. High-level comparison table of the three engines.

### `transcription/apple-speech.md`
On-device transcription using Apple's built-in Speech framework. No download required. Works on any Mac. Accuracy trade-offs vs. Whisper.

### `transcription/local-whisper.md`
On-device Whisper via WhisperKit. Requires Apple Silicon. Downloads a ~150 MB model on first use (stored in `~/Library/Application Support/dBrief/`). How to trigger a download, how to delete the model.

### `transcription/remote-endpoint.md`
Connecting to an OpenAI-compatible `/v1/audio/transcriptions` server or a whisper-asr-webservice instance. Adding an endpoint in settings. API key setup. Auto-detection of whisper-asr-webservice by URL pattern.

### `ai-analysis/ai-overview.md`
What AI generates after transcription: summary, action items, tags, sentiment, and a generated title. The sequential pipeline. How to toggle which outputs are generated.

### `ai-analysis/apple-intelligence.md`
On-device AI via the FoundationModels framework. Requires macOS 26+ on Apple Silicon. No download needed beyond the OS.

### `ai-analysis/local-qwen.md`
On-device Qwen3 4B via MLX. Requires Apple Silicon. Downloads a ~2–3 GB model on first use. Streaming output. How to trigger a download, how to delete the model.

### `ai-analysis/remote-endpoint.md`
Connecting to an OpenAI-compatible `/v1/chat/completions` server. Adding an endpoint, model name, API key. Works with OpenAI, local Ollama, etc.

### `integrations/integrations-overview.md`
What integrations do: send recording outputs (audio, transcript, summary, tags, sentiment, action items, markdown) to external destinations after processing. Field selection — choosing what each integration receives.

### `integrations/apple-notes.md`
Sends a note to Apple Notes via AppleScript. Setup: just enable in settings. Field selection.

### `integrations/apple-reminders.md`
Creates one reminder per action item via EventKit. Setup: grant Reminders permission. Field selection.

### `integrations/notion.md`
Sends content to a Notion database via the Notion API. Setup: create an integration token, share a database, paste the token in settings. Field selection.

### `integrations/obsidian.md`
Writes Markdown files directly to an Obsidian vault folder on disk. Setup: pick the vault folder in settings. YAML frontmatter, timestamp-based filenames.

### `integrations/webhook.md`
HTTP POST to any URL with a configurable payload. Optional multipart audio upload. Use cases: Zapier, Make, custom backends. Field selection.

### `integrations/other-integrations.md`
Evernote, Google Keep, Microsoft OneNote — setup and field selection for each.

### `profiles/what-are-profiles.md`
What meeting profiles are: per-meeting configuration overrides for engine, prompts, output folder, and integrations. Built-in presets (Default, Team Meeting, Sales Meeting). When to use them.

### `profiles/using-profiles.md`
Selecting a profile before recording. Editing a custom profile. Switching between profiles. How overrides resolve against global settings.

### `profiles/import-export.md`
Exporting profiles to a file (for backup or sharing). Importing from a file. Conflict handling when a profile name already exists.

### `history/recording-history.md`
The history list in the menu bar popover. The 20-item cap. Expanding a row to see action chips (replay, view transcript, export, delete). Duration display. Re-running transcription or AI analysis on a past recording.

### `reference/keyboard-shortcuts.md`
Global hotkey: ⌘⇧R (record/stop toggle). Any in-app shortcuts.

### `reference/file-locations.md`
Where dBrief stores things: recordings (`~/Documents/Recordings/YYYY/MM/`), Markdown exports, AI models (`~/Library/Application Support/dBrief/LocalAIPlugin/`), settings (UserDefaults), tokens (Keychain).

### `reference/permissions.md`
The four permissions dBrief may request: Microphone, Screen Recording (for mixed audio), Speech Recognition (Apple Speech engine), Reminders (Apple Reminders integration). How to grant each in System Settings if declined at first-run.

---

## Scope

All 27 pages are in scope. No phasing — full coverage delivered together.

Out of scope for this docs site:
- Developer/contributor docs (covered by CLAUDE.md)
- App Store description or marketing copy
- In-app help UI
