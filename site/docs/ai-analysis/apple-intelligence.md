# Apple Intelligence

On-device AI analysis using Apple's Foundation Models framework.

> **Requires:** macOS 26 or later, Mac with Apple Silicon (M1 or later).

## What it is

Apple Intelligence uses the language model built into macOS 26 to generate summaries, action items, tags, sentiment, and a title concept entirely on your Mac — in a single guided-generation call. No data leaves your device.

dBrief uses Apple's `FoundationModels` guided generation (`@Generable`/`@Guide`) to produce all analysis fields at once, matching the same `LocalInsightsResult` shape as the Gemma and Local CLI engines. This means no separate title-generation step and a tight ~12K-character transcript budget tuned for the on-device context window.

## Setup

No download or configuration needed. If your Mac meets the requirements, Apple Intelligence is available immediately in **Settings → AI Analysis**.

If the option is greyed out, your Mac either doesn't have Apple Silicon or isn't running macOS 26.

## Privacy

All processing happens on-device. Your transcripts and recordings are never sent to Apple's servers.
