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
