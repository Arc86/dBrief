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

Apple Notes and Webhook have a **Send fields** card where you choose what to send:

- Audio (Webhook only)
- Transcript
- Summary
- Action Items
- Tags
- Sentiment
- Markdown (the full Markdown export)
- Meeting Info (from your calendar)

Obsidian always writes the summary, action items and tags, with an **Include the transcript** toggle. Apple Reminders sends only action items.

## Enabling integrations

Go to **Settings → Integrations**, click the integration you want, and turn it on. Each integration has its own setup steps (folder, URL, etc.) — see the individual pages for details.

Each integration in the list shows a status: **On**, **Off**, or **Needs setup** (turned on but missing something it needs, such as an Obsidian vault or a webhook URL).

## When integrations run

Integrations run at the end of the processing pipeline, after transcription and AI analysis are complete.
