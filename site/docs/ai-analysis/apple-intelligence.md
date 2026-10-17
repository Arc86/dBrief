# Apple Intelligence

On-device AI analysis using Apple's Foundation Models framework.

> **Requires:** macOS 26 or later, Mac with Apple Silicon (M1 or later).

## What it is

Apple Intelligence uses the language model built into macOS 26 to generate summaries, action items, tags, sentiment, and a title concept entirely on your Mac — in a single guided-generation call. No data leaves your device.

dBrief uses Apple's `FoundationModels` guided generation (`@Generable`/`@Guide`) to produce all analysis fields at once, matching the same `LocalInsightsResult` shape as the Gemma and Local CLI engines. This means no separate title-generation step. A long transcript that doesn't fit the on-device context window is analysed in parts, and the results are combined.

## Setup

No download or configuration needed. Choose **Apple Intelligence** as the **Engine** in **Settings → AI analysis**. When your Mac supports it, it's marked **Recommended** in the menu.

If your Mac doesn't have Apple Silicon or isn't running macOS 26, choose another engine.

## Privacy

All processing happens on-device. Your transcripts and recordings are never sent to Apple's servers.
