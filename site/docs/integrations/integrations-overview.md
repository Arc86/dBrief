# Integrations Overview

Integrations send your recording outputs to external apps and services automatically after each recording is processed.

## Available integrations

These integrations are available in **Settings → Integrations**:

| Integration | What it does |
|---|---|
| [Obsidian](obsidian.md) | Writes a Markdown file to your vault |
| [Apple Notes](apple-notes.md) | Creates a formatted note with your selected content |
| [Apple Reminders](apple-reminders.md) | Creates one reminder per action item |
| [Webhook](webhook.md) | HTTP POST to any URL |
| [Todoist](todoist.md) | Creates one task per action item, in your Inbox or a project |
| [Notion](notion.md) | Creates one page per meeting, under a page or in a database |
| [TickTick](ticktick.md) | Creates one task per action item, in the list you choose (official downloads) |

## Not yet available

Support for [Evernote, Google Keep, and Microsoft OneNote](other-integrations.md) is built but hidden from the Settings UI while it's being verified.

## What each integration sends

Apple Notes and Webhook have a **Send fields** card where you choose what to send:

- Audio (Webhook only)
- Transcript
- Summary
- Action Items
- Tags
- Sentiment
- Markdown (the full Markdown export)
- Meeting Info (from your calendar)

Notion has an **Include in the page** card with the same choices, minus audio and Markdown. Obsidian always writes the summary, action items and tags, with an **Include the transcript** toggle. Apple Reminders, Todoist and TickTick send only action items.

Notes, tasks and pages are named after the meeting: the AI-generated title, or your meeting title when there isn't one. Placeholder action items such as "No action items identified" are never sent as tasks, reminders or to-dos.

## Enabling integrations

Go to **Settings → Integrations**, click the integration you want, and turn it on. Each integration has its own setup steps (folder, URL, token, sign-in) — see the individual pages for details. Press **⌘[** or click **All integrations** to go back to the list.

Each integration in the list shows a status: **On**, **Off**, or **Needs setup** (turned on but missing something it needs, such as an Obsidian vault, a webhook URL or a Todoist token).

## Per-profile destinations

A [meeting profile](../profiles/using-profiles.md) can send to its own Todoist project, TickTick list or Notion page or database. Set this in the profile's **Integrations** card in **Settings → Profiles**.

## When integrations run

Integrations run at the end of the processing pipeline, after transcription and AI analysis are complete.

## Retrying a delivery

If a destination couldn't be reached, the recording shows a notice and keeps its delivery for later. Use **Integrations…** on the recording (or in [Queue & Recovery](../history/queue-recovery.md#retry-an-integration)) to send it again; you can pick one destination or **All remaining**. Retries only add what's missing, so they never create duplicate notes, tasks or pages.
