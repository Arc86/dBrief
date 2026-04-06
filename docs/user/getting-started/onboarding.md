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
