# Integrations Overview

Integrations send your recording outputs to external apps and services automatically after each recording is processed.

## Available integrations

These integrations are available in **Settings → Integrations**:

| Integration | What it does |
|---|---|
| [Obsidian](obsidian.md) | Writes a Markdown file to your vault |
| [Apple Notes](apple-notes.md) | Creates a note with your selected content |
| [Apple Reminders](apple-reminders.md) | Creates one reminder per action item |
| [Webhook](webhook.md) | HTTP POST to any URL |

## Not yet available

Support for [Notion, Evernote, Google Keep, and Microsoft OneNote](other-integrations.md) is built but currently hidden from the Settings UI while it's being verified. These don't appear in **Settings → Integrations** yet.

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
