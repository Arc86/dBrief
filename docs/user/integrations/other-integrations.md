# Notion, Evernote, Google Keep, and Microsoft OneNote

dBrief can also send recordings to Notion, Evernote, Google Keep, and Microsoft OneNote.

> **Not currently available.** These integrations are built into dBrief but temporarily hidden from **Settings → Integrations** while they're being verified. The steps below describe how they work for when they're re-enabled.

---

## Notion

Add a page to a Notion database for each recording.

### Setup

#### 1. Create a Notion integration

1. Go to [https://www.notion.so/my-integrations](https://www.notion.so/my-integrations)
2. Click **New integration**
3. Give it a name (e.g. "dBrief") and select your workspace
4. Copy the **Internal Integration Token**

#### 2. Share a database with the integration

1. Open the Notion database where you want dBrief to add pages
2. Click **...** → **Add connections** → find your integration and add it

#### 3. Add the integration in dBrief

1. Go to **Settings → Integrations**
2. Enable **Notion**
3. Paste your integration token
4. Enter the database ID (the long string of characters in your database URL)
5. Choose which fields to include

### Finding your database ID

Open the database in Notion. The URL looks like:

```
https://www.notion.so/myworkspace/abc123def456...
```

The database ID is the part after the last `/` (and before any `?`).

### What gets sent

Each recording creates one page in the database. Choose from: transcript, summary, action items, tags, sentiment, and the full Markdown export.

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
