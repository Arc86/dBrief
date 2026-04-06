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
